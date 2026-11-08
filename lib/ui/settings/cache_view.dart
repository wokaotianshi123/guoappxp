import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../app_scope.dart';
import '../widgets/group_card.dart';
import '../widgets/status_view.dart';
import 'storage_view.dart' show storageSize;

/// 「我的 → 设置 → 缓存」：统计并清理磁力下载分片、播放缓存与临时文件。
/// 已完成下载、剧库、追剧和设置都不在清理范围内。
class CacheView extends StatefulWidget {
  const CacheView({super.key});

  @override
  State<CacheView> createState() => _CacheViewState();
}

class _CacheViewState extends State<CacheView> {
  Map<String, dynamic>? _info;
  String? _error;
  String? _message;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  static Future<String> _cacheDirectory() async {
    try {
      return (await getTemporaryDirectory()).path;
    } catch (_) {
      // Web / 桌面端拿不到临时目录时只清理核心数据目录下的缓存。
      return '';
    }
  }

  Future<void> _refresh() async {
    final repository = AppScope.of(context).repository;
    try {
      final directory = await _cacheDirectory();
      final info = await repository.cacheInfo(cacheDirectory: directory);
      if (mounted) {
        setState(() {
          _info = info;
          _error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => _error = '$failure');
    }
  }

  Future<void> _clear() async {
    if (_busy) return;
    final repository = AppScope.of(context).repository;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理缓存？'),
        content: const Text(
          '将删除磁力下载缓存、播放与转码临时文件。\n'
          '已下载的视频、剧库、追剧记录和设置不会受影响。\n'
          '正在播放的视频建议先退出。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final directory = await _cacheDirectory();
      final result = await repository.clearCache(cacheDirectory: directory);
      final cleared = (result['clearedBytes'] as num?)?.toInt() ?? 0;
      final warning = result['warning'] as String? ?? '';
      if (mounted) {
        setState(() {
          _message = cleared > 0
              ? '已释放 ${storageSize(cleared)}${warning.isEmpty ? '' : '；$warning'}'
              : warning.isEmpty
              ? '没有需要清理的缓存'
              : warning;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => _error = '$failure');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null) {
      return _error == null
          ? const StatusView.loading()
          : StatusView(
              title: '无法读取缓存占用',
              message: _error,
              icon: Icons.error_outline,
              action: '重试',
              onAction: _refresh,
            );
    }
    int bytes(String key) => (info[key] as num?)?.toInt() ?? 0;
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        GroupCard(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Text(
                    '可清理 ${storageSize(bytes('bytes'))}',
                    style: text.headlineSmall,
                  ),
                  Text(
                    '${info['files'] ?? 0} 个缓存文件',
                    style: text.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(indent: 16, endIndent: 16),
            SettingsTile(
              title: '磁力下载缓存',
              subtitle: 'BT 边下边播产生的种子分片',
              value: storageSize(bytes('magnetBytes')),
            ),
            const Divider(indent: 16, endIndent: 16),
            SettingsTile(
              title: '播放缓存',
              subtitle: '播放器与播放临时目录中的可再生成文件',
              value: storageSize(bytes('playbackBytes')),
            ),
            const Divider(indent: 16, endIndent: 16),
            SettingsTile(
              title: '临时文件',
              subtitle: '下载与转码留下的过期临时文件',
              value: storageSize(bytes('tempBytes')),
            ),
            const Divider(indent: 16, endIndent: 16),
            SettingsTile(
              icon: Icons.cleaning_services_outlined,
              title: _busy ? '正在清理…' : '清理缓存',
              subtitle: '释放空间；不影响已下载视频与账号资料',
              enabled: !_busy && bytes('bytes') > 0,
              onTap: _clear,
            ),
            const Divider(indent: 16, endIndent: 16),
            SettingsTile(title: '刷新占用', enabled: !_busy, onTap: _refresh),
          ],
        ),
        if (_message != null || _error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              _error ?? _message!,
              style: text.bodyMedium?.copyWith(
                color: _error == null ? colors.primary : colors.error,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            '清理后再次播放磁力会重新下载所需分片。',
            style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
