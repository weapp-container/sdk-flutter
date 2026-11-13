<a id="小程序容器平台接口"></a>
# Weapp Container platform interface

[简体中文](README.md) · **English**

The main branch prepares the preview.7 public release. Use public installation only after the version appears in its registry; see the [SDK home](../README.en.md) for installation, requirements, and status. The details below retain the pinned preview.6 source contract. Build that version from the exact checkout linked on the SDK home and do not mix it with preview.7 runtimes.


Internal injectable transport for the federated Flutter SDK. Application code
uses `weapp_container`. The method/event channels are documented by the shared
`FLUTTER_PROTOCOL.md`; this package owns the Dart runtime epoch and subscribes
before initialization. All implementations share JSON payloads and native SDK
error codes. No native pointers or raster bytes cross this interface.
