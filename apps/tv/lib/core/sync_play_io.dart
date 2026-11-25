import 'dart:io';
import 'errors.dart';
import 'jellyfin_client.dart';
import 'sync_play_connection.dart';

/// A same-server authenticated socket. The token travels in the
/// Authorization header, never in the URL.
Future<SyncPlayConnection> connect(JellyfinClient client) async {
  final session = client.session;
  if (session == null || session.server != client.server) {
    throw const ClientError(ClientErrorKind.missingSession);
  }
  final endpoint = client.server.endpoint(
    ['socket'],
    {'deviceId': client.identity.deviceId},
  );
  final url = endpoint.replace(
    scheme: endpoint.scheme == 'https' ? 'wss' : 'ws',
  );
  try {
    final socket = await WebSocket.connect(
      url.toString(),
      headers: client.authHeaders,
    ).timeout(const Duration(seconds: 20));
    socket.pingInterval = const Duration(seconds: 20);
    return _IoConnection(socket);
  } catch (_) {
    throw const ClientError(ClientErrorKind.network);
  }
}

class _IoConnection implements SyncPlayConnection {
  _IoConnection(this._socket);

  final WebSocket _socket;

  @override
  Stream<Map<String, dynamic>> get messages => decodeSyncPlayMessages(_socket);

  @override
  void send(String text) => _socket.add(text);

  @override
  Future<void> close() => _socket.close(WebSocketStatus.goingAway);
}
