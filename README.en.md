# Weapp Container Flutter SDK

[简体中文](README.md) · **English**

<a id="公开发行候选preview7"></a>
## Public distribution candidate: preview.7

The Flutter package, platform interface and all five native platform packages at `0.1.0-preview.7.1` are published on pub.dev. This is still a prerelease, with no stable version available. Android Maven and Linux/Windows Desktop archives are anonymously downloadable. The iOS/macOS CocoaPods specifications reference unavailable standalone SDK archives, so public Apple-platform builds are not yet usable. Check the [SDK release status](https://github.com/weapp-container/weapp-container/blob/main/docs/public-sdk-release.en.md) for platform boundaries.

Version: `0.1.0-preview.7.1`；C ABI `1`。

The seven public packages are `weapp_container`, `weapp_container_platform_interface`, `weapp_container_android`, `weapp_container_ios`, `weapp_container_macos`, `weapp_container_linux`, and `weapp_container_windows`. The main package selects the corresponding plugin for each platform. Registry availability does not imply that every native target has passed a build or device test.

```yaml
dependencies:
  weapp_container: 0.1.0-preview.7.1
```

```sh
flutter pub get
```

Android API 26+; iOS 16+; macOS 12+ universal; Linux / Windows x86_64. Flutter 3.22+ / Dart 3.3+. Android uses Maven Central. iOS and macOS use public CocoaPods specifications; add both sources to each Apple Podfile:

```ruby
source 'https://github.com/weapp-container/Specs.git'
source 'https://cdn.cocoapods.org/'
```

Linux / Windows CMake downloads a fixed Desktop archive and verifies SHA-256. For offline builds, prefetch the exact archive and set `FETCHCONTENT_SOURCE_DIR_WEAPP_CONTAINER_RUNTIME` to its extracted directory. Each platform package includes its bridge sources, headers and licenses. Normal application installation requires no Node preparation command or sibling repository.

Published archives include bridge sources and licenses. iOS/macOS remain blocked by missing standalone SDK archives referenced by their Podspecs. Linux/Windows consume the Desktop SDK tarballs in the core preview release. Source-build and target-validation steps follow below.

<a id="已复核的源码构建版本"></a>
### Reviewed source-build checkout

```sh
git clone https://github.com/weapp-container/sdk-flutter.git sdk-flutter-source
cd sdk-flutter-source
git checkout d115f7d3ea6f5d7df2e3fe4cef38607ca248dccf
```



[Documentation](https://container.weapp.dev/en/docs/) · [Source builds](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.en.md) · [APIs and protocols](https://github.com/weapp-container/sdk-contract/blob/main/README.en.md)

Embed a mini-program container in a Flutter application. Android and iOS use native Views; desktop platforms use Flutter external textures. One Dart Controller handles local packs, navigation, messages and session ownership.

Reviewed source example version: `0.1.0-preview.7.1`; native ABI: `1`. This repository contains the Apache-2.0 integration layer. The runtime is a separately authorized binary dependency. All seven Flutter packages are published on pub.dev. Native builds and device acceptance remain recorded per target platform.

<a id="从当前源码开始"></a>
## Start from current source

For a new integration, use the public core repository and its pinned SDK revisions. This path needs no historical archive download token:

```sh
git clone --recurse-submodules https://github.com/weapp-container/weapp-container.git
cd weapp-container
corepack enable
pnpm install --frozen-lockfile
node sdk/contract/fixtures/make-acceptance-pack.mjs --out artifacts/hello-pack
```

Follow the [source build guide](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.en.md) to prepare the target runtime and notices, then use this SDK's packaging tools. Platform toolchains remain prerequisites. A version on pub.dev does not imply that every native archive referenced by that target is downloadable; see the release notes above for platform status. Native mini-program directories and existing framework builds can be packaged independently; weapp-vite is optional.

The remaining sections describe standalone SDK installation, views, and lifecycle. Commands using `prepare-runtime` or `prepare-native` select the explicit archive path and require a reviewed matching manifest. Historical default locks may be unavailable; see the migration section at the end.

<a id="环境与平台"></a>
## Requirements and platforms

Dependency preparation needs Node.js 24+, Python 3 and your target's native development tools. The distribution script verifies the pinned framework/engine revisions of Flutter **3.47.7**.

| Platform | Minimum OS / architectures | SDK in the default lock |
| --- | --- | --- |
| Android | API 26; arm64-v8a, x86_64 | universal |
| iOS | iOS 16; arm64 device, arm64/x86_64 simulator | universal |
| macOS | macOS 12; arm64, x86_64 | universal |
| Linux | x86_64; see [desktop requirements](native_desktop/README.en.md) | x86_64 |
| Windows | x86_64 | Unavailable; preparation explicitly fails |

Archive availability, successful client builds and device execution are separate results. After packaging, check `targets` in `distribution.json`.

<a id="1-准备原生依赖"></a>
## 1. Prepare native dependencies

```sh
# Run at the core checkout root after creating a reviewed local manifest.
node sdk/flutter/tools/prepare-native.mjs --platform android --arch universal \
  --manifest artifacts/local-release/manifest.json --artifact-dir artifacts/local-release
```

Follow the [source build guide](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.en.md) to build the matching SDK and create a local `manifest.json` and archives. The command above consumes those local inputs from the core checkout root and needs no historical archive token. Adjust paths to your actual output and keep native archives out of Git.

Prepare only the platforms you need:

```sh
node sdk/flutter/tools/prepare-native.mjs --platform ios --arch universal \
  --manifest artifacts/local-release/manifest.json --artifact-dir artifacts/local-release
node sdk/flutter/tools/prepare-native.mjs --platform macos --arch universal \
  --manifest artifacts/local-release/manifest.json --artifact-dir artifacts/local-release
node sdk/flutter/tools/prepare-native.mjs --platform linux --arch x86_64 \
  --manifest artifacts/local-release/manifest.json --artifact-dir artifacts/local-release
```

Preparation verifies the exact version, ABI, architecture, size, and SHA-256 against the explicit manifest. Missing or mismatched targets never fall back to an older runtime. The default `runtime-artifacts.lock.json` is a historical compatibility input.

<a id="2-生成分发包并运行示例"></a>
## 2. Build a distribution and run the example

The example app is in the SDK checkout's `example/` directory and uses the sibling `weapp_container` package through a path dependency:

```sh
cd sdk/flutter/example
# Generate the example pack, then add the Flutter platform project folders.
node shared/make-fixture.mjs --out assets/portable-pack
flutter create --empty --platforms=android,ios,macos,linux,windows .
flutter pub get
flutter analyze lib
flutter run -d DEVICE_ID
```

After generating the Android project, replace `minSdk = flutter.minSdkVersion` with `minSdk = 26` inside `defaultConfig` in `android/app/build.gradle.kts`. This is the minimum supported version for `weapp_container_android`; projects generated by `tools/package.mjs` receive this value automatically.

The example includes an authored test pack for taps, scrolling, navigation, messages, storage and session recreation. Android, iOS, macOS, Windows, and Linux builds require the corresponding platform toolchain and an available native SDK. See the [release status](https://github.com/weapp-container/weapp-container/blob/main/docs/public-sdk-release.en.md) for public package coordinates and target availability.

`make-fixture.mjs` creates `assets/fixture-index.json` and the portable pack used by the example. The example `.gitignore` excludes generated assets and platform folders, so generate them again after a fresh clone. For one target only, replace `flutter create --platforms` with the platform you need. After launch, wait for `ready-for-input`, complete the tap, scroll, and session-reopen checks shown by the app, and inspect `sdk-flutter-report.json` in the application-support directory.

The Android example uses NDK `27.1.12297006`, CMake `3.22.1` and only the two supported ABIs:

```sh
flutter build apk --debug --target-platform android-arm64,android-x64
```

<a id="3-接入你的-flutter-应用"></a>
## 3. Add the SDK to your Flutter application

The example's seven federated packages use relative dependencies. When distributing them locally, keep the whole `packages/` directory:

```yaml
dependencies:
  weapp_container:
    path: /absolute/new-flutter-distribution/packages/weapp_container
```

Create a Controller and register host methods and event listeners before the first `load`. Run this in your page or route's session owner, outside `build()`:

```dart
import 'package:flutter/material.dart';
import 'package:weapp_container/weapp_container.dart';

final controller = await WeappContainerController.create(
  storageKey: 'account-42:catalog',
);
await controller.registerHostMethod('host.echo', (call) async {
  call.cancellation.throwIfCancelled();
  return {'value': call.payload};
});
final subscription = controller.events.listen((event) {
  if (event.type == 'message') debugPrint('${event.message}');
}, onError: (Object error, StackTrace stack) {
  debugPrint('$error');
});
```

Mount a View with positive width and height, using that same Controller:

```dart
SizedBox(
  height: 480,
  child: WeappContainerView(
    controller: controller,
    onError: (error, stack) => debugPrint('$error'),
  ),
)
```

Once mounted, load a generated, verified local pack. Extract Flutter assets to application-private storage first; see the [example](example/lib/main.dart):

```dart
await controller.load('/verified/local/portable-pack');
await controller.navigate('pages/detail/index', query: {'id': '42'});
await controller.sendMessage({'type': 'refresh'});
await controller.back();
```

`load()` waits for a valid native layout. Do not await it before mounting the View. The path must identify a supported runtime pack, rather than an ordinary mini-program source directory.

On iOS the complete window snapshot comes from the native SDK's `captureWindowMetrics()`; the paired archive must contain that Swift API. The optional `hostLayout` reports View-local safe insets, the resolved physical bar edge, and active occlusion/fold regions. Legacy `safeArea` remains in fixed screen coordinates and is not View padding. iOS 27.1+ samples UIKit traits and reserved regions, using the View's trait `displayScale`; the minimum remains iOS 16.

For a full-window background, let `WeappContainerView` fill the actual render region without wrapping the entire canvas in `SafeArea`. Guest controls use `wx.getWindowInfo().hostLayout` to avoid unsafe regions. Shared guest navigation, back, and close may request host closure through messaging; host failure UI replaces the inactive guest. The container extensions `wx.onHostLayoutChange/offHostLayoutChange` report region changes, while `onResize` reports size changes only.

Same-size layout updates, folding, and rotation preserve the session but invalidate old touches, measurements, and presentation receipts. Submission compares the complete snapshot and retains owner, surface, observation, deadline, and cancellation checks. An absent optional layout clears the old value. Link the final iOS application with iOS 27.1+ SDK; signing and physical-device verification are separate results.

<a id="会话存储和宿主能力"></a>
## Sessions, storage and host capabilities

- Use a stable application/account identity for `storageKey`; pass `null` explicitly for memory-only storage.
- Pass `compatibilityVersion: '0.0.1'` when selecting an SDK compatibility profile. The default profile targets the mini-program base library `3.17.4`; `0.0.0` remains available for regression against the historical `3.17.3` behavior. Unknown versions are rejected, and this value is separate from the container package release.
- Controllers outlive Widgets. Temporary View detach preserves the session, and only one View may attach to a Controller at a time.
- Set `WeappContainerView(foreground: false, ...)` when hiding a mounted feature. The Widget forwards application lifecycle changes.
- When finished with a session, cancel its event subscription and await `close()`. Unmounting a Widget does not close its Controller. Retain ownership and handle retries if closing fails.

```dart
await subscription.cancel();
await controller.flushStorage();
await controller.close();
```

Host methods return JSON-compatible values. Asynchronous handlers should observe `call.cancellation`; use `WeappHostError` for explicit error codes.

Configure login, accounts, networking and device capabilities explicitly in the host: call `configureHostServices`, then optionally `installNativeDeviceApis`, before `load()`. The host controls network origin allowlists and OS permissions. Restricted Showcase runtimes also enforce their compiled policy. See [CONTRACT.md](CONTRACT.en.md) and the [Controller API](weapp_container/lib/src/controller.dart) for configuration and account switching.

<a id="常见问题"></a>
## Troubleshooting

| Symptom | Check |
| --- | --- |
| `load()` keeps waiting | Mount the View with positive width and height |
| Version, digest or target mismatch | Use the exact published SDK version and verify its recorded checksum |
| Android installation or linking fails | minSdk 26, ABI filters, NDK and CMake configuration |
| Windows preparation fails | Confirm x86_64, CMake, the pinned archive checksum and network/cache availability |

Native text editing, full accessibility semantics and advanced gestures still have preview limitations. Validate your integration on the target devices.

<a id="更多资料与许可"></a>
## Documentation and licensing

- [Widget and Controller usage](weapp_container/README.en.md)
- [Complete example](example/lib/main.dart) · [Running the example](example/README.en.md)
- [Desktop integration](native_desktop/README.en.md) · [SDK protocol](CONTRACT.en.md)
- [Public types and C ABI](https://github.com/weapp-container/sdk-contract/blob/main/README.en.md)

The integration source is licensed under [Apache-2.0](LICENSE). Runtime and third-party components retain the `RUNTIME-LICENSE` and notices in their archives. Historical archives retain their supplied licenses and access requirements.

<a id="历史归档与迁移"></a>
## Historical archives and migration

Historical storage: updated downloaders map the nine frozen legacy `runtime-artifacts` versions to the private `weapp-container/runtime-artifacts-private-archive`, retaining original lock bytes, hashes and licenses and recording the resolved repository. Old downloaders must upgrade. The new repository at the old name contains retired tool source only; new runtime releases use the core repository. Private archive access still requires authorization, with no cross-repository fallback.

Historical release audit (2026-11-12): Some default SDK archives are missing and several runtime pins differ from current same-name legacy assets; default online preparation fails integrity checks. Build from matching clean source or explicitly select an independently reviewed matching manifest with `--manifest`; do not merely replace old hashes. See the [audit and migration record](https://github.com/weapp-container/weapp-container/blob/main/docs/runtime-artifacts-migration.en.md).

Runtime packaging and publication now live in the [core repository](https://github.com/weapp-container/weapp-container/tree/main/tools/runtime-artifacts). New manifests select exact core releases through `--manifest`. The default lock retains its historical `runtime-artifacts` source, version, hashes and bundled licenses. The retired repository remains a read-only archive; downloads never fall back between repositories. Private repositories still require read access; source licensing does not imply public binary availability.

The core runtime and SDK source are available under Apache-2.0. Build the current runtime from the [core source guide](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.en.md). Existing prebuilt archives retain their original licenses, access requirements and exact version/hash pins; this source update does not publish replacement binaries.
