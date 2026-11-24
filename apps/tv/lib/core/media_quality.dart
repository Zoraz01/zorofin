import 'models.dart';

/// Source-file facts (Apple `MediaQuality`), never a promise about the
/// negotiated playback output. Each file version is described separately.
class MediaQuality {
  MediaQuality._({
    this.container,
    this.video,
    this.audio,
    this.size,
    this.bitrate,
  });

  factory MediaQuality.of(
    MediaSource? source,
    List<MediaStream> streams, {
    String? container,
    int? audioIndex,
  }) {
    final audioTracks = streams.where((s) => s.type == 'Audio').toList();
    final wanted = audioIndex ?? source?.defaultAudioStreamIndex;
    return MediaQuality._(
      container: _clean(source?.container ?? container)?.toUpperCase(),
      video: streams
          .where((s) => s.type == 'Video' && !s.isAttachedPicture)
          .firstOrNull,
      audio:
          audioTracks.where((s) => s.index == wanted).firstOrNull ??
          audioTracks.where((s) => s.isDefault).firstOrNull ??
          audioTracks.firstOrNull,
      size: (source?.size ?? 0) > 0 ? source!.size : null,
      bitrate: (source?.bitrate ?? 0) > 0 ? source!.bitrate : null,
    );
  }

  final String? container;
  final MediaStream? video;
  final MediaStream? audio;
  final int? size;
  final int? bitrate;

  String? get resolution {
    final width = video?.width ?? 0;
    final height = video?.height ?? 0;
    if (video == null || (width <= 0 && height <= 0)) return null;
    // Width also recognizes cinematic crops such as 3840 × 1600.
    if (width >= 7680 || height >= 4320) return '8K';
    if (width >= 3840 || height >= 2160) return '4K';
    if (width >= 1920 || height >= 1080) {
      return video!.isInterlaced ? '1080i' : '1080p';
    }
    if (width >= 1280 || height >= 720) return '720p';
    return 'SD';
  }

  String? get dynamicRange {
    switch (video?.videoRangeType?.toUpperCase() ?? '') {
      case 'DOVI':
      case 'DOVIWITHHDR10':
      case 'DOVIWITHHLG':
      case 'DOVIWITHSDR':
      case 'DOVIWITHEL':
      case 'DOVIWITHHDR10PLUS':
      case 'DOVIWITHELHDR10PLUS':
        return 'Dolby Vision';
      case 'HDR10PLUS':
        return 'HDR10+';
      case 'HDR10':
        return 'HDR10';
      case 'HLG':
        return 'HLG';
      case 'SDR':
        return 'SDR';
    }
    // Unknown and DOVIInvalid never produce a Dolby Vision badge.
    return switch (video?.videoRange?.toUpperCase()) {
      'HDR' => 'HDR',
      'SDR' => 'SDR',
      _ => null,
    };
  }

  String? get spatialAudio {
    switch (audio?.audioSpatialFormat?.toUpperCase()) {
      case 'DOLBYATMOS':
        return 'Dolby Atmos';
      case 'DTSX':
        return 'DTS:X';
      case null:
      case '':
      case 'NONE':
        // Older servers expose this in Profile; codecs alone prove nothing.
        final profile = audio?.profile?.toUpperCase() ?? '';
        if (profile.contains('DOLBY ATMOS')) return 'Dolby Atmos';
        if (profile.contains('DTS:X')) return 'DTS:X';
        return null;
    }
    return null;
  }

  String? get audioLayout {
    final layout = _clean(audio?.channelLayout);
    if (layout != null) return layout;
    final channels = audio?.channels ?? 0;
    if (channels <= 0) return null;
    return channels == 1
        ? 'Mono'
        : channels == 2
        ? 'Stereo'
        : '$channels channels';
  }

  /// Compact badges for artwork: resolution and non-SDR range.
  List<String> get thumbnailBadges => [
    ?resolution,
    if (dynamicRange != null && dynamicRange != 'SDR')
      dynamicRange == 'Dolby Vision' ? 'DV' : dynamicRange!,
  ];

  /// Detail-page badges.
  List<String> get badges => [
    ?resolution,
    ?dynamicRange,
    ?container,
    ?_codec(video?.codec),
    ?spatialAudio,
    ?_codec(audio?.codec),
    ?audioLayout,
  ];

  /// Rows for the file information sheet.
  List<(String, String)> get facts {
    final result = <(String, String)>[];
    void add(String title, String? value) {
      if (value != null) result.add((title, value));
    }

    add('File format', container);
    if (size != null) add('File size', fileSize(size!));
    if (bitrate != null) {
      add('File bitrate', '${(bitrate! / 1000000).toStringAsFixed(1)} Mbps');
    }
    final w = video?.width ?? 0;
    final h = video?.height ?? 0;
    add('Resolution', w > 0 && h > 0 ? '$w × $h' : resolution);
    add('Video codec', _codec(video?.codec));
    add('Dynamic range', dynamicRange);
    if ((video?.bitDepth ?? 0) > 0) add('Bit depth', '${video!.bitDepth}-bit');
    final rate = video?.frameRate ?? 0;
    if (rate > 0 && rate.isFinite) {
      add(
        'Frame rate',
        '${rate.toStringAsFixed(3).replaceAll(RegExp(r'\.?0+$'), '')} fps',
      );
    }
    add('Audio codec', _codec(audio?.codec));
    add('Spatial audio', spatialAudio);
    add('Audio channels', audioLayout);
    return result;
  }

  static String fileSize(int bytes) {
    const units = ['bytes', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1000 && unit < units.length - 1) {
      value /= 1000;
      unit++;
    }
    return unit == 0
        ? '$bytes bytes'
        : '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
  }

  static String? _clean(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    return text.length > 48 ? text.substring(0, 48) : text;
  }

  static String? _codec(String? value) {
    final text = _clean(value);
    if (text == null) return null;
    return switch (text.toLowerCase()) {
      'h264' || 'avc' => 'H.264',
      'hevc' || 'h265' => 'HEVC',
      'eac3' => 'Dolby Digital Plus',
      'ac3' => 'Dolby Digital',
      'truehd' => 'TrueHD',
      _ => text.toUpperCase(),
    };
  }
}

extension MediaItemQuality on MediaItem {
  /// A series or season has no single file format.
  bool get _hasFile => !isSeries && type != 'Season' && !isLive;

  MediaQuality quality({int? audioIndex}) {
    final source = mediaSources.firstOrNull;
    if (!_hasFile) return MediaQuality.of(null, const []);
    final streams = source?.mediaStreams.isNotEmpty == true
        ? source!.mediaStreams
        : mediaStreams;
    return MediaQuality.of(
      source,
      streams,
      container: container,
      audioIndex: audioIndex,
    );
  }

  /// One entry per file version.
  List<MediaQuality> get fileQualities {
    if (!_hasFile) return const [];
    if (mediaSources.isEmpty) return [quality()];
    return [
      for (final (i, source) in mediaSources.indexed)
        MediaQuality.of(
          source,
          source.mediaStreams.isNotEmpty || i > 0
              ? source.mediaStreams
              : mediaStreams,
        ),
    ];
  }
}
