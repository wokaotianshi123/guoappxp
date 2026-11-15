import 'dart:io';

import 'package:duanju_app/ui/audiobook/audiobook_decryptor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('解密参数：decryption_key 排在 -i 之前，白名单放行本机 http', () {
    const key = '00112233445566778899aabbccddeeff';
    final args = AudiobookDecryptor.buildArguments(
      input: 'http://127.0.0.1:12345/audio/abc.m4a',
      key: key,
      output: '/tmp/plain.m4a',
    );
    final keyAt = args.indexOf('-decryption_key');
    final inputAt = args.indexOf('-i');
    expect(keyAt, greaterThanOrEqualTo(0));
    expect(
      inputAt,
      greaterThan(keyAt),
      reason: '-decryption_key 是输入选项，必须排在 -i 之前',
    );
    expect(args[keyAt + 1], key);
    expect(
      args[args.indexOf('-protocol_whitelist') + 1],
      contains('http'),
      reason: '输入是本机 HTTP 流，FFmpegExecutor 的 file,crypto,data 不够用',
    );
    expect(args.last, '/tmp/plain.m4a');
    expect(args, contains('-c:a'));
    expect(args, contains('aac'), reason: '解密后重编码成标准 AAC 明文');
  });

  test('上游请求头编码成 ffmpeg -headers 格式并排在 -i 之前', () {
    final encoded = AudiobookDecryptor.encodeHeaders({
      'User-Agent': 'com.dragon.read',
      'Referer': 'https://novel.snssdk.com/',
      '空': '  ',
    });
    expect(encoded, contains('Referer: https://novel.snssdk.com/'));
    expect(encoded, contains('User-Agent: com.dragon.read'));
    expect(encoded.contains('\r\n'), isTrue);
    expect(encoded.contains('空'), isFalse, reason: '空值请求头要跳过');
    final args = AudiobookDecryptor.buildArguments(
      input: 'https://cdn.example/audio/playinfo',
      key: 'ab',
      output: 'out.m4a',
      headers: const {'User-Agent': 'com.dragon.read'},
    );
    final headersAt = args.indexOf('-headers');
    expect(headersAt, greaterThanOrEqualTo(0));
    expect(headersAt, lessThan(args.indexOf('-i')));
  });

  test('本地文件输入不能带 -headers（ffmpeg 会报 Option not found）', () {
    final args = AudiobookDecryptor.buildArguments(
      input: '/path/to/downloaded.m4a',
      key: 'ab',
      output: 'out.m4a',
      headers: const {'User-Agent': 'com.dragon.read'},
    );
    expect(
      args,
      isNot(contains('-headers')),
      reason: '-headers 是 http 协议私有选项，本地文件输入传了会直接拒绝',
    );
  });

  test('没有密钥时不传 -decryption_key（番茄明文）', () {
    final args = AudiobookDecryptor.buildArguments(
      input: 'x',
      key: '',
      output: 'y',
    );
    expect(args, isNot(contains('-decryption_key')));
  });

  test('Windows 加密章节走 ffmpeg 明文，且 demuxer-lavf-o 不再有逗号坑', () {
    final source = File(
      'lib/ui/audiobook/audiobook_session.dart',
    ).readAsStringSync();
    expect(
      source.contains('AudiobookDecryptor.instance.ensure'),
      isTrue,
      reason: 'Windows 必须先把 CENC 音频解密成明文',
    );
    expect(
      source.contains('Platform.isWindows && target.key.isNotEmpty'),
      isTrue,
      reason: '只对 Windows 的加密章节启用，Android / 番茄不受影响',
    );
    expect(
      source.contains('if (!plainAudio && target.key.isNotEmpty)'),
      isTrue,
      reason: '已解密的明文不能再传 decryption_key',
    );
    // mpv 的 demuxer-lavf-o 按逗号拆 key=value；protocol_whitelist 的值里
    // 含逗号会拆出一堆无 = 的碎片，整条选项可能被丢弃，排在最后的
    // decryption_key 就从未生效。
    expect(
      source.contains(
        'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
      ),
      isFalse,
      reason: 'demuxer-lavf-o 里不能出现含逗号的 protocol_whitelist 值',
    );
    expect(
      source.contains("setProperty('demuxer-lavf-format', 'mov')"),
      isFalse,
      reason: '不应把容器锁死为 mov',
    );
  });
}
