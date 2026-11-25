import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'runtime_platform.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'errors.dart';
import 'saved_connections.dart';
export 'saved_connections.dart';

class AndroidConnectionVault implements ConnectionVault {
  static const _key = 'zorofin.connections.secure.v1';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
}

/// No browser token is persisted until a webOS vault has been device-tested.
class MemoryConnectionVault implements ConnectionVault {
  String? _value;
  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String value) async {
    _value = value;
  }
}

/// Android/Fire OS sessions use Keystore-backed encryption. Native webOS and
/// Linux retain app-private preferences; the web target uses memory only.
/// Device ID and ordinary preferences contain no session token.
class SessionStore {
  SessionStore._(this._prefs, this._vault, this._loaded);

  static const _legacySessionKey = 'zorofin.session.v1';
  static const _connectionsKey = 'zorofin.connections.v1';
  static const _deviceKey = 'zorofin.device.v1';

  final SharedPreferences _prefs;
  final ConnectionVault? _vault;
  SavedConnections _loaded;
  Future<void> _pending = Future.value();

  SharedPreferences get prefs => _prefs;

  bool get supportsPersistentSignIn => _vault is! MemoryConnectionVault;

  static Future<SessionStore> open({
    ConnectionVault? vault,
    bool? persistentConnections,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final persist = persistentConnections ?? !kIsWeb;
    final selectedVault = !persist
        ? MemoryConnectionVault()
        : vault ?? (usesAndroidVault ? AndroidConnectionVault() : null);
    try {
      final encrypted = await selectedVault?.read();
      final legacy = prefs.getString(_connectionsKey);
      final single = prefs.getString(_legacySessionKey);
      final loaded = encrypted != null
          ? SavedConnections.fromJson(
              jsonDecode(encrypted) as Map<String, dynamic>,
            )
          : legacy != null
          ? SavedConnections.fromJson(
              jsonDecode(legacy) as Map<String, dynamic>,
            )
          : SavedConnections();
      if (encrypted == null && legacy == null && single != null) {
        loaded.remember(
          Session.fromJson(jsonDecode(single) as Map<String, dynamic>),
          '',
        );
      }
      final store = SessionStore._(prefs, selectedVault, loaded);
      // Commit and read back the complete encrypted snapshot BEFORE removing
      // either legacy key. An interrupted migration can safely be retried.
      if (selectedVault != null && (legacy != null || single != null)) {
        if (encrypted == null) {
          await store._writeVault(jsonEncode(loaded.toJson()));
        }
        await store._removeLegacy();
      }
      return store;
    } catch (_) {
      throw const ClientError(ClientErrorKind.storage);
    }
  }

  String deviceId() {
    final existing = _prefs.getString(_deviceKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final id =
        'zorofin-tv-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    _prefs.setString(_deviceKey, id);
    return id;
  }

  SavedConnections load() => SavedConnections.fromJson(_loaded.toJson());

  Future<void> _writeVault(String text) async {
    await _vault!.write(text);
    if (await _vault.read() != text) {
      throw StateError('Account storage verification failed');
    }
  }

  Future<void> _removeLegacy() async {
    for (final key in [_connectionsKey, _legacySessionKey]) {
      if (_prefs.containsKey(key) && !await _prefs.remove(key)) {
        throw StateError('Account storage cleanup failed');
      }
    }
  }

  Future<void> save(SavedConnections connections) {
    // Snapshot before awaiting and serialize writes, including sign-out, so a
    // late earlier write cannot restore a token that has just been removed.
    final text = jsonEncode(connections.toJson());
    final operation = _pending.then((_) async {
      try {
        if (_vault != null) {
          await _writeVault(text);
          await _removeLegacy();
        } else {
          if (!await _prefs.setString(_connectionsKey, text)) {
            throw StateError('Account storage write failed');
          }
          if (_prefs.containsKey(_legacySessionKey) &&
              !await _prefs.remove(_legacySessionKey)) {
            throw StateError('Account storage cleanup failed');
          }
        }
        _loaded = SavedConnections.fromJson(
          jsonDecode(text) as Map<String, dynamic>,
        );
      } catch (_) {
        throw const ClientError(ClientErrorKind.storage);
      }
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }
}
