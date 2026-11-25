import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// 首页默认源：JS 沙箱的官方免费短剧（`js:hongguo`）。
///
/// 模块红果（`hongguo`）与它内容同源，但对用户是两个独立站源：默认值只在
/// 「还没选过」时生效，一旦选了其中任何一个就停在那个上，绝不互相顶替。
void main() {
  const jsOfficial = 'js:hongguo';

  /// 装上脚本源：`SourceSite.installJs` 之后 `sources` 才会包含它。
  void installJsOfficial() => SourceSite.installJs([
    const SourceSite(
      jsOfficial,
      '官方免费短剧',
      '',
      available: true,
      pagedSearch: true,
      searchSuggestions: true,
      recommends: true,
      danmaku: true,
      vipPrompt: false,
    ),
  ]);

  tearDown(() => SourceSite.installJs(const []));

  test('没选过站源时默认落在 JS 沙箱的官方免费短剧', () async {
    installJsOfficial();
    final store = await openStore();
    expect(store.source, jsOfficial);
  });

  test('脚本源还没导入时退回模块红果', () async {
    SourceSite.installJs(const []);
    final store = await openStore();
    expect(store.source, hongguoSourceId);
  });

  test('选了模块红果就停在模块红果，不被改写成脚本源', () async {
    installJsOfficial();
    final store = await openStore();
    expect(store.sources.map((site) => site.id), contains(hongguoSourceId));

    await store.setSource(hongguoSourceId);
    expect(store.source, hongguoSourceId);

    // 再选回脚本源也要停在脚本源，两边互不影响。
    await store.setSource(jsOfficial);
    expect(store.source, jsOfficial);
  });

  test('用户自己选过别的源时保持原选择', () async {
    installJsOfficial();
    final store = await openStore();
    final other = store.sources.firstWhere(
      (site) => site.id != jsOfficial && site.id != hongguoSourceId,
    );
    await store.setSource(other.id);
    expect(store.source, other.id);
  });

  test('脚本源被关掉时默认源退回模块红果', () async {
    installJsOfficial();
    final store = await openStore();
    await store.setSourceEnabled(jsOfficial, false);
    expect(store.source, hongguoSourceId);
  });
}
