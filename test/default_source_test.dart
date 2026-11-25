import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// 首页默认源：JS 沙箱的官方免费短剧（`js:hongguo`）。
///
/// 它与模块红果是同一套内容，但脚本在端侧跑，不依赖商店模块是否安装。
/// 这些断言锁住三件事：默认落在脚本源、老用户从模块红果一次性迁移、
/// 用户自己选过的源不被覆盖。
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

  test('老用户存的是模块红果时自动升到脚本版', () async {
    installJsOfficial();
    final store = await openStore();
    await store.setSource(hongguoSourceId);
    expect(store.source, jsOfficial);

    // 读取时已自动升级；启动流程里的显式迁移把持久化值也改掉，且只写一次。
    expect(await store.adoptJsDefaultSource(), isTrue);
    expect(await store.adoptJsDefaultSource(), isFalse);
    expect(store.source, jsOfficial);
  });

  test('用户自己选过别的源时保持原选择', () async {
    installJsOfficial();
    final store = await openStore();
    // 排除模块红果：它属于「老默认值」，本就该被迁移，不算用户主动选择。
    final other = store.sources.firstWhere(
      (site) => site.id != jsOfficial && site.id != hongguoSourceId,
    );
    await store.setSource(other.id);

    expect(await store.adoptJsDefaultSource(), isFalse);
    expect(store.source, other.id);
  });

  test('迁移只写一次：已经指向脚本源时不再写盘', () async {
    installJsOfficial();
    final store = await openStore();
    await store.setSource(jsOfficial);
    expect(await store.adoptJsDefaultSource(), isFalse);
    expect(store.source, jsOfficial);
  });

  test('脚本源被关掉时默认源退回模块红果', () async {
    installJsOfficial();
    final store = await openStore();
    await store.setSourceEnabled(jsOfficial, false);
    expect(store.source, hongguoSourceId);
  });
}
