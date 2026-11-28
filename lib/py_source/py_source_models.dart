/// Python 数据源（TVBox 方言的 `class Spider`）的元信息与导入结果。
///
/// 与 JS 沙箱的 `meta` 字面量不同，py 脚本的显示名在代码里：通行做法是
/// `def getName(self)` 里 `return "红果短剧"`，也有老脚本写 `self.name = "…"`。
/// 显示名优先从脚本正文读，读不到才退回文件名；标识仍由文件名推导。
class PySourceMeta {
  const PySourceMeta({
    required this.id,
    required this.name,
    this.description = '',
    this.fileName = '',
  });

  final String id;
  final String name;
  final String description;

  /// 脚本在本地目录里的文件名（`demo.py`）。
  final String fileName;

  String get sourceId => pySourceIdOf(id);
}

/// py 源前缀。用户在源菜单里看到的是一类独立站源，
/// 播放 / 详情 / 搜索都按这个前缀路由到 py 宿主。
const pySourcePrefix = 'py:';

String pySourceIdOf(String id) => '$pySourcePrefix$id';
bool isPySourceId(String id) => id.startsWith(pySourcePrefix);
String pySourceScriptId(String sourceId) =>
    sourceId.startsWith(pySourcePrefix)
    ? sourceId.substring(pySourcePrefix.length)
    : sourceId;

/// 文件名 → 站源标识。只保留小写字母、数字、下划线与连字符；
/// 全被过滤掉时用内容哈希兜底，保证不会得到空标识。
String pyIdFromFileName(String fileName) {
  final stem = fileName.replaceAll(RegExp(r'\.py$', caseSensitive: false), '');
  var id = stem
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (id.isEmpty) {
    var hash = 0x811c9dc5;
    for (final unit in stem.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    id = 'py${hash.toRadixString(16)}';
  }
  if (id.length > 64) id = id.substring(0, 64);
  return id;
}

/// 显示名：文件主名原样保留（允许中文），去掉尾部 `.py`。
String pyNameFromFileName(String fileName) {
  final stem = fileName.replaceAll(RegExp(r'\.py$', caseSensitive: false), '');
  final trimmed = stem.trim();
  return trimmed.isEmpty ? fileName : trimmed;
}

/// 从脚本正文里读显示名。
///
/// 认三种写法（按优先级）：
///   1. `def getName(self): return "红果短剧"` —— TVBox 方言的标准做法；
///   2. `self.name = "红果短剧"` / `name = "红果短剧"` —— 老脚本的类属性；
///   3. `meta = {"name": "红果短剧"}` —— 少数从 JS 方言移植过来的脚本。
///
/// 读不到返回空串，由调用方退回文件名。这里不做完整 Python 解析：目标只是
/// 拿一个显示名，正则够用，也不该因为语法怪异就拒绝导入。
String pyNameFromScript(String script) {
  if (script.isEmpty) return '';

  // 1) def getName(self) 的返回值。先截出这个方法体，再找第一个 return，
  //    避免把文件里后面别的 return 误当成名字。
  //    返回类型注解（`-> str`）要一并吃掉，否则匹配不到冒号。
  final method = RegExp(
    r'def\s+getName\s*\(\s*self[^)]*\)\s*(?:->\s*[^:\n]+)?\s*:',
  ).firstMatch(script);
  if (method != null) {
    final body = _methodBody(script, method.end);
    // Python 的字符串前缀有 f / r / b / u 及两两组合（fr、rf…），一并吃掉。
    final returned = RegExp(
      r'''\breturn\s+[fFrRbBuU]{0,2}(['"])(.*?)\1''',
      dotAll: true,
    ).firstMatch(body);
    final value = returned?.group(2)?.trim() ?? '';
    if (value.isNotEmpty && !value.contains('{')) return value;
  }

  // 2) self.name / name 赋值。必须卡单词边界，否则 `file_name = "x.py"`
  //    这类普通变量会被误当成显示名。
  final assigned = RegExp(
    r'''(?:^|\W)(?:self\.)?name\s*=\s*(['"])(.*?)\1''',
    multiLine: true,
  ).firstMatch(script);
  final assignedValue = assigned?.group(2)?.trim() ?? '';
  if (assignedValue.isNotEmpty && !assignedValue.contains('{')) {
    return assignedValue;
  }

  // 3) meta 字典里的 "name"。
  final metaName = RegExp(
    r'''["']name["']\s*:\s*(['"])(.*?)\1''',
  ).firstMatch(script);
  final metaValue = metaName?.group(2)?.trim() ?? '';
  if (metaValue.isNotEmpty && !metaValue.contains('{')) return metaValue;

  return '';
}

/// 截出 `def` 后面的方法体：从 `start` 到下一个同级 `def` / `class` 之前。
String _methodBody(String script, int start) {
  final rest = script.substring(start);
  // 把首字符换成换行，避免当前行自己被 `^` 匹配到。长度不变，索引仍然有效。
  final probe = rest.isEmpty ? '\n' : '\n${rest.substring(1)}';
  // 只用行内空白，不用 `\s*`：后者会吞掉换行，让 `^` 提前匹配到空行。
  final next = RegExp(r'^[ \t]*(?:def|class)\s+', multiLine: true).firstMatch(
    probe,
  );
  if (next == null) return rest;
  return rest.substring(0, next.start);
}

/// 导入时的文件名校验：只认单层、以 .py 结尾、不含路径分隔符与保留字符。
bool validPySourceFileName(String name) {
  if (name.isEmpty || name.length > 180) return false;
  if (name.contains('/') || name.contains(r'\') || name.contains('..')) {
    return false;
  }
  if (RegExp(r'[<>:"|?*\x00-\x1F]').hasMatch(name)) return false;
  return name.toLowerCase().endsWith('.py');
}

/// 把脚本正文转成可直接写盘的 UTF-8 文本：去 BOM、统一换行。
String normalizePyScript(String raw) {
  var script = raw;
  if (script.startsWith('\uFEFF')) script = script.substring(1);
  return script.replaceAll('\r\n', '\n');
}

class PySourceMetaResult {
  const PySourceMetaResult(this.meta) : error = '';
  const PySourceMetaResult.failed(this.error) : meta = null;
  final PySourceMeta? meta;
  final String error;
  bool get success => meta != null;
}

/// 从文件名生成元信息；文件名不合法时返回失败。
///
/// 给了 [script] 时优先用脚本里的显示名（`getName()` 的返回值），读不到才
/// 退回文件名。标识始终由文件名推导——它要稳定，不能随脚本改名而变。
PySourceMetaResult pyMetaFromFileName(String fileName, {String script = ''}) {
  final name = fileName.trim();
  if (!validPySourceFileName(name)) {
    return const PySourceMetaResult.failed('文件名无效，需以 .py 结尾且不能包含路径');
  }
  final fromScript = pyNameFromScript(script);
  return PySourceMetaResult(
    PySourceMeta(
      id: pyIdFromFileName(name),
      name: fromScript.isNotEmpty ? fromScript : pyNameFromFileName(name),
      fileName: name,
    ),
  );
}

class PyImportResult {
  const PyImportResult.ok(this.meta) : error = '';
  const PyImportResult.failed(this.error) : meta = null;
  final PySourceMeta? meta;
  final String error;
  bool get success => meta != null;
}

class PyZipImportResult {
  const PyZipImportResult({
    this.imported = const [],
    this.failed = const [],
    this.error = '',
  });
  final List<PySourceMeta> imported;
  final List<String> failed;
  final String error;
  bool get success => imported.isNotEmpty;
}

/// 从订阅导入的结果。
class PySubscriptionResult {
  const PySubscriptionResult({
    this.imported = const [],
    this.failed = const [],
    this.error = '',
  });
  const PySubscriptionResult.failed(this.error)
    : imported = const [],
      failed = const [];

  final List<PySourceMeta> imported;
  final List<String> failed;
  final String error;

  bool get success => imported.isNotEmpty;
}
