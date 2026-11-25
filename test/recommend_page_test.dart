import 'package:duanju_app/models.dart';
import 'package:duanju_app/recommend/recommend_feed.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/recommend/recommend_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// 推荐页的渲染冒烟测试。
///
/// 注意：这里**不能**测「详情就绪后进入播放器」的分支——那会构造
/// media_kit 的 Player，而 widget 测试环境没有原生解码器
/// （会报 `MediaKit.ensureInitialized must be called`）。
/// 播放器分支靠 recommend_feed_test 里的数据层测试 + 实机验证。
///
/// 能测的是：空状态、封面占位、布局不异常。这类问题一旦出现会让整块
/// 内容被丢弃（界面只剩黑屏），单元测试完全发现不了。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required Size size,
    FormFactor form = FormFactor.phone,
    String source = '',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = await openStore();
    if (source.isNotEmpty) await store.setSource(source);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          repository: _FeedRepository(),
          formFactor: form,
          child: RecommendPage(store: store),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('没有任何站源可用时给出明确提示，而不是黑屏', (tester) async {
    // 清空全部站源，模拟「一个源都没有」的极端情况。
    SourceSite.install(const []);
    SourceSite.installJs(const []);
    addTearDown(() => SourceSite.install(const []));

    await pump(tester, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(find.text('还没有选择站源'), findsOneWidget);
  });

  testWidgets('手机竖屏下推荐页布局正常', (tester) async {
    await pump(tester, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏下推荐页布局正常', (tester) async {
    await pump(
      tester,
      size: const Size(1600, 1000),
      form: FormFactor.window,
    );
    expect(tester.takeException(), isNull);
  });

  // 「有站源 + 详情就绪 → 进播放器」这条分支不在这里测：
  // * 构造 media_kit Player 需要原生解码器，widget 测试环境没有；
  // * 封面占位会发起真实网络请求（SocketException）。
  // 数据层由 recommend_feed_test 覆盖，播放器分支靠实机验证。
}

/// 固定返回两部推荐的假仓库；detail 故意留空，让页面停在封面占位分支。
class _FeedRepository extends FakeRepository {
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String lane = '',
    bool force = false,
  }) async => CatalogPage(
    [
      drama('a', title: '推荐甲'),
      drama('b', title: '推荐乙'),
    ],
    page: 1,
    hasMore: false,
  );
}
