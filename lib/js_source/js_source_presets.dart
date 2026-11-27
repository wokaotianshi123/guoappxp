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

/// 内置的脚本源订阅。
///
/// 与 [kPresetJsSources] 不同，这里只提供订阅地址：导入时仍走
/// `importSubscription`，由订阅 JSON 决定要装哪些脚本、各自的地址与配置。
class PresetJsSubscription {
  const PresetJsSubscription({
    required this.id,
    required this.name,
    required this.url,
    this.description = '',
  });

  final String id;
  final String name;
  final String url;
  final String description;
}

/// 默认不预填地址；用户在「从网址导入」里点一下才写进输入框。
const List<PresetJsSubscription> kPresetJsSubscriptions = [
  PresetJsSubscription(
    id: 'xiaoguo',
    name: '小果',
    description: '小果影视脚本源订阅（含脚本与配置）',
    url:
        'https://cfkua.wokaotianshi.eu.org/https://raw.githubusercontent.com/'
        'wokaotianshi123/config/refs/heads/main/xiaoguojs/xiaoguo.json',
  ),
];

PresetJsSubscription? findPresetSubscription(String id) {
  for (final preset in kPresetJsSubscriptions) {
    if (preset.id == id) return preset;
  }
  return null;
}
