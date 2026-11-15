import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/ui/audiobook/audiobook_stream_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const headers = <String, String>{
    'Referer': 'https://novel.snssdk.com/',
    'User-Agent': 'com.dragon.read',
  };

  test('本机代理给出 loopback + .m4a 地址，重复登记复用同一 token', () async {
    final proxy = AudiobookStreamProxy.instance;
    final url = await proxy.register(
      'https://cdn.example/reading/reader/audio/playinfo',
      headers,
    );
    expect(
      url.startsWith('http://127.0.0.1:'),
      isTrue,
      reason: '播放器只应连本机，不能直连 CDN',
    );
    expect(
      url.endsWith('.m4a'),
      isTrue,
      reason: '带容器扩展名，Windows libmpv 才能稳定探测 mov/mp4',
    );
    expect(isLoopbackAudiobookUrl(url), isTrue);
    final again = await proxy.register(
      'https://cdn.example/reading/reader/audio/playinfo',
      headers,
    );
    expect(again, url, reason: '切章来回跳不应累积条目');
    expect(
      isLoopbackAudiobookUrl('https://cdn.example/audio/playinfo'),
      isFalse,
    );
  });

  test('上游请求头由代理注入，Range 与响应体原样透传', () async {
    final seen = <String, String>{};
    var lastRange = '';
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));
    upstream.listen((request) async {
      request.headers.forEach((name, values) {
        seen[name.toLowerCase()] = values.first;
      });
      lastRange = request.headers.value('range') ?? '';
      final body = utf8.encode('AUDIO-BYTES-0123456789');
      if (lastRange.isNotEmpty) {
        final parts = lastRange.replaceAll('bytes=', '').split('-');
        final start = int.parse(parts[0]);
        final end = int.parse(parts[1]);
        final slice = body.sublist(start, end + 1);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          'Content-Range',
          'bytes $start-$end/${body.length}',
        );
        request.response.headers.set('Content-Length', slice.length);
        request.response.add(slice);
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set('Content-Length', body.length);
        request.response.add(body);
      }
      request.response.headers.set('Content-Type', 'audio/mp4');
      request.response.headers.set('Accept-Ranges', 'bytes');
      await request.response.close();
    });

    final url = await AudiobookStreamProxy.instance.register(
      'http://127.0.0.1:${upstream.port}/audio/playinfo',
      headers,
    );
    final client = HttpClient()..autoUncompress = false;
    addTearDown(() => client.close(force: true));

    Future<List<int>> fetch({String? range}) async {
      final request = await client.getUrl(Uri.parse(url));
      if (range != null) request.headers.set('Range', range);
      final response = await request.close();
      final out = <int>[];
      await for (final chunk in response) {
        out.addAll(chunk);
      }
      return out;
    }

    final whole = await fetch();
    expect(utf8.decode(whole), 'AUDIO-BYTES-0123456789');
    expect(
      seen['user-agent'],
      'com.dragon.read',
      reason: '红果 CDN 校验 UA，交给 libmpv 转发在 Windows 上会被忽略',
    );
    expect(seen['referer'], 'https://novel.snssdk.com/');

    final slice = await fetch(range: 'bytes=6-14');
    expect(utf8.decode(slice), 'BYTES-012');
    expect(lastRange, 'bytes=6-14', reason: '拖动进度需要 Range 透传');
  });
}
