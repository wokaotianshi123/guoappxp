import 'dart:convert';

class LiveChannel {
  const LiveChannel({
    required this.key,
    required this.name,
    required this.urls,
    this.number = '',
    this.headers = const {},
    this.logo = '',
    this.group = '',
    this.source = '',
    this.tvgId = '',
    this.token = '',
    this.subtitle = '',
  });

  final String key;
  final String name;
  final List<String> urls;
  final String number;
  final Map<String, String> headers;
  final String logo;
  final String group;
  final String source;
  final String tvgId;
  final String token;
  final String subtitle;

  String get url => urls.isEmpty ? '' : urls.first;
  bool get playable => urls.any(isPlayableLiveUrl);
  String get label => number.isEmpty ? name : '$number  $name';

  LiveChannel withUrls(List<String> values) => LiveChannel(
    key: key,
    name: name,
    urls: values,
    number: number,
    headers: headers,
    logo: logo,
    group: group,
    source: source,
    tvgId: tvgId,
    token: token,
    subtitle: subtitle,
  );

  LiveChannel withPlayback(String value, Map<String, String> values) =>
      LiveChannel(
        key: key,
        name: name,
        urls: [value],
        number: number,
        headers: mergeLiveHeaders(headers, values),
        logo: logo,
        group: group,
        source: source,
        tvgId: tvgId,
        token: token,
        subtitle: subtitle,
      );

  static String makeKey(String source, String group, String name) =>
      '$source\u0000$group\u0000$name';

  Map<String, dynamic> toFavourite() => {
    'key': key,
    'name': name,
    'group': group,
    'source': source,
    'url': url,
    'urls': urls,
    'headers': headers,
    'logo': logo,
    'number': number,
    'token': token,
    'subtitle': subtitle,
  };

  static LiveChannel fromFavourite(Map<String, dynamic> json) => LiveChannel(
    key: json['key'] as String? ?? '',
    name: json['name'] as String? ?? '',
    urls: (json['urls'] as List? ?? [json['url']])
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toList(),
    headers: (json['headers'] as Map? ?? {}).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    ),
    logo: json['logo'] as String? ?? '',
    group: json['group'] as String? ?? '',
    source: json['source'] as String? ?? '',
    number: json['number'] as String? ?? '',
    token: json['token'] as String? ?? '',
    subtitle: json['subtitle'] as String? ?? '',
  );
}

class LiveGroup {
  const LiveGroup(this.name, this.channels);
  final String name;
  final List<LiveChannel> channels;

  int get count => channels.length;
}

class LiveLine {
  const LiveLine({
    required this.group,
    required this.channel,
    required this.index,
  });
  final String group;
  final LiveChannel channel;
  final int index;
}

class LivePlatform {
  const LivePlatform({
    required this.id,
    required this.name,
    this.logo = '',
    this.count = 0,
    this.subtitle = '',
    this.endpoint = '',
  });

  final String id;
  final String name;
  final String logo;
  final int count;
  final String subtitle;

  /// 提供该分类的镜像地址。同一面板的不同镜像各自维护分类子集， поэтому
  /// 分类要记住它来自哪个镜像，取频道时才不会请求到对不上的域名。
  final String endpoint;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'logo': logo,
    'count': count,
    'subtitle': subtitle,
    'endpoint': endpoint,
  };

  static LivePlatform fromJson(Map<String, dynamic> json) => LivePlatform(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    logo: json['logo'] as String? ?? '',
    count: json['count'] as int? ?? 0,
    subtitle: json['subtitle'] as String? ?? '',
    endpoint: json['endpoint'] as String? ?? '',
  );
}

class LivePlayback {
  const LivePlayback({required this.url, this.headers = const {}});
  final String url;
  final Map<String, String> headers;
}

const livePageSize = 60;
const liveUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36';

/// 虎牙取流专用的客户端标识。
///
/// `mp.huya.com` 下发的取流地址带 `ctype=tars_mp`，CDN 只认虎牙自家客户端。
/// 用浏览器 UA 去拉仍然返回 200，但只吐出几百 KB（约 3 秒画面）就主动断开，
/// 表现就是「播几秒断流」；换成虎牙客户端的 UA 后同一条地址可以稳定拉满。
const huyaLiveUserAgent =
    'HYSDK(Windows,30000002)_APP(pc_exe&50108&official)'
    '_SDK(android,6.8.0)_PLATFORM(internal)_OS(micromac)';

/// 房间型直播源的取流头。Referer 决定防盗链，User-Agent 决定 CDN 认不认这个
/// 客户端——虎牙必须带客户端标识，否则只能播几秒。
Map<String, String> livePlaybackHeaders(String referer, {String? userAgent}) =>
    {'Referer': referer, 'User-Agent': (userAgent ?? liveUserAgent).trim()};

bool isPlayableLiveUrl(String url) {
  final text = url.trim();
  if (!text.contains('://')) return false;
  final scheme = text.split('://').first.toLowerCase();
  return const {
    'http',
    'https',
    'rtmp',
    'rtsp',
    'rtp',
    'udp',
    'rtmps',
    'rtmpe',
    'rtmpt',
  }.contains(scheme);
}

Map<String, String> parseLiveHeaders(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const {};
  final result = <String, String>{};
  dynamic decoded;
  if (text.startsWith('{')) {
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      decoded = null;
    }
  }
  if (decoded is Map) {
    for (final entry in decoded.entries) {
      result[entry.key.toString()] = entry.value.toString();
    }
    return result;
  }
  for (final pair in text.split(RegExp(r'[&;]'))) {
    final at = pair.indexOf('=');
    if (at <= 0) continue;
    final key = pair.substring(0, at).trim();
    final value = pair.substring(at + 1).trim();
    if (key.isEmpty || value.isEmpty) continue;
    result[key] = value;
  }
  return result;
}

Map<String, String> mergeLiveHeaders(
  Map<String, String> base,
  Map<String, String> extra,
) {
  if (base.isEmpty) return extra;
  if (extra.isEmpty) return base;
  return {...base, ...extra};
}
