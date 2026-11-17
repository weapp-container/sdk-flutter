<a id="weapp-容器-ios-实现"></a>
# Weapp Container iOS implementation

[简体中文](README.md) · **English**

The main branch prepares the preview.7 public release. Use public installation only after the version appears in its registry; see the [SDK home](../README.en.md) for installation, requirements, and status. The source instructions below use preview.7. Build the exact checkout linked on the SDK home with same-version runtimes. Old locks remain for historical compatibility; current preparation tools default to the versioned preview.7 public lock.

Federated iOS plugin for `weapp_container`, using UiKitView and public `WeappContainer` Pod `0.1.0-preview.7.0`. Add both `https://github.com/weapp-container/Specs.git` and `https://cdn.cocoapods.org/` to the application Podfile. Minimum iOS is 16; compilation requires Xcode 27.2+. The plugin contains its Swift bridge; the dependency Pod supplies the XCFramework. Consumers need no sibling checkout, Node preparation or Cargo build.
