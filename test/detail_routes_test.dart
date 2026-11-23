import 'package:duanju_app/drama_details.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/detail/detail_routes.dart';
import 'package:flutter_test/flutter_test.dart';

Episode _episode(int number, String title) =>
    Episode({'currentEpisode': number, 'title': title}, number);

void main() {
  test('没有「线路 · 集名」编码时不出线路', () {
    final episodes = [
      for (var number = 1; number <= 5; number++) _episode(number, '第$number集'),
    ];
    expect(extractDetailRoutes(episodes), isEmpty);
  });

  test('只有一条线路时不显示线路选择器', () {
    final episodes = [
      for (var number = 1; number <= 3; number++)
        _episode(number, '线路1 · 第$number集'),
    ];
    expect(extractDetailRoutes(episodes), isEmpty);
  });

  test('多线路按「线路名 · 集名」拆开，保留集顺序', () {
    final episodes = [
      _episode(1, '线路1 · 第1集'),
      _episode(2, '线路1 · 第2集'),
      _episode(3, '线路2 · 第1集'),
      _episode(4, '线路2 · 第2集'),
    ];
    final routes = extractDetailRoutes(episodes);
    expect(routes.map((route) => route.name), ['线路1', '线路2']);
    expect(routes[0].entries, hasLength(2));
    expect(routes[1].entries, hasLength(2));
    // 真实索引必须保留，否则点第 2 条线路会播到第 1 条。
    expect(routes[1].entries.first.index, 2);
    expect(routes[1].entries.first.label, '第1集');
  });

  test('网盘展开的线路保留原文件名', () {
    final episodes = [
      _episode(1, '夸克 · 我的剧 S01E01.mp4'),
      _episode(2, '夸克 · 我的剧 S01E02.mp4'),
      _episode(3, 'UC · 我的剧 S01E01.mp4'),
      _episode(4, 'UC · 我的剧 S01E02.mp4'),
    ];
    final routes = extractDetailRoutes(episodes);
    expect(routes.map((route) => route.name), ['夸克', 'UC']);
    expect(routes[0].entries.first.label, '我的剧 S01E01.mp4');
  });

  test('compactEpisodeLabel 把纯序号压成数字', () {
    expect(compactEpisodeLabel('第1集', 1), '1');
    expect(compactEpisodeLabel('3', 3), '3');
    expect(compactEpisodeLabel('', 5), '5');
    expect(compactEpisodeLabel('大结局', 9), '大结局');
  });

  test('resolveDetailEpisodeScope 换剧时落到当前播放集所在线路', () async {
    final drama = Drama(id: 'x:1', source: 'x', title: '剧');
    // 两条线路各 40 集，共 80 集；第 45 集属于线路2。
    final episodes = [
      for (var number = 1; number <= 40; number++) _episode(number, '线路1 · 第$number集'),
      for (var number = 41; number <= 80; number++)
        _episode(number, '线路2 · 第$number集'),
    ];
    final details = _FakeScopeDetails(drama, episodes, currentIndex: 45);

    final scope = resolveDetailEpisodeScope(
      details,
      routeDramaId: 'other',
      selectedRoute: '',
      routeGroup: 0,
    );
    expect(scope.routes, hasLength(2));
    expect(scope.routeName, '线路2');
    // 第 45 集是线路2 的第 5 集，应落在第 0 组。
    expect(scope.group, 0);
    expect(scope.entries.first.episode.number, 41);
  });
}

/// 只提供 resolveDetailEpisodeScope 需要的成员，避免构造完整 DramaDetails。
class _FakeScopeDetails implements DramaDetails {
  _FakeScopeDetails(this.drama, this.episodes, {required this.currentIndex});

  @override
  final Drama drama;
  @override
  final List<Episode> episodes;
  @override
  final int? currentIndex;
  @override
  int get group => 0;
  @override
  int get groupCount => (episodes.length / episodeGroupSize).ceil();
  @override
  List<Episode> get groupEpisodes =>
      episodes.take(episodeGroupSize).toList();
  @override
  List<Episode> episodesIn(int group) =>
      episodes.skip(group * episodeGroupSize).take(episodeGroupSize).toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
