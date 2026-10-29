# Weapp Container Flutter SDK

Apache-2.0 Flutter bindings for the Weapp Container native SDK. Source repository: https://github.com/weapp-container/sdk-flutter. Version: **0.1.0-preview.5.3**; native ABI: **1**.

The current source requires `0.1.0-preview.5.3` native runtime and SDK bundles, including the shared Skia layout-authority and native selector-owner corrections. The checked-in lock pins the independently reviewed, privately published release bytes (SHA-256 `ee393000b5726172755b24a31812f9b55051e710c2714edadb9b3ac287b95388`). Archive review and publication do not establish consumer installation or Player/GPU/device acceptance; those remain separate gates.

This repository contains seven federated Dart/plugin packages, the desktop adapter, consumers and contract tests. It contains no container-core/Rust source, native runtime binary, generated application pack or parent-checkout dependency. Public Dart names and method/event channels are preserved. The runtime is a separate private binary dependency.

Atomic host layout captures queued geometry by value. A cancelled measurement is
treated as superseded only when the same native owner proves a newer observation
or accepted layout revision and execution remains healthy. Unknown cancellations
still reach `onError`; an obsolete operation cannot acknowledge chrome or resume
presentation. Android development diagnostics expose only allowlisted reasons
and canonical decimal layout identities. These wrapper changes reuse the exact
native archives above; their source commit does not replace the archive's
original producer identity. Device verification remains a separate requirement.

The View keeps desired geometry, native control metadata and occlusion separate.
Immediately before dispatch, it checks the complete current widget and native
pending observation, including owner, surface, page and window metrics. Startup
may already have consumed a prepared observation; queued duplicates are skipped
without another layout ACK or input restoration. Titles and accessibility labels
still update independently. Only a successful current layout is committed, and
the native acceptance event is distinct from GPU presentation. `closeRequested`
is set when closing begins; that View retires its waits and ignores late replies,
even when native cleanup needs an explicit retry.

The default lock identifies the **0.1.0-preview.5.3** distribution of QuickJS
+ Skia GPU artifacts by exact size and SHA-256: seven runtime slices and Android,
iOS and macOS universal SDK packages. Native production remains bound to
`012400d43cb20b4d91a73fbbde7e1cf11bd0bb6a`; the packaging envelope is
`eff194421aa48ea7871b0989f9903f3636f6432e`. Android, iOS and desktop wrapper
producer commits are respectively `e4fa84e784edc1a80d972655eea347537ca40774`,
`159b7e2e66aa83e952e2af43edcd771344829379` and
`ae67dde1a104587968e2db37a9636b8776328607`. Later lock-only commits do not
replace those producer identities. Windows/Linux runtime distributions remain
blocked.

The historical preview.5.2 lock had SHA-256
`10cf2f084601c9d0e2f06c54dcce4810527035beeee760f075b414651c67d829`. Its
native production remains bound to `747d0b02131d7f67b3adbdd7127abcd5e21ffdbe`.
Android wrapper `preview.5.2` was built
from `c8241b83017d7f5f7fd614dc34bd9fbf00230c0f`; iOS wrapper `preview.5.2`
from `f8af959868b009b6b627c370c28983c410be7e9e`. That distribution used the
`preview.5.1` desktop SDK. Later pin-only commits do not change those historical
producer identities.
Archive validation, private publication and actual Player/GPU/device acceptance
are separate gates. No older-runtime fallback is allowed.

Historical preview.5 native production remains bound to
`05aec6c4056a124a9c399c75b34d081cffbdaa5d`. All earlier release bytes, reports
and source identities keep their original bindings.
Preparation downloads the exact reviewed SDK archive from the private release or
an authorized offline directory. Caches are isolated by version, platform,
architecture and content hash. Prior preview.2 caches and reports remain intact;
failed preparation preserves the current vendor installation. Windows/Linux
SDK distributions remain blocked. Download/installation is not GPU/device
acceptance.

## Prerequisites and native artifacts

Use Node.js 24+, Python 3, and pinned Flutter **3.47.7** (framework `abaf9c523780a608bd46686fd5e53740a07077f8`, engine `deb287481e3ce9468f3434937ced4240a70539ca`). Native Android consumers require minSdk 26; iOS requires 16.0; macOS requires 12.0. Desktop tooling and platform SDK requirements are documented in `native_desktop/README.md`.

`runtime-artifacts.lock.json` permits only exact version, component, platform, architecture, byte size and SHA-256 pins from the private `weapp-container/runtime-artifacts` release `runtime-v0.1.0-preview.5.3`. The current lock pins the reviewed Android universal SDK (arm64-v8a and x86_64), iOS universal SDK (arm64 device, arm64 simulator and x86_64 simulator), and macOS universal desktop SDK (arm64 and x86_64). The checked-in lock preserves all ten reviewed runtime/SDK assets; these tools consume the SDK entry for the selected platform. Targets without their exact reviewed SDK entry remain **blocked** and return an explicit missing-target error. No floating `latest`, placeholder digest, local core build or silent fallback is used.

For an available versioned GitHub release, grant `WEAPP_CONTAINER_RUNTIME_TOKEN` read access to that private repository, or set `WEAPP_CONTAINER_RUNTIME_ARTIFACT_DIR` to authorized offline `.tar.gz` assets. Never commit credentials or archives.

Network artifact transfers have a single 15-minute deadline covering headers,
redirects and the complete body; release metadata has a separate 30-second
deadline. For slower connections, set `WEAPP_CONTAINER_RUNTIME_TIMEOUT_MS` to a
positive base-10 integer in milliseconds, up to `3600000` (one hour). Invalid
values return `ERR_RUNTIME_OPTIONS`; transfer failures and timeouts return
sanitized `ERR_RUNTIME_NETWORK`. Explicit API/CLI overrides are documented in the
[shared SDK contract](https://github.com/weapp-container/sdk-contract).

```sh
node tools/prepare-native.mjs --platform android --arch universal
node tools/prepare-native.mjs --platform ios --arch universal
node tools/prepare-native.mjs --platform macos --arch universal
node tools/prepare-native.mjs --platform windows --arch x86_64
node tools/prepare-native.mjs --platform linux --arch x86_64
```

Each selected architecture must exist in the lock; a universal entry must list its actual slices. Downloads are verified and safely unpacked under ignored `.runtime/`. Platform package directories receive relocatable native installations; the desktop adapter validates native SDK receipts. Preparation does not execute a native compiler. Missing native files stop Maven/CocoaPods/CMake explicitly.

Downloads and immutable installations are addressed by the validated
`version/component/platform/architecture/SHA-256` under `.runtime/downloads/`
and `.runtime/install/`. SDK upgrades and different reviewed pins can coexist
even when their archive filenames match. Historical flat caches and platform
directories are preserved and are never used as a fallback. Repeating a pin
still revalidates its archive and installed bytes; a corrupt cache fails
explicitly. Only after successful validation does preparation replace the
plugin's active native/vendor directory transactionally.

Packaging uses the same pinned installation and archive paths. Its default
requires one exact SDK artifact per platform; use an explicit installed SDK
path if a lock contains multiple architectures for that platform. An alternate
reviewed lock can be selected with `tools/package.mjs --manifest /absolute/lock.json`.

## Packages and consumer

The packages are `weapp_container`, `weapp_container_platform_interface`, and Android/iOS/macOS/Windows/Linux implementations. Relative path dependencies are entirely within this checkout. Use `weapp_container` as the application-facing package; retain all sibling packages when relocating the source tree.

```yaml
dependencies:
  weapp_container:
    path: /absolute/path/sdk-flutter/weapp_container
```

The shared fixture generator authors a small portable pack from source without reading another checkout. It is explicitly labeled `handwritten-sdk-fixture`, not a weapp-vite build or upstream conformance result. On a committed checkout, assemble a relocatable distribution and independent consumer:

```sh
node tools/package.mjs --flutter /absolute/path/flutter/bin/flutter \
  --out /absolute/path/new-flutter-distribution
```

The output contains `packages/`, `distribution.json`, `consumer/` and `consumer.json`. Only native targets that pass their pinned-installation and receipt checks receive `packaged`; unavailable targets retain `blocked` reasons and are removed from staging. To build one selected prepared target, add `--platform android|ios|macos|windows|linux`. `--portable-consumer` produces sources without installed dependencies/caches; it cannot be combined with `--platform`. Runtime compilation never occurs here.

The public Widget/Controller API is described in `weapp_container/README.md`. `example/lib/main.dart` covers sessions, native bridge messages and resource ownership. `native_desktop/tests/run-public-linux.mjs` consumes the generated distribution without a parent checkout. `tools/ios-smoke.mjs`, `tools/android-smoke.mjs`, and `tools/android-host-smoke.mjs` retain the explicit existing-device, evidence-directory and cleanup contracts. Do not interpret source checks as device/GPU evidence.

## Validation and provenance

```sh
node --test tests/source-contract.test.mjs
node native_desktop/tests/prepare_receipts.mjs
node --test tests/prepare-native.test.mjs
c++ -std=c++17 -Wall -Wextra -Werror -pthread -I native_desktop/include -I native_desktop/third_party native_desktop/tests/registry_failures.cpp native_desktop/src/registry.cpp -o /absolute/path/registry-receipts
/absolute/path/registry-receipts
```

`CONTRACT.md` defines the SDK protocol, including native GPU presentation receipts. Desktop textures carry the exact pre-submit generation/revision. Metal waits for completion and Flutter texture consumption; raster callbacks queue receipts, and the original runtime thread sends `presented` only when the SDK requires it. Stale/retired receipts do not unlock input. This proves texture consumption, not display vSync or hardware/device acceptance. Android/iOS use the native SDK view and inherit its presentation contract.

`ORIGIN.json` records the private source revision, original per-file SHA-256, source paths and exported output hashes. `LICENSE` covers these bindings. The vendored nlohmann JSON header retains its MIT license and upstream `SOURCE.json`. Native archive notices are distributed with authorized artifacts; they are not replaced by this wrapper license. A pin identifies reviewed distribution bytes. Archive publication, consumer compilation, device/GPU results and registry publication require their own recorded validation; they are not implied by a source checkout.

### Reviewing later SDK source changes

`ORIGIN.json` remains the historical extraction receipt. `SOURCE-INVENTORY.json` separately pins the current reviewed wrapper source paths, SHA-256, sizes and executable modes, including the unchanged historical receipt. Neither file is build or device acceptance evidence. Source tests and package assembly require an independent Git checkout and reject untracked files, unreviewed tracked paths, changed bytes, symlinks, core sources, binary files and build caches.

After reviewing source or runtime-lock updates, stage all intended new files and explicitly refresh the current inventory; do not rewrite `ORIGIN.json`:

```sh
git add <reviewed-files>
node tools/source-inventory.mjs --write --version 0.1.0-preview.5.3 --reason "Describe the reviewed source changes"
git add SOURCE-INVENTORY.json
node tools/source-inventory.mjs
node --test tests/source-inventory.test.mjs tests/source-contract.test.mjs
```

Commit the source and inventory together before assembling distributable packages. The inventory's `sourceBaseCommit` identifies the checkout on which the review was prepared; it does not bind later build or runtime evidence to that earlier commit. Runtime artifact locks must use actual published archive hashes and are reviewed independently.
