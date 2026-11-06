# Weapp Container Flutter SDK

[简体中文](README.md) | [English](README.en.md)

Embed a mini-program container in a Flutter application. Android and iOS use native Views; desktop platforms use Flutter external textures. One Dart Controller handles local packs, navigation, messages and session ownership.

Current version: `0.1.0-preview.6.0`; native ABI: `1`. This repository contains the Apache-2.0 integration layer. The runtime is a separately authorized binary dependency. Packages currently use local path dependencies and are not published on pub.dev.

## Requirements and platforms

Dependency preparation needs Node.js 24+, Python 3 and your target's native development tools. The distribution script verifies the pinned framework/engine revisions of Flutter **3.47.7**.

| Platform | Minimum OS / architectures | SDK in the default lock |
| --- | --- | --- |
| Android | API 26; arm64-v8a, x86_64 | universal |
| iOS | iOS 16; arm64 device, arm64/x86_64 simulator | universal |
| macOS | macOS 12; arm64, x86_64 | universal |
| Linux | x86_64; see [desktop requirements](native_desktop/README.md) | x86_64 |
| Windows | x86_64 | Unavailable; preparation explicitly fails |

Archive availability, successful client builds and device execution are separate results. After packaging, check `targets` in `distribution.json`.

## 1. Prepare native dependencies

```sh
git clone https://github.com/weapp-container/sdk-flutter.git
cd sdk-flutter
node tools/prepare-native.mjs --platform android --arch universal
```

Before running, provide read access to the private runtime repository through `WEAPP_CONTAINER_RUNTIME_TOKEN`. Alternatively, set `WEAPP_CONTAINER_RUNTIME_ARTIFACT_DIR` or add `--artifact-dir /absolute/archives` to use authorized offline archives. Keep credentials and native archives out of Git.

Prepare only the platforms you need:

```sh
node tools/prepare-native.mjs --platform ios --arch universal
node tools/prepare-native.mjs --platform macos --arch universal
node tools/prepare-native.mjs --platform linux --arch x86_64
```

Preparation verifies the exact version, ABI, architecture, size and SHA-256 in `runtime-artifacts.lock.json`. Select another reviewed distribution of the same version with `--manifest /absolute/reviewed-lock.json`. Missing or mismatched targets never fall back to an older runtime.

## 2. Build a distribution and run the example

Run from a committed standalone checkout that passes source inventory verification:

```sh
node tools/package.mjs --flutter /absolute/flutter/bin/flutter \
  --out /absolute/new-flutter-distribution
cd /absolute/new-flutter-distribution/consumer
flutter run -d DEVICE_ID
```

The output contains `packages/`, `consumer/`, `distribution.json` and `consumer.json`. The example includes an authored test pack for taps, scrolling, navigation, messages, storage and session recreation. Keep `packages/` and `consumer/` together when moving the distribution.

By default the script prepares the example, resolves dependencies and runs static analysis. Add `--platform android`, `ios`, `macos`, `linux` or `windows` to build one client. Building requires its platform toolchain and an available native SDK.

The Android example uses NDK `27.1.12297006`, CMake `3.22.1` and only the two supported ABIs:

```sh
flutter build apk --debug --target-platform android-arm64,android-x64
```

## 3. Add the SDK to your Flutter application

Reference the generated distribution in your application's `pubspec.yaml`. The seven federated packages use relative dependencies, so keep the whole `packages/` directory:

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

On iOS, extents, DPR, safe area, and orientation use the native SDK's `captureWindowMetrics()`; the paired iOS SDK archive must contain that Swift API. Folding, rotation, and window changes use real measurements without model allowlists. Layout submission retains its owner, surface, observation, deadline, and cancellation checks.

## Sessions, storage and host capabilities

- Use a stable application/account identity for `storageKey`; pass `null` explicitly for memory-only storage.
- Controllers outlive Widgets. Temporary View detach preserves the session, and only one View may attach to a Controller at a time.
- Set `WeappContainerView(foreground: false, ...)` when hiding a mounted feature. The Widget forwards application lifecycle changes.
- When finished with a session, cancel its event subscription and await `close()`. Unmounting a Widget does not close its Controller. Retain ownership and handle retries if closing fails.

```dart
await subscription.cancel();
await controller.flushStorage();
await controller.close();
```

Host methods return JSON-compatible values. Asynchronous handlers should observe `call.cancellation`; use `WeappHostError` for explicit error codes.

Configure login, accounts, networking and device capabilities explicitly in the host: call `configureHostServices`, then optionally `installNativeDeviceApis`, before `load()`. The host controls network origin allowlists and OS permissions. Restricted Showcase runtimes also enforce their compiled policy. See [CONTRACT.md](CONTRACT.md) and the [Controller API](weapp_container/lib/src/controller.dart) for configuration and account switching.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Missing native SDK / vendor files | Run `prepare-native.mjs` for the platform before packaging |
| `load()` keeps waiting | Mount the View with positive width and height |
| Version, digest or target mismatch | Use authorized archives and a reviewed lock matching this source |
| Android installation or linking fails | minSdk 26, ABI filters, NDK and CMake configuration |
| Windows preparation fails | The default lock has no Windows SDK; provide a separately reviewed same-version distribution |

Native text editing, full accessibility semantics and advanced gestures still have preview limitations. Validate your integration on the target devices.

## Documentation and licensing

- [Widget and Controller usage](weapp_container/README.md)
- [Complete example](example/lib/main.dart) · [Running the example](example/README.md)
- [Desktop integration](native_desktop/README.md) · [SDK protocol](CONTRACT.md)
- [Public types and C ABI](https://github.com/weapp-container/sdk-contract)

The integration source is licensed under [Apache-2.0](LICENSE). Runtime and third-party components retain the `RUNTIME-LICENSE` and notices in their archives. This repository's open-source license does not grant private runtime downloads or additional commercial rights.
