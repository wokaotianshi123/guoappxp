import 'core_bridge.dart';
import 'models.dart';
import 'ranking_models.dart';

String categoryName(String name) {
  final compact = name.trim().replaceAll(RegExp(r'\s+'), '');
  return switch (compact) {
    'AI成人短剧' || 'AI短剧' => 'AI 短剧',
    'AI成人漫剧' || 'AI漫剧' => 'AI 漫剧',
    'AI换脸' => 'AI 换脸',
    'AI魔改' => 'AI 魔改',
    'AI剧' => 'AI 剧',
    '' => '未分类',
    _ => name.trim(),
  };
}

class SourceCatalog {
  SourceCatalog(this.repository, this.source);
  final AppRepository repository;
  final SourceSite source;
  List<CatalogCategory> _remote = const [];
  List<RankingBoard> _boards = const [];

  static const recommendGenre = 'find_drama';

  bool get recommends => source.recommends;

  List<RankingBoard> get boards => _boards;

  /// 分类条严格等于站源声明的分类（外加预置的「全部」）。
  ///
  /// 以前这里会从已缓存剧集里反推出 `local:xxx` 分类追加进去，导致模块 / JS /
  /// XBPQ 三种源都会冒出与站源设置不符的多余分类（如「成长」「都市」「未分类」），
  /// 而且用户浏览得越多、tab 越多。分类只认 `Categories` / `home.class` /
  /// `type_name` 给出的结果；缓存剧集只用于显示，不再参与分类生成。
  List<CatalogCategory> get categories {
    final names = <String>{};
    final remote = <CatalogCategory>[];
    for (final category in _remote) {
      if (category.id.isEmpty) continue;
      final name = categoryName(category.name);
      if (!names.add(name)) continue;
      remote.add(CatalogCategory(category.id, name));
    }
    return [CatalogCategory.all, ...remote];
  }

  Future<void> loadCategories({bool force = false}) async {
    try {
      _boards = [
        for (final board in await repository.rankingBoards())
          if (board.source == source.id) board,
      ];
    } catch (_) {}
    _remote = await repository.categories(source.id, force: force);
  }

  Future<RankingPage> ranking(
    RankingBoard board, {
    int page = 1,
    bool force = false,
  }) => repository.rankings(board, page: page, force: force);

  Future<CatalogPage> cached(
    CatalogCategory category,
  ) => repository.cached(source.id, category: category.id);

  Future<CatalogPage> fetch(
    CatalogCategory category, {
    int page = 1,
    String lane = '',
    bool force = false,
  }) => repository.catalog(
    source.id,
    category: category.id,
    page: page,
    lane: lane,
    force: force,
  );

  Future<CatalogPage> recommendations({
    bool more = false,
    bool force = false,
  }) => repository.recommendations(
    source.id,
    recommendGenre,
    more: more,
    force: force,
  );

  Future<CatalogPage> search(String query, {int page = 1}) async {
    final result = await repository.catalog(
      source.id,
      query: query,
      page: page,
    );
    return CatalogPage(
      result.items,
      hasMore: source.pagedSearch && result.hasMore,
      warning: result.warning,
      page: result.page,
      fresh: result.fresh,
    );
  }

}
