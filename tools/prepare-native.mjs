#!/usr/bin/env node
import { distributionOptions } from './distribution-identity.mjs';
import { cp, mkdir, rename, rm, lstat, readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { downloadRuntimeArtifact, SDK_VERSION } from './runtime-artifacts.mjs';
import { nativeArtifactPaths } from './native-artifact-paths.mjs';
async function replaceDirectory(staged, destination) {
  const previous = `${destination}.previous-${randomUUID()}`; let existed = false;
  try {
    try { await rename(destination, previous); existed = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
    try { await rename(staged, destination); }
    catch (error) { if (existed) await rename(previous, destination); throw error; }
    if (existed) await rm(previous, { recursive: true, force: true });
  } finally { await rm(staged, { recursive: true, force: true }); }
}
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2), at = name => { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; };
const expectedDistribution = distributionOptions(args);
const platform = at('--platform'), arch = at('--arch');
if (!['android', 'ios', 'macos', 'windows', 'linux'].includes(platform) || !arch) throw new Error('Usage: node tools/prepare-native.mjs --platform android|ios|macos|windows|linux --arch <exact pinned arch> [--manifest <release lock>] [--artifact-dir <authorized offline archives>]');
const manifestPath = resolve(at('--manifest') ?? join(root, 'runtime-artifacts.lock.json'));
if ((await lstat(manifestPath)).size > 1024 ** 2) throw Object.assign(new Error('Artifact manifest exceeded its size limit.'), { code: 'ERR_RUNTIME_MANIFEST' });
const paths = nativeArtifactPaths(join(root, '.runtime'), JSON.parse(await readFile(manifestPath, 'utf8')),
  { ...expectedDistribution, version: SDK_VERSION, platform, arch, abiVersion: 1 });
const installed = paths.installDirectory;
const artifact = await downloadRuntimeArtifact({ manifestPath,
  ...expectedDistribution, version: SDK_VERSION, platform, arch, component: paths.pin.component, abiVersion: 1, outDirectory: paths.outDirectory, installDirectory: installed,
  expectedArtifact: paths.pin,
  artifactDirectory: at('--artifact-dir') ?? process.env.WEAPP_CONTAINER_RUNTIME_ARTIFACT_DIR });
const regular = async path => { if (!(await lstat(path)).isFile()) throw new Error(`Native SDK file is not regular: ${path}`); };
if (platform === 'android') {
  await regular(join(installed, `maven/io/github/weapp-container/weapp-container-android/${SDK_VERSION}/weapp-container-android-${SDK_VERSION}.aar`));
  const parent = join(root, 'weapp_container_android'), destination = join(parent, 'native');
  const staged = join(parent, `.native-${randomUUID()}`); await cp(installed, staged, { recursive: true });
  await replaceDirectory(staged, destination);
} else if (platform === 'ios') {
  await regular(join(installed, 'Frameworks/WeappContainerNative.xcframework/Info.plist'));
  const parent = join(root, 'weapp_container_ios/ios/vendor'), destination = join(parent, 'WeappContainer');
  await mkdir(parent, { recursive: true }); const staged = join(parent, `.WeappContainer-${randomUUID()}`);
  await cp(installed, staged, { recursive: true });
  await replaceDirectory(staged, destination);
} else {
  const result = spawnSync(process.execPath, [join(root, 'native_desktop/prepare.mjs'), '--target', platform, '--from', installed, '--distribution-profile', expectedDistribution.distributionProfile, ...(expectedDistribution.policySha256 ? ['--showcase-policy-sha256', expectedDistribution.policySha256] : [])], { stdio: 'inherit' });
  if (result.error || result.status !== 0) throw new Error(`Desktop native preparation failed: ${result.error?.message ?? result.status}`);
}
console.log(JSON.stringify({ status: 'prepared', sdkVersion: SDK_VERSION, ...expectedDistribution, platform, arch, nativeBuild: 'not-run',
  artifactSha256: artifact.receipt.sha256, installed }, null, 2));
