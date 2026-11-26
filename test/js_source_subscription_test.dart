import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:duanju_app/js_source/js_source_models.dart';
import 'package:duanju_app/js_source/js_source_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _script = '''
var spider = {
  meta: {
    id: "demo-source",
    name: "演示源",
    version: "1.0.0",
    author: "tester",
  },
  home: function () { return { class: [] }; },
};
''';

void main() {
  group('订阅解析', () {
    test('sources 数组：取名称与地址', () {
      final entries = JsSourceService.parseJsSubscription('''
      {"sources":[
        {"name":"A","url":"https://example.com/a.js"},
        {"title":"B","address":"https://example.com/b.js"}
      ]}
      ''');
      expect([for (final entry in entries) entry.name], ['A', 'B']);
      expect(entries.first.url, 'https://example.com/a.js');
    });

    test('裸数组与裸地址都认', () {
      final entries = JsSourceService.parseJsSubscription(
        '["https://example.com/a.js", {"name":"B","src":"https://example.com/b.js"}]',
      );
      expect(entries.length, 2);
      expect(entries[0].name, isEmpty);
      expect(entries[1].name, 'B');
    });

    test('映射写法：源名 → 地址', () {
      final entries = JsSourceService.parseJsSubscription(
        '{"甲源":"https://example.com/a.js"}',
      );
      expect(entries.single.name, '甲源');
      expect(entries.single.url, 'https://example.com/a.js');
    });

    test('不是 JSON 时返回空，交给单个脚本直链兜底', () {
      expect(JsSourceService.parseJsSubscription('var spider = {};'), isEmpty);
    });

    test('非 http 地址被忽略', () {
      final entries = JsSourceService.parseJsSubscription(
        '{"sources":[{"name":"X","url":"file:///tmp/a.js"}]}',
      );
      expect(entries, isEmpty);
    });

    test('相对地址按订阅地址解析成绝对地址', () {
      final base = Uri.parse('https://example.com/subs/list.json');
      final entries = JsSourceService.parseJsSubscription(
        jsonEncode({
          'sources': [
            {'name': '同级', 'url': './a.js'},
            {'name': '子目录', 'url': 'js/b.js'},
            {'name': '根目录', 'url': '/root/c.js'},
            {'name': '上级', 'url': '../lib/d.js'},
            {'name': '反斜杠', 'url': r'.\win\e.js'},
            {'name': '协议相对', 'url': '//cdn.example.com/f.js'},
          ],
        }),
        base: base,
      );
      expect([for (final entry in entries) entry.url], [
        'https://example.com/subs/a.js',
        'https://example.com/subs/js/b.js',
        'https://example.com/root/c.js',
        'https://example.com/lib/d.js',
        'https://example.com/subs/win/e.js',
        'https://cdn.example.com/f.js',
      ]);
    });

    test('没有订阅地址时相对地址仍然忽略', () {
      final entries = JsSourceService.parseJsSubscription(
        '{"sources":[{"name":"X","url":"./a.js"}]}',
      );
      expect(entries, isEmpty);
    });

    test('单个对象写法也认，相对地址同样解析', () {
      final entries = JsSourceService.parseJsSubscription(
        jsonEncode({'name': '单源', 'url': './a.js'}),
        base: Uri.parse('https://example.com/subs/list.json'),
      );
      expect(entries.single.name, '单源');
      expect(entries.single.url, 'https://example.com/subs/a.js');
    });

    test('带 BOM 的订阅 JSON 也能识别', () {
      final entries = JsSourceService.parseJsSubscription(
        '\uFEFF{"sources":[{"name":"A","url":"./a.js"}]}',
        base: Uri.parse('https://example.com/list.json'),
      );
      expect(entries.single.url, 'https://example.com/a.js');
    });
  });

  test('zip 往返：导出的包能按 meta 重新解析出脚本', () {
    final meta = parseJsSourceMeta(_script, 'demo-source.js');
    expect(meta, isNotNull);
    expect(meta!.name, '演示源');
    expect(meta.version, '1.0.0');
  });

  test('zip 编码后可解出 .js 条目并还原 meta', () {
    final archive = Archive()
      ..add(ArchiveFile.string('demo-source.js', _script))
      ..add(ArchiveFile.string('readme.txt', 'ignore me'));
    final bytes = ZipEncoder().encodeBytes(archive);

    final decoded = ZipDecoder().decodeBytes(bytes);
    final scripts = [
      for (final file in decoded)
        if (file.isFile && file.name.toLowerCase().endsWith('.js'))
          utf8.decode(file.content),
    ];
    expect(scripts.length, 1);
    final meta = parseJsSourceMeta(normalizeJsScript(scripts.single), 'demo-source.js');
    expect(meta?.id, 'demo-source');
  });
}
