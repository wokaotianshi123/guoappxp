import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 播放流的**本机 HLS 代理**，负责去广告。
///
/// 为什么需要它：去广告原本只实现在 Go 核心的 `nativeOpen` 里（见
/// `native/core/app_adfilter.go`），只对核心自己创建的本地流会话生效。
/// JS 沙箱、PY 沙箱返回的是站源给的原始直链，播放器直接连上游，
/// 那一层完全不介入——于是「设置里开了去广告，沙箱源照样有广告」。
///
/// 这里把播放地址包一层：播放器拿到的是 `http://127.0.0.1:<port>/hls/<token>`，
/// 代理去上游取清单、清洗广告分片、把分片地址改写成绝对地址再交回去。
/// 分片本身仍然直连 CDN（libmpv 会把 http-header-fields 带到每个分片请求），
/// 所以只多一次清单请求，不额外吃带宽。
///
/// 与 `AudiobookStreamProxy` 同一套做法：纯 Dart 实现，重新构建 Flutter
/// 应用就生效，不依赖重新编译 Go 核心。
class PlaybackStreamProxy {
  PlaybackStreamProxy._();

  static final PlaybackStreamProxy instance = PlaybackStreamProxy._();

  HttpServer? _server;
  Future<HttpServer>? _starting;
  final Map<String, _ProxyEntry> _entries = {};

  /// 同时保留的条目上限。切集频繁，别让表无限增长。
  static const _maxEntries = 48;

  /// 清单正文上限：m3u8 正常只有几十 KB，超过这个量级说明不是清单。
  static const _maxPlaylistBytes = 8 * 1024 * 1024;

  /// 把一条播放地址登记成去广告代理地址。
  ///
  /// 只有「看起来是 HLS」的地址才会被接管：
  ///   * 路径里带 `.m3u8` → 直接接管；
  ///   * 带 `.mp4` / `.mkv` / `.flv` / `.ts` 等确定是单文件 → 原样返回；
  ///   * 其余（无扩展名的 CDN 路径，HLS 常这么藏）→ 取前 1KB 探一下。
  ///
  /// [enabled] 为 false 时直接返回原地址，不产生任何请求。
  Future<String> wrap(
    String url, {
    required bool enabled,
    Map<String, String> headers = const {},
  }) async {
    if (!enabled) return url;
    final trimmed = url.trim();
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      return url;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return url;
    // 已经是本机地址（核心给的本地流）就别再套一层。
    if (_isLoopback(uri.host)) return url;

    final path = uri.path.toLowerCase();
    if (RegExp(r'\.(mp4|mkv|flv|ts|m4v|mov|webm)$').hasMatch(path)) {
      return url;
    }
    if (!path.contains('.m3u8')) {
      // 无扩展名：探一次，是清单才接管。
      final isHls = await _probeHls(uri, headers);
      if (!isHls) return url;
    }

    final HttpServer server;
    try {
      server = await _ensureServer();
    } catch (_) {
      // 端口起不来（极少数受限环境）时退回原地址：宁可没去广告，也不能不能播。
      return url;
    }
    final token = _register(trimmed, headers);
    return 'http://127.0.0.1:${server.port}/hls/$token';
  }

  static bool _isLoopback(String host) =>
      host == '127.0.0.1' || host == 'localhost' || host == '::1';

  /// 取前 1KB 判断是不是 m3u8 清单。
  Future<bool> _probeHls(Uri uri, Map<String, String> headers) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..autoUncompress = false;
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      headers.forEach((key, value) {
        if (value.isNotEmpty) request.headers.set(key, value);
      });
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return false;
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 8))) {
        bytes.addAll(chunk.take(1024 - bytes.length));
        if (bytes.length >= 1024) break;
      }
      return _looksLikePlaylist(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static bool _looksLikePlaylist(String text) {
    final head = text.trimLeft();
    return head.startsWith('#EXTM3U') || head.contains('#EXTINF');
  }

  String _register(String url, Map<String, String> headers) {
    final key = '$url\x00${_headersKey(headers)}';
    final token = _stableHash(key).toRadixString(16);
    _entries.remove(token);
    _entries[token] = _ProxyEntry(url, Map<String, String>.of(headers));
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return token;
  }

  static String _headersKey(Map<String, String> headers) {
    final keys = headers.keys.toList()..sort();
    return [for (final key in keys) '$key=${headers[key]}'].join('&');
  }

  /// FNV-1a 32 位：只为进程内的几十条地址生成稳定短 token。
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
    final segments = request.uri.pathSegments;
    final token = segments.length >= 2 && segments.first == 'hls'
        ? segments[1]
        : '';
    final entry = _entries[token];
    if (entry == null) {
      response.statusCode = HttpStatus.gone;
      await response.close();
      return;
    }

    // 子清单 / 分片用 `?u=<绝对地址>` 指回来，请求头沿用根条目的。
    final rawTarget = request.uri.queryParameters['u'] ?? '';
    final Uri target;
    try {
      target = rawTarget.isEmpty
          ? Uri.parse(entry.url)
          : Uri.parse(Uri.decodeComponent(rawTarget));
    } catch (_) {
      response.statusCode = HttpStatus.badRequest;
      await response.close();
      return;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..autoUncompress = false;
    try {
      final upstream = await client.getUrl(target);
      upstream.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      entry.headers.forEach((key, value) {
        if (value.isNotEmpty) upstream.headers.set(key, value);
      });
      final range = request.headers.value('range');
      if (range != null && range.isNotEmpty) {
        upstream.headers.set(HttpHeaders.rangeHeader, range);
      }
      final reply = await upstream.close().timeout(
        const Duration(seconds: 20),
      );
      if (reply.statusCode < 200 || reply.statusCode >= 300) {
        response.statusCode = reply.statusCode;
        await response.close();
        return;
      }

      final isPlaylist = (reply.headers.contentType?.value ?? '').contains(
            'mpegurl',
          ) ||
          target.path.toLowerCase().endsWith('.m3u8');

      if (!isPlaylist) {
        // 分片 / 单文件：原样透传（含 Range），不解压不改写。
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
        if (request.method == 'GET') await response.addStream(reply);
        await response.close();
        return;
      }

      final bytes = BytesBuilder(copy: false);
      await for (final chunk in reply.timeout(const Duration(seconds: 20))) {
        if (bytes.length + chunk.length > _maxPlaylistBytes) break;
        bytes.add(chunk);
      }
      final text = utf8.decode(bytes.takeBytes(), allowMalformed: true);
      if (!_looksLikePlaylist(text)) {
        // 声明是清单却不是清单：别猜，直接给回原文。
        response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        response.write(text);
        await response.close();
        return;
      }

      final cleaned = _filterAdSegments(text, target);
      final rewritten = _rewritePlaylist(cleaned, target, token);
      response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
        charset: 'utf-8',
      );
      response.write(rewritten);
      await response.close();
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {
        // 播放器已经断开。
      }
    } finally {
      client.close(force: true);
    }
  }

  /// 把清单里的子清单 / 分片地址改写成走本代理的绝对地址。
  ///
  /// 只改写 URI，不动标签语义：`#EXT-X-KEY`、`#EXT-X-MAP` 这类带 `URI="…"`
  /// 的属性也要一起改，否则密钥或初始化分片会绕过代理（虽然多半也能直接取，
  /// 但带鉴权头的源会因此失败）。
  String _rewritePlaylist(String text, Uri base, String token) {
    final buffer = StringBuffer();
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        buffer.writeln(line);
        continue;
      }
      if (trimmed.startsWith('#')) {
        buffer.writeln(_rewriteTagUris(line, base, token));
        continue;
      }
      // 裸 URI 行：子清单或分片。
      buffer.writeln(_proxyUri(trimmed, base, token));
    }
    return buffer.toString();
  }

  static final _tagUri = RegExp(r'URI="([^"]*)"');

  String _rewriteTagUris(String line, Uri base, String token) {
    if (!line.contains('URI="')) return line;
    return line.replaceAllMapped(_tagUri, (match) {
      final value = match.group(1) ?? '';
      if (value.isEmpty || value.startsWith('data:')) return match.group(0)!;
      return 'URI="${_proxyUri(value, base, token)}"';
    });
  }

  String _proxyUri(String reference, Uri base, String token) {
    final resolved = base.resolve(reference.trim());
    final encoded = Uri.encodeComponent(resolved.toString());
    return '/hls/$token?u=$encoded';
  }

  // ── 去广告 ──────────────────────────────────────────────────────────
  //
  // 与 `native/core/app_adfilter.go` 同一套规则：按「host + 目录」给每个分片
  // 算来源指纹，取占比最高的作为正片来源，丢掉指纹不同的分片。占比低于 40%
  // 说明结构不可信（多半只是切片命名差异），放弃清洗。
  // 纯前置贴片（整段同源）无法与正片区分，不猜删。

  static final _masterVariantTag = RegExp(
    r'^#EXT-X-(STREAM-INF|MEDIA:|I-FRAME-STREAM-INF|IMAGE-STREAM-INF)',
    caseSensitive: false,
  );
  static final _segmentTag = RegExp(r'^#EXTINF:', caseSensitive: false);
  static final _adTagLine = RegExp(
    r'^#EXT(INF:|-X-(BYTERANGE|KEY|DISCONTINUITY))',
    caseSensitive: false,
  );

  String _filterAdSegments(String text, Uri base) {
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty || lines.first.trim() != '#EXTM3U') return text;

    final baseFp = _hostDir(base);
    final commentIndexes = <int>[];
    final segments = <_Segment>[];
    var sawExtInf = false;

    for (var index = 0; index < lines.length; index++) {
      final trimmed = lines[index].trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('#')) {
        if (_masterVariantTag.hasMatch(trimmed)) return text; // master 不改写
        if (_segmentTag.hasMatch(trimmed)) sawExtInf = true;
        commentIndexes.add(index);
        continue;
      }
      if (!sawExtInf) return text; // 没有分片级标注：不是媒体清单
      var fp = _lineFingerprint(trimmed, base, baseFp);
      if (fp.isEmpty) fp = baseFp;
      segments.add(
        _Segment(
          comment: List<int>.of(commentIndexes),
          uri: index,
          fingerprint: fp,
        ),
      );
      commentIndexes.clear();
    }
    if (segments.length < 2) return text;

    final counts = <String, int>{};
    for (final segment in segments) {
      counts[segment.fingerprint] = (counts[segment.fingerprint] ?? 0) + 1;
    }
    var dominant = '';
    var dominantCount = 0;
    counts.forEach((fp, count) {
      if (count > dominantCount) {
        dominant = fp;
        dominantCount = count;
      }
    });
    if (dominant.isEmpty || dominantCount / segments.length < 0.4) {
      return text;
    }

    final remove = <int>{};
    var removed = 0;
    for (final segment in segments) {
      if (segment.fingerprint == dominant) continue;
      removed++;
      remove.add(segment.uri);
      // 从最靠近分片的注释行向上回溯：命中分片级标签就删，普通注释保留但
      // 继续，其它 #EXT 头部标签（VERSION / TARGETDURATION / MAP…）停手。
      // 广告若是贴片，头部注释就挂在第一个分片前，误删会让清单整体失效。
      for (var i = segment.comment.length - 1; i >= 0; i--) {
        final line = lines[segment.comment[i]].trim();
        if (_adTagLine.hasMatch(line)) {
          remove.add(segment.comment[i]);
          continue;
        }
        if (line.startsWith('#') && !line.startsWith('#EXT')) continue;
        break;
      }
    }
    if (removed == 0 || removed >= segments.length) return text;

    final output = <String>[];
    for (var index = 0; index < lines.length; index++) {
      if (!remove.contains(index)) output.add(lines[index]);
    }
    final cleaned = output.join('\n');
    // 清洗后若一个分片都不剩，回退原文：宁可有广告也不能黑屏。
    if (!cleaned.contains('#EXTINF')) return text;
    return cleaned;
  }

  static String _lineFingerprint(String reference, Uri base, String baseFp) {
    final value = reference.trim();
    if (value.isEmpty || value.startsWith('data:')) return '';
    final parsed = Uri.tryParse(value);
    if (parsed == null) return '';
    if (parsed.hasScheme && parsed.host.isNotEmpty) return _hostDir(parsed);
    return _hostDir(base.resolve(value));
  }

  /// host + 目录（丢文件名与 query，同目录视为同源）。
  static String _hostDir(Uri uri) {
    if (uri.host.isEmpty) return '';
    var dir = uri.path.toLowerCase();
    final slash = dir.lastIndexOf('/');
    dir = slash >= 0 ? dir.substring(0, slash) : '';
    return '${uri.host.toLowerCase()}|$dir';
  }
}

class _ProxyEntry {
  const _ProxyEntry(this.url, this.headers);
  final String url;
  final Map<String, String> headers;
}

class _Segment {
  const _Segment({
    required this.comment,
    required this.uri,
    required this.fingerprint,
  });

  /// 归属该分片的注释行下标（含 #EXTINF、BYTERANGE、DISCONTINUITY 等）。
  final List<int> comment;
  final int uri;
  final String fingerprint;
}
