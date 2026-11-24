import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/catalog.dart';
import 'core/errors.dart';
import 'core/jellyfin_client.dart';
import 'core/models.dart';
import 'core/preferences.dart';
import 'core/preview_catalog.dart';
import 'core/server_address.dart';
import 'core/session_store.dart';

/// Root app state: saved accounts, and the catalog of the selected account or
/// the preview. Without a catalog the app shows Who's watching (accounts
/// saved) or the connect screen (none).
class AppState extends ChangeNotifier {
  AppState(this._store, {required String deviceName, this.clientFactory})
    : identity = ClientIdentity(
        deviceId: _store.deviceId(),
        deviceName: deviceName,
      ),
      preferences = Preferences(_store.prefs),
      connections = _store.load();

  final SessionStore _store;
  final ClientIdentity identity;
  final Preferences preferences;
  final SavedConnections connections;

  /// Device storage for per-account module state (inbox history, request
  /// receipts).
  SharedPreferences get storage => _store.prefs;

  /// Lets tests supply a client with a fake HTTP transport.
  final JellyfinClient Function(ServerAddress server, ClientIdentity identity)?
  clientFactory;

  Catalog? _catalog;
  Catalog? get catalog => _catalog;

  /// Increments on every account change so late results can be discarded.
  int generation = 0;

  JellyfinClient clientFor(ServerAddress server) =>
      clientFactory?.call(server, identity) ??
      JellyfinClient(server: server, identity: identity);

  bool isCurrent(SavedAccount account) =>
      _catalog is JellyfinCatalog && connections.activeId == account.id;

  void _open(SavedAccount account) {
    final session = account.session!;
    preferences.use(account.scope);
    _catalog = JellyfinCatalog(
      clientFor(
        session.server,
      ).withSession(session, onUnauthorized: () => expire(account.id)),
      serverName: account.serverName,
    );
    generation++;
  }

  /// Restores the selected account without a network round trip; an expired
  /// token surfaces as a sign-in prompt on the first failing request.
  void restore() {
    final account = connections.active;
    if (account?.session != null) _open(account!);
  }

  /// An account opened without "Keep this account on this device"; it is
  /// never written to storage and is gone after the app closes.
  static const transientId = 'this-session-only';

  Future<void> signedIn(
    Session session, {
    String serverName = '',
    bool remember = true,
  }) async {
    if (!remember) {
      connections.activeId = null;
      await _store.save(connections);
      final trimmed = serverName.trim();
      _open(
        SavedAccount(
          id: transientId,
          server: session.server,
          serverName: trimmed.isEmpty ? session.server.url.host : trimmed,
          viewer: session.viewer,
          session: session,
        ),
      );
      notifyListeners();
      return;
    }
    final id = connections.remember(session, serverName);
    await _store.save(connections);
    _open(connections.accounts.firstWhere((a) => a.id == id));
    notifyListeners();
  }

  /// Opens a saved account. Its session is checked first so a revoked token
  /// asks for sign-in instead of opening an empty library.
  Future<void> switchAccount(String id) async {
    final account = connections.accounts.firstWhere((a) => a.id == id);
    final session = account.session;
    if (session == null) {
      throw const ClientError(ClientErrorKind.missingSession);
    }
    final client = clientFor(session.server).withSession(session);
    final viewer = await client.currentViewer();
    if (viewer.id != session.viewer.id) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    connections.activeId = id;
    await _store.save(connections);
    _open(account);
    notifyListeners();
  }

  Future<void> removeAccount(String id) async {
    final account = connections.accounts.where((a) => a.id == id).firstOrNull;
    if (account == null) return;
    final wasActive = connections.activeId == id;
    connections.remove(id);
    await _store.save(connections);
    await preferences.forget(account.scope);
    if (wasActive) {
      _catalog = null;
      generation++;
    }
    notifyListeners();
    final session = account.session;
    if (session != null) {
      try {
        await clientFor(session.server).withSession(session).logout();
      } catch (_) {
        // The token is already gone from this device.
      }
    }
  }

  /// A token the server rejected: keep the account, ask for sign-in again.
  Future<void> expire(String id) async {
    if (id == transientId) {
      _catalog = null;
      generation++;
      notifyListeners();
      return;
    }
    if (connections.activeId != id) return;
    connections.signOut(id);
    _catalog = null;
    generation++;
    notifyListeners();
    await _store.save(connections);
  }

  void openPreview() {
    preferences.use('preview');
    _catalog = PreviewCatalog();
    generation++;
    notifyListeners();
  }

  /// Leaves the preview or signs the current account out on this device. The
  /// account stays in Who's watching so it can sign in again.
  Future<void> signOut() async {
    final current = _catalog;
    final id = connections.activeId;
    _catalog = null;
    generation++;
    if (current is JellyfinCatalog && id != null) connections.signOut(id);
    notifyListeners();
    await _store.save(connections);
    if (current is JellyfinCatalog) {
      try {
        await current.client.logout();
      } catch (_) {
        // The local session is already gone; a failed revoke is not fatal.
      }
    }
  }
}
