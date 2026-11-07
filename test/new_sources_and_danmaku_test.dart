import 'package:duanju_app/danmaku_style.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/player/danmaku_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  test('新增的三个站源只在真果鉴出现且默认关闭', () {
    for (final id in ['jinguoduanju', 'jinguo', 'heitao']) {
      final site = SourceSite.byId(id);
      expect(site.id, id);
      // 放进 restrictedValues = 站源管理里默认关闭，用户可手动打开。
      expect(SourceSite.isRestricted(id), isTrue, reason: '$id 应默认关闭');
      expect(site.onlineSearch, isTrue, reason: '$id 应支持在线搜索');
    }
    expect(SourceSite.byId('jinguoduanju').name, '禁果短剧');
    expect(SourceSite.byId('jinguo').name, '禁果');
    expect(SourceSite.byId('heitao').name, '黑桃');
  });

  test('站点角标随 Drama 读写与合并', () {
    const drama = Drama(
      id: 'heitao:42',
      source: 'heitao',
      title: '示例剧',
      badge: '6集',
      score: '9.2',
    );
    final restored = Drama.fromJson(drama.toJson());
    expect(restored.badge, '6集');
    expect(restored.score, '9.2');
    expect(restored.toJson()['badge'], '6集');

    // 看过详情后如果没有站点角标，保留旧的；新角标优先。
    final merged = drama.merge(
      const Drama(id: 'heitao:42', source: 'heitao', title: '示例剧'),
    );
    expect(merged.badge, '6集');
    expect(merged.score, '9.2');
    final replaced = drama.merge(
      const Drama(
        id: 'heitao:42',
        source: 'heitao',
        title: '示例剧',
        badge: '完整版',
      ),
    );
    expect(replaced.badge, '完整版');
  });

  test('弹幕样式由播放偏好构造，显示区域三档', () {
    const preferences = PlaybackPreferences(
      danmakuScale: 1.6,
      danmakuColor: 0xFFFFE066,
      danmakuOpacity: .5,
      danmakuBold: false,
      danmakuStroke: 2,
      danmakuShadow: 0,
      danmakuCoverage: DanmakuCoverage.quarter,
    );
    final style = DanmakuStyle.of(preferences);
    expect(style.scale, 1.6);
    expect(style.color, const Color(0xFFFFE066));
    expect(style.opacity, .5);
    expect(style.bold, isFalse);
    expect(style.hasStroke, isTrue);
    expect(style.hasShadow, isFalse);
    expect(style.coverage.fraction, .25);
    expect(DanmakuCoverage.half.fraction, .5);
    expect(DanmakuCoverage.full.fraction, 1);
    expect(danmakuScaleMin, .6);
    expect(danmakuScaleMax, 2.0);
  });

  testWidgets('弹幕样式面板提供全部可调项', (tester) async {
    await tester.pumpWidget(
      AppScope(
        repository: FakeRepository(),
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DanmakuSettings(
                preferences: const PlaybackPreferences(),
                save: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    for (final label in [
      '字号',
      '透明度',
      '加粗',
      '描边',
      '阴影',
      '显示区域',
      '顶部四分之一',
      '顶部一半',
      '全部',
    ]) {
      expect(find.text(label), findsWidgets, reason: '缺少 $label');
    }
  });
}
