import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, cp, rm, readdir, realpath } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { nativeArtifactPaths } from '../tools/native-artifact-paths.mjs';
import { downloadRuntimeArtifact, SDK_VERSION } from '../tools/runtime-artifacts.mjs';
import { writeSourceInventory } from '../tools/source-inventory.mjs';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const toolNames = ['distribution-identity.mjs', 'prepare-native.mjs', 'runtime-artifacts.mjs', 'native-artifact-paths.mjs', 'verify-native.mjs', 'package.mjs', 'source-inventory.mjs', 'unpack-runtime.py'];
const root = new URL('../', import.meta.url);
async function fixture(t) {
  const dir = await realpath(await mkdtemp(join(tmpdir(), 'weapp-flutter-native-cache-')));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const tools = join(dir, 'tools'), offline = join(dir, 'offline');
  await mkdir(tools); await mkdir(offline);
  await mkdir(join(dir, 'weapp_container_ios/ios/vendor'), { recursive: true });
  for (const name of toolNames) await cp(new URL(`tools/${name}`, root), join(tools, name));
  await mkdir(join(dir, 'example/shared'), { recursive: true });
  await cp(new URL('example/shared/make-fixture.mjs', root), join(dir, 'example/shared/make-fixture.mjs'));
  return { dir, tools, offline, lock: join(dir, 'lock.json'), vendor: join(dir, 'weapp_container_ios/ios/vendor/WeappContainer') };
}
async function pin(f, version, content) {
  const fileName = 'ios-sdk.tar.gz', archive = join(f.offline, fileName);
  // This is an inert installer fixture, not a native SDK/device acceptance pack.
  const made = spawnSync(process.env.PYTHON ?? 'python3', ['-c',
    'import io,tarfile,sys; t=tarfile.open(sys.argv[1],"w:gz"); b=sys.argv[2].encode(); i=tarfile.TarInfo("Frameworks/WeappContainerNative.xcframework/Info.plist"); i.size=len(b); i.mode=420; t.addfile(i,io.BytesIO(b)); t.close()', archive, content], { encoding: 'utf8' });
  assert.equal(made.status, 0, made.stderr);
  const bytes = await readFile(archive);
  const entry = { component: 'ios-sdk', platform: 'ios', arch: 'universal', architectures: ['arm64-device', 'arm64-simulator', 'x86_64-simulator'], fileName, size: bytes.length, sha256: sha(bytes) };
  const manifest = { schemaVersion: 1, runtimeVersion: version, abiVersion: 1,
    source: { repository: 'weapp-container/weapp-container', releaseTag: `runtime-v${version}` }, artifacts: [entry] };
  await writeFile(f.lock, JSON.stringify(manifest));
  const original = await readFile(new URL('tools/runtime-artifacts.mjs', root), 'utf8');
  // Model upgrading the standalone SDK itself, keeping the CLI's strict version
  // match. No --version escape hatch is added to production preparation.
  await writeFile(join(f.tools, 'runtime-artifacts.mjs'), original.replace(/export const SDK_VERSION = '[^']+';/, `export const SDK_VERSION = '${version}';`));
  return { entry, manifest };
}
async function reviewPackageFixture(f) {
  // Packaging requires reviewed standalone source; installed native bytes and
  // download caches stay outside that source inventory, as in real checkouts.
  await writeFile(join(f.dir, '.gitignore'), '/offline/\n/.runtime/\n/weapp_container_ios/ios/vendor/\n');
  await writeFile(join(f.dir, 'ORIGIN.json'), JSON.stringify({ schemaVersion: 1, scope: 'Inert source-contract fixture, not extraction or runtime acceptance evidence' }));
  const git = args => {
    const result = spawnSync('git', args, { cwd: f.dir, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
  };
  git(['init', '--quiet']); git(['add', '.']);
  git(['-c', 'user.name=SDK Package Test', '-c', 'user.email=sdk-package@example.invalid', 'commit', '--quiet', '-m', 'Fixture source baseline']);
  writeSourceInventory(f.dir, { sdkVersion: SDK_VERSION, reason: 'Review inert package preflight fixture source' });
  git(['add', 'SOURCE-INVENTORY.json']);
}
function prepare(f) {
  return spawnSync(process.execPath, [join(f.tools, 'prepare-native.mjs'), '--platform', 'ios', '--arch', 'universal', '--manifest', f.lock, '--artifact-dir', f.offline], { encoding: 'utf8' });
}
function verify(f, installed) {
  return spawnSync(process.execPath, ['--input-type=module', '-e',
    'const {verifyNativeInstallation}=await import(process.argv[1]); console.log(JSON.stringify(verifyNativeInstallation(process.argv[2],"ios",process.argv[3])));',
    pathToFileURL(join(f.tools, 'verify-native.mjs')).href, installed, f.lock], { encoding: 'utf8' });
}
const info = base => join(base, 'Frameworks/WeappContainerNative.xcframework/Info.plist');

test('real prepare preserves immutable caches across SDK upgrades and different valid pins with one filename', async t => {
  const f = await fixture(t);
  const legacyInstall = join(f.dir, '.runtime/ios'), legacyDownload = join(f.dir, '.runtime/downloads/ios-sdk.tar.gz');
  await mkdir(legacyInstall, { recursive: true }); await mkdir(join(f.dir, '.runtime/downloads'), { recursive: true });
  await writeFile(join(legacyInstall, 'historical.txt'), 'preserve old install'); await writeFile(legacyDownload, 'preserve old flat cache');
  const accepted = [];
  for (const [version, content] of [['0.1.0-preview.2', 'old preview'], [SDK_VERSION, 'first current-version pin'], [SDK_VERSION, 'final reviewed current-version pin']]) {
    const { manifest, entry } = await pin(f, version, content);
    const result = prepare(f); assert.equal(result.status, 0, result.stderr);
    const report = JSON.parse(result.stdout);
    const paths = nativeArtifactPaths(join(f.dir, '.runtime'), manifest, { version, platform: 'ios', arch: 'universal', abiVersion: 1 });
    assert.equal(report.installed, paths.installDirectory);
    assert.equal(report.artifactSha256, entry.sha256);
    assert.equal(await readFile(info(f.vendor), 'utf8'), content);
    assert.equal(await readFile(info(paths.installDirectory), 'utf8'), content);
    assert.equal(sha(await readFile(join(paths.outDirectory, entry.fileName))), entry.sha256);
    const revalidated = verify(f, f.vendor); assert.equal(revalidated.status, 0, revalidated.stderr);
    assert.equal(JSON.parse(revalidated.stdout).archiveSha256, entry.sha256, 'package verification uses the same content-addressed archive');
    for (const prior of accepted) assert.equal(await readFile(info(prior.directory), 'utf8'), prior.content);
    accepted.push({ directory: paths.installDirectory, content });
  }
  assert.equal(new Set(accepted.map(v => v.directory)).size, 3);
  assert.equal(await readFile(join(legacyInstall, 'historical.txt'), 'utf8'), 'preserve old install');
  assert.equal(await readFile(legacyDownload, 'utf8'), 'preserve old flat cache');
  const repeated = prepare(f); assert.equal(repeated.status, 0, repeated.stderr);
  assert.equal(await readFile(info(f.vendor), 'utf8'), accepted.at(-1).content);
  await reviewPackageFixture(f);
  const packageCheck = spawnSync(process.execPath, [join(f.tools, 'package.mjs'), '--platform', 'ios', '--manifest', f.lock, '--flutter', join(f.dir, 'intentionally-absent-flutter')], { encoding: 'utf8' });
  assert.notEqual(packageCheck.status, 0);
  assert.match(packageCheck.stderr, /Cannot verify Flutter toolchain/, 'package preflight accepts the exact new install/cache before requiring Flutter');
});

test('validated platform and architecture identities have distinct storage paths', () => {
  const version = SDK_VERSION;
  const manifest = { schemaVersion: 1, runtimeVersion: version, abiVersion: 1,
    source: { repository: 'weapp-container/weapp-container', releaseTag: `runtime-v${version}` },
    artifacts: ['arm64-device', 'arm64-simulator'].map(arch => ({ component: 'ios-sdk', platform: 'ios', arch,
      fileName: `${arch}.tar.gz`, size: 1, sha256: 'a'.repeat(64) })) };
  const device = nativeArtifactPaths('/unused/runtime', manifest, { version, platform: 'ios', arch: 'arm64-device' });
  const simulator = nativeArtifactPaths('/unused/runtime', manifest, { version, platform: 'ios', arch: 'arm64-simulator' });
  assert.notEqual(device.outDirectory, simulator.outDirectory);
  assert.notEqual(device.installDirectory, simulator.installDirectory);
  assert.throws(() => nativeArtifactPaths('/unused/runtime', manifest, { version, platform: 'ios', arch: '../escape' }), { code: 'ERR_RUNTIME_TARGET' });
});

test('bad pin and corrupt immutable installation cannot replace accepted vendor bytes', async t => {
  const f = await fixture(t), { manifest } = await pin(f, SDK_VERSION, 'accepted bytes');
  const first = prepare(f); assert.equal(first.status, 0, first.stderr);
  const installed = JSON.parse(first.stdout).installed;
  const vendorReceipt = await readFile(join(f.vendor, '.runtime-install.json'));
  await writeFile(f.lock, JSON.stringify({ ...manifest, artifacts: [{ ...manifest.artifacts[0], sha256: '0'.repeat(64) }] }));
  const rejected = prepare(f); assert.notEqual(rejected.status, 0); assert.match(rejected.stderr, /ERR_RUNTIME_INTEGRITY/);
  assert.equal(await readFile(info(f.vendor), 'utf8'), 'accepted bytes');
  assert.deepEqual(await readFile(join(f.vendor, '.runtime-install.json')), vendorReceipt);
  await writeFile(f.lock, JSON.stringify(manifest));
  await writeFile(info(installed), 'changed cache installation');
  const corrupt = prepare(f); assert.notEqual(corrupt.status, 0); assert.match(corrupt.stderr, /ERR_RUNTIME_INSTALL/);
  assert.equal(await readFile(info(f.vendor), 'utf8'), 'accepted bytes');
  assert.deepEqual(await readFile(join(f.vendor, '.runtime-install.json')), vendorReceipt);
  assert.equal((await readdir(join(f.dir, 'weapp_container_ios/ios/vendor'))).some(name => name.startsWith('.WeappContainer-')), false);
});

test('a manifest changing between address selection and retrieval is rejected before writing', async t => {
  const f = await fixture(t), { manifest } = await pin(f, SDK_VERSION, 'pinned bytes');
  const paths = nativeArtifactPaths(join(f.dir, '.runtime'), manifest, { version: SDK_VERSION, platform: 'ios', arch: 'universal', abiVersion: 1 });
  await writeFile(f.lock, JSON.stringify({ ...manifest, artifacts: [{ ...manifest.artifacts[0], sha256: '1'.repeat(64) }] }));
  await assert.rejects(downloadRuntimeArtifact({ manifestPath: f.lock, platform: 'ios', arch: 'universal', component: 'ios-sdk', expectedArtifact: paths.pin,
    outDirectory: paths.outDirectory, installDirectory: paths.installDirectory, artifactDirectory: f.offline }), { code: 'ERR_RUNTIME_MANIFEST' });
  await assert.rejects(readFile(join(paths.outDirectory, paths.pin.fileName)), { code: 'ENOENT' });
});
