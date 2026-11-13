<a id="weapp-容器-ios-实现"></a>
# Weapp Container iOS implementation

[简体中文](README.md) · **English**

The main branch prepares the preview.7 public release. Use public installation only after the version appears in its registry; see the [SDK home](../README.en.md) for installation, requirements, and status. The details below retain the pinned preview.6 source contract. Build that version from the exact checkout linked on the SDK home and do not mix it with preview.7 runtimes.


Federated native plugin for `weapp_container`. Uses a UiKitView and the installed
Apple SDK wrapper plus its native universal XCFramework. The distribution builder
includes `ios/vendor/WeappContainer`. Minimum iOS is 16.0. No Cargo build occurs
in a consuming Flutter application.
