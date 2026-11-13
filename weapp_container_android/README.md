<a id="weapp-container-android-implementation"></a>
# Weapp 容器 Android 实现

**简体中文** · [English](README.en.md)

当前主分支准备 preview.7 公开发行；只有对应版本在注册源发布后才使用公开安装入口。安装、平台要求与状态见 [SDK 首页](../README.md)。下方源码说明使用 preview.7；从 SDK 首页给出的精确提交构建，并使用同版本运行库。旧锁只用于历史兼容，当前准备工具默认读取版本化的 preview.7 公开锁。

`weapp_container` 的联邦 Android 插件，通过 Maven Central 依赖 `io.github.weapp-container:weapp-container-android:0.1.0-preview.7.0`。最低 Android API 为 26。普通应用无需准备兄弟仓库、Node 或 Cargo；`weappSdkMavenDir` 仅用于显式本地构建验证。
