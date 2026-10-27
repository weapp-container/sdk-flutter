#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, renameSync, writeFileSync } from 'node:fs';
import { resolve, dirname, join, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { verifyNativeInstallation } from './verify-native.mjs';
import { makeFixture } from '../example/shared/make-fixture.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const option = (name, fallback) => { const at = args.indexOf(name); return at < 0 ? fallback : args[at + 1]; };
const out = resolve(option('--out', join(root, '.build/distribution')));
const finalPackages = join(out, 'packages'), consumer = join(out, 'consumer');
let packages = finalPackages;
const flutter = option('--flutter', process.env.FLUTTER || 'flutter');
const androidNdkVersion = option('--android-ndk-version', '27.1.12297006');
if (!/^\d+\.\d+\.\d+$/.test(androidNdkVersion)) throw new Error('Invalid Android NDK version');
const androidCmakeVersion = option('--android-cmake-version', '3.22.1');
if (!/^\d+\.\d+\.\d+$/.test(androidCmakeVersion)) throw new Error('Invalid Android CMake version');
const targets = ['android', 'ios', 'macos', 'windows', 'linux'];
const selected = option('--platform');
if (selected && !targets.includes(selected)) throw new Error(`Unsupported platform ${selected}`);
if (selected) verifyNativeInstallation(join(root, '.runtime', selected), selected);
if (selected && args.includes('--portable-consumer')) throw new Error('--portable-consumer prepares sources only; omit --platform');
function run(command, argv, cwd = root) {
  console.log(`Running ${command} ${argv.join(' ')}`);
  const value = spawnSync(command, argv, { cwd, stdio: 'inherit' });
  if (value.error || value.status !== 0) throw new Error(`${command} failed: ${value.error?.message || value.status}`);
}
const versionResult = spawnSync(flutter, ['--version', '--machine'], { encoding: 'utf8' });
if (versionResult.error || versionResult.status !== 0) throw new Error(`Cannot verify Flutter toolchain: ${versionResult.stderr}`);
const flutterVersion = JSON.parse(versionResult.stdout);
if (flutterVersion.frameworkVersion !== '3.47.7' || flutterVersion.frameworkRevision !== 'abaf9c523780a608bd46686fd5e53740a07077f8' || flutterVersion.engineRevision !== 'deb287481e3ce9468f3434937ced4240a70539ca') {
  throw new Error('This preview requires pinned Flutter 3.47.7 stable (framework abaf9c523780a608bd46686fd5e53740a07077f8)');
}
const ignored = new Set(['.dart_tool', 'build', '.gradle', '.cxx', '.DS_Store', 'pubspec.lock', '.flutter-plugins-dependencies', 'vendor', 'native_shared', 'native']);
const hash = path => createHash('sha256').update(readFileSync(path)).digest('hex');
function provenance() {
  if (!existsSync(join(root, '.git'))) throw new Error('Package assembly requires this standalone repository to be committed; a parent repository is never used');
  const revision = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' });
  const dirty = spawnSync('git', ['status', '--porcelain'], { cwd: root, encoding: 'utf8' });
  if (revision.status || dirty.status) throw new Error('Unable to record source provenance');
  return { sourceCommit: revision.stdout.trim(), sourceDirty: Boolean(dirty.stdout.trim()) };
}
function receipt(path, status) {
  const value = JSON.parse(readFileSync(path, 'utf8'));
  if (value.status !== status || value.sdkVersion !== '0.1.0-preview.2') throw new Error(`Invalid SDK receipt ${path}`);
  if (value.native) {
    if (!value.native.length || value.native.some(r => r.status !== 'built' || r.sourceDirty !== false || !/^[a-f0-9]{40}$/.test(r.sourceCommit))) throw new Error(`Native SDK lacks clean committed provenance: ${path}`);
  } else if (value.sourceDirty !== false || !/^[a-f0-9]{40}$/.test(value.sourceCommit)) throw new Error(`SDK lacks clean committed provenance: ${path}`);
  return value;
}
function verifyFiles(directory, artifacts) {
  if (!Array.isArray(artifacts) || !artifacts.length) throw new Error('SDK receipt has no artifact digests');
  for (const entry of artifacts) {
    const file = resolve(directory, entry.file);
    if (!file.startsWith(resolve(directory) + sep) || !/^[a-f0-9]{64}$/.test(entry.sha256) || hash(file) !== entry.sha256) throw new Error(`SDK artifact digest mismatch: ${entry.file}`);
  }
}
function prepare(status, target, work) {
  try { status[target] = { status: 'packaged', ...work() }; }
  catch (error) {
    const plugin = join(packages, `weapp_container_${target}`);
    for (const relative of ['native', `${target}/vendor`, `${target}/native_shared`]) rmSync(join(plugin, relative), { recursive: true, force: true });
    status[target] = { status: 'blocked', reason: error.message };
  }
}
mkdirSync(out, { recursive: true });
if (!args.includes('--skip-packages')) {
  packages = join(out, `.packages-staging-${process.pid}`);
  rmSync(packages, { recursive: true, force: true }); mkdirSync(packages, { recursive: true });
  for (const name of ['weapp_container', 'weapp_container_platform_interface', ...targets.map(t => `weapp_container_${t}`), 'native_desktop']) {
    cpSync(join(root, name), join(packages, name), { recursive: true, filter: path => !ignored.has(path.split('/').at(-1)) });
  }
  const status = {};
  const maven = resolve(option('--android-maven', join(root, '.runtime/android/maven')));
  prepare(status, 'android', () => {
    verifyNativeInstallation(dirname(maven), 'android');
    const source = resolve(option('--android-receipt', join(dirname(maven), 'validation.json')));
    const value = receipt(source, 'passed'); verifyFiles(maven, value.mavenArtifacts);
    cpSync(maven, join(packages, 'weapp_container_android/native/maven'), { recursive: true });
    return { source, receiptSha256: hash(source), sourceCommit: value.sourceCommit, artifactCount: value.mavenArtifacts.length };
  });
  const ios = resolve(option('--ios-sdk', join(root, '.runtime/ios')));
  prepare(status, 'ios', () => {
    verifyNativeInstallation(ios, 'ios');
    const source = join(ios, 'build.json'); const value = receipt(source, 'built'); verifyFiles(ios, value.artifacts);
    cpSync(ios, join(packages, 'weapp_container_ios/ios/vendor/WeappContainer'), { recursive: true });
    return { source, receiptSha256: hash(source), sourceCommit: value.sourceCommit, artifactCount: value.artifacts.length };
  });
  for (const target of ['macos', 'windows', 'linux']) {
    const native = resolve(option(`--${target}-sdk`, join(root, '.runtime', target)));
    prepare(status, target, () => {
      verifyNativeInstallation(native, target);
      const source = join(native, 'package.json'); const value = receipt(source, 'verified'); verifyFiles(native, value.artifacts);
      run(process.execPath, [join(packages, 'native_desktop/prepare.mjs'), '--target', target, '--from', native]);
      return { source, receiptSha256: hash(source), nativeSourceCommits: value.native.map(r => r.sourceCommit), artifactCount: value.artifacts.length };
    });
  }
  // Every staging run starts without native inputs. Missing/invalid targets can
  // never inherit a previous vendor directory and masquerade as available.
  const previous = join(out, '.packages-previous'); rmSync(previous, { recursive: true, force: true });
  if (existsSync(finalPackages)) renameSync(finalPackages, previous);
  renameSync(packages, finalPackages); packages = finalPackages;
  rmSync(previous, { recursive: true, force: true });
  writeFileSync(join(out, 'distribution.json'), JSON.stringify({ schemaVersion: 1, version: '0.1.0-preview.2', ...provenance(), flutterToolchain: flutterVersion, packages, targets: status }, null, 2) + '\n');
}
if (!existsSync(join(consumer, 'pubspec.yaml'))) {
  run(flutter, ['create', '--no-pub', '--platforms=android,ios,macos,windows,linux', '--org', 'dev.weapp', '--project-name', 'weapp_sdk_consumer', consumer]);
}
cpSync(join(root, 'example/lib'), join(consumer, 'lib'), { recursive: true });
cpSync(join(root, 'example/README.md'), join(consumer, 'README.md'));
cpSync(join(root, 'example/analysis_options.yaml'), join(consumer, 'analysis_options.yaml'));
// flutter create's counter-app test does not describe this consumer.
const templateTest = join(consumer, 'test/widget_test.dart');
if (existsSync(templateTest) && readFileSync(templateTest, 'utf8').includes('Counter increments smoke test')) rmSync(templateTest);
if (existsSync(join(root, 'example/integration_test'))) cpSync(join(root, 'example/integration_test'), join(consumer, 'integration_test'), { recursive: true });
const yaml = readFileSync(join(root, 'example/pubspec.yaml'), 'utf8').replace('path: ../weapp_container', 'path: ../packages/weapp_container');
writeFileSync(join(consumer, 'pubspec.yaml'), yaml);
const fixture = join(consumer, 'assets/portable-pack');
if (existsSync(fixture)) rmSync(fixture, { recursive: true });
const integrity = makeFixture(root, fixture);
const files = [];
function scan(directory, prefix = '') { for (const item of readdirSync(directory, { withFileTypes: true })) { const name = `${prefix}${item.name}`; if (item.isDirectory()) scan(join(directory, item.name), `${name}/`); else files.push(name); } }
scan(fixture);
writeFileSync(join(consumer, 'assets/fixture-index.json'), JSON.stringify(files.sort()));
const androidGradle = join(consumer, 'android/app/build.gradle.kts');
if (existsSync(androidGradle)) {
  let content = readFileSync(androidGradle, 'utf8').replace('minSdk = flutter.minSdkVersion', 'minSdk = 26');
  content = content.replace(/ndkVersion = (?:flutter\.ndkVersion|"[0-9.]+")/, `ndkVersion = "${androidNdkVersion}"`);
  if (!content.includes('// weapp-sdk-supported-abis')) content = content.replace('minSdk = 26', 'minSdk = 26\n        // weapp-sdk-supported-abis\n        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }');
  writeFileSync(androidGradle, content);
}
const androidWrapper = join(consumer, 'android/gradle/wrapper/gradle-wrapper.properties');
const androidRootGradle = join(consumer, 'android/build.gradle.kts');
if (existsSync(androidRootGradle)) {
  // Plugins such as package:jni assign flutter.ndkVersion themselves. Select
  // the consumer's toolchain at DSL finalization, after their configuration.
  const marker = '// weapp-sdk-native-plugin-toolchain';
  const content = readFileSync(androidRootGradle, 'utf8').split(marker)[0].trimEnd();
  writeFileSync(androidRootGradle, `${content}\n\n${marker}\nsubprojects {\n    plugins.withId("com.android.library") {\n        extensions.configure<com.android.build.api.variant.LibraryAndroidComponentsExtension> {\n            finalizeDsl {\n                it.ndkVersion = "${androidNdkVersion}"\n                if (it.externalNativeBuild.cmake.path != null) {\n                    it.externalNativeBuild.cmake.version = "${androidCmakeVersion}"\n                }\n            }\n        }\n    }\n}\n`);
}
if (existsSync(androidWrapper)) {
  const properties = readFileSync(androidWrapper, 'utf8')
    .replace(/^distributionUrl=.*$/m, 'distributionUrl=https\\://services.gradle.org/distributions/gradle-9.4.1-bin.zip')
    .replace(/^distributionSha256Sum=.*\n?/m, '');
  writeFileSync(androidWrapper, properties.trimEnd() + '\ndistributionSha256Sum=2ab2958f2a1e51120c326cad6f385153bb11ee93b3c216c5fccebfdfbb7ec6cb\n');
}
const xcodeProject = join(consumer, 'ios/Runner.xcodeproj/project.pbxproj');
if (existsSync(xcodeProject)) writeFileSync(xcodeProject, readFileSync(xcodeProject, 'utf8').replace(/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/g, 'IPHONEOS_DEPLOYMENT_TARGET = 16.0;'));
const podfile = join(consumer, 'ios/Podfile');
if (existsSync(podfile)) writeFileSync(podfile, readFileSync(podfile, 'utf8').replace(/^#?\s*platform :ios, '[^']+'/m, "platform :ios, '16.0'"));
const macProject = join(consumer, 'macos/Runner.xcodeproj/project.pbxproj');
if (existsSync(macProject)) writeFileSync(macProject, readFileSync(macProject, 'utf8').replace(/MACOSX_DEPLOYMENT_TARGET = [0-9.]+;/g, 'MACOSX_DEPLOYMENT_TARGET = 12.0;'));
const macPodfile = join(consumer, 'macos/Podfile');
if (existsSync(macPodfile)) writeFileSync(macPodfile, readFileSync(macPodfile, 'utf8').replace(/^#?\s*platform :osx, '[^']+'/m, "platform :osx, '12.0'"));
run(flutter, ['pub', 'get'], consumer);
run(flutter, ['analyze', '--no-pub'], consumer);
writeFileSync(join(out, 'consumer.json'), JSON.stringify({ schemaVersion: 1, consumer, ...provenance(), fixtureIntegrity: integrity, bundleIdentifier: 'dev.weapp.weappSdkConsumer', reportFile: 'Application Support/sdk-flutter-report.json', targets: selected ? [selected] : [] }, null, 2) + '\n');
if (selected) {
  const distribution = JSON.parse(readFileSync(join(out, 'distribution.json'), 'utf8'));
  if (distribution.targets[selected]?.status !== 'packaged') throw new Error(`Build blocked: ${distribution.targets[selected]?.reason}`);
  const argv = selected === 'android' ? ['build', 'apk', '--debug', '--target-platform', 'android-arm64,android-x64'] : selected === 'ios' ? ['build', 'ios', '--simulator', '--no-codesign', '--debug'] : ['build', selected, '--debug'];
  if (args.includes('--verbose')) argv.push('--verbose');
  const buildReceipt = join(out, `build-${selected}.json`);
  const validation = { schemaVersion: 1, status: 'building', platform: selected, startedAt: new Date().toISOString(),
    distributionSha256: hash(join(out, 'distribution.json')), consumerSource: provenance(), fixtureIntegrity: integrity, flutterToolchain: flutterVersion };
  // Keep the exact input manifest when another platform is staged later.
  mkdirSync(join(out, 'manifests'), { recursive: true });
  validation.distributionSnapshot = join(out, 'manifests', `${validation.distributionSha256}.json`);
  cpSync(join(out, 'distribution.json'), validation.distributionSnapshot);
  if (selected === 'android') { validation.gradleWrapper = readFileSync(androidWrapper, 'utf8'); validation.androidNdkVersion = androidNdkVersion; validation.androidCmakeVersion = androidCmakeVersion; }
  writeFileSync(buildReceipt, JSON.stringify(validation, null, 2) + '\n');
  try {
    run(flutter, [...argv, '--no-pub'], consumer);
    const products = selected === 'android' ? [join(consumer, 'build/app/outputs/flutter-apk/app-debug.apk')]
      : selected === 'ios' ? [join(consumer, 'build/ios/iphonesimulator/Runner.app/Runner')]
      : selected === 'macos' ? [join(consumer, 'build/macos/Build/Products/Debug/weapp_sdk_consumer.app/Contents/MacOS/weapp_sdk_consumer')]
      : selected === 'windows' ? [join(consumer, `build/windows/${process.arch === 'arm64' ? 'arm64' : 'x64'}/runner/Debug/weapp_sdk_consumer.exe`)]
      : [join(consumer, `build/linux/${process.arch === 'arm64' ? 'arm64' : 'x64'}/debug/bundle/weapp_sdk_consumer`)];
    validation.status = 'built'; validation.artifacts = products.map(file => ({ file, sha256: hash(file) }));
  } catch (error) { validation.status = 'failed'; validation.error = error.message; throw error; }
  finally { validation.finishedAt = new Date().toISOString(); writeFileSync(buildReceipt, JSON.stringify(validation, null, 2) + '\n'); }
}
if (args.includes('--portable-consumer')) {
  const generatedDirectories = new Set(['.dart_tool', '.gradle', '.cxx', '.idea', 'build', 'ephemeral', 'Pods', '.symlinks', 'xcuserdata']);
  const generatedFiles = new Set(['local.properties', 'Generated.xcconfig', 'flutter_export_environment.sh', '.flutter-plugins-dependencies', '.flutter-plugins', '.DS_Store']);
  const removed = [];
  function clean(directory) {
    for (const item of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, item.name);
      if (generatedDirectories.has(item.name) || generatedFiles.has(item.name) || item.name.endsWith('.iml')) {
        rmSync(path, { recursive: true, force: true }); removed.push(path.slice(consumer.length + 1));
      } else if (item.isDirectory() && !item.isSymbolicLink()) clean(path);
    }
  }
  clean(consumer);
  writeFileSync(join(out, 'consumer-portability.json'), JSON.stringify({ schemaVersion: 1, status: 'prepared', ...provenance(), dependencyPath: '../packages/weapp_container', removed: removed.sort() }, null, 2) + '\n');
}
console.log(JSON.stringify({ out, packages, consumer, fixtureIntegrity: integrity, platform: selected ?? 'prepared' }, null, 2));
