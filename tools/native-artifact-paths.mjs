import { join, resolve } from 'node:path';
import { selectArtifact } from './runtime-artifacts.mjs';

export const nativeSdkComponent = platform => platform === 'android' ? 'android-sdk'
  : platform === 'ios' ? 'ios-sdk' : 'desktop-sdk';

/** Derive storage names only after validating the full manifest and exact pin. */
export function nativeArtifactPaths(runtimeRoot, manifest, expected) {
  const pin = selectArtifact(manifest, { ...expected, component: nativeSdkComponent(expected.platform) });
  const identity = [pin.runtimeVersion, pin.component, pin.platform, pin.arch, pin.sha256];
  return Object.freeze({ pin,
    outDirectory: join(resolve(runtimeRoot), 'downloads', ...identity),
    installDirectory: join(resolve(runtimeRoot), 'install', ...identity) });
}
