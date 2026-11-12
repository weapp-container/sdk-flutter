# Weapp Container Flutter SDK

版本 / Version: `0.1.0-preview.7.0`；C ABI `1`。

```yaml
dependencies:
  weapp_container: 0.1.0-preview.7.0
```

```sh
flutter pub get
```

Android API 26+；iOS 16+；macOS 12+ universal；Linux / Windows x86_64。Flutter 3.22+ / Dart 3.3+。Android uses Maven Central. iOS and macOS use public CocoaPods specifications; add both sources to each Apple Podfile:

```ruby
source 'https://github.com/weapp-container/Specs.git'
source 'https://cdn.cocoapods.org/'
```

Linux / Windows CMake downloads a fixed Desktop archive and verifies SHA-256. For offline builds, prefetch the exact archive and set `FETCHCONTENT_SOURCE_DIR_WEAPP_CONTAINER_RUNTIME` to its extracted directory. Each platform package includes its bridge sources, headers and licenses. Normal application installation requires no Node preparation command or sibling repository.

First public publication is being prepared; registry and device validation results are recorded separately. Historical private locks remain unchanged.

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

## 常见问题

| 现象 | 检查项 |
| --- | --- |
| 找不到原生 SDK / vendor 文件 | 先为当前平台执行 `prepare-native.mjs`，再生成分发包 |
| `load()` 一直等待 | View 是否已挂载、是否具有正数宽高 |
| 版本、哈希或目标不匹配 | 使用与源码一致的授权归档及审核过的 lock |
| Android 安装或链接失败 | minSdk 26、ABI 过滤器、NDK 和 CMake 配置 |
| Windows 无法准备 | 默认 lock 暂无对应 SDK，需要单独提供审核过的同版本分发 |

原生文本输入、完整无障碍语义与高级手势仍有 preview 限制，接入前应在目标设备验证。

## 更多资料与许可

- [Widget 与 Controller 用法](weapp_container/README.md)
- [完整示例](example/lib/main.dart) · [示例运行说明](example/README.md)
- [桌面接入](native_desktop/README.md) · [SDK 协议](CONTRACT.md)
- [公共类型和 C ABI](https://github.com/weapp-container/sdk-contract)

接入层源码使用 [Apache-2.0](LICENSE)。运行库和第三方组件遵循归档中的 `RUNTIME-LICENSE` 及 notices；本仓库的开源许可不授予私有运行库下载权或额外的商用权利。
