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
  await cp(path.join(here, '../distribution-identity.mjs'), path.join(helper, 'distribution-identity.mjs'));
  await mkdir(path.join(root, 'flutter/tools'), { recursive: true });
  await cp(path.join(here, '../../tools/runtime-artifacts.mjs'), path.join(root, 'flutter/tools/runtime-artifacts.mjs'));
  const headerBytes = await readFile(path.join(here, '../include/weapp_container_sdk.h'));
  await writeFile(path.join(native, 'include/weapp_container_sdk.h'), headerBytes);
  await writeFile(path.join(helper, 'include/weapp_container_sdk.h'), headerBytes);
  const bytes = Buffer.from('isolated archive fixture');
  await writeFile(path.join(native, 'lib/libweapp_container_sdk.a'), bytes);
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const wrapper = Buffer.from('isolated native device and preview wrapper fixture');
  const wrapperSha = createHash('sha256').update(wrapper).digest('hex');
  await writeFile(path.join(native, 'lib/libweapp_container_desktop.a'), wrapper);
  for (const file of ['weapp/desktop.hpp', 'weapp/device_apis.hpp', 'weapp/native_preview.hpp', 'weapp_container_sdk_gl.h']) {
    const source = await readFile(path.join(here, '../include', file));
    for (const directory of [native, helper]) {
      await mkdir(path.dirname(path.join(directory, 'include', file)), { recursive: true });
      await writeFile(path.join(directory, 'include', file), source);
    }
  }
  const receipt = {
    schemaVersion: 1, sdkVersion: desktopProducerVersion, platform: 'macos-universal',
    sourceCommit: 'a'.repeat(40), sourceDirty: false, status: 'verified',
    native: [{ schemaVersion: 1, abiVersion: 1, sdkVersion: desktopProducerVersion, platform: 'macos', target: 'aarch64-apple-darwin', sourceCommit: 'b'.repeat(40), sourceDirty: false, status: 'built' }],
    artifacts: [{ file: 'lib/libweapp_container_sdk.a', sha256 }, {file:'lib/libweapp_container_desktop.a',sha256:wrapperSha}],
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
  assert.equal(prepared.wrapperSha256,wrapperSha);
  assert.ok(prepared.wrapperHeaders['weapp/device_apis.hpp']);
  await run({...receipt,artifacts:receipt.artifacts.filter(value=>!value.file.includes('desktop.a'))},false);
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
  const linux = { ...receipt, platform: 'linux-x64',
    native: [{ ...receipt.native[0], platform: 'linux', target: 'x86_64-unknown-linux-gnu' }],
    artifacts: receipt.artifacts };
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
  await runLinux({ ...linux, artifacts: receipt.artifacts.filter(value=>!value.file.includes('desktop.a')) }, false);
  await writeFile(path.join(native, 'lib/libweapp_container_desktop.a'), 'tampered preview adapter');
  await runLinux(linux, false);
  assert.deepEqual(await readFile(path.join(linuxPlugin, 'lib/libweapp_container_desktop.a')), wrapper);
  await writeFile(path.join(native, 'lib/libweapp_container_desktop.a'), wrapper);
  await writeFile(path.join(native, 'include/weapp/native_preview.hpp'), 'unreviewed native adapter');
  await runLinux(linux, false);
  assert.equal(JSON.parse(await readFile(path.join(linuxPlugin, 'prepared.json'), 'utf8')).wrapperSha256, wrapperSha);
  await writeFile(path.join(native, 'include/weapp/native_preview.hpp'), await readFile(path.join(helper, 'include/weapp/native_preview.hpp')));
  // Windows core is consumed through its import interface and bundled DLL.
  // An import library cannot carry the runtime policy marker; validate the DLL.
  const importBytes = Buffer.from('isolated DLL import interface'), dllBytes = Buffer.from('isolated runtime DLL body');
  const importSha = createHash('sha256').update(importBytes).digest('hex'), dllSha = createHash('sha256').update(dllBytes).digest('hex');
  await mkdir(path.join(native, 'bin'));
  await writeFile(path.join(native, 'lib/weapp_container_sdk.dll.lib'), importBytes);
  await writeFile(path.join(native, 'bin/weapp_container_sdk.dll'), dllBytes);
  await writeFile(path.join(native, 'lib/weapp_container_desktop.lib'), wrapper);
  const windows = { ...receipt, platform: 'windows-x64',
    native: [{ ...receipt.native[0], platform: 'windows', target: 'x86_64-pc-windows-msvc' }],
    artifacts: [{ file: 'lib/weapp_container_sdk.dll.lib', sha256: importSha }, { file: 'bin/weapp_container_sdk.dll', sha256: dllSha }, { file: 'lib/weapp_container_desktop.lib', sha256: wrapperSha }] };
  const runWindows = async (value, success, restricted = false) => {
    await writeFile(path.join(native, 'package.json'), JSON.stringify(value));
    const args = [path.join(helper, 'prepare.mjs'), '--target', 'windows', '--from', native,
      ...(restricted ? ['--distribution-profile', 'restricted-showcase', '--showcase-policy-sha256', 'a'.repeat(64)] : [])];
    const result = spawnSync(process.execPath, args, { encoding: 'utf8' });
    assert.equal(result.status === 0, success, result.stderr);
  };
  await runWindows(windows, true);
  const windowsPlugin = path.join(root, 'flutter/weapp_container_windows/windows/vendor');
  const preparedWindows = JSON.parse(await readFile(path.join(windowsPlugin, 'prepared.json'), 'utf8'));
  assert.equal(preparedWindows.archive, 'weapp_container_sdk.dll.lib');
  assert.equal(preparedWindows.archiveSha256, importSha);
  assert.equal(preparedWindows.runtimeLibrary, 'weapp_container_sdk.dll');
  assert.equal(preparedWindows.runtimeSha256, dllSha);
  assert.deepEqual(await readFile(path.join(windowsPlugin, 'bin/weapp_container_sdk.dll')), dllBytes);
  await assert.rejects(readFile(path.join(windowsPlugin, 'lib/weapp_container_sdk.lib')), { code: 'ENOENT' });
  await runWindows({ ...windows, artifacts: windows.artifacts.filter(item => !item.file.endsWith('.dll')) }, false);
  await writeFile(path.join(native, 'bin/weapp_container_sdk.dll'), 'tampered runtime DLL');
  await runWindows(windows, false);
  assert.deepEqual(await readFile(path.join(windowsPlugin, 'bin/weapp_container_sdk.dll')), dllBytes);
  const marker = Buffer.from(`weapp-container-distribution:restricted-showcase:${'a'.repeat(64)}\0`);
  const restrictedDll = Buffer.concat([dllBytes, marker]);
  await writeFile(path.join(native, 'bin/weapp_container_sdk.dll'), restrictedDll);
  const restrictedWindows = { ...windows, distributionProfile: 'restricted-showcase', policySha256: 'a'.repeat(64),
    native: windows.native.map(item => ({ ...item, distributionProfile: 'restricted-showcase', policySha256: 'a'.repeat(64) })),
    artifacts: windows.artifacts.map(item => item.file.endsWith('.dll') ? { ...item, sha256: createHash('sha256').update(restrictedDll).digest('hex') } : item) };
  await runWindows(restrictedWindows, true, true);
  assert.deepEqual(await readFile(path.join(windowsPlugin, 'lib/weapp_container_sdk.dll.lib')), importBytes);
  console.log('PASS native preview wrapper/archive/header binding and rejected-input installation preservation');
  console.log('PASS Windows import-library and runtime DLL hash binding, restricted marker scope and bundle closure');
  console.log('PASS native v1 receipt/ABI provenance, optional exit status, integrity rejection, and clean restaging');
} finally {
  await rm(root, { recursive: true, force: true });
}
