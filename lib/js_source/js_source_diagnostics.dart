import 'dart:async';
import 'dart:convert';

/// JS 沙箱的诊断记录。
///
/// 移植自 thlredguo 的 `SourceDiagnostics`，只保留沙箱自己会用到的部分：
/// 请求分级、错误归类、凭据脱敏和一环形缓冲的最近记录。原实现还带着诊断
/// 报告导出与界面，本项目的沙箱页只需要「最近发生了什么」，因此收成一屏。
class JsDiagnosticEntry {
  const JsDiagnosticEntry({
    required this.at,
    required this.stage,
    this.context = '',
    this.host = '',
    this.url = '',
    this.method = 'GET',
    this.status = 0,
    this.logId = '',
    this.businessCode = '',
    this.errorCode = '',
    this.elapsedMs = 0,
    this.errorCategory = '',
    this.errorTitle = '',
    this.errorMessage = '',
    this.advice = '',
    this.searchTabsSummary = '',
    this.sessionStatus = '',
  });

  final DateTime at;
  final String stage;
  final String context;
  final String host;
  final String url;
  final String method;
  final int status;
  final String logId;
  final String businessCode;
  final String errorCode;
  final int elapsedMs;
  final String errorCategory;
  final String errorTitle;
  final String errorMessage;
  final String advice;
  final String searchTabsSummary;
  final String sessionStatus;

  bool get failed => errorCode.isNotEmpty || (status > 0 && status >= 400);

  String get text => [
    '${at.toLocal().toIso8601String().substring(11, 19)} $stage',
    if (host.isNotEmpty) host,
    if (status > 0) 'HTTP $status',
    if (errorCode.isNotEmpty) errorCode,
    if (elapsedMs > 0) '${elapsedMs}ms',
  ].join(' · ');
}

class JsDiagnosticFailure {
  const JsDiagnosticFailure(
    this.code,
    this.message, {
    this.category = '',
    this.title = '',
    this.advice = '',
  });
  final String code;
  final String message;
  final String category;
  final String title;
  final String advice;

  JsDiagnosticFailure withTarget(String host) => JsDiagnosticFailure(
    code,
    message.contains(host) || host.isEmpty ? message : '$message（$host）',
    category: category,
    title: title,
    advice: advice,
  );
}

class JsSourceDiagnostics {
  static final shared = JsSourceDiagnostics();

  static const _limit = 120;
  final List<JsDiagnosticEntry> _entries = [];

  List<JsDiagnosticEntry> get entries => List.unmodifiable(_entries.reversed);

  void add(JsDiagnosticEntry entry) {
    _entries.add(entry);
    if (_entries.length > _limit) _entries.removeAt(0);
  }

  void clear() => _entries.clear();

  /// 只保留能安全落进日志的短标识：太长的、含长数字串的一律丢弃。
  static String safeCode(Object? value) {
    final code = value?.toString() ?? '';
    return RegExp(r'^-?[A-Za-z0-9_.:-]{1,64}$').hasMatch(code) &&
            !RegExp(r'\d{10,}').hasMatch(code)
        ? code
        : '';
  }

  /// 请求落到哪一类环节，用于把错误按阶段归堆。
  static String? stageFor(Uri uri) {
    if (uri.host == 'log.snssdk.com' &&
        uri.path == '/service/2/device_register/') {
      return '游客注册';
    }
    if (uri.host == 'reading.snssdk.com') {
      final stage = switch (uri.path) {
        '/reading/bookapi/search/tab/v' => '搜索',
        '/reading/bookapi/search/cue/v' => '猜你想搜',
        '/reading/bookapi/search/suggest/v' => '搜索联想',
        '/reading/bookapi/plan/v' => '榜单',
        '/reading/bookapi/bookmall/tab/v' => '找剧与推荐',
        '/reading/bookapi/bookmall/cell/change/v' => '列表分页',
        _ => null,
      };
      if (stage != null) return stage;
    }
    if (uri.host.endsWith('.fqnovel.com') ||
        uri.host == 'reading.snssdk.com') {
      if (uri.path.contains('/video_detail/')) return '详情';
      if (uri.path.contains('/video_model/') ||
          uri.path.contains('/multi_video_model/')) {
        return '播放解析';
      }
      if (uri.path.startsWith('/novel/commentapi/comment/list/')) {
        return '弹幕';
      }
    }
    if (uri.host == 'hongguoduanju.com' ||
        uri.host.endsWith('.hongguoduanju.com')) {
      if (uri.path == '/detail' || uri.path.startsWith('/detail/')) {
        return '详情';
      }
      if (uri.path.startsWith('/player/')) return '播放解析';
      return '网页路由';
    }
    return null;
  }

  /// 把异常归类成沙箱内部的错误码，界面与播放失败提示都按它说话。
  static JsDiagnosticFailure analyzeError(
    Object error, {
    String url = '',
    bool timedOut = false,
  }) {
    final target = Uri.tryParse(url)?.host ?? '目标服务器';
    if (timedOut || error is TimeoutException) {
      return const JsDiagnosticFailure(
        'TIMEOUT',
        '网络连接超时，未在时限内收到响应',
        category: 'network_timeout',
        title: '网络超时',
        advice: '检查网络、DNS 或分流代理是否拦截了请求。',
      ).withTarget(target);
    }
    final text = error.toString();
    if (error is FormatException) {
      return const JsDiagnosticFailure(
        'INVALID_RESPONSE',
        '返回的数据不是有效的响应格式',
        category: 'invalid_response',
        title: '响应无效',
      ).withTarget(target);
    }
    if (text.contains('SocketException') ||
        text.contains('Connection refused') ||
        text.contains('Connection reset')) {
      return const JsDiagnosticFailure(
        'CONNECTION',
        '无法建立连接，连接被拒绝或中断',
        category: 'conn_refused',
        title: '连接失败',
      ).withTarget(target);
    }
    if (text.contains('HandshakeException') ||
        text.contains('CertificateException')) {
      return const JsDiagnosticFailure(
        'TLS',
        '建立加密连接失败',
        category: 'tls_error',
        title: '加密连接失败',
      ).withTarget(target);
    }
    if (text.contains('Failed host lookup') ||
        text.contains('nodename nor servname')) {
      return const JsDiagnosticFailure(
        'DNS',
        '域名解析失败，请检查网络或分流规则',
        category: 'dns_error',
        title: '域名解析失败',
      ).withTarget(target);
    }
    if (text.contains('CANCELLED')) {
      return const JsDiagnosticFailure(
        'CANCELLED',
        '请求已取消',
        category: 'cancelled',
        title: '已取消',
      );
    }
    return const JsDiagnosticFailure(
      'REQUEST',
      '网络请求失败',
      category: 'unknown',
      title: '请求失败',
    ).withTarget(target);
  }

  static String networkCode(Object error, {bool timedOut = false}) =>
      analyzeError(error, timedOut: timedOut).code;

  /// 地址里的查询参数可能带签名与票据，落日志前把值抹掉。
  static String desensitizeUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return raw;
    if (uri.query.isEmpty) return uri.replace(fragment: '').toString();
    final kept = [
      for (final entry in uri.queryParametersAll.entries)
        if (['aid', 'page', 'count', 'tab_type', 'app_name'].contains(entry.key))
          '${entry.key}=${entry.value.join(",")}',
    ];
    return uri
        .replace(query: kept.isEmpty ? '' : kept.join('&'), fragment: '')
        .toString();
  }

  static String redact(String raw) => raw
      .replaceAllMapped(
        RegExp(
          r'\b(?:Cookie|Set-Cookie|Authorization|Proxy-Authorization)\s*[:=]\s*[^\r\n]+',
          caseSensitive: false,
        ),
        (_) => '[请求凭据已隐藏]',
      )
      .replaceAllMapped(
        RegExp(r'''https?://[^\s<>"']+'''),
        (match) => desensitizeUrl(match[0]!),
      );

  /// 记录一次网络往返。返回的条目在「播放解析」阶段会被运行时拿去判断
  /// 「四路模型都回空」这种特定失败，因此必须把 stage 一起带回去。
  JsDiagnosticEntry? record({
    required String url,
    required int elapsedMs,
    String context = '',
    int status = 0,
    String body = '',
    String errorCode = '',
    Object? error,
    Map<String, String> headers = const {},
    String method = 'GET',
    String sessionStatus = '',
    bool timedOut = false,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final stage = stageFor(uri);
    if (stage == null) return null;

    var failure = safeCode(errorCode);
    if (error != null) {
      failure = analyzeError(error, url: url, timedOut: timedOut).code;
    } else if (failure.isEmpty) {
      try {
        final value = body.length <= 4 * 1024 * 1024 ? jsonDecode(body) : null;
        if (value is Map && value['error'] is String) {
          failure = safeCode(value['error']);
        }
      } catch (_) {}
      if (failure.isEmpty && status >= 400) failure = 'HTTP_$status';
    }

    final entry = JsDiagnosticEntry(
      at: DateTime.now(),
      stage: stage,
      context: context,
      host: uri.host,
      url: desensitizeUrl(url),
      method: method,
      status: status,
      errorCode: failure,
      elapsedMs: elapsedMs,
      sessionStatus: sessionStatus,
    );
    add(entry);
    return entry;
  }
}
