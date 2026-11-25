import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core_bridge.dart';
import '../local_store.dart';
import '../models.dart';

/// 推荐流的数据源：上下滑动换一部剧。
///
/// 与「发现」页的分类列表不同，这里一次只放一部剧在屏幕上，靠翻页换剧。
/// 优先用站源自己的推荐接口（`recommendations`，目前官方源支持），
/// 站源没有推荐能力时退化成该源「全部」目录，保证这个入口永远有内容。
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

  List<Drama> get items => _items;
  int get index => _index;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  String get error => _error;
  Drama? get current => _index >= 0 && _index < _items.length
      ? _items[_index]
      : null;

  /// 推荐接口只有部分站源支持；其余站源用「全部」目录顶上。
  bool get _usesRecommendations =>
      _source.isNotEmpty && SourceSite.byId(_source).recommends;

  void _storeChanged() {
    if (store.source == _source) return;
    _source = store.source;
    unawaited(refresh());
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final source = _source = store.source;
    final generation = ++_generation;
    _items = const [];
    _index = 0;
    _page = 0;
    _hasMore = true;
    _error = '';
    _loading = source.isNotEmpty;
    _notify();
    if (source.isEmpty) return;
    try {
      final page = await _load(source, 1, false);
      if (_disposed || generation != _generation) return;
      _items = _unique(page.items);
      _page = page.page;
      _hasMore = page.hasMore;
      _error = page.warning;
    } catch (error) {
      if (!_disposed && generation == _generation) _error = '$error';
    } finally {
      if (!_disposed && generation == _generation) {
        _loading = false;
        _notify();
      }
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
      final page = await _load(source, _page + 1, true);
      if (_disposed || generation != _generation) return;
      final known = {for (final item in _items) item.id};
      _items = [
        ..._items,
        for (final item in _unique(page.items))
          if (known.add(item.id)) item,
      ];
      _page = page.page;
      _hasMore = page.hasMore;
    } catch (error) {
      if (!_disposed && generation == _generation) _error = '$error';
    } finally {
      if (!_disposed && generation == _generation) {
        _loadingMore = false;
        _notify();
      }
    }
  }

  Future<CatalogPage> _load(String source, int page, bool more) {
    if (_usesRecommendations) {
      return repository.recommendations(source, _genre, more: more);
    }
    return repository.catalog(source, category: '', page: page);
  }

  /// 推荐接口的题材参数：沿用「发现」页推荐 tab 的口径。
  static const _genre = 'find_drama';

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
    _notify();
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
