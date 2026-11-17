<a id="flutter-sdk-consumer"></a>
# Flutter SDK 消费者

**简体中文** · [English](README.en.md)

当前主分支准备 preview.7 公开发行；只有对应版本在注册源发布后才使用公开安装入口。安装、平台要求与状态见 [SDK 首页](../README.md)。下方源码说明使用 preview.7；从 SDK 首页给出的精确提交构建，并使用同版本运行库。旧锁只用于历史兼容，当前准备工具默认读取版本化的 preview.7 公开锁。


该应用程序消耗同级 `packages/weapp_container` 分发包。
移动分发包时需保持 `consumer` 和 `packages` 一同存在。无需进行 Rust 代码检出或 Rust 编译器。请使用 Flutter 3.47.7 稳定版本以及针对目标平台的常规原生开发工具。

```sh
flutter pub get
flutter analyze lib
flutter run -d <device-id>
```

对于 Android，需安装平台 SDK 35 和 36、NDK 27.1.12297006 以及 CMake 3.22.1。应用及其原生插件模块将使用该 NDK。Gradle 包装器锁定版本为 9.4.1 并验证其分发校验和。使用以下命令构建两个支持的 ABIs：

```sh
flutter build apk --debug --target-platform android-arm64,android-x64
```

iOS 要求 iOS 16 或更高版本；macOS 要求 macOS 12 或更高版本。请参考同级分发包 `distribution.json` 中的打包目标。若目标被阻塞，则必须先获取其原生 SDK 产物才能进行构建；本预览版本不包含 Windows 二进制文件。

应用显示一个受限的原生小程序视图。点击其第一个按钮，然后滚动列表以启动其余生命周期、导航、Unicode、宿主方法、重新挂载、重新加载以及持久存储检查。结果将显示在屏幕上，并保存在应用支持目录中的 `sdk-flutter-report.json` 文件中。
自动化运行器和测试用例生成维护在源码独立仓库的 `tools/*-smoke.mjs` 和 `native_desktop/tests` 中。
