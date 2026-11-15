import 'models.dart';

/// 站源模块：本体不再把站源写死，站源以一个可安装的包（manifest.json + main.js）
/// 提供，安装后在站源列表里出现。移植自 guoappxpx，字段与核心侧的
/// nativeModuleInfo 对齐。
class SourceModule {
  const SourceModule({
    required this.id,
    required this.name,
    this.version = '',
    this.description = '',
    this.hosts = const [],
    this.capabilities = const [],
    this.adult = false,
    this.installed = false,
    this.previous = '',
    this.token = '',
    this.error = '',
    this.sourceId = '',
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
    installed: json['installed'] == true,
    previous: json['previous'] as String? ?? '',
    token: json['token'] as String? ?? '',
    error: json['error'] as String? ?? '',
    sourceId: json['sourceId'] as String? ?? '',
  );
  final String id;
  final String name;
  final String version;
  final String description;
  final List<String> hosts;
  final List<String> capabilities;
  final bool adult;
  final bool installed;
  final String previous;
  final String token;
  final String error;

  /// 模块在站源列表里实际用的 ID。
  ///
  /// 与本体已编入的站源同名时（例如红果、笔盒）核心会把它改成 `mod-<标识>`，
  /// 让模块源与本体源各占一个 ID、互不影响；其余情况与 [id] 相同。
  final String sourceId;

  /// 模块提供的站源。核心判定加载失败（[error] 非空）时不进源列表。
  ModuleSourceSite? get source {
    if (error.isNotEmpty || sourceId.isEmpty) return null;
    return ModuleSourceSite(
      id: sourceId,
      name: name,
      search: capabilities.contains('search'),
      suggestions: capabilities.contains('suggestions'),
    );
  }
}

/// 模块在页面上的展示形态：先列出来，点「安装」再走 [SourceModule] 的校验流程。
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

/// 模块商店的一次读取结果：[warning] 是索引拉取失败时的说明，
/// 此时 [entries] 里仍会有随包内置的模块。
class ModuleStore {
  const ModuleStore(this.entries, {this.warning = ''});
  final List<ModuleIndexEntry> entries;
  final String warning;
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

/// 已安装模块提供的站源，登记进 [SourceSite] 的模块源表后即可当作普通站源使用。
class ModuleSourceSite {
  const ModuleSourceSite({
    required this.id,
    required this.name,
    this.search = false,
    this.suggestions = false,
  });
  factory ModuleSourceSite.fromJson(Map<String, dynamic> json) =>
      ModuleSourceSite(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        search: json['search'] == true,
        suggestions: json['suggestions'] == true,
      );
  final String id;
  final String name;
  final bool search;
  final bool suggestions;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'search': search,
    'suggestions': suggestions,
  };

  /// 站源列表里显示的名字：模块源一律标出「（模块）」，
  /// 与同名的本体源（例如红果与红果模块）区分开。
  String get displayName => '$name（模块）';

  SourceSite get asSourceSite => SourceSite(id, displayName, '站源模块');
}

/// 从已安装模块列表里挑出可用的站源。
List<ModuleSourceSite> moduleSourceSites(Iterable<SourceModule> modules) => [
  for (final module in modules) ?module.source,
];

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
