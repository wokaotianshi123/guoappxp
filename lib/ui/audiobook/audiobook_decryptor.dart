import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';

import '../../diary_service.dart';

/// Windows 桌面端把 CENC 加密的听书章节交给 ffmpeg 解密成**明文**本地文件。
///
/// 为什么必须这么做：项目 README 与本地服务版 `transcode.go` 都写明了
/// 「听书章节是 CENC 加密的 m4a，浏览器不能解密也不能解 CENC 盒，同样交给
/// ffmpeg 解密后重编码」。Web 版有 `startAudio()` 走这条路，但 App 端一直
/// 把「加密 URL + decryption_key」直接丢给 libmpv —— Windows 的 libmpv
/// 构建解不了 CENC：容器读得出时长、position 照常推进，加密的音频 sample
/// 却解不出音轨，于是「进度在走但没有声音」。Android 的 libmpv 构建能直解、
/// 番茄多为明文，所以只有 Windows + 红果复现；短剧在 Windows 正常也是因为
/// 加密视频同样走 ffmpeg 转码，而不是靠 libmpv。
///
/// 这里复用项目已有的 `ffmpeg_kit_flutter_new_min_gpl`（Windows 发布包必带
/// `libffmpegkit.dll`），用 `-decryption_key` 解密后重编码成标准 AAC 的
/// `.m4a`，播放器拿到的是纯明文文件，不再依赖任何平台相关的解密选项。
/// 结果按「书 + 章节 + 密钥」缓存，重复收听 / 回退重播不必再转一次。
class AudiobookDecryptor {
  AudiobookDecryptor._();

  static final AudiobookDecryptor instance = AudiobookDecryptor._();

  /// 明文缓存最多保留的文件数，按最后访问时间淘汰。
  static const _maxFiles = 24;

  static const _timeout = Duration(minutes: 5);

  /// [input] 可以是本机代理地址（请求头已注入）或本地已下载的加密文件。
  /// 返回可直接交给播放器的明文 `.m4a` 绝对路径。
  Future<String> ensure({
    required String input,
    required String key,
    required String cacheKey,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final directory = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}duanju_audio_plain',
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final token = _hash('$cacheKey\x00$key');
    final output = File('${directory.path}${Platform.pathSeparator}$token.m4a');
    if (await output.exists() && await output.length() > 4096) {
      try {
        await output.setLastModified(DateTime.now());
      } catch (_) {}
      return output.path;
    }
    final part = File('${output.path}.part');
    if (await part.exists()) await part.delete();

    final arguments = buildArguments(
      input: input,
      key: key,
      output: part.path,
      headers: headers,
    );

    var ok = await _runKit(arguments);
    // 插件没注册 / 执行失败时，再试一次 PATH 上（或用户自行放置）的
    // ffmpeg 可执行文件，参数完全一致。
    if (!ok) ok = await _runProcess(arguments);
    if (!ok || !await part.exists() || await part.length() < 4096) {
      try {
        await part.delete();
      } catch (_) {}
      // 留在应用日记里，便于在 Windows 上确认是否走了 ffmpeg 解密链路。
      DiaryService.add('[听书] ffmpeg 解密失败，回退播放器直解');
      throw StateError('音频解密失败');
    }
    if (await output.exists()) await output.delete();
    await part.rename(output.path);
    await _trim(directory);
    DiaryService.add('[听书] Windows 加密章节已由 ffmpeg 解密为明文');
    return output.path;
  }

  /// 单独抽出来便于回归测试：`-decryption_key` 是输入选项，必须排在
  /// `-i` 之前；输入是本机 HTTP 流，白名单里必须放行 http。
  static List<String> buildArguments({
    required String input,
    required String key,
    required String output,
    Map<String, String> headers = const <String, String>{},
  }) {
    // -headers 是 http 协议的私有选项：输入是本地文件（已下载的加密章节）
    // 时传它，ffmpeg 会直接报 "Option headers not found" 并拒绝打开输入。
    final remote = input.startsWith('http://') || input.startsWith('https://');
    final headerText = remote ? encodeHeaders(headers) : '';
    return <String>[
      '-nostdin',
      '-loglevel',
      'error',
      '-y',
      '-protocol_whitelist',
      'file,crypto,data,http,https,tcp,tls',
      if (key.isNotEmpty) ...['-decryption_key', key],
      // 与本地服务版 startAudio 一致：远端上游的 Referer / User-Agent 由
      // ffmpeg 自己带，不必经过本机代理多一跳。
      if (headerText.isNotEmpty) ...['-headers', headerText],
      '-i',
      input,
      '-vn',
      '-sn',
      '-dn',
      '-c:a',
      'aac',
      '-b:a',
      '96k',
      '-ac',
      '2',
      '-ar',
      '44100',
      '-movflags',
      '+faststart',
      output,
    ];
  }

  /// ffmpeg 的 `-headers` 需要 `Name: value\r\n` 形式，与本地服务版
  /// `transcode.go` 的 startAudio 完全一致。
  static String encodeHeaders(Map<String, String> headers) {
    final names = headers.keys.toList()..sort();
    final buffer = StringBuffer();
    for (final name in names) {
      final value = headers[name]?.trim() ?? '';
      if (name.trim().isEmpty || value.isEmpty) continue;
      buffer.write('$name: $value\r\n');
    }
    return buffer.toString();
  }

  Future<bool> _runKit(List<String> arguments) async {
    try {
      final finished = Completer<bool>();
      final session = await FFmpegKit.executeWithArgumentsAsync(
        arguments,
        (result) async {
          final code = await result.getReturnCode();
          if (!finished.isCompleted) {
            finished.complete(ReturnCode.isSuccess(code));
          }
        },
        null,
        null,
      );
      return await finished.future.timeout(
        _timeout,
        onTimeout: () {
          FFmpegKit.cancel(session.getSessionId());
          return false;
        },
      );
    } catch (_) {
      return false;
    }
  }

  Future<bool> _runProcess(List<String> arguments) async {
    try {
      // 输入可能是本机播放服务；清掉代理环境变量，与 transcode.go 的
      // launch 保持一致，避免 127.0.0.1 被系统代理劫持。
      final environment = <String, String>{
        ...Platform.environment,
        'http_proxy': '',
        'https_proxy': '',
        'all_proxy': '',
        'HTTP_PROXY': '',
        'HTTPS_PROXY': '',
        'ALL_PROXY': '',
        'no_proxy': '*',
        'NO_PROXY': '*',
      };
      final process = await Process.start(
        'ffmpeg',
        arguments,
        environment: environment,
      );
      final code = await process.exitCode.timeout(
        _timeout,
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      return code == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _trim(Directory directory) async {
    try {
      final files = directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.m4a'))
          .toList();
      if (files.length <= _maxFiles) return;
      files.sort(
        (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
      );
      for (final file in files.skip(_maxFiles)) {
        try {
          await file.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// FNV-1a 32 位，只为生成合法且稳定的文件名，不引入额外依赖。
  static String _hash(String text) {
    var hash = 0x811c9dc5;
    for (final unit in utf8.encode(text)) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return '${hash.toRadixString(16)}-${utf8.encode(text).length}';
  }
}
