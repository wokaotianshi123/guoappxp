import 'dart:async';

import 'package:duanju_app/magnet_models.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_loader.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/magnet/magnet_page.dart';
import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _magnet = 'magnet:?xt=urn:btih:$_hash';

class _MagnetRepository extends FakeRepository {
  final searches = <String>[];
  final fileRequests = <String>[];
  final playRequests = <String>[];
  final peerRequests = <List<String>>[];
  int cancelCalls = 0;
  int resolveCalls = 0;
  MagnetPeersInfo peersInfo = const MagnetPeersInfo();

  @override
  Future<List<MagnetSite>> magnetSites() async => const [
    MagnetSite(id: 10001, name: 'SOBT', info: '测试站一'),
    MagnetSite(id: 10002, name: '磁力猫', info: '测试站二'),
  ];

  @override
  Future<MagnetSearchPage> magnetSearch(
    String query, {
    int page = 1,
    List<int> sites = const [],
  }) async {
    searches.add('$query|$page|${sites.join(',')}');
    return MagnetSearchPage(
      items: const [
        MagnetResult(
          id: _hash,
          title: '三体 第一季',
          magnet: _magnet,
          size: '1.2 GB',
          date: '2026-11-08',
          site: 'SOBT',
          playable: true,
        ),
        MagnetResult(
          id: '',
          title: '未解析出链接',
          detail: 'https://a.test/detail/1',
          site: '磁力猫',
        ),
      ],
      sites: const [
        MagnetSite(id: 10001, name: 'SOBT'),
        MagnetSite(id: 10002, name: '磁力猫'),
      ],
      hasMore: true,
      page: page,
    );
  }

  // 设成非 null 时模拟「种子元数据解析失败」，用于验证不会直接进播放器。
  Object? fileError;

  @override
  Future<List<MagnetFile>> magnetFiles(String magnet) async {
    fileRequests.add(magnet);
    if (fileError != null) throw fileError!;
    return const [
      MagnetFile(index: 0, name: 'sample.mp4', size: 100, video: true),
      MagnetFile(index: 1, name: 'movie.mkv', size: 900, video: true),
    ];
  }

  @override
  Future<PlaybackPlan> magnetPlay(String magnet, {int fileIndex = -1}) async {
    playRequests.add('$magnet|$fileIndex');
    return const PlaybackPlan(
      url: 'http://127.0.0.1:1234/magnet/$_hash/0',
      local: true,
    );
  }

  @override
  Future<void> magnetCancel() async {
    cancelCalls++;
  }

  @override
  Future<MagnetPeersInfo> magnetPeers(
    List<String> hashes, {
    bool force = false,
  }) async {
    peerRequests.add(hashes);
    return peersInfo;
  }

  final browseRequests = <String>[];
  final categoryBrowseRequests = <String>[];
  final categorySites = <String>[];
  final removedSites = <int>[];
  final savedRules = <String>[];
  int resetCalls = 0;
  List<String> hotWords = [for (var i = 0; i < 20; i++) '热词$i'];
  // 分类由「站源」给出，测试里可改成空列表来验证没有分类时的回退。
  List<MagnetCategory> siteCategories = const [
    MagnetCategory(
      siteId: 10001,
      siteName: 'SOBT',
      name: '电影',
      url: 'https://sobt.test/list/1.html?page=1',
    ),
    MagnetCategory(
      siteId: 10001,
      siteName: 'SOBT',
      name: '剧集',
      url: 'https://sobt.test/list/2.html?page=1',
    ),
    MagnetCategory(
      siteId: 10002,
      siteName: '磁力猫',
      name: '动漫',
      url: 'https://cat.test/cate/3.html',
    ),
  ];

  @override
  Future<List<String>> magnetHotWords({bool refresh = false}) async => hotWords;

  @override
  Future<List<MagnetCategory>> magnetCategories({
    List<int> sites = const [],
    bool refresh = false,
  }) async {
    categorySites.add('${sites.join(',')}|$refresh');
    if (sites.isEmpty) return siteCategories;
    return siteCategories.where((item) => sites.contains(item.siteId)).toList();
  }

  @override
  Future<MagnetSearchPage> magnetBrowse(
    String query, {
    int page = 1,
    List<int> sites = const [],
    String categoryUrl = '',
    int categorySiteId = 0,
  }) async {
    browseRequests.add('$query|$page|${sites.join(',')}');
    categoryBrowseRequests.add('$categorySiteId|$categoryUrl');
    return MagnetSearchPage(
      items: const [
        MagnetResult(
          id: _hash,
          title: '分类列表影片',
          magnet: _magnet,
          size: '2.1 GB',
          date: '2026-11-09',
          site: 'SOBT',
          siteId: 10001,
          playable: true,
        ),
      ],
      page: page,
    );
  }

  @override
  Future<MagnetSiteAnalysis> analyzeMagnetSite(String base) async =>
      MagnetSiteAnalysis(
        rule:
            '{"name":"识别站点","mainUrl":"https://a.test",'
            '"searchUrl":"https://a.test/s?keyword=[keyword]&page=[page]",'
            '"expressionModel":{"group":"//li[contains(@class,\'item\')]",'
            '"title":".//a[1]"}}',
        name: '识别站点',
        base: 'https://a.test',
        notes: const ['已从搜索表单识别出关键词参数 keyword'],
      );

  @override
  Future<MagnetSite> addMagnetSite({
    required String name,
    required String base,
    required String rule,
  }) async {
    savedRules.add(rule);
    return MagnetSite(id: 900001, name: name, mainUrl: base, custom: true);
  }

  @override
  Future<MagnetSite> updateMagnetSite(
    int id, {
    required String name,
    required String rule,
    bool? state,
  }) async {
    savedRules.add(rule);
    return MagnetSite(id: id, name: name, custom: true);
  }

  @override
  Future<void> removeMagnetSite(int id) async => removedSites.add(id);

  @override
  Future<int> resetMagnetSites() async {
    resetCalls++;
    return 0;
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool adBlock = true,
    int route = 0,
  }) async {
    resolveCalls++;
    return const PlaybackPlan(url: 'https://example.com/video.m3u8');
  }
}

const _hashB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _magnetB = 'magnet:?xt=urn:btih:$_hashB';

/// 第一条磁力故意一直挂着不返回，用来验证用户点第二条时旧任务被立刻放弃。
class _SwitchingRepository extends FakeRepository {
  final fileRequests = <String>[];
  int cancelCalls = 0;
  final _first = Completer<List<MagnetFile>>();

  @override
  Future<List<MagnetSite>> magnetSites() async => const [
    MagnetSite(id: 10001, name: 'SOBT'),
    MagnetSite(id: 10002, name: '磁力猫'),
  ];

  @override
  Future<MagnetSearchPage> magnetSearch(
    String query, {
    int page = 1,
    List<int> sites = const [],
  }) async => MagnetSearchPage(
    items: [
      MagnetResult(
        id: _hash,
        title: '第一条',
        magnet: _magnet,
        site: 'SOBT',
        siteId: 10001,
        playable: true,
      ),
      MagnetResult(
        id: _hashB,
        title: '第二条',
        magnet: _magnetB,
        site: '磁力猫',
        siteId: 10002,
        playable: true,
      ),
    ],
  );

  @override
  Future<void> magnetCancel() async {
    cancelCalls++;
  }

  @override
  Future<List<MagnetFile>> magnetFiles(String magnet) {
    fileRequests.add(magnet);
    if (magnet == _magnet) return _first.future;
    return Future.value(const [
      MagnetFile(index: 0, name: 'second-a.mkv', size: 10, video: true),
      MagnetFile(index: 1, name: 'second-b.mkv', size: 20, video: true),
    ]);
  }

  void finishFirst() {
    if (!_first.isCompleted) {
      _first.complete(const [
        MagnetFile(index: 0, name: 'first-a.mkv', size: 10, video: true),
        MagnetFile(index: 1, name: 'first-b.mkv', size: 20, video: true),
      ]);
    }
  }
}

Future<void> _pumpMagnetPage(
  WidgetTester tester,
  FakeRepository repository,
) async {
  final store = await openStore();
  await tester.pumpWidget(
    AppScope(
      repository: repository,
      child: MaterialApp(home: MagnetPage(store: store)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('主页四个标签并列，原有三项索引不变', () {
    expect(AppTab.values.map((tab) => tab.label), ['发现', '追剧', '我的', '磁力']);
    expect(AppTab.explore.index, 0);
    expect(AppTab.follow.index, 1);
    expect(AppTab.mine.index, 2);
    expect(AppTab.magnet.index, 3);
  });

  test('磁力数据模型按 Go 侧 JSON 解析', () {
    final page = MagnetSearchPage.fromJson({
      'items': [
        {
          'id': _hash,
          'title': '资源一',
          'magnet': _magnet,
          'playable': true,
          'size': 1234,
          'sizeBytes': 1234,
          'timestamp': 1762540800,
          'siteId': 10001,
        },
        {'title': '资源二', 'playable': true},
      ],
      'sites': [
        {'id': 10001, 'name': 'SOBT', 'state': true},
        {'id': 10002, 'name': '磁力猫', 'state': false},
      ],
      'hasMore': true,
      'page': 2,
      'warning': '部分站源超时',
    });
    expect(page.items, hasLength(2));
    expect(page.items.first.playable, isTrue);
    // 没解析出磁力链接时，即使 Go 侧给了 playable 也不能点播。
    expect(page.items.last.playable, isFalse);
    expect(page.items.first.size, '1234');
    expect(page.items.first.sizeBytes, 1234);
    expect(page.items.first.timestamp, 1762540800);
    expect(page.items.first.siteId, 10001);
    expect(page.sites.last.state, isFalse);
    expect(page.hasMore, isTrue);
    expect(page.page, 2);
    expect(page.warning, '部分站源超时');

    final file = MagnetFile.fromJson({
      'index': 3,
      'name': 'movie.mkv',
      'size': 900.0,
      'video': true,
    });
    expect(file.index, 3);
    expect(file.size, 900);
    expect(file.video, isTrue);
  });

  test('按站源分组、独立筛选与按 DHT / 时间 / 大小排序', () {
    final items = [
      MagnetResult(
        id: 'a',
        title: '小且旧',
        magnet: 'magnet:?xt=urn:btih:a',
        playable: true,
        site: 'SOBT',
        siteId: 10001,
        size: '100 MB',
        sizeBytes: 100 << 20,
        date: '2026-01-01',
        timestamp: 100,
        dht: 2,
        peers: 5,
        dhtProbed: true,
      ),
      MagnetResult(
        id: 'b',
        title: '大且新',
        magnet: 'magnet:?xt=urn:btih:b',
        playable: true,
        site: 'SOBT',
        siteId: 10001,
        size: '2 GB',
        sizeBytes: 2 << 30,
        date: '2026-11-08',
        timestamp: 900,
        dht: 30,
        peers: 40,
        dhtProbed: true,
      ),
      const MagnetResult(id: 'c', title: '没磁力', site: '磁力猫', siteId: 10002),
    ];
    final groups = magnetSiteGroups(items);
    expect(groups.map((group) => group.name), ['SOBT', '磁力猫']);
    expect(groups.first.items, hasLength(2));
    expect(magnetFilterResults(items).map((item) => item.id), ['a', 'b', 'c']);
    expect(magnetFilterResults(items, sort: MagnetSort.size).first.id, 'b');
    expect(magnetFilterResults(items, sort: MagnetSort.date).first.id, 'b');
    expect(magnetFilterResults(items, sort: MagnetSort.dht).first.id, 'b');
    expect(
      magnetFilterResults(items, onlyMagnet: true).map((item) => item.id),
      ['a', 'b'],
    );
    // 站源 id 缺失时退化为按名字分组，不会把两个站混成一个标签。
    expect(
      magnetSiteGroups(const [
        MagnetResult(id: 'x', title: 'x', site: '甲'),
        MagnetResult(id: 'y', title: 'y', site: '乙'),
      ]),
      hasLength(2),
    );
  });

  test('DHT 探测结果能解析并回填到搜索结果', () {
    final info = MagnetPeersInfo.fromJson({
      'items': [
        {'hash': _hash, 'dht': 12, 'peers': 30, 'connected': 3},
      ],
      'dhtNodes': 256,
      'probing': 1,
    });
    expect(info.items.single.dht, 12);
    expect(info.items.single.peers, 30);
    expect(info.dhtNodes, 256);
    final updated = const MagnetResult(
      id: 'x',
      title: 'x',
    ).copyWith(dht: 12, peers: 30, dhtProbed: true);
    expect(updated.dhtProbed, isTrue);
    expect(updated.dht, 12);
    expect(updated.peers, 30);
  });

  test('分集带 magnet 时 PlaybackLoader 直接走磁力播放', () async {
    final repository = _MagnetRepository();
    final loader = PlaybackLoader(repository);
    final item = drama('m1', source: 'magnet');
    final episode = Episode({
      'id': 'magnet:$_hash:2',
      'title': 'movie.mkv',
      'currentEpisode': 3,
      'magnet': _magnet,
      'fileIndex': 2,
    }, 3);

    final plan = await loader.load(item, episode);

    expect(plan?.url, 'http://127.0.0.1:1234/magnet/$_hash/0');
    expect(plan?.local, isTrue);
    expect(repository.playRequests, ['$_magnet|2']);
    expect(repository.resolveCalls, 0, reason: '磁力分集不该再走站源取流');

    await loader.load(item, Episode({'currentEpisode': 1}, 1));
    expect(repository.resolveCalls, 1);
    expect(repository.playRequests, hasLength(1));
    await loader.close();
  });

  testWidgets('磁力页能选站源、搜索并列出结果', (tester) async {
    final repository = _MagnetRepository();
    await _pumpMagnetPage(tester, repository);

    expect(find.text('站源 2/2'), findsOneWidget);
    expect(find.text('输入关键词，搜索 35 个磁力站源'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '三体');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    expect(repository.searches, ['三体|1|10001,10002']);
    expect(find.text('三体 第一季'), findsOneWidget);
    expect(find.text('未解析出链接'), findsOneWidget);
    expect(find.textContaining('共 2 条'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget);

    await tester.tap(find.text('站源 2/2'));
    await tester.pumpAndSettle();
    expect(find.text('选择站源'), findsOneWidget);
    // 结果列表的副标题可能恰好也是站源名，所以用 BottomSheet 限定查找范围。
    Finder inSitePicker(Finder finder) =>
        find.descendant(of: find.byType(BottomSheet), matching: finder);
    expect(inSitePicker(find.text('SOBT')), findsOneWidget);
    expect(inSitePicker(find.text('磁力猫')), findsOneWidget);
    Navigator.of(tester.element(find.text('选择站源'))).pop(<int>{10001});
    await tester.pumpAndSettle();
    expect(find.text('站源 1/2'), findsOneWidget);
  });

  testWidgets('点播磁力结果会列出种子内文件供选集', (tester) async {
    final repository = _MagnetRepository();
    await _pumpMagnetPage(tester, repository);

    await tester.enterText(find.byType(TextField), '三体');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('播放'), findsOneWidget);
    expect(find.byTooltip('未解析出磁力链接'), findsOneWidget);
    await tester.tap(find.byTooltip('播放'));
    await tester.pumpAndSettle();

    expect(repository.fileRequests, [_magnet]);
    expect(find.text('选择要播放的文件'), findsOneWidget);
    expect(find.text('sample.mp4'), findsOneWidget);
    expect(find.text('movie.mkv'), findsOneWidget);
  });

  testWidgets('点另一条磁力立即取消上一条，旧结果不会覆盖新任务', (tester) async {
    final repository = _SwitchingRepository();
    await _pumpMagnetPage(tester, repository);

    await tester.enterText(find.byType(TextField), '三体');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('播放'), findsNWidgets(2));

    await tester.tap(find.byTooltip('播放').first);
    await tester.pump();
    await tester.pump();
    expect(repository.cancelCalls, 1);
    expect(repository.fileRequests, [_magnet]);

    // 第一条还挂在 DHT 上时点第二条，不应再被 _preparing 挡住。
    await tester.tap(find.byTooltip('播放').last);
    await tester.pumpAndSettle();
    expect(repository.cancelCalls, 2);
    expect(repository.fileRequests, [_magnet, _magnetB]);
    expect(find.text('选择要播放的文件'), findsOneWidget);
    expect(find.text('second-a.mkv'), findsOneWidget);

    // 旧请求最终返回也必须被丢弃，不能把新任务的文件列表顶掉。
    repository.finishFirst();
    await tester.pumpAndSettle();
    expect(find.text('first-a.mkv'), findsNothing);
    expect(find.text('second-a.mkv'), findsOneWidget);
  });

  testWidgets('站源标签可切换，且每个标签独立筛选', (tester) async {
    final repository = _MagnetRepository();
    repository.peersInfo = MagnetPeersInfo.fromJson({
      'items': [
        {'hash': _hash, 'dht': 18, 'peers': 26, 'connected': 2},
      ],
      'dhtNodes': 128,
    });
    await _pumpMagnetPage(tester, repository);

    await tester.enterText(find.byType(TextField), '三体');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    expect(find.textContaining('全部 2'), findsOneWidget);
    expect(find.textContaining('SOBT 1'), findsOneWidget);
    expect(repository.peerRequests, hasLength(1));
    // DHT 节点数回填后显示在结果副标题里。
    expect(find.textContaining('DHT 18'), findsOneWidget);

    await tester.tap(find.textContaining('磁力猫 1'));
    await tester.pumpAndSettle();
    expect(find.text('未解析出链接'), findsOneWidget);
    expect(find.text('三体 第一季'), findsNothing);

    // 「仅含磁力」只作用于当前标签。
    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    expect(find.text('未解析出链接'), findsNothing);

    await tester.tap(find.textContaining('全部 2'));
    await tester.pumpAndSettle();
    // 切回「全部」后它自己的筛选仍是默认，两条结果都还在。
    expect(find.text('三体 第一季'), findsOneWidget);
    expect(find.text('未解析出链接'), findsOneWidget);
  });

  testWidgets('磁力页顶部横向排列三个标签', (tester) async {
    await _pumpMagnetPage(tester, _MagnetRepository());
    expect(find.text('磁力搜索'), findsOneWidget);
    expect(find.text('磁力播放'), findsOneWidget);
    expect(find.text('磁力源管理'), findsOneWidget);
    final first = tester.getTopLeft(find.text('磁力搜索'));
    final second = tester.getTopLeft(find.text('磁力播放'));
    final third = tester.getTopLeft(find.text('磁力源管理'));
    expect(first.dx, lessThan(second.dx));
    expect(second.dx, lessThan(third.dx));
    // 三个标签同一行，纵向不堆叠。
    expect(first.dy, equals(second.dy));
    expect(second.dy, equals(third.dy));
  });

  testWidgets('磁力搜索标签展示热词，行高受限且点击即搜索', (tester) async {
    final repository = _MagnetRepository();
    await _pumpMagnetPage(tester, repository);
    expect(find.text('热词0'), findsOneWidget);
    // 热词整行固定 34px，不会把结果区挤掉。
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SizedBox && widget.height == 34,
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('热词0'));
    await tester.pumpAndSettle();
    expect(repository.searches.first, startsWith('热词0|1|'));
    expect(find.textContaining('「热词0」共'), findsOneWidget);
  });

  testWidgets('磁力播放标签：分类列表无封面、链接校验', (tester) async {
    final repository = _MagnetRepository();
    await _pumpMagnetPage(tester, repository);
    await tester.tap(find.text('磁力播放'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, '播放'), findsOneWidget);
    // 站源行仍是「全部 + 两个站源」；分类行另有一个「全部」默认项。
    expect(find.widgetWithText(FilterChip, '全部'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '全部'), findsOneWidget);
    expect(find.text('SOBT'), findsOneWidget);
    expect(repository.browseRequests, isNotEmpty);
    expect(find.text('分类列表影片'), findsOneWidget);
    final tile = tester.widget<ListTile>(
      find
          .ancestor(of: find.text('分类列表影片'), matching: find.byType(ListTile))
          .first,
    );
    expect(tile.leading, isNull, reason: '按需求列表项不设封面');

    final input = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          (widget.decoration?.hintText ?? '').contains('magnet:'),
    );
    expect(input, findsOneWidget);
    await tester.enterText(input, 'not-a-magnet');
    await tester.tap(find.widgetWithText(FilledButton, '播放'));
    await tester.pumpAndSettle();
    expect(find.text('请粘贴以 magnet: 开头的磁力链接'), findsOneWidget);
  });

  testWidgets('磁力源管理：自动识别回填规则后保存，并支持删除', (tester) async {
    final repository = _MagnetRepository();
    await _pumpMagnetPage(tester, repository);
    await tester.tap(find.text('磁力源管理'));
    await tester.pumpAndSettle();

    expect(find.textContaining('共 2 个磁力源'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '新增'));
    await tester.pumpAndSettle();

    TextField field(String label) => tester.widget<TextField>(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is TextField && widget.decoration?.labelText == label,
          )
          .first,
    );
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '源网址',
      ),
      'https://a.test',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '自动识别磁力源'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已按站点 HTML 生成磁力源规则'), findsOneWidget);
    expect(field('磁力源规则 JSON').controller?.text, contains('mainUrl'));
    expect(field('源名称').controller?.text, '识别站点');

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(repository.savedRules, hasLength(1));
    expect(repository.savedRules.single, contains('expressionModel'));

    await tester.tap(find.byTooltip('删除').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(repository.removedSites, contains(10001));
  });

  testWidgets('磁力播放标签：粘贴链接和列表项都先解析再加载播放器', (tester) async {
    final repository = _MagnetRepository();
    await _pumpMagnetPage(tester, repository);
    await tester.tap(find.text('磁力播放'));
    await tester.pumpAndSettle();

    final input = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          (widget.decoration?.hintText ?? '').contains('magnet:'),
    );
    await tester.enterText(input, _magnet);
    await tester.tap(find.widgetWithText(FilledButton, '播放'));
    await tester.pumpAndSettle();

    // 与磁力搜索一致：先取消旧任务、解析种子内文件列表，再让用户选集，
    // 而不是把裸磁力链接直接丢给播放器。
    expect(repository.cancelCalls, 1);
    expect(repository.fileRequests, [_magnet]);
    expect(repository.playRequests, isEmpty);
    expect(find.text('选择要播放的文件'), findsOneWidget);

    Navigator.of(tester.element(find.text('选择要播放的文件'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('选择要播放的文件'), findsNothing);

    await tester.tap(find.byTooltip('播放'));
    await tester.pumpAndSettle();
    expect(repository.cancelCalls, 2);
    expect(repository.fileRequests, [_magnet, _magnet]);
    expect(find.text('选择要播放的文件'), findsOneWidget);
  });

  testWidgets('磁力播放标签：解析失败时不进播放器并给出提示', (tester) async {
    final repository = _MagnetRepository()..fileError = StateError('DHT 超时');
    await _pumpMagnetPage(tester, repository);
    await tester.tap(find.text('磁力播放'));
    await tester.pumpAndSettle();

    final input = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          (widget.decoration?.hintText ?? '').contains('magnet:'),
    );
    await tester.enterText(input, _magnet);
    await tester.tap(find.widgetWithText(FilledButton, '播放'));
    await tester.pumpAndSettle();

    expect(repository.fileRequests, [_magnet]);
    expect(repository.playRequests, isEmpty, reason: '解析失败不应加载播放器');
    expect(find.textContaining('磁力解析失败'), findsOneWidget);
    // loading 态已复位，按钮可以直接重试。
    expect(find.widgetWithText(FilledButton, '播放'), findsOneWidget);
  });

  testWidgets('磁力播放分类来自站源实际导航，点分类按真实地址浏览', (tester) async {
    final repository = _MagnetRepository();
    await _pumpMagnetPage(tester, repository);
    await tester.tap(find.text('磁力播放'));
    await tester.pumpAndSettle();

    // 「全部站源」下分类带站名，且不再出现写死的分类词表。
    expect(find.widgetWithText(ChoiceChip, 'SOBT·电影'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '磁力猫·动漫'), findsOneWidget);
    expect(find.text('最新'), findsNothing);
    expect(repository.categorySites, isNotEmpty);

    await tester.tap(find.widgetWithText(ChoiceChip, 'SOBT·电影'));
    await tester.pumpAndSettle();
    expect(
      repository.categoryBrowseRequests.last,
      '10001|https://sobt.test/list/1.html?page=1',
    );
    expect(repository.browseRequests.last, '|1|10001');

    // 切到另一个源后，分类行只显示该源自己的分类。
    await tester.tap(find.widgetWithText(FilterChip, '磁力猫'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, '动漫'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'SOBT·电影'), findsNothing);
    expect(find.text('电影'), findsNothing);
    expect(repository.categorySites.last, startsWith('10002|'));
  });

  testWidgets('磁力源没有分类时回退全部，列表照常显示', (tester) async {
    final repository = _MagnetRepository()..siteCategories = const [];
    await _pumpMagnetPage(tester, repository);
    await tester.tap(find.text('磁力播放'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ChoiceChip, '全部'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsOneWidget, reason: '只保留「全部」');
    expect(find.text('分类列表影片'), findsOneWidget);
    expect(repository.browseRequests, isNotEmpty);
    expect(repository.categoryBrowseRequests.last, '0|');
  });
}
