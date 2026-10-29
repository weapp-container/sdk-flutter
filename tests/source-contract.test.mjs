import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve, extname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { downloadRuntimeArtifact, selectArtifact, SDK_VERSION } from '../tools/runtime-artifacts.mjs';
import { makeFixture } from '../example/shared/make-fixture.mjs';
import { verifyNativeInstallation } from '../tools/verify-native.mjs';
import { verifySourceInventory } from '../tools/source-inventory.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const json = async file => JSON.parse(await readFile(join(root, file), 'utf8'));
let inventory;
async function sourceFiles() {
  inventory ??= verifySourceInventory(root).files;
  return inventory;
}
test('artifact lock matches the reviewed preview.5.2 archive coordinates', async () => {
  assert.equal(createHash('sha256').update(await readFile(join(root, 'runtime-artifacts.lock.json'))).digest('hex'), '10cf2f084601c9d0e2f06c54dcce4810527035beeee760f075b414651c67d829');
  const lock = await json('runtime-artifacts.lock.json');
  assert.equal(lock.runtimeVersion, '0.1.0-preview.5.2');
  assert.equal(lock.artifacts.length, 10);
  assert.equal(lock.abiVersion, 1);
  assert.equal(lock.source.repository, 'weapp-container/runtime-artifacts');
  assert.equal(lock.source.releaseTag, 'runtime-v0.1.0-preview.5.2');
  if (lock.artifacts.length === 0) assert.throws(() => selectArtifact(lock, { version: lock.runtimeVersion, platform: 'android', arch: 'universal', component: 'android-sdk' }), { code: 'ERR_RUNTIME_MANIFEST' });
  for (const entry of lock.artifacts) assert.equal(selectArtifact(lock, { version: lock.runtimeVersion, abiVersion: lock.abiVersion, platform: entry.platform, arch: entry.arch, component: entry.component }).sha256, entry.sha256);
});
test('source export contains no core sources, binaries, links or build caches', async () => {
  const files = await sourceFiles();
  assert.ok(files.length > 20);
  for (const file of files) {
    assert.doesNotMatch(file, /(?:^|\/)(?:crates|target|\.gradle|\.cxx|Pods|\.symlinks)(?:\/|$)/, file);
    assert.doesNotMatch(file, /\.(?:rs|aar|a|so|dylib|dll|exe|wasm|tgz|tar\.gz|class|pyc)$/i, file);
    assert.notEqual(file, 'Cargo.toml');
  }
  assert.match(await readFile(join(root, 'LICENSE'), 'utf8'), /Apache License/);
});
test('all ESM source files parse and local static imports remain within the checkout', async () => {
  for (const file of (await sourceFiles()).filter(file => extname(file) === '.mjs')) {
    const result = spawnSync(process.execPath, ['--check', join(root, file)], { encoding: 'utf8' });
    assert.equal(result.status, 0, `${file}: ${result.stderr}`);
    const text = await readFile(join(root, file), 'utf8');
    assert.doesNotMatch(text, /\/Users\/icebreaker|(?:\.\.\/)+(?:crates|sdk|examples)\//, file);
    for (const match of text.matchAll(/(?:from\s*|import\s*)['"](\.[^'"]+)['"]/g)) {
      const target = resolve(dirname(join(root, file)), match[1]);
      assert.ok(target.startsWith(`${root}${sep}`), `${file}: ${match[1]}`);
      await readFile(target);
    }
  }
});
test('native preparation fails explicitly without a selected target', () => {
  const result = spawnSync(process.execPath, [join(root, 'tools/prepare-native.mjs')], { encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Usage:/);
});
test('native package verification rejects modified installed bytes', async () => {
  const temp = await mkdtemp(join(tmpdir(), 'sdk-source-install-'));
  try {
    const archive = join(temp, 'android.tar.gz'), cache = join(temp, 'cache'), installed = join(temp, 'installed');
    const result = spawnSync(process.env.PYTHON ?? 'python3', ['-c', "import io,tarfile,sys; t=tarfile.open(sys.argv[1],'w:gz'); b=b'pinned native SDK fixture'; i=tarfile.TarInfo('native.txt'); i.size=len(b); i.mode=420; t.addfile(i,io.BytesIO(b)); t.close()", archive], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    const bytes = await readFile(archive), sha256 = createHash('sha256').update(bytes).digest('hex');
    const manifestPath = join(temp, 'lock.json');
    await writeFile(manifestPath, JSON.stringify({ schemaVersion: 1, runtimeVersion: SDK_VERSION, abiVersion: 1, source: {repository: 'weapp-container/runtime-artifacts', releaseTag: `runtime-v${SDK_VERSION}`}, artifacts: [{component: 'android-sdk', platform: 'android', arch: 'universal', architectures: ['arm64-v8a', 'x86_64'], fileName: 'android.tar.gz', size: bytes.length, sha256}] }));
    await downloadRuntimeArtifact({ manifestPath, platform: 'android', arch: 'universal', component: 'android-sdk', outDirectory: cache, installDirectory: installed, artifactDirectory: temp });
    assert.equal(verifyNativeInstallation(installed, 'android', manifestPath, cache).archiveSha256, sha256);
    await writeFile(join(installed, 'native.txt'), 'changed');
    assert.throws(() => verifyNativeInstallation(installed, 'android', manifestPath, cache), /changed/);
    const receiptPath = join(installed, '.runtime-install.json'), receipt = JSON.parse(await readFile(receiptPath, 'utf8'));
    receipt.files[0].size = 7; receipt.files[0].sha256 = createHash('sha256').update('changed').digest('hex');
    await writeFile(receiptPath, JSON.stringify(receipt));
    assert.throws(() => verifyNativeInstallation(installed, 'android', manifestPath, cache), /Command failed/);
  } finally { await rm(temp, { recursive: true, force: true }); }
});
test('all seven federated packages preserve their version and local dependency closure', async () => {
  const packages = ['weapp_container', 'weapp_container_platform_interface', ...['android', 'ios', 'macos', 'windows', 'linux'].map(platform => `weapp_container_${platform}`)];
  for (const name of packages) {
    const text = await readFile(join(root, name, 'pubspec.yaml'), 'utf8');
    assert.match(text, new RegExp(`^name: ${name}$`, 'm'));
    assert.equal(text.match(/^version: (.+)$/m)?.[1], SDK_VERSION);
    for (const match of text.matchAll(/path:\s*(\.\.[^\s]*)/g)) await readFile(resolve(root, name, match[1], 'pubspec.yaml'));
  }
  assert.doesNotMatch(await readFile(join(root, '.gitignore'), 'utf8'), /^\/?lib\/$/m);
  assert.match(await readFile(join(root, 'weapp_container_android/android/build.gradle'), 'utf8'), /Missing pinned Android SDK/);
  assert.match(await readFile(join(root, 'weapp_container_ios/ios/weapp_container_ios.podspec'), 'utf8'), /Missing pinned iOS SDK/);
});
test('authored fixture is deterministic and contains content-addressed modules and templates', async () => {
  const temp = await mkdtemp(join(tmpdir(), 'sdk-fixture-'));
  const canonical = value => Array.isArray(value) ? `[${value.map(canonical).join(',')}]` : value !== null && typeof value === 'object' ? `{${Object.keys(value).sort((a,b) => Buffer.compare(Buffer.from(a),Buffer.from(b))).map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}` : JSON.stringify(value);
  const sha = value => createHash('sha256').update(value).digest('hex');
  try {
    const first = makeFixture(undefined, join(temp, 'a')), second = makeFixture(undefined, join(temp, 'b'));
    assert.equal(first, second);
    const manifest = JSON.parse(await readFile(join(temp, 'a/manifest.json'), 'utf8'));
    assert.match(manifest.compiler.commit, /handwritten/);
    manifest.integrity.root = ''; assert.equal(sha(canonical(manifest)), first);
    for (const hash of [...manifest.modules.map(module => module.sha256), ...manifest.templates.map(template => template.wxmlAst.slice(7)), ...manifest.styles.map(style => style.wxssIr.slice(7))]) assert.equal(sha(await readFile(join(temp, 'a/blobs/sha256', hash))), hash);
    assert.equal(manifest.routes.length, 2);
  } finally { await rm(temp, { recursive: true, force: true }); }
});
