#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const argv = process.argv.slice(2);
const option = name => { const i = argv.indexOf(name); return i < 0 ? undefined : argv[i + 1]; };
if (!option('--sdk') || !option('--flutter')) throw new Error('Usage: node run-macos.mjs --sdk <installed-macos-sdk> --flutter <flutter-root> [--out <evidence-directory>]');
const native = path.resolve(option('--sdk'));
const flutter = path.resolve(option('--flutter'));
const output = path.resolve(option('--out') ?? path.join(repo, 'artifacts/sdk/flutter-desktop-test'));
const common = path.dirname(here);
const framework = path.join(flutter, 'bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64');
mkdirSync(output, { recursive: true });
const run = (command, args, cwd = repo, timeout = 600000) => {
  const result = spawnSync(command, args, { cwd, stdio: 'inherit', timeout });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status ?? result.signal})`);
};
const includes = [`-I${common}/include`, `-I${common}/third_party`, `-I${native}/include`];
run('clang++', ['-std=c++17', '-Wall', '-Wextra', '-Werror', ...includes, path.join(here, 'registry_failures.cpp'), path.join(common, 'src/registry.cpp'), '-o', path.join(output, 'registry-failures')]);
run(path.join(output, 'registry-failures'), []);
run(process.execPath, [path.join(repo, 'example/shared/make-fixture.mjs'), '--out', path.join(output, 'pack')]);
run('clang++', ['-std=c++17', '-fobjc-arc', ...includes, `-F${framework}`, path.join(here, 'macos_texture.mm'), path.join(common, 'src/registry.cpp'), path.join(native, 'lib/libweapp_container_sdk.a'), ...['FlutterMacOS', 'Metal', 'CoreVideo', 'IOSurface', 'AppKit', 'CoreGraphics', 'CoreText', 'CoreFoundation', 'Security', 'SystemConfiguration', 'IOKit'].flatMap(name => ['-framework', name]), '-liconv', '-lresolv', `-Wl,-rpath,${framework}`, '-o', path.join(output, 'macos-texture')]);
run(path.join(output, 'macos-texture'), [path.join(output, 'pack'), path.join(output, 'native-storage')]);
run(process.execPath, [path.join(common, 'prepare.mjs'), '--target', 'macos', '--from', native]);
const app = path.join(output, 'consumer');
if (!existsSync(path.join(app, 'pubspec.yaml'))) run(path.join(flutter, 'bin/flutter'), ['create', '--platforms', 'macos', '--project-name', 'weapp_desktop_consumer', app]);
const plugin = path.relative(app, path.join(common, '../weapp_container_macos')).replaceAll(path.sep, '/');
writeFileSync(path.join(app, 'pubspec.yaml'), `name: weapp_desktop_consumer\npublish_to: none\nversion: 1.0.0+1\nenvironment:\n  sdk: '>=3.6.0 <4.0.0'\ndependencies:\n  flutter:\n    sdk: flutter\n  weapp_container_macos:\n    path: ${plugin}\nflutter:\n  uses-material-design: true\n`);
cpSync(path.join(here, 'engine_consumer.dart'), path.join(app, 'lib/main.dart'));
for (const name of ['DebugProfile.entitlements', 'Release.entitlements']) {
  const file = path.join(app, 'macos/Runner', name);
  writeFileSync(file, readFileSync(file, 'utf8').replace(/(<key>com.apple.security.app-sandbox<\/key>\s*)<true\/>/, '$1<false/>'));
}
run(path.join(flutter, 'bin/flutter'), ['pub', 'get'], app);
run(path.join(flutter, 'bin/flutter'), ['build', 'macos', '--debug', `--dart-define=WEAPP_TEST_PACK=${output}/pack`, `--dart-define=WEAPP_TEST_EVIDENCE=${output}`], app);
rmSync(path.join(output, 'result.json'), { force: true });
run(path.join(app, 'build/macos/Build/Products/Debug/weapp_desktop_consumer.app/Contents/MacOS/weapp_desktop_consumer'), [], app, 90000);
const result = JSON.parse(readFileSync(path.join(output, 'result.json')));
if (result.status !== 'passed') throw new Error(JSON.stringify(result));
console.log(`Flutter macOS validation passed. Evidence: ${output}`);
