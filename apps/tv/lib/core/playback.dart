import 'errors.dart';
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

class PlaybackOptions {
  PlaybackOptions({
    int startTicks = 0,
    int bitrate = 40000000,
    this.audioIndex,
    this.subtitleIndex = automatic,
    this.burnSubtitles = false,
  }) : startTicks = startTicks < 0 ? 0 : startTicks,
       bitrate = bitrate.clamp(1000000, 40000000);

  /// Let the account's subtitle defaults choose (Apple uses the same -2).
  static const automatic = -2;

  final int startTicks;
  final int bitrate;

  /// Null lets the server pick its default audio track.
  final int? audioIndex;

  /// -1 is off; [automatic] follows the account defaults.
  final int subtitleIndex;

  /// Image subtitles are burned in by the server. Text subtitles are
  /// delivered separately and drawn by the app, so they can be styled and
  /// do not prevent direct play.
  final bool burnSubtitles;

  /// Audio choices and burned-in subtitles only take effect in a server
  /// transcode; direct play streams the file as stored.
  bool get needsTranscode =>
      audioIndex != null || (subtitleIndex >= 0 && burnSubtitles);

  PlaybackOptions copyWith({
    int? startTicks,
    int? bitrate,
    int? Function()? audioIndex,
    int? subtitleIndex,
    bool? burnSubtitles,
  }) => PlaybackOptions(
    startTicks: startTicks ?? this.startTicks,
    bitrate: bitrate ?? this.bitrate,
    audioIndex: audioIndex == null ? this.audioIndex : audioIndex(),
    subtitleIndex: subtitleIndex ?? this.subtitleIndex,
    burnSubtitles: burnSubtitles ?? this.burnSubtitles,
  );

  /// Whether switching to [other] needs a new stream. Changing between text
  /// subtitles, or turning them off, does not.
  bool sameStream(PlaybackOptions other) =>
      bitrate == other.bitrate &&
      audioIndex == other.audioIndex &&
      burnSubtitles == other.burnSubtitles &&
      (!burnSubtitles || subtitleIndex == other.subtitleIndex);
}

/// Same deliberately narrow profile as the Apple client until physical TVs
/// pass the codec matrix: direct play H.264/AAC MP4, otherwise HLS transcode.
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

  static Map<String, Object?> request(String userId, PlaybackOptions options) =>
      {
        'UserId': userId,
        'StartTimeTicks': options.startTicks,
        'MaxStreamingBitrate': options.bitrate,
        'MaxAudioChannels': 2,
        'DeviceProfile': conservative(options.bitrate),
        if (options.subtitleIndex >= -1)
          'SubtitleStreamIndex': options.subtitleIndex,
        'AudioStreamIndex': ?options.audioIndex,
        'EnableDirectPlay': !options.needsTranscode,
        'EnableDirectStream': false,
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

  /// WebVTT for a text subtitle track of this source.
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
    if (source.supportsDirectPlay == true) {
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
    } else if (source.supportsTranscoding == true &&
        reference != null &&
        (source.transcodingSubProtocol?.toLowerCase() == 'hls' ||
            reference.toLowerCase().contains('.m3u8'))) {
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

  /// [event] is `start`, `progress` or `stop`.
  Future<void> reportPlayback(
    String event,
    Map<String, Object?> payload,
  ) async {
    final path = event == 'start'
        ? ['Sessions', 'Playing']
        : ['Sessions', 'Playing', event == 'stop' ? 'Stopped' : 'Progress'];
    await requestText(path, method: 'POST', body: payload);
  }
}

class MediaTime {
  static int ticks(Duration d) => d.isNegative ? 0 : d.inMicroseconds * 10;
  static Duration duration(int ticks) =>
      Duration(microseconds: (ticks < 0 ? 0 : ticks) ~/ 10);
}
