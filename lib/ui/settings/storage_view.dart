import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../local_store.dart';
import '../app_scope.dart';
import '../widgets/focus_ring.dart';
import '../widgets/group_card.dart';
import '../widgets/status_view.dart';
import 'settings_rows.dart';

String storageSize(int bytes) {
  if (bytes < 0) return '暂不可用';
  if (bytes < 1 << 20) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1 << 30) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
}

/// 系统临时/缓存目录。核心只认应用私有目录，拿不到时返回空串，
/// 由核心退化成只清理数据目录里的缓存。
Future<String> storageCacheDirectory() async {
  try {
    return (await getTemporaryDirectory()).path;
  } catch (_) {
    return '';
  }
}

/// 「设置 → 存储」：下载目录、用量、清理缓存与删除全部数据。
///
/// 总用量把缓存算进去（核心在 storage 里已累加），这样「清理缓存」释放的
/// 空间能在同一个数字上直接看到。
class StorageView extends StatefulWidget {
  const StorageView({super.key, required this.store});
  final LocalStore store;

  @override
  State<StorageView> createState() => _StorageViewState();
}

class _StorageViewState extends State<StorageView> {
  Map<String, dynamic>? _info;
  int? _cacheBytes;
  String? _error;
  bool _clearing = false;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final repository = AppScope.of(context).repository;
    final directory = await storageCacheDirectory();
    try {
      final info = await repository.storage(cacheDirectory: directory);
      if (mounted) {
        setState(() {
          _info = info;
          _cacheBytes = (info['cache'] as num?)?.toInt();
          _error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => _error = '$failure');
    }
  }

  Future<void> _clearCache() async {
    if (_clearing) return;
    setState(() => _clearing = true);
    final repository = AppScope.of(context).repository;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final directory = await storageCacheDirectory();
      final result = await repository.clearCache(cacheDirectory: directory);
      final cleared = (result['clearedBytes'] as num?)?.toInt() ?? 0;
      final warning = result['warning'] as String? ?? '';
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            cleared > 0
                ? '已释放 ${storageSize(cleared)}${warning.isEmpty ? '' : '；$warning'}'
                : warning.isEmpty
                ? '没有需要清理的缓存'
                : warning,
          ),
        ),
      );
    } catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text('$failure')));
    } finally {
      if (mounted) setState(() => _clearing = false);
      await _refresh();
    }
  }

  Future<void> _deleteAll() async {
    if (_deleting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除全部数据？'),
        content: const Text(
          '将删除所有用户、追剧、观看记录、设置、已安装模块、缓存和已下载的视频，无法恢复。'
          '已导出到相册的视频保留。完成后应用会退出。',
        ),
        actions: [
          FocusRing(
            radius: 20,
            child: TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
          ),
          FocusRing(
            radius: 20,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    final repository = AppScope.of(context).repository;
    final store = widget.store;
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            spacing: 20,
            children: [
              CircularProgressIndicator(),
              Expanded(child: Text('正在删除，请保持应用运行…')),
            ],
          ),
        ),
      ),
    );
    List<String> leftover;
    try {
      final directory = await storageCacheDirectory();
      leftover = await store.eraseAll(
        () => repository.deleteAllData(cacheDirectory: directory),
      );
    } catch (failure) {
      navigator.pop();
      if (mounted) {
        setState(() => _deleting = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$failure')));
      }
      return;
    }
    navigator.pop();
    // 数据都删完了，进程里还留着已失效的索引与文件句柄，继续跑只会不断报错。
    // 除 iOS（不允许自行退出）外直接退出。
    if (leftover.isEmpty && !Platform.isIOS) exit(0);
    if (!mounted) return;
    setState(() => _deleting = false);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('数据已删除'),
          content: SelectableText(
            [
              if (leftover.isNotEmpty)
                '以下文件没能删除，请退出后手动删除：\n${leftover.join('\n')}',
              if (Platform.isIOS) '请从后台划掉应用后重新打开。',
            ].join('\n\n'),
          ),
          actions: [
            if (!Platform.isIOS)
              FilledButton(
                autofocus: true,
                onPressed: () => exit(0),
                child: const Text('退出应用'),
              ),
          ],
        ),
      ),
    );
  }

  Future<String?> _pickParent() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return FilePicker.getDirectoryPath(dialogTitle: '选择下载保存位置');
    }
    final support = await getApplicationSupportDirectory();
    final directories = <String, String>{support.path: '应用内部存储'};
    if (Platform.isAndroid) {
      final external = await getExternalStorageDirectories() ?? [];
      for (final (index, directory) in external.indexed) {
        directories[directory.path] = index == 0
            ? '设备共享存储（应用目录）'
            : 'SD 卡 ${index + 1}（应用目录）';
      }
    } else {
      final documents = await getApplicationDocumentsDirectory();
      directories[documents.path] = '文件 App 可见目录';
    }
    if (!mounted) return null;
    return showOptionDialog(
      context,
      title: '选择下载位置',
      options: directories,
      selected: null,
    );
  }

  Future<void> _move() async {
    final parent = await _pickParent();
    if (parent == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('迁移已下载内容？'),
        content: Text(
          '将下载目录里的全部内容迁移到：\n$parent\n\n下载会先暂停，复制成功后清理旧目录。请保证目标有足够空间，并在完成后继续下载。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('迁移'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final repository = AppScope.of(context).repository;
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            spacing: 20,
            children: [
              CircularProgressIndicator(),
              Expanded(child: Text('正在迁移，请保持应用运行…')),
            ],
          ),
        ),
      ),
    );
    try {
      await repository.moveDownloads(parent);
    } catch (failure) {
      if (mounted) setState(() => _error = '$failure');
    } finally {
      navigator.pop();
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    children: [
      ..._body(context),
      const SizedBox(height: 12),
      // 清理缓存与删除全部数据不依赖下载能力，只读用户也能清理自己的空间。
      SettingsCard(
        children: [
          SettingsTile(
            icon: Icons.cleaning_services_outlined,
            title: _clearing ? '正在清理…' : '清理缓存',
            subtitle: [
              if (_cacheBytes case final bytes?) '已用 ${storageSize(bytes)}',
              '海报、目录和榜单会重新加载',
            ].join(' · '),
            enabled: !_clearing && !_deleting,
            onTap: _clearCache,
          ),
          const Divider(indent: 16, endIndent: 16),
          SettingsTile(
            icon: Icons.delete_forever_outlined,
            title: _deleting ? '正在删除…' : '删除全部数据',
            subtitle: '删除用户、记录、设置、模块、缓存和已下载的视频，完成后退出应用',
            enabled: !_clearing && !_deleting,
            onTap: _deleteAll,
          ),
        ],
      ),
    ],
  );

  List<Widget> _body(BuildContext context) {
    final info = _info;
    if (info == null) {
      return [
        _error == null
            ? const StatusView.loading()
            : StatusView(
                title: '无法读取下载目录',
                message: _error,
                icon: Icons.folder_off_outlined,
                action: '重试',
                onAction: _refresh,
              ),
      ];
    }
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final directory = info['directory'] as String? ?? '';
    final admin = widget.store.profile.admin;
    final cache = (info['cache'] as num?)?.toInt() ?? 0;
    return [
      GroupCard(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(
                  '已使用 ${storageSize((info['bytes'] as num?)?.toInt() ?? 0)}',
                  style: text.headlineSmall,
                ),
                Text(
                  '剩余 ${storageSize((info['free'] as num?)?.toInt() ?? -1)} · ${info['files'] ?? 0} 个文件'
                  '${cache > 0 ? ' · 其中缓存 ${storageSize(cache)}' : ''}',
                  style: text.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(indent: 16, endIndent: 16),
          SettingsTile(
            title: '当前下载目录',
            subtitle: directory,
            trailing: FocusRing(
              radius: 999,
              child: IconButton(
                tooltip: '复制路径',
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: directory)),
                icon: const Icon(Icons.copy_rounded),
              ),
            ),
          ),
          const Divider(indent: 16, endIndent: 16),
          SettingsTile(
            title: '更改并迁移目录',
            subtitle: admin ? '下载会先暂停，复制成功后清理旧目录' : '需要管理员',
            enabled: admin,
            onTap: _move,
          ),
          const Divider(indent: 16, endIndent: 16),
          SettingsTile(title: '刷新用量', onTap: _refresh),
        ],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Text(
          _error ?? '在下载页删除不需要的分集，在本地媒体页删除合并成品，可释放空间。',
          style: text.bodyMedium?.copyWith(
            color: _error == null ? colors.onSurfaceVariant : colors.error,
          ),
        ),
      ),
    ];
  }
}
