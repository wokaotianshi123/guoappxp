import 'dart:convert';

const hongguoSourceId = 'hongguo';

bool validSourceId(String id) => RegExp(r'^[a-z0-9_-]{1,64}$').hasMatch(id);

/// 站源类目：站源菜单、站源管理页按它分段，与 guoappcheng 的四分类同口径——
/// 短剧类 / 视频类 / 黄果类 / 成人类。黄果类优先于内容类型（黄果系入口自成
/// 一类，不与短剧类、视频类混），其余按内容归类，认不出的归「其他站源」。
abstract final class SourceClass {
  static const shortDrama = 'shortDrama';
  static const video = 'video';
  static const huangguo = 'huangguo';
  static const adult = 'adult';

  /// 用户在「自定义XBPQ」里自己添加的源（MacCMS 站点 / XBPQ 规则），
  /// 与模块安装的源分开成组；本机没加过这类源时整组不出现。
  static const xbpq = 'xbpq';
  static const other = 'other';

  /// 界面分段顺序。类目以外的自定义类目排在后面。
  static const order = [shortDrama, video, huangguo, adult, xbpq, other];

  static String labelOf(String key) => switch (key) {
    shortDrama => '短剧类',
    video => '视频类',
    huangguo => '黄果类',
    adult => '成人类',
    xbpq => 'XBPQ',
    other => '其他站源',
    _ => key,
  };

  /// 把清单里的类目写法归一（shortdrama / ShortDrama 都算短剧类）。
  static String? normalize(String raw) => switch (raw.trim().toLowerCase()) {
    'shortdrama' => shortDrama,
    'video' => video,
    'huangguo' => huangguo,
    'adult' => adult,
    _ => null,
  };

  static int rankOf(String key) {
    final index = order.indexOf(key);
    return index < 0 ? order.length : index;
  }
}

/// 黄果类成员：黄果系入口（AI/旧版/视频）+ 黄豆/野果/剧果。与 guoappcheng 的
/// 站源表一致——它们优先级高于内容类型，自成一类。
///
/// 为什么认标识而不是认清单的 category/family：商店清单里红果也写着
/// "family": "huangguo"（同一套 App 系谱），而黄豆这些的 category 写的是
/// shortDrama。只有标识能表达「界面上的黄果类」。
const _huangguoClasses = <String>{
  'huangguo-video',
  'huangguoai',
  'cloudfront',
  'huangdou',
  'yeguo',
  'huangju',
};

/// 没写类目的老模块按站源标识归类（口径照搬 guoappcheng）。新模块在清单里
/// 声明 category/family 后以清单为准，这张表只是兜底，不再往里面加新源。
const _legacyClasses = <String, String>{
  'hongguo': SourceClass.shortDrama,
  'dsd': SourceClass.shortDrama,
  'yaguo': SourceClass.shortDrama,
  'maoguo': SourceClass.shortDrama,
  'fanguo': SourceClass.shortDrama,
  'heguo': SourceClass.shortDrama,
  'xingguo': SourceClass.shortDrama,
  'huaguo': SourceClass.shortDrama,
  'wangguo': SourceClass.shortDrama,
  'wuguo': SourceClass.shortDrama,
  'jinguoduanju': SourceClass.shortDrama,
  'faguo': SourceClass.video,
  'guipian': SourceClass.video,
  'hanxiaoquan': SourceClass.video,
  'ikanbot': SourceClass.video,
  'sorani': SourceClass.video,
  'yingshigongchang': SourceClass.video,
  '360zy': SourceClass.video,
  'modu': SourceClass.video,
  'dytt': SourceClass.video,
  'shandian': SourceClass.video,
  'hongniu': SourceClass.video,
  'niuniuzy': SourceClass.video,
  'wsyzy': SourceClass.video,
  'dongpiandi': SourceClass.video,
  'beabox': SourceClass.video,
  'heitao': SourceClass.video,
  'hanime1': SourceClass.adult,
  'missav': SourceClass.adult,
  'zy155': SourceClass.adult,
  'yutu': SourceClass.adult,
  'fanhao': SourceClass.adult,
  'lsbzy': SourceClass.adult,
  'hsck': SourceClass.adult,
  'danaizi': SourceClass.adult,
  'jkun': SourceClass.adult,
  'lebo': SourceClass.adult,
  'senlin': SourceClass.adult,
  'doudou': SourceClass.adult,
  'didi': SourceClass.adult,
  'heiliao': SourceClass.adult,
  'taohua': SourceClass.adult,
  'souav': SourceClass.adult,
  'ckzy': SourceClass.adult,
  'aosika': SourceClass.adult,
};

/// 站源 / 模块属于哪个类目。站源菜单、模块的「已安装」分段都用这一份判定，
/// 保证两边把同一个源放进同一类：自定义XBPQ 的源自成一组；黄果类成员按标识
/// 恒定归黄果类；其余以清单的 category/family 为准，没写的按标识查老表。
String sourceClassOf(String id, {String category = ''}) {
  if (SourceSite.isCustomId(id)) return SourceClass.xbpq;
  if (_huangguoClasses.contains(id)) return SourceClass.huangguo;
  return SourceClass.normalize(category) ??
      _legacyClasses[id] ??
      SourceClass.other;
}

class SourceSite {
  const SourceSite(
    this.id,
    this.name,
    this.description, {
    this.group = '',
    this.groupLabel = '',
    this.category = '',
    this.entryLabel = '',
    this.available = true,
    this.pagedSearch = false,
    this.searchSuggestions = false,
    this.recommends = false,
    this.danmaku = false,
    this.devices = false,
    this.account = false,
    this.metadata = false,
    this.adult = false,
    this.vipPrompt = true,
    this.module = false,
  });
  factory SourceSite.fromJson(Map<String, dynamic> json) => SourceSite(
    json['id'] as String? ?? '',
    json['name'] as String? ?? '',
    json['description'] as String? ?? '',
    group: json['group'] as String? ?? '',
    groupLabel: json['groupName'] as String? ?? '',
    category: json['category'] as String? ?? '',
    entryLabel: json['entryName'] as String? ?? '',
    available: json['available'] == true,
    pagedSearch: json['search'] == true,
    searchSuggestions: json['suggestions'] == true,
    recommends: json['recommendations'] == true,
    danmaku: json['danmaku'] == true,
    devices: json['devices'] == true,
    account: json['account'] == true,
    metadata: json['metadata'] == true,
    adult: json['adult'] == true,
    vipPrompt: json['vipPrompt'] != false,
    module: json['module'] == true,
  );
  final String id;
  final String name;
  final String description;
  final String group;
  final String groupLabel;

  /// 站源类目（shortDrama/video/huangguo/adult），由模块清单的 family/category
  /// 推导；编进包里的源或没写类目的老模块为空，由 [classKey] 兜底。
  final String category;
  final String entryLabel;
  final bool available;
  final bool pagedSearch;
  final bool searchSuggestions;
  final bool recommends;
  final bool danmaku;
  final bool devices;
  final bool account;
  final bool metadata;
  final bool adult;
  final bool vipPrompt;

  /// 这个源由站源模块提供（不是编进包里的）。模块源与自定义源一样属于
  /// 「谁用谁配」的本机内容，见 [LocalStore.allowsSource]。
  final bool module;
  bool get onlineSearch => pagedSearch;
  String get groupId => group.isEmpty ? id : group;
  String get groupName => groupLabel.isEmpty ? name : groupLabel;
  String get entryName => entryLabel.isEmpty ? name : entryLabel;

  /// 菜单分段用的类目：在「自定义XBPQ」里添加的源自成一组；黄果类成员按标识
  /// 恒定归黄果类；其余以清单声明的 category/family 为准，没声明的按标识查
  /// 老表，都不认的归「其他站源」。
  String get classKey => sourceClassOf(id, category: category);

  static List<SourceSite> _installed = const [];
  static List<String> _order = const [];
  static List<SourceSite> _all = const [];
  static List<SourceSite> _available = const [];

  /// 自定义源（`custom:` 前缀）由本机配置，不在核心的注册源表里。但详情页、
  /// 播放页、追剧 / 历史 / 搜索结果都用 [byId] 取显示名，没有这张表就会把
  /// `custom:3f2a…` 原样显示给用户。LocalStore 加载 / 同步自定义源后写进来。
  static final Map<String, SourceSite> _custom = {};

  static void install(Iterable<SourceSite> sites) {
    _installed = List.unmodifiable(sites.where((site) => site.id.isNotEmpty));
    _arrange();
  }

  static void arrange(Iterable<String> order) {
    _order = List.unmodifiable(order);
    _arrange();
  }

  static void _arrange() {
    int rank(SourceSite site) {
      final index = _order.indexOf(site.id);
      return index < 0 ? _order.length + _installed.indexOf(site) : index;
    }

    _all = List.unmodifiable(
      [..._installed]..sort((a, b) => rank(a).compareTo(rank(b))),
    );
    _available = List.unmodifiable(_all.where((site) => site.available));
  }

  static void installCustom(Iterable<SourceSite> sites) {
    final custom = {
      for (final site in sites)
        if (site.id.isNotEmpty) site.id: site,
    };
    _custom
      ..clear()
      ..addAll(custom);
  }

  static List<SourceSite> get allValues => _all;
  static List<SourceSite> get values => _available;
  static bool isCustomId(String id) => id.startsWith('custom:');

  /// 该 id 对应的源是否由站源模块提供。未知 id 一律为假。
  static bool isModule(String id) =>
      _available.any((site) => site.id == id && site.module);
  /// 自定义源（MacCMS / XBPQ 规则）不进核心的注册源列表，但属于本机已配置
  /// 的可用站源：核心侧同样按 `custom:` 前缀放行（见 Go 的
  /// `isCustomMaccmsSource`）。这里必须与之一致，否则站源列表能显示名字，
  /// 一点目录 / 详情 / 播放就被 AppRepository 拦成「当前版本不包含此站源」。
  static bool isAvailable(String id) =>
      _available.any((site) => site.id == id) || isCustomId(id);
  static bool isKnown(String id) => _all.any((site) => site.id == id);
  static bool isAdult(String id) =>
      _all.any((site) => site.id == id && site.adult);
  static SourceSite byId(String id) {
    for (final site in _all) {
      if (site.id == id) return site;
    }
    // 自定义源没有注册进核心，但显示名要从本机配置里取；
    // 都不认识时才退化成把 id 当名字。
    return _custom[id] ?? SourceSite(id, id, '', available: false);
  }
}

class SourceGroup {
  const SourceGroup(this.id, this.name, this.sources);
  final String id;
  final String name;
  final List<SourceSite> sources;

  static List<SourceGroup> fromSources(Iterable<SourceSite> sources) {
    final groups = <String, List<SourceSite>>{};
    for (final source in sources) {
      (groups[source.groupId] ??= []).add(source);
    }
    return [
      for (final group in groups.entries)
        SourceGroup(group.key, group.value.first.groupName, group.value),
    ];
  }

  /// 按站源类目分段：类目顺序固定（短剧类 → 视频类 → 黄果类 → 成人类 →
  /// 其他站源），空类目不出现；只有一个类目时调用方可以不画标题。
  static List<SourceGroup> byClass(Iterable<SourceSite> sources) {
    final buckets = <String, List<SourceSite>>{};
    for (final source in sources) {
      (buckets[source.classKey] ??= []).add(source);
    }
    final keys = buckets.keys.toList()
      ..sort((a, b) {
        final rank = SourceClass.rankOf(a).compareTo(SourceClass.rankOf(b));
        return rank != 0 ? rank : a.compareTo(b);
      });
    return [
      for (final key in keys)
        SourceGroup(key, SourceClass.labelOf(key), buckets[key]!),
    ];
  }
}

class CatalogCategory {
  const CatalogCategory(this.id, this.name, {this.local = false});
  static const all = CatalogCategory('', '全部');
  final String id;
  final String name;
  final bool local;
  factory CatalogCategory.fromJson(Map<String, dynamic> json) =>
      CatalogCategory(
        json['id'] as String? ?? '',
        json['name'] as String? ?? '全部',
      );
}

int intValue(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

class Drama {
  const Drama({
    required this.id,
    required this.source,
    required this.title,
    this.sourceId = '',
    this.description = '',
    this.cover = '',
    this.episodes = 0,
    this.category = '',
    bool? vip,
    this.heat = '',
    this.views = '',
    this.onlineDate = '',
    this.score = '',
    this.tags = const [],
    this.releaseStatus = '',
    this.badge = '',
    this.peers = const [],
  }) : vipStatus = vip;
  final String id;
  final String source;
  final String sourceId;
  final String title;
  final String description;
  final String cover;
  final int episodes;
  final String category;
  final bool? vipStatus;
  bool get vip => vipStatus == true;
  final String heat;
  final String views;
  final String onlineDate;
  final String score;
  final List<String> tags;
  final String releaseStatus;
  final String badge;

  /// 跨源聚合搜索里其它站源的同一部剧，供界面一键切换播放源。
  final List<Drama> peers;
  String get releaseLabel => switch (releaseStatus) {
    'finished' || 'completed' => '已完结',
    'ongoing' => '连载中',
    _ => '状态未知',
  };

  factory Drama.fromJson(Map<String, dynamic> json) => Drama(
    id: json['id'] as String? ?? '',
    source: json['source'] as String? ?? 'hongguo',
    sourceId: json['sourceId'] as String? ?? '',
    title: json['title'] as String? ?? '短剧',
    description: json['description'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    episodes: intValue(json['episodes']),
    category: json['category'] as String? ?? '',
    vip: json['vip'] == true
        ? true
        : json['vip'] == false &&
              (json['source'] != 'huangdou' ||
                  intValue(json['metadataSchema']) >= 1)
        ? false
        : null,
    heat: json['heat']?.toString() ?? '',
    views: json['views']?.toString() ?? '',
    onlineDate: json['onlineDate'] as String? ?? '',
    score: json['score'] as String? ?? '',
    tags: (json['tags'] as List? ?? const []).whereType<String>().toList(),
    releaseStatus: json['releaseStatus'] as String? ?? '',
    badge: json['badge'] as String? ?? '',
    peers: [
      for (final row in json['peers'] as List? ?? const [])
        Drama.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
  );
  Map<String, dynamic> toJson() => {
    'metadataSchema': 1,
    'id': id,
    'source': source,
    'sourceId': sourceId,
    'title': title,
    'description': description,
    'cover': cover,
    'episodes': episodes,
    'category': category,
    'vip': vipStatus,
    'heat': heat,
    'views': views,
    'onlineDate': onlineDate,
    'score': score,
    'tags': tags,
    'releaseStatus': releaseStatus,
    'badge': badge,
  };

  Drama merge(Drama fresh) {
    if (id != fresh.id) return fresh;
    const genericCategories = {
      '短剧',
      '真人剧',
      '漫剧',
      'AI剧',
      'AI 剧',
      'AI短剧',
      'AI 短剧',
      'AI漫剧',
      'AI 漫剧',
    };
    return Drama(
      id: id,
      source: fresh.source.isEmpty ? source : fresh.source,
      sourceId: fresh.sourceId.isEmpty ? sourceId : fresh.sourceId,
      title: fresh.title.isEmpty || fresh.title == '短剧' ? title : fresh.title,
      description: fresh.description.isEmpty ? description : fresh.description,
      cover: fresh.cover.isEmpty ? cover : fresh.cover,
      episodes: fresh.episodes > 0 ? fresh.episodes : episodes,
      category:
          fresh.category.isEmpty ||
              genericCategories.contains(fresh.category) &&
                  category.isNotEmpty &&
                  !genericCategories.contains(category)
          ? category
          : fresh.category,
      vip: fresh.vipStatus ?? vipStatus,
      heat: fresh.heat.isEmpty ? heat : fresh.heat,
      views: fresh.views.isEmpty ? views : fresh.views,
      onlineDate: fresh.onlineDate.isEmpty ? onlineDate : fresh.onlineDate,
      score: fresh.score.isEmpty ? score : fresh.score,
      tags: fresh.tags.isEmpty ? tags : fresh.tags,
      releaseStatus:
          fresh.releaseStatus.isEmpty || fresh.releaseStatus == 'unknown'
          ? releaseStatus
          : fresh.releaseStatus,
      badge: fresh.badge.isEmpty ? badge : fresh.badge,
    );
  }
}

class Episode {
  Episode(this.raw, int fallback)
    : id = raw['id'] as String? ?? '',
      title = raw['title'] as String? ?? '第$fallback集',
      number = intValue(raw['currentEpisode']) > 0
          ? intValue(raw['currentEpisode'])
          : fallback,
      vip = raw['vip'] == true,
      vertical = raw['vertical'] as bool?;
  final Map<String, dynamic> raw;
  final String id;
  final String title;
  final int number;
  final bool vip;
  final bool? vertical;
}

class DramaDetail {
  DramaDetail(
    this.drama,
    this.episodes, {
    this.warning = '',
    this.seasons = const [],
  });
  final Drama drama;
  final List<Episode> episodes;
  final String warning;
  final List<DramaSeason> seasons;

  DramaSeason? get nextSeason {
    final index = seasons.indexWhere((season) => season.drama.id == drama.id);
    return index < 0 || index + 1 >= seasons.length ? null : seasons[index + 1];
  }

  factory DramaDetail.fromJson(Map<String, dynamic> json) {
    final rows = json['chapters'] as List? ?? const [];
    return DramaDetail(
      Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
      [
        for (var i = 0; i < rows.length; i++)
          Episode(Map<String, dynamic>.from(rows[i] as Map), i + 1),
      ],
      warning: json['warning'] as String? ?? '',
    );
  }
}

class DramaSeason {
  const DramaSeason({required this.number, required this.drama});
  final int number;
  final Drama drama;

  String get label => '第$number季';

  bool get upcoming {
    final date = DateTime.tryParse(drama.onlineDate);
    if (date == null) return drama.episodes == 0;
    final now = DateTime.now();
    return date.isAfter(DateTime(now.year, now.month, now.day));
  }

  String? get onlineLabel {
    final date = DateTime.tryParse(drama.onlineDate);
    if (date == null) return null;
    String two(int value) => value.toString().padLeft(2, '0');
    final day = '${two(date.month)}-${two(date.day)}';
    return upcoming ? '$day 待上线' : '$day 上线';
  }

  factory DramaSeason.fromJson(Map<String, dynamic> json) => DramaSeason(
    number: json['number'] as int? ?? 0,
    drama: Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
  );
}

class CatalogPage {
  CatalogPage(
    this.items, {
    this.hasMore = false,
    this.warning = '',
    this.page = 1,
    this.fresh = false,
  });
  final List<Drama> items;
  final bool hasMore;
  final String warning;
  final int page;
  final bool fresh;
  factory CatalogPage.fromJson(Map<String, dynamic> json) => CatalogPage(
    [
      for (final row in json['items'] as List? ?? const [])
        Drama.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
    hasMore: json['hasMore'] == true,
    warning: json['warning'] as String? ?? '',
    page: intValue(json['page']) > 0 ? intValue(json['page']) : 1,
    fresh: json['fresh'] == true,
  );
}

class PlaybackPlan {
  const PlaybackPlan({
    required this.url,
    this.headers = const {},
    this.decryptionKey = '',
    this.quality = 0,
    this.qualities = const [],
    this.session = '',
    this.danmakuId = '',
    this.prefetchedBytes = 0,
    this.expiresAt = 0,
    this.routeIndex = 0,
    this.routeCount = 1,
    this.local = false,
    this.directUrl = '',
    this.verify = '',
  });
  final String url;

  /// 站源给出的原始播放地址。非空时投屏直接把它交给电视，电视自己上网拉流，
  /// 手机退出 App 也不影响播放；为空说明这条线路只能经手机转发。
  final String directUrl;
  final Map<String, String> headers;
  final String decryptionKey;
  final int quality;
  final List<int> qualities;
  final String session;
  final String danmakuId;
  final int prefetchedBytes;
  final int expiresAt;
  final int routeIndex;
  final int routeCount;
  final bool local;
  /// 非空表示这一集要先用隐藏浏览器完成验证；值是短链地址。
  final String verify;
  bool get hasAlternative => session.isNotEmpty && routeIndex + 1 < routeCount;
  factory PlaybackPlan.fromJson(Map<String, dynamic> json) => PlaybackPlan(
    url: json['url'] as String? ?? '',
    directUrl: json['directUrl'] as String? ?? '',
    local: json['local'] == true,
    verify: json['verify'] as String? ?? '',
    headers: (json['headers'] as Map? ?? {}).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    ),
    decryptionKey: json['decryptionKey'] as String? ?? '',
    quality: intValue(json['quality']),
    qualities: (json['qualities'] as List? ?? []).map(intValue).toSet().toList()
      ..sort((a, b) => b.compareTo(a)),
    session: json['session'] as String? ?? '',
    danmakuId: json['danmakuId'] as String? ?? '',
    prefetchedBytes: intValue(json['prefetchedBytes']),
    expiresAt: intValue(json['expiresAt']),
    routeIndex: intValue(json['routeIndex']),
    routeCount: intValue(json['routeCount']) > 0
        ? intValue(json['routeCount'])
        : 1,
  );
}

class WatchEntry {
  WatchEntry({
    required this.drama,
    required this.episode,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });
  final Drama drama;
  final int episode;
  final double position;
  final double duration;
  final DateTime updatedAt;
  bool get finished => duration > 1 && position >= duration - 1;
  Map<String, dynamic> toJson() => {
    'drama': drama.toJson(),
    'episode': episode,
    'position': position,
    'duration': duration,
    'updatedAt': updatedAt.toIso8601String(),
  };
  factory WatchEntry.fromJson(Map<String, dynamic> json) => WatchEntry(
    drama: Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
    episode: intValue(json['episode']),
    position: (json['position'] as num?)?.toDouble() ?? 0,
    duration: (json['duration'] as num?)?.toDouble() ?? 0,
    updatedAt:
        DateTime.tryParse(json['updatedAt'].toString()) ?? DateTime(2000),
  );
}

class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.drama,
    required this.episode,
    required this.state,
    this.bytes = 0,
    this.total = 0,
    this.progress = 0,
    this.quality = 0,
    this.actualQuality = 0,
    this.error = '',
    this.created = 0,
    this.revision = 0,
    this.archived = false,
  });
  final int created;
  final int revision;
  final bool archived;
  final String id;
  final Drama drama;
  final Episode episode;
  final String state;
  final int bytes;
  final int total;
  final double progress;
  final int quality;
  final int actualQuality;
  final String error;
  bool get completed => state == 'completed';
  bool get active => state == 'queued' || state == 'downloading';
  bool get resumable => state == 'paused' || state == 'failed';
  bool get converting => state == 'converting';
  String get stateLabel => switch (state) {
    'queued' => '等待下载',
    'downloading' => '正在下载',
    'converting' => '正在处理',
    'paused' => '已暂停',
    'failed' => '下载失败',
    'completed' => '已下载',
    'removing' => '正在取消',
    _ => '等待更新',
  };
  factory DownloadJob.fromJson(Map<String, dynamic> value) => DownloadJob(
    id: value['id'] as String? ?? '',
    drama: Drama.fromJson(Map<String, dynamic>.from(value['drama'] as Map)),
    episode: Episode(
      Map<String, dynamic>.from(value['chapter'] as Map),
      intValue(value['index']),
    ),
    state: value['state'] as String? ?? 'failed',
    bytes: intValue(value['bytes']),
    total: intValue(value['total']),
    progress: ((value['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
    quality: intValue(value['quality']),
    actualQuality: intValue(value['actualQuality']),
    error: value['error'] as String? ?? '',
    created: intValue(value['created']),
    revision: intValue(value['revision']),
    archived: value['archived'] == true,
  );
}

typedef DownloadConversion = ({String input, String key, String output});
typedef CastDevice = ({String id, String name});
typedef CastStatus = ({String state, double position, double duration});

List<Map<String, dynamic>> readJsonList(String? value) {
  try {
    return (jsonDecode(value ?? '[]') as List)
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  } catch (_) {
    return [];
  }
}

/// 自定义源（MacCMS 站点 / XBPQ 规则源）。移植自 guoappxp。
class CustomSourceSite {
  const CustomSourceSite({
    required this.id,
    required this.name,
    required this.base,
    this.rule = '',
    this.kind = '',
  });
  final String id;
  final String name;
  final String base;
  final String rule;

  /// 源类型：web=网页源（走 HTML 抓取）/ json=JSON 源（直连 API）/ 空=自动识别。
  final String kind;

  factory CustomSourceSite.fromJson(Map<String, dynamic> json) =>
      CustomSourceSite(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        base: json['base'] as String? ?? '',
        rule: json['rule'] as String? ?? '',
        kind: (json['kind'] as String? ?? json['type'] as String? ?? ''),
      );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'base': base,
    if (rule.isNotEmpty) 'rule': rule,
    if (kind.isNotEmpty) 'kind': kind,
  };
  bool get isCustom => SourceSite.isCustomId(id);
  bool get hasRule => rule.trim().isNotEmpty;
  SourceSite get asSourceSite => SourceSite(id, name, base);
}

/// 一轮跨源聚合搜索的增量快照。移植自 guoappxp。
///
/// 核心侧每个站源返回后都会更新快照，前端按 [id] 轮询即可看到结果陆续到位，
/// 不必等所有站源搜完；[pending] 是仍在搜的站源，[failures] 记录失败原因。
class SearchProgress {
  const SearchProgress({
    this.id = '',
    this.query = '',
    this.items = const [],
    this.sources = const [],
    this.pending = const [],
    this.failures = const {},
    this.warning = '',
    this.total = 0,
    this.done = 0,
    this.finished = false,
  });
  final String id;
  final String query;
  final List<Drama> items;

  /// 已成功返回的站源。
  final List<String> sources;

  /// 仍在搜索中的站源。
  final List<String> pending;
  final Map<String, String> failures;
  final String warning;
  final int total;
  final int done;
  final bool finished;

  bool get running => !finished;

  factory SearchProgress.fromJson(Map<String, dynamic> json) => SearchProgress(
    id: json['search'] as String? ?? '',
    query: json['query'] as String? ?? '',
    items: [
      for (final row in json['items'] as List? ?? const [])
        Drama.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
    sources: (json['sources'] as List? ?? const [])
        .whereType<String>()
        .toList(),
    pending: (json['pending'] as List? ?? const [])
        .whereType<String>()
        .toList(),
    failures: {
      for (final entry in (json['failures'] as Map? ?? const {}).entries)
        entry.key as String: '${entry.value}',
    },
    warning: json['warning'] as String? ?? '',
    total: intValue(json['total']),
    done: intValue(json['done']),
    finished: json['finished'] == true,
  );
}
