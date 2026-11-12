Pod::Spec.new do |s|
  s.name = 'weapp_container_ios'
  s.version = '0.1.0-preview.7.0'
  s.summary = 'Native Weapp Container SDK for Flutter iOS'
  s.homepage = 'https://github.com/weapp-container/sdk-flutter'
  s.license = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author = 'Weapp Container contributors'
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.dependency 'WeappContainer', '0.1.0-preview.7.0'
  s.platform = :ios, '16.0'
  s.swift_version = '5.9'
  s.static_framework = true
  s.libraries = 'c++', 'z', 'iconv'
  s.frameworks = 'UIKit', 'Metal', 'QuartzCore', 'CoreGraphics', 'CoreText', 'CoreFoundation', 'Security', 'SystemConfiguration'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
