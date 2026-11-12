import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/ui/audiobook/audiobook_fanqie.dart';

void main() {
  group('有声书类型标签', () {
    test('有主播名的是真人录音', () {
      expect(fanqieVoiceMode('金火火o'), '真人录音');
      expect(fanqieVoiceMode('众创众阅'), '真人录音');
      expect(fanqieVoiceMode('  午夜的昙花  '), '真人录音');
    });

    test('没有主播名的按 AI 朗读标注', () {
      expect(fanqieVoiceMode(''), 'AI 朗读');
      expect(fanqieVoiceMode('   '), 'AI 朗读');
    });

    test('官方 AI 音色账号不当作真人', () {
      expect(fanqieVoiceMode('番茄畅听AI'), 'AI 朗读');
      expect(fanqieVoiceMode('智能语音'), 'AI 朗读');
      expect(fanqieVoiceMode('TTS 合成'), 'AI 朗读');
    });
  });

  group('听书书源', () {
    test('两个书源：默认红果听书，其次番茄听书', () {
      expect(fanqieAudiobookOrigins.map((item) => item.name).toList(), [
        '红果听书',
        '番茄听书',
      ]);
      expect(fanqieAudiobookOrigins.first.type, 0);
      expect(fanqieAudiobookOrigins[1].type, 1);
    });
  });
}
