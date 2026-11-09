import 'package:flutter/material.dart';

/// 标签行的视觉风格：站源 / 结果标签用标准筛选胶囊，热词用轻量圆角胶囊。
enum MagnetChipStyle { filter, pill }

/// [MagnetChipFlow] 里的一项。
class MagnetChipItem {
  const MagnetChipItem({
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
}

/// 按可用宽度自动换行排列标签，最多 [maxLines] 行，放不下的收进「更多」菜单。
///
/// 原来这些行都是横向 ListView：窗口一窄就有一半标签要靠横滑才看得到，
/// 用户会以为「没显示出来」。改成按窗口宽度分行——宽屏一行放得更多，窄屏
/// 自动多行；两行仍放不下时才折叠，「更多」里点一下直接切换，不用先滚动再找。
/// 被折叠的正好是当前选中项时，「更多」按钮直接显示该项名称并高亮，不至于
/// 让人以为选择丢了。
class MagnetChipFlow extends StatelessWidget {
  const MagnetChipFlow({
    super.key,
    required this.items,
    this.style = MagnetChipStyle.filter,
    this.maxLines = 2,
    this.trailing = const <Widget>[],
  });

  final List<MagnetChipItem> items;
  final MagnetChipStyle style;
  final int maxLines;

  /// 跟在标签流末尾的控件（刷新按钮、筛选开关等），与标签一起换行。
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && trailing.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        // 宽度未知（例如放在水平滚动容器里）时不做折叠，交给 Wrap 自己换行。
        if (!available.isFinite || available <= 0) {
          return Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [..._chips(context, items), ...trailing],
          );
        }
        final widths = [for (final item in items) _measure(context, item)];
        var visible = _fit(widths, available, maxLines);
        if (visible < items.length) {
          // 折叠时给「更多」腾一个位置，宁可少放一个也不让最后一行挤出去。
          visible = (visible - 1).clamp(0, items.length);
        }
        final hidden = items.sublist(visible);
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ..._chips(context, items.take(visible).toList()),
            if (hidden.isNotEmpty) _more(context, hidden),
            ...trailing,
          ],
        );
      },
    );
  }

  List<Widget> _chips(BuildContext context, List<MagnetChipItem> source) => [
    for (final item in source) _chip(context, item),
  ];

  Widget _chip(BuildContext context, MagnetChipItem item) => switch (style) {
    MagnetChipStyle.filter => FilterChip(
      label: Text(item.label, style: const TextStyle(fontSize: 12)),
      selected: item.selected,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      labelPadding: const EdgeInsets.symmetric(horizontal: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      onSelected: (_) => item.onTap(),
    ),
    MagnetChipStyle.pill => _PillChip(
      label: item.label,
      selected: item.selected,
      onTap: item.onTap,
    ),
  };

  Widget _more(BuildContext context, List<MagnetChipItem> hidden) {
    MagnetChipItem? chosen;
    for (final item in hidden) {
      if (item.selected) {
        chosen = item;
        break;
      }
    }
    final label = chosen?.label ?? '+${hidden.length}';
    return PopupMenuButton<int>(
      tooltip: hidden.length > 1 ? '还有 ${hidden.length} 个标签' : '更多标签',
      onSelected: (index) => hidden[index].onTap(),
      itemBuilder: (context) => [
        for (var i = 0; i < hidden.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Row(
              children: [
                if (hidden[i].selected)
                  Icon(
                    Icons.check,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  )
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    hidden[i].label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Chip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        labelPadding: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
    );
  }

  /// 估算单个标签的渲染宽度：文字宽度 + 内边距，选中态还要加一个勾选图标。
  double _measure(BuildContext context, MagnetChipItem item) {
    final painter = TextPainter(
      text: TextSpan(text: item.label, style: const TextStyle(fontSize: 12)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final base = style == MagnetChipStyle.pill ? 22.0 : 26.0;
    final check = item.selected && style == MagnetChipStyle.filter ? 20.0 : 0.0;
    return painter.width + base + check;
  }

  /// 贪心分行，返回在 [maxLines] 行内能完整放下的前 N 项。
  int _fit(List<double> widths, double maxWidth, int maxLines) {
    const spacing = 6.0;
    var lines = 1;
    var used = 0.0;
    var count = 0;
    for (final width in widths) {
      if (used == 0) {
        used = width;
        count++;
        continue;
      }
      if (used + spacing + width <= maxWidth) {
        used += spacing + width;
        count++;
        continue;
      }
      if (lines >= maxLines) break;
      lines++;
      used = width;
      count++;
    }
    return count;
  }
}

class _PillChip extends StatelessWidget {
  const _PillChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primaryContainer
          : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          // 必须用 Center(widthFactor/heightFactor: 1) 收缩到文字尺寸：
          // 直接给 Container 设 alignment 会撑满 Wrap 分到的整行宽度，
          // 每个热词各占一行（实测 20 个热词撑到 370px 高，把结果区挤爆）。
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
