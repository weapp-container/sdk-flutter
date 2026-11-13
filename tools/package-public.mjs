import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cleanSource, filesUnder, readRelease, releaseUrl, run, sha256, versionOf } from './public-release.mjs';
import { verifySourceInventory } from './source-inventory.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2), option = name => { const i = args.indexOf(name); return i < 0 ? undefined : args[i + 1]; };
const version = versionOf(root), sourceCommit = cleanSource(root);
const reviewed = verifySourceInventory(root);
if (!option('--desktop-release')) throw Error('--desktop-release must select the verified three-platform Desktop manifest');
const desktop = readRelease(resolve(option('--desktop-release')), 'weapp-container/sdk-desktop', version);
if (['macos-universal', 'linux-x86_64', 'windows-x86_64'].some(platform => !desktop.assets.some(asset => asset.platform === platform && asset.component === 'desktop-sdk'))) throw Error('Complete public Desktop distribution is required');
const out = resolve(option('--out') ?? join(root, '.build/public'));
if (existsSync(out)) throw Error('Use a fresh public package output directory');
mkdirSync(out, { recursive: true });
const names = ['weapp_container_platform_interface', ...['android', 'ios', 'macos', 'linux', 'windows'].map(platform => `weapp_container_${platform}`), 'weapp_container'];
for (const name of names) {
  const destination = join(out, name);
  cpSync(join(root, name), destination, { recursive: true, filter: path => !['build', '.dart_tool', 'pubspec.lock', 'native', 'vendor', 'native_shared', '.gradle', '.cxx', 'Pods', 'test', 'tests'].includes(path.split('/').at(-1)) });
  const spec = readFileSync(join(destination, 'pubspec.yaml'), 'utf8');
  if (/^publish_to:|^\s+path:/m.test(spec) || !spec.includes(`version: ${version}`)) throw Error(`Unpublishable dependency closure in ${name}`);
}
for (const platform of ['macos', 'linux', 'windows']) {
  const destination = join(out, `weapp_container_${platform}`, platform);
  for (const directory of ['src', 'include', 'third_party']) cpSync(join(root, 'native_desktop', directory), join(destination, 'native_shared', directory), { recursive: true });
  if (platform !== 'macos') {
    const artifact = desktop.assets.find(entry => entry.platform === `${platform}-x86_64`);
    if (!artifact) throw Error(`Missing public Desktop archive for ${platform}`);
    const url = releaseUrl(desktop, artifact);
    // FetchContent verifies the archive before extraction. Fully disconnected builds can override its source directory.
    writeFileSync(join(destination, 'runtime.cmake'), `include(FetchContent)\nFetchContent_Declare(weapp_container_runtime URL "${url}" URL_HASH "SHA256=${artifact.sha256}")\nFetchContent_MakeAvailable(weapp_container_runtime)\nset(NATIVE_ROOT "\${weapp_container_runtime_SOURCE_DIR}")\n`);
  }
}
const fileInventory = Object.fromEntries(filesUnder(out).map(file => [file, sha256(readFileSync(join(out, file)))]));
if (cleanSource(root) !== sourceCommit) throw Error('Source changed during Flutter staging');
writeFileSync(join(out, 'distribution.json'), JSON.stringify({ schemaVersion: 1, sdkVersion: version, sourceCommit, sourceDirty: false, sourceInventorySha256: reviewed.inventorySha256, desktop, packages: names, files: fileInventory, published: false }, null, 2) + '\n');
console.log(`Staged ${names.length} packages at ${out}. Publish hosted dependencies in the recorded order.`);
