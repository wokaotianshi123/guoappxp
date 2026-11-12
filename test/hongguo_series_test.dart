import 'package:duanju_app/hongguo_series.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

Drama _hongguoDrama(String id, String title) => Drama(
  id: 'hongguo:$id',
  source: SourceSite.hongguo.id,
  sourceId: id,
  title: title,
);

void main() {
  group('红果系列剧季匹配', () {
    test('同名分季剧归到同一组，基础名不同的剧不混', () {
      final anchor = _hongguoDrama('1', '长夜将明第二季');
      final entries = hongguoSeriesEntries(anchor, [
        _hongguoDrama('2', '长夜将明第一季'),
        _hongguoDrama('3', '长夜将明第三季'),
        _hongguoDrama('4', '长夜将明之归途第二季'),
        _hongguoDrama('5', '完全无关的剧第二季'),
      ]);
      expect(entries.map((entry) => entry.season).toList(), [1, 2, 3]);
    });

    test('当前剧没写季号时按第 1 季算，后续季仍能识别', () {
      final anchor = _hongguoDrama('10', '旧城故事');
      final entries = hongguoSeriesEntries(anchor, [
        _hongguoDrama('11', '旧城故事第二季'),
        _hongguoDrama('12', '旧城故事第三季'),
      ]);
      expect(entries.length, 3);
      expect(entries.first.season, 1);
      expect(entries.first.drama.id, anchor.id);
    });

    test('只有一季时不显示系列', () {
      final anchor = _hongguoDrama('20', '单季短剧');
      expect(hongguoSeriesEntries(anchor, const []), isEmpty);
    });

    test('第X季与第X部不混为一组', () {
      final anchor = _hongguoDrama('30', '山河故人第二季');
      final entries = hongguoSeriesEntries(anchor, [
        _hongguoDrama('31', '山河故人第三季'),
        _hongguoDrama('32', '山河故人第二部'),
      ]);
      expect(entries.length, 2);
      expect(entries.every((entry) => entry.unit == '季'), isTrue);
    });
  });

  group('本季播完接下一季', () {
    test('nextSeason 指向下一季，最后一季没有下一季', () {
      final season1 = _hongguoDrama('1', '第一季');
      final season2 = _hongguoDrama('2', '第二季');
      final detail = DramaDetail(season1, const [], seasons: [
        DramaSeason(number: 1, drama: season1),
        DramaSeason(number: 2, drama: season2),
      ]);
      expect(detail.nextSeason?.drama.id, season2.id);

      final last = DramaDetail(season2, const [], seasons: detail.seasons);
      expect(last.nextSeason, isNull);
    });

    test('季列表里没有当前剧时没有下一季', () {
      final current = _hongguoDrama('9', '别的剧');
      final detail = DramaDetail(current, const [], seasons: [
        DramaSeason(number: 1, drama: _hongguoDrama('1', '第一季')),
      ]);
      expect(detail.nextSeason, isNull);
    });
  });
}
