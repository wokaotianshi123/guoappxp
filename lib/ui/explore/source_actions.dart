import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../modules/modules_page.dart';
import '../search/search_page.dart';
import '../settings/sources_page.dart';
import '../shell/app_shell.dart';
import '../widgets/choice_panel.dart';

Future<void> pickSource(BuildContext anchor, LocalStore store) async {
  final sources = store.sources;
  // 站源菜单按类目分段（短剧类 / 视频类 / 黄果类 / 成人类 / 其他站源），
  // 与站源管理页同一口径；只有一个类目时不画分段标题，保持原来的扁平外观。
  final sections = SourceGroup.byClass(sources);
  // 分段显示的条件：有两个以上类目，或者本机加过自定义XBPQ 源——后者即使
  // 只剩这一组也要把「XBPQ」标出来，否则用户看不出自己加的源在哪儿。
  final grouped =
      sections.length > 1 ||
      sections.any((section) => section.id == SourceClass.xbpq);
  final value = await showChoicePanel<String>(
    context: anchor,
    title: '全部站源',
    options: [
      for (final source in sources) ChoiceOption(source.id, source.name),
    ],
    groups: grouped
        ? [
            for (final section in sections)
              ChoiceGroup(section.id, section.name, [
                for (final source in section.sources)
                  ChoiceOption(source.id, source.name),
              ]),
          ]
        : null,
    selected: store.source,
    grid: ChoiceGrid.sources,
    // 右上角两个入口：模块装的源去「自定义模块」管，自己加的源去「自定义XBPQ」管。
    actions: store.profile.admin
        ? [
            (
              label: '管理模块项',
              icon: Icons.extension_outlined,
              onPressed: () =>
                  openPage<void>(anchor, (_) => ModulesPage(store: store)),
            ),
            (
              label: '管理XBPQ',
              icon: Icons.dns_outlined,
              onPressed: () =>
                  openPage<void>(anchor, (_) => SourcesPage(store: store)),
            ),
          ]
        : const [],
  );
  if (value == null || value == store.source) return;
  try {
    await store.setSource(value);
  } catch (_) {
    if (!anchor.mounted) return;
    ScaffoldMessenger.maybeOf(anchor)
        ?.showSnackBar(const SnackBar(content: Text('未能切换站源，请重试')));
  }
}

Future<void> openSearch(
  BuildContext context,
  LocalStore store,
  SourceSite source, {
  String query = '',
}) => openPage<void>(
  context,
  (_) => SearchPage(store: store, source: source, query: query),
);
