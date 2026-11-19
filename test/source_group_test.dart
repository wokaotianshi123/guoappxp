import 'package:duanju_app/models.dart';
import 'package:duanju_app/source_modules.dart';
import 'package:flutter_test/flutter_test.dart';

SourceSite site(String id, {String category = '', String group = ''}) =>
    SourceSite.fromJson({
      'id': id,
      'name': id,
      'description': '',
      'available': true,
      'category': category,
      'group': group,
    });

void main() {
  group('SourceSite.classKey', () {
    test('清单声明类目优先，大小写都认', () {
      expect(site('a', category: 'shortDrama').classKey, SourceClass.shortDrama);
      expect(site('b', category: 'shortdrama').classKey, SourceClass.shortDrama);
      expect(site('c', category: 'video').classKey, SourceClass.video);
      expect(site('d', category: 'huangguo').classKey, SourceClass.huangguo);
      expect(site('e', category: 'adult').classKey, SourceClass.adult);
    });

    test('没写类目的老模块按标识兜底', () {
      expect(site('hongguo').classKey, SourceClass.shortDrama);
      expect(site('huangdou').classKey, SourceClass.huangguo);
      expect(site('sorani').classKey, SourceClass.video);
      expect(site('missav').classKey, SourceClass.adult);
      // 自定义XBPQ 添加的源自成一组，不会被误判成某一类。
      expect(site('custom:3f2a').classKey, SourceClass.xbpq);
      // 完全不认识的模块才归「其他站源」。
      expect(site('some-new-module').classKey, SourceClass.other);
    });

    test('黄果类成员按标识恒定归类，清单的类别不改变它', () {
      // 商店清单里黄豆/剧果这类写的是 category: shortDrama，界面上仍归黄果类。
      expect(
        site('huangdou', category: 'shortDrama').classKey,
        SourceClass.huangguo,
      );
      expect(site('huangju', category: 'shortDrama').classKey, SourceClass.huangguo);
      expect(site('cloudfront', category: 'video').classKey, SourceClass.huangguo);
      // 红果虽然清单里带 family: huangguo，但界面归短剧类。
      expect(site('hongguo', category: 'shortDrama').classKey, SourceClass.shortDrama);
    });

    test('显式 group 不影响类目', () {
      // group 是「同一入口多个条目」的老用法，类目仍由 category 决定。
      expect(
        site('huangguoai', category: 'huangguo', group: 'huangguo').classKey,
        SourceClass.huangguo,
      );
    });
  });

  group('SourceGroup.byClass', () {
    test('按类目顺序分段，空类目不出现', () {
      final groups = SourceGroup.byClass([
        site('missav', category: 'adult'),
        site('custom:1'),
        site('hongguo', category: 'shortDrama'),
        site('sorani', category: 'video'),
        site('huangdou', category: 'huangguo'),
        site('huangju', category: 'shortDrama'),
      ]);
      expect(groups.map((group) => group.id), [
        SourceClass.shortDrama,
        SourceClass.video,
        SourceClass.huangguo,
        SourceClass.adult,
        SourceClass.xbpq,
      ]);
      expect(groups.first.name, '短剧类');
      expect(groups.first.sources.map((source) => source.id), ['hongguo']);
      // 黄豆与剧果都按标识归黄果类，即便清单写的是 shortDrama。
      expect(
        groups[2].sources.map((source) => source.id),
        ['huangdou', 'huangju'],
      );
      // 自定义XBPQ 添加的源单独一组，排在模块类目之后。
      expect(groups.last.name, 'XBPQ');
      expect(groups.last.sources.single.id, 'custom:1');
    });

    test('没有自定义XBPQ 源时不出现 XBPQ 分组', () {
      final groups = SourceGroup.byClass([
        site('hongguo'),
        site('sorani'),
      ]);
      expect(groups.map((group) => group.id), [
        SourceClass.shortDrama,
        SourceClass.video,
      ]);
      expect(groups.any((group) => group.id == SourceClass.xbpq), isFalse);
    });

    test('只有一个类目时仍返回一组，界面据此不画标题', () {
      final groups = SourceGroup.byClass([site('hongguo')]);
      expect(groups.length, 1);
      expect(groups.single.id, SourceClass.shortDrama);
    });
  });

  group('SourceModule 分组标签', () {
    test('category 转成中文类目名', () {
      expect(
        SourceModule.fromJson({
          'id': 'yaguo',
          'name': '鸭果',
          'category': 'shortDrama',
        }).classLabel,
        '短剧类',
      );
      expect(
        SourceModule.fromJson({
          'id': '360zy',
          'name': '360',
          'category': 'video',
        }).classLabel,
        '视频类',
      );
    });

    test('没写类目的内置模块按标识兜底，与站源菜单同一类', () {
      // 内置模块清单里没有 category，靠标识归到黄果类 / 短剧类。
      expect(SourceModule.fromJson({'id': 'huangdou', 'name': '黄豆'}).classLabel, '黄果类');
      expect(SourceModule.fromJson({'id': 'hongguo', 'name': '红果'}).classLabel, '短剧类');
    });

    test('没写或不认识的类目不显示标签', () {
      expect(SourceModule.fromJson({'id': 'x', 'name': 'x'}).classLabel, '');
      expect(
        SourceModule.fromJson({
          'id': 'x',
          'name': 'x',
          'category': 'weird',
        }).classLabel,
        '',
      );
    });
  });
}
