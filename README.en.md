# Weapp Container Flutter SDK

Version: `0.1.0-preview.7.0`; C ABI `1`.

Publication status: only the [platform interface](https://pub.dev/packages/weapp_container_platform_interface/versions/0.1.0-preview.7.0) is public. The five platform packages and main package remain unpublished; Android still requires Maven Central credentials and signing. The main-package installation below becomes available after its dependencies are published.

Future interface releases use GitHub OIDC with tags matching `weapp_container_platform_interface-v{{version}}`. Complete `package-pub.yml` at the same clean commit before pushing a new version tag. The publication workflow selects that commit's successful staging artifact, validates it, then freezes and uploads the same archive. To resume an unpublished package manually, use `tools/publish-public.mjs --distribution /absolute/staging --package <name> --execute`; existing public versions are always rejected.

```yaml
dependencies:
  weapp_container: 0.1.0-preview.7.0
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

First public publication is being prepared; registry and device validation results are recorded separately. Historical private locks remain unchanged.

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
| `load()` keeps waiting | Mount the View with positive width and height |
| Version, digest or target mismatch | Use the exact published SDK version and verify its recorded checksum |
| Android installation or linking fails | minSdk 26, ABI filters, NDK and CMake configuration |
| Windows preparation fails | Confirm x86_64, CMake, the pinned archive checksum and network/cache availability |

Native text editing, full accessibility semantics and advanced gestures still have preview limitations. Validate your integration on the target devices.

## Documentation and licensing

- [Widget and Controller usage](weapp_container/README.md)
- [Complete example](example/lib/main.dart) · [Running the example](example/README.md)
- [Desktop integration](native_desktop/README.md) · [SDK protocol](CONTRACT.md)
- [Public types and C ABI](https://github.com/weapp-container/sdk-contract)

The integration source is licensed under [Apache-2.0](LICENSE). Runtime and third-party components retain the `RUNTIME-LICENSE` and notices in their archives. Historical archives retain their supplied licenses and access requirements.
