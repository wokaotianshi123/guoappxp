import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Windows 桌面 / 平板走 `_widePage`，手机走 `_phonePage`。
/// 上一轮只改 Go 核心的 seasons 数据，卡片条依旧不出现 —— 因为宽屏
/// 布局根本没画 `_SeasonStrip`。这个回归用例锁住「宽屏也要画」这件事，
/// 避免以后再只补数据不补 UI。
void main() {
  test('桌面 / 平板宽屏布局同样渲染「系列多季」卡片条', () {
    final source = File('lib/ui/detail/detail_page.dart').readAsStringSync();
    final wideStart = source.indexOf('Widget _widePage(');
    final wideEnd = source.indexOf('Widget _televisionPage(', wideStart);
    expect(wideStart, greaterThan(0), reason: '找不到 _widePage');
    expect(wideEnd, greaterThan(wideStart), reason: '找不到 _widePage 结束位置');
    final wide = source.substring(wideStart, wideEnd);
    expect(
      wide.contains('details.seasons.length > 1'),
      isTrue,
      reason: '宽屏布局缺少季列表显示条件',
    );
    expect(
      wide.contains('_SeasonStrip('),
      isTrue,
      reason: '宽屏布局缺少 _SeasonStrip，Windows 上永远看不到系列多季',
    );
  });

  test('手机布局仍保留季列表', () {
    final source = File('lib/ui/detail/detail_page.dart').readAsStringSync();
    final phoneStart = source.indexOf('Widget _phonePage(');
    final phoneEnd = source.indexOf('Widget _widePage(', phoneStart);
    final phone = source.substring(phoneStart, phoneEnd);
    expect(phone.contains('_SeasonStrip('), isTrue);
  });
}
