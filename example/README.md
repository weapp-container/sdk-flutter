<a id="flutter-sdk-consumer"></a>
# Flutter SDK 消费者

**简体中文** · [English](README.en.md)

此应用通过 path dependency 使用同仓库的 `../weapp_container`，并从 `assets/portable-pack` 加载示例 pack。公开 Flutter SDK 为 `0.1.0-preview.7.1`，仍是预览版。pub.dev 安装方式和平台状态见 [SDK README](../README.md)；Apple 平台的原生归档限制见[公开发行状态](https://github.com/weapp-container/weapp-container/blob/main/docs/public-sdk-release.md)。

## 运行示例

在 `example/` 目录执行以下命令：

```sh
flutter create --platforms=android,ios,macos,linux,windows .
flutter pub get
flutter analyze lib
flutter run -d <device-id>
```

Android 工程生成后，在 `android/app/build.gradle.kts` 的 `defaultConfig` 中设置 `minSdk = 26`。这是 `weapp_container_android` 的最低支持版本；`tools/package.mjs` 生成的分发工程会自动写入该值。

示例覆盖原生 View、点击和滚动、导航、消息、宿主方法、前后台状态、失败重载、持久化重开及重复关闭。运行结果显示在屏幕上，并写入应用支持目录中的 `sdk-flutter-report.json`。

需要生成或刷新测试 pack 及其 `fixture-index.json` 时，在 `example/` 目录执行：

```sh
node shared/make-fixture.mjs --out assets/portable-pack
```

可选的 C ABI fixture 检查需要运行库、pack 和报告路径：

```sh
python3 shared/verify-fixture.py <shared-library> assets/portable-pack <report-path>
```

## 平台构建

仓库工作流固定使用 Flutter 3.47.7。Android 构建需要 Android SDK 35 和 36、NDK `27.1.12297006`、CMake 3.22.1；使用以下命令构建 arm64 与 x86_64：

```sh
flutter build apk --debug --target-platform android-arm64,android-x64
```

iOS 最低部署目标为 iOS 16，macOS 最低为 macOS 12。当前预览版中，iOS/macOS Podspec 引用的独立 SDK 归档不可用，需按[源码构建指南](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.md)准备对应原生 SDK。Linux 与 Windows 使用 Desktop CMake 归档，并需要目标系统工具链。每个目标的构建、模拟器和设备验收分别记录。

## 维护位置

Flutter example 位于本仓库的 `example/`。共享 fixture 生成器位于 `example/shared/`；原生 Desktop consumer 与其自动化位于 `native_desktop/`。
