import 'package:flutter/material.dart';

import '../widgets/status_view.dart';

/// 听书模块沿用源项目的 StatusPanel 调用方式；这里转接到 guoappxp 的
/// StatusView，保持与其它一级页面一致的状态页样式与电视焦点样式。
class StatusPanel extends StatelessWidget {
  const StatusPanel({
    super.key,
    required this.title,
    this.message = '',
    this.onRetry,
    this.icon = Icons.movie_filter_outlined,
    this.action = '重试',
    this.secondaryAction,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;
  final IconData icon;
  final String action;
  final Widget? secondaryAction;

  @override
  Widget build(BuildContext context) {
    final view = StatusView(
      title: title,
      message: message.isEmpty ? null : message,
      icon: icon,
      action: onRetry == null ? null : action,
      onAction: onRetry,
    );
    final secondary = secondaryAction;
    if (secondary == null) return view;
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 320, child: view),
            const SizedBox(height: 8),
            secondary,
          ],
        ),
      ),
    );
  }
}
