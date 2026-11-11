import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core_bridge.dart';
import 'live_models.dart';

const liveRequestTimeout = Duration(seconds: 14);

/// 线路预检超时。比正常请求短得多：预检只为排序，慢线路按「不可用」处理，
/// 不能让用户停在列表页等一条 14 秒的超时。
const liveRouteProbeTimeout = Duration(seconds: 4);
const _maxLiveBytes = 8 << 20;
const _deviceInfo = '{"t":"webPc","v":"1.0","ui":"0","ck":{"sessKeyAsp":""}}';

String get liveDeviceInfo => _deviceInfo;

class LiveHttpResult {
  const LiveHttpResult(this.body, {this.date});

  final String body;
  final DateTime? date;
}

class LiveHttp {
  LiveHttp();

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  final Map<String, String> _cookies = {};

  void close() => _client.close(force: true);

  Future<LiveHttpResult> getResult(
    String url, {
    Map<String, String> headers = const {},
  }) => _send(url, method: 'GET', headers: headers);

  Future<String> get(
    String url, {
    Map<String, String> headers = const {},
  }) async => (await getResult(url, headers: headers)).body;

  Future<String> postForm(
    String url,
    String body, {
    Map<String, String> headers = const {},
  }) async =>
      (await _send(url, method: 'POST', body: body, headers: headers)).body;

  Future<String> postJson(
    String url,
    Object body, {
    Map<String, String> headers = const {},
  }) async => (await _send(
    url,
    method: 'POST',
    body: jsonEncode(body),
    contentType: 'application/json',
    headers: headers,
  )).body;

  Future<LiveHttpResult> _send(
    String url, {
    required String method,
    String body = '',
    String contentType = '',
    Map<String, String> headers = const {},
    Duration timeout = liveRequestTimeout,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('直播源地址无效');
    }
    try {
      final request = method == 'POST'
          ? await _client.postUrl(uri).timeout(timeout)
          : await _client.getUrl(uri).timeout(timeout);
      request.followRedirects = true;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        headers['User-Agent'] ?? liveUserAgent,
      );
      if (_cookies.isNotEmpty) {
        request.headers.set(
          HttpHeaders.cookieHeader,
          _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
        );
      }
      headers.forEach((key, value) {
        final name = key.toLowerCase();
        if (name == 'user-agent' || name == 'cookie' || value.isEmpty) return;
        request.headers.set(key, value);
      });
      if (method == 'POST') {
        request.headers.contentType = ContentType.parse(
          contentType.isEmpty
              ? 'application/x-www-form-urlencoded; charset=UTF-8'
              : contentType,
        );
        request.write(body);
      }
      final response = await request.close().timeout(timeout);
      _rememberCookies(response);
      final date = _responseDate(response);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw AppFailure('直播源返回 ${response.statusCode}');
      }
      return LiveHttpResult(
        _decode(await _collect(response).timeout(timeout)),
        date: date,
      );
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      throw AppFailure('直播源连接超时');
    } on HandshakeException {
      throw AppFailure('直播源证书校验失败');
    } on SocketException {
      throw AppFailure('无法连接直播源');
    } on FormatException {
      throw AppFailure('直播源返回的内容无法识别');
    }
  }

  static DateTime? _responseDate(HttpClientResponse response) {
    final value = response.headers.value(HttpHeaders.dateHeader);
    if (value == null || value.isEmpty) return null;
    try {
      return HttpDate.parse(value);
    } on Exception {
      return null;
    }
  }

  void _rememberCookies(HttpClientResponse response) {
    final values = response.headers[HttpHeaders.setCookieHeader];
    if (values == null) return;
    for (final value in values) {
      final at = value.indexOf('=');
      if (at <= 0) continue;
      final name = value.substring(0, at).trim();
      if (name.isEmpty) continue;
      final semi = value.indexOf(';');
      final raw = semi < 0
          ? value.substring(at + 1)
          : value.substring(at + 1, semi);
      _cookies[name] = raw.trim();
    }
  }

  static Future<Uint8List> _collect(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (builder.length > _maxLiveBytes) {
        throw AppFailure('直播源返回的数据过大');
      }
    }
    return builder.takeBytes();
  }

  static String _decode(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
}
