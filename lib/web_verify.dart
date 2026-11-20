import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'core_bridge.dart';

/// 有些站源的播放地址藏在广告短链后面（例如 ouo.io），短链带 Cloudflare 托管挑战，
/// 只有浏览器内核能过去。这里用一个验证页把短链走完，把最终地址交回站源模块。
///
/// 站源模块把 `videoUrl` 写成 `browser://<短链地址>`，播放前由 [WebVerify] 换成真实地址。
/// 验证只在取播放地址时发生（点播放之后）；Android 上藏起来的 WebView 会变成白屏遮罩，
/// 所以验证页就是一张看得见的整屏页，自动提交验证表单，落地后自己收起来。
class WebVerify {
  WebVerify._();

  static final WebVerify instance = WebVerify._();

  static const marker = 'browser://';

  static const shortHosts = {'ouo.io', 'ouo.press', 'ouo.pw'};

  static const blockedHosts = {
    'pubadx.one',
    'adsco.re',
    'weedsyearday.com',
    'cdn4ads.com',
    'magsrv.com',
    'googletagmanager.com',
    'google-analytics.com',
    'doubleclick.net',
    'googlesyndication.com',
    'cloudflareinsights.com',
  };

  final ValueNotifier<String> progress = ValueNotifier<String>('');

  WebVerifyHostState? _host;

  void _attach(WebVerifyHostState host) => _host = host;

  void _detach(WebVerifyHostState host) {
    if (identical(_host, host)) _host = null;
  }

  bool get ready => _host != null;

  static bool get supported {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return true;
      default:
        return false;
    }
  }

  Future<String> resolve(String url) async {
    final address = url.trim();
    if (address.isEmpty) {
      throw AppFailure('验证地址为空，请重新播放');
    }
    if (!supported) {
      throw AppFailure('当前平台没有浏览器内核，无法完成验证');
    }
    final host = _host;
    if (host == null) {
      throw AppFailure('浏览器内核没有就绪，请回到首页后重试');
    }
    return host.resolve(address);
  }

  void cancel() => _host?.cancel();

  static const playerHosts = {
    'mxdrop.to',
    'mxdrop.click',
    'mixdrop.co',
    'mixdrop.top',
    'mixdrop.ag',
    'advtpe.com',
    'playmogo.com',
    'dood.to',
    'dood.watch',
    'doodstream.com',
    'ds2play.com',
    '1069jp.com',
    'hgcloud.to',
    'luluvdo.com',
    'hypeboy.link',
    'voe.sx',
    'streamtape.com',
    'streamtape.to',
  };

  static bool isShortHost(String host) => shortHosts.contains(host.toLowerCase());

  /// 落地页是不是真正的播放器站点（中间广告页不算）。
  static bool isPlayerHost(String host) {
    final name = host.toLowerCase();
    if (name.isEmpty) return false;
    if (playerHosts.contains(name)) return true;
    for (final player in playerHosts) {
      if (name.endsWith('.$player')) return true;
    }
    return name.contains('mxcontent') ||
        name.contains('cloudatacdn') ||
        name.contains('doodcdn');
  }

  static bool isBlockedHost(String host) {
    final name = host.toLowerCase();
    if (name.isEmpty) return false;
    for (final blocked in blockedHosts) {
      if (name == blocked || name.endsWith('.$blocked')) return true;
    }
    return false;
  }
}

/// 挂在应用根部：验证时才盖一张整屏验证页，其余时间只有界面本身。
class WebVerifyHost extends StatefulWidget {
  const WebVerifyHost({super.key, required this.child});

  final Widget child;

  @override
  State<WebVerifyHost> createState() => WebVerifyHostState();
}

class WebVerifyHostState extends State<WebVerifyHost> {
  Completer<String>? _job;
  Timer? _timeout;
  Timer? _retry;
  String _lastShort = '';
  String _address = '';
  int _attempts = 0;
  int _advanceAttempts = 0;
  String _advancedFrom = '';
  String _status = '';

  @override
  void initState() {
    super.initState();
    WebVerify.instance._attach(this);
  }

  @override
  void dispose() {
    WebVerify.instance._detach(this);
    _timeout?.cancel();
    _retry?.cancel();
    final job = _job;
    _job = null;
    if (job != null && !job.isCompleted) {
      job.completeError(AppFailure('验证已取消'));
    }
    super.dispose();
  }

  Future<String> resolve(String url) async {
    if (_job != null) {
      throw AppFailure('上一次验证还没结束，请稍后重试');
    }
    final completer = Completer<String>();
    _job = completer;
    _attempts = 0;
    _advanceAttempts = 0;
    _advancedFrom = '';
    _lastShort = '';
    _address = url;
    _setStatus('正在打开短链验证页…');
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 90), () {
      _complete('', '验证超时，请检查网络后重试');
    });
    if (mounted) setState(() {});
    return completer.future;
  }

  void cancel() {
    if (_job == null) return;
    _complete('', '已取消验证');
  }

  void _setStatus(String text) {
    WebVerify.instance.progress.value = text;
    if (mounted) setState(() => _status = text);
  }

  void _complete(String value, [String? message]) {
    final job = _job;
    _job = null;
    _timeout?.cancel();
    _timeout = null;
    _retry?.cancel();
    _retry = null;
    WebVerify.instance.progress.value = '';
    if (mounted) {
      setState(() {
        _status = '';
        _address = '';
      });
    }
    if (job == null || job.isCompleted) return;
    if (value.isEmpty) {
      job.completeError(AppFailure(message ?? '验证失败，请重试'));
    } else {
      job.complete(value);
    }
  }

  /// ouo 这类短链是两步表单：第一步 #form-captcha（我是人类），
  /// 第二步 #form-go（GET LINK），两步都是点 #btn-main 触发提交。
  Future<void> _submit(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(
        source: '''
(function () {
  var button = document.getElementById('btn-main')
    || document.querySelector('#form-captcha button')
    || document.querySelector('#form-go button')
    || document.querySelector('form[action*="/xreallcygo/"] button')
    || document.querySelector('form[action*="/go/"] button');
  if (button) {
    button.click();
    return 'clicked';
  }
  var form = document.querySelector('#form-captcha')
    || document.querySelector('#form-go')
    || document.querySelector('form[action*="/xreallcygo/"]')
    || document.querySelector('form[action*="/go/"]');
  if (form) {
    form.submit();
    return 'submitted';
  }
  return 'none';
})();
''',
      );
    } catch (_) {}
  }

  Future<bool> _challenging(InAppWebViewController controller) async {
    try {
      final result = await controller.evaluateJavascript(
        source: '''
(function () {
  if (document.querySelector('#form-captcha')
    || document.querySelector('#form-go')
    || document.querySelector('form[action*="/xreallcygo/"]')
    || document.querySelector('form[action*="/go/"]')) return true;
  var labels = /(i.?m a human|click the captcha|verify you are a human)/i;
  return labels.test(document.body ? document.body.innerText : '');
})();
''',
      );
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// 验证完落在广告中间页时，点页面上的“继续/前往”把浏览器带到真正的播放器站点；
  /// 几次都带不过去就把当前地址交回站源，由模块自己找。
  void _advance(InAppWebViewController controller, String current, String host) {
    _advanceAttempts++;
    if (_advanceAttempts > 4 || current == _advancedFrom) {
      _setStatus('已跳到 $host，正在返回播放…');
      _complete(current);
      return;
    }
    _advancedFrom = current;
    _setStatus('正在跳过广告页（第 $_advanceAttempts 次）：$host');
    unawaited(_clickForward(controller));
    _retry?.cancel();
    _retry = Timer(const Duration(milliseconds: 2600), () {
      if (_job == null) return;
      unawaited(_checkAdvanced(controller, current));
    });
  }

  Future<void> _clickForward(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(
        source: '''
(function () {
  var labels = /(continue|go ?to|proceed|click here|skip|next|get ?link|i.?m a human|here)/i;
  var nodes = [].slice.call(document.querySelectorAll('a, button, div, span, input[type=button], input[type=submit]'));
  var pick = null;
  for (var index = 0; index < nodes.length; index++) {
    var node = nodes[index];
    if (!node.offsetParent) continue;
    var text = ((node.innerText || node.value || '') + ' ' + (node.id || '') + ' ' + (node.className || '')).trim();
    if (text.length > 90 || !labels.test(text)) continue;
    if (node.tagName === 'A' && node.href && /^https?:/.test(node.href)) return 'link:' + node.href.slice(0, 80), node.click();
    if (!pick) pick = node;
  }
  if (pick) { pick.click(); return 'clicked'; }
  var frame = document.querySelector('iframe');
  if (frame) return 'frame-only';
  return 'none';
})();
''',
      );
    } catch (_) {}
  }

  Future<void> _checkAdvanced(
    InAppWebViewController controller,
    String previous,
  ) async {
    if (_job == null) return;
    String current = previous;
    try {
      final value = await controller.evaluateJavascript(source: 'location.href');
      if (value is String && value.isNotEmpty) current = value;
    } catch (_) {}
    if (current != previous) {
      return;
    }
    final uri = Uri.tryParse(current);
    if (uri != null && WebVerify.isPlayerHost(uri.host)) {
      _complete(current);
      return;
    }
    if (_advanceAttempts > 4) {
      _setStatus('已跳到 ${uri?.host ?? ""}，正在返回播放…');
      _complete(current);
      return;
    }
    _advanceAttempts++;
    _setStatus('正在跳过广告页（第 $_advanceAttempts 次）：${uri?.host ?? ""}');
    unawaited(_clickForward(controller));
    _retry?.cancel();
    _retry = Timer(const Duration(milliseconds: 2600), () {
      if (_job == null) return;
      unawaited(_checkAdvanced(controller, current));
    });
  }

  Future<bool> _waitingForHuman(InAppWebViewController controller) async {
    try {
      final result = await controller.evaluateJavascript(
        source: '''
(function () {
  var frame = document.querySelector('iframe[src*="challenges.cloudflare.com"], iframe[src*="hcaptcha"], iframe[src*="recaptcha"], iframe[src*="turnstile"]');
  if (frame) return true;
  var text = document.body ? document.body.innerText : '';
  return /click the captcha|verify you are a human/i.test(text);
})();
''',
      );
      return result == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleStop(InAppWebViewController controller, WebUri? url) async {
    if (_job == null) return;
    final current = url?.toString() ?? '';
    if (current.isEmpty) return;
    final uri = Uri.tryParse(current);
    if (uri == null || uri.host.isEmpty) return;
    if (WebVerify.isBlockedHost(uri.host)) return;
    if (WebVerify.isPlayerHost(uri.host)) {
      _setStatus('已跳到 ${uri.host}，正在返回播放…');
      _complete(current);
      return;
    }
    final challenge = WebVerify.isShortHost(uri.host) || await _challenging(controller);
    if (!challenge) {
      _advance(controller, current, uri.host);
      return;
    }
    _attempts++;
    if (_attempts > 30) {
      _complete('', '短链验证没有通过，请稍后重试');
      return;
    }
    final waiting = await _waitingForHuman(controller);
    _setStatus(
      waiting
          ? '需要点一下页面里的验证框（点完会自动继续）'
          : '正在自动验证（第 $_attempts 步）：${uri.host}',
    );
    _lastShort = current;
    await _submit(controller);
    _retry?.cancel();
    _retry = Timer(const Duration(milliseconds: 2200), () {
      if (_job == null || _lastShort != current) return;
      unawaited(_submit(controller));
    });
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;
    return Stack(
      alignment: Alignment.topLeft,
      children: [
        widget.child,
        if (job != null && _address.isNotEmpty)
          Positioned.fill(
            child: _VerifyPage(
              url: _address,
              status: _status,
              onLoadStop: _handleStop,
              onError: (description) => _complete('', '验证页面加载失败：$description'),
              onCancel: _complete,
            ),
          ),
      ],
    );
  }
}

/// 整屏验证页：不依赖应用内的 MaterialApp（它在根部件下面），所以自带方向与样式。
class _VerifyPage extends StatelessWidget {
  const _VerifyPage({
    required this.url,
    required this.status,
    required this.onLoadStop,
    required this.onError,
    required this.onCancel,
  });

  final String url;
  final String status;
  final void Function(InAppWebViewController controller, WebUri? url) onLoadStop;
  final void Function(String description) onError;
  final void Function(String value, [String? message]) onCancel;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Material(
      color: const Color(0xFF121212),
      child: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
              color: const Color(0xFF1E1E1E),
              child: Row(
                children: [
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF8BD4A0),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      status.isEmpty ? '正在验证播放地址…' : status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => onCancel('', '已取消验证'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2E2E2E),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        '取消',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(url)),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  thirdPartyCookiesEnabled: true,
                  mediaPlaybackRequiresUserGesture: false,
                  supportMultipleWindows: false,
                  useShouldOverrideUrlLoading: true,
                  userAgent:
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36',
                ),
                shouldOverrideUrlLoading: (controller, action) async =>
                    WebVerify.isBlockedHost(action.request.url?.host ?? '')
                    ? NavigationActionPolicy.CANCEL
                    : NavigationActionPolicy.ALLOW,
                onCreateWindow: (controller, action) async => false,
                onLoadStop: (controller, address) =>
                    onLoadStop(controller, address),
                onReceivedError: (controller, request, error) {
                  if (request.isForMainFrame != true) return;
                  final host = request.url.host;
                  if (host.isEmpty || WebVerify.isBlockedHost(host)) return;
                  onError(error.description);
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
