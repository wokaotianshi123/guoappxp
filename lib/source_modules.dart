import 'dart:typed_data';

import 'models.dart' show SourceClass;

class SourceModule {
  const SourceModule({
    required this.id,
    required this.name,
    this.version = '',
    this.description = '',
    this.hosts = const [],
    this.capabilities = const [],
    this.adult = false,
    this.category = '',
    this.installed = false,
    this.previous = '',
    this.token = '',
    this.error = '',
  });
  factory SourceModule.fromJson(Map<String, dynamic> json) => SourceModule(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    version: json['version'] as String? ?? '',
    description: json['description'] as String? ?? '',
    hosts: (json['hosts'] as List? ?? const []).whereType<String>().toList(),
    capabilities: (json['capabilities'] as List? ?? const [])
        .whereType<String>()
        .toList(),
    adult: json['adult'] == true,
    category: json['category'] as String? ?? '',
    installed: json['installed'] == true,
    previous: json['previous'] as String? ?? '',
    token: json['token'] as String? ?? '',
    error: json['error'] as String? ?? '',
  );
  final String id;
  final String name;
  final String version;
  final String description;
  final List<String> hosts;
  final List<String> capabilities;
  final bool adult;

  /// 模块作为站源时的类目（shortDrama/video/huangguo/adult），来自清单的
  /// family/category；没写类目的老模块为空。
  final String category;
  final bool installed;
  final String previous;
  final String token;
  final String error;

  /// 类目显示名；认不出的类目返回空，界面上不显示分组标签。
  String get classLabel {
    final key = SourceClass.normalize(category);
    return key == null ? '' : SourceClass.labelOf(key);
  }
}

class ModuleIndexEntry {
  const ModuleIndexEntry({
    required this.id,
    required this.name,
    required this.version,
    this.description = '',
    this.repo = '',
    this.adult = false,
    this.bundled = false,
  });
  factory ModuleIndexEntry.fromJson(Map<String, dynamic> json) =>
      ModuleIndexEntry(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        version: json['version'] as String? ?? '',
        description: json['description'] as String? ?? '',
        repo: json['repo'] as String? ?? '',
        adult: json['adult'] == true,
        bundled: json['bundled'] == true,
      );
  final String id;
  final String name;
  final String version;
  final String description;
  final String repo;
  final bool adult;
  final bool bundled;
}

class ModuleStore {
  const ModuleStore(this.entries, {this.warning = ''});
  final List<ModuleIndexEntry> entries;
  final String warning;
}

/// 在线仓库：一个仓库名对应一个 index.json 地址。
class ModuleRepository {
  const ModuleRepository({required this.name, required this.url});
  factory ModuleRepository.fromJson(Map<String, dynamic> json) =>
      ModuleRepository(
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
      );
  final String name;
  final String url;
  Map<String, dynamic> toJson() => {'name': name, 'url': url};
}

/// 已保存的仓库配置：列表与当前启用的下标。
class ModuleRepositories {
  const ModuleRepositories({
    this.repositories = const [],
    this.active = 0,
    this.warning = '',
  });
  factory ModuleRepositories.fromJson(Map<String, dynamic> json) =>
      ModuleRepositories(
        repositories: [
          for (final row in json['items'] as List? ?? const [])
            ModuleRepository.fromJson(Map<String, dynamic>.from(row as Map)),
        ],
        active: json['active'] as int? ?? 0,
        warning: json['warning'] as String? ?? '',
      );
  final List<ModuleRepository> repositories;
  final int active;
  final String warning;
}

/// 批量准备安装包时单项的结果：成功带 [module]（含 token），失败带 [error]。
class PreparedModule {
  const PreparedModule({this.name = '', this.module, this.error = ''});
  factory PreparedModule.fromJson(Map<String, dynamic> json) => PreparedModule(
    name: json['name'] as String? ?? '',
    module: json['info'] is Map
        ? SourceModule.fromJson(Map<String, dynamic>.from(json['info'] as Map))
        : null,
    error: json['error'] as String? ?? '',
  );
  final String name;
  final SourceModule? module;
  final String error;
  bool get ok => module != null && module!.token.isNotEmpty;
  String get displayName =>
      module?.name.isNotEmpty == true ? module!.name : name;
}

/// 导出的模块包：内容为 zip 字节，另带导出的模块数与标识。
class ModuleExport {
  const ModuleExport({
    required this.bytes,
    this.names = const [],
    this.count = 0,
  });
  final Uint8List bytes;
  final List<String> names;
  final int count;
}

bool isNewerModuleVersion(String latest, String installed) {
  List<int>? parse(String version) {
    final parts = version.split('.').map(int.tryParse).toList();
    return parts.length == 3 && !parts.contains(null)
        ? parts.cast<int>()
        : null;
  }

  final next = parse(latest);
  final current = parse(installed);
  if (next == null) return false;
  if (current == null) return latest != installed;
  for (var index = 0; index < 3; index++) {
    if (next[index] != current[index]) return next[index] > current[index];
  }
  return false;
}

/// 基础三件套的能力名（目录 / 详情 / 播放）。guoappcheng 商店的清单会显式写
/// 这三个，界面统一用「目录、详情和播放」一行表示，不重复列出。
const moduleBaseCapabilityNames = {'catalog', 'detail', 'media'};

const moduleCapabilityNames = {
  'search': '搜索',
  'account': '账号登录',
  'suggestions': '搜索联想',
  'recommendations': '推荐',
  'danmaku': '弹幕',
  'devices': '设备注册',
  'rankings': '榜单',
  'seasons': '分季',
  'cover': '封面',
  'metadata': '补充信息',
  'catalogState': '目录状态',
};

String? missingSourceHint(Map<String, int> counts, String unit) {
  final total = counts.values.fold(0, (sum, count) => sum + count);
  return total == 0 ? null : '有 $total $unit来自未安装的站源，在 我的 › 自定义模块 安装后恢复显示';
}
