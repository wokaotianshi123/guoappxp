/// 内置的 py 源订阅。
///
/// 与 JS 沙箱的 `kPresetJsSubscriptions` 同构：只提供订阅地址，导入时仍走
/// `PySourceService.importSubscription`，由订阅 JSON 决定要装哪些脚本。
/// 地址默认留空，用户在「从网址导入」里点一下才写进输入框，仍可改成镜像。
class PresetPySubscription {
  const PresetPySubscription({
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

const List<PresetPySubscription> kPresetPySubscriptions = [
  PresetPySubscription(
    id: 'xiaoguo',
    name: '小果',
    description: '小果影视 py 蜘蛛源订阅（含脚本与配置）',
    url:
        'https://cfkua.wokaotianshi.eu.org/https://raw.githubusercontent.com/'
        'wokaotianshi123/config/refs/heads/main/xiaoguopy/xiaoguo.json',
  ),
];

PresetPySubscription? findPresetPySubscription(String id) {
  for (final preset in kPresetPySubscriptions) {
    if (preset.id == id) return preset;
  }
  return null;
}
