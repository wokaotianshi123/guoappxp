import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core_bridge.dart';
import '../js_source/js_source_models.dart';
import '../local_store.dart';
import '../models.dart';

/// 推荐流的数据源：上下滑动换一部剧。
///
/// 与「发现」页的分类列表不同，这里一次只放一部剧在屏幕上，靠翻页换剧。
/// 官方 JS 源固定走「全部」分类：脚本里的「推荐」是 `tab_type 38` 的一段信息流，
/// 「全部」（`tab_type 8`）才是能一直翻下去的主列表。模块 / 内核源保持各自的
/// 推荐接口，它们的翻页口径是按源单独调好的，换掉反而会取不到流。
class RecommendFeed extends ChangeNotifier {
  RecommendFeed(this.repository, this.store) {
    store.addListener(_storeChanged);
  }

  final AppRepository repository;
  final LocalStore store;

  List<Drama> _items = const [];
  int _index = 0;
  int _page = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String _error = '';
  int _generation = 0;
  bool _disposed = false;
  String _source = '';

  /// 已拉到的剧集详情，供全屏播放建播放句柄用。
  final _details = <String, DramaDetail>{};
  final _loadingDetails = <String>{};
  final _detailErrors = <String, String>{};

  /// 这个源上已经展示过的剧集，供「换一批」跳过重复内容。
  ///
  /// 脚本与内核都会缓存第一页（hongguo.js 缓存 60 秒），重新请求第一页只会
  /// 原样返回，所以换一批只能靠往后翻页 + 去重。记录上限避免长会话占内存。
  final _seen = <String>{};
  static const _seenLimit = 400;

  List<Drama> get items => _items;
  int get index => _index;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  String get error => _error;
  Drama? get current => _index >= 0 && _index < _items.length
      ? _items[_index]
      : null;

  /// 已缓存的详情；没有就返回 null，由 [loadDetail] 去拉。
  DramaDetail? detailOf(String dramaId) => _details[dramaId];

  bool detailLoading(String dramaId) => _loadingDetails.contains(dramaId);

  /// 某部剧详情加载失败的原因；没失败就是 null。
  String? detailError(String dramaId) => _detailErrors[dramaId];

  /// 拉取某部剧的详情（含分集）。成功后缓存，播放页据此建播放句柄。
  ///
  /// [force] 为真时忽略缓存与「正在加载」标记，用于用户点重试。
  Future<void> loadDetail(Drama drama, {bool force = false}) async {
    if (_disposed || drama.id.isEmpty) return;
    if (!force) {
      if (_details.containsKey(drama.id)) return;
      if (!_loadingDetails.add(drama.id)) return;
    } else {
      _loadingDetails.add(drama.id);
    }
    _detailErrors.remove(drama.id);
    _notify();
    try {
      final detail = await repository.detail(drama);
      if (_disposed) return;
      if (detail.episodes.isNotEmpty) {
        _details[drama.id] = detail;
        // 只留最近 8 条，避免长列表把详情全攒在内存里。
        while (_details.length > 8) {
          _details.remove(_details.keys.first);
        }
      } else {
        _detailErrors[drama.id] = '没有返回可播放的分集';
      }
    } catch (error) {
      if (!_disposed) _detailErrors[drama.id] = '$error';
    } finally {
      _loadingDetails.remove(drama.id);
      _notify();
    }
  }

  /// 推荐接口只有部分站源支持；其余站源用「全部」目录顶上。
  void _storeChanged() {
    if (store.source == _source) return;
    _source = store.source;
    unawaited(refresh());
  }

  Future<void> refresh({bool advance = false}) async {
    if (_disposed) return;
    final source = _source = store.source;
    final generation = ++_generation;
    if (!advance) {
      // 换源 / 首次加载：去重记录属于上一个源，一起清掉。
      _seen.clear();
      _page = 0;
    }
    _items = const [];
    _index = 0;
    _hasMore = true;
    _error = '';
    _details.clear();
    _loadingDetails.clear();
    _detailErrors.clear();
    _loading = source.isNotEmpty;
    _notify();
    if (source.isEmpty) return;
    try {
      final page = advance
          ? await _nextBatch(source, generation)
          : await _fetch(source, 1, generation);
      if (_disposed || generation != _generation) return;
      _items = _unique(page.items);
      _page = page.page;
      _hasMore = page.hasMore;
      _error = page.warning;
      _remember(_items);
      // 首屏先把第一部的详情拉好，进来就能直接起播。
      // 这里刻意 await：否则进页面会先闪一下封面再出画面。
      if (_items.isNotEmpty) await loadDetail(_items.first);
    } catch (error) {
      if (!_disposed && generation == _generation) {
        // 换源竞态里的取消是内核 / 沙箱的内部措辞，直接显示「context canceled」
        // 只会让人以为站源坏了。
        _error = _cancelled(error) ? '站源刚刚切换，点「刷新」重试' : '$error';
      }
    } finally {
      if (!_disposed && generation == _generation) {
        _loading = false;
        _notify();
      }
    }
  }

  /// 「换一批」：从当前页往后翻，跳过已经展示过的剧集。
  ///
  /// 第一页在脚本 / 内核里都有缓存，重新拉第一页只会拿回同一批，所以刷新
  /// 按钮必须往后翻页；翻到底后回到第一页重新开始，避免换出一张空页。
  Future<CatalogPage> _nextBatch(String source, int generation) async {
    var page = _page + 1;
    for (var attempt = 0; attempt < 4; attempt++) {
      final result = await _fetch(source, page, generation);
      if (_disposed || generation != _generation) return result;
      final fresh = [
        for (final drama in result.items)
          if (drama.id.isNotEmpty && !_seen.contains(drama.id)) drama,
      ];
      if (fresh.isNotEmpty) {
        return CatalogPage(
          fresh,
          page: result.page,
          hasMore: result.hasMore,
          warning: result.warning,
        );
      }
      if (!result.hasMore) break;
      page = (result.page > page ? result.page : page) + 1;
    }
    // 翻到底 / 连续几页都是老内容：清空去重记录，从头再来一轮。
    _seen.clear();
    return _fetch(source, 1, generation);
  }

  void _remember(Iterable<Drama> items) {
    for (final drama in items) {
      if (drama.id.isNotEmpty) _seen.add(drama.id);
    }
    while (_seen.length > _seenLimit) {
      _seen.remove(_seen.first);
    }
  }

  Future<void> loadMore() async {
    if (_disposed || _loading || _loadingMore || !_hasMore) return;
    final source = _source;
    if (source.isEmpty) return;
    final generation = _generation;
    _loadingMore = true;
    _notify();
    try {
      final page = await _load(source, _page + 1);
      if (_disposed || generation != _generation) return;
      final known = {for (final item in _items) item.id};
      final added = [
        for (final item in _unique(page.items))
          if (known.add(item.id)) item,
      ];
      _items = [..._items, ...added];
      _page = page.page;
      _hasMore = page.hasMore;
      _remember(added);
    } catch (error) {
      if (!_disposed && generation == _generation) _error = '$error';
    } finally {
      if (!_disposed && generation == _generation) {
        _loadingMore = false;
        _notify();
      }
    }
  }

  Future<CatalogPage> _load(String source, int page) {
    if (!isJsSourceId(source) && SourceSite.byId(source).recommends) {
      return repository.recommendations(
        source,
        _genre,
        more: page > 1,
        lane: _lane,
      );
    }
    return repository.catalog(
      source,
      category: '',
      page: page,
      lane: _lane,
    );
  }

  /// 推荐流在内核里的读取会话标记。
  ///
  /// 内核按会话名串行化同类请求：同一会话来了更新的请求就会取消前一个。
  /// 发现页也在同一站源上取流，两边若共用会话名就会互相取消，表现为换源后
  /// 推荐页停在「context canceled」。带上独立标记各取各的。
  static const _lane = 'feed';

  /// 非 JS 源的推荐接口题材参数：沿用「发现」页推荐 tab 的口径。
  static const _genre = 'find_drama';

  /// 换源瞬间「发现」页会取消在途的目录 / 推荐读取，首屏请求被误伤很常见。
  /// 这种取消是内部实现的产物，不该变成用户可见的报错，稍等重取一次即可。
  static bool _cancelled(Object error) {
    final text = '$error'.toLowerCase();
    return text.contains('context canceled') ||
        text.contains('cancelled') ||
        text.contains('canceled') ||
        text.contains('取消');
  }

  /// 取一页，遇到「被取消」自动重试一次。
  Future<CatalogPage> _fetch(String source, int page, int generation) async {
    try {
      return await _load(source, page);
    } catch (error) {
      if (!_cancelled(error) || _disposed || generation != _generation) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (_disposed || generation != _generation) rethrow;
      return _load(source, page);
    }
  }

  List<Drama> _unique(Iterable<Drama> values) {
    final seen = <String>{};
    return [
      for (final drama in values)
        if (drama.id.isNotEmpty && seen.add(drama.id)) drama,
    ];
  }

  void select(int value) {
    if (_disposed || value < 0 || value >= _items.length) return;
    if (value == _index) return;
    _index = value;
    // 上一轮失败（比如起播时把请求连带取消了）不该挡住这次重新拉取。
    _detailErrors.remove(_items[value].id);
    _notify();
    // 当前这部与下一部都提前把详情拉好，滑过去就能直接起播。
    unawaited(loadDetail(_items[value]));
    final next = value + 1;
    if (next < _items.length) unawaited(loadDetail(_items[next]));
    // 快滑到底部时提前补一页，避免最后一部之后突然空掉。
    if (_items.length - _index <= 2) unawaited(loadMore());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    store.removeListener(_storeChanged);
    super.dispose();
  }
}
