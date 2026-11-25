import 'dart:async';
import 'package:web_socket_channel/html.dart';
import 'errors.dart';
import 'jellyfin_client.dart';
import 'sync_play_connection.dart';

Future<SyncPlayConnection> connect(JellyfinClient client) async {
  final session = client.session;
  if (session == null || session.server != client.server) {
    throw const ClientError(ClientErrorKind.missingSession);
  }
  // Browser WebSockets cannot set Authorization headers. Jellyfin's browser
  // contract uses api_key; never log this URL or pass it to another origin.
  final endpoint = client.server.endpoint(
    ['socket'],
    {'deviceId': client.identity.deviceId, 'api_key': session.token},
  );
  final socket = HtmlWebSocketChannel.connect(
    endpoint.replace(scheme: endpoint.scheme == 'https' ? 'wss' : 'ws'),
  );
  final connection = _BrowserConnection(socket);
  try {
    await socket.ready.timeout(const Duration(seconds: 20));
    return connection;
  } catch (_) {
    await connection.close();
    throw const ClientError(ClientErrorKind.network);
  }
}

class _BrowserConnection implements SyncPlayConnection {
  _BrowserConnection(this._socket) {
    // Subscribe before ready so connection errors cannot become unhandled
    // exceptions containing implementation details.
    _subscription = _socket.stream.listen(
      _messages.add,
      onError: (Object _) =>
          _messages.addError(const ClientError(ClientErrorKind.network)),
      onDone: _messages.close,
    );
  }
  final HtmlWebSocketChannel _socket;
  final _messages = StreamController<dynamic>();
  late final StreamSubscription<dynamic> _subscription;
  @override
  Stream<Map<String, dynamic>> get messages =>
      decodeSyncPlayMessages(_messages.stream);
  @override
  void send(String text) => _socket.sink.add(text);
  @override
  Future<void> close() async {
    await _subscription.cancel();
    unawaited(_socket.sink.close(1001));
    // Do not await a single-subscription controller with no listener.
    unawaited(_messages.close());
  }
}
