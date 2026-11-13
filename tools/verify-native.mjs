import { assertDistributionIdentity, installationDistribution } from './distribution-identity.mjs';
import { closeSync, existsSync, lstatSync, openSync, readFileSync, readSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { SDK_VERSION } from './runtime-artifacts.mjs';
import { nativeArtifactPaths } from './native-artifact-paths.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
function digest(file) {
  const hash = createHash('sha256'), buffer = Buffer.allocUnsafe(1024 * 1024), fd = openSync(file, 'r');
  try { let size; while ((size = readSync(fd, buffer)) !== 0) hash.update(buffer.subarray(0, size)); }
  finally { closeSync(fd); }
  return hash.digest('hex');
}
/** Recheck every installed byte against the exact release pin before packaging. */
export function verifyNativeInstallation(directory, platform, manifestPath = join(root, 'runtime-artifacts.0.1.0-preview.7.1.lock.json'), archiveDirectory, expectedDistribution) {
  const install = resolve(directory), status = lstatSync(install);
  if (!status.isDirectory() || status.isSymbolicLink()) throw new Error('Native SDK installation must be a regular directory');
  const receiptPath = join(install, '.runtime-install.json');
  if (!lstatSync(receiptPath).isFile() || lstatSync(receiptPath).isSymbolicLink()) throw new Error('Native installation receipt must be a regular file');
  const saved = JSON.parse(readFileSync(receiptPath, 'utf8'));
  const component = ['android', 'ios'].includes(platform) ? `${platform}-sdk` : 'desktop-sdk';
  const identity = { ...installationDistribution(expectedDistribution), runtimeVersion: SDK_VERSION, abiVersion: 1, component, platform, arch: saved.identity?.arch };
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  const paths = nativeArtifactPaths(join(root, '.runtime'), manifest, { ...installationDistribution(expectedDistribution), version: SDK_VERSION, abiVersion: 1, platform, arch: identity.arch });
  const pin = paths.pin;
  assertDistributionIdentity(saved.identity, expectedDistribution);
  assertDistributionIdentity(pin, expectedDistribution);
  if (saved.schemaVersion !== 1 || saved.archiveSha256 !== pin.sha256 || !isDeepStrictEqual(saved.identity, identity)) throw new Error('Native SDK receipt differs from the exact release pin');
  const files = []; let bytes = 0;
  function walk(parent, prefix = '') {
    for (const name of readdirSync(parent).sort()) {
      const relative = `${prefix}${name}`, file = join(parent, name);
      if (relative === '.runtime-install.json') continue;
      const stat = lstatSync(file);
      if (stat.isSymbolicLink() || !stat.isDirectory() && !stat.isFile()) throw new Error('Native installation contains a link or special file');
      if (files.length >= 100000 || (bytes += stat.isFile() ? stat.size : 0) > 8 * 1024 ** 3) throw new Error('Native installation exceeded its bounds');
      if (stat.isDirectory()) { files.push({ path: relative, directory: true }); walk(file, `${relative}/`); }
      else files.push({ path: relative, size: stat.size, sha256: digest(file), executable: Boolean(stat.mode & 0o111) });
    }
  }
  walk(install); files.sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  if (!files.length || !isDeepStrictEqual(files, saved.files)) throw new Error('Native installation bytes, paths or modes have changed');
  const archive = join(archiveDirectory ?? paths.outDirectory, pin.fileName);
  if (!existsSync(archive)) throw new Error('Pinned native archive is required for package revalidation; run tools/prepare-native.mjs again');
  execFileSync(process.env.PYTHON ?? 'python3', [join(root, 'tools/unpack-runtime.py'), '--archive', archive, '--destination', install, '--sha256', pin.sha256, '--identity-json', JSON.stringify(identity)], { maxBuffer: 1024 ** 2, stdio: 'pipe' });
  return { archiveSha256: pin.sha256, identity, files: files.length };
}
