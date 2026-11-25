import 'dart:async';
import 'sync_play_connection.dart';
import 'sync_play_io.dart'
    if (dart.library.js_interop) 'sync_play_web.dart'
    as transport;
export 'sync_play_connection.dart';

import 'errors.dart';
import 'jellyfin_client.dart';

/// Jellyfin's built-in SyncPlay contract (Apple `SyncPlay.swift`). No server
/// extension is required.
class SyncPlayGroup {
  SyncPlayGroup({
    required this.groupId,
    required this.groupName,
    this.state,
    List<String> participants = const [],
  }) : participants = [...participants];

  factory SyncPlayGroup.fromJson(Map<String, dynamic> json) {
    final id = json['GroupId'], name = json['GroupName'];
    if (id is! String || id.isEmpty || name is! String) {
      throw const FormatException('SyncPlayGroup');
    }
    return SyncPlayGroup(
      groupId: id,
      groupName: name,
      state: json['State'] as String?,
      participants: [
        for (final p in json['Participants'] as List? ?? const [])
          if (p is String) p,
      ],
    );
  }

  final String groupId;
  final String groupName;
  String? state;
  final List<String> participants;

  String get id => groupId;
}

class SyncPlayQueueItem {
  const SyncPlayQueueItem(this.itemId, this.playlistItemId);

  final String itemId;
  final String playlistItemId;
}

class SyncPlayQueue {
  const SyncPlayQueue({
    required this.reason,
    required this.lastUpdate,
    required this.playlist,
    required this.playingItemIndex,
    required this.startPositionTicks,
    required this.isPlaying,
  });

  factory SyncPlayQueue.fromJson(Map<String, dynamic> json) => SyncPlayQueue(
    reason: json['Reason'] as String? ?? '',
    lastUpdate: json['LastUpdate'] as String? ?? '',
    playlist: [
      for (final p in json['Playlist'] as List? ?? const [])
        if (p is Map && p['ItemId'] is String && p['PlaylistItemId'] is String)
          SyncPlayQueueItem(
            p['ItemId'] as String,
            p['PlaylistItemId'] as String,
          ),
    ],
    playingItemIndex: (json['PlayingItemIndex'] as num?)?.toInt() ?? -1,
    startPositionTicks: (json['StartPositionTicks'] as num?)?.toInt() ?? 0,
    isPlaying: json['IsPlaying'] == true,
  );

  final String reason;
  final String lastUpdate;
  final List<SyncPlayQueueItem> playlist;
  final int playingItemIndex;
  final int startPositionTicks;
  final bool isPlaying;

  SyncPlayQueueItem? get current =>
      playingItemIndex >= 0 && playingItemIndex < playlist.length
      ? playlist[playingItemIndex]
      : null;
}

class SyncPlayCommand {
  const SyncPlayCommand({
    required this.groupId,
    required this.when,
    required this.command,
    required this.emittedAt,
    this.playlistItemId,
    this.positionTicks,
  });

  factory SyncPlayCommand.fromJson(Map<String, dynamic> json) {
    final group = json['GroupId'], when = json['When'];
    final command = json['Command'], emitted = json['EmittedAt'];
    if (group is! String ||
        when is! String ||
        command is! String ||
        emitted is! String) {
      throw const FormatException('SyncPlayCommand');
    }
    return SyncPlayCommand(
      groupId: group,
      when: when,
      command: command,
      emittedAt: emitted,
      playlistItemId: json['PlaylistItemId'] as String?,
      positionTicks: (json['PositionTicks'] as num?)?.toInt(),
    );
  }

  final String groupId;
  final String? playlistItemId;
  final String when;
  final int? positionTicks;
  final String command;
  final String emittedAt;

  bool sameAs(SyncPlayCommand other) =>
      command == other.command &&
      when == other.when &&
      positionTicks == other.positionTicks &&
      playlistItemId == other.playlistItemId;
}

abstract final class SyncPlayTime {
  static DateTime? date(String? text) =>
      text == null ? null : DateTime.tryParse(text)?.toUtc();

  static String string(DateTime date) => date.toUtc().toIso8601String();
}

/// Server clock offset and the request's round trip.
typedef SyncPlayClock = ({Duration offset, Duration roundTrip});

extension SyncPlayRequests on JellyfinClient {
  static const actions = {
    'Join',
    'Leave',
    'Pause',
    'Unpause',
    'Stop',
    'Seek',
    'Ready',
    'Buffering',
    'Ping',
    'SetIgnoreWait',
    'SetNewQueue',
    'NextItem',
  };

  Future<List<SyncPlayGroup>> syncPlayGroups() async {
    final json = await requestJson(['SyncPlay', 'List']);
    if (json is! List) throw const ClientError(ClientErrorKind.invalidResponse);
    final groups = <SyncPlayGroup>[];
    for (final g in json) {
      try {
        groups.add(SyncPlayGroup.fromJson(g as Map<String, dynamic>));
      } catch (_) {}
    }
    return groups;
  }

  Future<SyncPlayGroup> createSyncPlayGroup(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 100) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return request(
      SyncPlayGroup.fromJson,
      ['SyncPlay', 'New'],
      method: 'POST',
      body: {'GroupName': trimmed},
    );
  }

  Future<void> syncPlay(String action, [Map<String, Object?>? body]) async {
    if (!actions.contains(action)) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    await requestText(['SyncPlay', action], method: 'POST', body: body ?? {});
  }

  Future<SyncPlayClock> syncPlayClock() async {
    final start = DateTime.now().toUtc();
    final json = await requestJson(['GetUtcTime']);
    final end = DateTime.now().toUtc();
    final received = json is Map
        ? SyncPlayTime.date(json['RequestReceptionTime'] as String?)
        : null;
    final sent = json is Map
        ? SyncPlayTime.date(json['ResponseTransmissionTime'] as String?)
        : null;
    if (received == null || sent == null) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    final offset = (received.difference(start) + sent.difference(end)) ~/ 2;
    final trip = end.difference(start) - sent.difference(received);
    return (offset: offset, roundTrip: trip.isNegative ? Duration.zero : trip);
  }
}

/// Each transport preserves the selected server/account boundary.
Future<SyncPlayConnection> connectSyncPlay(JellyfinClient client) =>
    transport.connect(client);
