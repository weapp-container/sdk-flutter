<a id="公共-flutter-宿主生命周期验证"></a>
# Public Flutter host lifecycle acceptance

[简体中文](host-lifecycle.md) · **English**


`host_lifecycle_consumer.dart` is an independent interactive harness for the public
`WeappContainerController` and `WeappContainerView`. It uses the same portable
fixture and asset index as the packaged SDK consumer, but tests Flutter host
navigation and parent scrolling. The standard consumer's `navigate-back` check
covers mini-program navigation, so it does not replace this harness.

<a id="准备与构建"></a>
## Prepare and build

1. Prepare a clean distribution with the repository SDK tooling. Keep its
   `distribution.json` and platform build receipts.
2. Copy its `consumer` and sibling `packages` into a new evidence directory. Keep
   their relative layout and exclude generated `build`, `.dart_tool`, and platform
   `ephemeral` directories. Do not modify the prepared distribution in place.
3. Replace only the cloned `consumer/lib/main.dart` with
   `host_lifecycle_consumer.dart`. Keep its assets and `pubspec.yaml` unchanged.
4. With pinned Flutter 3.47.7, run `flutter pub get --offline`,
   `flutter analyze lib --no-pub`, and the appropriate debug build. Record the
   distribution hash, harness hash, package source hashes, toolchain revisions,
   and produced executable hash. If testing a candidate fix, label the package
   patch explicitly rather than presenting the old manifest as its identity.

The harness supports macOS, Windows, Linux, Android, and iOS. A build or run on one
platform is not evidence for another. Desktop presentation identity is the actual
Flutter `Texture` ID. Mobile records `AndroidViewSurface` / `UiKitView` count.

<a id="交互操作"></a>
## Interact

Use the real platform UI and collect screenshots plus the report after each
milestone. Input coordinates must come from the current `viewOrigin`, `viewSize`,
and native `geometry` fields; account for the window title bar and pixel ratio.
Do not issue native pointer methods directly to substitute for UI input.

1. At `scroll-parent-then-check`, scroll or drag the yellow Flutter header until
   `parentOffset` is at least 20 logical pixels, then press **Check parent**.
2. At `click-child-after-parent-scroll`, tap the native target at `geometry.tap`
   inside the moved view. The harness requires a real native tap event.
3. At `scroll-child`, scroll or drag inside `geometry.scroll`. The harness records
   native `scrollTop` and the parent offset after input settles. A parent offset
   change over one logical pixel is an issue; it continues to test navigation so
   the failure does not hide later lifecycle observations.
4. On desktop, press **Test drag** at `arm-child-drag`, then drag upward inside
   the native scroll area at `drag-child`. The child must advance its scroll
   offset while the parent stays in place. Mobile already uses a real touch drag
   for its first child scrolling step.
5. Press **Move route**. The first widget is disposed and its surface must retire
   before `Navigator.push` creates a second widget with the same controller.
6. At `pop-flutter-route`, use the visible Flutter back button. The second
   presentation must retire before the first route recreates its widget. Session
   ID and generation must match throughout.
7. At `ready-to-close`, press **Close SDK**. Exactly one presentation must exist
   before closing and none afterward. The public controller must report closed.
8. The final report must have `stage: complete`, `status: passed`, no errors or
   issues, and all ten desktop checks (eight on mobile). Save it, close the test window, and verify a normal
   process exit. Keep failed-run evidence when validating a repair.

The report is written to `sdk-flutter-host-lifecycle.json` in
`getApplicationSupportDirectory()` and also exposed as a semantics label on the
primary route. Its native history records surface retirement and reattachment;
texture IDs may be reused after retirement and need not be globally unique.
Linux and Windows use CPU pixel-buffer textures, so their native `surface` stays
null while active. They require one live Flutter Texture and foreground state;
retirement requires foreground false. GPU platforms additionally require a native
surface while attached.

<a id="真实的-flutter-热重启"></a>
## True Flutter hot restart

This harness does not claim hot restart coverage. For that check, launch a debug
public consumer, keep a live native presentation mounted, attach the pinned
Flutter tool, and request `app.restart` with `fullRestart: true` through its machine
protocol (or use the Flutter tool's interactive full restart command). Capture
`getVM` before and after: the process PID must stay unchanged and the main Dart
isolate ID must change. Then repeat real native input and close checks. Manually
calling the SDK `initialize` method with a new client epoch is useful native
coverage but is not an actual Flutter hot restart.

<a id="linux-x11-自动化"></a>
## Linux X11 automation

`run-public-linux.mjs` clones the specified distribution into a new directory,
records source and binary hashes, builds with the pinned toolchain, and starts its
own Xvfb display. Its input runner selects only the window belonging to the child
process, waits for GTK mapping, focuses it, and uses real XTest pointer input.
Normal shutdown sends `WM_DELETE_WINDOW`; forced cleanup makes the run fail.

```sh
node native_desktop/tests/run-public-linux.mjs \
  --distribution /absolute/path/prepared-flutter-distribution \
  --flutter /opt/flutter --out /absolute/path/new-evidence/linux-host \
  --host-lifecycle

node native_desktop/tests/run-public-linux.mjs \
  --distribution /absolute/path/prepared-flutter-distribution \
  --flutter /opt/flutter --out /absolute/path/new-evidence/linux-restart \
  --hot-restart
```

`--host-lifecycle` selects the ten-check host harness. `--hot-restart` selects the
standard consumer and adds a real Flutter machine-protocol full restart between
its first native click and subsequent input. It records process and isolate
identities, detaches the Flutter tool, then requires the normal ten consumer
checks. Use separate output directories for separate attempts. Linux X11 results
do not establish Wayland or other operating-system coverage.
