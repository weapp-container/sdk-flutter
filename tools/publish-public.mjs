import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cleanSource, contained, run, sha256, versionOf } from './public-release.mjs';
import { publicationPackages } from './pub-publication.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const option = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
if (!option('--distribution')) throw Error('Supply the staged --distribution directory [--execute]');
const directory = resolve(option('--distribution')), manifest = JSON.parse(readFileSync(join(directory, 'distribution.json')));
if (manifest.sdkVersion !== versionOf(root) || manifest.sourceDirty !== false || manifest.sourceCommit !== cleanSource(root)) throw Error('Flutter publication must use the exact clean staging source');
const execute = process.argv.includes('--execute');
const packages = publicationPackages(manifest, option('--package'), execute && process.env.GITHUB_ACTIONS === 'true' ? process.env.GITHUB_REF_NAME ?? '' : undefined);
function verify() {
  for (const [file, expected] of Object.entries(manifest.files)) if (sha256(readFileSync(contained(directory, file))) !== expected) throw Error(`Staged Flutter file changed: ${file}`);
}
verify();
for (const name of packages) {
  const cwd = join(directory, name);
  const url = `https://pub.dev/api/packages/${name}/versions/${manifest.sdkVersion}`;
  const prior = await fetch(url, { signal: AbortSignal.timeout(30000) });
  if (prior.status !== 404) throw Error(`Existing version or uncertain pub.dev state for ${name} (${prior.status}); never overwrite or skip a version`);
  run('flutter', ['pub', 'get'], cwd);
  run('flutter', ['analyze', '--no-pub'], cwd);
  verify();
  run('dart', ['pub', 'publish', '--dry-run'], cwd, { stdio: 'inherit' });
  const archivePath = join(directory, `${name}-${manifest.sdkVersion}.tar.gz`);
  if (existsSync(archivePath)) throw Error('A frozen package archive already exists; select a fresh staging directory');
  run('dart', ['pub', 'publish', '--to-archive', archivePath], cwd, { stdio: 'inherit' });
  const frozenHash = sha256(readFileSync(archivePath));
  writeFileSync(join(directory, `${name}-archive.json`), JSON.stringify({ name, version: manifest.sdkVersion, sha256: frozenHash, sourceCommit: manifest.sourceCommit }, null, 2) + '\n');
  if (execute) {
    verify();
    if (sha256(readFileSync(archivePath)) !== frozenHash) throw Error('Frozen pub archive changed');
    // First publication remains interactive so pub.dev can authorize the human publisher.
    run('dart', ['pub', 'publish', '--from-archive', archivePath, ...(process.env.GITHUB_ACTIONS === 'true' ? ['--force'] : [])], cwd, { stdio: 'inherit' });
    const response = await fetch(url, { signal: AbortSignal.timeout(30000) });
    if (!response.ok) throw Error(`${name} publication is pending verification; do not republish`);
    const remote = await response.json();
    const archive = await fetch(remote.archive_url, { signal: AbortSignal.timeout(120000) });
    if (!archive.ok) throw Error(`Cannot anonymously download ${name}`);
    const bytes = Buffer.from(await archive.arrayBuffer());
    const actual = createHash('sha256').update(bytes).digest('hex');
    if (remote.archive_sha256 !== actual || actual !== frozenHash) throw Error(`pub.dev archive checksum mismatch for ${name}`);
    writeFileSync(join(directory, `${name}-publication.json`), JSON.stringify({ name, version: manifest.sdkVersion, archiveSha256: actual, published: true }, null, 2) + '\n');
  }
}
