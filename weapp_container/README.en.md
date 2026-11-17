<a id="weapp-container-for-flutter-preview"></a>
# Weapp Container Flutter SDK

[简体中文](README.md) · **English**

Version: `0.1.0-preview.7.0`; C ABI `1`.

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

Once mounted, load a generated, verified local pack. Extract Flutter assets to application-private storage first; see the [example](https://github.com/weapp-container/sdk-flutter/blob/main/example/lib/main.dart):

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

Configure login, accounts, networking and device capabilities explicitly in the host: call `configureHostServices`, then optionally `installNativeDeviceApis`, before `load()`. The host controls network origin allowlists and OS permissions. Restricted Showcase runtimes also enforce their compiled policy. See [CONTRACT.md](https://github.com/weapp-container/sdk-flutter/blob/main/CONTRACT.en.md) and the [Controller API](https://github.com/weapp-container/sdk-flutter/blob/main/weapp_container/lib/src/controller.dart) for configuration and account switching.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `load()` keeps waiting | Mount the View with positive width and height |
| Version, digest or target mismatch | Use the exact published SDK version and verify its recorded checksum |
| Android installation or linking fails | minSdk 26, ABI filters, NDK and CMake configuration |
| Windows preparation fails | Confirm x86_64, CMake, the pinned archive checksum and network/cache availability |

Native text editing, full accessibility semantics and advanced gestures still have preview limitations. Validate your integration on the target devices.

## Documentation and licensing

- [Widget and Controller usage](https://github.com/weapp-container/sdk-flutter/blob/main/weapp_container/README.en.md)
- [Complete example](https://github.com/weapp-container/sdk-flutter/blob/main/example/lib/main.dart) · [Running the example](https://github.com/weapp-container/sdk-flutter/blob/main/example/README.en.md)
- [Desktop integration](https://github.com/weapp-container/sdk-flutter/blob/main/native_desktop/README.en.md) · [SDK protocol](https://github.com/weapp-container/sdk-flutter/blob/main/CONTRACT.en.md)
- [Public types and C ABI](https://github.com/weapp-container/sdk-contract)

The integration source is licensed under [Apache-2.0](LICENSE). Runtime and third-party components retain the `RUNTIME-LICENSE` and notices in their archives. Historical archives retain their supplied licenses and access requirements.

## Development clients and lifecycle details

Development clients can await `controller.prepareView()` after mounting the
widget to inspect capabilities before the first `load`. This waits for actual
native layout and creates only an empty runtime; it executes no guest code and
does not acknowledge presentation. Keep the widget mounted while waiting and
close a cancelled candidate. Initial startup uses `load`; `applyDevPack` updates
an already loaded session. A staged replacement can remain mounted with
`foreground: false` and input disabled until accepted.

Keep a controller across route/widget detach to retain the JavaScript isolate.
Only one widget may attach to a controller. Widget disposal waits for native
surface/texture retirement before a remount can attach. `close()` is asynchronous
and idempotent; await it to persist and release the session. Native cleanup
failures retain ownership and allow explicit retry.
Close intent immediately retires the mounted View's layout queue; late native
replies cannot acknowledge geometry, update controls or resume preview input.
`controller.closeRequested` remains true if cleanup needs a retry. A successful
layout command or `acceptedHostLayout` event establishes layout acceptance only;
the separate native presentation receipt still controls frame/input readiness.

The widget forwards application lifecycle and its `foreground` property. Set
`foreground: false` when hiding a feature that remains mounted. Completion pumps
continue host replies, cancellation, HTTP and persistence while rendering is
hidden, subject to OS process limits. A new Dart runtime epoch retires old native
sessions before creating new ones; hot reload retains the epoch.

Host method results are JSON values, including null. Throw `WeappHostError` with
`invalid_request`, `permission_denied`, `timeout`, `cancelled` or `unsupported`.
Cancellation is observable through `call.cancellation`; cancelled/stale completions
cannot revive an old generation. Events and method failures preserve SDK codes.

Android requires API 26 and uses explicit Hybrid Composition with the production
SDK AAR. This preview supports `arm64-v8a` and `x86_64`; set the host app's
`android.defaultConfig.ndk.abiFilters` to those two values and build Flutter with
`--target-platform android-arm64,android-x64` so unsupported 32-bit devices are
not offered an incomplete application. The independent consumer applies both.
iOS requires 16 and compiles the shipped Swift wrapper with its universal
native XCFramework; macOS requires 12. The acceptance toolchain is pinned to
Flutter 3.47.7 stable, NDK 27.1.12297006, and Gradle 9.4.1 with its official
distribution checksum. The consumer pins that NDK for its app and native plugin
modules, including transitive JNI dependencies. The builder accepts
`--android-ndk-version` for a host that intentionally validates a different NDK
release.
Desktop plugin availability is recorded in the distribution manifest.
Native text editing/IME, complete accessibility semantics and advanced
gestures remain preview limitations. These are separate from Flutter host UI.

The independent consumer in the generated distribution’s `consumer/` uses the common
acceptance pack. Its accessible `sdk-status` JSON includes real target geometry;
a native tap and scroll unlock async validation for timers, navigation, host
calls, background completion, failed/successful reload, rapid detach/remount and
persistent reopen. It writes `sdk-flutter-report.json` to application support.
