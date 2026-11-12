import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { run } from './public-release.mjs';
const root = fileURLToPath(new URL('../', import.meta.url));
const names = ['weapp_container_platform_interface', ...['android', 'ios', 'macos', 'linux', 'windows'].map(p => `weapp_container_${p}`), 'weapp_container'];
const generated = [];
try {
  for (const name of names) {
    const file = resolve(root, name, 'pubspec_overrides.yaml');
    if (existsSync(file)) throw Error('Do not overwrite an existing developer pubspec override');
    const spec = readFileSync(resolve(root, name, 'pubspec.yaml'), 'utf8');
    const dependencies = names.filter(other => other !== name && new RegExp(`^  ${other}:`, 'm').test(spec));
    writeFileSync(file, 'dependency_overrides:\n' + dependencies.map(other => `  ${other}:\n    path: ../${other}\n`).join(''));
    generated.push(file);
  }
  for (const name of names) {
    const cwd = resolve(root, name);
    run('flutter', ['pub', 'get'], cwd, { stdio: 'inherit' });
    run('flutter', ['analyze', '--no-pub'], cwd, { stdio: 'inherit' });
  }
} finally { for (const file of generated) rmSync(file); }
