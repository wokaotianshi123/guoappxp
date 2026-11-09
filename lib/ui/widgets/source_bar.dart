import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'bar_button.dart';
import 'page_header.dart';

class SourceBar extends StatelessWidget {
  const SourceBar({
    super.key,
    required this.source,
    required this.onSwitchSource,
    required this.onOpenSearch,
    this.televisionLeading,
    this.sourceFocusNode,
    this.searchFocusNode,
    this.actions = const [],
  });
  final String source;
  final void Function(BuildContext anchor) onSwitchSource;
  final VoidCallback onOpenSearch;
  final Widget? televisionLeading;

  /// 电视端顶栏两个按钮的焦点节点；宿主按顺序串起整行遥控器导航。
  final FocusNode? sourceFocusNode;
  final FocusNode? searchFocusNode;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final form = AppScope.formFactorOf(context);
    final hint = '在 $source 中搜索';
    final switcher = Builder(
      builder: (anchor) => BarButton(
        icon: Icons.public_rounded,
        tooltip: '切换站源',
        focusNode: sourceFocusNode,
        onPressed: () => onSwitchSource(anchor),
      ),
    );
    final search = BarButton(
      icon: Icons.search_rounded,
      tooltip: hint,
      focusNode: searchFocusNode,
      onPressed: onOpenSearch,
    );
    if (form == FormFactor.television) {
      return SizedBox(
        height: 48,
        child: Row(
          spacing: 10,
          children: [
            ?televisionLeading,
            const Spacer(),
            Text(
              source,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            switcher,
            search,
            ...actions,
          ],
        ),
      );
    }
    // 手机 / 平板 / Windows 窗口统一成同一套顶栏：标题 + 切换站源 + 搜索按钮。
    // 以前平板和窗口塞了一个常驻输入框，占宽又和两端不一致；现在点按钮才进搜索页，
    // 搜索页里再专注输入。
    return PageHeader(title: source, actions: [switcher, search, ...actions]);
  }
}
