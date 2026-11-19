import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'focus_ring.dart';

class ChoiceOption<T> {
  const ChoiceOption(this.value, this.label);
  final T value;
  final String label;
}

/// 分组选项：站源菜单按类目分段时用，[options] 在组内按原顺序排。
/// 只给一个组时组标题不画，视觉上与不分段一致。
class ChoiceGroup<T> {
  const ChoiceGroup(this.id, this.label, this.options);
  final String id;
  final String label;
  final List<ChoiceOption<T>> options;
}

class ChoiceGrid {
  const ChoiceGrid({
    required this.phone,
    required this.wide,
    required this.television,
    required this.wideWidth,
    required this.televisionWidth,
  });
  final int phone;
  final int wide;
  final int television;
  final double wideWidth;
  final double televisionWidth;

  static const sources = ChoiceGrid(
    phone: 3,
    wide: 3,
    television: 2,
    wideWidth: 420,
    televisionWidth: 400,
  );
  static const categories = ChoiceGrid(
    phone: 4,
    wide: 5,
    television: 4,
    wideWidth: 520,
    televisionWidth: 440,
  );
}

typedef ChoiceAction = ({String label, IconData icon, VoidCallback onPressed});

Future<T?> showChoicePanel<T>({
  required BuildContext context,
  required String title,
  required List<ChoiceOption<T>> options,
  required T? selected,
  required ChoiceGrid grid,
  List<ChoiceGroup<T>>? groups,
  ChoiceAction? action,
}) {
  final form = AppScope.formFactorOf(context);
  Widget panel(BuildContext context) => _ChoicePanel<T>(
    form: form,
    title: title,
    options: options,
    groups: groups,
    selected: selected,
    columns: switch (form) {
      FormFactor.phone => grid.phone,
      FormFactor.pad || FormFactor.window => grid.wide,
      FormFactor.television => grid.television,
    },
    action: action,
  );
  switch (form) {
    case FormFactor.phone:
      return showModalBottomSheet<T>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        constraints: const BoxConstraints(maxHeight: 640),
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
        builder: panel,
      );
    case FormFactor.pad || FormFactor.window:
      return showAnchoredPanel<T>(
        context: context,
        width: grid.wideWidth,
        builder: panel,
      );
    case FormFactor.television:
      return showGeneralDialog<T>(
        context: context,
        barrierDismissible: true,
        barrierLabel: MaterialLocalizations.of(
          context,
        ).modalBarrierDismissLabel,
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, _, _) => Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            elevation: 8,
            child: SizedBox(
              width: grid.televisionWidth,
              height: double.infinity,
              child: panel(context),
            ),
          ),
        ),
        transitionBuilder: (_, animation, _, child) => SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          ),
          child: child,
        ),
      );
  }
}

Future<T?> showAnchoredPanel<T>({
  required BuildContext context,
  required double width,
  required WidgetBuilder builder,
}) {
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final anchor = context.findRenderObject()! as RenderBox;
  return navigator.push(
    _AnchoredRoute<T>(
      anchor:
          anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size,
      width: width,
      builder: builder,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

class _ChoicePanel<T> extends StatelessWidget {
  const _ChoicePanel({
    required this.form,
    required this.title,
    required this.options,
    required this.selected,
    required this.columns,
    required this.action,
    this.groups,
  });
  final FormFactor form;
  final String title;
  final List<ChoiceOption<T>> options;

  /// 分段展示的选项（站源菜单按类目分段时传入）；为空时用扁平的 [options]。
  final List<ChoiceGroup<T>>? groups;
  final T? selected;
  final int columns;
  final ChoiceAction? action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final television = form == FormFactor.television;
    final spacing = television ? 12.0 : 8.0;
    final header = Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: (television ? text.headlineSmall : text.titleLarge)
                    ?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontSize: television || form == FormFactor.phone
                          ? null
                          : 17,
                    ),
              ),
              Text(
                '${_total()} 个',
                style: (television ? text.bodyMedium : text.bodySmall)
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        // 附加操作放在右上角（原来在面板底部，手机上正好压在系统返回手势 /
        // 导航条上方，容易误触），手机只显示图标，其余形态带上文字。
        if (action case final action?)
          FocusRing(
            radius: 999,
            child: form == FormFactor.phone
                ? IconButton(
                    tooltip: action.label,
                    onPressed: () {
                      Navigator.pop(context);
                      action.onPressed();
                    },
                    icon: Icon(action.icon),
                  )
                : TextButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      action.onPressed();
                    },
                    icon: Icon(action.icon, size: 18),
                    label: Text(action.label),
                  ),
          ),
        if (form == FormFactor.phone)
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
          ),
      ],
    );
    return Padding(
      padding: switch (form) {
        FormFactor.phone => const EdgeInsets.fromLTRB(16, 0, 4, 20),
        FormFactor.pad ||
        FormFactor.window => const EdgeInsets.fromLTRB(16, 12, 16, 12),
        FormFactor.television => const EdgeInsets.fromLTRB(32, 36, 48, 32),
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          SizedBox(height: television ? 20 : 12),
          Flexible(
            child: Padding(
              padding: EdgeInsets.only(
                right: form == FormFactor.phone ? 12 : 0,
              ),
              child: _body(context, spacing, television),
            ),
          ),
        ],
      ),
    );
  }

  int _total() {
    final sections = groups;
    if (sections == null) return options.length;
    return sections.fold<int>(0, (sum, group) => sum + group.options.length);
  }

  Widget _body(BuildContext context, double spacing, bool television) {
    final sections = groups;
    if (sections == null || sections.isEmpty) {
      return _grid(options, spacing, television);
    }
    // 只有一个类目时不画标题，外观与原来的扁平网格一致。
    final headers = sections.length > 1;
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: EdgeInsets.all(television ? 12 : 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, group) in sections.indexed) ...[
            if (index > 0) SizedBox(height: television ? 18 : 14),
            if (headers)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Row(
                  spacing: 6,
                  children: [
                    Text(
                      group.label,
                      style: (television
                              ? text.titleSmall
                              : text.labelLarge)
                          ?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                    Text(
                      '${group.options.length}',
                      style: text.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            _grid(
              group.options,
              spacing,
              television,
              padding: EdgeInsets.zero,
              shrink: true,
            ),
          ],
        ],
      ),
    );
  }

  Widget _grid(
    List<ChoiceOption<T>> items,
    double spacing,
    bool television, {
    EdgeInsets? padding,
    bool shrink = false,
  }) => GridView.builder(
    shrinkWrap: true,
    // 分段时每组网格自己不滚，滚动交给外层；扁平形态仍由网格自己滚。
    physics: shrink ? const NeverScrollableScrollPhysics() : null,
    padding: padding ?? EdgeInsets.all(television ? 12 : 6),
    itemCount: items.length,
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      mainAxisSpacing: spacing,
      crossAxisSpacing: spacing,
      mainAxisExtent: switch (form) {
        FormFactor.phone => 44,
        FormFactor.pad || FormFactor.window => 36,
        FormFactor.television => 48,
      },
    ),
    itemBuilder: (context, index) => _ChoiceCell<T>(
      option: items[index],
      selected: items[index].value == selected,
      form: form,
    ),
  );
}

class _ChoiceCell<T> extends StatelessWidget {
  const _ChoiceCell({
    required this.option,
    required this.selected,
    required this.form,
  });
  final ChoiceOption<T> option;
  final bool selected;
  final FormFactor form;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = switch (form) {
      FormFactor.phone => 12.0,
      FormFactor.pad || FormFactor.window => 10.0,
      FormFactor.television => 14.0,
    };
    return FocusRing(
      radius: radius,
      child: Material(
        color: selected ? colors.secondaryContainer : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: selected
              ? BorderSide.none
              : BorderSide(color: colors.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          autofocus: selected,
          focusColor: Colors.transparent,
          onTap: () => Navigator.pop(context, option.value),
          child: Semantics(
            selected: selected,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  option.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: form == FormFactor.television ? 15 : 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? colors.onSecondaryContainer
                        : colors.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AnchoredRoute<T> extends PopupRoute<T> {
  _AnchoredRoute({
    required this.anchor,
    required this.width,
    required this.builder,
    required this.barrierLabel,
  });
  final Rect anchor;
  final double width;
  final WidgetBuilder builder;
  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildPage(BuildContext context, _, _) {
    final colors = Theme.of(context).colorScheme;
    return CustomSingleChildLayout(
      delegate: _AnchoredLayout(anchor, width),
      child: Material(
        color: colors.surfaceContainerHigh,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: builder(context),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    _,
    Widget child,
  ) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
    child: child,
  );
}

class _AnchoredLayout extends SingleChildLayoutDelegate {
  const _AnchoredLayout(this.anchor, this.width);
  final Rect anchor;
  final double width;
  static const _margin = 16.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final top = anchor.bottom + 6;
    return BoxConstraints(
      maxWidth: math.min(width, constraints.maxWidth - _margin * 2),
      minWidth: math.min(width, constraints.maxWidth - _margin * 2),
      maxHeight: math.max(0, constraints.maxHeight - top - _margin),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    (anchor.right - childSize.width).clamp(
      _margin,
      math.max(_margin, size.width - childSize.width - _margin),
    ),
    anchor.bottom + 6,
  );

  @override
  bool shouldRelayout(_AnchoredLayout oldDelegate) =>
      anchor != oldDelegate.anchor || width != oldDelegate.width;
}
