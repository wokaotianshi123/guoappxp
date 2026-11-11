import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'audiobook_download.dart';
import 'audiobook_fanqie.dart';
import 'audiobook_store.dart';
import '../../core_bridge.dart';

enum AudiobookSleep {
  off(0, '关'),
  quarter(15, '15分钟'),
  half(30, '30分钟'),
  hour(60, '60分钟'),
  long(90, '90分钟'),
  chapter(0, '本章结束');

  const AudiobookSleep(this.minutes, this.label);
  final int minutes;
  final String label;
}

/// 全应用唯一的听书播放会话。
///
/// 播放器不再归听书页面所有：离开听书页面只是关掉界面，声音继续播放，
/// 自动续播下一章、记进度、睡眠定时都在这里进行；回到听书页面或点迷你播放条
/// 会接上同一个会话。
class AudiobookSession extends ChangeNotifier {
  AudiobookSession._();

  static final AudiobookSession instance = AudiobookSession._();

  /// 测试用：替换真实播放器（测试环境没有 libmpv）。
  @visibleForTesting
  static Player Function()? debugPlayerFactory;

  Player? _player;
  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _clock;
  Timer? _sleepTimer;

  AppRepository? repository;
  FanqieAudiobookApi? api;
  AudiobookStore? store;
  FanqieBook? book;
  List<FanqieChapter> chapters = const [];
  int index = 0;

  AudiobookSleep sleep = AudiobookSleep.off;
  bool loading = false;
  bool ready = false;
  bool playing = false;
  bool local = false;
  String? error;
  double speed = 1;
  double position = 0;
  double duration = 0;

  double _resumeFloor = 0;
  bool _caughtUp = true;
  int _generation = 0;
  bool _opening = false;
  bool _handledEnd = false;
  bool _heardProgress = false;
  bool _asleep = false;

  bool get active => book != null && chapters.isNotEmpty;
  FanqieChapter? get chapter =>
      active && index >= 0 && index < chapters.length ? chapters[index] : null;
  bool get hasNext => active && index + 1 < chapters.length;
  bool get hasPrevious => active && index > 0;

  Player get player {
    final existing = _player;
    if (existing != null) return existing;
    final created = debugPlayerFactory?.call() ?? Player();
    _player = created;
    _subs
      ..add(created.stream.position.listen(_notePosition))
      ..add(
        created.stream.playing.listen((value) {
          playing = value;
          if (!value) unawaited(persist());
          notifyListeners();
        }),
      )
      ..add(
        created.stream.completed.listen((done) {
          if (done && _heardProgress) _finishChapter();
        }),
      );
    _clock ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (playing) unawaited(persist());
    });
    return created;
  }

  /// 打开某本书的某一章。若同一本书同一章已在播放，只接上会话，不重新打开。
  Future<void> start({
    required AppRepository repository,
    required FanqieAudiobookApi api,
    required AudiobookStore store,
    required FanqieBook book,
    required List<FanqieChapter> chapters,
    required int index,
  }) async {
    if (chapters.isEmpty) return;
    final target = index.clamp(0, chapters.length - 1).toInt();
    // 只在已经 ready 时复用会话。loading 也算 same 会踩坑：旧 open
    // 被 generation 作废后仍留下 loading=true，再点同一章会直接 return，
    // 音频永远打不开。
    final same =
        this.book?.id == book.id && chapter?.id == chapters[target].id && ready;
    this.repository = repository;
    this.api = api;
    this.store = store;
    // 参数 index 和字段同名：这里必须写 this.index，否则只改了参数，
    // 会话仍停在原来的章节（新会话就是第 1 章）。
    if (same) {
      this.chapters = List<FanqieChapter>.of(chapters);
      this.index = target;
      notifyListeners();
      return;
    }
    // 先抬 generation，作废还在飞的 open，避免旧章取流/player.open 在切章后晚到。
    _generation++;
    await persist();
    this.book = book;
    this.chapters = List<FanqieChapter>.of(chapters);
    this.index = target;
    await open();
  }

  double secondsToSave() {
    var seconds = (_player?.state.position.inMilliseconds ?? 0) / 1000;
    if (!_caughtUp && seconds + 1 < _resumeFloor) seconds = _resumeFloor;
    if (seconds < 0) return 0;
    return seconds;
  }

  Future<void> persist() async {
    final current = chapter;
    final store = this.store;
    final book = this.book;
    if (!ready || current == null || store == null || book == null) return;
    final total = (_player?.state.duration.inMilliseconds ?? 0) / 1000;
    await store.remember(book, current, secondsToSave(), duration: total);
  }

  void _notePosition(Duration value) {
    final seconds = value.inMilliseconds / 1000;
    final total = (_player?.state.duration.inMilliseconds ?? 0) / 1000;
    if (_resumeFloor <= 1 || seconds + 2 >= _resumeFloor) _caughtUp = true;
    if (total > 1 && seconds + 1.5 < total) _heardProgress = true;
    if (_heardProgress && total > 1 && seconds >= total - 0.35) {
      _finishChapter();
    }
    position = seconds;
    if (total > 0) duration = total;
    notifyListeners();
  }

  void _finishChapter() {
    if (_handledEnd || !ready || _opening || _asleep) return;
    _handledEnd = true;
    if (sleep == AudiobookSleep.chapter) {
      sleep = AudiobookSleep.off;
      unawaited(_player?.pause());
      notifyListeners();
      return;
    }
    if (!hasNext) return;
    unawaited(step(1));
  }

  Future<void> open({double? at}) async {
    final current = chapter;
    final store = this.store;
    final repository = this.repository;
    final book = this.book;
    if (current == null ||
        store == null ||
        repository == null ||
        book == null) {
      return;
    }
    final generation = ++_generation;
    _opening = true;
    _handledEnd = true;
    _heardProgress = false;
    _asleep = false;

    final localFile = store.hasLocal(book.id, current.id);
    final resume = at ?? store.heardSeconds(book.id, current.id);
    ready = false;
    _resumeFloor = resume < 0 ? 0 : resume;
    _caughtUp = _resumeFloor <= 1;
    local = localFile;
    loading = true;
    error = null;
    position = _resumeFloor;
    duration = 0;
    notifyListeners();
    final player = this.player;
    try {
      Map<String, dynamic>? remote;
      if (!localFile) {
        remote = await repository.audiobookMedia(book.id, current.id);
        if (generation != _generation) {
          _opening = false;
          return;
        }
        final total = (remote['duration'] as num?)?.toDouble() ?? 0;
        if (total > 0) await store.noteDuration(book.id, current.id, total);
      }
      if (generation != _generation) {
        _opening = false;
        return;
      }
      final target = audiobookOpenTarget(
        store: store,
        bookId: book.id,
        chapterId: current.id,
        remote: remote,
      );
      if (target.url.isEmpty) throw AppFailure('这一章暂时没有音频地址');
      final platform = player.platform;
      if (platform is NativePlayer) {
        if (Platform.isAndroid) {
          await platform.setProperty('ao', 'audiotrack,opensles');
        }
        await platform.setProperty(
          'demuxer-lavf-o',
          [
            'strict=experimental',
            target.local
                ? 'protocol_whitelist=[file,crypto,data]'
                : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
            if (target.key.isNotEmpty) 'decryption_key=${target.key}',
          ].join(','),
        );
        if (!target.local) await platform.setProperty('network-timeout', '20');
      }
      if (generation != _generation) {
        _opening = false;
        return;
      }
      await player.setRate(speed);
      await player.open(
        Media(
          target.url,
          httpHeaders: target.headers,
          start: _resumeFloor > 0.5
              ? Duration(milliseconds: (_resumeFloor * 1000).round())
              : null,
        ),
      );
      if (generation != _generation) {
        _opening = false;
        return;
      }
      ready = true;
      _opening = false;
      _handledEnd = false;
      local = target.local;
      loading = false;
      duration = player.state.duration.inMilliseconds / 1000;
      notifyListeners();
    } catch (failure) {
      if (generation != _generation) return;
      ready = false;
      _opening = false;
      final message = '$failure';
      if (localFile) await store.markMissing(book.id, current.id, message);
      if (generation != _generation) return;
      loading = false;
      error = message;
      notifyListeners();
    }
  }

  Future<void> step(int delta) async {
    final next = index + delta;
    if (next < 0 || next >= chapters.length) return;
    await persist();
    index = next;
    await open();
  }

  Future<void> jumpToChapter(int target, {double? at}) async {
    if (target < 0 || target >= chapters.length) return;
    if (target == index && ready) {
      if (at != null) await seekTo(at);
      return;
    }
    await persist();
    index = target;
    await open(at: at);
  }

  Future<void> seekTo(double seconds) async {
    _caughtUp = true;
    _handledEnd = false;
    position = seconds;
    notifyListeners();
    await _player?.seek(Duration(milliseconds: (seconds * 1000).round()));
    await persist();
  }

  Future<void> seekBy(int seconds) async {
    final total = (_player?.state.duration.inMilliseconds ?? 0) / 1000;
    await seekTo(seekAudiobookSeconds(secondsToSave(), seconds, total));
  }

  Future<void> playOrPause() async => _player?.playOrPause();

  Future<void> setSpeed(double value) async {
    speed = value;
    notifyListeners();
    await _player?.setRate(value);
  }

  void armSleep(AudiobookSleep value) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _asleep = false;
    sleep = value;
    notifyListeners();
    if (value == AudiobookSleep.off || value == AudiobookSleep.chapter) return;
    _sleepTimer = Timer(Duration(minutes: value.minutes), () async {
      _asleep = true;
      sleep = AudiobookSleep.off;
      notifyListeners();
      await _player?.pause();
    });
  }

  /// 关掉迷你播放条：记下进度，停止播放并释放播放器。
  Future<void> stop() async {
    await persist();
    _generation++;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _clock?.cancel();
    _clock = null;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    final player = _player;
    _player = null;
    book = null;
    chapters = const [];
    index = 0;
    ready = false;
    loading = false;
    playing = false;
    error = null;
    position = 0;
    duration = 0;
    sleep = AudiobookSleep.off;
    notifyListeners();
    await player?.dispose();
  }
}
