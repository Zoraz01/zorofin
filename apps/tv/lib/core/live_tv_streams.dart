import 'errors.dart';
import 'jellyfin_client.dart';
import 'models.dart';

/// Which channels are using the server's Live TV streams, from the companion's
/// `liveTvStreams` module (capability version 1). Viewers get channel names and
/// counts only, never who is watching. Text matches the web client
/// (branding/zorofin-live-tv-streams.js) and the Apple apps
/// (ZorofinCore `LiveTVStreams`) so every app says the same thing.
class LiveTvStreams {
  const LiveTvStreams({
    required this.limit,
    required this.inUse,
    required this.free,
    this.otherUse = 0,
    this.streams = const [],
    this.request,
  });

  factory LiveTvStreams.fromJson(Map<String, dynamic> json) {
    final limit = json['limit'];
    final inUse = json['inUse'];
    final free = json['free'];
    final otherUse = json['otherUse'] ?? 0;
    final streams = json['streams'] ?? const [];
    if (json['version'] != 1 ||
        limit is! int ||
        limit <= 0 ||
        limit > 1000 ||
        inUse is! int ||
        inUse < 0 ||
        free is! int ||
        free < 0 ||
        otherUse is! int ||
        streams is! List) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    final request = json['request'];
    return LiveTvStreams(
      limit: limit,
      inUse: inUse,
      free: free,
      otherUse: otherUse,
      streams: [
        for (final s in streams)
          if (s is Map<String, dynamic>) LiveTvStream.fromJson(s),
      ],
      request: request is Map<String, dynamic>
          ? LiveTvStreamRequest.fromJson(request)
          : null,
    );
  }

  final int limit;
  final int inUse;
  final int free;
  final int otherUse;
  final List<LiveTvStream> streams;
  final LiveTvStreamRequest? request;

  bool get isFull => free <= 0;

  /// "1 of 1 Live TV stream in use. Anyone can join a channel that’s already playing."
  String get summary {
    final head = '$inUse of ${_plural(limit, 'Live TV stream')} in use.';
    return isFull
        ? '$head Anyone can join a channel that’s already playing.'
        : '$head ${_plural(free, 'stream')} free for another channel.';
  }

  LiveTvStream? streamFor(String channelId) {
    final id = clean(channelId);
    for (final s in streams) {
      if (clean(s.channelId) == id) return s;
    }
    return null;
  }

  /// The line under a channel's Play button, or null when there is nothing to say.
  String? channelLine(String channelId) {
    final playing = streamFor(channelId);
    if (playing != null) {
      if (playing.yours) return 'You’re watching this channel.';
      return 'Already playing${playing.viewers > 1 ? ' for ${playing.viewers} people' : ''}. Joining doesn’t use another stream.';
    }
    final list = isFull ? _othersList(channelId) : null;
    if (list == null) return null;
    return limit == 1
        ? '$list is using the only Live TV stream.'
        : '$list are using all $limit Live TV streams.';
  }

  /// Set when starting this channel would need a stream and none is free.
  LiveTvBlocked? blocked(String channelId) {
    final request = this.request;
    if (request != null && clean(request.channelId) == clean(channelId)) {
      if (request.canStart) return null;
    } else if (streamFor(channelId) != null || !isFull) {
      return null;
    }
    final others = streams
        .where((s) => clean(s.channelId) != clean(channelId))
        .toList();
    final list = _othersList(channelId);
    final text = list == null
        ? 'Every Live TV stream is in use right now.'
        : limit == 1
        ? '$list is using the only Live TV stream right now.'
        : '$list are using all $limit Live TV streams right now.';
    final hint = others.isEmpty
        ? 'Try again when a stream is free.'
        : 'You can watch ${others.length == 1 ? others.first.channelName : 'one of those channels'} instead, or try again when a stream is free.';
    return LiveTvBlocked(
      text: text,
      hint: hint,
      join: others.length == 1 ? others.first : null,
    );
  }

  String? _othersList(String channelId) {
    final names = [
      for (final s in streams)
        if (clean(s.channelId) != clean(channelId) && s.channelName.isNotEmpty)
          s.channelName,
    ];
    if (otherUse > 0) {
      names.add(otherUse == 1 ? 'another app' : '$otherUse other apps');
    }
    if (names.isEmpty) return null;
    if (names.length == 1) return names.first;
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }

  static String _plural(int count, String word) =>
      '$count $word${count == 1 ? '' : 's'}';

  static String clean(String id) => id.replaceAll('-', '').toLowerCase();
}

class LiveTvStream {
  const LiveTvStream({
    required this.channelId,
    required this.channelName,
    this.channelNumber,
    this.programmeTitle,
    this.endsAt,
    this.viewers = 1,
    this.paused = false,
    this.yours = false,
  });

  factory LiveTvStream.fromJson(Map<String, dynamic> json) {
    final programme = json['programme'];
    final title = programme is Map ? programme['title'] : null;
    final ends = programme is Map ? programme['endsAt'] : null;
    final viewers = json['viewers'];
    return LiveTvStream(
      channelId: '${json['channelId'] ?? ''}',
      channelName: '${json['channelName'] ?? ''}',
      channelNumber: json['channelNumber'] as String?,
      programmeTitle: title is String && title.isNotEmpty ? title : null,
      endsAt: ends is String ? DateTime.tryParse(ends) : null,
      viewers: viewers is int ? viewers : 1,
      paused: json['paused'] == true,
      yours: json['yours'] == true,
    );
  }

  final String channelId;
  final String channelName;
  final String? channelNumber;
  final String? programmeTitle;
  final DateTime? endsAt;
  final int viewers;
  final bool paused;
  final bool yours;

  /// A playable channel item for Join.
  MediaItem get channel =>
      MediaItem(id: channelId, name: channelName, type: 'TvChannel');

  /// "2 watching · 18 min left"
  String detail([DateTime? now]) {
    final parts = ['${viewers < 1 ? 1 : viewers} watching'];
    final end = endsAt;
    if (end != null) {
      final minutes = (end.difference(now ?? DateTime.now()).inSeconds / 60)
          .round();
      if (minutes > 0) {
        parts.add(
          minutes < 60
              ? '$minutes min left'
              : '${minutes ~/ 60} hr ${minutes % 60 > 0 ? '${minutes % 60} min ' : ''}left',
        );
      }
    }
    return parts.join(' · ');
  }
}

class LiveTvStreamRequest {
  const LiveTvStreamRequest({
    required this.channelId,
    this.playing = false,
    this.canStart = true,
    this.reason = '',
  });

  factory LiveTvStreamRequest.fromJson(Map<String, dynamic> json) =>
      LiveTvStreamRequest(
        channelId: '${json['channelId'] ?? ''}',
        playing: json['playing'] == true,
        canStart: json['canStart'] != false,
        reason: '${json['reason'] ?? ''}',
      );

  final String channelId;
  final bool playing;
  final bool canStart;
  final String reason;
}

class LiveTvBlocked {
  const LiveTvBlocked({required this.text, required this.hint, this.join});
  final String title = 'Live TV is in use';
  final String text;
  final String hint;

  /// The one channel the viewer could watch instead.
  final LiveTvStream? join;
}

extension LiveTvStreamsClient on JellyfinClient {
  /// Through the Zorofin plugin's companion route. Fails when the module is missing.
  Future<LiveTvStreams> liveTvStreams({String? channelId}) async {
    final json = await requestJson(
      ['Zorofin', 'Companion', 'liveTvStreams', 'status'],
      query: {'deviceId': identity.deviceId, 'channelId': ?channelId},
      extensionToken: true,
      expectedStatus: 200,
    );
    if (json is! Map<String, dynamic>) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return LiveTvStreams.fromJson(json);
  }
}
