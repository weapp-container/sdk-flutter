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
  const cmakeRoot = 'lib/cmake/WeappContainerDesktop';
  const cmake = new Map([
    ['WeappContainerDesktopConfig.cmake', `get_filename_component(PACKAGE_PREFIX_DIR "\${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
if(NOT TARGET WeappContainer::Core)
add_library(WeappContainer::Core SHARED IMPORTED)
set_target_properties(WeappContainer::Core PROPERTIES IMPORTED_IMPLIB "\${PACKAGE_PREFIX_DIR}/lib/weapp_container_sdk.dll.lib" IMPORTED_LOCATION "\${PACKAGE_PREFIX_DIR}/bin/weapp_container_sdk.dll" INTERFACE_COMPILE_DEFINITIONS WEAPP_CONTAINER_SDK_SHARED)
endif()
include("\${CMAKE_CURRENT_LIST_DIR}/WeappContainerDesktopTargets.cmake")
`],
    ['WeappContainerDesktopConfigVersion.cmake', `set(PACKAGE_VERSION "${SDK_VERSION}")\n`],
    ['WeappContainerDesktopTargets.cmake', `if(NOT TARGET WeappContainer::Desktop)
add_library(WeappContainer::Desktop STATIC IMPORTED)
set_target_properties(WeappContainer::Desktop PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "\${PACKAGE_PREFIX_DIR}/include" INTERFACE_LINK_LIBRARIES "WeappContainer::Core;wlanapi;iphlpapi;windowsapp;runtimeobject;comctl32")
endif()
include("\${CMAKE_CURRENT_LIST_DIR}/WeappContainerDesktopTargets-release.cmake")
`],
    ['WeappContainerDesktopTargets-release.cmake', 'set_target_properties(WeappContainer::Desktop PROPERTIES IMPORTED_LOCATION "${PACKAGE_PREFIX_DIR}/lib/weapp_container_desktop.lib")\n'],
  ]);
  await mkdir(path.join(native, cmakeRoot), { recursive: true });
  for (const [file, text] of cmake) await writeFile(path.join(native, cmakeRoot, file), text);
  const cmakeInventory = [...cmake].map(([file, text]) => ({ path: `${cmakeRoot}/${file}`, size: Buffer.byteLength(text), sha256: createHash('sha256').update(text).digest('hex'), executable: false }));
  const runWindows = async (value, success, restricted = false, changeInstallation = value => value) => {
    await writeFile(path.join(native, 'package.json'), JSON.stringify(value));
    const packageBytes = await readFile(path.join(native, 'package.json'));
    const installation = changeInstallation({ schemaVersion: 1, archiveSha256: 'c'.repeat(64),
      identity: { runtimeVersion: SDK_VERSION, abiVersion: 1, component: 'desktop-sdk', platform: 'windows', arch: 'x86_64',
        ...(restricted ? { distributionProfile: 'restricted-showcase', policySha256: 'a'.repeat(64) } : {}) },
      files: [...cmakeInventory, { path: 'package.json', size: packageBytes.length, sha256: createHash('sha256').update(packageBytes).digest('hex'), executable: false }] });
    if (installation) await writeFile(path.join(native, '.runtime-install.json'), JSON.stringify(installation));
    else await rm(path.join(native, '.runtime-install.json'), { force: true });
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
  assert.equal(preparedWindows.nativeInstallationArchiveSha256, 'c'.repeat(64));
  assert.deepEqual(preparedWindows.cmakeFileHashes, Object.fromEntries(cmakeInventory.map(file => [file.path, file.sha256])));
  for (const [file, text] of cmake) assert.equal(await readFile(path.join(windowsPlugin, cmakeRoot, file), 'utf8'), text);
  assert.deepEqual(await readFile(path.join(windowsPlugin, 'bin/weapp_container_sdk.dll')), dllBytes);
  await assert.rejects(readFile(path.join(windowsPlugin, 'lib/weapp_container_sdk.lib')), { code: 'ENOENT' });
  // Metadata is executable CMake input. Reject missing, modified, additional,
  // incomplete or mismatched installation input before replacing old vendor.
  await runWindows(windows, false, false, () => null);
  await runWindows(windows, false, false, value => ({ ...value, identity: { ...value.identity, platform: 'linux' } }));
  await runWindows(windows, false, false, value => ({ ...value, files: value.files.filter(file => file.path !== 'package.json') }));
  await runWindows(windows, false, false, value => ({ ...value, files: value.files.filter(file => !file.path.endsWith('Targets-release.cmake')) }));
  const targetsPath = path.join(native, cmakeRoot, 'WeappContainerDesktopTargets.cmake');
  await writeFile(targetsPath, 'message(FATAL_ERROR "unreviewed metadata")');
  await runWindows(windows, false);
  await writeFile(targetsPath, cmake.get('WeappContainerDesktopTargets.cmake'));
  const extraPath = path.join(native, cmakeRoot, 'WeappContainerDesktopTargets-debug.cmake');
  await writeFile(extraPath, 'message(FATAL_ERROR "unreviewed configuration")');
  await runWindows(windows, false);
  await rm(extraPath);
  const releasePath = path.join(native, cmakeRoot, 'WeappContainerDesktopTargets-release.cmake');
  await rm(releasePath);
  await runWindows(windows, false);
  await writeFile(releasePath, cmake.get('WeappContainerDesktopTargets-release.cmake'));
  assert.deepEqual(JSON.parse(await readFile(path.join(windowsPlugin, 'prepared.json'), 'utf8')), preparedWindows);
  // Configure the actual plugin against the installed export. This exercises
  // CMake target propagation without linking fixture libraries or using Rust.
  const windowsPackage = path.dirname(windowsPlugin);
  await cp(path.join(here, '../../weapp_container_windows/windows/CMakeLists.txt'), path.join(windowsPackage, 'CMakeLists.txt'));
  await writeFile(path.join(windowsPackage, 'weapp_container_windows_plugin.cpp'), 'void plugin_fixture() {}\n');
  await mkdir(path.join(windowsPackage, 'include'), { recursive: true });
  await writeFile(path.join(windowsPackage, 'native_shared/src/registry.cpp'), 'void registry_fixture() {}\n');
  const cmakeConsumer = path.join(root, 'cmake-consumer');
  await mkdir(cmakeConsumer);
  await writeFile(path.join(cmakeConsumer, 'CMakeLists.txt'), `cmake_minimum_required(VERSION 3.14)
project(FlutterExportContract LANGUAGES CXX)
add_library(flutter INTERFACE)
add_library(flutter_wrapper_plugin INTERFACE)
function(apply_standard_settings target)
endfunction()
find_package(WeappContainerDesktop CONFIG REQUIRED PATHS "${path.join(windowsPlugin, 'lib/cmake/WeappContainerDesktop').replaceAll('\\', '/')}" NO_DEFAULT_PATH)
add_subdirectory("${windowsPackage.replaceAll('\\', '/')}" plugin)
get_target_property(dependencies WeappContainer::Desktop INTERFACE_LINK_LIBRARIES)
foreach(dependency WeappContainer::Core wlanapi iphlpapi windowsapp runtimeobject comctl32)
  if(NOT dependency IN_LIST dependencies)
    message(FATAL_ERROR "Missing desktop transitive dependency: \${dependency}")
  endif()
endforeach()
get_target_property(plugin_links weapp_container_windows_plugin LINK_LIBRARIES)
if(NOT plugin_links STREQUAL "flutter;flutter_wrapper_plugin;WeappContainer::Desktop")
  message(FATAL_ERROR "Plugin must consume the desktop target: \${plugin_links}")
endif()
get_target_property(core_type WeappContainer::Core TYPE)
get_target_property(core_import WeappContainer::Core IMPORTED_IMPLIB)
get_target_property(core_dll WeappContainer::Core IMPORTED_LOCATION)
get_target_property(core_definitions WeappContainer::Core INTERFACE_COMPILE_DEFINITIONS)
if(NOT core_type STREQUAL "SHARED_LIBRARY" OR NOT core_import MATCHES "weapp_container_sdk.dll.lib$" OR NOT core_dll MATCHES "weapp_container_sdk.dll$" OR NOT core_definitions STREQUAL "WEAPP_CONTAINER_SDK_SHARED")
  message(FATAL_ERROR "Core must preserve the shared DLL/import-library ABI")
endif()
if(NOT weapp_container_windows_bundled_libraries STREQUAL core_dll)
  message(FATAL_ERROR "Plugin must bundle the imported runtime DLL")
endif()
`);
  const configured = spawnSync('cmake', ['-S', cmakeConsumer, '-B', path.join(root, 'cmake-build')], { encoding: 'utf8' });
  assert.equal(configured.status, 0, `${configured.stdout}\n${configured.stderr}`);
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
  console.log('PASS verified CMake metadata closure, installation preservation and exported Windows target dependencies');
  console.log('PASS native v1 receipt/ABI provenance, optional exit status, integrity rejection, and clean restaging');
} finally {
  await rm(root, { recursive: true, force: true });
}
