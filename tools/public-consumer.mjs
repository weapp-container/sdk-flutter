import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { versionOf } from './public-release.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const platform = process.argv[2], version = versionOf(root);
if (!['android', 'ios', 'macos', 'linux', 'windows'].includes(platform)) throw Error('Select a public Flutter target');
const out = resolve(root, '.build/public-consumer', platform), app = resolve(out, 'app'), evidence = resolve(out, 'evidence');
if (existsSync(out)) throw Error('Use a fresh public consumer directory');
mkdirSync(evidence, { recursive: true });
const receipt = { sdkVersion: version, platform, status: 'running', nativeExecution: 'not-run', checks: [] };
const save = () => writeFileSync(resolve(evidence, 'validation.json'), JSON.stringify(receipt, null, 2) + '\n');
function run(command, args, cwd = out) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8', maxBuffer: 64 * 1024 ** 2, shell: process.platform === 'win32' });
  const log = `${receipt.checks.length + 1}.log`;
  writeFileSync(resolve(evidence, log), (result.stdout ?? '') + (result.stderr ?? ''));
  receipt.checks.push({ command, args, exitCode: result.status, log }); save();
  if (result.error || result.status !== 0) throw Error(`Public consumer command failed; inspect ${log}`);
}
try {
  for (const name of ['weapp_container_platform_interface', ...['android', 'ios', 'macos', 'linux', 'windows'].map(p => `weapp_container_${p}`), 'weapp_container']) {
    const response = await fetch(`https://pub.dev/api/packages/${name}/versions/${version}`, { signal: AbortSignal.timeout(30000) });
    if (!response.ok) throw Error(`Exact public package unavailable: ${name} (${response.status})`);
    const metadata = await response.json();
    if (metadata.version !== version || !/^[a-f0-9]{64}$/.test(metadata.archive_sha256 ?? '')) throw Error(`Invalid public package identity: ${name}`);
    writeFileSync(resolve(evidence, `${name}.json`), JSON.stringify(metadata, null, 2) + '\n');
  }
  if (['ios', 'macos'].includes(platform)) run('flutter', ['config', '--no-enable-swift-package-manager']);
  run('flutter', ['create', '--platforms', platform, '--project-name', 'public_consumer', app]);
  run('flutter', ['pub', 'add', `weapp_container:${version}`], app);
  writeFileSync(resolve(app, 'lib/main.dart'), `import 'package:flutter/material.dart';
import 'package:weapp_container/weapp_container.dart';
void main() => runApp(const MaterialApp(home: Consumer()));
class Consumer extends StatefulWidget {
  const Consumer({super.key});
  @override State<Consumer> createState() => _ConsumerState();
}
class _ConsumerState extends State<Consumer> {
  final Future<WeappContainerController> controller = WeappContainerController.create(storageKey: null);
  @override Widget build(BuildContext context) => Scaffold(body: FutureBuilder<WeappContainerController>(
    future: controller,
    builder: (context, snapshot) => snapshot.hasData
      ? WeappContainerView(controller: snapshot.data!)
      : const Center(child: CircularProgressIndicator()),
  ));
}
`);
  if (platform === 'android') {
    const gradle = resolve(app, 'android/app/build.gradle.kts');
    const source = readFileSync(gradle, 'utf8');
    if (!source.includes('minSdk = flutter.minSdkVersion')) throw Error('Review the generated Android minimum SDK setting');
    writeFileSync(gradle, source.replace('minSdk = flutter.minSdkVersion', 'minSdk = 26'));
  }
  if (['ios', 'macos'].includes(platform)) {
    const podfile = resolve(app, platform, 'Podfile');
    if (!existsSync(podfile)) throw Error('Expected a CocoaPods consumer Podfile');
    const source = readFileSync(podfile, 'utf8').replace(/^#?\s*platform :osx,.*$/m, "platform :osx, '12.0'").replace(/^#?\s*platform :ios,.*$/m, "platform :ios, '16.0'");
    writeFileSync(podfile, "source 'https://github.com/weapp-container/Specs.git'\nsource 'https://cdn.cocoapods.org/'\n" + source);
    const project = resolve(app, platform, 'Runner.xcodeproj/project.pbxproj');
    writeFileSync(project, readFileSync(project, 'utf8').replace(/IPHONEOS_DEPLOYMENT_TARGET = [^;]+;/g, 'IPHONEOS_DEPLOYMENT_TARGET = 16.0;').replace(/MACOSX_DEPLOYMENT_TARGET = [^;]+;/g, 'MACOSX_DEPLOYMENT_TARGET = 12.0;'));
  }
  const target = { android: ['apk', '--release'], ios: ['ios', '--simulator', '--debug'], macos: ['macos', '--release'], linux: ['linux', '--release'], windows: ['windows', '--release'] }[platform];
  run('flutter', ['build', ...target], app);
  copyFileSync(resolve(app, 'pubspec.lock'), resolve(evidence, 'pubspec.lock'));
  receipt.status = 'passed'; receipt.scope = 'Fresh public package resolution and native compile/link; no device execution';
} catch (error) {
  receipt.status = 'failed'; receipt.error = error.message; process.exitCode = 1;
} finally { save(); }
