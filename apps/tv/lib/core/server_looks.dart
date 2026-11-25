import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/painting.dart' show Color, HSLColor;

import 'errors.dart';
import 'jellyfin_client.dart';

/// The server's look for every viewer (companion `looks.json`, through the
/// plugin at `/Zorofin/Web/ui/looks.json`): one accent colour and one card
/// size. The web look uses the same file. With [enforced] (the Dashboard's
/// "Same look for every viewer"), the apps hide their own card size setting;
/// without it, the server's card size is only the starting point.
class ServerLooks {
  const ServerLooks({
    this.accent,
    this.cardSize = 'standard',
    this.enforced = true,
  });

  static const cardSizes = {'compact': 0.85, 'standard': 1.0, 'large': 1.2};
  static final _hex = RegExp(r'^#[0-9a-fA-F]{6}$');

  /// The web look's own Zorofin green preset.
  static const zorofinWeb = '#42d779';

  /// Null keeps the apps' own Zorofin green (the server's "zorofin" colours).
  final Color? accent;

  /// `compact`, `standard` or `large`.
  final String cardSize;
  final bool enforced;

  /// The apps' poster size step for [cardSize].
  double get posterScale => cardSizes[cardSize] ?? 1.0;

  /// Null when the answer isn't a version 1 looks file.
  static ServerLooks? fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['version'] != 1) return null;
    final accent = json['accent'], colors = json['colors'];
    final size = json['cardSize'];
    return ServerLooks(
      // Zorofin green on the server is the apps' own green, as on the web.
      accent:
          colors != 'zorofin' &&
              accent is String &&
              _hex.hasMatch(accent) &&
              accent.toLowerCase() != zorofinWeb
          ? readableAccent(
              Color(int.parse('ff${accent.substring(1)}', radix: 16)),
            )
          : null,
      cardSize: size is String && cardSizes.containsKey(size)
          ? size
          : 'standard',
      enforced: json['enforced'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'colors': accent == null ? 'zorofin' : 'custom',
    if (accent case final c?) 'accent': hexOf(c),
    'cardSize': cardSize,
    'enforced': enforced,
  };

  @override
  bool operator ==(Object other) =>
      other is ServerLooks &&
      other.accent == accent &&
      other.cardSize == cardSize &&
      other.enforced == enforced;

  @override
  int get hashCode => Object.hash(accent, cardSize, enforced);
}

/// The accent of the account on screen (null: Zorofin green). The theme reads
/// it as `Zoro.jade`; [Preferences] sets it with the account's looks.
final serverAccent = ValueNotifier<Color?>(null);

/// `#rrggbb`.
String hexOf(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// An accent stays readable: on the dark panels, and under the dark label of a
/// primary button (4.5:1 against the background needs a luminance of about
/// 0.22). One that is too dark is lightened, keeping its hue.
Color readableAccent(Color c) {
  var hsl = HSLColor.fromColor(c);
  var out = c;
  while (out.computeLuminance() < 0.22 && hsl.lightness < 0.95) {
    hsl = hsl.withLightness((hsl.lightness + 0.04).clamp(0, 0.95));
    out = hsl.toColor();
  }
  return out;
}

extension ServerLooksClient on JellyfinClient {
  /// The server's looks, or null for a server without them (older companion,
  /// no plugin, or the web look turned off).
  Future<ServerLooks?> serverLooks() async {
    try {
      return ServerLooks.fromJson(
        await requestJson([
          'Zorofin',
          'Web',
          'ui',
          'looks.json',
        ], expectedStatus: 200),
      );
    } on ClientError catch (e) {
      if (e.kind == ClientErrorKind.unavailable &&
          (e.status == 404 || e.status == 405)) {
        return null;
      }
      if (e.kind == ClientErrorKind.forbidden) return null;
      rethrow;
    }
  }
}
