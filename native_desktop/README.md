<a id="flutter-desktop-native-support"></a>
# Flutter 桌面原生支持

**简体中文** · [English](README.en.md)

当前主分支准备 preview.7 公开发行；只有对应版本在注册源发布后才使用公开安装入口。安装、平台要求与状态见 [SDK 首页](../README.md)。下方保留固定 preview.6 源码的详细说明；该版本须从 SDK 首页给出的精确提交 checkout 构建，不与 preview.7 运行库混用。


三个桌面实现共享此引擎管理的注册表。平台线程独占运行时句柄；光栅回调接收不可变的帧租用（Windows/Linux）或完成的 IOSurface 像素缓冲区（macOS Metal）。像素永远不会通过 Flutter 方法通道传输。

在安装本地联邦包树之前，需从其已安装的桌面原生 SDK 分发版中准备每个目标：

```sh
node native_desktop/prepare.mjs --target macos --from /path/to/macos-universal
node native_desktop/prepare.mjs --target windows --from C:/path/to/windows-x64
node native_desktop/prepare.mjs --target linux --from /path/to/linux-x64
```

该命令将核心库和桌面设备/预览包装器库、已审核的 C/C++ 头文件、通知和公共源码复制到该插件包中。分发已准备好的目录树，包括生成的 `vendor` 和 `native_shared` 目录。消费项目无需检出仓库或配置 Rust 工具链。公共注册表发布超出了此预览范围。
准备过程需要匹配 `SDK_VERSION` 的验证原生包收据，并且包及其每个原生切片的源码提交必须是干净的。它会验证核心和包装器归档的 SHA256 值，以及每个已审核头文件，并清除旧的生成文件，同时在 `vendor/prepared.json` 中保留完整的收据和归档哈希。Windows 通过其验证的 `weapp_container_sdk.dll.lib` 导入接口链接核心库，并捆绑了单独验证的 `weapp_container_sdk.dll`；这两个哈希值均保留在准备收据中。macOS 和 Linux 保持其静态核心归档边界。

macOS 直接使用 Metal 写入 CVPixelBuffer IOSurface，对同一 GPU 队列进行栅栏操作再发布，并在 Flutter 释放纹理对象的最后一个引用时才完成退役。此方案也支持不包含可选注销通知的 macOS 引擎版本。
Linux 频道使用 JSON UTF-8 字节信封，因为 Flutter Linux 的 FlValue 字符串无法保留嵌入的空字符（NUL）。各平台的公共 Dart API 均保持为 JSON 值。
Windows 会锁定每个原生帧，直到引擎的像素缓冲区释放回调完成，并等待异步注销完成。Linux 无公共光栅退役栅栏：其注册器返回一个借来的 GObject，注销仍可被排队。引擎管理的池在并发纹理峰值时保留 GObject，并复用其槽位。每个槽位保留其最后一次光栅读取者，直到下一次复制回调或引擎关闭；原生会话仍会立即关闭。退役和重新获取会清空生产者邮箱，一个不可变的透明 1×1 帧将覆盖有效区间直至首次渲染前。Flutter 在释放消息处理器之前会先关闭其光栅任务。
池子。不使用猜测延迟作为资源生命周期的边界。

所有平台在关闭时会取消待处理的布局加载，隐藏状态下保持服务持续运行，并在旧会话存储和纹理资源退出后才完成新的Dart时钟周期。打包加载失败时会恢复之前的表面和会话。

故障恢复保留所有权：关闭返回原生销毁错误并允许重试；引擎终止时会保留未完成的资源，在平台线程清理任务中保留，直到GPU/纹理/会话资源成功退出。错误仍会显示在平台日志中。它不会终止宿主以处理清理工作。

Windows/Linux的`WeappContainerView.nativeChrome`描述符可能包含一个可选的`accessibilityLabels`对象，该对象带有`more`、`close`、`back`、`navigation`和`tabs`字符串。这些仅用于本地化宿主控件；小程序标题和标签文本仍由应用所有。每个提供的标签必须是非空的UTF-8文本，最多1024字节，且不能包含嵌入的NUL字符。省略标签将保留现有消费者中的英文默认值。标签变更在当前Chrome几何版本中应用，无需调整大小、分离或重启客体。这属于Flutter到原生的呈现元数据，不会改变核心运行时ABI。标签解析器和Dart分发由本地合同/组件测试覆盖；Windows/Linux在实际窗口中的可访问性需要单独的平台证据。

测试包括：`registry_failures.cpp`（注入故障的退休测试）、`prepare_receipts.mjs`（原生来源、哈希拒绝和干净重置）、`macos_texture.mm`（真实的QuickJS/Skia/Metal配合带仪器化的Flutter注册器）和`engine_consumer.dart`（真实的Flutter引擎、外部纹理像素快照、通道、持久存储、导航、隐藏泵送和时钟周期替换）。`tests/run-public-linux.mjs`将已准备的公共Flutter分发版本进行重定位，构建其Widget/Controller消费者，并在Xvfb下使用X11指针输入运行全部十项验收检查。它记录输入坐标、截图、源码和二进制哈希，并记录正常的GTK窗口/引擎关闭流程。依赖项包括Flutter 3.47.7、GTK开发库、Xvfb、xdotool、ImageMagick和Python 3。此检查覆盖X11；Wayland需要在独立的Wayland会话中进行单独验收。macOS需要版本12.0或更高版本，与原生SDK存档版本匹配。目前Flutter 3.47.7通过CocoaPods构建macOS插件；Swift Package Manager的打包功能未包含在本次预览中。

`installNativeDeviceApis`选择启用可重用的桌面操作系统适配器。原生注册表会从客体中独立接收受信任的应用程序/账户配置。
payloads，获取核心提供的私有文件作用域，并仅合并已安装的API和观察到的同步快照。`allowedNetworkOrigins` 是宿主拥有的白名单；其默认值为空。原生操作系统调用在注册表中被消费，而未声明的业务调用则通过Dart继续传递。平台回调仅将记录入队；现有所有者定时器会将完成项泵入QuickJS。

公共控制器在账户切换和运行时重启后仍保持存在。旧的OS资源在确认纹理清理握手之前将被退役。下一驱动将绑定最新的接受包、账户纪元和运行时实例；只有在新内部所有者存在后，才会发布新的快照。隐藏视图会将前台状态传递给设备适配器。无法从插件编译成功推断出设备支持或商户接受。
