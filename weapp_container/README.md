<a id="weapp-container-for-flutter-preview"></a>
# Weapp Container Flutter SDK

**简体中文** · [English](README.en.md)

版本： `0.1.0-preview.7.0`；C ABI `1`。

```yaml
dependencies:
  weapp_container: 0.1.0-preview.7.0
```

```sh
flutter pub get
```

Android API 26+；iOS 16+；macOS 12+ universal；Linux / Windows x86_64。Flutter 3.22+ / Dart 3.3+。Android 通过 Maven Central 获取依赖；iOS 和 macOS 使用公开 CocoaPods Specs，请在对应 Podfile 中添加两个源：

```ruby
source 'https://github.com/weapp-container/Specs.git'
source 'https://cdn.cocoapods.org/'
```

Linux / Windows 通过 CMake 下载固定版本的 Desktop 归档并校验 SHA-256。离线构建时，提前下载并校验该归档，将 `FETCHCONTENT_SOURCE_DIR_WEAPP_CONTAINER_RUNTIME` 指向解压目录。每个平台包包含桥接源码、头文件和许可，普通安装无需 Node 准备命令或兄弟仓库。

首次公开发布正在准备中；注册源发布和设备验证结果分别记录，历史私有锁文件保留原样。

先创建 Controller，并在首次 `load` 前注册宿主方法和事件。以下代码由页面或路由的会话管理逻辑执行，不放在 `build()` 中：

```dart
import 'package:flutter/material.dart';
import 'package:weapp_container/weapp_container.dart';

final controller = await WeappContainerController.create(
  storageKey: 'account-42:catalog',
);
await controller.registerHostMethod('host.echo', (call) async {
  call.cancellation.throwIfCancelled();
  return {'value': call.payload};
});
final subscription = controller.events.listen((event) {
  if (event.type == 'message') debugPrint('${event.message}');
}, onError: (Object error, StackTrace stack) {
  debugPrint('$error');
});
```

把 View 挂载到具有正数宽高的区域，使用上面创建的同一个 Controller：

```dart
SizedBox(
  height: 480,
  child: WeappContainerView(
    controller: controller,
    onError: (error, stack) => debugPrint('$error'),
  ),
)
```

View 挂载后加载已生成并校验的本地 pack。Flutter assets 需要先解包到应用私有目录，具体做法见[示例](https://github.com/weapp-container/sdk-flutter/blob/main/example/lib/main.dart)：

```dart
await controller.load('/verified/local/portable-pack');
await controller.navigate('pages/detail/index', query: {'id': '42'});
await controller.sendMessage({'type': 'refresh'});
await controller.back();
```

`load()` 会等待有效的原生布局，不要在挂载 View 前等待它完成。路径应指向运行库支持的 pack，不能直接传入普通小程序源码目录。

iOS 的完整窗口快照统一由原生 SDK 的 `captureWindowMetrics()` 读取，配套归档必须包含此 Swift API。新增 `hostLayout` 保留 View 局部安全边距、系统解析后的物理侧栏边缘，以及活动遮挡／折叠区域；原有 `safeArea` 继续使用屏幕固定坐标，不能直接作为 View 的 padding。iOS 27.1+ 读取 UIKit traits 和保留区域，倍率取 View 的 `displayScale`；最低版本仍为 iOS 16。

需要全屏背景时让 `WeappContainerView` 填满实际渲染区域，不给整张画布额外套 `SafeArea`。业务控件通过小程序 `wx.getWindowInfo().hostLayout` 避让；导航、返回、关闭可以由共享页面负责，再用消息请求宿主关闭。宿主失败 UI 应替换已停止交互的容器。`wx.onHostLayoutChange/offHostLayoutChange` 是布局区域变化的容器扩展；`onResize` 只表示尺寸变化。

同尺寸布局变化、折叠和旋转保留会话，但旧触摸、测量和呈现回执不再有效。提交继续比较完整快照并校验原有 owner、surface、observation、期限与取消边界；缺失可选布局会清除旧值。最终 iOS App 需链接 iOS 27.1+ SDK，签名与真机验证单独记录。

## 会话、存储和宿主能力

- 用稳定的应用/账号标识作为 `storageKey`；传 `null` 显式选择纯内存存储。
- Controller 独立于 Widget 存活。临时卸载 View 可保留会话，同一 Controller 同时只能绑定一个 View。
- 页面隐藏但仍挂载时，设置 `WeappContainerView(foreground: false, ...)`；Widget 负责转发应用生命周期。
- 不再复用会话时，取消事件订阅并等待 `close()` 完成。卸载 Widget 本身不会关闭 Controller；关闭失败需要由宿主保留引用并处理重试。

```dart
await subscription.cancel();
await controller.flushStorage();
await controller.close();
```

宿主方法只返回 JSON 可表示的值。异步方法应观察 `call.cancellation`，错误可使用 `WeappHostError` 返回明确的代码。

登录、账号、网络和设备能力通过宿主显式配置：在 `load()` 前先调用 `configureHostServices`，再按需调用 `installNativeDeviceApis`。网络 origin 白名单和系统权限由宿主管理；受限 Showcase 运行库仍按编译时策略限制能力。配置和账号切换协议见 [CONTRACT.md](https://github.com/weapp-container/sdk-flutter/blob/main/CONTRACT.md) 与 [Controller API](https://github.com/weapp-container/sdk-flutter/blob/main/weapp_container/lib/src/controller.dart)。

## 常见问题

| 现象 | 检查项 |
| --- | --- |
| `load()` 一直等待 | View 是否已挂载、是否具有正数宽高 |
| 版本、哈希或目标不匹配 | 使用本次精确公开版本，并核对归档校验和 |
| Android 安装或链接失败 | minSdk 26、ABI 过滤器、NDK 和 CMake 配置 |
| Windows 无法准备 | 检查 x86_64、CMake、固定归档校验和与网络／缓存 |

原生文本输入、完整无障碍语义与高级手势仍有 preview 限制，接入前应在目标设备验证。

## 更多资料与许可

- [Widget 与 Controller 用法](https://github.com/weapp-container/sdk-flutter/blob/main/weapp_container/README.md)
- [完整示例](https://github.com/weapp-container/sdk-flutter/blob/main/example/lib/main.dart) · [示例运行说明](https://github.com/weapp-container/sdk-flutter/blob/main/example/README.md)
- [桌面接入](https://github.com/weapp-container/sdk-flutter/blob/main/native_desktop/README.md) · [SDK 协议](https://github.com/weapp-container/sdk-flutter/blob/main/CONTRACT.md)
- [公共类型和 C ABI](https://github.com/weapp-container/sdk-contract)

接入层源码使用 [Apache-2.0](LICENSE)。运行库和第三方组件遵循归档中的 `RUNTIME-LICENSE` 及 notices；历史归档保留各自随附的许可和访问要求。

## 开发客户端与生命周期细节

开发客户端可以在挂载控件后等待`controller.prepareView()`，在首次`load`之前检查能力。这会等待实际的原生布局，并仅创建一个空的运行时；它不会执行客套代码，也不会确认呈现。在等待期间保持控件挂载，并在取消候选时关闭控件。初始启动使用`load`；`applyDevPack`会更新已加载的会话。一个分阶段的替换可以在`foreground: false`且输入已禁用的情况下保持挂载，直到被接受。

保持控制器在路由/小部件解绑时不变，以保留 JavaScript 隔离环境。
只有一个小部件可以附加到一个控制器上。小部件销毁会等待原生绘制表面/纹理退役后，才能重新挂载。`close()` 是异步且幂等的；需等待其完成以持久化并释放会话。原生清理失败将保留所有权，并允许显式重试。
关闭意图会立即退役已挂载视图的布局队列；延迟的原生回复无法确认几何信息、更新控件或恢复预览输入。如果清理需要重试，`controller.closeRequested` 保持为 true。一次成功的布局命令或 `acceptedHostLayout` 事件仅建立布局验收；独立的原生呈现回执仍控制帧/输入的就绪状态。

该小部件转发应用生命周期及其 `foreground` 属性。当隐藏一个保持挂载的特性时，设置 `foreground: false`。完成泵在渲染被隐藏时继续处理宿主回复、取消、HTTP 以及持久化操作，但受操作系统进程限制。新的 Dart 运行时周期在创建新会话前会终止旧的原生会话；热重载保留该周期。

宿主方法的结果是 JSON 值，包括 null。抛出 `WeappHostError`，错误类型为 `invalid_request`、`permission_denied`、`timeout`、`cancelled` 或 `unsupported`。取消操作可通过 `call.cancellation` 观察到；已取消/过时的完成操作无法恢复旧一代。事件和方法失败保持 SDK 错误码。

Android 要求 API 26，并使用生产 SDK AAR 的显式混合合成。此预览版本支持 `arm64-v8a` 和 `x86_64`；将宿主应用的 `android.defaultConfig.ndk.abiFilters` 设置为这两个值，并使用 `--target-platform android-arm64,android-x64` 构建 Flutter，以确保不向不支持的 32 位设备提供不完整的应用。独立的消费者需应用此设置。
iOS 要求版本 16，并使用其通用原生 XCFramework 编译内置的 Swift 包装器；macOS 要求版本 12。验收工具链固定在 Flutter 3.47.7 稳定版、NDK 27.1.12297006 和 Gradle 9.4.1（含官方分发校验和）。消费者会为其应用和原生插件模块（包括传递的 JNI 依赖）固定该 NDK。构建器接受 `--android-ndk-version` 以支持宿主明确验证不同 NDK 版本。
桌面插件的可用性记录在分发清单中。原生文本编辑/输入法、完整的可访问性语义和高级手势仍属于预览限制。这些与 Flutter 宿主 UI 无关。

生成的分布中的独立消费者在 `consumer/` 目录中使用通用验收包。其可访问的 `sdk-status` JSON 包含实际的目标几何信息；支持原生点击和滚动解锁异步验证，用于定时器、导航、宿主调用、后台完成、重载失败/成功、快速解绑/重新挂载以及持久重开。它将 `sdk-flutter-report.json` 写入应用程序支持目录。
