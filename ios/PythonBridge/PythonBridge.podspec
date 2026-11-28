Pod::Spec.new do |spec|
  spec.name = 'PythonBridge'
  spec.version = '0.1.0'
  spec.summary = '火蚁短剧 iOS 嵌入式 CPython 蜘蛛桥（guoapp/py）'
  spec.homepage = 'https://github.com/fish2018/guoapp'
  spec.author = '短剧视界 contributors'
  spec.source = { :path => '.' }
  spec.license = { :type => 'See application repository' }
  spec.ios.deployment_target = '15.0'
  spec.swift_version = '5.0'
  spec.source_files = 'Sources/**/*.{swift,c,h}'
  spec.public_header_files = 'Sources/**/*.h'
  # Resources must be listed explicitly: a 'Resources/**/*' glob would also
  # enumerate every file inside PythonVendor.bundle, and CocoaPods would copy
  # those files flat into the app bundle root next to the bundle itself.
  # Both entries are produced by scripts/prepare_ios_python.py before pod install.
  spec.resources = ['Resources/py_spider_host.py', 'Resources/PythonVendor.bundle']
  # No vendored_frameworks: Python.xcframework is referenced, linked and
  # embedded by the Runner Xcode project itself (see prepare_ios_python.py).
  # The pod keeps only the C shim plus the header search path below, so the
  # framework is signed exactly once, by the Embed Frameworks phase.
  spec.static_framework = true
  spec.dependency 'Flutter'
  spec.frameworks = 'Foundation'
  spec.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
    'BUILD_LIBRARY_FOR_DISTRIBUTION' => 'NO',
    'HEADER_SEARCH_PATHS' => '$(inherited) $(PODS_TARGET_SRCROOT)/../Frameworks/Python.xcframework/ios-arm64/Python.framework/Headers'
  }
end
