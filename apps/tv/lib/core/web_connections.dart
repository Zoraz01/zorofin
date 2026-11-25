import 'dart:convert';
import 'models.dart';
import 'errors.dart';
import 'saved_connections.dart';

/// Serializes read-modify-write operations in the platform's protected vault.
/// A failed write never updates an in-memory account snapshot.
class WebConnections {
  WebConnections({this.vault, this.isAvailable});
  final ConnectionVault? vault;
  final bool Function()? isAvailable;
  Future<void> _tail = Future.value();
  bool get supported => vault != null && (isAvailable?.call() ?? true);

  Future<T> _run<T>(Future<T> Function(SavedConnections) work) {
    final result = _tail.then((_) async {
      try {
        if (!supported) throw StateError('Protected storage unavailable');
        final raw = await vault!.read();
        final saved = raw == null
            ? SavedConnections()
            : SavedConnections.fromJson(
                jsonDecode(raw) as Map<String, dynamic>,
              );
        return await work(saved);
      } catch (_) {
        throw const ClientError(ClientErrorKind.storage);
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object e, StackTrace s) {});
    return result;
  }

  Future<void> _write(SavedConnections saved) =>
      vault!.write(jsonEncode(saved.toJson()));

  Future<Map<String, Object?>> list() async {
    if (!supported) return {'supported': false, 'accounts': <Object>[]};
    return _run(
      (saved) async => {
        'supported': true,
        'activeId': saved.activeId,
        'launchId': saved.launchAccount(sharedDevice: true)?.id,
        'servers': [
          for (final server in saved.servers)
            {'id': server.accounts.first.id, 'name': server.name},
        ],
        'accounts': [
          for (final a in saved.accounts)
            {
              'id': a.id,
              'viewer': a.viewer.name,
              'serverName': a.serverName,
              'signedIn': a.session != null,
              'hasPhoto': a.session != null && a.viewer.primaryImageTag != null,
            },
        ],
      },
    );
  }

  Future<String> remember(Session session, String serverName) =>
      _run((saved) async {
        final id = saved.remember(session, serverName);
        await _write(saved);
        return id;
      });

  Future<SavedAccount?> get(String id) => _run(
    (saved) async => saved.accounts.where((a) => a.id == id).firstOrNull,
  );

  Future<void> select(String id) => _run((saved) async {
    if (!saved.accounts.any((a) => a.id == id && a.session != null)) {
      throw StateError('Saved session unavailable');
    }
    saved.activeId = id;
    await _write(saved);
  });

  Future<void> signOut(String id) => _run((saved) async {
    saved.signOut(id);
    await _write(saved);
  });

  Future<SavedAccount?> remove(String id) => _run((saved) async {
    final account = saved.accounts.where((a) => a.id == id).firstOrNull;
    saved.remove(id);
    await _write(saved);
    return account;
  });
}
