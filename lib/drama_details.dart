import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'follow_state.dart';
import 'hongguo_series.dart';
import 'local_store.dart';
import 'models.dart';

const episodeGroupSize = 30;

class DramaDetails extends ChangeNotifier {
  DramaDetails(this.repository, this.store, Drama drama)
    : _drama = repository.catalogUpdates.current(drama),
      _epoch = store.profileEpoch {
    store.addListener(_notify);
    load();
  }
  final AppRepository repository;
  final LocalStore store;
  final int _epoch;
  Drama _drama;
  List<Episode> _episodes = const [];
  List<DramaSeason> _seasons = const [];
  String _warning = '';
  String? _error;
  bool _loading = false;
  int _group = 0;
  int _generation = 0;
  bool _disposed = false;

  Drama get drama => _drama;
  List<Episode> get episodes => _episodes;
  List<DramaSeason> get seasons => _seasons;
  String get warning => _warning;
  String? get error => _error;
  bool get loading => _loading;
  bool get allowed =>
      store.profileEpoch == _epoch && store.allowsSource(_drama.source);
  WatchEntry? get watch => allowed ? store.watched(_drama.id) : null;
  int get resumeIndex => resumeEpisodeIndex(_episodes, watch);
  int? get currentIndex {
    final number = watch?.episode;
    final index = _episodes.indexWhere((episode) => episode.number == number);
    return index < 0 ? null : index;
  }

  int get groupCount => (_episodes.length / episodeGroupSize).ceil();
  int get group => _group;
  List<Episode> get groupEpisodes =>
      _episodes.skip(_group * episodeGroupSize).take(episodeGroupSize).toList();

  String groupLabel(int group) {
    final start = group * episodeGroupSize;
    final end = (start + episodeGroupSize).clamp(0, _episodes.length) - 1;
    return '${_episodes[start].number}-${_episodes[end].number}';
  }

  void selectGroup(int group) {
    if (group == _group || group < 0 || group >= groupCount) return;
    _group = group;
    _notify();
  }

  Future<void> load() async {
    if (!allowed) return;
    final generation = ++_generation;
    _loading = true;
    _error = null;
    _notify();
    try {
      final detail = await repository.detail(_drama);
      if (!_current(generation)) return;
      _drama = repository.catalogUpdates.current(_drama).merge(detail.drama);
      _episodes = detail.episodes;
      _warning = detail.warning;
      _group = groupCount == 0 ? 0 : resumeIndex ~/ episodeGroupSize;
      _loading = false;
      _notify();
      repository.catalogUpdates.publish(_drama, retryCover: true);
      unawaited(store.refreshDrama(_drama).catchError((Object _) {}));
      unawaited(_supplement(generation));
      if (!_seasons.any((season) => season.drama.id == _drama.id)) {
        unawaited(_loadSeasons(generation));
      }
    } catch (error) {
      if (!_current(generation)) return;
      _error = error.toString();
      _loading = false;
      _notify();
      repository.catalogUpdates.publish(_drama, retryCover: true);
    }
  }

  /// 季列表单独取：失败了只影响卡片条，不影响详情和分集。
  Future<void> _loadSeasons(int generation) async {
    var seasons = <DramaSeason>[];
    try {
      seasons = await repository.seasons(_drama);
    } catch (_) {
      // 核心不支持 / 报错时继续走下面的 Dart 层兜底。
    }
    if (!_current(generation)) return;
    // 桌面端（Windows / macOS）的站源来自外置源包，SeasonProvider 常返回
    // 空或只给当前一季；旧版核心也不会跑内置的「基础名 + 季号」补搜。
    // 上一版把补搜放在 Go 核心里，但 duanju_core.dll 是编译产物：没有重新
    // 执行 build_native.py 时核心里根本没有那段逻辑，卡片条依旧不出现。
    // 这里在 Dart 层兜底 —— 核心给的季不足两季时，按基础名自己搜一遍再用
    // hongguoSeriesEntries 分组；只要重新构建 Flutter 应用就必定生效。
    if (seasons.length < 2 && _drama.source == SourceSite.hongguo.id) {
      try {
        final fallback = await _searchSeasons(generation);
        if (!_current(generation)) return;
        if (fallback.length > seasons.length) seasons = fallback;
      } catch (_) {
        // 兜底失败不影响核心已经给出的季。
      }
    }
    _seasons = seasons;
    _notify();
  }

  /// 用站源自己的搜索把同一系列各季找回来，再按季号分组。
  ///
  /// 第一季标题通常不带「第一季」后缀（就是基础名），hongguoSeriesEntries
  /// 会把 anchor 当作第 1 季，并从候选里推断「季 / 部」单位，因此不会漏。
  Future<List<DramaSeason>> _searchSeasons(int generation) async {
    final info = hongguoSeriesInfo(_drama);
    final query = (info?.baseTitle ?? _drama.title).trim();
    if (query.isEmpty) return const <DramaSeason>[];
    final started = await repository.searchStart([_drama.source], query);
    var progress = started;
    try {
      for (var round = 0; round < 6 && !progress.finished; round++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!_current(generation)) return const <DramaSeason>[];
        progress = await repository.searchPoll(started.id);
      }
    } finally {
      // 聚合搜索是核心里的后台会话，取完就注销，不留常驻任务。
      try {
        await repository.searchCancel(started.id);
      } catch (_) {}
    }
    final candidates = <Drama>[...started.items, ...progress.items];
    final entries = hongguoSeriesEntries(_drama, candidates);
    return <DramaSeason>[
      for (final entry in entries)
        DramaSeason(number: entry.season, drama: entry.drama),
    ];
  }

  /// 切到另一季：清掉当前分集再重新加载，加载完即可直接播放。
  Future<void> selectSeason(DramaSeason season) async {
    if (!allowed || season.drama.id == _drama.id) return;
    _drama = repository.catalogUpdates.current(season.drama);
    _episodes = const [];
    _warning = '';
    _group = 0;
    _notify();
    await load();
  }

  Future<void> _supplement(int generation) async {    try {
      final fresh = await repository.supplementMetadata(_drama);
      if (fresh == null || !_current(generation)) return;
      _drama = _drama.merge(fresh);
      _notify();
      repository.catalogUpdates.publish(_drama);
      await store.refreshDrama(_drama);
    } catch (_) {}
  }

  bool _current(int generation) =>
      !_disposed && generation == _generation && allowed;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_notify);
    super.dispose();
  }
}
