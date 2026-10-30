native_framework = File.join(__dir__, 'vendor/WeappContainer/Frameworks/WeappContainerNative.xcframework/Info.plist')
unless File.file?(native_framework)
  raise 'Missing pinned iOS SDK; run node tools/prepare-native.mjs --platform ios --arch universal from sdk-flutter. No core source build fallback is available.'
end
Pod::Spec.new do |s|
  s.name = 'weapp_container_ios'
  s.version = '0.1.0-preview.5.7'
  s.summary = 'Native Weapp Container SDK for Flutter iOS'
  s.homepage = 'https://github.com/weapp-container/sdk-flutter'
  s.license = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author = 'Weapp Container contributors'
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.swift', 'vendor/WeappContainer/Sources/WeappContainer/**/*.swift'
  s.vendored_frameworks = 'vendor/WeappContainer/Frameworks/WeappContainerNative.xcframework'
  s.preserve_paths = 'vendor/WeappContainer/LICENSE', 'vendor/WeappContainer/licenses/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '16.0'
  s.swift_version = '5.9'
  s.static_framework = true
  s.libraries = 'c++', 'z', 'iconv'
  s.frameworks = 'UIKit', 'Metal', 'QuartzCore', 'CoreGraphics', 'CoreText', 'CoreFoundation', 'Security', 'SystemConfiguration'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
