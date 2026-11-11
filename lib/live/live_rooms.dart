import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../core_bridge.dart';
import 'live_http.dart';
import 'live_models.dart';
import 'live_sources.dart';

const liveRoomPageSize = 30;
const bilibiliReferer = 'https://live.bilibili.com/';
const douyuReferer = 'https://www.douyu.com/';
const huyaReferer = 'https://www.huya.com/';
const douyuDeviceId = '10000000000000000000000000001501';

class LiveMediaChoice {
  const LiveMediaChoice({required this.url, required this.quality});

  final String url;
  final int quality;
}

class LiveRoomClient {
  const LiveRoomClient(this._http);

  final LiveHttp _http;

  Future<List<LivePlatform>> platforms(LiveSource source) {
    return switch (source.id) {
      'bilibili' => _bilibiliPlatforms(),
      'douyu' => _douyuPlatforms(),
      'huya' => _huyaPlatforms(),
      _ => Future<List<LivePlatform>>.error(AppFailure('该直播源没有可用分类')),
    };
  }

  Future<List<LiveChannel>> channels(
    LiveSource source,
    LivePlatform platform, {
    required int page,
  }) {
    final current = page < 1 ? 1 : page;
    return switch (source.id) {
      'bilibili' => _bilibiliChannels(source, platform, current),
      'douyu' => _douyuChannels(source, platform, current),
      'huya' => _huyaChannels(source, platform, current),
      _ => Future<List<LiveChannel>>.error(AppFailure('该分类暂时没有频道')),
    };
  }

  Future<LivePlayback> playback(LiveSource source, LiveChannel channel) {
    final room = channel.token.trim();
    if (room.isEmpty) {
      return Future<LivePlayback>.error(AppFailure('该频道没有可用线路'));
    }
    return switch (source.id) {
      'bilibili' => _bilibiliPlayback(room),
      'douyu' => _douyuPlayback(room),
      'huya' => _huyaPlayback(room),
      _ => Future<LivePlayback>.error(AppFailure('该频道没有可用线路')),
    };
  }

  Future<List<LivePlatform>> _bilibiliPlatforms() async {
    final json = await _object(
      'https://api.live.bilibili.com/room/v1/Area/getList',
      _headers(bilibiliReferer),
    );
    _accept(json, 'code', 0);
    final platforms = <LivePlatform>[];
    final seen = <String>{};
    for (final row in liveJsonMaps(json['data'])) {
      final id = liveJsonText(row['id']);
      final name = liveJsonText(row['name']);
      if (id.isEmpty || name.isEmpty || !seen.add(id)) continue;
      platforms.add(LivePlatform(id: id, name: name));
    }
    return platforms;
  }

  Future<List<LiveChannel>> _bilibiliChannels(
    LiveSource source,
    LivePlatform platform,
    int page,
  ) async {
    final json = await _object(
      'https://api.live.bilibili.com/room/v3/Area/getRoomList'
      '?platform=web&parent_area_id=${Uri.encodeQueryComponent(platform.id)}'
      '&cate_id=0&area_id=0&sort_type=online&page=$page'
      '&page_size=$liveRoomPageSize',
      _headers(bilibiliReferer),
    );
    _accept(json, 'code', 0);
    return _rooms(
      source,
      platform,
      liveJsonMaps(liveJsonMap(json['data'])?['list']),
      referer: bilibiliReferer,
      idOf: (row) => liveJsonText(row['roomid']),
      nameOf: (row) => liveJsonText(row['title']),
      hostOf: (row) => liveJsonText(row['uname']),
      logoOf: (row) => liveJsonText(row['user_cover']),
      audienceOf: (row) => row['online'],
    );
  }

  Future<LivePlayback> _bilibiliPlayback(String room) async {
    final json = await _object(
      'https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo'
      '?room_id=${Uri.encodeQueryComponent(room)}'
      '&protocol=0,1&format=0,1,2&codec=0,1&qn=10000'
      '&platform=web&ptype=8&dolby=5&panorama=1',
      _headers(bilibiliReferer),
    );
    _accept(json, 'code', 0);
    final choice = bilibiliBestPlay(json);
    if (choice == null) throw AppFailure('该直播间当前没有可播放的地址');
    return _playback(choice.url, bilibiliReferer);
  }

  Future<List<LivePlatform>> _douyuPlatforms() async {
    final json = await _object(
      'https://m.douyu.com/api/cate/list',
      _headers('https://m.douyu.com/'),
    );
    _accept(json, 'code', 0);
    final platforms = <LivePlatform>[];
    final seen = <String>{};
    for (final row in liveJsonMaps(liveJsonMap(json['data'])?['cate2Info'])) {
      final id = liveJsonText(row['cate2Id']);
      final name = liveJsonText(row['cate2Name']);
      if (id.isEmpty || name.isEmpty || !seen.add(id)) continue;
      if (row.containsKey('count') && liveJsonInt(row['count']) <= 0) continue;
      platforms.add(
        LivePlatform(id: id, name: name, count: liveJsonInt(row['count'])),
      );
    }
    return platforms;
  }

  Future<List<LiveChannel>> _douyuChannels(
    LiveSource source,
    LivePlatform platform,
    int page,
  ) async {
    final json = await _object(
      'https://www.douyu.com/gapi/rkc/directory/mixList/2_${platform.id}/$page',
      _headers(douyuReferer),
    );
    _accept(json, 'code', 0);
    return _rooms(
      source,
      platform,
      liveJsonMaps(liveJsonMap(json['data'])?['rl']),
      referer: douyuReferer,
      idOf: (row) => liveJsonText(row['rid']),
      nameOf: (row) => liveJsonText(row['rn']),
      hostOf: (row) => liveJsonText(row['nn']),
      logoOf: (row) => liveJsonText(row['rs16']),
      audienceOf: (row) => row['ol'],
    );
  }

  Future<LivePlayback> _douyuPlayback(String room) async {
    final first = await _douyuStream(room, 0);
    if (first == null) throw AppFailure('该直播间当前没有可播放的地址');
    final preferred = douyuPreferredRate(first['multirates']);
    var chosen = first;
    if (preferred != null && preferred != 0) {
      final again = await _douyuStream(room, preferred);
      if (again != null && douyuPlayUrl(again) != null) chosen = again;
    }
    final url = douyuPlayUrl(chosen);
    if (url == null) throw AppFailure('该直播间当前没有可播放的地址');
    return _playback(url, douyuReferer);
  }

  Future<Map<String, dynamic>?> _douyuStream(String room, int rate) async {
    final encrypted = await _http.getResult(
      'https://www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption'
      '?did=$douyuDeviceId',
      headers: _headers(douyuReferer),
    );
    final envelope = liveJsonMap(liveDecode(encrypted.body));
    if (envelope == null) throw AppFailure('直播源返回的内容无法识别');
    _accept(envelope, 'error', 0);
    final data = liveJsonMap(envelope['data']);
    if (data == null) throw AppFailure('该直播源暂时不可用');
    final key = liveJsonText(data['key']);
    final rand = liveJsonText(data['rand_str']);
    final encData = liveJsonText(data['enc_data']);
    final encTime = liveJsonInt(data['enc_time']);
    if (key.isEmpty ||
        rand.isEmpty ||
        encData.isEmpty ||
        encTime < 0 ||
        encTime > 4096) {
      throw AppFailure('该直播源暂时不可用');
    }
    final timestamp = _unixSeconds(encrypted.date);
    final body = liveForm({
      'enc_data': encData,
      'tt': '$timestamp',
      'did': douyuDeviceId,
      'auth': douyuAuth(
        roomId: room,
        timestamp: timestamp,
        key: key,
        randStr: rand,
        encTime: encTime,
        special: liveJsonInt(data['is_special']),
      ),
      'cdn': '',
      'rate': '$rate',
      'hevc': '0',
      'fa': '0',
      'ive': '0',
    });
    final play = liveJsonMap(
      liveDecode(
        await _http.postForm(
          'https://www.douyu.com/lapi/live/getH5PlayV1/$room',
          body,
          headers: _headers(douyuReferer),
        ),
      ),
    );
    if (play == null) throw AppFailure('直播源返回的内容无法识别');
    if (liveJsonInt(play['error']) != 0) return null;
    return liveJsonMap(play['data']);
  }

  Future<List<LivePlatform>> _huyaPlatforms() async {
    final json = await _object(
      'https://www.huya.com/cache.php?m=Game&do=getGameList',
      _headers(huyaReferer),
    );
    _accept(json, 'status', 200);
    final platforms = <LivePlatform>[];
    final seen = <String>{};
    for (final row in liveJsonMaps(json['gameList'])) {
      final id = liveJsonText(row['gid']);
      final name = liveJsonText(row['gameFullName']);
      if (id.isEmpty || name.isEmpty || !seen.add(id)) continue;
      if (liveJsonInt(row['isHide']) == 1) continue;
      if (row.containsKey('profileNum') &&
          liveJsonInt(row['profileNum']) <= 0) {
        continue;
      }
      platforms.add(
        LivePlatform(id: id, name: name, count: liveJsonInt(row['profileNum'])),
      );
    }
    return platforms;
  }

  Future<List<LiveChannel>> _huyaChannels(
    LiveSource source,
    LivePlatform platform,
    int page,
  ) async {
    final json = await _object(
      'https://www.huya.com/cache.php?m=LiveList&do=getLiveListByPage'
      '&gameId=${Uri.encodeQueryComponent(platform.id)}&tagAll=0&page=$page',
      _headers(huyaReferer),
    );
    _accept(json, 'status', 200);
    return _rooms(
      source,
      platform,
      liveJsonMaps(liveJsonMap(json['data'])?['datas']),
      referer: huyaReferer,
      idOf: (row) => liveJsonText(row['profileRoom']),
      nameOf: (row) => liveJsonText(row['roomName']),
      hostOf: (row) => liveJsonText(row['nick']),
      logoOf: (row) => liveJsonText(row['screenshot']),
      audienceOf: (row) => row['totalCount'],
    );
  }

  Future<LivePlayback> _huyaPlayback(String room) async {
    final json = await _object(
      'https://mp.huya.com/cache.php?m=Live&do=profileRoom'
      '&roomid=${Uri.encodeQueryComponent(room)}',
      _headers(huyaReferer),
    );
    _accept(json, 'status', 200);
    final url = huyaBestFlv(liveJsonMap(json['data'])?['stream']);
    if (url == null) throw AppFailure('该直播间当前没有可播放的地址');
    // 这条地址的 anti-code 是 `ctype=tars_mp`，必须配虎牙客户端 UA 才不会被
    // 秒断，详见 huyaLiveUserAgent。
    return _playback(url, huyaReferer, userAgent: huyaLiveUserAgent);
  }

  Future<Map<String, dynamic>> _object(
    String url,
    Map<String, String> headers,
  ) async {
    final json = liveJsonMap(
      liveDecode(await _http.get(url, headers: headers)),
    );
    if (json == null) throw AppFailure('直播源返回的内容无法识别');
    return json;
  }

  List<LiveChannel> _rooms(
    LiveSource source,
    LivePlatform platform,
    List<Map<String, dynamic>> rows, {
    required String referer,
    required String Function(Map<String, dynamic> row) idOf,
    required String Function(Map<String, dynamic> row) nameOf,
    required String Function(Map<String, dynamic> row) hostOf,
    required String Function(Map<String, dynamic> row) logoOf,
    required Object? Function(Map<String, dynamic> row) audienceOf,
  }) {
    final channels = <LiveChannel>[];
    final seen = <String>{};
    for (final row in rows) {
      final room = idOf(row);
      final host = hostOf(row);
      final roomTitle = nameOf(row);
      final name = host.isEmpty ? roomTitle : host;
      if (room.isEmpty || name.isEmpty || !seen.add(room)) continue;
      final audience = liveAudience(audienceOf(row));
      final subtitle = [
        if (roomTitle.isNotEmpty && roomTitle != name) roomTitle,
        if (audience.isNotEmpty) audience,
      ].join(' · ');
      channels.add(
        LiveChannel(
          key: LiveChannel.makeKey(source.id, platform.name, room),
          name: name,
          urls: const [],
          headers: _headers(referer),
          logo: logoOf(row),
          group: platform.name,
          source: source.id,
          token: room,
          subtitle: subtitle,
        ),
      );
    }
    return channels;
  }

  LivePlayback _playback(String url, String referer, {String? userAgent}) {
    if (!isPlayableLiveUrl(url)) throw AppFailure('该直播间当前没有可播放的地址');
    return LivePlayback(
      url: url,
      headers: _headers(referer, userAgent: userAgent),
    );
  }

  Map<String, String> _headers(String referer, {String? userAgent}) =>
      livePlaybackHeaders(referer, userAgent: userAgent);

  void _accept(Map<String, dynamic> json, String key, int ok) {
    if (!json.containsKey(key) || liveJsonInt(json[key]) == ok) return;
    throw AppFailure('该直播源暂时不可用');
  }

  int _unixSeconds(DateTime? date) =>
      (date ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
}

Object? liveDecode(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    throw AppFailure('直播源返回的内容无法识别');
  }
}

Map<String, dynamic>? liveJsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return null;
}

List<Map<String, dynamic>> liveJsonMaps(Object? value) {
  if (value is! List) return const [];
  final rows = <Map<String, dynamic>>[];
  for (final item in value) {
    final row = liveJsonMap(item);
    if (row != null) rows.add(row);
  }
  return rows;
}

String liveJsonText(Object? value) {
  if (value == null) return '';
  return '$value'.trim();
}

int liveJsonInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(liveJsonText(value)) ?? 0;
}

String liveAudience(Object? value) {
  final count = liveJsonInt(value);
  if (count <= 0) return '';
  return '在线 $count';
}

String liveForm(Map<String, String> fields) => fields.entries
    .map(
      (entry) =>
          '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
    )
    .join('&');

String douyuAuth({
  required String roomId,
  required int timestamp,
  required String key,
  required String randStr,
  required int encTime,
  required int special,
}) {
  var value = randStr;
  final rounds = encTime < 0 ? 0 : encTime;
  for (var index = 0; index < rounds; index++) {
    value = md5.convert(utf8.encode('$value$key')).toString();
  }
  final suffix = special == 1 ? '' : '$roomId$timestamp';
  return md5.convert(utf8.encode('$value$key$suffix')).toString();
}

int? douyuPreferredRate(Object? rows) {
  final list = liveJsonMaps(rows);
  if (list.isEmpty) return null;
  var rate = 0;
  var weight = -1;
  for (final row in list) {
    final bit = liveJsonInt(row['bit']);
    final score = bit <= 0 ? 1 << 62 : bit;
    if (score <= weight) continue;
    weight = score;
    rate = liveJsonInt(row['rate']);
  }
  return rate;
}

String? douyuPlayUrl(Map<String, dynamic> data) {
  final base = liveJsonText(data['rtmp_url']);
  final live = liveJsonText(data['rtmp_live']);
  if (base.isEmpty || live.isEmpty) return null;
  if (live.contains('://')) return live;
  final root = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  final path = live.startsWith('/') ? live.substring(1) : live;
  return '$root/$path';
}

String? joinLiveMediaUrl(String host, String base, String extra) {
  final origin = host.trim();
  final path = base.trim();
  if (origin.isEmpty || path.isEmpty) return null;
  var joined = origin;
  if (path.contains('://')) {
    joined = path;
  } else {
    if (joined.endsWith('/') && path.startsWith('/')) {
      joined = joined.substring(0, joined.length - 1);
    } else if (!joined.endsWith('/') && !path.startsWith('/')) {
      joined = '$joined/';
    }
    joined = '$joined$path';
  }
  final tail = extra.trim();
  if (tail.isEmpty) return joined;
  if (tail.startsWith('?') || tail.startsWith('&')) {
    if (joined.contains('?') && tail.startsWith('?')) {
      return '$joined&${tail.substring(1)}';
    }
    return '$joined$tail';
  }
  if (joined.endsWith('?') || joined.endsWith('&')) return '$joined$tail';
  return joined.contains('?') ? '$joined&$tail' : '$joined?$tail';
}

LiveMediaChoice? bilibiliBestPlay(Object? decoded) {
  final play = liveJsonMap(
    liveJsonMap(
      liveJsonMap(liveJsonMap(decoded)?['data'])?['playurl_info'],
    )?['playurl'],
  );
  LiveMediaChoice? best;
  var bestFlv = false;
  for (final stream in liveJsonMaps(play?['stream'])) {
    final httpStream = liveJsonText(stream['protocol_name']) == 'http_stream';
    for (final format in liveJsonMaps(stream['format'])) {
      final flv = httpStream || liveJsonText(format['format_name']) == 'flv';
      for (final codec in liveJsonMaps(format['codec'])) {
        final quality = liveJsonInt(codec['current_qn']);
        final url = _bilibiliUrl(codec);
        if (url == null) continue;
        final better =
            best == null ||
            quality > best.quality ||
            (quality == best.quality && flv && !bestFlv);
        if (!better) continue;
        best = LiveMediaChoice(url: url, quality: quality);
        bestFlv = flv;
      }
    }
  }
  return best;
}

String? _bilibiliUrl(Map<String, dynamic> codec) {
  final base = liveJsonText(codec['base_url']);
  for (final info in liveJsonMaps(codec['url_info'])) {
    final url = joinLiveMediaUrl(
      liveJsonText(info['host']),
      base,
      liveJsonText(info['extra']),
    );
    if (url != null && isPlayableLiveUrl(url)) return url;
  }
  return null;
}

String? huyaBestFlv(Object? stream) {
  final root = liveJsonMap(stream);
  final rows = liveJsonMaps(root?['baseSteamInfoList'] ?? stream);
  String? best;
  var bestMaster = false;
  var bestRate = -1 << 31;
  for (final row in rows) {
    final url = huyaLineUrl(row);
    if (url == null) continue;
    final master = liveJsonInt(row['iIsMaster']) == 1;
    final rate = liveJsonInt(row['iPCPriorityRate']);
    final better =
        best == null ||
        (master && !bestMaster) ||
        (master == bestMaster && rate > bestRate);
    if (!better) continue;
    best = url;
    bestMaster = master;
    bestRate = rate;
  }
  return best;
}

String? huyaLineUrl(Map<String, dynamic> row) {
  final host = liveJsonText(row['sFlvUrl']);
  final name = liveJsonText(row['sStreamName']);
  final suffix = liveJsonText(row['sFlvUrlSuffix']);
  final anti = liveJsonText(row['sFlvAntiCode']);
  if (host.isEmpty || name.isEmpty || suffix.isEmpty) return null;
  final root = host.endsWith('/') ? host.substring(0, host.length - 1) : host;
  if (anti.isEmpty) return '$root/$name.$suffix';
  if (anti.startsWith('?') || anti.startsWith('&')) {
    return '$root/$name.$suffix$anti';
  }
  return '$root/$name.$suffix?$anti';
}
