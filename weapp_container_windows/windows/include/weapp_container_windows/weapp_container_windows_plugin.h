#ifndef FLUTTER_PLUGIN_WEAPP_CONTAINER_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_WEAPP_CONTAINER_WINDOWS_PLUGIN_H_
#include <flutter_plugin_registrar.h>
#ifdef FLUTTER_PLUGIN_IMPL
#define WEAPP_PLUGIN_EXPORT __declspec(dllexport)
#else
#define WEAPP_PLUGIN_EXPORT __declspec(dllimport)
#endif
#ifdef __cplusplus
extern "C" {
#endif
WEAPP_PLUGIN_EXPORT void WeappContainerWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);
#ifdef __cplusplus
}
#endif
#endif
