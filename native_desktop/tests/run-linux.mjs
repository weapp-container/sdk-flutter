#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const argv = process.argv.slice(2);
const option = name => { const i = argv.indexOf(name); return i < 0 ? undefined : argv[i + 1]; };
const offline = argv.includes('--offline');
if (!option('--sdk') || !option('--flutter')) throw new Error('Usage: node run-linux.mjs --sdk <installed-linux-sdk> --flutter <flutter-root> [--out <evidence-directory>]');
const native = path.resolve(option('--sdk'));
const flutter = path.resolve(option('--flutter'));
const output = path.resolve(option('--out') ?? path.join(repo, 'artifacts/sdk/flutter-linux-test'));
mkdirSync(output, { recursive: true });
const run = (command, args, cwd = repo, timeout = 600000) => {
  const result = spawnSync(command, args, { cwd, stdio: 'inherit', timeout });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status ?? result.signal})`);
};
const common = path.dirname(here);
run('clang++', ['-std=c++17', '-Wall', '-Wextra', '-Werror', `-I${common}/include`, `-I${common}/third_party`, `-I${native}/include`, path.join(here, 'registry_failures.cpp'), path.join(common, 'src/registry.cpp'), '-o', path.join(output, 'registry-failures')]);
run(path.join(output, 'registry-failures'), []);
run(process.execPath, [path.join(repo, 'example/shared/make-fixture.mjs'), '--out', path.join(output, 'pack')]);
run(process.execPath, [path.join(common, 'prepare.mjs'), '--target', 'linux', '--from', native]);
const app = path.join(output, 'consumer');
if (!existsSync(path.join(app, 'pubspec.yaml'))) run(path.join(flutter, 'bin/flutter'), ['create', '--no-pub', '--platforms', 'linux', '--project-name', 'weapp_desktop_consumer', app]);
const plugin = path.relative(app, path.join(common, '../weapp_container_linux')).replaceAll(path.sep, '/');
writeFileSync(path.join(app, 'pubspec.yaml'), `name: weapp_desktop_consumer\npublish_to: none\nversion: 1.0.0+1\nenvironment:\n  sdk: '>=3.6.0 <4.0.0'\ndependencies:\n  flutter:\n    sdk: flutter\n  weapp_container_linux:\n    path: ${plugin}\nflutter:\n  uses-material-design: true\n`);
cpSync(path.join(here, 'engine_consumer.dart'), path.join(app, 'lib/main.dart'));
run(path.join(flutter, 'bin/flutter'), ['pub', 'get', ...(offline ? ['--offline'] : [])], app);
run(path.join(flutter, 'bin/flutter'), ['build', 'linux', '--debug', '--no-pub', `--dart-define=WEAPP_TEST_PACK=${output}/pack`, `--dart-define=WEAPP_TEST_EVIDENCE=${output}`], app);
rmSync(path.join(output, 'result.json'), { force: true });
const arch = process.arch === 'arm64' ? 'arm64' : 'x64';
run('xvfb-run', ['--auto-servernum', '-s', '-screen 0 1280x800x24', 'env', 'LIBGL_ALWAYS_SOFTWARE=1', 'GDK_BACKEND=x11', path.join(app, `build/linux/${arch}/debug/bundle/weapp_desktop_consumer`)], app, 90000);
const result = JSON.parse(readFileSync(path.join(output, 'result.json')));
if (result.status !== 'passed') throw new Error(JSON.stringify(result));
console.log(`Flutter Linux engine validation passed. Evidence: ${output}`);
