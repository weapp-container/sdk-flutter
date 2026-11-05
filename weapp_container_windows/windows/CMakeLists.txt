cmake_minimum_required(VERSION 3.14)
project(weapp_container_windows LANGUAGES CXX)
set(PLUGIN_NAME "weapp_container_windows_plugin")
set(NATIVE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/vendor")
if(NOT EXISTS "${NATIVE_ROOT}/lib/weapp_container_sdk.dll.lib" OR NOT EXISTS "${NATIVE_ROOT}/bin/weapp_container_sdk.dll")
  message(FATAL_ERROR "Prepare the local SDK first: node native_desktop/prepare.mjs --target windows --from <installed-desktop-sdk>")
endif()
if(NOT EXISTS "${NATIVE_ROOT}/lib/weapp_container_desktop.lib" OR NOT EXISTS "${NATIVE_ROOT}/include/weapp/native_preview.hpp" OR NOT EXISTS "${NATIVE_ROOT}/include/weapp/device_apis.hpp" OR NOT EXISTS "${NATIVE_ROOT}/lib/cmake/WeappContainerDesktop/WeappContainerDesktopConfig.cmake")
  message(FATAL_ERROR "The reviewed desktop native device/preview wrapper is required; re-run prepare with the matching SDK version")
endif()
add_library(${PLUGIN_NAME} SHARED weapp_container_windows_plugin.cpp native_shared/src/registry.cpp)
# Use the installed target's transitive Windows dependencies. The desktop
# wrapper owns its WLAN, network and WinRT feature detection and link contract.
# Resolve only the verified vendor metadata copied by native_desktop/prepare.
set(WeappContainerDesktop_DIR "${NATIVE_ROOT}/lib/cmake/WeappContainerDesktop")
find_package(WeappContainerDesktop CONFIG REQUIRED NO_DEFAULT_PATH)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX)
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE native_shared/include native_shared/third_party "${NATIVE_ROOT}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin WeappContainer::Desktop)
# The device wrapper imports TaskDialogIndirect from Common Controls v6.
# Flutter links the wrapper into this plugin DLL, while the final runner EXE
# owns the process activation context. Propagate the dependency to that EXE.
if(MSVC)
  target_link_options(${PLUGIN_NAME} INTERFACE "/MANIFESTDEPENDENCY:\"type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")
endif()
set(weapp_container_windows_bundled_libraries "${NATIVE_ROOT}/bin/weapp_container_sdk.dll" PARENT_SCOPE)
