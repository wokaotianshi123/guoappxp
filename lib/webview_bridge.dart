import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'core_bridge.dart';

/// 应用内 WebView 验证桥接。
///
/// Cloudflare 这类人机验证只有真实浏览器内核能通过，普通 HTTP 请求永远拿回
/// 「Just a moment」。这里的做法是：
///   1. 起一个只监听 127.0.0.1 的 HTTP 服务，暴露 `/fetch` 与 `/spider`；
///   2. 把端口登记给 Go 核心，核心遇到需要验证的域名时改走这个回环地址；
///   3. 用户在应用内浏览器完成验证后，把 Cookie / UA 一并交给核心，后续请求
///      带着同一套指纹直连，不再被拦。
///
/// 端口只绑回环地址，且只在应用进程内有效。
abstract final class WebViewBridge {
  static const MethodChannel _channel = MethodChannel('guoapp/webview');
  static const MethodChannel _spiderChannel = MethodChannel('guoapp/spider');
  static HttpServer? _server;

  /// 应用内浏览器验证支持的平台（Android / iOS / macOS）。
  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  /// TVBox .jar Spider 插件只在 Android 上能加载（需要 DexClassLoader）。
  static bool get spiderSupported => !kIsWeb && Platform.isAndroid;

  /// 判断一条报错是不是「被 Cloudflare 拦了」。
  ///
  /// CF_CHALLENGE 是 ASCII 标记：报错经过 URL 编码后中文会变成 %E8..，
  /// 只有纯 ASCII 能稳定穿过那一层。
  static bool isChallengeError(String message) =>
      message.contains('CF_CHALLENGE') ||
      message.contains('Cloudflare 人机验证') ||
      message.contains('完成人机验证') ||
      message.contains('手动完成验证') ||
      message.toLowerCase().contains('just a moment');

  static Future<int> _ensureServer() async {
    final existing = _server;
    if (existing != null) return existing.port;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      try {
        if (request.uri.path == '/spider' && request.method == 'POST') {
          final bodyText = await utf8.decoder.bind(request).join();
          final payload = Map<String, dynamic>.from(
            jsonDecode(bodyText) as Map,
          );
          final res = await _spiderChannel.invokeMapMethod<String, dynamic>(
            'callSpider',
            payload,
          );
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'ok': res?['ok'] == true,
              'json': res?['json'] as String? ?? '',
              'error': res?['error'] as String? ?? '',
            }),
          );
          return;
        }
        if (request.uri.path != '/fetch') {
          request.response.statusCode = HttpStatus.notFound;
          return;
        }
        final target = request.uri.queryParameters['url'] ?? '';
        if (target.isEmpty) {
          request.response.statusCode = HttpStatus.badRequest;
          return;
        }
        final res = await _channel.invokeMapMethod<String, dynamic>(
          'fetchHtml',
          {'url': target},
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'ok': res?['ok'] == true,
            'html': res?['html'] as String? ?? '',
            'url': res?['url'] as String? ?? target,
          }),
        );
      } catch (error) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ok': false, 'error': '$error'}));
      } finally {
        await request.response.close();
      }
    });
    return server.port;
  }

  /// 登记 Spider 插件桥接端口（仅 Android）。
  static Future<void> ensureSpiderBridge(AppRepository repo) async {
    if (!spiderSupported) return;
    final port = await _ensureServer();
    await repo.registerSpiderBridge(port);
  }

  /// 打开应用内验证页，通过后把 Cookie / UA 与回环端口交给核心。
  ///
  /// 返回 false 表示当前平台不支持、没有可用验证地址，或用户取消了验证。
  static Future<bool> verifySource(AppRepository repo, String source) async {
    if (!supported) return false;
    final url = await repo.sourceChallengeUrl(source);
    if (url.isEmpty) return false;
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'openChallenge',
      {'url': url},
    );
    if (res?['ok'] != true) return false;
    final cookies = res?['cookies'] as String? ?? '';
    final userAgent = res?['userAgent'] as String? ?? '';
    final port = await _ensureServer();
    await repo.registerWebViewBridge(
      port: port,
      url: url,
      source: source,
      cookies: cookies,
      userAgent: userAgent,
    );
    return true;
  }
}
