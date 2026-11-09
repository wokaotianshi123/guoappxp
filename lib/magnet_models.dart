/// 磁力搜索的数据结构。Go 核心（`native/core/provider_magnet*.go`）返回的 JSON
/// 与这里一一对应；cisou.apk 的 35 个站源规则由 Go 侧嵌入，Dart 只负责展示与交互。
library;

class MagnetSite {
  const MagnetSite({
    required this.id,
    required this.name,
    this.info = '',
    this.state = true,
    this.custom = false,
    this.mainUrl = '',
    this.rule = '',
  });

  final int id;
  final String name;
  final String info;
  final bool state;
  // custom 为 true 表示用户在「磁力源管理」里新增的站源，可编辑/删除；
  // 内置站源只允许删除（Go 侧记进 disabled 表）与一键恢复默认。
  final bool custom;
  final String mainUrl;
  final String rule;

  factory MagnetSite.fromJson(Map<String, dynamic> json) => MagnetSite(
    id: json['id'] as int? ?? 0,
    name: json['name'] as String? ?? '未命名站源',
    info: json['info'] as String? ?? '',
    state: json['state'] == true,
    custom: json['custom'] == true,
    mainUrl: json['mainUrl'] as String? ?? '',
    rule: json['rule'] as String? ?? '',
  );
}

/// 「磁力源管理 → 自动识别」的返回：规则文本只回填表单，不写盘。
class MagnetSiteAnalysis {
  const MagnetSiteAnalysis({
    this.rule = '',
    this.name = '',
    this.base = '',
    this.notes = const [],
  });

  final String rule;
  final String name;
  final String base;
  final List<String> notes;

  bool get hasRule => rule.trim().isNotEmpty;

  factory MagnetSiteAnalysis.fromJson(Map<String, dynamic> json) =>
      MagnetSiteAnalysis(
        rule: json['rule'] as String? ?? '',
        name: json['name'] as String? ?? '',
        base: json['base'] as String? ?? '',
        notes: [
          for (final row in json['notes'] as List? ?? const [])
            if (row is String && row.trim().isNotEmpty) row,
        ],
      );
}

/// 每个站源标签独立记忆的排序 / 筛选方式。
enum MagnetSort { defaultOrder, date, size, dht }

extension MagnetSortLabel on MagnetSort {
  String get label => switch (this) {
    MagnetSort.defaultOrder => '默认',
    MagnetSort.date => '按时间',
    MagnetSort.size => '按大小',
    MagnetSort.dht => '按 DHT 数量',
  };
}

class MagnetResult {
  const MagnetResult({
    required this.id,
    required this.title,
    this.magnet = '',
    this.size = '',
    this.sizeBytes = 0,
    this.date = '',
    this.timestamp = 0,
    this.site = '',
    this.siteId = 0,
    this.detail = '',
    this.playable = false,
    this.dht = 0,
    this.peers = 0,
    this.dhtProbed = false,
  });

  final String id;
  final String title;
  final String magnet;
  final String size;
  final int sizeBytes;
  final String date;
  final int timestamp;
  final String site;
  final int siteId;
  final String detail;

  /// 只有解析出 infohash 的结果才能直接交给磁力播放器。
  final bool playable;

  /// 当前能连接的 DHT 节点数 / 全部已知可连接节点数，由 magnetPeers 探测回填。
  final int dht;
  final int peers;

  /// 区分「探测过但 0 节点」与「还没探测」。
  final bool dhtProbed;

  bool get hasMagnet => playable && magnet.startsWith('magnet:');

  MagnetResult copyWith({int? dht, int? peers, bool? dhtProbed}) =>
      MagnetResult(
        id: id,
        title: title,
        magnet: magnet,
        size: size,
        sizeBytes: sizeBytes,
        date: date,
        timestamp: timestamp,
        site: site,
        siteId: siteId,
        detail: detail,
        playable: playable,
        dht: dht ?? this.dht,
        peers: peers ?? this.peers,
        dhtProbed: dhtProbed ?? this.dhtProbed,
      );

  factory MagnetResult.fromJson(Map<String, dynamic> json) {
    final magnet = json['magnet'] as String? ?? '';
    return MagnetResult(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '未命名资源',
      magnet: magnet,
      size: json['size']?.toString() ?? '',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      date: json['date']?.toString() ?? '',
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
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

/// magnetPeers 的单条结果：Go 侧短窗口 DHT / tracker 探测出的可连接节点数。
class MagnetPeerItem {
  const MagnetPeerItem({
    required this.hash,
    this.dht = 0,
    this.peers = 0,
    this.connected = 0,
  });

  final String hash;
  final int dht;
  final int peers;
  final int connected;

  factory MagnetPeerItem.fromJson(Map<String, dynamic> json) => MagnetPeerItem(
    hash: json['hash'] as String? ?? '',
    dht: (json['dht'] as num?)?.toInt() ?? 0,
    peers: (json['peers'] as num?)?.toInt() ?? 0,
    connected: (json['connected'] as num?)?.toInt() ?? 0,
  );
}

class MagnetPeersInfo {
  const MagnetPeersInfo({
    this.items = const [],
    this.dhtNodes = 0,
    this.probing = 0,
  });

  final List<MagnetPeerItem> items;
  final int dhtNodes;
  final int probing;

  factory MagnetPeersInfo.fromJson(Map<String, dynamic> json) =>
      MagnetPeersInfo(
        items: [
          for (final row in json['items'] as List? ?? const [])
            MagnetPeerItem.fromJson(Map<String, dynamic>.from(row as Map)),
        ],
        dhtNodes: (json['dhtNodes'] as num?)?.toInt() ?? 0,
        probing: (json['probing'] as num?)?.toInt() ?? 0,
      );
}

/// 一个站源标签对应的结果分组。tab 顺序与站源表一致；siteId 缺失时按站源名分组。
class MagnetSiteGroup {
  const MagnetSiteGroup({
    required this.key,
    required this.name,
    required this.items,
  });

  final String key;
  final String name;
  final List<MagnetResult> items;
}

List<MagnetSiteGroup> magnetSiteGroups(List<MagnetResult> items) {
  final order = <String>[];
  final grouped = <String, List<MagnetResult>>{};
  final names = <String, String>{};
  for (final item in items) {
    final key = item.siteId > 0 ? 'id:${item.siteId}' : 'name:${item.site}';
    if (!grouped.containsKey(key)) {
      order.add(key);
      grouped[key] = <MagnetResult>[];
      names[key] = item.site.isEmpty ? '其它站源' : item.site;
    }
    grouped[key]!.add(item);
  }
  return [
    for (final key in order)
      MagnetSiteGroup(key: key, name: names[key]!, items: grouped[key]!),
  ];
}

/// 单个站源标签内的排序 / 「仅含磁力」筛选。排序是稳定的：数值相同时保持站源原始顺序。
List<MagnetResult> magnetFilterResults(
  List<MagnetResult> items, {
  MagnetSort sort = MagnetSort.defaultOrder,
  bool onlyMagnet = false,
}) {
  final source = onlyMagnet
      ? items.where((item) => item.hasMagnet).toList()
      : List<MagnetResult>.of(items);
  if (sort == MagnetSort.defaultOrder) return source;
  final order = List<int>.generate(source.length, (index) => index);
  int compare(MagnetResult a, MagnetResult b) => switch (sort) {
    MagnetSort.date => b.timestamp.compareTo(a.timestamp),
    MagnetSort.size => b.sizeBytes.compareTo(a.sizeBytes),
    MagnetSort.dht =>
      b.dht.compareTo(a.dht) != 0
          ? b.dht.compareTo(a.dht)
          : b.peers.compareTo(a.peers),
    MagnetSort.defaultOrder => 0,
  };
  order.sort((left, right) {
    final result = compare(source[left], source[right]);
    return result != 0 ? result : left.compareTo(right);
  });
  return [for (final index in order) source[index]];
}
