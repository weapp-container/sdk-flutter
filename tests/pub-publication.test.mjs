import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { publicationPackages } from '../tools/pub-publication.mjs';

const packageWorkflow = readFileSync(new URL('../.github/workflows/package-pub.yml', import.meta.url), 'utf8');
const publishWorkflow = readFileSync(new URL('../.github/workflows/publish-pub-interface.yml', import.meta.url), 'utf8');

const manifest = {
  sdkVersion: '0.1.0-preview.7.1',
  packages: [
    'weapp_container_platform_interface', 'weapp_container_android',
    'weapp_container_ios', 'weapp_container_macos', 'weapp_container_linux',
    'weapp_container_windows', 'weapp_container',
  ],
};
test('selects one unpublished package without replaying previously published packages', () => {
  assert.deepEqual(publicationPackages(manifest, 'weapp_container_android'), ['weapp_container_android']);
  assert.deepEqual(publicationPackages(manifest), manifest.packages);
  assert.throws(() => publicationPackages(manifest, '../other'), /Unknown staged package/);
});
test('OIDC publishing requires a package-specific tag with the staged version', () => {
  assert.deepEqual(publicationPackages(manifest, 'weapp_container_platform_interface', 'weapp_container_platform_interface-v0.1.0-preview.7.1'), ['weapp_container_platform_interface']);
  for (const tag of ['', 'main', 'weapp_container_android-v0.1.0-preview.7.1', 'weapp_container_platform_interface-v0.1.0-preview.6.0']) {
    assert.throws(() => publicationPackages(manifest, 'weapp_container_platform_interface', tag), /exact version tag/);
  }
  assert.throws(() => publicationPackages(manifest, undefined, 'weapp_container-v0.1.0-preview.7.1'), /selected package/);
});

test('pub packages are staged and published outside checkout gitignored paths', () => {
  assert.match(packageWorkflow, /--out "\$RUNNER_TEMP\/public-flutter-staging"/);
  assert.match(packageWorkflow, /path: \$\{\{ runner\.temp \}\}\/public-flutter-staging\//);
  assert.match(publishWorkflow, /path: \$\{\{ runner\.temp \}\}\/verified-public/);
  assert.match(publishWorkflow, /--distribution "\$RUNNER_TEMP\/verified-public"/);
  assert.doesNotMatch(packageWorkflow + publishWorkflow, /\.build\/(?:public|verified-public)(?:\/|\b)/);
});
