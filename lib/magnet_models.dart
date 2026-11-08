/// 磁力搜索的数据结构。Go 核心（`native/core/provider_magnet*.go`）返回的 JSON
/// 与这里一一对应；cisou.apk 的 35 个站源规则由 Go 侧嵌入，Dart 只负责展示与交互。
class MagnetSite {
  const MagnetSite({
    required this.id,
    required this.name,
    this.info = '',
    this.state = true,
  });

  final int id;
  final String name;
  final String info;
  final bool state;

  factory MagnetSite.fromJson(Map<String, dynamic> json) => MagnetSite(
    id: json['id'] as int? ?? 0,
    name: json['name'] as String? ?? '未命名站源',
    info: json['info'] as String? ?? '',
    state: json['state'] == true,
  );
}

class MagnetResult {
  const MagnetResult({
    required this.id,
    required this.title,
    this.magnet = '',
    this.size = '',
    this.date = '',
    this.site = '',
    this.siteId = 0,
    this.detail = '',
    this.playable = false,
  });

  final String id;
  final String title;
  final String magnet;
  final String size;
  final String date;
  final String site;
  final int siteId;
  final String detail;

  /// 只有解析出 infohash 的结果才能直接交给磁力播放器。
  final bool playable;

  factory MagnetResult.fromJson(Map<String, dynamic> json) {
    final magnet = json['magnet'] as String? ?? '';
    return MagnetResult(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '未命名资源',
      magnet: magnet,
      size: json['size']?.toString() ?? '',
      date: json['date']?.toString() ?? '',
      site: json['site'] as String? ?? '',
      siteId: json['siteId'] as int? ?? 0,
      detail: json['detail'] as String? ?? '',
      playable: json['playable'] == true && magnet.startsWith('magnet:'),
    );
  }
}

class MagnetFile {
  const MagnetFile({
    required this.index,
    required this.name,
    required this.size,
    this.video = false,
  });

  final int index;
  final String name;
  final int size;
  final bool video;

  factory MagnetFile.fromJson(Map<String, dynamic> json) => MagnetFile(
    index: json['index'] as int? ?? 0,
    name: json['name'] as String? ?? '未命名文件',
    size: (json['size'] as num?)?.toInt() ?? 0,
    video: json['video'] == true,
  );
}

class MagnetSearchPage {
  const MagnetSearchPage({
    this.items = const [],
    this.sites = const [],
    this.hasMore = false,
    this.page = 1,
    this.warning = '',
  });

  final List<MagnetResult> items;
  final List<MagnetSite> sites;
  final bool hasMore;
  final int page;
  final String warning;

  factory MagnetSearchPage.fromJson(Map<String, dynamic> json) =>
      MagnetSearchPage(
        items: [
          for (final row in json['items'] as List? ?? const [])
            MagnetResult.fromJson(Map<String, dynamic>.from(row as Map)),
        ],
        sites: [
          for (final row in json['sites'] as List? ?? const [])
            MagnetSite.fromJson(Map<String, dynamic>.from(row as Map)),
        ],
        hasMore: json['hasMore'] == true,
        page: json['page'] as int? ?? 1,
        warning: json['warning'] as String? ?? '',
      );
}
