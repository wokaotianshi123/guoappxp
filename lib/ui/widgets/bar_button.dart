import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'focus_ring.dart';

class BarButton extends StatelessWidget {
  const BarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.focusNode,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  /// 电视端顶栏的按钮由宿主持有 FocusNode，才能参与确定性的遥控器顺序。
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final television = AppScope.of(context).television;
    return FocusRing(
      radius: 999,
      child: IconButton(
        focusNode: focusNode,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: television ? 20 : 22),
        style: IconButton.styleFrom(
          fixedSize: television ? const Size.square(40) : null,
          minimumSize: television ? const Size.square(40) : null,
          backgroundColor: television ? colors.surfaceContainerHigh : null,
          foregroundColor: television
              ? colors.onSurface
              : colors.onSurfaceVariant,
        ),
      ),
    );
  }
}
