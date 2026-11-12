#!/usr/bin/env node
import { assertDistributionIdentity, distributionOptions, verifyDistributionArtifact } from './distribution-identity.mjs';
// Keep this standalone packaging helper self-contained: package.mjs exports
// native_desktop without the source checkout's tools/ directory.
const SDK_VERSION = process.env.WEAPP_CONTAINER_SDK_VERSION ?? '0.1.0-preview.7.0';
import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const expectedDistribution = distributionOptions(argv);
const option = name => { const i = argv.indexOf(name); return i < 0 ? undefined : argv[i + 1]; };
const target = option('--target');
const source = option('--from');
if (!['macos', 'windows', 'linux'].includes(target) || !source) throw new Error('Usage: node prepare.mjs --target macos|windows|linux --from <installed-desktop-sdk>');
const native = path.resolve(source);
const archive = target === 'windows' ? 'weapp_container_sdk.dll.lib' : 'libweapp_container_sdk.a';
const sdkVersion = SDK_VERSION;
const receipt = JSON.parse(await readFile(path.join(native, 'package.json'), 'utf8'));
assertDistributionIdentity(receipt, expectedDistribution);
for (const slice of receipt.native ?? []) assertDistributionIdentity(slice, expectedDistribution);
const cleanSource = value => value.sourceDirty === false && /^[a-f0-9]{40}$/.test(value.sourceCommit ?? '');
if (receipt.schemaVersion !== 1 || receipt.status !== 'verified' || receipt.sdkVersion !== sdkVersion || !cleanSource(receipt)) {
  throw new Error(`Native desktop package must have a verified, clean ${sdkVersion} package.json receipt`);
}
if (!String(receipt.platform).startsWith(`${target}-`)) throw new Error('Native package platform does not match the requested Flutter target');
if (!Array.isArray(receipt.native) || receipt.native.length === 0 || receipt.native.some(value =>
  value.schemaVersion !== 1 || value.abiVersion !== 1 || !cleanSource(value) || value.platform !== target ||
  value.sdkVersion !== sdkVersion || value.status !== 'built' || value.exitCode !== undefined && value.exitCode !== 0)) {
  throw new Error('Every native slice must have a successful clean source receipt for this SDK version');
}
const archiveFile = `lib/${archive}`;
const artifact = receipt.artifacts?.find(value => value.file === archiveFile);
const archiveBytes = await readFile(path.join(native, archiveFile));
const archiveSha256 = createHash('sha256').update(archiveBytes).digest('hex');
if (!artifact || artifact.sha256 !== archiveSha256) throw new Error('Native archive SHA256 does not match the installed package receipt');
let runtimeLibrary, runtimeBytes, runtimeSha256;
if (target === 'windows') {
  runtimeLibrary = 'weapp_container_sdk.dll';
  const file = `bin/${runtimeLibrary}`, runtimeArtifact = receipt.artifacts?.find(value => value.file === file);
  runtimeBytes = await readFile(path.join(native, file));
  runtimeSha256 = createHash('sha256').update(runtimeBytes).digest('hex');
  if (!runtimeArtifact || runtimeArtifact.sha256 !== runtimeSha256) throw new Error('Native runtime DLL SHA256 does not match the installed package receipt');
}
if (expectedDistribution.distributionProfile === 'restricted-showcase') verifyDistributionArtifact(runtimeBytes ?? archiveBytes, expectedDistribution);
const headerBytes = await readFile(path.join(native, 'include/weapp_container_sdk.h'));
const expectedHeader = await readFile(path.join(here, 'include/weapp_container_sdk.h'));
if (!headerBytes.equals(expectedHeader)) throw new Error('Installed native SDK header differs from the reviewed ABI contract');
const headerSha256 = createHash('sha256').update(headerBytes).digest('hex');
// Native preview adapters use the separately built open-source desktop wrapper
// and borrow the exact registry-owned runtime. Neither source nor another
// checkout is compiled while preparing a consumer.
let wrapperBytes, wrapperArchive, wrapperSha256;
const wrapperHeaders = new Map();
{
  wrapperArchive = target === 'windows' ? 'weapp_container_desktop.lib' : 'libweapp_container_desktop.a';
  const file = `lib/${wrapperArchive}`;
  const artifact = receipt.artifacts?.find(value => value.file === file);
  wrapperBytes = await readFile(path.join(native, file));
  wrapperSha256 = createHash('sha256').update(wrapperBytes).digest('hex');
  if (!artifact || artifact.sha256 !== wrapperSha256) throw new Error('Native device/preview wrapper archive SHA256 does not match the package receipt');
  for (const file of ['weapp/desktop.hpp', 'weapp/device_apis.hpp', 'weapp/native_preview.hpp', 'weapp_container_sdk_gl.h']) {
    const bytes = await readFile(path.join(native, 'include', file));
    const expected = await readFile(path.join(here, 'include', file));
    if (!bytes.equals(expected)) throw new Error(`Installed native device/preview header differs from the reviewed contract: ${file}`);
    wrapperHeaders.set(file, bytes);
  }
}

const plugin = path.join(here, '..', `weapp_container_${target}`, target);
// Copy into each package so CocoaPods and CMake consumers are relocatable and
// never resolve a source checkout, Cargo cache, or another worktree's outputs.
await rm(path.join(plugin, 'native_shared'), { recursive: true, force: true });
await rm(path.join(plugin, 'vendor'), { recursive: true, force: true });
for (const directory of ['include', 'src', 'third_party']) await cp(path.join(here, directory), path.join(plugin, 'native_shared', directory), { recursive: true });
await mkdir(path.join(plugin, 'vendor/lib'), { recursive: true });
await mkdir(path.join(plugin, 'vendor/include'), { recursive: true });
await writeFile(path.join(plugin, 'vendor/include/weapp_container_sdk.h'), headerBytes);
await writeFile(path.join(plugin, `vendor/lib/${archive}`), archiveBytes);
if (runtimeBytes) {
  await mkdir(path.join(plugin, 'vendor/bin'), { recursive: true });
  await writeFile(path.join(plugin, `vendor/bin/${runtimeLibrary}`), runtimeBytes);
}
if (wrapperBytes) {
  await writeFile(path.join(plugin, `vendor/lib/${wrapperArchive}`), wrapperBytes);
  for (const [file, bytes] of wrapperHeaders) {
    await mkdir(path.dirname(path.join(plugin, 'vendor/include', file)), { recursive: true });
    await writeFile(path.join(plugin, 'vendor/include', file), bytes);
  }
}

// Native installation layouts carry the verified notices in share/ or licenses/.
for (const directory of ['share', 'licenses']) {
  try { await cp(path.join(native, directory), path.join(plugin, 'vendor', directory), { recursive: true }); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
}
await writeFile(path.join(plugin, 'vendor/prepared.json'), `${JSON.stringify({
  schemaVersion: 1, target, archive, abi: 1, sdkVersion, ...expectedDistribution,
  sourceCommit: receipt.sourceCommit, sourceDirty: false,
  nativeSourceCommits: [...new Set(receipt.native.map(value => value.sourceCommit))],
  archiveSha256, headerSha256, packageReceipt: receipt,
  ...(runtimeBytes ? { runtimeLibrary, runtimeSha256 } : {}),
  ...(wrapperBytes ? { wrapperArchive, wrapperSha256,
    wrapperHeaders: Object.fromEntries([...wrapperHeaders].map(([file, bytes]) =>
      [file, createHash('sha256').update(bytes).digest('hex')])) } : {}),
}, null, 2)}\n`);
console.log(`Prepared ${target}: ${plugin}`);
