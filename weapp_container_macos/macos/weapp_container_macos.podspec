Pod::Spec.new do |s|
  s.name = 'weapp_container_macos'
  s.version = '0.1.0-preview.3'
  s.summary = 'WeApp Container macOS Flutter texture plugin'
  s.homepage = 'https://github.com/weapp-container/sdk-flutter'
  s.license = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author = 'WeApp Container contributors'
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.{h,mm}', 'native_shared/src/*.cpp', 'native_shared/include/*.hpp'
  s.public_header_files = 'Classes/WeappContainerMacosPlugin.h'
  s.preserve_paths = 'native_shared/third_party/**/*', 'vendor/**/*'
  s.vendored_libraries = 'vendor/lib/libweapp_container_sdk.a'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '12.0'
  s.frameworks = 'FlutterMacOS', 'Metal', 'CoreVideo', 'IOSurface', 'AppKit', 'CoreGraphics', 'CoreText', 'Security', 'SystemConfiguration', 'IOKit', 'QuartzCore'
  s.libraries = 'c++', 'z', 'iconv', 'resolv'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_ENABLE_OBJC_ARC' => 'YES',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/native_shared/include" "$(PODS_TARGET_SRCROOT)/native_shared/third_party" "$(PODS_TARGET_SRCROOT)/vendor/include"'
  }
end
