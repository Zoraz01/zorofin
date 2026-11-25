import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/catalog.dart';
import 'core/home_recommendations.dart';
import 'core/home_shelf_snapshot.dart';
import 'core/errors.dart';
import 'core/jellyfin_client.dart';
import 'core/models.dart';
import 'core/preferences.dart';
import 'core/server_looks.dart';
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
      connections = _store.load(),
      recommendations = HomeRecommendations(_store.prefs);

  final SessionStore _store;
  final ClientIdentity identity;
  final Preferences preferences;
  final HomeRecommendations recommendations;
  SavedConnections connections;

  SavedConnections _copyConnections() =>
      SavedConnections.fromJson(connections.toJson());

  Future<void> _persist(SavedConnections next) async {
    await _store.save(next);
    connections = next;
  }

  /// Device storage for per-account module state (inbox history, request
  /// receipts).
  SharedPreferences get storage => _store.prefs;
  bool get supportsPersistentSignIn => _store.supportsPersistentSignIn;

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

  HomeShelfSnapshot _homeSnapshot(String id) => HomeShelfSnapshot(
    id,
    readValue: storage.getString,
    writeValue: storage.setString,
    removeValue: storage.remove,
  );

  void _open(SavedAccount account) {
    final session = account.session!;
    preferences.use(account.scope);
    _catalog = JellyfinCatalog(
      clientFor(
        session.server,
      ).withSession(session, onUnauthorized: () => expire(account.id)),
      serverName: account.serverName,
      homeSnapshot: account.id == transientId
          ? null
          : _homeSnapshot(account.id),
    );
    generation++;
    unawaited(refreshLooks(account));
  }

  /// Reads the server's looks (accent, card size) for the open account. A
  /// failed read keeps the last known looks.
  Future<void> refreshLooks([SavedAccount? account]) async {
    account ??= connections.active;
    final client = _catalog?.client;
    if (account == null || client == null) return;
    final expected = generation;
    try {
      final looks = await client.serverLooks();
      if (expected != generation) return;
      await preferences.useLooks(account.scope, looks);
    } catch (_) {}
  }

  /// Restores the selected account without a network round trip; an expired
  /// token surfaces as a sign-in prompt on the first failing request.
  void restore({bool sharedDevice = false}) {
    final account = connections.launchAccount(sharedDevice: sharedDevice);
    if (account?.session != null) _open(account!);
    unawaited(recommendations.use(account, _catalog));
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
      final next = _copyConnections()..activeId = null;
      await _persist(next);
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
    final next = _copyConnections();
    final id = next.remember(session, serverName);
    await _persist(next);
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
    await _persist(_copyConnections()..activeId = id);
    _open(account);
    notifyListeners();
  }

  Future<void> removeAccount(String id) async {
    final account = connections.accounts.where((a) => a.id == id).firstOrNull;
    if (account == null) return;
    final wasActive = connections.activeId == id;
    await _persist(_copyConnections()..remove(id));
    await preferences.forget(account.scope);
    final catalog = _catalog;
    final cache = wasActive && catalog is JellyfinCatalog
        ? catalog.homeSnapshot
        : null;
    await (cache ?? _homeSnapshot(id)).clear(revoke: true);
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
    final catalog = _catalog;
    if (catalog is JellyfinCatalog) {
      unawaited(catalog.homeSnapshot?.clear(revoke: true));
    }
    connections.signOut(id);
    _catalog = null;
    generation++;
    notifyListeners();
    try {
      await _store.save(connections);
    } on ClientError {
      // The server rejected this token; retain the signed-out in-memory state.
      // A later successful save retries cleanup; restore still revalidates it.
    }
  }

  @override
  void notifyListeners() {
    unawaited(
      recommendations.use(
        _catalog is JellyfinCatalog ? connections.active : null,
        _catalog,
      ),
    );
    super.notifyListeners();
  }

  @override
  void dispose() {
    recommendations.dispose();
    super.dispose();
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
    final next = _copyConnections();
    if (current is JellyfinCatalog && id != null) {
      next.signOut(id);
      await current.homeSnapshot?.clear(revoke: true);
    }
    await _persist(next);
    _catalog = null;
    generation++;
    notifyListeners();
    if (current is JellyfinCatalog) {
      try {
        await current.client.logout();
      } catch (_) {
        // The local session is already gone; a failed revoke is not fatal.
      }
    }
  }
}
