<a id="public-flutter-host-lifecycle-acceptance"></a>
# 公共 Flutter 宿主生命周期验证

**简体中文** · [English](host-lifecycle.en.md)


`host_lifecycle_consumer.dart` 是一个独立的交互式验证工具，用于验证公共环境下的
`WeappContainerController` 和 `WeappContainerView`。它使用与打包 SDK 消费者相同的可移植固定件和资源索引，但会测试 Flutter 宿主的导航和父级滚动功能。标准消费者中的 `navigate-back` 检查已涵盖小程序导航，因此该工具不会替代此验证工具。

<a id="prepare-and-build"></a>
## 准备与构建

1. 准备一个干净的分发版本，并使用仓库 SDK 工具链。保留其
   `distribution.json` 和平台构建收据。
2. 将其 `consumer` 和同级文件 `packages` 复制到一个新的证据目录中。保留其相对路径结构，并排除生成的
   `build`、`.dart_tool` 和平台目录 `ephemeral`。禁止直接修改原分发版本。
3. 仅替换已克隆的 `consumer/lib/main.dart` 为
   `host_lifecycle_consumer.dart`。保持其资源和 `pubspec.yaml` 不变。
4. 使用固定版本的 Flutter 3.47.7，运行 `flutter pub get --offline`、`flutter analyze lib --no-pub` 和相应的调试构建。记录分发版本哈希、验证工具哈希、包源码哈希、工具链版本修订号，以及生成可执行文件的哈希值。若测试修复方案，应明确标注包补丁，而非以旧清单作为其身份标识。

该验证工具支持 macOS、Windows、Linux、Android 和 iOS。任一平台的构建或运行结果不能作为其他平台的证据。桌面端的呈现身份以实际的 Flutter `Texture` ID 为准。移动端记录 `AndroidViewSurface` / `UiKitView` 的计数。

<a id="interact"></a>
## 交互操作

使用真实的平台 UI，每完成一个里程碑后收集截图及报告。输入坐标必须来源于当前的 `viewOrigin`、`viewSize` 和原生 `geometry` 字段；需考虑窗口标题栏和像素比例。禁止直接调用原生指针方法来替代 UI 输入。

1. 在 `scroll-parent-then-check` 处，滚动或拖动黄色 Flutter 头部，直到
   `parentOffset` 位于至少 20 个逻辑像素处，然后点击 **检查父级**。
2. 在 `click-child-after-parent-scroll` 处，点击位于移动视图内的原生目标 `geometry.tap`。验证工具要求必须触发真实的原生点击事件。
3. 在 `scroll-child` 处，滚动或拖动操作位于 `geometry.scroll` 内部。验证工具记录原生 `scrollTop` 事件和父级偏移量（在输入稳定后）。若父级偏移量变化超过一个逻辑像素，则视为问题；由于验证过程仍持续测试导航行为，因此该失败不会掩盖后续生命周期观察结果。
4. 在桌面端，点击 **测试拖动**（`arm-child-drag`），然后在原生滚动区域（`drag-child`）内向上拖动。要求子级必须更新其滚动偏移，而父级保持静止。移动端已使用真实的触摸拖动操作。
对于其第一个子滚动步骤。
5. 按下 **移动路由**。第一个小部件将被销毁，其表面必须在 `Navigator.push` 创建第二个具有相同控制器的小部件之前退役。
6. 在 `pop-flutter-route` 时，使用可见的 Flutter 返回按钮。第二个呈现必须在第一个路由重新创建其小部件之前退役。会话 ID 和生成号必须在整个过程中保持一致。
7. 在 `ready-to-close` 时，按下 **关闭 SDK**。关闭前必须恰好存在一个呈现，关闭后则不存在。公共控制器必须报告已关闭。
8. 最终报告必须包含 `stage: complete`、`status: passed`，无错误或问题，并且所有十项桌面检查（八项在移动设备上）均通过。保存该报告，关闭测试窗口，并验证正常退出。在验证修复时，保留失败运行的证据。

该报告写入到 `sdk-flutter-host-lifecycle.json`，在 `getApplicationSupportDirectory()` 中，并作为主路由的语义标签暴露。其原生历史记录了表面的退役和重新附加；纹理 ID 在退役后可以被重用，无需全局唯一。Linux 和 Windows 使用 CPU 像素缓冲纹理，因此在活动时其原生 `surface` 保持为空。它们需要一个活跃的 Flutter 纹理和前台状态；退役需要前台为 false。GPU 平台在附加时还要求一个原生表面。

<a id="true-flutter-hot-restart"></a>
## 真实的 Flutter 热重启

此工具包不声称支持热重启功能。要进行该检查，需启动一个调试版的公共消费者，保持一个活跃的原生呈现，附加固定的 Flutter 工具，并通过其机器协议请求 `app.restart` 与 `fullRestart: true`（或使用 Flutter 工具的交互式完整重启命令）。捕获请求前后的 `getVM`：进程 PID 必须保持不变，而主 Dart 隔离 ID 必须发生变化。然后重复实际的原生输入和关闭检查。手动调用 SDK 的 `initialize` 方法并使用新的客户端纪元对原生功能有帮助，但这并非真正的 Flutter 热重启。

<a id="linux-x11-automation"></a>
## Linux X11 自动化

`run-public-linux.mjs` 会将指定的发行版克隆到新目录中，记录源码和二进制哈希值，使用固定工具链进行构建，并启动其自己的 Xvfb 显示。其输入运行器仅选择属于子进程的窗口，等待 GTK 映射，聚焦该窗口，并使用真实的 XTest 指针输入。正常关闭会发送 `WM_DELETE_WINDOW`；强制清理会导致运行失败。

```sh
node native_desktop/tests/run-public-linux.mjs \
  --distribution /absolute/path/prepared-flutter-distribution \
  --flutter /opt/flutter --out /absolute/path/new-evidence/linux-host \
  --host-lifecycle

node native_desktop/tests/run-public-linux.mjs \
  --distribution /absolute/path/prepared-flutter-distribution \
  --flutter /opt/flutter --out /absolute/path/new-evidence/linux-restart \
  --hot-restart
```

`--host-lifecycle` 选择十项检查的宿主工具包。`--hot-restart` 选择标准消费者，并在其首次原生点击和后续输入之间添加一个真实的 Flutter 机器协议完整重启。它记录进程和隔离 ID
身份验证，解除 Flutter 工具，然后要求正常消费者进行检查。为每次尝试使用单独的输出目录。Linux X11 结果不支持 Wayland 或其他操作系统环境。
