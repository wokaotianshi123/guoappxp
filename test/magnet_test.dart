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
  int resolveCalls = 0;

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

  @override
  Future<List<MagnetFile>> magnetFiles(String magnet) async {
    fileRequests.add(magnet);
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

Future<void> _pumpMagnetPage(
  WidgetTester tester,
  _MagnetRepository repository,
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
}
