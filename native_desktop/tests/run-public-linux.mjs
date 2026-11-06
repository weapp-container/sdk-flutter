#!/usr/bin/env node
// Runs the public Widget/Controller consumer from a relocated prepared SDK.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const option = name => { const i = args.indexOf(name); return i < 0 ? undefined : args[i + 1]; };
if (!option('--distribution') || !option('--flutter') || !option('--out')) {
  throw new Error('Usage: run-public-linux.mjs --distribution <prepared-flutter-directory> --flutter <flutter-root> --out <new-evidence-directory>');
}
if (args.includes('--host-lifecycle') && args.includes('--hot-restart')) {
  throw new Error('Host lifecycle and standard consumer hot restart require separate runs');
}
const source = path.resolve(option('--distribution'));
const output = path.resolve(option('--out'));
const flutter = path.join(path.resolve(option('--flutter')), 'bin/flutter');
if (source === output || output.startsWith(source + path.sep)) throw new Error('Evidence must be outside the distribution');
mkdirSync(output, { recursive: true });
const run = (command, argv, cwd = output, timeout = 600000) => {
  const result = spawnSync(command, argv, { cwd, stdio: 'inherit', timeout });
  if (result.error || result.status !== 0) throw new Error(`${command} failed: ${result.error?.message ?? result.status ?? result.signal}`);
};
run('which', ['xvfb-run', 'xdotool', 'import', 'python3']);
const version = spawnSync(flutter, ['--version', '--machine'], { encoding: 'utf8' });
if (version.error || version.status !== 0) throw new Error('Cannot inspect Flutter toolchain');
const toolchain = JSON.parse(version.stdout);
if (toolchain.frameworkRevision !== 'abaf9c523780a608bd46686fd5e53740a07077f8'
    || toolchain.engineRevision !== 'deb287481e3ce9468f3434937ced4240a70539ca') {
  throw new Error('Public consumer acceptance requires pinned Flutter 3.47.7');
}
const hash = file => createHash('sha256').update(readFileSync(file)).digest('hex');
const manifestPath = path.join(source, 'distribution.json');
const manifest = JSON.parse(readFileSync(manifestPath));
if (manifest.sourceDirty !== false || manifest.targets?.linux?.status !== 'packaged') throw new Error('A clean prepared Linux distribution is required');
cpSync(manifestPath, path.join(output, 'distribution.json'));
cpSync(path.join(source, 'consumer.json'), path.join(output, 'consumer-source.json'));
const ignored = new Set(['.dart_tool', 'build', '.gradle', '.cxx', '.DS_Store', '.flutter-plugins-dependencies', 'ephemeral']);
cpSync(path.join(source, 'packages'), path.join(output, 'packages'), {
  recursive: true, errorOnExist: true, force: false,
  filter: file => !ignored.has(path.basename(file)),
});
const consumer = path.join(output, 'consumer');
mkdirSync(consumer, { recursive: true });
for (const name of ['pubspec.yaml', 'pubspec.lock', 'lib', 'assets', 'linux']) {
  cpSync(path.join(source, 'consumer', name), path.join(consumer, name), {
    recursive: true, filter: file => !ignored.has(path.basename(file)),
  });
}
const hostLifecycle = args.includes('--host-lifecycle');
if (hostLifecycle) {
  const main = path.join(consumer, 'lib/main.dart');
  rmSync(main);
  cpSync(path.join(here, 'host_lifecycle_consumer.dart'), main);
}
const packageInputDigests = {};
const ignoredInput = new Set(['build', '.dart_tool', '.gradle', '.cxx', 'pubspec.lock']);
function scanInput(directory, relative) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (ignoredInput.has(entry.name)) continue;
    const file = path.join(directory, entry.name), key = `${relative}/${entry.name}`;
    if (entry.isDirectory()) scanInput(file, key);
    else if (entry.isFile()) packageInputDigests[key] = hash(file);
  }
}
for (const name of ['weapp_container', 'weapp_container_platform_interface', 'weapp_container_linux']) {
  scanInput(path.join(output, 'packages', name), name);
}
run(flutter, ['pub', 'get', '--offline'], consumer);
run(flutter, ['analyze', 'lib', '--no-pub'], consumer);
run(flutter, ['build', 'linux', '--debug', '--no-pub'], consumer);
const bundle = path.join(consumer, 'build/linux/x64/debug/bundle');
const executable = path.join(bundle, 'weapp_sdk_consumer');
const artifacts = [executable, path.join(bundle, 'lib/libweapp_container_linux_plugin.so')];
writeFileSync(path.join(output, 'build.json'), JSON.stringify({
  schemaVersion: 1, status: 'built', platform: 'linux-x64-x11',
  sourceCommit: manifest.sourceCommit, distributionSha256: hash(manifestPath),
  consumerMainSha256: hash(path.join(consumer, 'lib/main.dart')),
  flutterToolchain: toolchain, packageInputDigests,
  harness: hostLifecycle ? 'host-lifecycle' : 'public-consumer',
  artifacts: artifacts.map(file => ({ file, sha256: hash(file) })),
}, null, 2) + '\n');
run('xvfb-run', ['--auto-servernum', '-s', '-screen 0 1280x800x24',
  'env', 'LIBGL_ALWAYS_SOFTWARE=1', 'GDK_BACKEND=x11', 'PYTHONDONTWRITEBYTECODE=1',
  'python3', path.join(here, hostLifecycle ? 'host-linux-input.py' : 'public-linux-input.py'), executable, output,
  ...(args.includes('--hot-restart') ? [flutter] : [])], consumer, 180000);
console.log(`Flutter Linux ${hostLifecycle ? 'host lifecycle' : args.includes('--hot-restart') ? 'hot restart and public consumer' : 'public consumer'} passed: ${output}`);
