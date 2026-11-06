import 'package:flutter/material.dart';

import '../core_bridge.dart';
import '../local_store.dart';
import '../resource_settings.dart';
import 'app_scope.dart';
import 'widgets/focus_ring.dart';

// 整个进程只注册一次：主题 / 语言切换会重建 App，但门禁不该再弹一遍。
var _devicesReady = false;

/// 首启门禁：先把红果主设备和辅助设备注册好，再挂载 AppShell 加载推荐等内容。
/// 已注册过的设备直接放行；老版本升级后只有辅助设备缺失，会弹一次补注册。
class DeviceRegistrationGate extends StatefulWidget {
  const DeviceRegistrationGate({
    super.key,
    required this.store,
    required this.child,
  });
  final LocalStore store;
  final Widget child;

  @override
  State<DeviceRegistrationGate> createState() => _DeviceRegistrationGateState();
}

class _DeviceRegistrationGateState extends State<DeviceRegistrationGate> {
  @override
  void initState() {
    super.initState();
    if (!_devicesReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    }
  }

  Future<void> _open() async {
    if (!mounted) return;
    final repository = AppScope.of(context).repository;
    var ready = await repository.hongguoDevices().catchError((_) => false);
    if (!ready && mounted) {
      ready =
          await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => _RegistrationDialog(repository: repository),
          ) ??
          false;
    }
    if (ready && mounted) setState(() => _devicesReady = true);
  }

  @override
  Widget build(BuildContext context) => _devicesReady
      ? widget.child
      : const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _RegistrationDialog extends StatefulWidget {
  const _RegistrationDialog({required this.repository});
  final AppRepository repository;

  @override
  State<_RegistrationDialog> createState() => _RegistrationDialogState();
}

class _RegistrationDialogState extends State<_RegistrationDialog> {
  String? _error;

  @override
  void initState() {
    super.initState();
    _register();
  }

  Future<void> _register() async {
    if (_error != null) setState(() => _error = null);
    String error;
    try {
      if (await widget.repository.hongguoDevices(register: true)) {
        if (mounted) Navigator.pop(context, true);
        return;
      }
      error = '设备注册未完成，请重试';
    } catch (failure) {
      error = '$failure';
    }
    if (mounted) setState(() => _error = error);
  }

  /// 注册失败常见于网络不通 / 代理不对，这里直接改代理后自动重试，
  /// 不必先退出播放流程去设置页绕一圈。
  Future<void> _openProxy() async {
    ResourceSettings? settings;
    try {
      settings = await widget.repository.resourceSettings();
    } catch (_) {
      // 未解锁或无权读取时仍允许手动填一个地址。
    }
    if (!mounted) return;
    final address = await showDialog<String>(
      context: context,
      builder: (_) => _ProxyAddressDialog(initial: settings?.proxyUrl ?? ''),
    );
    if (address == null) return;
    try {
      await widget.repository.saveResourceSettings(
        (settings ?? const ResourceSettings()).copyWith(
          proxyMode: 'manual',
          proxyUrl: address,
        ),
      );
    } catch (failure) {
      if (mounted) setState(() => _error = '网络设置保存失败：$failure');
      return;
    }
    if (mounted) await _register();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(error == null ? '正在注册设备...' : '设备注册失败'),
        content: error == null
            ? const Row(
                spacing: 16,
                children: [
                  SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  Flexible(child: Text('正在注册红果设备和辅助设备，完成后自动进入')),
                ],
              )
            : Text('$error\n\n请检查网络，或在网络设置中修改代理后重试。'),
        actions: error == null
            ? null
            : [
                FocusRing(
                  radius: 20,
                  child: TextButton(
                    onPressed: _openProxy,
                    child: const Text('网络设置'),
                  ),
                ),
                FocusRing(
                  radius: 20,
                  child: FilledButton(
                    autofocus: true,
                    onPressed: _register,
                    child: const Text('重试'),
                  ),
                ),
              ],
      ),
    );
  }
}

class _ProxyAddressDialog extends StatefulWidget {
  const _ProxyAddressDialog({required this.initial});
  final String initial;

  @override
  State<_ProxyAddressDialog> createState() => _ProxyAddressDialogState();
}

class _ProxyAddressDialogState extends State<_ProxyAddressDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('网络设置'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(
        labelText: '代理地址',
        hintText: 'http://127.0.0.1:7890',
      ),
      onSubmitted: (_) => Navigator.pop(context, _controller.text.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: const Text('保存并重试'),
      ),
    ],
  );
}
