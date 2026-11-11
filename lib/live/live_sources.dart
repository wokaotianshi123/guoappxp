enum LiveProtocol { pingtai, list, room }

class LiveSource {
  const LiveSource({
    required this.id,
    required this.name,
    required this.description,
    required this.protocol,
    this.endpoints = const [],
    this.script = '',
    this.headers = const {},
    this.epg = '',
    this.proxies = const [],
    this.group = '',
    this.adult = false,
    this.builtin = true,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String description;
  final LiveProtocol protocol;

  /// 同一面板的多个镜像。它们共享内容但各自维护分类子集，合并后按分类路由。
  final List<String> endpoints;
  final String script;

  String get endpoint => endpoints.isEmpty ? '' : endpoints.first;
  final Map<String, String> headers;
  final String epg;

  /// 取流代理前缀。源站直连被拒时按顺序作为候选线路拼在原始地址前。
  final List<String> proxies;

  /// 列表型源没有分组信息时的默认分组名。
  final String group;

  /// 成人站源。绿色模式开启时整个源不出现在直播里。
  final bool adult;
  final bool builtin;
  final bool enabled;

  /// 是否支持按页续载。整类一次返回的源不参与滚动加载。
  bool get paginated =>
      protocol == LiveProtocol.list || protocol == LiveProtocol.room;

  /// 默认斗鱼，其次哔哩哔哩、虎牙，原有的秀果直播排在最后。
  static const values = <LiveSource>[
    LiveSource(
      id: 'douyu',
      name: '斗鱼',
      description: '游戏 · 娱乐 · 赛事',
      protocol: LiveProtocol.room,
      endpoints: ['https://www.douyu.com'],
    ),
    LiveSource(
      id: 'bilibili',
      name: '哔哩哔哩',
      description: '游戏 · 娱乐 · 赛事',
      protocol: LiveProtocol.room,
      endpoints: ['https://live.bilibili.com'],
    ),
    LiveSource(
      id: 'huya',
      name: '虎牙',
      description: '游戏 · 娱乐 · 赛事',
      protocol: LiveProtocol.room,
      endpoints: ['https://www.huya.com'],
    ),
    LiveSource(
      id: 'xiuguo',
      name: '秀果直播',
      description: '主播直播 · 实时开播',
      protocol: LiveProtocol.pingtai,
      endpoints: [
        'http://api.vipmisss.com:81/xcdsw',
        'http://api.hclyz.com:81/mf',
      ],
      adult: true,
    ),
  ];

  /// 绿色模式放行的直播分类名。改成白名单而不是罗列成人特征词：直播面板的
  /// 分类以「卡哇伊」「花蝴蝶」「蜜桃」「小妲己」这类花名为主，黑名单列不全，
  /// 实测 137 个分类里只有「卫视直播」属于公开电视直播，其余全是秀场。
  /// 白名单下没被明确认定为绿色的分类一律不展示。
  static final _greenCategory = RegExp(
    r'(卫视|央视|CCTV|CGTN|电视直播|广播|新闻|体育|财经|少儿|纪录|地方台|剧场|电影|电视剧)',
    caseSensitive: false,
  );

  /// 绿色模式下的直播可见性：秀果直播这类成人源整源隐藏；
  /// 斗鱼 / 哔哩哔哩 / 虎牙是公开平台，绿色模式下依然可见。
  static List<LiveSource> visible(bool greenMode) => [
    for (final source in values)
      if (!greenMode || !source.adult) source,
  ];

  /// 只过滤成人源的分类；公开平台即使有娱乐分区也不整类隐藏。
  static bool hidesCategory(
    String name, {
    required bool greenMode,
    bool adult = true,
  }) => greenMode && adult && !_greenCategory.hasMatch(name);

  /// 在既有内置源之外追加一个源，仅用于验证绿色模式的整源过滤。
  static List<LiveSource> spreadWith(
    LiveSource extra, {
    required bool greenMode,
  }) => [
    for (final source in [...values, extra])
      if (!greenMode || !source.adult) source,
  ];

  static LiveSource? byId(String id) =>
      values.where((source) => source.id == id).firstOrNull;

  static bool isBuiltin(String id) => values.any((source) => source.id == id);

  LiveSource copyWith({bool? enabled}) => LiveSource(
    id: id,
    name: name,
    description: description,
    protocol: protocol,
    endpoints: endpoints,
    script: script,
    headers: headers,
    epg: epg,
    proxies: proxies,
    group: group,
    adult: adult,
    builtin: builtin,
    enabled: enabled ?? this.enabled,
  );
}
