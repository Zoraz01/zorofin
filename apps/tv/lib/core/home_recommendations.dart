import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'catalog.dart';
import 'models.dart';
import 'session_store.dart';

/// Viewer opt-in for local Fire TV launcher cards, scoped to one saved account.
/// Not the cloud watch-history API. Tokens and server addresses never leave
/// the app. Only title, episode label, pixels and opaque local IDs are shared.
class HomeRecommendations extends ChangeNotifier {
  HomeRecommendations(this._prefs) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'open') {
        _pending = Map<String, dynamic>.from(call.arguments as Map);
        await _ready;
        if (!_disposed) await _openPending();
      }
    });
    _ready = _initialize();
  }
  static const channel = MethodChannel('org.zorofin.tv/recommendations');
  final SharedPreferences _prefs;
  late final Future<void> _ready;
  bool available = false;
  bool _disposed = false;
  SavedAccount? _account;
  Catalog? _catalog;
  int _generation = 0, _refresh = 0;
  Map<String, dynamic>? _pending;
  MediaItem? _opening;
  String? get _key => _account == null
      ? null
      : 'zorofin.homeRecommendations.v1.${_account!.id}';
  bool get enabled => _key != null && (_prefs.getBool(_key!) ?? false);
  bool get canEnable =>
      available && _account?.session != null && _catalog?.isPreview == false;

  Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> _initialize() async {
    available = await _call<bool>('available') ?? false;
    final pending = await _call<Map>('pending');
    if (pending != null) _pending = Map<String, dynamic>.from(pending);
    if (!_disposed) notifyListeners();
  }

  Future<void> use(SavedAccount? account, Catalog? catalog) async {
    _account = account;
    _catalog = catalog;
    _opening = null;
    final generation = ++_generation;
    await _ready;
    if (_disposed || generation != _generation) return;
    await _call<void>('scope', canEnable && enabled ? _account!.id : null);
    if (_disposed || generation != _generation) return;
    notifyListeners();
    await _openPending();
    await refresh();
  }

  Future<bool> setEnabled(bool value) async {
    final key = _key, generation = _generation;
    if (key == null || !canEnable) return false;
    if (value && await _call<bool>('permission') != true) return false;
    if (generation != _generation || _disposed) return false;
    if (!await _prefs.setBool(key, value)) return false;
    await _call<void>('scope', value ? _account!.id : null);
    if (generation != _generation || _disposed) return false;
    notifyListeners();
    if (value) await refresh();
    return true;
  }

  Future<void> refresh() async {
    await _ready;
    final account = _account, catalog = _catalog;
    final generation = _generation, revision = ++_refresh;
    bool current() =>
        !_disposed &&
        generation == _generation &&
        revision == _refresh &&
        enabled;
    if (!canEnable || !enabled || account == null || catalog == null) return;
    try {
      final viewer = await catalog.client!.currentViewer();
      if (!current() || viewer.id != account.viewer.id) return;
      final rows = await catalog.home();
      if (!current()) return;
      final seen = <String>{};
      final items = rows
          .expand((r) => r.items)
          .where(
            (item) =>
                const {'Movie', 'Episode', 'Series'}.contains(item.type) &&
                seen.add(item.id),
          )
          .take(5);
      final cards = <Map<String, Object>>[];
      for (final item in items) {
        Uint8List? thumbnail;
        final uri =
            catalog.backdrop(item, width: 320) ??
            catalog.artwork(item, landscape: true, width: 320);
        if (uri != null) {
          try {
            final bytes = await catalog.client!.recommendationArtwork(uri);
            if (bytes != null) {
              final codec = await ui.instantiateImageCodec(
                bytes,
                targetWidth: 240,
                targetHeight: 135,
              );
              try {
                final frame = await codec.getNextFrame();
                try {
                  thumbnail = (await frame.image.toByteData(
                    format: ui.ImageByteFormat.png,
                  ))?.buffer.asUint8List();
                } finally {
                  frame.image.dispose();
                }
              } finally {
                codec.dispose();
              }
            }
          } catch (_) {
            /* Missing artwork does not block a card. */
          }
        }
        if (!current()) return;
        cards.add({
          'itemId': item.id,
          'title': item.displayTitle,
          'description': item.isEpisode ? item.episodeLabel : 'Open in Zorofin',
          if (thumbnail != null && thumbnail.length <= 180000)
            'image': thumbnail,
        });
      }
      if (current()) {
        await _call<bool>('publish', {'accountId': account.id, 'cards': cards});
      }
    } catch (_) {
      // Optional discovery cannot break browsing. Remove stale cards when
      // permission or the server fails; another visit can repopulate them.
      if (current()) await _call<void>('scope', account.id);
    }
  }

  Future<void> _openPending() async {
    final pending = _pending, account = _account, catalog = _catalog;
    if (pending == null || account == null || catalog == null) return;
    _pending = null;
    if (!canEnable || !enabled || pending['accountId'] != account.id) return;
    final id = pending['itemId'];
    if (id is! String || id.isEmpty || id.length > 256) return;
    final generation = _generation;
    try {
      final item = await catalog.item(id);
      if (_disposed || generation != _generation || !enabled) return;
      _opening = item;
      notifyListeners();
    } catch (_) {
      /* Removed content never opens another account. */
    }
  }

  MediaItem? takeOpening() {
    final item = _opening;
    _opening = null;
    return item;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}
