import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'audiobook_fanqie.dart';

class AudiobookBookmark {
  const AudiobookBookmark({
    required this.chapterId,
    required this.chapterTitle,
    required this.seconds,
  });

  final String chapterId;
  final String chapterTitle;
  final double seconds;

  Map<String, dynamic> toJson() => {
    'chapterId': chapterId,
    'chapterTitle': chapterTitle,
    'seconds': seconds,
  };

  static AudiobookBookmark fromJson(Map<String, dynamic> json) =>
      AudiobookBookmark(
        chapterId: '${json['chapterId'] ?? ''}',
        chapterTitle: '${json['chapterTitle'] ?? ''}',
        seconds: (json['seconds'] as num?)?.toDouble() ?? 0,
      );
}

class AudiobookHistoryEntry {
  const AudiobookHistoryEntry({
    required this.book,
    required this.chapterId,
    required this.chapterTitle,
    required this.seconds,
    required this.updatedAt,
  });

  final FanqieBook book;
  final String chapterId;
  final String chapterTitle;
  final double seconds;
  final int updatedAt;
}

class AudiobookStore extends ChangeNotifier {
  AudiobookStore(this.directory);

  final Directory directory;
  final List<FanqieBook> _shelf = [];
  final List<AudiobookHistoryEntry> _history = [];
  final Map<String, Map<String, double>> _heard = {};
  final Map<String, Map<String, double>> _durations = {};
  final Map<String, List<AudiobookBookmark>> _bookmarks = {};
  final Map<String, Map<String, String>> _missing = {};
  Future<void> _pending = Future.value();
  // guoappxp 支持多用户切换：书架 / 进度 / 下载按当前用户分目录存放，
  // 每个用户保留同一份会话，切回来时仍然接着上次听。
  static final Map<String, Future<AudiobookStore>> _sharedByProfile = {};

  static Future<AudiobookStore> open({String profileId = 'default'}) {
    final existing = _sharedByProfile[profileId];
    if (existing != null) return existing;
    final created = _openShared(profileId);
    _sharedByProfile[profileId] = created;
    return created;
  }

  static Future<AudiobookStore> _openShared(String profileId) async {
    try {
      final support = await getApplicationSupportDirectory();
      final safe = profileId.isEmpty
          ? 'default'
          : profileId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      return await openDirectory(Directory('${support.path}/audiobooks/$safe'));
    } catch (error) {
      _sharedByProfile.remove(profileId);
      rethrow;
    }
  }

  static Future<AudiobookStore> openDirectory(Directory directory) async {
    await directory.create(recursive: true);
    final store = AudiobookStore(directory);
    await store._load();
    return store;
  }

  List<FanqieBook> get shelf => List.unmodifiable(_shelf);
  List<AudiobookHistoryEntry> get history => List.unmodifiable(_history);

  bool onShelf(String bookId) => _shelf.any((book) => book.id == bookId);

  List<AudiobookBookmark> bookmarks(String bookId) =>
      List.unmodifiable(_bookmarks[bookId] ?? const []);

  String? missingReason(String bookId, String chapterId) =>
      _missing[bookId]?[chapterId];

  Map<String, String> missingFor(String bookId) =>
      Map.unmodifiable(_missing[bookId] ?? const {});

  double heardSeconds(String bookId, String chapterId) =>
      _heard[bookId]?[chapterId] ?? 0;

  double durationSeconds(String bookId, String chapterId) =>
      _durations[bookId]?[chapterId] ?? 0;

  AudiobookHistoryEntry? latest(String bookId) {
    for (final entry in _history) {
      if (entry.book.id == bookId) return entry;
    }
    return null;
  }

  File audioFile(String bookId, String chapterId) =>
      File('${directory.path}/$bookId/$chapterId.m4a');

  File keyFile(String bookId, String chapterId) =>
      File('${directory.path}/$bookId/$chapterId.key');

  bool hasLocal(String bookId, String chapterId) {
    final file = audioFile(bookId, chapterId);
    return file.existsSync() && file.lengthSync() > 0;
  }

  String localKey(String bookId, String chapterId) {
    final file = keyFile(bookId, chapterId);
    if (!file.existsSync()) return '';
    return file.readAsStringSync().trim();
  }

  Future<void> toggleShelf(FanqieBook book) async {
    if (onShelf(book.id)) {
      _shelf.removeWhere((item) => item.id == book.id);
    } else {
      _shelf.insert(0, book);
    }
    notifyListeners();
    await _save();
  }

  Future<void> remember(
    FanqieBook book,
    FanqieChapter chapter,
    double seconds, {
    double duration = 0,
  }) async {
    final heard = _heard.putIfAbsent(book.id, () => {});
    heard[chapter.id] = seconds < 0 ? 0 : seconds;
    if (duration > 0) {
      _durations.putIfAbsent(book.id, () => {})[chapter.id] = duration;
    }
    _history.removeWhere((entry) => entry.book.id == book.id);
    _history.insert(
      0,
      AudiobookHistoryEntry(
        book: book,
        chapterId: chapter.id,
        chapterTitle: chapter.title,
        seconds: seconds < 0 ? 0 : seconds,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (_history.length > 50) _history.removeRange(50, _history.length);
    notifyListeners();
    await _save();
  }

  Future<void> noteDuration(
    String bookId,
    String chapterId,
    double duration,
  ) async {
    if (duration <= 0) return;
    _durations.putIfAbsent(bookId, () => {})[chapterId] = duration;
    notifyListeners();
    await _save();
  }

  Future<void> addBookmark(
    FanqieBook book,
    FanqieChapter chapter,
    double seconds,
  ) async {
    final marks = _bookmarks.putIfAbsent(book.id, () => []);
    marks.removeWhere(
      (mark) =>
          mark.chapterId == chapter.id && (mark.seconds - seconds).abs() < 1,
    );
    marks.insert(
      0,
      AudiobookBookmark(
        chapterId: chapter.id,
        chapterTitle: chapter.title,
        seconds: seconds,
      ),
    );
    notifyListeners();
    await _save();
  }

  Future<void> markMissing(
    String bookId,
    String chapterId,
    String reason,
  ) async {
    _missing.putIfAbsent(bookId, () => {})[chapterId] = reason;
    notifyListeners();
    await _save();
  }

  Future<void> clearMissing(String bookId, String chapterId) async {
    _missing[bookId]?.remove(chapterId);
    notifyListeners();
    await _save();
  }

  bool unfinished(String bookId, FanqieChapter chapter) {
    final heard = heardSeconds(bookId, chapter.id);
    final duration = durationSeconds(bookId, chapter.id);
    if (duration <= 0) return true;
    return heard < duration - 2;
  }

  Future<void> _load() async {
    final file = File('${directory.path}/index.json');
    if (!file.existsSync()) return;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return;
    for (final row in decoded['shelf'] as List? ?? const []) {
      if (row is Map) {
        final book = _book(Map<String, dynamic>.from(row));
        if (book != null) _shelf.add(book);
      }
    }
    for (final row in decoded['history'] as List? ?? const []) {
      if (row is! Map) continue;
      final map = Map<String, dynamic>.from(row);
      final book = _book(map);
      if (book == null) continue;
      _history.add(
        AudiobookHistoryEntry(
          book: book,
          chapterId: '${map['chapterId'] ?? ''}',
          chapterTitle: '${map['chapterTitle'] ?? ''}',
          seconds: (map['seconds'] as num?)?.toDouble() ?? 0,
          updatedAt: (map['updatedAt'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    final heard = decoded['heard'];
    if (heard is Map) {
      for (final entry in heard.entries) {
        final chapters = entry.value;
        if (chapters is! Map) continue;
        _heard['${entry.key}'] = {
          for (final item in chapters.entries)
            '${item.key}': (item.value as num?)?.toDouble() ?? 0,
        };
      }
    }
    final durations = decoded['durations'];
    if (durations is Map) {
      for (final entry in durations.entries) {
        final chapters = entry.value;
        if (chapters is! Map) continue;
        _durations['${entry.key}'] = {
          for (final item in chapters.entries)
            '${item.key}': (item.value as num?)?.toDouble() ?? 0,
        };
      }
    }
    final bookmarks = decoded['bookmarks'];
    if (bookmarks is Map) {
      for (final entry in bookmarks.entries) {
        final rows = entry.value;
        if (rows is! List) continue;
        _bookmarks['${entry.key}'] = [
          for (final row in rows)
            if (row is Map)
              AudiobookBookmark.fromJson(Map<String, dynamic>.from(row)),
        ];
      }
    }
    final missing = decoded['missing'];
    if (missing is Map) {
      for (final entry in missing.entries) {
        final rows = entry.value;
        if (rows is! Map) continue;
        _missing['${entry.key}'] = {
          for (final item in rows.entries) '${item.key}': '${item.value}',
        };
      }
    }
  }

  Future<void> _save() {
    _pending = _pending.catchError((Object _) {}).then((_) => _write());
    return _pending;
  }

  Future<void> _write() async {
    await directory.create(recursive: true);
    final file = File('${directory.path}/index.json');
    await file.writeAsString(
      jsonEncode({
        'shelf': [for (final book in _shelf) _bookJson(book)],
        'history': [
          for (final entry in _history)
            {
              ..._bookJson(entry.book),
              'chapterId': entry.chapterId,
              'chapterTitle': entry.chapterTitle,
              'seconds': entry.seconds,
              'updatedAt': entry.updatedAt,
            },
        ],
        'heard': _heard,
        'durations': _durations,
        'bookmarks': {
          for (final entry in _bookmarks.entries)
            entry.key: [for (final mark in entry.value) mark.toJson()],
        },
        'missing': _missing,
      }),
    );
  }

  static FanqieBook? _book(Map<String, dynamic> json) {
    final id = '${json['id'] ?? ''}'.trim();
    final title = '${json['title'] ?? ''}'.trim();
    if (id.isEmpty || title.isEmpty) return null;
    return FanqieBook(
      id: id,
      title: title,
      author: '${json['author'] ?? ''}',
      category: '${json['category'] ?? ''}',
      // 旧存档没有这两个字段，缺省空串即可，封面/简介为空时列表用占位。
      cover: '${json['cover'] ?? ''}',
      intro: '${json['intro'] ?? ''}',
      // 旧存档没有 source，按番茄听书处理；红果听书写入 hongguo。
      source: '${json['source'] ?? 'fanqie'}',
    );
  }

  static Map<String, dynamic> _bookJson(FanqieBook book) => {
    'id': book.id,
    'title': book.title,
    'author': book.author,
    'category': book.category,
    'cover': book.cover,
    'intro': book.intro,
    'source': book.source,
  };
}

List<FanqieChapter> selectAudiobookDownloads({
  required List<FanqieChapter> chapters,
  required String kind,
  required String bookId,
  required AudiobookStore store,
  String chapterId = '',
  int fromOrder = 0,
  int toOrder = 0,
}) {
  switch (kind) {
    case 'single':
      return [
        for (final chapter in chapters)
          if (chapter.id == chapterId && !store.hasLocal(bookId, chapter.id))
            chapter,
      ];
    case 'range':
      final start = fromOrder < toOrder ? fromOrder : toOrder;
      final end = fromOrder < toOrder ? toOrder : fromOrder;
      return [
        for (final chapter in chapters)
          if (chapter.order >= start &&
              chapter.order <= end &&
              !store.hasLocal(bookId, chapter.id))
            chapter,
      ];
    case 'unfinished':
      return [
        for (final chapter in chapters)
          if (store.unfinished(bookId, chapter) &&
              !store.hasLocal(bookId, chapter.id))
            chapter,
      ];
    case 'missing':
      return [
        for (final chapter in chapters)
          if (store.missingReason(bookId, chapter.id) != null) chapter,
      ];
    case 'all':
      return [
        for (final chapter in chapters)
          if (!store.hasLocal(bookId, chapter.id)) chapter,
      ];
  }
  return const [];
}

double seekAudiobookSeconds(double position, int delta, double duration) {
  final next = position + delta;
  if (next < 0) return 0;
  if (duration > 0 && next > duration) return duration;
  return next;
}

String formatAudiobookClock(double seconds) {
  final whole = seconds.isFinite && seconds > 0 ? seconds.round() : 0;
  final hours = whole ~/ 3600;
  final minutes = (whole % 3600) ~/ 60;
  final remain = whole % 60;
  final clock =
      '${minutes.toString().padLeft(2, '0')}:${remain.toString().padLeft(2, '0')}';
  if (hours <= 0) return clock;
  return '$hours:$clock';
}
