import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../magnet_models.dart';
import '../../models.dart';
import '../player/playback_handle.dart';
import '../player/playback_page.dart';

/// 把「已解析好的」磁力分集交给内置播放器。
///
/// 项目里播放统一走「构造 DramaDetail + PlaybackHandle → push PlaybackPage」，
/// PlaybackLoader 看到分集 raw['magnet'] 会改走 Go 侧 magnetPlay（BT 元数据 →
/// 本机 HTTP 流）。因此这里只需要一套「伪剧集」，不需要自己碰播放器/弹幕/进度。
///
/// [files] 为空时造一集并把 fileIndex 设为 -1，让 Go 侧自动挑种子里最大的视频
/// 文件；[files] 非空时每个文件对应一集，供解析后选集回灌。
Future<void> openMagnetPlayback(
  BuildContext context, {
  required AppRepository repository,
  required LocalStore store,
  required String magnet,
  String title = '磁力播放',
  String subtitle = '',
  List<MagnetFile>? files,
  int startIndex = 0,
}) async {
  final link = magnet.trim();
  if (!link.startsWith('magnet:')) {
    throw const FormatException('不是有效的磁力链接（需以 magnet: 开头）');
  }
  final entries = files ?? const <MagnetFile>[];
  final episodes = entries.isEmpty
      ? <Episode>[
          Episode({
            'id': 'magnet:$link',
            'title': title,
            'currentEpisode': 1,
            'magnet': link,
            // -1 让 Go 侧 magnetPickFile 自动选最大的视频文件。
            'fileIndex': -1,
          }, 1),
        ]
      : <Episode>[
          for (var i = 0; i < entries.length; i++)
            Episode({
              'id': 'magnet:$link:${entries[i].index}',
              'title': entries[i].name,
              'currentEpisode': i + 1,
              'magnet': link,
              'fileIndex': entries[i].index,
            }, i + 1),
        ];
  final start = startIndex.clamp(0, episodes.length - 1);
  final detail = DramaDetail(
    Drama(
      id: 'magnet:$link',
      source: 'magnet',
      title: title,
      description: subtitle,
      episodes: episodes.length,
    ),
    episodes,
  );
  final handle = PlaybackHandle(
    repository: repository,
    store: store,
    detail: detail,
    index: start,
  );
  handle.session.start(start);
  await Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => PlaybackPage(store: store, handle: handle),
    ),
  );
  handle.dispose();
}

/// 磁力播放的统一入口：**先解析磁力链接，再加载播放器**。
///
/// 「磁力搜索」与「磁力播放」两个标签都必须走这里，不能把裸链接直接丢给
/// [openMagnetPlayback]：先取消上一个解析任务并取回种子内文件列表，用户选集
/// （或只有一个视频文件时自动选）之后才构造分集、加载播放器。
///
/// [isCurrent] 由调用方提供，用来在每次异步等待后丢弃过期任务（例如用户连续
/// 点了两条资源）；[onPreparing]/[onError] 用于回显解析中状态与错误提示。
/// [fileIndex] 可强制指定文件，跳过选集弹窗。
///
/// [cancelSignal] 非空时，解析期间如果它被 complete（用户点了「停止解析」），
/// 这里会立即调 magnetCancel 中断 Go 侧的元数据等待并放弃本次播放。
Future<void> resolveAndPlayMagnet(
  BuildContext context, {
  required AppRepository repository,
  required LocalStore store,
  required String magnet,
  required String title,
  String subtitle = '',
  int? fileIndex,
  bool Function()? isCurrent,
  void Function(bool preparing)? onPreparing,
  void Function(String message)? onError,
  Future<void>? cancelSignal,
}) async {
  final link = magnet.trim();
  if (!link.startsWith('magnet:')) {
    onError?.call('这条资源暂未解析出磁力链接');
    return;
  }
  bool stillActive() => isCurrent?.call() ?? true;

  Future<void> launch({List<MagnetFile>? files, int startIndex = 0}) async {
    try {
      await openMagnetPlayback(
        context,
        repository: repository,
        store: store,
        magnet: link,
        title: title,
        subtitle: subtitle,
        files: files,
        startIndex: startIndex,
      );
    } catch (error) {
      if (context.mounted && stillActive()) {
        onError?.call('磁力播放失败：$error');
      }
    }
  }

  onPreparing?.call(true);
  // 解析期间监听「停止」信号：一旦触发就取消 Go 侧加载，并把取消原因回传，
  // 让界面把状态复位（而不是一直转圈）。
  var cancelled = false;
  final watcher = cancelSignal?.then((_) {
    cancelled = true;
    unawaited(repository.magnetCancel());
  });

  final List<MagnetFile> files;
  try {
    // 每次点播先取消上一个还在 DHT 上挂着的解析任务，避免抢占 BT 客户端。
    await repository.magnetCancel();
    if (cancelled) {
      onPreparing?.call(false);
      return;
    }
    files = await repository.magnetFiles(link);
  } catch (error) {
    if (context.mounted && stillActive() && !cancelled) {
      onPreparing?.call(false);
      onError?.call('磁力解析失败：$error');
    } else {
      onPreparing?.call(false);
    }
    return;
  }
  // watcher 只是挂上去等信号，不需要 await 它的返回值。
  unawaited(watcher ?? Future<void>.value());
  if (!context.mounted || !stillActive()) return;
  onPreparing?.call(false);
  if (cancelled) return;

  if (files.isEmpty) {
    // 元数据还没回来也不必卡死：解析已尝试过，这里让 Go 侧自动挑最大视频文件。
    await launch();
    return;
  }

  int chosen = fileIndex ?? -1;
  if (chosen < 0) {
    final videos = files.where((file) => file.video).toList();
    if (videos.length == 1) {
      chosen = videos.first.index;
    } else if (files.length == 1) {
      chosen = files.first.index;
    } else {
      chosen =
          await showModalBottomSheet<int>(
            context: context,
            isScrollControlled: true,
            builder: (_) => _MagnetFilePicker(files: files),
          ) ??
          -1;
    }
  }
  if (chosen < 0 || !context.mounted || !stillActive()) return;
  final start = files.indexWhere((file) => file.index == chosen);
  await launch(files: files, startIndex: start < 0 ? 0 : start);
}

Future<void> copyMagnetLink(BuildContext context, String value) async {
  if (value.trim().isEmpty) return;
  await Clipboard.setData(ClipboardData(text: value.trim()));
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制磁力链接')));
  }
}

/// 解析出多个文件时的选集弹窗（搜索页与播放页共用）。
class _MagnetFilePicker extends StatelessWidget {
  const _MagnetFilePicker({required this.files});

  final List<MagnetFile> files;

  String _size(int bytes) {
    if (bytes <= 0) return '';
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
    return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                '选择要播放的文件',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final file in files)
                    ListTile(
                      leading: Icon(
                        file.video
                            ? Icons.movie_outlined
                            : Icons.insert_drive_file_outlined,
                      ),
                      title: Text(
                        file.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(_size(file.size)),
                      onTap: () => Navigator.of(context).pop(file.index),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
