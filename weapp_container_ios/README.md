<a id="weapp-container-ios-implementation"></a>
# Weapp 容器 iOS 实现

**简体中文** · [English](README.en.md)

当前主分支准备 preview.7 公开发行；只有对应版本在注册源发布后才使用公开安装入口。安装、平台要求与状态见 [SDK 首页](../README.md)。下方源码说明使用 preview.7；从 SDK 首页给出的精确提交构建，并使用同版本运行库。旧锁只用于历史兼容，当前准备工具默认读取版本化的 preview.7 公开锁。


`weapp_container` 的联邦原生插件。使用 UiKitView 和已安装的 Apple SDK 包装器，以及其原生通用 XCFramework。分发构建器包含 `ios/vendor/WeappContainer`。最低 iOS 版本为 16.0。在消费的 Flutter 应用中不会执行 Cargo 构建。
