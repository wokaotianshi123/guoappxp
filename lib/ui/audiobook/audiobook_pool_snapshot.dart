import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'audiobook_fanqie.dart';

/// 红果听书首屏书池的本地快照。
///
/// 首屏取自红果书城的 tab 接口：单次响应约 500KB，实测 4~5 秒，站点抖动或
/// 触发重试时更久。而「听书 / 小说」两个频道的首屏在一段时间内基本不变，
/// 于是每次进听书页都要对着加载圈等十几秒。这里把上一次成功取回的首屏按频道
/// 落盘：进页面先把快照渲染出来，再在后台请求刷新——用户直接看到内容，
/// 刷新完成后再原地替换。
///
/// 只缓存书籍列表与 hasMore，不含任何用户数据；快照超龄、解析失败或写盘失败
/// 都只当作「没有快照」处理，退回到原来的加载态，不影响功能。
class AudiobookPoolSnapshot {
  const AudiobookPoolSnapshot({required this.books, required this.hasMore});

  final List<FanqieBook> books;
  final bool hasMore;

  /// 快照的可用时长。封面地址带签名与过期时间，放太久会全部失效；
  /// 书城榜单本身也早变了，超过这个时长就当没有快照。
  static const maxAge = Duration(hours: 24);

  static const _version = 1;

  /// 快照目录在应用数据目录下，与书架 / 历史同级但在独立的 pool 子目录里，
  /// 「删除全部数据」按目录清理时不会漏掉。
  static Future<File> _file(String channel) async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(path.join(support.path, 'audiobooks', 'pool'));
    await directory.create(recursive: true);
    return File(path.join(directory.path, 'hongguo-$channel.json'));
  }

  /// 读某个频道的首屏快照；没有、超龄或内容不可用时返回 null。
  static Future<AudiobookPoolSnapshot?> read(String channel) async {
    try {
      final file = await _file(channel);
      if (!await file.exists()) return null;
      final stat = await file.stat();
      if (DateTime.now().difference(stat.modified) > maxAge) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      if ((decoded['version'] as num?)?.toInt() != _version) return null;
      final rows = decoded['books'];
      if (rows is! List) return null;
      final books = <FanqieBook>[];
      for (final row in rows) {
        if (row is! Map) continue;
        final book = FanqieBook.fromJson(Map<String, dynamic>.from(row));
        if (book.id.isEmpty || book.title.isEmpty) continue;
        books.add(book);
      }
      if (books.isEmpty) return null;
      return AudiobookPoolSnapshot(
        books: books,
        hasMore: decoded['hasMore'] == true,
      );
    } catch (_) {
      // 快照只是加速手段：读不出来就让调用方走正常的加载态。
      return null;
    }
  }

  /// 写入某个频道的首屏快照。空列表不写（免得把「本来有内容」覆盖成空）。
  static Future<void> write(
    String channel,
    List<FanqieBook> books, {
    required bool hasMore,
  }) async {
    if (books.isEmpty) return;
    try {
      final file = await _file(channel);
      final payload = jsonEncode({
        'version': _version,
        'channel': channel,
        'savedAt': DateTime.now().toIso8601String(),
        'hasMore': hasMore,
        'books': [for (final book in books) book.toJson()],
      });
      // 先写同目录的临时文件再改名：中途被杀不会留下半截 JSON
      // （半截 JSON 会被 read 当成解析失败，等于白写一次）。
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(payload, flush: true);
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
    } catch (_) {
      // 写不进去只影响下次的启动速度，不影响本次功能。
    }
  }
}
