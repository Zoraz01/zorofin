/// Player capabilities, never inferred from the UI canvas size. Unknown players
/// keep the compatibility profile. HDR and audio support are separate from 4K.
class PlaybackCapabilities {
  const PlaybackCapabilities({
    this.name = 'Compatibility',
    this.videos = const {},
    this.audio = const {'aac': 2},
    this.mkvPassthrough = const {},
    this.mkvAudioByVideo = const {},
    this.containers = 'mp4,m4v',
    this.fragmentedHls = false,
    this.pgsSubtitles = false,
    this.styledSubtitles = false,
    this.decodedAudio = const {},
  });
  final String name;

  /// The player draws PGS (Blu-ray image) subtitles itself, so the server
  /// sends the subtitle stream instead of burning it into a video transcode.
  final bool pgsSubtitles;

  /// The player draws ASS/SSA with its styling, so the server sends the
  /// original file instead of converting it to plain WebVTT.
  final bool styledSubtitles;
  final Map<String, VideoCapability> videos;
  final Map<String, int> audio;
  final Map<String, int> mkvPassthrough;

  /// MKV audio the app decodes itself (FFmpeg) when the device has neither
  /// a decoder nor passthrough for it, with the most channels it outputs.
  final Map<String, int> decodedAudio;
  final Map<String, List<String>> mkvAudioByVideo;
  final String containers;

  /// Advertise fMP4 HLS only when compatible with the server's fragment timing.
  /// Direct-file containers and decoder support are independent of this policy.
  final bool fragmentedHls;
  bool get detected => videos.isNotEmpty;
  int get maxAudioChannels => [
    ...audio.values,
    ...mkvPassthrough.values,
    ...decodedAudio.values,
  ].fold(2, (a, b) => a > b ? a : b);

  /// Samsung's Tizen 6.0+ TV decoder baseline. Use UHD only for a known UHD
  /// target. The Flutter viewport is not evidence of the panel or decoder.
  /// https://developer.samsung.com/smarttv/develop/specifications/media-specifications.html
  factory PlaybackCapabilities.samsungTv({
    bool uhd = false,
    bool q80bHdr = false,
  }) {
    return PlaybackCapabilities(
      name: uhd ? 'Samsung Tizen UHD' : 'Samsung Tizen TV',
      containers: 'mp4,m4v,mkv,ts',
      videos: {
        'h264': VideoCapability(
          width: uhd ? 3840 : 1920,
          height: uhd ? 2160 : 1080,
          fps: uhd ? 30 : 60,
          fpsAt1080: uhd ? 60 : null,
          level: uhd ? 51 : 42,
          maxBitrate: uhd ? 60000000 : 40000000,
        ),
        'hevc': VideoCapability(
          width: uhd ? 3840 : 1920,
          height: uhd ? 2160 : 1080,
          fps: 60,
          level: uhd ? 153 : 123,
          maxBitrate: uhd ? 60000000 : 40000000,
          bitDepth: 10,
          ranges: q80bHdr && uhd
              ? const [
                  'SDR',
                  'HDR10',
                  'HDR10Plus',
                  'HLG',
                  'DOVIWithHDR10',
                  'DOVIWithHDR10Plus',
                ]
              : null,
        ),
      },
      audio: const {'aac': 6, 'ac3': 6, 'eac3': 6},
      // The Flutter player draws Blu-ray and styled subtitles itself
      // (core/pgs.dart, core/ass.dart).
      pgsSubtitles: true,
      styledSubtitles: true,
    );
  }

  factory PlaybackCapabilities.fromJson(Map<String, dynamic> json) {
    final platform = json['platform'];
    if (platform == 'lg' &&
        json['packaged'] == true &&
        (int.tryParse('${json['sdkVersion']}'.split('.').first) ?? 0) >= 4) {
      final uhd = json['uhd'] == true;
      final mkv = <String, List<String>>{};
      final combinations = json['mkvAudioByVideo'];
      if (combinations is Map) {
        for (final video in ['h264', 'hevc']) {
          final reported = combinations[video];
          if (reported is! List) continue;
          final audio = [
            'aac',
            'ac3',
            'eac3',
          ].where(reported.contains).toList();
          if (audio.isNotEmpty) mkv[video] = audio;
        }
      }
      return PlaybackCapabilities(
        name: 'LG webOS',
        mkvAudioByVideo: mkv,
        containers: 'mp4,m4v,mov',
        videos: {
          'h264': VideoCapability(
            width: uhd ? 3840 : 1920,
            height: uhd ? 2160 : 1080,
            fps: uhd ? 30 : 60,
            fpsAt1080: uhd ? 60 : null,
            level: uhd ? 51 : 42,
            maxBitrate: uhd ? 50000000 : 40000000,
          ),
          'hevc': VideoCapability(
            width: uhd ? 3840 : 1920,
            height: uhd ? 2160 : 1080,
            fps: 60,
            level: uhd ? 153 : 123,
            maxBitrate: uhd ? 60000000 : 40000000,
            bitDepth: 10,
            hdr10: json['hdr10'] == true,
            ranges: [
              'SDR',
              if (json['hdr10'] == true) 'HDR10',
              if (json['dolbyVision'] == true) 'DOVI',
              if (json['hdr10'] == true && json['dolbyVisionHdr10'] == true)
                'DOVIWithHDR10',
            ],
          ),
        },
        audio: const {'aac': 6, 'ac3': 6, 'eac3': 6},
        fragmentedHls: true,
        pgsSubtitles: json['pgs'] == true,
        styledSubtitles: json['ass'] == true,
      );
    }
    if (platform == 'android' && json['videos'] is Map) {
      final videos = <String, VideoCapability>{};
      for (final codec in ['h264', 'hevc']) {
        final data = (json['videos'] as Map)[codec];
        if (data is! Map) continue;
        final width = data['width'],
            height = data['height'],
            fps = data['fps'],
            level = data['level'];
        if (width is! int ||
            height is! int ||
            fps is! num ||
            level is! int ||
            width < 1280 ||
            height < 720 ||
            fps < 24 ||
            level < 1) {
          continue;
        }
        videos[codec] = VideoCapability(
          width: width.clamp(1280, 3840),
          height: height.clamp(720, 2160),
          fps: fps.toInt().clamp(24, 60),
          level: level,
          bitDepth: codec == 'hevc' && data['main10'] == true ? 10 : 8,
          maxBitrate: data['maxBitrate'] is int
              ? (data['maxBitrate'] as int).clamp(1000000, 120000000)
              : 40000000,
        );
      }
      if (videos.isEmpty) return const PlaybackCapabilities();
      // HDR only when the screen shows it, on a Main 10 HEVC decoder: the
      // player doesn't tone-map. Dolby Vision 8.1 plays as its HDR10 layer.
      final hdr = json['hdr'] is List ? (json['hdr'] as List) : const [];
      final hevc = videos['hevc'];
      if (hevc != null && hevc.bitDepth == 10) {
        videos['hevc'] = hevc.withRanges([
          'SDR',
          if (hdr.contains('hdr10')) ...['HDR10', 'DOVIWithHDR10'],
          if (hdr.contains('hlg')) 'HLG',
          if (hdr.contains('dolbyVision') && json['dvProfile5'] == true) 'DOVI',
        ]);
      }
      final audio = <String, int>{'aac': 2};
      for (final codec in ['aac', 'ac3', 'eac3']) {
        final channels = json['audio'] is Map
            ? (json['audio'] as Map)[codec]
            : null;
        if (channels is int && channels >= 2) {
          audio[codec] = channels.clamp(2, codec == 'ac3' ? 6 : 8);
        }
      }
      final passthrough = <String, int>{};
      final route = json['mkvPassthrough'];
      if (route is Map) {
        for (final codec in ['truehd', 'dts']) {
          final count = route[codec];
          if (count == 6 || (codec == 'truehd' && count == 8)) {
            passthrough[codec] = count as int;
          }
        }
      }
      final decoded = <String, int>{
        if (json['ffmpegAudio'] is List)
          for (final codec in json['ffmpegAudio'] as List)
            if (codec == 'dts' || codec == 'truehd') codec as String: 8,
      };
      return PlaybackCapabilities(
        mkvPassthrough: passthrough,
        decodedAudio: decoded,
        name: 'Android hardware decoder',
        videos: videos,
        audio: audio,
        containers: 'mp4,m4v,mov,mkv,ts',
        // Media3 1.9.2 rejects Jellyfin fMP4 audio preroll with negative tfdt.
        // Negotiate TS HLS until the upstream parser fix is in our stable player.
        // Keep hardware/direct-file HEVC, Main10 and audio capabilities intact.
        // https://github.com/androidx/media/issues/3412
        fragmentedHls: false,
        // The Flutter player draws Blu-ray and styled subtitles itself
        // (core/pgs.dart, core/ass.dart).
        pgsSubtitles: true,
        styledSubtitles: true,
      );
    }
    return const PlaybackCapabilities();
  }
}

class VideoCapability {
  const VideoCapability({
    required this.width,
    required this.height,
    required this.fps,
    required this.level,
    this.bitDepth = 8,
    this.maxBitrate = 40000000,
    this.hdr10 = false,
    this.fpsAt1080,
    this.ranges,
  });
  final int width, height, fps, level, bitDepth, maxBitrate;
  final bool hdr10;

  /// Jellyfin VideoRangeType values this decoder and screen show.
  final List<String>? ranges;
  String get rangeTypes => ranges?.join('|') ?? (hdr10 ? 'SDR|HDR10' : 'SDR');

  VideoCapability withRanges(List<String> ranges) => VideoCapability(
    width: width,
    height: height,
    fps: fps,
    level: level,
    bitDepth: bitDepth,
    maxBitrate: maxBitrate,
    hdr10: ranges.contains('HDR10'),
    fpsAt1080: fpsAt1080,
    ranges: ranges,
  );

  /// Some decoders support 1080p60 but only 4K30 for the same codec.
  final int? fpsAt1080;
}
