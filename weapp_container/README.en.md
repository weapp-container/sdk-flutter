<a id="flutter-在小程序中的容器预览版"></a>
# Weapp Container for Flutter (preview)

[简体中文](README.md) · **English**

The main branch prepares the preview.7 public release. Use public installation only after the version appears in its registry; see the [SDK home](../README.en.md) for installation, requirements, and status. The details below retain the pinned preview.6 source contract. Build that version from the exact checkout linked on the SDK home and do not mix it with preview.7 runtimes.


Embed the shared QuickJS mini-program runtime and native renderer in Android,
iOS, macOS, Windows and Linux applications. Mobile uses native platform Views;
desktop uses Flutter external textures. JavaScript, page state, storage and host
calls remain in the shared native SDK. No rendered images cross method channels.

Use the generated distribution from `node tools/package.mjs` from the standalone SDK root.
Its seven packages use relative local dependencies and carry the installed
native SDKs. The consumer does not install Rust or resolve this source checkout.
`distribution.json` explicitly lists packaged and blocked native targets; a
source plugin alone is not evidence that a target is usable. This preview is a
local distribution, not a published pub.dev package.

```yaml
dependencies:
  weapp_container:
    path: /absolute/path/your-flutter-distribution/packages/weapp_container
```

```dart
final controller = await WeappContainerController.create(
  storageKey: 'account-42:catalog', // null explicitly selects memory-only storage
);
await controller.registerHostMethod('host.profile', (call) async {
  final profile = await fetchProfile();
  call.cancellation.throwIfCancelled();
  return profile;
});
controller.events.listen((event) { /* ready/navigation/message/error/closed */ });
// Mount this widget in a bounded area before awaiting load.
WeappContainerView(controller: controller, onError: reportError);
await controller.load('/verified/local/portable-pack');
await controller.navigate('pages/details/index', query: {'id': '42'});
await controller.sendMessage({'type': 'refresh'});
await controller.flushStorage();
await controller.close();
```

`load` waits for positive measured layout. The application extracts bundled
assets or downloads/verifies a local pack directory; platform plugins do not
provide another pack parser. The example shows asset extraction. Stable storage
keys identify application/account data, never runtime IDs or pack hashes.

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
