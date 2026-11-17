import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

/// 横向滚动条封装：桌面端给横向栏一条可拖动的拇指。
///
/// 横向栏溢出后，桌面用户有三条路可走——按住鼠标拖（靠
/// FocusOutlineScrollBehavior 把 mouse 加进 dragDevices）、Shift + 滚轮
/// （Windows 走 WM_MOUSEHWHEEL，引擎转成横向 delta）、或者直接拖滚动条。
/// 前两条都要用户先知道怎么操作，滚动条是唯一「看得见」的入口，所以补上。
///
/// 移动端和电视端不加：手指本来就能拖，电视端遥控器没有拖拽手势，
/// 多一条滚动条只是占地方。
class HorizontalScrollBar extends StatefulWidget {
  const HorizontalScrollBar({
    super.key,
    required this.child,
    this.controller,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final ScrollController? controller;
  final EdgeInsetsGeometry padding;

  @override
  State<HorizontalScrollBar> createState() => _HorizontalScrollBarState();
}

class _HorizontalScrollBarState extends State<HorizontalScrollBar> {
  ScrollController? _owned;

  ScrollController get _controller =>
      widget.controller ?? (_owned ??= ScrollController());

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desktop = switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };
    if (!desktop) {
      return widget.child;
    }
    // thumbVisibility 要求 controller 固定，不能每次 build 新建。
    return Scrollbar(
      controller: _controller,
      thumbVisibility: true,
      scrollbarOrientation: ScrollbarOrientation.bottom,
      child: ScrollConfiguration(
        // 鼠标拖动：即便外层 behavior 被替换掉，这条横向栏也仍然可拖。
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: {
            ...ScrollConfiguration.of(context).dragDevices,
            PointerDeviceKind.mouse,
          },
          scrollbars: false,
        ),
        child: widget.child,
      ),
    );
  }
}
