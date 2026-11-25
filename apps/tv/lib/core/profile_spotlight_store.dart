import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'profile_spotlight.dart';

// Kept apart from profile_spotlight.dart so the LG bridge, which compiles
// without Flutter, can import the model.

/// Last known spotlight per saved account, so the picker draws at once.
class ProfileSpotlightStore {
  ProfileSpotlightStore(this._prefs);

  static const _prefix = 'profileSpotlight.';
  final SharedPreferences _prefs;

  ProfileSpotlight? load(String accountId) {
    final raw = _prefs.getString('$_prefix$accountId');
    if (raw == null) return null;
    try {
      return ProfileSpotlight.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String accountId, ProfileSpotlight? spotlight) =>
      spotlight == null
      ? _prefs.remove('$_prefix$accountId')
      : _prefs.setString(
          '$_prefix$accountId',
          jsonEncode(spotlight.toJson()),
        );

  /// Drops entries for accounts no longer saved on this device.
  Future<void> prune(Set<String> keep) async {
    for (final key in _prefs.getKeys().toList()) {
      if (key.startsWith(_prefix) && !keep.contains(key.substring(_prefix.length))) {
        await _prefs.remove(key);
      }
    }
  }
}
