/// 订阅导入的共享模型：JS 沙箱与 PY 沙箱共用。
///
/// 导入订阅时先解析出「可勾选条目」，用户在列表里挑完再逐个导入，
/// 导入过程中回调进度（已导入 / 剩余 / 共）。
library;

/// 一条可导入的候选。
class SubscriptionCandidate {
  const SubscriptionCandidate({
    required this.name,
    required this.url,
    this.localPath = '',
    this.detail = '',
  });

  /// 清单里写的显示名，可能为空（裸地址写法）。
  final String name;

  /// 原始地址：远程是 http(s) 直链，本机订阅里是相对路径（`.\xx.js`）。
  final String url;

  /// 本机订阅 JSON 里的相对地址解析出的绝对路径；远程订阅为空。
  final String localPath;

  /// 列表里显示的第二行，通常是地址或文件名。
  final String detail;

  /// 列表标题：没有名字时退回地址末段。
  String get label {
    if (name.trim().isNotEmpty) return name.trim();
    final segment = url.replaceAll(r'\', '/').split('/').last;
    return segment.isEmpty ? url : segment;
  }

  /// 列表副标题。
  String get subtitle {
    if (detail.trim().isNotEmpty) return detail.trim();
    return localPath.isNotEmpty ? localPath : url;
  }
}

/// 一次导入进度。
class SubscriptionProgress {
  const SubscriptionProgress({
    required this.done,
    required this.total,
    required this.name,
  });

  /// 已处理条数（含失败）。
  final int done;
  final int total;

  /// 当前正在处理的条目名。
  final String name;

  int get remaining => (total - done) < 0 ? 0 : total - done;
}

/// 导入结果：成功与失败分别列出，界面上给一句汇总。
class SubscriptionImportReport {
  const SubscriptionImportReport({
    this.imported = const [],
    this.failed = const [],
  });

  final List<String> imported;
  final List<String> failed;

  int get total => imported.length + failed.length;
  bool get success => imported.isNotEmpty;
}

/// 订阅解析结果。
///
/// [fromSubscription] 为 false 表示地址本身就是一个脚本直链（不是订阅），
/// 调用方可以跳过选择列表直接导入。
class SubscriptionFetch {
  const SubscriptionFetch({
    this.candidates = const [],
    this.fromSubscription = false,
    this.error = '',
  });

  const SubscriptionFetch.failed(this.error)
    : candidates = const [],
      fromSubscription = false;

  final List<SubscriptionCandidate> candidates;
  final bool fromSubscription;
  final String error;

  bool get success => candidates.isNotEmpty && error.isEmpty;
}
