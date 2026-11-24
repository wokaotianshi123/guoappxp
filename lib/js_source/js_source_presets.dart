import 'dart:io';

import 'package:flutter/services.dart';

/// 出厂内置的 JS 数据源。
///
/// 只有一份：`hongguo.js` 是官方 App 接口版本，签名参数在构建时经环境变量
/// 编译进包，用户无需在「签名参数」里填写。
///
/// 其余源由用户从文件 / 网址 / 源码导入。
class PresetJsSource {
  const PresetJsSource({
    required this.id,
    required this.fileName,
    required this.name,
    required this.description,
    required this.assetPath,
  });

  final String id;
  final String fileName;
  final String name;
  final String description;
  final String assetPath;

  /// 优先读 Asset（正式包）；纯 Dart 环境（测试 / 脚本）回退到本地文件。
  Future<String> loadScript() async {
    try {
      return await rootBundle.loadString(assetPath);
    } catch (_) {
      final file = File(assetPath);
      if (await file.exists()) return await file.readAsString();
      rethrow;
    }
  }
}

const List<PresetJsSource> kPresetJsSources = [
  PresetJsSource(
    id: 'hongguo',
    fileName: 'hongguo.js',
    name: '官方免费短剧',
    description: '官方首发短剧源，包含海量都市爽文、战神回归、现代甜宠短剧（签名已内置）',
    assetPath: 'assets/sources/hongguo.js',
  ),
];

PresetJsSource? findPresetSource(String idOrFileName) {
  for (final preset in kPresetJsSources) {
    if (preset.id == idOrFileName ||
        preset.fileName == idOrFileName ||
        preset.fileName == '$idOrFileName.js') {
      return preset;
    }
  }
  return null;
}
