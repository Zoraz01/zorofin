import 'errors.dart';
import 'playback_capabilities.dart';
import 'jellyfin_client.dart';
import 'models.dart';

/// Starts playback of an item, optionally from a position and with the
/// tracks chosen on the details page (null keeps each default).
typedef PlayItem =
    Future<void> Function(
      MediaItem item, {
      int? startTicks,
      int? audioIndex,
      int? subtitleIndex,
      bool? burnSubtitles,
    });

/// Optional Jellyfin media segments. A missing provider leaves the player
/// usable; only validated intro markers inside this title can offer a seek.
typedef IntroSegment = ({Duration start, Duration end});

extension IntroMarkers on JellyfinClient {
  Future<List<IntroSegment>> introSegments(String id) async {
    final page = await requestJson(
      ['MediaSegments', id],
      query: {'includeSegmentTypes': 'Intro'},
    );
    if (page is! Map || page['Items'] is! List) return [];
    return [
      for (final entry in page['Items'])
        if (entry case {
          'Type': 'Intro',
          'StartTicks': int start,
          'EndTicks': int end,
        } when start >= 0 && end > start)
          (start: MediaTime.duration(start), end: MediaTime.duration(end)),
    ];
  }
}

Duration? introEndAt(
  List<IntroSegment> segments,
  Duration at,
  Duration? duration,
) {
  if (duration == null) return null;
  for (final intro in segments) {
    if (intro.start <= at && at < intro.end && intro.end < duration) {
      return intro.end;
    }
  }
  return null;
}

class PlaybackOptions {
  PlaybackOptions({
    int startTicks = 0,
    int bitrate = 40000000,
    this.audioIndex,
    this.subtitleIndex = automatic,
    this.burnSubtitles = false,
    this.allowDirectPlay = true,
    this.selectAudioOnDevice = false,
    this.capabilities = const PlaybackCapabilities(),
  }) : startTicks = startTicks < 0 ? 0 : startTicks,
       bitrate = bitrate.clamp(1000000, 120000000);

  /// Let the account's subtitle defaults choose (Apple uses the same -2).
  static const automatic = -2;

  final int startTicks;
  final int bitrate;
  final PlaybackCapabilities capabilities;
  final bool allowDirectPlay;
  final bool selectAudioOnDevice;

  /// Null lets the server pick its default audio track.
  final int? audioIndex;

  /// -1 is off; [automatic] follows the account defaults.
  final int subtitleIndex;

  /// Image subtitles are burned in by the server. Text subtitles are
  /// delivered separately and drawn by the app, so they can be styled and
  /// do not prevent direct play.
  final bool burnSubtitles;

  /// Whether choosing [stream] needs the server to burn it into the video:
  /// image subtitles this player can't draw itself.
  bool burnsIn(MediaStream? stream) =>
      stream != null &&
      !stream.isTextSubtitle &&
      !(stream.isPgs && capabilities.pgsSubtitles);

  /// The detail page chooses a track before the device renderer is probed.
  PlaybackOptions withDeviceCapabilities(
    PlaybackCapabilities device,
    MediaItem item,
  ) {
    final detected = copyWith(capabilities: device);
    if (subtitleIndex < 0) return detected;
    final sourceTracks = item.mediaSources.firstOrNull?.mediaStreams;
    final tracks = sourceTracks != null && sourceTracks.isNotEmpty
        ? sourceTracks
        : item.mediaStreams;
    final selected = tracks
        .where((s) => s.type == 'Subtitle' && s.index == subtitleIndex)
        .firstOrNull;
    return selected == null
        ? detected
        : detected.copyWith(burnSubtitles: detected.burnsIn(selected));
  }

  bool get needsTranscode =>
      (audioIndex != null && !selectAudioOnDevice) ||
      (subtitleIndex >= 0 && burnSubtitles);

  PlaybackOptions copyWith({
    int? startTicks,
    int? bitrate,
    int? Function()? audioIndex,
    int? subtitleIndex,
    bool? burnSubtitles,
    bool? allowDirectPlay,
    bool? selectAudioOnDevice,
    PlaybackCapabilities? capabilities,
  }) => PlaybackOptions(
    startTicks: startTicks ?? this.startTicks,
    bitrate: bitrate ?? this.bitrate,
    audioIndex: audioIndex == null ? this.audioIndex : audioIndex(),
    subtitleIndex: subtitleIndex ?? this.subtitleIndex,
    burnSubtitles: burnSubtitles ?? this.burnSubtitles,
    allowDirectPlay: allowDirectPlay ?? this.allowDirectPlay,
    selectAudioOnDevice: selectAudioOnDevice ?? this.selectAudioOnDevice,
    capabilities: capabilities ?? this.capabilities,
  );

  /// Whether switching to [other] needs a new stream. Changing between text
  /// subtitles, or turning them off, does not.
  bool sameStream(PlaybackOptions other) =>
      bitrate == other.bitrate &&
      allowDirectPlay == other.allowDirectPlay &&
      audioIndex == other.audioIndex &&
      burnSubtitles == other.burnSubtitles &&
      (!burnSubtitles || subtitleIndex == other.subtitleIndex);
}

/// Device-detected formats with a compatibility profile for unknown players.
class PlaybackProfile {
  static Map<String, Object?> conservative(int bitrate) {
    Map<String, Object?> condition(
      String property,
      String value, [
      String comparison = 'LessThanEqual',
    ]) => {
      'Property': property,
      'Value': value,
      'Condition': comparison,
      'IsRequired': true,
    };
    return {
      'Name': 'Zorofin TV SDR',
      'MaxStreamingBitrate': bitrate,
      'MaxStaticBitrate': bitrate,
      'DirectPlayProfiles': [
        {
          'Type': 'Video',
          'Container': 'mp4,m4v',
          'VideoCodec': 'h264',
          'AudioCodec': 'aac',
        },
      ],
      'TranscodingProfiles': [
        {
          'Type': 'Video',
          'Container': 'ts',
          'Protocol': 'hls',
          'VideoCodec': 'h264',
          'AudioCodec': 'aac',
          'Context': 'Streaming',
          'MaxAudioChannels': '2',
          'MinSegments': 2,
          'SegmentLength': 4,
          'CopyTimestamps': false,
          'EnableSubtitlesInManifest': false,
        },
      ],
      'CodecProfiles': [
        {
          'Type': 'Video',
          'Codec': 'h264',
          'Conditions': [
            condition('VideoBitDepth', '8'),
            condition('Width', '1920'),
            condition('Height', '1080'),
            condition('VideoLevel', '41'),
            condition('VideoFramerate', '30'),
            condition(
              'VideoProfile',
              'high|main|baseline|constrained baseline',
              'EqualsAny',
            ),
            condition('VideoRangeType', 'SDR', 'Equals'),
            condition('IsInterlaced', 'false', 'Equals'),
          ],
        },
        {
          'Type': 'VideoAudio',
          'Codec': 'aac',
          'Conditions': [condition('AudioChannels', '2')],
        },
      ],
      'ContainerProfiles': <Object>[],
      // Text subtitles come as WebVTT the app draws; image subtitles are
      // burned in during a transcode.
      'SubtitleProfiles': [
        {'Format': 'vtt', 'Method': 'External'},
        for (final f in ['pgssub', 'dvdsub', 'dvbsub', 'pgs'])
          {'Format': f, 'Method': 'Encode'},
      ],
    };
  }

  static Map<String, Object?> forDevice(PlaybackOptions options) {
    final c = options.capabilities;
    final profile = conservative(options.bitrate);
    if (!c.detected) return profile;
    Map<String, Object?> condition(
      String key,
      String value, [
      String op = 'LessThanEqual',
    ]) => {
      'Property': key,
      'Value': value,
      'Condition': op,
      'IsRequired': true,
    };
    profile['Name'] = 'Zorofin ${c.name}';
    if (c.pgsSubtitles || c.styledSubtitles) {
      // What the player draws itself comes as the original track; other
      // image formats are still burned in.
      profile['SubtitleProfiles'] = [
        {'Format': 'vtt', 'Method': 'External'},
        if (c.styledSubtitles)
          for (final f in ['ass', 'ssa']) {'Format': f, 'Method': 'External'},
        for (final f in ['pgssub', 'pgs'])
          {'Format': f, 'Method': c.pgsSubtitles ? 'External' : 'Encode'},
        for (final f in ['dvdsub', 'dvbsub']) {'Format': f, 'Method': 'Encode'},
      ];
    }
    profile['DirectPlayProfiles'] = [
      {
        'Type': 'Video',
        'Container': c.containers,
        'VideoCodec': c.videos.keys.join(','),
        'AudioCodec': c.audio.keys.join(','),
      },
      for (final entry in c.mkvAudioByVideo.entries)
        {
          'Type': 'Video',
          'Container': 'mkv',
          'VideoCodec': entry.key,
          'AudioCodec': entry.value.join(','),
        },
      if (c.mkvPassthrough.isNotEmpty || c.decodedAudio.isNotEmpty)
        {
          'Type': 'Video',
          'Container': 'mkv',
          'VideoCodec': c.videos.keys.join(','),
          'AudioCodec': {
            ...c.mkvPassthrough.keys,
            ...c.decodedAudio.keys,
          }.join(','),
        },
    ];
    profile['CodecProfiles'] = [
      for (final entry in c.videos.entries)
        {
          'Type': 'Video',
          'Codec': entry.key,
          'Conditions': [
            condition('Width', '${entry.value.width}'),
            condition('Height', '${entry.value.height}'),
            condition(
              'VideoFramerate',
              '${entry.value.fpsAt1080 ?? entry.value.fps}',
            ),
            condition('VideoLevel', '${entry.value.level}'),
            condition('VideoBitDepth', '${entry.value.bitDepth}'),
            condition('VideoBitrate', '${entry.value.maxBitrate}'),
            condition(
              'VideoProfile',
              entry.key == 'hevc'
                  ? 'main|main 10'
                  : 'high|main|baseline|constrained baseline',
              'EqualsAny',
            ),
            condition('VideoRangeType', entry.value.rangeTypes, 'EqualsAny'),
            condition('IsInterlaced', 'false', 'Equals'),
          ],
        },
      // The LG Dolby Vision probe tests MP4. A positive Matroska codec
      // result alone cannot establish Dolby Vision signaling in that container.
      if (c.mkvAudioByVideo.containsKey('hevc'))
        {
          'Type': 'Video',
          'Codec': 'hevc',
          'Container': 'mkv',
          'Conditions': [
            condition(
              'VideoRangeType',
              c.videos['hevc']!.hdr10 ? 'SDR|HDR10' : 'SDR',
              'EqualsAny',
            ),
          ],
        },
      // LG H.264 supports 1080p60 and 4K30. Restrict either oversized
      // dimension without imposing the 4K frame-rate cap on HD sports.
      for (final entry in c.videos.entries)
        if (entry.value.fpsAt1080 != null)
          for (final edge in {'Width': 1921, 'Height': 1081}.entries)
            {
              'Type': 'Video',
              'Codec': entry.key,
              'ApplyConditions': [
                condition(edge.key, '${edge.value}', 'GreaterThanEqual'),
              ],
              'Conditions': [condition('VideoFramerate', '${entry.value.fps}')],
            },
      // Passthrough-only formats are limited to what the receiver takes;
      // formats the app also decodes play whatever their layout.
      for (final entry in c.mkvPassthrough.entries)
        if (!c.decodedAudio.containsKey(entry.key))
          {
            'Type': 'VideoAudio',
            'Codec': entry.key,
            'Conditions': [
              condition('AudioChannels', '${entry.value}'),
              condition('AudioSampleRate', '48000', 'Equals'),
              if (entry.key == 'dts')
                condition('AudioProfile', 'DTS', 'Equals'),
            ],
          },
      for (final entry in c.audio.entries)
        {
          'Type': 'VideoAudio',
          'Codec': entry.key,
          'Conditions': [condition('AudioChannels', '${entry.value}')],
        },
    ];
    final transcode = (profile['TranscodingProfiles'] as List).first as Map;
    transcode['Container'] = c.fragmentedHls ? 'mp4' : 'ts';
    transcode['VideoCodec'] = c.videos.keys.join(',');
    // AAC first for conversion. Let Jellyfin copy compatible surround tracks
    // when a container, track selection or subtitle requires HLS.
    transcode['AudioCodec'] = c.audio.keys
        .where((codec) => const {'aac', 'ac3', 'eac3'}.contains(codec))
        .join(',');
    // Converted audio stops at 5.1. Decoders that list 8 AAC channels often
    // fail on 7.1 AAC in HLS, and the stream then never starts; 7.1 tracks
    // the device plays itself are not converted and keep every channel.
    transcode['MaxAudioChannels'] = c.audio.values
        .fold(2, (a, b) => a > b ? a : b)
        .clamp(2, 6)
        .toString();
    // Live sources using UseMostCompatibleTranscodingProfile require TS HLS.
    // Keep fragmented MP4 first for VOD and HEVC; offer H264/AAC as fallback.
    if (c.fragmentedHls) {
      (profile['TranscodingProfiles'] as List).add(<String, Object>{
        ...transcode,
        'Container': 'ts',
        'VideoCodec': 'h264',
        'AudioCodec': 'aac',
        'MaxAudioChannels': '2',
      });
    }
    return profile;
  }

  static Map<String, Object?> request(String userId, PlaybackOptions options) =>
      {
        'UserId': userId,
        'StartTimeTicks': options.startTicks,
        'MaxStreamingBitrate': options.bitrate,
        'MaxAudioChannels': options.capabilities.maxAudioChannels,
        'DeviceProfile': forDevice(options),
        if (options.subtitleIndex >= -1)
          'SubtitleStreamIndex': options.subtitleIndex,
        'AudioStreamIndex': ?options.audioIndex,
        'EnableDirectPlay': options.allowDirectPlay && !options.needsTranscode,
        // Keep remux-only viewers eligible for HLS negotiation. PlaybackPlan
        // still rejects HTTP-only conversion returned by the server.
        'EnableDirectStream': true,
        'EnableTranscoding': true,
        'AllowVideoStreamCopy': true,
        'AllowAudioStreamCopy': true,
        'AutoOpenLiveStream': false,
        'AlwaysBurnInSubtitleWhenTranscoding': false,
      };
}

class PlaybackPlan {
  PlaybackPlan._({
    required this.itemId,
    required this.sourceId,
    required this.sessionId,
    required this.url,
    required this.method,
    required this.options,
    this.liveStreamId,
    this.streams = const [],
    this.source,
  });

  final String itemId;
  final String sourceId;
  final String sessionId;
  final Uri url;
  final String method;
  final PlaybackOptions options;
  final String? liveStreamId;

  /// Tracks in the chosen source, for the audio and subtitle choices.
  final List<MediaStream> streams;

  /// The chosen source, with the server's per-viewer track defaults.
  final MediaSource? source;

  String get mimeType => method != 'DirectPlay'
      ? 'application/x-mpegURL'
      : switch (source?.container?.toLowerCase()) {
          'mkv' => 'video/x-matroska',
          'ts' || 'mpegts' => 'video/mp2t',
          'mov' => 'video/quicktime',
          _ => 'video/mp4',
        };

  /// WebVTT for a text subtitle track of this source.
  /// The server's address for a PGS stream the player draws itself, or null
  /// when the player can't, the stream isn't PGS or the server didn't offer it.
  /// Whether choosing [stream] needs the server to burn it into the video.
  bool burnsIn(MediaStream? stream) => options.burnsIn(stream);

  String? imageSubtitleUrl(int index) {
    if (!options.capabilities.pgsSubtitles) return null;
    final stream = streams
        .where((s) => s.type == 'Subtitle' && s.index == index)
        .firstOrNull;
    if (stream == null || !stream.isPgs) return null;
    final url = stream.deliveryUrl;
    return url == null || url.isEmpty ? null : url;
  }

  /// The original ASS/SSA file, for players that keep its styling.
  List<String>? styledSubtitlePath(int index) {
    if (!options.capabilities.styledSubtitles) return null;
    final stream = streams
        .where((s) => s.type == 'Subtitle' && s.index == index)
        .firstOrNull;
    if (stream == null || !stream.isStyled) return null;
    return [
      'Videos',
      itemId,
      sourceId,
      'Subtitles',
      '$index',
      '0',
      'Stream.${stream.codec!.toLowerCase()}',
    ];
  }

  List<String>? subtitlePath(int index) {
    final stream = streams
        .where((s) => s.type == 'Subtitle' && s.index == index)
        .firstOrNull;
    if (stream == null || !stream.isTextSubtitle) return null;
    return [
      'Videos',
      itemId,
      sourceId,
      'Subtitles',
      '$index',
      '0',
      'Stream.vtt',
    ];
  }

  static PlaybackPlan make(
    PlaybackInfo info, {
    required String itemId,
    required JellyfinClient client,
    required PlaybackOptions options,
  }) {
    final session = client.session;
    if (session != null && session.server != client.server) {
      throw const ClientError(ClientErrorKind.unsafeUrl);
    }
    final source = info.mediaSources.isEmpty ? null : info.mediaSources.first;
    final sourceId = source?.id;
    final playSessionId = info.playSessionId;
    if (info.errorCode != null ||
        session == null ||
        source == null ||
        sourceId == null ||
        playSessionId == null ||
        (source.requiresOpening == true && source.liveStreamId == null)) {
      throw const ClientError(ClientErrorKind.unsupportedPlayback);
    }
    final String method;
    final Uri target;
    final reference = source.transcodingUrl;
    if (options.allowDirectPlay &&
        !options.needsTranscode &&
        source.supportsDirectPlay == true) {
      method = 'DirectPlay';
      final direct = client.server.endpoint(
        ['Videos', itemId, 'stream'],
        {
          'static': 'true',
          'MediaSourceId': sourceId,
          'DeviceId': client.identity.deviceId,
          'PlaySessionId': playSessionId,
          if (source.liveStreamId != null) 'LiveStreamId': source.liveStreamId!,
        },
      );
      target = client.server.mediaUrl(direct.toString(), session.token);
    } else if ((source.supportsTranscoding == true ||
            source.supportsDirectStream == true) &&
        reference != null &&
        (source.transcodingSubProtocol != null
            ? source.transcodingSubProtocol!.toLowerCase() == 'hls'
            : Uri.tryParse(reference)?.path.toLowerCase().endsWith('.m3u8') ==
                  true)) {
      method = 'Transcode';
      target = client.server.mediaUrl(reference, session.token);
    } else {
      throw const ClientError(ClientErrorKind.unsupportedPlayback);
    }
    return PlaybackPlan._(
      itemId: itemId,
      sourceId: sourceId,
      sessionId: playSessionId,
      url: target,
      method: method,
      options: options,
      liveStreamId: source.liveStreamId,
      streams: source.mediaStreams,
      source: source,
    );
  }

  Map<String, Object?> report({
    required int positionTicks,
    required bool paused,
    bool canSeek = true,
  }) => {
    'ItemId': itemId,
    'MediaSourceId': sourceId,
    'PlaySessionId': sessionId,
    'PositionTicks': positionTicks < 0 ? 0 : positionTicks,
    'IsPaused': paused,
    'CanSeek': canSeek,
    'PlayMethod': method,
    'SubtitleStreamIndex': options.subtitleIndex < -1
        ? -1
        : options.subtitleIndex,
    'AudioStreamIndex': ?options.audioIndex,
    if (liveStreamId != null) 'LiveStreamId': liveStreamId,
  };
}

extension PlaybackApi on JellyfinClient {
  /// Negotiate first, then open only a selected live source. Browsing never
  /// reserves a tuner. Any failure after Open releases the acquired session.
  Future<PlaybackPlan> preparePlayback(
    MediaItem item,
    PlaybackOptions options,
  ) async {
    var info = await playbackInfo(item, options);
    String? opened;
    try {
      final source = info.mediaSources.firstOrNull;
      if (info.errorCode == null &&
          source?.requiresOpening == true &&
          source?.liveStreamId == null) {
        if (source?.openToken == null || info.playSessionId == null) {
          throw const ClientError(ClientErrorKind.unsupportedPlayback);
        }
        final data = await requestJson(
          ['LiveStreams', 'Open'],
          method: 'POST',
          body: {
            ...PlaybackProfile.request(session!.viewer.id, options),
            'OpenToken': source!.openToken,
            'PlaySessionId': info.playSessionId,
            'ItemId': item.id,
          },
        );
        if (data is! Map<String, dynamic> ||
            data['MediaSource'] is! Map<String, dynamic>) {
          throw const ClientError(ClientErrorKind.invalidResponse);
        }
        final live = MediaSource.fromJson(
          data['MediaSource'] as Map<String, dynamic>,
        );
        opened = live.liveStreamId;
        info = PlaybackInfo(
          mediaSources: [live],
          playSessionId: info.playSessionId,
        );
      }
      return PlaybackPlan.make(
        info,
        itemId: item.id,
        client: this,
        options: options,
      );
    } catch (_) {
      if (opened != null) {
        try {
          await closeLive(opened);
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> closeLive(String id) async {
    await requestText(
      ['LiveStreams', 'Close'],
      method: 'POST',
      query: {'liveStreamId': id},
    );
  }

  Future<PlaybackInfo> playbackInfo(
    MediaItem item,
    PlaybackOptions options,
  ) async {
    final current = session;
    if (current == null) {
      throw const ClientError(ClientErrorKind.missingSession);
    }
    // Track selections only apply when the request names a media source;
    // discover it when the item metadata has none.
    var sourceId = item.isLive
        ? null
        : (item.mediaSources.isEmpty ? null : item.mediaSources.first.id);
    if (sourceId == null || sourceId.isEmpty) {
      final discovered = await request(
        PlaybackInfo.fromJson,
        ['Items', item.id, 'PlaybackInfo'],
        query: {'userId': current.viewer.id},
      );
      sourceId = discovered.mediaSources.isEmpty
          ? null
          : discovered.mediaSources.first.id;
      if (discovered.errorCode != null ||
          sourceId == null ||
          sourceId.isEmpty) {
        throw const ClientError(ClientErrorKind.unsupportedPlayback);
      }
    }
    return request(
      PlaybackInfo.fromJson,
      ['Items', item.id, 'PlaybackInfo'],
      method: 'POST',
      body: {
        ...PlaybackProfile.request(current.viewer.id, options),
        'MediaSourceId': sourceId,
      },
    );
  }

  /// Read only the current account/device's matching playback. A server may
  /// restrict Sessions; negotiated facts remain useful without admin rights.
  Future<PlaybackDiagnostics> playbackDiagnostics(PlaybackPlan plan) async {
    final fallback = PlaybackDiagnostics.fromPlan(plan);
    final current = session;
    if (current == null) return fallback;
    try {
      final data = await requestJson(
        ['Sessions'],
        query: {'deviceId': identity.deviceId},
      );
      if (data is! List) return fallback;
      for (final row in data.whereType<Map<String, dynamic>>()) {
        final state = row['PlayState'];
        final item = row['NowPlayingItem'];
        if (row['DeviceId'] != identity.deviceId ||
            row['UserId'] != current.viewer.id ||
            item is! Map ||
            item['Id'] != plan.itemId ||
            state is! Map ||
            state['MediaSourceId'] != plan.sourceId ||
            (state['PlaySessionId'] != null &&
                state['PlaySessionId'] != plan.sessionId)) {
          continue;
        }
        final transcode = row['TranscodingInfo'];
        if (transcode is Map<String, dynamic> && plan.method == 'Transcode') {
          return fallback.withServer(transcode);
        }
      }
    } catch (_) {
      /* Diagnostics must never terminate playback. */
    }
    return fallback;
  }

  /// Ends the server's conversion for a stopped or failed transcoded
  /// stream, so a retry doesn't compete with an orphaned encode (Apple
  /// `stopEncoding`). Direct play and Live TV have none to end.
  Future<void> stopEncoding(PlaybackPlan plan) async {
    if (plan.method == 'DirectPlay' || plan.liveStreamId != null) return;
    try {
      await requestText(
        ['Videos', 'ActiveEncodings'],
        query: {'deviceId': identity.deviceId, 'playSessionId': plan.sessionId},
        method: 'DELETE',
      );
    } catch (_) {}
  }

  /// [event] is `start`, `progress` or `stop`.
  Future<void> reportPlayback(
    String event,
    Map<String, Object?> payload, {
    bool Function()? isCurrent,
  }) async {
    // Freeze the final position and stream selection across transient failures.
    final report = Map<String, Object?>.unmodifiable(payload);
    final path = event == 'start'
        ? ['Sessions', 'Playing']
        : ['Sessions', 'Playing', event == 'stop' ? 'Stopped' : 'Progress'];
    try {
      for (var attempt = 0; ; attempt++) {
        if (isCurrent?.call() == false) {
          throw const ClientError(ClientErrorKind.missingSession);
        }
        try {
          await requestText(path, method: 'POST', body: report);
          break;
        } on ClientError catch (error) {
          // Retry only explicit transient server failures, never authentication,
          // arbitrary POSTs or potentially long network timeouts.
          if (event != 'stop' ||
              error.kind != ClientErrorKind.unavailable ||
              !const {502, 503, 504}.contains(error.status) ||
              attempt >= 2) {
            rethrow;
          }
          await Future<void>.delayed(
            Duration(milliseconds: attempt == 0 ? 250 : 750),
          );
        }
      }
    } finally {
      final live = report['LiveStreamId'];
      if (event == 'stop' && live is String && live.isNotEmpty) {
        await closeLive(live);
      }
    }
  }
}

class MediaTime {
  static int ticks(Duration d) => d.isNegative ? 0 : d.inMicroseconds * 10;
  static Duration duration(int ticks) =>
      Duration(microseconds: (ticks < 0 ? 0 : ticks) ~/ 10);
}

/// Only explicit safe fields are exposed. Never return media URLs, tokens,
/// titles, paths, other sessions or arbitrary server error messages.
class PlaybackDiagnostics {
  const PlaybackDiagnostics({
    required this.method,
    this.sourceBitrate,
    this.outputBitrate,
    required this.limit,
    this.reasons = const [],
  });
  final String method;
  final int? sourceBitrate, outputBitrate;
  final int limit;
  final List<String> reasons;
  static const reasonLabels = {
    'ContainerNotSupported': 'Container is not supported',
    'VideoCodecNotSupported': 'Video codec is not supported',
    'AudioCodecNotSupported': 'Audio codec is not supported',
    'SubtitleCodecNotSupported': 'Subtitles need conversion',
    'VideoResolutionNotSupported': 'Resolution exceeds device support',
    'VideoLevelNotSupported': 'Video level exceeds device support',
    'VideoProfileNotSupported': 'Video profile is not supported',
    'VideoBitDepthNotSupported': 'Video bit depth is not supported',
    'VideoRangeTypeNotSupported': 'HDR format is not supported',
    'VideoFramerateNotSupported': 'Frame rate exceeds device support',
    'VideoBitrateNotSupported': 'Video bitrate exceeds the limit',
    'ContainerBitrateExceedsLimit': 'Source bitrate exceeds the quality limit',
    'AudioBitrateNotSupported': 'Audio bitrate exceeds the limit',
    'AudioChannelsNotSupported': 'Audio channels exceed device support',
    'AudioProfileNotSupported': 'Audio profile is not supported',
    'AudioIsExternal': 'Separate audio track selected',
    'SecondaryAudioNotSupported': 'Alternate audio track selected',
    'InterlacedVideoNotSupported': 'Interlaced video needs conversion',
    'DirectPlayError': 'Player compatibility retry',
  };
  static List<String> _reasons(Iterable<Object?> raw) => raw
      .whereType<String>()
      .map(
        (code) =>
            reasonLabels[code] ??
            (RegExp(r'^[A-Za-z]{1,80}$').hasMatch(code)
                ? code
                : 'Compatibility conversion'),
      )
      .toSet()
      .toList();
  static int? _positive(Object? value) =>
      value is num && value.isFinite && value > 0 ? value.toInt() : null;
  factory PlaybackDiagnostics.fromPlan(PlaybackPlan plan) {
    final q = plan.url.queryParameters;
    final direct = plan.method == 'DirectPlay';
    final reasons = _reasons((q['TranscodeReasons'] ?? '').split(','));
    return PlaybackDiagnostics(
      method: direct ? 'Direct play' : 'Server conversion',
      sourceBitrate: plan.source?.bitrate,
      outputBitrate: direct ? plan.source?.bitrate : null,
      limit: plan.options.bitrate,
      reasons: direct
          ? const []
          : reasons.where((x) => x != 'Compatibility conversion').toList(),
    );
  }
  PlaybackDiagnostics withServer(Map<String, dynamic> info) =>
      PlaybackDiagnostics(
        method: info['IsVideoDirect'] == true
            ? (info['IsAudioDirect'] == true
                  ? 'Remuxing (video and audio copied)'
                  : 'Audio conversion (video copied)')
            : 'Video transcoding',
        sourceBitrate: sourceBitrate,
        outputBitrate: _positive(info['Bitrate']),
        limit: limit,
        reasons: info['TranscodeReasons'] is List
            ? _reasons(info['TranscodeReasons'] as List)
            : reasons,
      );
  Map<String, Object?> toJson() => {
    'method': method,
    'sourceBitrate': sourceBitrate,
    'outputBitrate': outputBitrate,
    'limit': limit,
    'reasons': reasons,
  };
  static String bitrateLabel(int? value) => value == null || value <= 0
      ? 'Unavailable'
      : '${(value / 1000000).toStringAsFixed(1)} Mbps';
  List<(String, String)> get facts => [
    ('Playback', method),
    ('Source bitrate', bitrateLabel(sourceBitrate)),
    ('Reported output bitrate', bitrateLabel(outputBitrate)),
    ('Quality limit', bitrateLabel(limit)),
    if (method != 'Direct play')
      (
        'Conversion reason',
        reasons.isEmpty ? 'Not reported by server' : reasons.join('; '),
      ),
  ];
}
