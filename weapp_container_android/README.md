<a id="weapp-container-android-implementation"></a>
# Weapp 容器 Android 实现

**简体中文** · [English](README.en.md)


`weapp_container` 的联邦原生插件。使用混合组合和已安装的 `com.sonofmagic.weapp:weapp-container-android:0.1.0-preview.5.1` AAR。
分发构建器包含 `native/maven`；源码消费者可将 `weappSdkMavenDir` 设置为已验证的 SDK Maven 仓库。最低 Android API 为 26。
在消费的 Flutter 应用中不会发生 Cargo/JNI 源码构建。
