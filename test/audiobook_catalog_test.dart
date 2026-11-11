import 'package:duanju_app/ui/audiobook/audiobook_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('目录快速定位：按固定行高换算章节位置，并夹在可滚动范围内', () {
    expect(audiobookChapterOffset(0, 300, 20000), 0);
    expect(
      audiobookChapterOffset(10, 300, 20000),
      10 * audiobookChapterRowExtent,
    );
    expect(audiobookChapterOffset(299, 300, 1000), 1000);
    expect(audiobookChapterOffset(-3, 300, 1000), 0);
    expect(audiobookChapterOffset(5, 0, 1000), 0);
  });

  test('听书会话是全应用唯一实例，离开页面后仍是同一个', () {
    expect(
      identical(AudiobookSession.instance, AudiobookSession.instance),
      isTrue,
    );
    expect(AudiobookSession.instance.active, isFalse);
  });
}
