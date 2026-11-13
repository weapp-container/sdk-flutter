<a id="weapp-container-platform-interface"></a>
# 小程序容器平台接口

**简体中文** · [English](README.en.md)

当前主分支准备 preview.7 公开发行；只有对应版本在注册源发布后才使用公开安装入口。安装、平台要求与状态见 [SDK 首页](../README.md)。下方源码说明使用 preview.7；从 SDK 首页给出的精确提交构建，并使用同版本运行库。旧锁只用于历史兼容，当前准备工具默认读取版本化的 preview.7 公开锁。


联邦式 Flutter SDK 的内部可注入传输层。应用代码使用 `weapp_container`。方法/事件通道由共享的 `FLUTTER_PROTOCOL.md` 文档化；本包拥有 Dart 运行时时钟，并在初始化前进行订阅。所有实现共享 JSON 数据负载和原生 SDK 错误码。此接口中不会有任何原生指针或位图字节的交叉。
