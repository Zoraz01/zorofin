import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'server_address.dart';

extension ServerStorageKey on ServerAddress {
  /// A server is its origin and installation path, never its display name.
  /// Dart's [Uri] already omits default ports.
  String get storageKey => url.toString();
}

/// One saved viewer on one server. A signed-out account keeps its server and
/// name so it can sign in again; the token is removed.
class SavedAccount {
  SavedAccount({
    required this.id,
    required this.server,
    required this.serverName,
    required this.viewer,
    this.session,
  });

  factory SavedAccount.fromJson(Map<String, dynamic> json) => SavedAccount(
    id: json['id'] as String,
    server: ServerAddress.fromJson(json['server'] as Map<String, dynamic>),
    serverName: json['serverName'] as String? ?? '',
    viewer: Viewer.fromJson(json['viewer'] as Map<String, dynamic>),
    session: json['session'] is Map<String, dynamic>
        ? Session.fromJson(json['session'] as Map<String, dynamic>)
        : null,
  );

  final String id;
  final ServerAddress server;
  final String serverName;
  final Viewer viewer;
  final Session? session;

  /// Identifies this account's device preferences; contains no token.
  String get scope => '${server.storageKey}\n${viewer.id}';

  SavedAccount copyWith({String? serverName, Session? Function()? session}) =>
      SavedAccount(
        id: id,
        server: server,
        serverName: serverName ?? this.serverName,
        viewer: session?.call()?.viewer ?? viewer,
        session: session == null ? this.session : session(),
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'server': server.toJson(),
    'serverName': serverName,
    'viewer': viewer.toJson(),
    'session': ?session?.toJson(),
  };
}

class SavedServer {
  SavedServer(this.address, this.name, this.accounts);

  final ServerAddress address;
  final String name;
  final List<SavedAccount> accounts;
}

/// Saved accounts and the active selection (Apple `SavedConnections`).
/// Passwords and Quick Connect secrets never enter this model.
class SavedConnections {
  SavedConnections({List<SavedAccount>? accounts, this.activeId})
    : accounts = accounts ?? [];

  final List<SavedAccount> accounts;
  String? activeId;

  SavedAccount? get active =>
      accounts.where((a) => a.id == activeId).firstOrNull;

  List<SavedServer> get servers {
    final result = <SavedServer>[];
    for (final account in accounts) {
      final key = account.server.storageKey;
      if (result.any((s) => s.address.storageKey == key)) continue;
      result.add(
        SavedServer(
          account.server,
          account.serverName,
          accounts.where((a) => a.server.storageKey == key).toList(),
        ),
      );
    }
    return result;
  }

  /// Adds or refreshes the account for [session] and selects it.
  String remember(Session session, String serverName) {
    final trimmed = serverName.trim();
    final name = trimmed.isEmpty ? session.server.url.host : trimmed;
    final key = session.server.storageKey;
    final index = accounts.indexWhere(
      (a) => a.server.storageKey == key && a.viewer.id == session.viewer.id,
    );
    final id = index >= 0 ? accounts[index].id : _newId();
    final account = SavedAccount(
      id: id,
      server: session.server,
      serverName: name,
      viewer: session.viewer,
      session: session,
    );
    if (index >= 0) {
      accounts[index] = account;
    } else {
      accounts.add(account);
    }
    for (final (i, a) in accounts.indexed) {
      if (a.server.storageKey == key) {
        accounts[i] = a.copyWith(serverName: name);
      }
    }
    activeId = id;
    return id;
  }

  void signOut(String id) {
    final index = accounts.indexWhere((a) => a.id == id);
    if (index >= 0) {
      accounts[index] = accounts[index].copyWith(session: () => null);
    }
    if (activeId == id) activeId = null;
  }

  void remove(String id) {
    accounts.removeWhere((a) => a.id == id);
    if (activeId == id) activeId = null;
  }

  static String _newId() {
    final random = Random.secure();
    return List.generate(
      12,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'accounts': [for (final a in accounts) a.toJson()],
    'activeId': ?activeId,
  };

  static SavedConnections fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) throw const FormatException('schema');
    final accounts = (json['accounts'] as List)
        .whereType<Map<String, dynamic>>()
        .map(SavedAccount.fromJson)
        .toList();
    final ids = <String>{};
    final identities = <String>{};
    for (final a in accounts) {
      final session = a.session;
      if (!ids.add(a.id) ||
          !identities.add(a.scope) ||
          (session != null &&
              (session.server.storageKey != a.server.storageKey ||
                  session.viewer.id != a.viewer.id))) {
        throw const FormatException('accounts');
      }
    }
    final result = SavedConnections(
      accounts: accounts,
      activeId: json['activeId'] as String?,
    );
    if (result.activeId != null && result.active?.session == null) {
      result.activeId = null;
    }
    return result;
  }
}

/// Persists the device ID and saved accounts.
///
/// Uses the app's private preferences store on every platform. Moving tokens
/// to platform secure storage is tracked in the TV README.
class SessionStore {
  SessionStore(this._prefs);

  static const _legacySessionKey = 'zorofin.session.v1';
  static const _connectionsKey = 'zorofin.connections.v1';
  static const _deviceKey = 'zorofin.device.v1';

  final SharedPreferences _prefs;

  /// Shared with [Preferences] so both use one store.
  SharedPreferences get prefs => _prefs;

  static Future<SessionStore> open() async =>
      SessionStore(await SharedPreferences.getInstance());

  String deviceId() {
    final existing = _prefs.getString(_deviceKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final id =
        'zorofin-tv-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    _prefs.setString(_deviceKey, id);
    return id;
  }

  SavedConnections load() {
    final text = _prefs.getString(_connectionsKey);
    if (text != null) {
      try {
        return SavedConnections.fromJson(
          jsonDecode(text) as Map<String, dynamic>,
        );
      } catch (_) {
        return SavedConnections();
      }
    }
    // A single session from earlier test builds becomes the first account.
    final legacy = _prefs.getString(_legacySessionKey);
    final result = SavedConnections();
    if (legacy != null) {
      try {
        final session = Session.fromJson(
          jsonDecode(legacy) as Map<String, dynamic>,
        );
        result.remember(session, '');
      } catch (_) {}
    }
    return result;
  }

  Future<void> save(SavedConnections connections) async {
    if (!await _prefs.setString(
      _connectionsKey,
      jsonEncode(connections.toJson()),
    )) {
      throw StateError('Saved accounts were not written');
    }
    await _prefs.remove(_legacySessionKey);
  }
}
