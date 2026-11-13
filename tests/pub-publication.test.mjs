import test from 'node:test';
import assert from 'node:assert/strict';
import { publicationPackages } from '../tools/pub-publication.mjs';

const manifest = { sdkVersion: '0.1.0-preview.7.0', packages: ['weapp_container_platform_interface', 'weapp_container_android', 'weapp_container'] };
test('selects one unpublished package without replaying previously published packages', () => {
  assert.deepEqual(publicationPackages(manifest, 'weapp_container_android'), ['weapp_container_android']);
  assert.deepEqual(publicationPackages(manifest), manifest.packages);
  assert.throws(() => publicationPackages(manifest, '../other'), /Unknown staged package/);
});
test('OIDC publishing requires a package-specific tag with the staged version', () => {
  assert.deepEqual(publicationPackages(manifest, 'weapp_container_platform_interface', 'weapp_container_platform_interface-v0.1.0-preview.7.0'), ['weapp_container_platform_interface']);
  for (const tag of ['', 'main', 'weapp_container_android-v0.1.0-preview.7.0', 'weapp_container_platform_interface-v0.1.0-preview.6.0']) {
    assert.throws(() => publicationPackages(manifest, 'weapp_container_platform_interface', tag), /exact version tag/);
  }
  assert.throws(() => publicationPackages(manifest, undefined, 'weapp_container-v0.1.0-preview.7.0'), /selected package/);
});
