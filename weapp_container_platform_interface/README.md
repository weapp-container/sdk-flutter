<a id="weapp-container-platform-interface"></a>
# 小程序容器平台接口

**简体中文** · [English](README.en.md)


联邦式 Flutter SDK 的内部可注入传输层。应用代码使用 `weapp_container`。方法/事件通道由共享的 `FLUTTER_PROTOCOL.md` 文档化；本包拥有 Dart 运行时时钟，并在初始化前进行订阅。所有实现共享 JSON 数据负载和原生 SDK 错误码。此接口中不会有任何原生指针或位图字节的交叉。
