import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../search/search_page.dart';
import '../settings/sources_page.dart';
import '../shell/app_shell.dart';
import '../widgets/choice_panel.dart';

Future<void> pickSource(BuildContext anchor, LocalStore store) async {
  final value = await showChoicePanel<String>(
    context: anchor,
    title: '全部站源',
    options: [
      for (final source in store.sources) ChoiceOption(source.id, source.name),
    ],
    selected: store.source,
    grid: ChoiceGrid.sources,
    action: store.profile.admin
        ? (
            label: '管理站源',
            icon: Icons.tune_rounded,
            // 站源页两个页签：站源与自定义源 / 模块。原来只跳模块页，
            // 自定义源的增删改在那边进不去。
            onPressed: () =>
                openPage<void>(anchor, (_) => SourcesPage(store: store)),
          )
        : null,
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
