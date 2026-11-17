<a id="weapp-容器-android-实现"></a>
# Weapp Container Android implementation

[简体中文](README.md) · **English**

The main branch prepares the preview.7 public release. Use public installation only after the version appears in its registry; see the [SDK home](../README.en.md) for installation, requirements, and status. The source instructions below use preview.7. Build the exact checkout linked on the SDK home with same-version runtimes. Old locks remain for historical compatibility; current preparation tools default to the versioned preview.7 public lock.

Federated Android plugin for `weapp_container`, using Maven Central dependency `io.github.weapp-container:weapp-container-android:0.1.0-preview.7.0`. Minimum Android API is 26. Ordinary applications need no sibling checkout, Node preparation or Cargo build; `weappSdkMavenDir` is only an explicit local build-test override.
