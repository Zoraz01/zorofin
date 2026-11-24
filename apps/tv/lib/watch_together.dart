import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core/errors.dart';
import 'core/jellyfin_client.dart';
import 'core/models.dart';
import 'core/playback.dart';
import 'core/sync_play.dart';

/// What the player exposes to the group (Apple `PlaybackController`).
abstract interface class GroupPlayer {
  String get syncItemId;
  int get syncPositionTicks;
  bool get isPlaying;
  bool get groupPlaybackSuspended;
  Future<void> applyGroupCommand(String command, int ticks);
  void applyGroupStop();
}

/// A title the group asked this device to open.
class GroupPlaybackRequest {
  GroupPlaybackRequest(this.item, this.startTicks) : id = _next++;

  static int _next = 0;
  final int id;
  final MediaItem item;
  final int startTicks;
}

/// One device session on an ordinary Jellyfin server (Apple
/// `WatchTogetherModel`). The server owns the group, queue, clock and
/// commands; this adapter connects that contract to the player.
class WatchTogether extends ChangeNotifier {
  WatchTogether({this.connector = connectSyncPlay});

  final SyncPlayConnector connector;

  List<SyncPlayGroup> groups = [];
  SyncPlayGroup? group;
  MediaItem? currentItem;
  GroupPlaybackRequest? playbackRequest;
  bool browseRequested = false;
  bool busy = false;
  String? error;
  String? access;
  bool connected = false;

  bool get canCreate => access == 'CreateAndJoinGroups';
  bool get canJoin => canCreate || access == 'JoinGroups';
  bool get isJoined => group != null;

  JellyfinClient? _client;
  SyncPlayConnection? _socket;
  StreamSubscription<Map<String, dynamic>>? _receiver;
  Timer? _heartbeat;
  Timer? _scheduled;
  Future<void>? _connecting;
  int _epoch = 0;
  Duration _clockOffset = Duration.zero;
  SyncPlayQueue? _queue;
  SyncPlayCommand? _latestCommand;
  String _queueRevision = '';
  bool _following = true;
  GroupPlayer? _player;
  bool _disposed = false;

  DateTime get _serverNow => DateTime.now().toUtc().add(_clockOffset);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Switches to another account, or none, leaving any group on the old one.
  void configure(JellyfinClient? client) {
    final previous = _client;
    final wasJoined = isJoined;
    _epoch++;
    _scheduled?.cancel();
    _heartbeat?.cancel();
    unawaited(_receiver?.cancel());
    final oldSocket = _socket;
    _socket = null;
    _receiver = null;
    _heartbeat = null;
    _scheduled = null;
    _connecting = null;
    _client = client;
    _player = null;
    group = null;
    groups = [];
    _queue = null;
    _latestCommand = null;
    _queueRevision = '';
    currentItem = null;
    playbackRequest = null;
    browseRequested = false;
    access = null;
    connected = false;
    busy = false;
    error = null;
    _following = true;
    unawaited(() async {
      await oldSocket?.close().catchError((_) {});
      if (wasJoined) await previous?.syncPlay('Leave').catchError((_) {});
    }());
    _changed();
  }

  Future<void> refresh() async {
    final client = _client;
    if (client == null || busy) return;
    final expected = _epoch;
    try {
      final viewer = await client.currentViewer();
      if (expected != _epoch) return;
      access = viewer.syncPlayAccess;
      if (!canJoin) {
        groups = [];
        _clearGroup();
        _disconnect();
        _changed();
        return;
      }
      final available = await client.syncPlayGroups();
      if (expected != _epoch) return;
      groups = available;
      final current = group;
      if (current != null) {
        group =
            available.where((g) => g.id == current.id).firstOrNull ?? current;
      }
      error = null;
    } catch (e) {
      if (expected != _epoch) return;
      error = _message(e);
      if (!isJoined) _disconnect();
    }
    _changed();
  }

  String _message(Object e) =>
      e is ClientError ? e.message : 'Something went wrong. Try again.';

  Future<void> _ensureConnected() {
    if (connected) return Future.value();
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<void> _connect() async {
    final client = _client;
    if (client == null) {
      throw const ClientError(ClientErrorKind.missingSession);
    }
    final expected = _epoch;
    final socket = await connector(client);
    if (expected != _epoch) {
      await socket.close();
      throw StateError('cancelled');
    }
    _socket = socket;
    connected = true;
    _receiver = socket.messages.listen(
      (m) {
        if (expected == _epoch) unawaited(_receive(m));
      },
      onError: (_) => _lost(expected, socket, client),
      onDone: () => _lost(expected, socket, client),
      cancelOnError: true,
    );
    try {
      final clock = await client.syncPlayClock();
      if (expected == _epoch) _clockOffset = clock.offset;
    } catch (_) {}
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) async {
      if (expected != _epoch) return;
      try {
        final clock = await client.syncPlayClock();
        if (expected != _epoch) return;
        _clockOffset = clock.offset;
        if (isJoined) {
          await client.syncPlay('Ping', {
            'Ping': clock.roundTrip.inMicroseconds / 1000,
          });
        }
      } catch (_) {
        // The receiver owns disconnect cleanup.
      }
    });
  }

  void _lost(int expected, SyncPlayConnection socket, JellyfinClient client) {
    if (expected != _epoch || !connected) return;
    connected = false;
    _scheduled?.cancel();
    _heartbeat?.cancel();
    _player = null;
    error =
        'The group connection was interrupted. Open Watch together to reconnect.';
    group = null;
    _queue = null;
    playbackRequest = null;
    _socket = null;
    _receiver = null;
    unawaited(socket.close().catchError((_) {}));
    // Remove this device from the server's buffering barrier.
    unawaited(client.syncPlay('Leave').catchError((_) {}));
    _changed();
  }

  Future<void> create(String name) async {
    final client = _client;
    if (!canCreate || busy || isJoined || client == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 100) {
      error = 'Enter a group name of up to 100 characters.';
      _changed();
      return;
    }
    final expected = _epoch;
    busy = true;
    error = null;
    _changed();
    try {
      await _ensureConnected();
      final created = await client.createSyncPlayGroup(trimmed);
      if (expected != _epoch) return;
      group = created;
      _following = true;
    } catch (e) {
      if (expected == _epoch) error = _message(e);
    } finally {
      if (expected == _epoch) busy = false;
      _changed();
    }
  }

  Future<void> join(SyncPlayGroup selected) async {
    final client = _client;
    if (!canJoin || busy || isJoined || client == null) return;
    final expected = _epoch;
    busy = true;
    error = null;
    _changed();
    try {
      await _ensureConnected();
      await client.syncPlay('Join', {'GroupId': selected.id});
      // Join is acknowledged on the socket. An HTTP 204 alone does not
      // prove membership (the server can send LibraryAccessDenied).
      for (var i = 0; i < 50; i++) {
        if (expected != _epoch || group?.id == selected.id) return;
        if (error != null) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      error =
          'The server did not confirm joining. Refresh the group list and try again.';
    } catch (e) {
      if (expected == _epoch) error = _message(e);
    } finally {
      if (expected == _epoch) busy = false;
      _changed();
    }
  }

  Future<void> leave() async {
    final client = _client;
    if (busy || client == null) return;
    final expected = _epoch;
    busy = true;
    error = null;
    _changed();
    try {
      await client.syncPlay('Leave');
      if (expected != _epoch) return;
      _clearGroup();
      _disconnect();
    } catch (e) {
      if (expected == _epoch) error = _message(e);
    } finally {
      if (expected == _epoch) busy = false;
      _changed();
    }
  }

  void _clearGroup() {
    _scheduled?.cancel();
    _scheduled = null;
    _player = null;
    group = null;
    _queue = null;
    currentItem = null;
    _latestCommand = null;
    _queueRevision = '';
    playbackRequest = null;
    _following = true;
  }

  void _disconnect() {
    _heartbeat?.cancel();
    _heartbeat = null;
    unawaited(_receiver?.cancel());
    _receiver = null;
    _connecting = null;
    connected = false;
    final old = _socket;
    _socket = null;
    unawaited(old?.close().catchError((_) {}));
  }

  void requestBrowse() {
    browseRequested = true;
    _changed();
  }

  /// Taken by the shell once it acts on the request.
  GroupPlaybackRequest? takePlaybackRequest() {
    final request = playbackRequest;
    playbackRequest = null;
    browseRequested = false;
    return request;
  }

  Future<void> selectForPlayback(MediaItem item, int startTicks) async {
    if (!isJoined || item.isLive) return;
    await _send('SetNewQueue', {
      'PlayingQueue': [item.id],
      'PlayingItemPosition': 0,
      'StartPositionTicks': startTicks,
    });
  }

  Future<void> continueWatching() async {
    final client = _client, queue = _queue;
    if (client == null || !isJoined || !connected) return;
    _following = true;
    if (queue != null) await _open(queue, client);
  }

  Future<void> nextItem() async {
    final id = _queue?.current?.playlistItemId;
    if (id == null) return;
    await _send('NextItem', {'PlaylistItemId': id});
  }

  Future<void> requestPause(bool paused) async {
    if (!paused) {
      await _send('SetIgnoreWait', {'IgnoreWait': false});
      await reportReadiness(buffering: false);
    }
    await _send(paused ? 'Pause' : 'Unpause');
  }

  Future<void> requestSeek(Duration position) async {
    await _send('SetIgnoreWait', {'IgnoreWait': false});
    await _send('Seek', {
      'PositionTicks': MediaTime.ticks(
        position.isNegative ? Duration.zero : position,
      ),
    });
  }

  Future<void> _send(String action, [Map<String, Object?>? body]) async {
    final client = _client;
    if (!isJoined || !connected || client == null) return;
    final expected = _epoch;
    try {
      await client.syncPlay(action, body);
    } catch (e) {
      if (expected == _epoch) {
        error = _message(e);
        _changed();
      }
    }
  }

  static String _plainId(String id) => id.replaceAll('-', '').toLowerCase();

  Future<void> playerReady(GroupPlayer player, String itemId) async {
    final current = _queue?.current;
    if (!isJoined ||
        current == null ||
        _plainId(current.itemId) != _plainId(itemId)) {
      return;
    }
    _player = player;
    _following = true;
    await _send('SetIgnoreWait', {'IgnoreWait': false});
    await reportReadiness(buffering: false);
    final latest = _latestCommand;
    if (latest != null) _schedule(latest);
  }

  Future<void> reportReadiness({required bool buffering}) async {
    final player = _player, id = _queue?.current?.playlistItemId;
    if (player == null || id == null) return;
    await _send(buffering ? 'Buffering' : 'Ready', {
      'When': SyncPlayTime.string(_serverNow),
      'PositionTicks': player.syncPositionTicks,
      'IsPlaying': player.isPlaying,
      'PlaylistItemId': id,
    });
  }

  Future<void> playerClosed(GroupPlayer player) async {
    if (_player != null && _player != player) return;
    if (playbackRequest != null) {
      _player = null;
      return;
    }
    _following = false;
    _player = null;
    _scheduled?.cancel();
    await _send('SetIgnoreWait', {'IgnoreWait': true});
  }

  /// Menus and panels hold this device without holding up the group.
  Future<void> pauseForInterface(GroupPlayer player) async {
    if (_player != player) return;
    _scheduled?.cancel();
    await _send('SetIgnoreWait', {'IgnoreWait': true});
  }

  Future<void> correctDrift(GroupPlayer player) async {
    final command = _latestCommand;
    final when = SyncPlayTime.date(command?.when);
    if (_player != player ||
        player.groupPlaybackSuspended ||
        group?.state != 'Playing' ||
        command == null ||
        command.command != 'Unpause' ||
        command.positionTicks == null ||
        when == null ||
        when.isAfter(_serverNow) ||
        command.playlistItemId != _queue?.current?.playlistItemId) {
      return;
    }
    final expected = _estimatedPosition(command);
    if ((expected - player.syncPositionTicks).abs() > 7500000) {
      await player.applyGroupCommand('Unpause', expected);
    }
  }

  @visibleForTesting
  Future<void> receive(Map<String, dynamic> message) => _receive(message);

  Future<void> _receive(Map<String, dynamic> message) async {
    final type = message['MessageType'];
    final data = message['Data'];
    if (type == 'ForceKeepAlive') {
      _socket?.send('{"MessageType":"KeepAlive"}');
      return;
    }
    if (type == 'SyncPlayCommand' && data is Map<String, dynamic>) {
      final SyncPlayCommand command;
      try {
        command = SyncPlayCommand.fromJson(data);
      } catch (_) {
        return;
      }
      final latest = _latestCommand;
      final latestAt = SyncPlayTime.date(latest?.emittedAt);
      final emitted = SyncPlayTime.date(command.emittedAt);
      if (command.groupId != group?.id) return;
      if (latestAt != null && (emitted == null || emitted.isBefore(latestAt))) {
        return;
      }
      if (latest != null && latest.sameAs(command)) return;
      _latestCommand = command;
      _schedule(command);
      return;
    }
    if (type != 'SyncPlayGroupUpdate' || data is! Map<String, dynamic>) return;
    final updateType = data['Type'];
    final groupId = data['GroupId'];
    final payload = data['Data'];
    final current = group;
    if (updateType != 'GroupJoined' &&
        updateType != 'NotInGroup' &&
        current != null &&
        groupId != current.id) {
      return;
    }
    switch (updateType) {
      case 'GroupJoined' || 'GroupUpdate':
        if (payload is Map<String, dynamic>) {
          try {
            final joined = SyncPlayGroup.fromJson(payload);
            if (group?.id != joined.id) _clearGroup();
            group = joined;
            _following = true;
            error = null;
          } catch (_) {}
        }
      case 'GroupLeft' || 'NotInGroup':
        _clearGroup();
      case 'UserJoined':
        if (payload is String) group?.participants.add(payload);
      case 'UserLeft':
        if (payload is String) group?.participants.remove(payload);
      case 'StateUpdate':
        if (payload is Map && payload['State'] is String) {
          group?.state = payload['State'] as String;
        }
      case 'PlayQueue':
        final client = _client;
        if (client == null || payload is! Map<String, dynamic>) return;
        final queue = SyncPlayQueue.fromJson(payload);
        final previous = SyncPlayTime.date(_queueRevision);
        final updated = SyncPlayTime.date(queue.lastUpdate);
        if (_queueRevision.isNotEmpty &&
            (updated == null ||
                previous == null ||
                !updated.isAfter(previous))) {
          return;
        }
        _queue = queue;
        _queueRevision = queue.lastUpdate;
        if (queue.reason == 'NewPlaylist') _following = true;
        if (!_following) break;
        if (queue.current == null) {
          currentItem = null;
          _player?.applyGroupStop();
          _player = null;
          break;
        }
        _changed();
        await _open(queue, client);
      case 'LibraryAccessDenied':
        error = 'Your account cannot play this group’s media.';
      case 'GroupDoesNotExist':
        error =
            'This group is no longer available. Refresh and choose another.';
      case 'CreateGroupDenied' || 'JoinGroupDenied' || 'SyncPlayIsDisabled':
        error = 'Your server does not allow this group action.';
    }
    _changed();
  }

  Future<void> _open(SyncPlayQueue queue, JellyfinClient client) async {
    final selected = queue.current;
    if (selected == null) return;
    final expected = _epoch, revision = _queueRevision;
    try {
      final item = await client.item(selected.itemId);
      if (expected != _epoch ||
          revision != _queueRevision ||
          !isJoined ||
          !_following) {
        return;
      }
      if (item.isLive) {
        error = 'Watch together supports movies and episodes.';
        _changed();
        await _send('SetIgnoreWait', {'IgnoreWait': true});
        return;
      }
      currentItem = item;
      if (_player?.syncItemId == item.id) {
        _changed();
        await reportReadiness(buffering: false);
        return;
      }
      var ticks = queue.startPositionTicks;
      final latest = _latestCommand;
      final updated = SyncPlayTime.date(queue.lastUpdate);
      if (latest != null && latest.playlistItemId == selected.playlistItemId) {
        ticks = _estimatedPosition(latest);
      } else if (queue.isPlaying && updated != null) {
        final elapsed = _serverNow.difference(updated);
        if (!elapsed.isNegative) ticks += MediaTime.ticks(elapsed);
      }
      playbackRequest = GroupPlaybackRequest(item, ticks < 0 ? 0 : ticks);
      _changed();
    } catch (_) {
      if (expected != _epoch) return;
      error =
          'This group’s media could not be opened. Check your access and try again.';
      _changed();
      await _send('SetIgnoreWait', {'IgnoreWait': true});
    }
  }

  int _estimatedPosition(SyncPlayCommand command) {
    var ticks =
        command.positionTicks ??
        _player?.syncPositionTicks ??
        _queue?.startPositionTicks ??
        0;
    final when = SyncPlayTime.date(command.when);
    if (command.command == 'Unpause' && when != null) {
      final elapsed = _serverNow.difference(when);
      if (!elapsed.isNegative) ticks += MediaTime.ticks(elapsed);
    }
    return ticks < 0 ? 0 : ticks;
  }

  void _schedule(SyncPlayCommand command) {
    final player = _player;
    final when = SyncPlayTime.date(command.when);
    if (player == null ||
        player.groupPlaybackSuspended ||
        !_following ||
        when == null ||
        (command.command != 'Stop' &&
            command.playlistItemId != _queue?.current?.playlistItemId)) {
      return;
    }
    _scheduled?.cancel();
    final delay = when.difference(_serverNow);
    if (delay > const Duration(seconds: 60)) return;
    final expected = _epoch;
    _scheduled = Timer(delay.isNegative ? Duration.zero : delay, () {
      if (expected != _epoch ||
          !isJoined ||
          _player != player ||
          player.groupPlaybackSuspended) {
        return;
      }
      unawaited(
        player.applyGroupCommand(command.command, _estimatedPosition(command)),
      );
    });
  }

  @override
  void dispose() {
    configure(null);
    _disposed = true;
    super.dispose();
  }
}
