import 'dart:io';

import 'audiobook_fanqie.dart';
import 'audiobook_store.dart';
import '../../core_bridge.dart';

class AudiobookOpenTarget {
  const AudiobookOpenTarget({
    required this.url,
    required this.key,
    required this.headers,
    required this.local,
  });

  final String url;
  final String key;
  final Map<String, String> headers;
  final bool local;
}

class AudiobookDownloadProgress {
  const AudiobookDownloadProgress({
    required this.completed,
    required this.total,
    required this.failed,
    required this.currentTitle,
  });

  final int completed;
  final int total;
  final int failed;
  final String currentTitle;
}

typedef AudiobookMediaLookup =
    Future<Map<String, dynamic>> Function(String bookId, String chapterId);

AudiobookOpenTarget audiobookOpenTarget({
  required AudiobookStore store,
  required String bookId,
  required String chapterId,
  Map<String, dynamic>? remote,
}) {
  if (store.hasLocal(bookId, chapterId)) {
    return AudiobookOpenTarget(
      url: store.audioFile(bookId, chapterId).path,
      key: store.localKey(bookId, chapterId),
      headers: const {},
      local: true,
    );
  }
  final plan = remote ?? const <String, dynamic>{};
  // 较新的核心会给在线音频附一个本机明文流地址（带 .m4a 扩展名，上游
  // Referer / User-Agent 由 Go 侧统一注入），优先播它。
  //
  // 但 duanju_core.dll / libduanju_core.so 是编译产物，没有重新执行
  // build_native.py 时核心里根本没有这段逻辑，streamUrl 不存在。这时
  // 保留原始 url 和 headers，由 AudiobookSession 用纯 Dart 的本机代理
  // 再包一层（见 audiobook_stream_proxy.dart）——不管核心新旧，播放器
  // 最终拿到的都是带扩展名的本机地址，不依赖播放器转发请求头。
  // 下载路径仍用原始 url，不受这里影响。
  final streamUrl = '${plan['streamUrl'] ?? ''}'.trim();
  final rawHeaders = plan['headers'];
  final headers = rawHeaders is Map
      ? rawHeaders.map((key, value) => MapEntry('$key', '$value'))
      : const <String, String>{};
  return AudiobookOpenTarget(
    url: streamUrl.isNotEmpty ? streamUrl : '${plan['url'] ?? ''}',
    key: '${plan['decryptionKey'] ?? ''}',
    // 走本地流时请求头已由核心加上，不必再让播放器转发一份。
    headers: streamUrl.isNotEmpty ? const <String, String>{} : headers,
    local: false,
  );
}

Future<AudiobookDownloadProgress> downloadAudiobookChapters({
  required AudiobookMediaLookup media,
  required AudiobookStore store,
  required FanqieBook book,
  required List<FanqieChapter> chapters,
  bool Function()? cancelled,
  void Function(AudiobookDownloadProgress progress)? onProgress,
}) async {
  var completed = 0;
  var failed = 0;
  for (final chapter in chapters) {
    if (cancelled?.call() == true) break;
    onProgress?.call(
      AudiobookDownloadProgress(
        completed: completed,
        total: chapters.length,
        failed: failed,
        currentTitle: chapter.title,
      ),
    );
    try {
      final plan = await media(book.id, chapter.id);
      if (cancelled?.call() == true) break;
      final url = '${plan['url'] ?? ''}';
      if (url.isEmpty) throw AppFailure('这一章暂时没有音频地址');
      final rawHeaders = plan['headers'];
      final headers = rawHeaders is Map
          ? rawHeaders.map((key, value) => MapEntry('$key', '$value'))
          : const <String, String>{};
      final key = '${plan['decryptionKey'] ?? ''}';
      final file = store.audioFile(book.id, chapter.id);
      await saveAudiobookAudio(
        url: url,
        headers: headers,
        destination: file,
        cancelled: cancelled,
      );
      final keyFile = store.keyFile(book.id, chapter.id);
      if (key.isEmpty) {
        if (keyFile.existsSync()) await keyFile.delete();
      } else {
        await keyFile.parent.create(recursive: true);
        await keyFile.writeAsString(key);
      }
      final duration = (plan['duration'] as num?)?.toDouble() ?? 0;
      if (duration > 0) {
        await store.noteDuration(book.id, chapter.id, duration);
      }
      await store.clearMissing(book.id, chapter.id);
      completed++;
    } catch (error) {
      if (cancelled?.call() == true) break;
      failed++;
      await _removeEmpty(store.audioFile(book.id, chapter.id));
      await store.markMissing(book.id, chapter.id, '$error');
    }
  }
  final result = AudiobookDownloadProgress(
    completed: completed,
    total: chapters.length,
    failed: failed,
    currentTitle: '',
  );
  onProgress?.call(result);
  return result;
}

Future<void> saveAudiobookAudio({
  required String url,
  required Map<String, String> headers,
  required File destination,
  bool Function()? cancelled,
}) async {
  final part = File('${destination.path}.part');
  await destination.parent.create(recursive: true);
  if (part.existsSync()) await part.delete();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  IOSink? sink;
  try {
    final request = await client.getUrl(Uri.parse(url));
    headers.forEach((name, value) {
      if (value.isNotEmpty) request.headers.set(name, value);
    });
    final response = await request.close();
    final status = response.statusCode;
    if (status != 200 && status != 206) {
      await response.drain<void>();
      throw AppFailure('下载返回 $status');
    }
    sink = part.openWrite();
    var bytes = 0;
    await for (final chunk in response) {
      if (cancelled?.call() == true) throw AppFailure('已停止下载');
      bytes += chunk.length;
      sink.add(chunk);
    }
    await sink.flush();
    await sink.close();
    sink = null;
    if (bytes <= 0) throw AppFailure('下载到的音频是空的');
    if (destination.existsSync()) await destination.delete();
    await part.rename(destination.path);
  } catch (error) {
    final open = sink;
    sink = null;
    if (open != null) {
      try {
        await open.close();
      } catch (_) {}
    }
    if (part.existsSync()) {
      try {
        await part.delete();
      } catch (_) {}
    }
    if (error is AppFailure) rethrow;
    throw AppFailure('无法下载这一章');
  } finally {
    client.close(force: true);
  }
}

Future<void> _removeEmpty(File file) async {
  if (!file.existsSync() || file.lengthSync() > 0) return;
  try {
    await file.delete();
  } catch (_) {}
}
