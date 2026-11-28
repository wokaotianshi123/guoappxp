import 'package:duanju_app/py_source/py_source_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// py 源显示名解析：优先脚本里的 `getName()`，读不到才退回文件名。
///
/// 这条链路以前只按文件名推导，导致导入 `hongguoxian.py` 后沙箱里显示
/// 「hongguoxian」而不是脚本自己声明的「红果短剧」。
void main() {
  group('从脚本读显示名', () {
    test('标准 getName 写法', () {
      const script = '''
class Spider:
    def getName(self):
        return "红果短剧"

    def isVideoFormat(self, url):
        return ".mp4" in url
''';
      expect(pyNameFromScript(script), '红果短剧');
    });

    test('带返回类型注解', () {
      const script = '''
class Spider:
    def getName(self) -> str:
        return "注解版"
''';
      expect(pyNameFromScript(script), '注解版');
    });

    test('单引号与同行 return', () {
      expect(
        pyNameFromScript("class Spider:\n    def getName(self):\n        return '单引号'\n"),
        '单引号',
      );
      expect(
        pyNameFromScript('class Spider:\n    def getName(self): return "同行"\n'),
        '同行',
      );
    });

    test('self.name 与裸 name 属性', () {
      expect(
        pyNameFromScript('class Spider:\n    def __init__(self):\n        self.name = "属性名"\n'),
        '属性名',
      );
      expect(pyNameFromScript('name = "裸名字"\nclass Spider:\n    pass\n'), '裸名字');
    });

    test('meta 字典写法', () {
      expect(
        pyNameFromScript('meta = {"name": "字典名", "id": "x"}\nclass Spider:\n    pass\n'),
        '字典名',
      );
    });

    test('不会误取别的方法的 return', () {
      const script = '''
class Spider:
    def other(self):
        return "错的"
    def getName(self):
        return "对的"
''';
      expect(pyNameFromScript(script), '对的');
    });

    test('不会把普通变量当名字', () {
      const script = '''
class Spider:
    def __init__(self):
        file_name = "误取.py"
''';
      expect(pyNameFromScript(script), '');
    });

    test('返回变量时不硬猜', () {
      expect(
        pyNameFromScript('class Spider:\n    def getName(self):\n        return self._title\n'),
        '',
      );
    });

    test('完全没有名字信息时返回空串', () {
      expect(
        pyNameFromScript('class Spider:\n    def homeContent(self, f=False):\n        return {}\n'),
        '',
      );
    });
  });

  group('文件名兜底', () {
    test('脚本有名字时用脚本的', () {
      final result = pyMetaFromFileName(
        'hongguoxian.py',
        script: 'class Spider:\n    def getName(self):\n        return "红果短剧"\n',
      );
      expect(result.meta!.name, '红果短剧');
      // 标识仍然来自文件名，保持稳定。
      expect(result.meta!.id, 'hongguoxian');
      expect(result.meta!.fileName, 'hongguoxian.py');
    });

    test('脚本没名字时退回文件名', () {
      final result = pyMetaFromFileName(
        '我的蜘蛛.py',
        script: 'class Spider:\n    pass\n',
      );
      expect(result.meta!.name, '我的蜘蛛');
    });

    test('不给脚本时保持原行为', () {
      final result = pyMetaFromFileName('demo.py');
      expect(result.meta!.name, 'demo');
    });
  });
}
