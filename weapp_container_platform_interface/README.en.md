<a id="小程序容器平台接口"></a>
# Weapp Container platform interface

[简体中文](README.md) · **English**


Internal injectable transport for the federated Flutter SDK. Application code
uses `weapp_container`. The method/event channels are documented by the shared
`FLUTTER_PROTOCOL.md`; this package owns the Dart runtime epoch and subscribes
before initialization. All implementations share JSON payloads and native SDK
error codes. No native pointers or raster bytes cross this interface.
