import 'dart:math' as math;
import 'dart:ui' show Size;

import 'catalog_sort.dart';
import 'video_enhancement_preferences.dart';

const playbackSpeeds = [.5, .75, 1.0, 1.25, 1.5, 2.0, 3.0];
const danmakuColors = [
  0xFFFFFFFF,
  0xFFFFE066,
  0xFF66E0FF,
  0xFFFF8FB8,
  0xFF8CF08C,
];

enum TelevisionDecoder { optimized, hardware, software }

enum DanmakuCoverage {
  quarter(.25, '顶部四分之一'),
  half(.5, '顶部一半'),
  full(1, '全部');

  const DanmakuCoverage(this.fraction, this.label);

  final double fraction;
  final String label;
}

/// 画面比例：4:3 / 16:9 里的 4 和 16 指长边，竖屏视频按 3:4、9:16 显示。
enum VideoFit {
  auto('自动'),
  stretch('拉伸'),
  crop('裁切'),
  fitWidth('等宽'),
  fitHeight('等高'),
  original('原始'),
  ratio4x3('4:3'),
  ratio16x9('16:9');

  const VideoFit(this.label);

  final String label;

  Size size(Size box, Size video, double pixelRatio) {
    final aspect = video.width / video.height;
    double long(double ratio) => aspect < 1 ? 1 / ratio : ratio;
    Size fit(double aspect, double Function(double, double) pick) {
      final height = pick(box.height, box.width / aspect);
      return Size(height * aspect, height);
    }

    return switch (this) {
      auto => fit(aspect, math.min),
      stretch => box,
      crop => fit(aspect, math.max),
      fitWidth => Size(box.width, box.width / aspect),
      fitHeight => Size(box.height * aspect, box.height),
      original => video / pixelRatio,
      ratio4x3 => fit(long(4 / 3), math.min),
      ratio16x9 => fit(long(16 / 9), math.min),
    };
  }
}

const danmakuScaleMin = .6;
const danmakuScaleMax = 2.0;

const danmakuStrokeMin = 0.0;
const danmakuStrokeMax = 6.0;

const danmakuShadowMin = 0.0;
const danmakuShadowMax = 12.0;

const danmakuWordLength = 40;
const danmakuWordLimit = 60;

class PlaybackPreferences {
  const PlaybackPreferences({
    this.speed = 1,
    this.quality = 0,
    this.autoAdvance = true,
    this.danmaku = true,
    this.danmakuScale = 1,
    this.danmakuColor = 0xFFFFFFFF,
    this.danmakuOpacity = 1,
    this.danmakuBold = true,
    this.danmakuStroke = 0,
    this.danmakuShadow = 3,
    this.danmakuCoverage = DanmakuCoverage.half,
    this.danmakuWords = const [],
    this.preload = true,
    this.adBlock = true,
    this.enhancement = const VideoEnhancementPreferences(),
    this.televisionDecoder = TelevisionDecoder.optimized,
    this.swipeEpisodes = false,
    this.progressLine = true,
    this.videoFit = VideoFit.auto,
  });

  final double speed;
  final int quality;
  final bool autoAdvance;
  final bool danmaku;
  final double danmakuScale;
  final int danmakuColor;
  final double danmakuOpacity;
  final bool danmakuBold;
  final double danmakuStroke;
  final double danmakuShadow;
  final DanmakuCoverage danmakuCoverage;
  final List<String> danmakuWords;
  final bool preload;

  /// 解析时是否尝试跳过源站片头广告；关闭后直接播放原始视频流。
  final bool adBlock;
  final VideoEnhancementPreferences enhancement;
  final TelevisionDecoder televisionDecoder;

  /// 手机 / 平板横屏全屏时上下滑动切集；需先关闭「滑动调节亮度 / 音量」。
  final bool swipeEpisodes;

  /// 横屏播放时底部是否显示一条随进度走的细进度线。
  final bool progressLine;

  /// 画面比例，切换后全局记住。
  final VideoFit videoFit;

  PlaybackPreferences copyWith({
    double? speed,
    int? quality,
    bool? autoAdvance,
    bool? danmaku,
    double? danmakuScale,
    int? danmakuColor,
    double? danmakuOpacity,
    bool? danmakuBold,
    double? danmakuStroke,
    double? danmakuShadow,
    DanmakuCoverage? danmakuCoverage,
    List<String>? danmakuWords,
    bool? preload,
    bool? adBlock,
    VideoEnhancementPreferences? enhancement,
    TelevisionDecoder? televisionDecoder,
    bool? swipeEpisodes,
    bool? progressLine,
    VideoFit? videoFit,
  }) => PlaybackPreferences(
    speed: speed ?? this.speed,
    quality: quality ?? this.quality,
    autoAdvance: autoAdvance ?? this.autoAdvance,
    danmaku: danmaku ?? this.danmaku,
    danmakuScale: danmakuScale ?? this.danmakuScale,
    danmakuColor: danmakuColor ?? this.danmakuColor,
    danmakuOpacity: danmakuOpacity ?? this.danmakuOpacity,
    danmakuBold: danmakuBold ?? this.danmakuBold,
    danmakuStroke: danmakuStroke ?? this.danmakuStroke,
    danmakuShadow: danmakuShadow ?? this.danmakuShadow,
    danmakuCoverage: danmakuCoverage ?? this.danmakuCoverage,
    danmakuWords: danmakuWords ?? this.danmakuWords,
    preload: preload ?? this.preload,
    adBlock: adBlock ?? this.adBlock,
    enhancement: enhancement ?? this.enhancement,
    televisionDecoder: televisionDecoder ?? this.televisionDecoder,
    swipeEpisodes: swipeEpisodes ?? this.swipeEpisodes,
    progressLine: progressLine ?? this.progressLine,
    videoFit: videoFit ?? this.videoFit,
  );

  Map<String, dynamic> toJson() => {
    'speed': speed,
    'quality': quality,
    'autoAdvance': autoAdvance,
    'danmaku': danmaku,
    'danmakuScale': danmakuScale,
    'danmakuColor': danmakuColor,
    'danmakuOpacity': danmakuOpacity,
    'danmakuBold': danmakuBold,
    'danmakuStroke': danmakuStroke,
    'danmakuShadow': danmakuShadow,
    'danmakuCoverage': danmakuCoverage.name,
    'danmakuWords': danmakuWords,
    'preload': preload,
    'adBlock': adBlock,
    'enhancement': enhancement.toJson(),
    'televisionDecoder': televisionDecoder.name,
    'swipeEpisodes': swipeEpisodes,
    'progressLine': progressLine,
    'videoFit': videoFit.name,
  };

  factory PlaybackPreferences.fromJson(Map<String, dynamic> value) {
    final speed = (value['speed'] as num? ?? 1).toDouble();
    final quality = value['quality'] as int? ?? 0;
    final autoAdvance = value['autoAdvance'] as bool? ?? true;
    final danmaku = value['danmaku'] as bool? ?? true;
    final preload = value['preload'] as bool? ?? true;
    final adBlock = value['adBlock'] as bool? ?? true;
    if (!playbackSpeeds.contains(speed) || quality < 0 || quality > 4320) {
      throw const FormatException('播放偏好无效');
    }
    return PlaybackPreferences(
      speed: speed,
      quality: quality,
      autoAdvance: autoAdvance,
      danmaku: danmaku,
      danmakuScale: (value['danmakuScale'] as num? ?? 1).toDouble().clamp(
        danmakuScaleMin,
        danmakuScaleMax,
      ),
      danmakuColor: danmakuColors.contains(value['danmakuColor'])
          ? value['danmakuColor'] as int
          : 0xFFFFFFFF,
      danmakuOpacity: (value['danmakuOpacity'] as num? ?? 1).toDouble().clamp(
        0.1,
        1.0,
      ),
      danmakuBold: value['danmakuBold'] as bool? ?? true,
      danmakuStroke: (value['danmakuStroke'] as num? ?? 0).toDouble().clamp(
        danmakuStrokeMin,
        danmakuStrokeMax,
      ),
      danmakuShadow: (value['danmakuShadow'] as num? ?? 3).toDouble().clamp(
        danmakuShadowMin,
        danmakuShadowMax,
      ),
      danmakuCoverage:
          DanmakuCoverage.values.asNameMap()[value['danmakuCoverage']] ??
          DanmakuCoverage.half,
      danmakuWords: normalizeDanmakuWords(value['danmakuWords']),
      preload: preload,
      adBlock: adBlock,
      enhancement: VideoEnhancementPreferences.fromJson(value['enhancement']),
      televisionDecoder:
          TelevisionDecoder.values.asNameMap()[value['televisionDecoder']] ??
          TelevisionDecoder.optimized,
      swipeEpisodes: value['swipeEpisodes'] as bool? ?? false,
      progressLine: value['progressLine'] as bool? ?? true,
      videoFit:
          VideoFit.values.asNameMap()[value['videoFit']] ?? VideoFit.auto,
    );
  }
}

List<String> normalizeDanmakuWords(Object? value) {
  if (value is! List) return const [];
  final words = <String>[];
  final keys = <String>{};
  for (final entry in value) {
    if (entry is! String) continue;
    final word = entry.trim();
    if (word.length > danmakuWordLength) continue;
    final key = normalizedSearchText(word);
    if (key.isEmpty || !keys.add(key)) continue;
    words.add(word);
    if (words.length >= danmakuWordLimit) break;
  }
  return List.unmodifiable(words);
}
