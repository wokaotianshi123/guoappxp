import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 在线听书音频的**本机**明文代理。
///
/// 为什么需要它：听书章节的真实地址是 CDN 上不带扩展名的路径，
/// 并且必须带 `Referer` / `User-Agent` 才返回音频。
/// 旧实现把裸 URL 和 `httpHeaders` 直接交给 libmpv，各平台对自定义请求头的
/// 支持并不一致：Windows 的 libmpv 常常忽略它们，CDN 返回非音频内容，
/// 于是「时长和进度都在走，但没有声音」，多见于 Windows 上的加密章节。
///
/// 这里在 Dart 层起一个只监听 127.0.0.1 的轻量服务：播放器拿到的永远是
/// `http://127.0.0.1:<port>/audio/<token>.m4a`（带容器扩展名，libmpv 能稳定
/// 探测 mov/mp4，CENC 的 decryption_key 也才能落到 demuxer），上游请求头由
/// Dart 侧统一注入，不再依赖播放器转发。同时透传 Range，拖动进度仍可用。
///
/// 关键：这是**纯 Dart 实现**。上一版把同样的代理放在 Go 核心里（新增
/// `streamUrl` 字段），但 `duanju_core.dll` / `libduanju_core.so` 是编译产物，
/// 没有重新执行 `build_native.py` 时核心里根本没有这段逻辑，`streamUrl` 不
/// 存在，播放器就又退回裸 URL，问题原样复现。放在 Dart 层只要重新构建
/// Flutter 应用就必定生效。
class AudiobookStreamProxy {
  AudiobookStreamProxy._();

  static final AudiobookStreamProxy instance = AudiobookStreamProxy._();

  HttpServer? _server;
  Future<HttpServer>? _starting;
  final Map<String, _AudiobookStreamEntry> _entries = {};

  /// 同时保留的书页条目上限：听书切章频繁，别让表无限增长。
  static const _maxEntries = 64;

  /// 把一条在线音频登记成本机地址。重复登记同一 URL + 请求头会得到同一个
  /// token，切章来回跳不会累积条目。
  Future<String> register(String url, Map<String, String> headers) async {
    final server = await _ensureServer();
    final source = '$url\x00${_headersKey(headers)}';
    final token = '${_stableHash(source)}-${utf8.encode(source).length}';
    if (!_entries.containsKey(token)) {
      _entries[token] = _AudiobookStreamEntry(
        url,
        Map<String, String>.of(headers),
      );
      while (_entries.length > _maxEntries) {
        _entries.remove(_entries.keys.first);
      }
    }
    return 'http://127.0.0.1:${server.port}/audio/$token.m4a';
  }

  static String _headersKey(Map<String, String> headers) {
    final keys = headers.keys.toList()..sort();
    return [for (final key in keys) '$key=${headers[key]}'].join('&');
  }

  /// FNV-1a 32 位：只为本次进程内几十条音频地址生成稳定短 token，
  /// 不需要引入额外的加密包，纯 dart:io 就能跑。
  static int _stableHash(String text) {
    var hash = 0x811c9dc5;
    for (final unit in utf8.encode(text)) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  Future<HttpServer> _ensureServer() {
    final existing = _server;
    if (existing != null) return Future<HttpServer>.value(existing);
    final starting = _starting;
    if (starting != null) return starting;
    final future = () async {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      // 只服务本机播放器；单个连接出错不能把整个服务带崩。
      unawaited(
        server.listen(_handle, onError: (Object _) {}).asFuture<void>(),
      );
      _server = server;
      _starting = null;
      return server;
    }();
    _starting = future;
    return future;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    final name = request.uri.pathSegments.isEmpty
        ? ''
        : request.uri.pathSegments.last;
    final token = name.endsWith('.m4a')
        ? name.substring(0, name.length - '.m4a'.length)
        : name;
    final entry = _entries[token];
    if (entry == null) {
      response.statusCode = HttpStatus.gone;
      await response.close();
      return;
    }

    // 不自动解压：一旦 Dart 替我们解了 gzip，回写的 Content-Length 就与
    // 实际字节数不符，连接会被强制断开，播放器表现为「放到一半没声」。
    final client = HttpClient()..autoUncompress = false;
    try {
      final upstream = await client.openUrl(
        request.method,
        Uri.parse(entry.url),
      );
      upstream.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      entry.headers.forEach((key, value) {
        if (value.isNotEmpty) upstream.headers.set(key, value);
      });
      for (final key in const ['range', 'if-range']) {
        final value = request.headers.value(key);
        if (value != null && value.isNotEmpty) {
          upstream.headers.set(key, value);
        }
      }
      final reply = await upstream.close();
      response.statusCode = reply.statusCode;
      for (final key in const [
        'content-type',
        'content-length',
        'content-range',
        'accept-ranges',
        'etag',
        'last-modified',
        'cache-control',
      ]) {
        final values = reply.headers[key];
        if (values != null && values.isNotEmpty) {
          response.headers.set(key, values.first);
        }
      }
      if (request.method == 'GET') {
        await response.addStream(reply);
      }
      await response.close();
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {
        // 播放器已经断开，忽略即可。
      }
    } finally {
      client.close(force: true);
    }
  }
}

class _AudiobookStreamEntry {
  const _AudiobookStreamEntry(this.url, this.headers);

  final String url;
  final Map<String, String> headers;
}

/// 判断一个地址是否已经指向本机（核心较新时会直接给出本机流地址）。
bool isLoopbackAudiobookUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  return host == '127.0.0.1' || host == 'localhost' || host == '::1';
}
