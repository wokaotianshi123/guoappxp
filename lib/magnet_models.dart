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
    this.edited = false,
    this.mainUrl = '',
    this.rule = '',
  });

  final int id;
  final String name;
  final String info;
  final bool state;
  // custom 为 true 表示用户在「磁力源管理」里新增的站源；
  // 内置站源（custom=false）现在也能编辑，改过的会带 edited=true。
  final bool custom;

  /// 内置源被用户改过（Go 侧有覆盖层），界面上要能看出与出厂规则的差别。
  final bool edited;
  final String mainUrl;

  /// 这条源当前生效的完整规则 JSON。内置源与自定义源都返回，
  /// 「编辑」弹窗与「导出配置」都依赖它。
  final String rule;

  factory MagnetSite.fromJson(Map<String, dynamic> json) => MagnetSite(
    id: json['id'] as int? ?? 0,
    name: json['name'] as String? ?? '未命名站源',
    info: json['info'] as String? ?? '',
    state: json['state'] == true,
    custom: json['custom'] == true,
    edited: json['edited'] == true,
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

/// 「磁力播放」页从某个磁力站首页导航里实际抓到的分类。
/// [url] 是该分类的列表地址，点分类时直接按它拉列表；站点没提供分类时
/// 界面回退到「全部」，照常按站点默认浏览地址显示列表。
class MagnetCategory {
  const MagnetCategory({
    required this.siteId,
    required this.siteName,
    required this.name,
    required this.url,
  });

  final int siteId;
  final String siteName;
  final String name;
  final String url;

  /// 不同站的同名分类是不同项，用站点 id + 地址做选中键。
  String get key => '$siteId::$url';

  factory MagnetCategory.fromJson(Map<String, dynamic> json) => MagnetCategory(
    siteId: json['siteId'] as int? ?? 0,
    siteName: json['siteName'] as String? ?? '',
    name: json['name'] as String? ?? '',
    url: json['url'] as String? ?? '',
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

/// 一条结果的可达性。三态是必须的：国内网络下 DHT 探测经常拿不到节点，
/// 把「还没探测」当成「不可达」会让整页结果看起来全坏。
enum MagnetReachability {
  /// 还没探测到，显示为中性。
  unknown,

  /// 探测到有可连接节点，可播。
  reachable,

  /// 探测过但 0 节点，标记为红色（冷门种子或已失效）。
  unreachable,
}

extension MagnetReachabilityLabel on MagnetReachability {
  String get label => switch (this) {
    MagnetReachability.unknown => '未探测',
    MagnetReachability.reachable => '可达',
    MagnetReachability.unreachable => '不可达',
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

  /// 可达性：探测过且有节点 = 可达；探测过但 0 节点 = 不可达；没探测 = 未知。
  MagnetReachability get reachability {
    if (!dhtProbed) return MagnetReachability.unknown;
    return dht > 0 || peers > 0
        ? MagnetReachability.reachable
        : MagnetReachability.unreachable;
  }

  MagnetResult copyWith({
    int? dht,
    int? peers,
    bool? dhtProbed,
    String? magnet,
    String? title,
    int? siteId,
    bool? playable,
  }) => MagnetResult(
    id: id,
    title: title ?? this.title,
    magnet: magnet ?? this.magnet,
    size: size,
    sizeBytes: sizeBytes,
    date: date,
    timestamp: timestamp,
    site: site,
    siteId: siteId ?? this.siteId,
    detail: detail,
    playable: playable ?? this.playable,
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

/// 搜索会话里某个站源标签的状态。会话 start 时就会带回全部站，界面先把标签
/// 画出来，再随 poll 的增量逐站填充——这就是「边搜边显」。
class MagnetSessionSite {
  const MagnetSessionSite({
    required this.siteId,
    required this.name,
    this.state = 'pending',
    this.count = 0,
    this.error = '',
  });

  final int siteId;
  final String name;

  /// pending / fetching / done / failed。
  final String state;
  final int count;
  final String error;

  bool get running => state == 'pending' || state == 'fetching';
  bool get failed => state == 'failed';

  factory MagnetSessionSite.fromJson(Map<String, dynamic> json) =>
      MagnetSessionSite(
        siteId: json['siteId'] as int? ?? 0,
        name: json['name'] as String? ?? '',
        state: json['state'] as String? ?? 'pending',
        count: (json['count'] as num?)?.toInt() ?? 0,
        error: json['error'] as String? ?? '',
      );
}

/// 一次 poll 拿到的增量快照。[items] 只含本轮新产出的条目，[total] 是会话累计数。
class MagnetSessionSnapshot {
  const MagnetSessionSnapshot({
    this.id = '',
    this.phase = 'running',
    this.page = 1,
    this.query = '',
    this.sites = const [],
    this.items = const [],
    this.total = 0,
    this.hasMore = false,
    this.warning = '',
  });

  final String id;

  /// running（还有站在跑）/ done（全部结束）。
  final String phase;
  final int page;
  final String query;
  final List<MagnetSessionSite> sites;
  final List<MagnetResult> items;
  final int total;
  final bool hasMore;
  final String warning;

  bool get running => phase == 'running';

  factory MagnetSessionSnapshot.fromJson(Map<String, dynamic> json) =>
      MagnetSessionSnapshot(
        id: json['id'] as String? ?? '',
        phase: json['phase'] as String? ?? 'running',
        page: json['page'] as int? ?? 1,
        query: json['query'] as String? ?? '',
        sites: [
          for (final row in json['sites'] as List? ?? const [])
            MagnetSessionSite.fromJson(Map<String, dynamic>.from(row as Map)),
        ],
        items: [
          for (final row in json['items'] as List? ?? const [])
            MagnetResult.fromJson(Map<String, dynamic>.from(row as Map)),
        ],
        total: (json['total'] as num?)?.toInt() ?? 0,
        hasMore: json['hasMore'] == true,
        warning: json['warning'] as String? ?? '',
      );
}

/// 导入站源配置的结果统计。
class MagnetImportResult {
  const MagnetImportResult({
    this.added = 0,
    this.updated = 0,
    this.skipped = 0,
  });

  final int added;
  final int updated;
  final int skipped;

  String get summary {
    final parts = <String>[];
    if (added > 0) parts.add('新增 $added');
    if (updated > 0) parts.add('更新 $updated');
    if (skipped > 0) parts.add('跳过 $skipped');
    return parts.isEmpty ? '没有可导入的站源' : parts.join(' · ');
  }

  factory MagnetImportResult.fromJson(Map<String, dynamic> json) =>
      MagnetImportResult(
        added: (json['added'] as num?)?.toInt() ?? 0,
        updated: (json['updated'] as num?)?.toInt() ?? 0,
        skipped: (json['skipped'] as num?)?.toInt() ?? 0,
      );
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

/// 单个站源标签内的排序 / 筛选。排序是稳定的：数值相同时保持站源原始顺序。
/// [onlyReachable] 只保留「探测过且有节点」的条目——未探测的不算可达，
/// 也不会被误判成死链（不可达只在确实探测过 0 节点时成立）。
List<MagnetResult> magnetFilterResults(
  List<MagnetResult> items, {
  MagnetSort sort = MagnetSort.defaultOrder,
  bool onlyMagnet = false,
  bool onlyReachable = false,
}) {
  var source = onlyMagnet
      ? items.where((item) => item.hasMagnet).toList()
      : List<MagnetResult>.of(items);
  if (onlyReachable) {
    source = source
        .where((item) => item.reachability == MagnetReachability.reachable)
        .toList();
  }
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
