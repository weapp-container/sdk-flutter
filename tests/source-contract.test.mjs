import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { lstat, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve, extname, isAbsolute, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { downloadRuntimeArtifact, selectArtifact } from '../tools/runtime-artifacts.mjs';
import { makeFixture } from '../example/shared/make-fixture.mjs';
import { verifyNativeInstallation } from '../tools/verify-native.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const json = async file => JSON.parse(await readFile(join(root, file), 'utf8'));
let inventory;
async function sourceFiles() {
  if (inventory) return inventory;
  inventory = (async () => {
    const checkout = spawnSync('git', ['rev-parse', '--show-toplevel'], { cwd: root, encoding: 'utf8' });
    assert.equal(checkout.status, 0, 'Source checks require the standalone Git checkout');
    assert.equal(await realpath(checkout.stdout.trim()), await realpath(root), 'A parent checkout cannot supply source provenance');
    const tracked = spawnSync('git', ['ls-files', '--cached', '-z'], { cwd: root, encoding: 'utf8' });
    assert.equal(tracked.status, 0, tracked.stderr);
    const untracked = spawnSync('git', ['ls-files', '--others', '--exclude-standard', '-z'], { cwd: root, encoding: 'utf8' });
    assert.equal(untracked.status, 0, untracked.stderr);
    assert.deepEqual(untracked.stdout.split('\0').filter(Boolean), [], 'Untracked source must be reviewed before it enters the export');
    const files = tracked.stdout.split('\0').filter(Boolean).sort();
    const origin = await json('ORIGIN.json');
    const entries = [...origin.files.map(entry => ({ path: entry.path, sha256: entry.exportedSha256 })), ...origin.generatedFiles];
    assert.equal(new Set(entries.map(entry => entry.path)).size, entries.length, 'Duplicate ORIGIN source paths');
    assert.deepEqual(files, ['ORIGIN.json', ...entries.map(entry => entry.path)].sort(), 'Tracked source must exactly match the reviewed ORIGIN allowlist');
    const checkoutRoot = `${await realpath(root)}${sep}`;
    for (const file of files) {
      assert.equal(isAbsolute(file) || file.split('/').includes('..'), false, file);
      const absolute = join(root, file), status = await lstat(absolute);
      assert.equal(status.isSymbolicLink(), false, file);
      assert.equal(status.isFile(), true, file);
      assert.ok((await realpath(absolute)).startsWith(checkoutRoot), file);
    }
    for (const entry of entries) assert.equal(createHash('sha256').update(await readFile(join(root, entry.path))).digest('hex'), entry.sha256, entry.path);
    return files;
  })();
  return inventory;
}
test('artifact lock is explicit and cannot fabricate a release', async () => {
  const lock = await json('runtime-artifacts.lock.json');
  assert.equal(lock.runtimeVersion, '0.1.0-preview.2');
  assert.equal(lock.abiVersion, 1);
  assert.equal(lock.source.repository, 'weapp-container/runtime-artifacts');
  assert.equal(lock.source.releaseTag, 'runtime-v0.1.0-preview.2');
  if (lock.artifacts.length === 0) assert.throws(() => selectArtifact(lock, { version: lock.runtimeVersion, platform: 'android', arch: 'universal', component: 'android-sdk' }), { code: 'ERR_RUNTIME_MANIFEST' });
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
    await writeFile(manifestPath, JSON.stringify({ schemaVersion: 1, runtimeVersion: '0.1.0-preview.2', abiVersion: 1, source: {repository: 'weapp-container/runtime-artifacts', releaseTag: 'runtime-v0.1.0-preview.2'}, artifacts: [{component: 'android-sdk', platform: 'android', arch: 'universal', architectures: ['arm64-v8a', 'x86_64'], fileName: 'android.tar.gz', size: bytes.length, sha256}] }));
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
    assert.match(text, /^version: 0\.1\.0-preview\.2$/m);
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
