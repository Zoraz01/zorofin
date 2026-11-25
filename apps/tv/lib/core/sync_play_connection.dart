import 'dart:convert';
import 'jellyfin_client.dart';

/// A message on the group socket.
abstract interface class SyncPlayConnection {
  Stream<Map<String, dynamic>> get messages;
  void send(String text);
  Future<void> close();
}

typedef SyncPlayConnector =
    Future<SyncPlayConnection> Function(JellyfinClient client);

/// Drop invalid and oversized messages before dispatching to the player.
Stream<Map<String, dynamic>> decodeSyncPlayMessages(Stream<dynamic> stream) =>
    stream
        .where((m) => m is String && m.length <= 1024 * 1024)
        .map((m) {
          try {
            final json = jsonDecode(m as String);
            return json is Map<String, dynamic> ? json : null;
          } catch (_) {
            return null;
          }
        })
        .where((m) => m != null)
        .cast<Map<String, dynamic>>();
