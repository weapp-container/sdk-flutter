import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { distributionIdentity, distributionOptions, assertDistributionIdentity } from '../tools/distribution-identity.mjs';
import { selectArtifact, downloadRuntimeArtifact, SDK_VERSION } from '../tools/runtime-artifacts.mjs';
const identity = { distributionProfile: 'restricted-showcase', policySha256: 'a'.repeat(64) };
const expected = { version: SDK_VERSION, abiVersion: 1, component: 'android-sdk', platform: 'android', arch: 'arm64-v8a' };
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
function manifest(artifact) { return { schemaVersion: 1, runtimeVersion: SDK_VERSION, abiVersion: 1, ...identity,
  source: { repository: 'weapp-container/runtime-artifacts', releaseTag: `runtime-v${SDK_VERSION}` }, artifacts: [artifact] }; }
test('distribution defaults to full and restricted policy selection is explicit', () => {
  assert.deepEqual(distributionIdentity(), { distributionProfile: 'full', policySha256: null });
  assert.deepEqual(distributionOptions(['--distribution-profile', identity.distributionProfile, '--showcase-policy-sha256', identity.policySha256]), identity);
  assert.throws(() => assertDistributionIdentity(identity), /mismatch/);
  for (const args of [['--distribution-profile','restricted-showcase'], ['--showcase-policy-sha256', identity.policySha256],
    ['--distribution-profile','other'], ['--distribution-profile','full','--distribution-profile','full'],
    ['--distribution-profile','restricted-showcase','--showcase-policy-sha256','x']]) assert.throws(() => distributionOptions(args));
});
test('a reviewed lock cannot be downgraded, rebound or silently selected as full', () => {
  const value = manifest({ component: 'android-sdk', platform: 'android', arch: 'arm64-v8a', fileName: 'runtime.tar.gz', size: 1, sha256: 'b'.repeat(64) });
  assert.throws(() => selectArtifact(value, expected), { code: 'ERR_RUNTIME_MANIFEST' });
  assert.throws(() => selectArtifact(value, { ...expected, ...identity, policySha256: 'b'.repeat(64) }), { code: 'ERR_RUNTIME_MANIFEST' });
  assert.equal(selectArtifact(value, { ...expected, ...identity }).policySha256, identity.policySha256);
  assert.throws(() => selectArtifact({ ...value, distributionProfile: 'full', policySha256: null }, { ...expected, ...identity }), { code: 'ERR_RUNTIME_MANIFEST' });
});
test('offline installation preserves the selected policy in exact archive receipts', async t => {
  const root = mkdtempSync(join(tmpdir(), 'weapp-restricted-sdk-')); t.after(() => rmSync(root, { recursive: true, force: true }));
  const archives = join(root, 'archives'); mkdirSync(archives); const archive = join(archives, 'runtime.tar.gz');
  const result = spawnSync('python3', ['-c', 'import io,tarfile,sys; t=tarfile.open(sys.argv[1],"w:gz"); b=b"pinned runtime"; i=tarfile.TarInfo("runtime.txt"); i.size=len(b); i.mode=420; t.addfile(i,io.BytesIO(b)); t.close()', archive], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr); const bytes = readFileSync(archive), path = join(root, 'lock.json');
  writeFileSync(path, JSON.stringify(manifest({ component: 'android-sdk', platform: 'android', arch: 'arm64-v8a', fileName: 'runtime.tar.gz', size: bytes.length, sha256: sha(bytes) })));
  const options = { manifestPath: path, ...expected, ...identity, artifactDirectory: archives, outDirectory: join(root, 'downloads'), installDirectory: join(root, 'install') };
  const installed = await downloadRuntimeArtifact(options);
  const { verifyNativeInstallation } = await import('../tools/verify-native.mjs');
  assert.throws(() => verifyNativeInstallation(options.installDirectory, 'android', path, archives), /mismatch/);
  assertDistributionIdentity(verifyNativeInstallation(options.installDirectory, 'android', path, archives, identity).identity, identity);
  assert.throws(() => verifyNativeInstallation(options.installDirectory, 'android', path, archives, { ...identity, policySha256: 'd'.repeat(64) }), /mismatch/);
  assertDistributionIdentity(installed.receipt, identity);
  assertDistributionIdentity(JSON.parse(readFileSync(join(root, 'install/.runtime-install.json'))).identity, identity);
  await assert.rejects(() => downloadRuntimeArtifact({ ...options, policySha256: 'c'.repeat(64) }), { code: 'ERR_RUNTIME_MANIFEST' });
});
