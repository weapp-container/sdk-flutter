# Weapp Container Flutter SDK

**简体中文** · [English](README.en.md)

<a id="public-distribution-candidate-preview7"></a>
## 公开发行候选：preview.7

下列安装示例描述 preview.7 发行候选，使用前须确认对应注册源或 Release 已提供该版本；源码公开不代表包已发布或设备验收完成。本文后续源码构建示例使用下面固定的 preview.6 checkout。当前核心构建器仍输出 preview.6，不要将该运行库与 preview.7 包装层混用。

版本 / Version: `0.1.0-preview.7.0`；C ABI `1`。

```yaml
dependencies:
  weapp_container: 0.1.0-preview.7.0
```

```sh
flutter pub get
```

Android API 26+；iOS 16+；macOS 12+ universal；Linux / Windows x86_64。Flutter 3.22+ / Dart 3.3+。Android 使用 Maven Central；iOS 与 macOS 使用公开 CocoaPods 规格，在各 Apple Podfile 中添加两个来源：

```ruby
source 'https://github.com/weapp-container/Specs.git'
source 'https://cdn.cocoapods.org/'
```

Linux / Windows 的 CMake 下载固定 Desktop 归档并验证 SHA-256。离线构建需预先获取精确归档，将 `FETCHCONTENT_SOURCE_DIR_WEAPP_CONTAINER_RUNTIME` 设为解压目录。各平台包包含桥接源码、头文件和许可，普通应用安装无需 Node 准备命令或兄弟仓库。

首次公开发行正在准备；注册源发布和设备验证分别记录，历史私有锁保持原样。

<a id="reviewed-source-build-checkout"></a>
### 已复核的源码构建版本

```sh
git clone https://github.com/weapp-container/sdk-flutter.git sdk-flutter-source
cd sdk-flutter-source
git checkout 2a6a2f0096b894e69d7049064d87072d8e5b3901
```



[开发文档](https://container.weapp.dev/docs/) · [源码构建](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.md) · [API 与协议](https://github.com/weapp-container/sdk-contract/blob/main/README.md)

在 Flutter 应用中嵌入小程序容器。Android、iOS 使用原生 View，桌面端使用 Flutter 外部纹理；同一个 Dart Controller 负责加载本地 pack、导航、收发消息和管理会话。

已复核源码示例版本：`0.1.0-preview.6.0`，原生 ABI：`1`。本仓库提供 Apache-2.0 许可的接入层，运行库从公开核心源码构建，或使用另行核验的配套归档。当前使用本地路径依赖，尚未发布到 pub.dev。

<a id="start-from-current-source"></a>
## 从当前源码开始

首次接入优先使用公开的核心仓库及其固定 SDK 提交，不需要历史归档的下载 token：

```sh
git clone --recurse-submodules https://github.com/weapp-container/weapp-container.git
cd weapp-container
corepack enable
pnpm install --frozen-lockfile
node sdk/contract/fixtures/make-acceptance-pack.mjs --out artifacts/hello-pack
```

随后按[源码构建说明](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.md)准备目标平台的运行库和 notices，再用本仓库的构建工具生成接入包。平台工具链仍是必要依赖；源码公开不表示公共包仓库已有可下载的二进制。已有原生小程序或框架构建产物可以由独立 portable pack 工具打包，不要求 weapp-vite。

下面保留独立 SDK 的安装、视图与生命周期说明。涉及 `prepare-runtime` / `prepare-native` 的命令属于显式归档路径，必须使用核验过的配套 manifest；历史默认锁可能无法下载，详见文末说明。

<a id="requirements-and-platforms"></a>
## 环境与平台

准备依赖需要 Node.js 24+、Python 3 和目标平台的原生开发工具。分发脚本校验 Flutter **3.47.7** 的固定 framework/engine 版本。

| 平台 | 最低系统 / 架构 | 默认 lock 中的 SDK |
| --- | --- | --- |
| Android | API 26；arm64-v8a、x86_64 | universal |
| iOS | iOS 16；arm64 真机、arm64/x86_64 模拟器 | universal |
| macOS | macOS 12；arm64、x86_64 | universal |
| Linux | x86_64；依赖见[桌面说明](native_desktop/README.md) | x86_64 |
| Windows | x86_64 | 暂无，准备时会明确失败 |

原生归档可用、客户端构建成功和设备运行通过是不同状态。生成分发包后，以 `distribution.json` 的 `targets` 为准。

<a id="1-prepare-native-dependencies"></a>
## 1. 准备原生依赖

```sh
# Run at the core checkout root after creating a reviewed local manifest.
node sdk/flutter/tools/prepare-native.mjs --platform android --arch universal \
  --manifest artifacts/local-release/manifest.json --artifact-dir artifacts/local-release
```

先按[源码构建说明](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.md)构建对应 SDK，并生成本地 `manifest.json` 和归档。上面的命令在核心仓库根目录消费这些本地输入，不需要历史归档 token。路径按实际输出调整，不要提交原生归档。

按目标选择命令，无需准备全部平台：

```sh
node sdk/flutter/tools/prepare-native.mjs --platform ios --arch universal \
  --manifest artifacts/local-release/manifest.json --artifact-dir artifacts/local-release
node sdk/flutter/tools/prepare-native.mjs --platform macos --arch universal \
  --manifest artifacts/local-release/manifest.json --artifact-dir artifacts/local-release
node sdk/flutter/tools/prepare-native.mjs --platform linux --arch x86_64 \
  --manifest artifacts/local-release/manifest.json --artifact-dir artifacts/local-release
```

工具按显式清单精确校验版本、ABI、架构、大小和 SHA-256；缺少或不匹配的目标不会回退到旧运行库。默认 `runtime-artifacts.lock.json` 属于历史兼容输入，不是首次接入路径。

<a id="2-build-a-distribution-and-run-the-example"></a>
## 2. 生成分发包并运行示例

在核心仓库根目录执行；固定的 SDK 子模块须已提交并通过源码清单校验：

```sh
pnpm sdk:build:flutter -- --platform android --flutter /absolute/flutter/bin/flutter \
  --manifest artifacts/local-release/manifest.json \
  --out /absolute/new-flutter-distribution
cd /absolute/new-flutter-distribution/consumer
flutter run -d DEVICE_ID
```

输出包括 `packages/`、`consumer/`、`distribution.json` 和 `consumer.json`。示例包含本仓库生成的测试 pack，可体验点击、滚动、导航、消息、存储和会话重建。移动分发目录时，保留 `packages/` 与 `consumer/` 的相对关系。

脚本默认准备示例、解析依赖并执行静态分析；追加 `--platform android`、`ios`、`macos`、`linux` 或 `windows` 可构建指定客户端。构建需要对应平台工具链和可用的原生 SDK。

Android 示例使用 NDK `27.1.12297006`、CMake `3.22.1`，仅包含两个受支持的 ABI：

```sh
flutter build apk --debug --target-platform android-arm64,android-x64
```

<a id="3-add-the-sdk-to-your-flutter-application"></a>
## 3. 接入你的 Flutter 应用

在应用的 `pubspec.yaml` 中引用生成的分发包。七个 federated packages 之间存在相对路径依赖，请保留整个 `packages/` 目录：

```yaml
dependencies:
  weapp_container:
    path: /absolute/new-flutter-distribution/packages/weapp_container
```

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

View 挂载后加载已生成并校验的本地 pack。Flutter assets 需要先解包到应用私有目录，具体做法见[示例](example/lib/main.dart)：

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

<a id="sessions-storage-and-host-capabilities"></a>
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

登录、账号、网络和设备能力通过宿主显式配置：在 `load()` 前先调用 `configureHostServices`，再按需调用 `installNativeDeviceApis`。网络 origin 白名单和系统权限由宿主管理；受限 Showcase 运行库仍按编译时策略限制能力。配置和账号切换协议见 [CONTRACT.md](CONTRACT.md) 与 [Controller API](weapp_container/lib/src/controller.dart)。

<a id="troubleshooting"></a>
## 常见问题

| 现象 | 检查项 |
| --- | --- |
| 找不到原生 SDK / vendor 文件 | 先为当前平台执行 `prepare-native.mjs`，再生成分发包 |
| `load()` 一直等待 | View 是否已挂载、是否具有正数宽高 |
| 版本、哈希或目标不匹配 | 使用与源码一致的授权归档及审核过的 lock |
| Android 安装或链接失败 | minSdk 26、ABI 过滤器、NDK 和 CMake 配置 |
| Windows 无法准备 | 默认 lock 暂无对应 SDK，需要单独提供审核过的同版本分发 |

原生文本输入、完整无障碍语义与高级手势仍有 preview 限制，接入前应在目标设备验证。

<a id="documentation-and-licensing"></a>
## 更多资料与许可

- [Widget 与 Controller 用法](weapp_container/README.md)
- [完整示例](example/lib/main.dart) · [示例运行说明](example/README.md)
- [桌面接入](native_desktop/README.md) · [SDK 协议](CONTRACT.md)
- [公共类型和 C ABI](https://github.com/weapp-container/sdk-contract/blob/main/README.md)

接入层源码使用 [Apache-2.0](LICENSE)。运行库和第三方组件遵循归档中的 `RUNTIME-LICENSE` 及 notices；本仓库的开源许可不授予私有运行库下载权或额外的商用权利。

<a id="historical-archives-and-migration"></a>
## 历史归档与迁移

历史发行审计（2026-11-12）：默认锁中的 SDK 归档部分缺失，多个 runtime pin 与当前同名资产不符，默认在线准备会被完整性校验拒绝。请从匹配的干净源码构建，或通过 `--manifest` 显式选取独立审核过的配套清单；不要仅修改旧哈希。[差异与迁移记录](https://github.com/weapp-container/weapp-container/blob/main/docs/runtime-artifacts-migration.md)。

运行库发行工具已迁入 [核心仓库](https://github.com/weapp-container/weapp-container/tree/main/tools/runtime-artifacts)。新清单使用核心仓库的精确版本 Release；用 `--manifest` 显式选取。更新后的下载器把旧锁中的 `runtime-artifacts` 标识定向到私有的 `weapp-container/runtime-artifacts-private-archive`，仅允许九个冻结版本，保留原版本、哈希及随附许可，回执记录实际存储库。旧版下载器需升级；同名新仓库只保留停更工具源码。无跨仓库回退，私有档案仍需读取权限，源码许可不代表历史发行物公开可用。

核心运行时与 SDK 自有源码采用 Apache-2.0，可按[主仓库源码构建说明](https://github.com/weapp-container/weapp-container/blob/main/docs/sdk-source-build.md)构建当前运行库。现有预编译归档保留原许可、访问要求及精确版本和哈希锁；本次源码更新不发布替代二进制。
