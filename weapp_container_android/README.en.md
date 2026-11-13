<a id="weapp-容器-android-实现"></a>
# Weapp Container Android implementation

[简体中文](README.md) · **English**

The main branch prepares the preview.7 public release. Use public installation only after the version appears in its registry; see the [SDK home](../README.en.md) for installation, requirements, and status. The source instructions below use preview.7. Build the exact checkout linked on the SDK home with same-version runtimes. Old locks remain for historical compatibility; current preparation tools default to the versioned preview.7 public lock.


Federated native plugin for `weapp_container`. Uses Hybrid Composition and the
installed `com.sonofmagic.weapp:weapp-container-android:0.1.0-preview.5.1` AAR.
The distribution builder includes `native/maven`; source consumers may set
`weappSdkMavenDir` to a verified SDK Maven repository. Minimum Android API is 26.
No Cargo/JNI source build occurs in a consuming Flutter application.
