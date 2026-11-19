import 'dart:typed_data';

import 'package:duanju_app/source_modules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PreparedModule', () {
    test('成功项解析出 token 与名称', () {
      final item = PreparedModule.fromJson({
        'name': '鬼片',
        'info': {
          'id': 'guipian',
          'name': '鬼片',
          'version': '1.0.1',
          'adult': false,
          'token': 'a' * 32,
        },
      });
      expect(item.ok, isTrue);
      expect(item.displayName, '鬼片');
      expect(item.module!.id, 'guipian');
      expect(item.module!.token, 'a' * 32);
    });

    test('失败项带原因且不算成功', () {
      final item = PreparedModule.fromJson({
        'name': 'bundle.zip',
        'error': '安装包不是有效的 zip 文件',
      });
      expect(item.ok, isFalse);
      expect(item.displayName, 'bundle.zip');
      expect(item.error, contains('zip'));
    });

    test('token 为空时不算成功', () {
      final item = PreparedModule.fromJson({
        'name': 'x',
        'info': {'id': 'x', 'name': 'X', 'token': ''},
      });
      expect(item.ok, isFalse);
    });
  });

  group('ModuleExport', () {
    test('保留模块名与数量', () {
      final export = ModuleExport(
        bytes: Uint8List.fromList([1, 2, 3]),
        names: const ['guipian', 'hongguo'],
        count: 2,
      );
      expect(export.count, 2);
      expect(export.names, ['guipian', 'hongguo']);
      expect(export.bytes.length, 3);
    });
  });
}
