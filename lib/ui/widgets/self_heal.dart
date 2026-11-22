import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../app_scope.dart';
import '../settings/settings_page.dart';
import '../settings/sorani_account_view.dart';
import 'focus_ring.dart';
import 'status_view.dart';

/// 出错时的「一键自愈」引导。
///
/// 站源加载失败大多是三类原因：Cloudflare 人机验证没过、需要登录（青空）、
/// 或者网络连不上。这里按失败原因给出对应入口，用户不用自己去设置里翻：
///
/// - 人机验证：调起应用内浏览器走完校验，成功后自动重试；
/// - 青空登录：直接弹账号登录框；
/// - 网络代理：跳到「设置 › 代理」。
///
/// 没有任何可用的自愈手段时返回空列表，调用方回落到普通的「重试」按钮。
class SelfHealGuide {
  const SelfHealGuide({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Future<void> Function() onPressed;

  /// 根据失败信息推断可用的自愈入口。
  ///
  /// [onRetry] 在自愈成功后调用，用来重新加载内容。
  /// [verify] 是「应用内浏览器验证」的实现，由调用方注入，避免 UI 层直接
  /// 依赖原生通道；为空表示当前平台不支持。
  static List<SelfHealGuide> forError(
    BuildContext context, {
    required String message,
    required VoidCallback onRetry,
    LocalStore? store,
    String source = '',
    Future<bool> Function(String source)? verify,
  }) {
    final guides = <SelfHealGuide>[];
    final lower = message.toLowerCase();

    final challenge =
        lower.contains('cf_challenge') ||
        message.contains('Cloudflare 人机验证') ||
        message.contains('完成人机验证') ||
        message.contains('手动完成验证') ||
        lower.contains('just a moment') ||
        lower.contains('cloudflare');
    if (challenge && verify != null) {
      guides.add(
        SelfHealGuide(
          label: '完成人机验证',
          icon: Icons.verified_user_outlined,
          onPressed: () async {
            if (!context.mounted) return;
            final messenger = ScaffoldMessenger.maybeOf(context);
            final ok = await verify(source);
            if (!context.mounted) return;
            messenger?.showSnackBar(
              SnackBar(
                content: Text(ok ? '验证通过，正在重新加载' : '没有完成验证，可稍后再试'),
              ),
            );
            if (ok) onRetry();
          },
        ),
      );
    }

    final login =
        lower.contains('登录') ||
        lower.contains('login') ||
        lower.contains('未授权') ||
        lower.contains('需要账号');
    if (login && soraniAccountAvailable()) {
      guides.add(
        SelfHealGuide(
          label: '登录青空账号',
          icon: Icons.person_outline_rounded,
          onPressed: () async {
            if (!context.mounted) return;
            final account = await showSoraniLogin(context);
            if (account != null) onRetry();
          },
        ),
      );
    }

    final network =
        lower.contains('超时') ||
        lower.contains('timeout') ||
        lower.contains('网络') ||
        lower.contains('连接') ||
        lower.contains('connection') ||
        lower.contains('socket') ||
        lower.contains('dns') ||
        lower.contains('失败');
    if (network && store != null) {
      guides.add(
        SelfHealGuide(
          label: '设置网络代理',
          icon: Icons.language_rounded,
          onPressed: () async {
            if (!context.mounted) return;
            await openProxySettings(context, store);
            if (context.mounted) onRetry();
          },
        ),
      );
    }

    return guides;
  }
}

/// 在状态视图里展示自愈引导按钮。
class SelfHealActions extends StatelessWidget {
  const SelfHealActions({
    super.key,
    required this.guides,
    this.autofocus = false,
  });

  final List<SelfHealGuide> guides;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    if (guides.isEmpty) return const SizedBox.shrink();
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final (index, guide) in guides.indexed)
          FocusRing(
            radius: 999,
            child: FilledButton.tonalIcon(
              autofocus: autofocus && index == 0,
              onPressed: () => guide.onPressed(),
              icon: Icon(guide.icon, size: 18),
              label: Text(guide.label),
            ),
          ),
      ],
    );
  }
}

/// 带自愈引导的错误视图：保留原来的标题 / 说明 / 重试，再补上引导按钮。
class ErrorStatusView extends StatelessWidget {
  const ErrorStatusView({
    super.key,
    required this.title,
    required this.message,
    this.icon = Icons.cloud_off_rounded,
    this.source = '',
    this.retryLabel = '重试',
    required this.onRetry,
    this.autofocus = false,
    this.store,
    this.verify,
  });

  final String title;
  final String message;
  final IconData icon;
  final String source;
  final String retryLabel;
  final VoidCallback onRetry;
  final bool autofocus;
  final LocalStore? store;
  final Future<bool> Function(String source)? verify;

  @override
  Widget build(BuildContext context) {
    final guides = SelfHealGuide.forError(
      context,
      message: message,
      onRetry: onRetry,
      store: store,
      source: source,
      verify: verify,
    );
    return StatusView(
      title: title,
      message: message,
      icon: icon,
      action: retryLabel,
      onAction: onRetry,
      autofocus: autofocus,
      extra: guides.isEmpty
          ? null
          : SelfHealActions(guides: guides, autofocus: autofocus),
    );
  }
}

/// 便捷入口：用全局的 WebView 验证能力构造 verify 回调。
///
/// 平台不支持时返回 null，自愈引导会自动隐藏「完成人机验证」按钮。
Future<bool> Function(String source)? webViewVerifier(BuildContext context) {
  final repository = AppScope.of(context).repository;
  if (!repository.supportsWebViewVerify) return null;
  return repository.verifySource;
}
