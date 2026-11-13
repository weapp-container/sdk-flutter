export function publicationPackages(manifest, requested, ciTag) {
  const names = manifest.packages;
  if (!Array.isArray(names) || names.length !== new Set(names).size || names.some(name => !/^weapp_container(?:_[a-z_]+)?$/.test(name))) throw Error('Invalid Flutter publication package list');
  if (requested && !names.includes(requested)) throw Error(`Unknown staged package: ${requested}`);
  if (ciTag !== undefined && (!requested || ciTag !== `${requested}-v${manifest.sdkVersion}`)) throw Error('OIDC publication requires the selected package and its exact version tag');
  return requested ? [requested] : names;
}
