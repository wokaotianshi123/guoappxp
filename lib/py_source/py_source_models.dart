/// Python 数据源（TVBox 方言的 `class Spider`）的元信息与导入结果。
///
/// 与 JS 沙箱不同，py 文件里没有可静态读取的 `meta` 字面量：标识与显示名
/// 都由文件名推导。落盘一个 `.py` 文件就是安装一个源，站源 id 为 `py:<标识>`。
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
PySourceMetaResult pyMetaFromFileName(String fileName) {
  final name = fileName.trim();
  if (!validPySourceFileName(name)) {
    return const PySourceMetaResult.failed('文件名无效，需以 .py 结尾且不能包含路径');
  }
  return PySourceMetaResult(
    PySourceMeta(
      id: pyIdFromFileName(name),
      name: pyNameFromFileName(name),
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
