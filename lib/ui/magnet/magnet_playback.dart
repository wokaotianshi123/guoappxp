import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../magnet_models.dart';
import '../../models.dart';
import '../player/playback_handle.dart';
import '../player/playback_page.dart';

/// 把一条磁力链接交给内置播放器。
///
/// 项目里播放统一走「构造 DramaDetail + PlaybackHandle → push PlaybackPage」，
/// PlaybackLoader 看到分集 raw['magnet'] 会改走 Go 侧 magnetPlay（BT 元数据 →
/// 本机 HTTP 流）。因此这里只需要一套「伪剧集」，不需要自己碰播放器/弹幕/进度。
///
/// [files] 为空时造一集并把 fileIndex 设为 -1，让 Go 侧自动挑种子里最大的视频
/// 文件；[files] 非空时每个文件对应一集，供搜索页选集后回灌。
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

/// 列表项/搜索结果共用：有 magnet 就直接播，没有则给出可理解的提示。
Future<void> playMagnetResult(
  BuildContext context, {
  required AppRepository repository,
  required LocalStore store,
  required MagnetResult result,
  void Function(String message)? onError,
}) async {
  if (!result.playable || !result.magnet.startsWith('magnet:')) {
    onError?.call('这条资源暂未解析出磁力链接');
    return;
  }
  try {
    await openMagnetPlayback(
      context,
      repository: repository,
      store: store,
      magnet: result.magnet,
      title: result.title,
      subtitle: [
        result.site,
        if (result.size.isNotEmpty) result.size,
        if (result.date.isNotEmpty) result.date,
      ].join(' · '),
    );
  } catch (error) {
    onError?.call('磁力播放失败：$error');
  }
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
