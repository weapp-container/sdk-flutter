# Flutter desktop native support

The three desktop implementations share this engine-owned registry. Platform
threads exclusively own runtime handles; raster callbacks see immutable frame
leases (Windows/Linux) or completed IOSurface pixel buffers (macOS Metal).
Pixels never traverse a Flutter method channel.

Before installing the local federated package tree, prepare each target from its
installed native desktop SDK distribution:

```sh
node native_desktop/prepare.mjs --target macos --from /path/to/macos-universal
node native_desktop/prepare.mjs --target windows --from C:/path/to/windows-x64
node native_desktop/prepare.mjs --target linux --from /path/to/linux-x64
```

The command copies the core archive, C header, notices and common source into
that plugin package. Distribute the prepared directory tree, including generated
`vendor` and `native_shared` directories. A consuming project needs no repository
checkout or Rust toolchain. Public registry publication is outside this preview.
Preparation requires a verified `0.1.0-preview.2` native package receipt with
clean source commits for the package and every native slice. It checks the core
archive SHA256, clears old generated files, and preserves the complete receipt
and archive hash in `vendor/prepared.json`.

macOS uses Metal directly into CVPixelBuffer IOSurfaces, fences the same GPU
queue before publishing, and completes retirement only when Flutter releases its
last reference to the texture object. This also supports macOS engine versions
that omit the optional unregister notification.
Linux channel payloads use JSON UTF-8 byte envelopes because Flutter Linux
FlValue strings cannot preserve embedded NUL bytes. The public Dart API remains
JSON values on every platform.
Windows pins each native frame until the engine's pixel-buffer release callback
and awaits asynchronous unregister completion. Linux has no public raster
retirement fence: its registrar returns a borrowed GObject and unregister can
still be queued. An engine-owned pool retains GObjects at the concurrent texture
high-water mark and reuses their slots. Each slot retains its last raster reader
until the next copy callback or engine shutdown; native sessions still close
immediately. Retire and reacquire clear the producer mailbox, and an immutable
transparent 1×1 frame covers the valid interval before the first render. Flutter
shuts down its raster tasks before releasing the messenger handlers that own
the pool. No guessed delay is used as a resource-lifetime boundary.

All platforms cancel pending layout loads during close, keep service pumping
while hidden, and complete a new Dart epoch only after old session storage and
textures retire. A failed pack load restores the prior surface and session.

Failure recovery preserves ownership: close returns a native destruction error
and allows retry; engine teardown retains unfinished resources in a platform
thread cleanup task until GPU/texture/session retirement succeeds. Errors remain
visible in the platform log. It never terminates the host to handle cleanup.

The tests include `registry_failures.cpp` (fault-injected retirement),
`prepare_receipts.mjs` (native provenance, hash rejection and clean restaging),
`macos_texture.mm` (real QuickJS/Skia/Metal with an instrumented Flutter registrar)
and `engine_consumer.dart` (real Flutter engine, external texture pixel snapshot,
channels, durable storage, navigation, hidden pumping and epoch replacement).
`tests/run-public-linux.mjs` relocates the prepared public Flutter distribution,
builds its Widget/Controller consumer, and runs all ten acceptance checks using
X11 pointer input under Xvfb. It records input coordinates, screenshots, source
and binary hashes, and normal GTK window/engine shutdown. Dependencies are
Flutter 3.47.7, GTK development libraries, Xvfb, xdotool, ImageMagick and Python 3.
This check covers X11; Wayland needs separate acceptance on a Wayland session.
macOS requires version 12.0 or newer, matching the native SDK archive.
Flutter 3.47.7 currently builds the macOS plugin through CocoaPods; Swift Package
Manager packaging is not included in this preview.
