import 'package:duanju_app/live/live_models.dart';
import 'package:duanju_app/live/live_rooms.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('虎牙取流头带客户端标识与防盗链 Referer', () {
    final headers = livePlaybackHeaders(
      huyaReferer,
      userAgent: huyaLiveUserAgent,
    );
    expect(headers['Referer'], 'https://www.huya.com/');
    expect(headers['User-Agent'], startsWith('HYSDK'));
    expect(headers['User-Agent'], isNot(liveUserAgent));
  });

  test('其它房间型源仍用普通浏览器标识', () {
    expect(livePlaybackHeaders(bilibiliReferer)['User-Agent'], liveUserAgent);
    expect(livePlaybackHeaders(douyuReferer)['User-Agent'], liveUserAgent);
  });

  test('虎牙优先主线路，其次按优先级码率', () {
    final stream = {
      'baseSteamInfoList': [
        {
          'sFlvUrl': 'http://a.flv.huya.com/src',
          'sStreamName': 'n1',
          'sFlvUrlSuffix': 'flv',
          'sFlvAntiCode': 'x=1',
          'iIsMaster': 0,
          'iPCPriorityRate': 50,
        },
        {
          'sFlvUrl': 'http://b.flv.huya.com/src',
          'sStreamName': 'n2',
          'sFlvUrlSuffix': 'flv',
          'sFlvAntiCode': 'x=2',
          'iIsMaster': 1,
          'iPCPriorityRate': 0,
        },
        {
          'sFlvUrl': 'http://c.flv.huya.com/src',
          'sStreamName': 'n3',
          'sFlvUrlSuffix': 'flv',
          'sFlvAntiCode': 'x=3',
          'iIsMaster': 0,
          'iPCPriorityRate': 100,
        },
      ],
    };
    expect(huyaBestFlv(stream), 'http://b.flv.huya.com/src/n2.flv?x=2');
    expect(
      huyaBestFlv({
        'baseSteamInfoList': [
          {
            'sFlvUrl': 'http://a.flv.huya.com/src',
            'sStreamName': 'n1',
            'sFlvUrlSuffix': 'flv',
            'sFlvAntiCode': 'x=1',
            'iPCPriorityRate': 50,
          },
          {
            'sFlvUrl': 'http://c.flv.huya.com/src',
            'sStreamName': 'n3',
            'sFlvUrlSuffix': 'flv',
            'sFlvAntiCode': 'x=3',
            'iPCPriorityRate': 100,
          },
        ],
      }),
      'http://c.flv.huya.com/src/n3.flv?x=3',
    );
  });

  test('虎牙 anti-code 已带问号时不重复拼接', () {
    expect(
      huyaLineUrl({
        'sFlvUrl': 'http://a.flv.huya.com/src/',
        'sStreamName': 'n',
        'sFlvUrlSuffix': 'flv',
        'sFlvAntiCode': '?a=1',
      }),
      'http://a.flv.huya.com/src/n.flv?a=1',
    );
    expect(
      huyaLineUrl({
        'sFlvUrl': 'http://a.flv.huya.com/src',
        'sStreamName': 'n',
        'sFlvUrlSuffix': 'flv',
      }),
      'http://a.flv.huya.com/src/n.flv',
    );
  });
}
