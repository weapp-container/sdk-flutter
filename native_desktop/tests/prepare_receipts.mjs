import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { SDK_VERSION } from '../../tools/runtime-artifacts.mjs';
// The current wrapper requires a newly produced desktop/native SDK of the same release.
const desktopProducerVersion = SDK_VERSION;

const here = path.dirname(fileURLToPath(import.meta.url));
const root = await mkdtemp(path.join(tmpdir(), 'weapp-flutter-receipt-'));
try {
  const helper = path.join(root, 'flutter/native_desktop');
  const native = path.join(root, 'installed');
  const plugin = path.join(root, 'flutter/weapp_container_macos/macos');
  for (const name of ['include', 'src', 'third_party']) await mkdir(path.join(helper, name), { recursive: true });
  await mkdir(path.join(native, 'include'), { recursive: true });
  await mkdir(path.join(native, 'lib'), { recursive: true });
  await cp(path.join(here, '../prepare.mjs'), path.join(helper, 'prepare.mjs'));
  await mkdir(path.join(root, 'flutter/tools'), { recursive: true });
  await cp(path.join(here, '../../tools/runtime-artifacts.mjs'), path.join(root, 'flutter/tools/runtime-artifacts.mjs'));
  const headerBytes = await readFile(path.join(here, '../include/weapp_container_sdk.h'));
  await writeFile(path.join(native, 'include/weapp_container_sdk.h'), headerBytes);
  await writeFile(path.join(helper, 'include/weapp_container_sdk.h'), headerBytes);
  const bytes = Buffer.from('isolated archive fixture');
  await writeFile(path.join(native, 'lib/libweapp_container_sdk.a'), bytes);
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const receipt = {
    schemaVersion: 1, sdkVersion: desktopProducerVersion, platform: 'macos-universal',
    sourceCommit: 'a'.repeat(40), sourceDirty: false, status: 'verified',
    native: [{ schemaVersion: 1, abiVersion: 1, sdkVersion: desktopProducerVersion, platform: 'macos', target: 'aarch64-apple-darwin', sourceCommit: 'b'.repeat(40), sourceDirty: false, status: 'built' }],
    artifacts: [{ file: 'lib/libweapp_container_sdk.a', sha256 }],
  };
  const run = async (value, success) => {
    await writeFile(path.join(native, 'package.json'), JSON.stringify(value));
    const result = spawnSync(process.execPath, [path.join(helper, 'prepare.mjs'), '--target', 'macos', '--from', native], { encoding: 'utf8' });
    assert.equal(result.status === 0, success, result.stderr);
  };
  await run(receipt, true);
  assert.equal(SDK_VERSION, desktopProducerVersion);
  for (const oldVersion of ['0.1.0-preview.5.1', '0.1.0-preview.5.2', '0.1.0-preview.5.3']) {
    await run({ ...receipt, sdkVersion: oldVersion }, false);
    await run({ ...receipt, native: [{ ...receipt.native[0], sdkVersion: oldVersion }] }, false);
  }
  const prepared = JSON.parse(await readFile(path.join(plugin, 'vendor/prepared.json'), 'utf8'));
  assert.equal(prepared.archiveSha256, sha256);
  assert.deepEqual(prepared.packageReceipt, receipt);
  for (const part of ['vendor', 'native_shared']) await writeFile(path.join(plugin, part, 'stale'), 'old');
  await run(receipt, true);
  for (const part of ['vendor', 'native_shared']) await assert.rejects(readFile(path.join(plugin, part, 'stale')), { code: 'ENOENT' });
  await run({ ...receipt, sourceDirty: true }, false);
  await run({ ...receipt, status: 'failed' }, false);
  await run({ ...receipt, sdkVersion: '0.1.0-dev.1' }, false);
  await run({ ...receipt, native: [{ ...receipt.native[0], sourceDirty: true }] }, false);
  await run({ ...receipt, native: [{ ...receipt.native[0], platform: 'linux' }] }, false);
  await run({ ...receipt, native: [{ ...receipt.native[0], schemaVersion: undefined }] }, false);
  await run({ ...receipt, native: [{ ...receipt.native[0], abiVersion: 2 }] }, false);
  await run({ ...receipt, native: [{ ...receipt.native[0], exitCode: 1 }] }, false);
  await run({ ...receipt, native: [{ ...receipt.native[0], exitCode: 0 }] }, true);
  await writeFile(path.join(native, 'include/weapp_container_sdk.h'), 'unreviewed ABI');
  await run(receipt, false);
  await writeFile(path.join(native, 'include/weapp_container_sdk.h'), headerBytes);
  await writeFile(path.join(native, 'lib/libweapp_container_sdk.a'), 'corrupted archive');
  await run(receipt, false);
  assert.equal(JSON.parse(await readFile(path.join(plugin, 'vendor/prepared.json'), 'utf8')).archiveSha256, sha256);
  // GPU preview preparation binds the separate desktop adapter archive and
  // reviewed native-only headers before replacing any previous installation.
  await writeFile(path.join(native, 'lib/libweapp_container_sdk.a'), bytes);
  const wrapper = Buffer.from('isolated native preview wrapper fixture');
  const wrapperSha = createHash('sha256').update(wrapper).digest('hex');
  await writeFile(path.join(native, 'lib/libweapp_container_desktop.a'), wrapper);
  for (const file of ['weapp/desktop.hpp', 'weapp/native_preview.hpp', 'weapp_container_sdk_gl.h']) {
    const source = await readFile(path.join(here, '../include', file));
    for (const directory of [native, helper]) {
      await mkdir(path.dirname(path.join(directory, 'include', file)), { recursive: true });
      await writeFile(path.join(directory, 'include', file), source);
    }
  }
  const linux = { ...receipt, platform: 'linux-x64',
    native: [{ ...receipt.native[0], platform: 'linux', target: 'x86_64-unknown-linux-gnu' }],
    artifacts: [...receipt.artifacts, { file: 'lib/libweapp_container_desktop.a', sha256: wrapperSha }] };
  const runLinux = async (value, success) => {
    await writeFile(path.join(native, 'package.json'), JSON.stringify(value));
    const result = spawnSync(process.execPath, [path.join(helper, 'prepare.mjs'), '--target', 'linux', '--from', native], { encoding: 'utf8' });
    assert.equal(result.status === 0, success, result.stderr);
  };
  await runLinux(linux, true);
  const linuxPlugin = path.join(root, 'flutter/weapp_container_linux/linux/vendor');
  const preparedLinux = JSON.parse(await readFile(path.join(linuxPlugin, 'prepared.json'), 'utf8'));
  assert.equal(preparedLinux.wrapperSha256, wrapperSha);
  assert.equal(preparedLinux.wrapperArchive, 'libweapp_container_desktop.a');
  assert.deepEqual(await readFile(path.join(linuxPlugin, 'lib/libweapp_container_desktop.a')), wrapper);
  await runLinux({ ...linux, artifacts: receipt.artifacts }, false);
  await writeFile(path.join(native, 'lib/libweapp_container_desktop.a'), 'tampered preview adapter');
  await runLinux(linux, false);
  assert.deepEqual(await readFile(path.join(linuxPlugin, 'lib/libweapp_container_desktop.a')), wrapper);
  await writeFile(path.join(native, 'lib/libweapp_container_desktop.a'), wrapper);
  await writeFile(path.join(native, 'include/weapp/native_preview.hpp'), 'unreviewed native adapter');
  await runLinux(linux, false);
  assert.equal(JSON.parse(await readFile(path.join(linuxPlugin, 'prepared.json'), 'utf8')).wrapperSha256, wrapperSha);
  console.log('PASS native preview wrapper/archive/header binding and rejected-input installation preservation');
  console.log('PASS native v1 receipt/ABI provenance, optional exit status, integrity rejection, and clean restaging');
} finally {
  await rm(root, { recursive: true, force: true });
}
