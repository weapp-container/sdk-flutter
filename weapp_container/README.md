<a id="weapp-container-for-flutter-preview"></a>
# Flutter 在小程序中的容器（预览版）

**简体中文** · [English](README.en.md)


在 Android、iOS、macOS、Windows 和 Linux 应用中嵌入共享的 QuickJS 小程序运行时和原生渲染器。移动设备使用原生平台的 View 组件；桌面端使用 Flutter 外部纹理。JavaScript、页面状态、存储和宿主调用均保留在共享的原生 SDK 中。没有渲染的图像通过方法通道传递。

使用来自独立 SDK 根目录的 `node tools/package.mjs` 生成的分发包。
其七个包使用相对本地依赖关系，并携带已安装的原生 SDK。消费者无需安装 Rust 或解析此源码检出。`distribution.json` 明确列出了已打包和被阻止的原生目标；仅凭源插件并不能证明某个目标可用。此预览是本地分发包，不是已发布的 pub.dev 包。

```yaml
dependencies:
  weapp_container:
    path: /absolute/path/your-flutter-distribution/packages/weapp_container
```

```dart
final controller = await WeappContainerController.create(
  storageKey: 'account-42:catalog', // null explicitly selects memory-only storage
);
await controller.registerHostMethod('host.profile', (call) async {
  final profile = await fetchProfile();
  call.cancellation.throwIfCancelled();
  return profile;
});
controller.events.listen((event) { /* ready/navigation/message/error/closed */ });
// Mount this widget in a bounded area before awaiting load.
WeappContainerView(controller: controller, onError: reportError);
await controller.load('/verified/local/portable-pack');
await controller.navigate('pages/details/index', query: {'id': '42'});
await controller.sendMessage({'type': 'refresh'});
await controller.flushStorage();
await controller.close();
```

`load` 等待测量到的正向布局。应用程序提取捆绑的资源或下载/验证本地包目录；平台插件不提供其他包解析器。示例展示了资源提取。稳定的存储键用于标识应用程序/账户数据，从不使用运行时 ID 或包哈希。

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
