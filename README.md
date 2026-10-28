# Weapp Container Flutter SDK

Apache-2.0 Flutter bindings for the Weapp Container native SDK. Source repository: https://github.com/weapp-container/sdk-flutter. Version: **0.1.0-preview.3**; native ABI: **1**.

This repository contains seven federated Dart/plugin packages, the desktop adapter, consumers and contract tests. It contains no container-core/Rust source, native runtime binary, generated application pack or parent-checkout dependency. Public Dart names and method/event channels are preserved. The runtime is a separate private binary dependency.

This checkout targets **0.1.0-preview.3** for Dev Player. The committed
preview.2 lock and historical reports remain unchanged and cannot prepare this
version. `prepare-native.mjs` requires an explicitly reviewed preview.3 lock via
`--manifest` once real archive hashes exist. For a locally verified preview.3
desktop installation, use `node native_desktop/prepare.mjs --target macos --from
/absolute/preview3-desktop-sdk` before building the Player. It verifies the
package and every native slice; this path does not claim private-release download
or device acceptance. No old-runtime fallback is allowed.

## Prerequisites and native artifacts

Use Node.js 24+, Python 3, and pinned Flutter **3.47.7** (framework `abaf9c523780a608bd46686fd5e53740a07077f8`, engine `deb287481e3ce9468f3434937ced4240a70539ca`). Native Android consumers require minSdk 26; iOS requires 16.0; macOS requires 12.0. Desktop tooling and platform SDK requirements are documented in `native_desktop/README.md`.

`runtime-artifacts.lock.json` permits only exact version, component, platform, architecture, byte size and SHA-256 pins from the private `weapp-container/runtime-artifacts` release `runtime-v0.1.0-preview.2`. The current lock pins the reviewed Android universal SDK (arm64-v8a and x86_64), iOS universal SDK (arm64 device, arm64 simulator and x86_64 simulator), and macOS universal desktop SDK (arm64 and x86_64). The checked-in lock preserves all ten reviewed runtime/SDK assets; these tools consume the SDK entry for the selected platform. Targets without their exact reviewed SDK entry remain **blocked** and return an explicit missing-target error. No floating `latest`, placeholder digest, local core build or silent fallback is used.

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
