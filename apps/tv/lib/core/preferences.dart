import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_extras.dart';
import 'server_looks.dart';

/// Text subtitle styling (Apple `SubtitleAppearance`). Null in
/// [DevicePreferences] means the system caption appearance.
@immutable
class SubtitleAppearance {
  const SubtitleAppearance({
    this.size = 100,
    this.yellow = false,
    this.backgroundOpacity = 0.65,
    this.bold = false,
  });

  static const sizes = [80, 100, 125, 150];
  static const backgrounds = [0.0, 0.65, 1.0];

  /// Percent of the default caption size.
  final int size;
  final bool yellow;
  final double backgroundOpacity;
  final bool bold;

  bool get isValid =>
      sizes.contains(size) && backgrounds.contains(backgroundOpacity);

  SubtitleAppearance copyWith({
    int? size,
    bool? yellow,
    double? backgroundOpacity,
    bool? bold,
  }) => SubtitleAppearance(
    size: size ?? this.size,
    yellow: yellow ?? this.yellow,
    backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
    bold: bold ?? this.bold,
  );

  static SubtitleAppearance? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final value = SubtitleAppearance(
      size: json['size'] is int ? json['size'] as int : 100,
      yellow: json['color'] == 'yellow',
      backgroundOpacity: (json['backgroundOpacity'] as num?)?.toDouble() ?? .65,
      bold: json['bold'] == true,
    );
    return value.isValid ? value : null;
  }

  Map<String, dynamic> toJson() => {
    'size': size,
    'color': yellow ? 'yellow' : 'white',
    'backgroundOpacity': backgroundOpacity,
    'bold': bold,
  };

  @override
  bool operator ==(Object other) =>
      other is SubtitleAppearance &&
      other.size == size &&
      other.yellow == yellow &&
      other.backgroundOpacity == backgroundOpacity &&
      other.bold == bold;

  @override
  int get hashCode => Object.hash(size, yellow, backgroundOpacity, bold);
}

/// Preferences kept on this device for one server and viewer, matching the
/// Apple app's `NativePreferences` fields, defaults and allowed values.
@immutable
class DevicePreferences {
  const DevicePreferences({
    this.bitrateMbps = 40,
    this.posterScale = 1.0,
    this.showTitles = true,
    this.showProgress = true,
    this.showRatings = true,
    this.showQualityBadges = true,
    this.hideAvailableRequests = false,
    this.reduceMotion = false,
    this.skipBack = 10,
    this.skipForward = 30,
    this.playbackSpeed = 1.0,
    this.showUnreadBadge = true,
    this.pauseInBackground = true,
    this.autoplayPreviews = true,
    this.showChapters = false,
    this.sendPlaybackReports = true,
    this.subtitleAppearance,
  });

  static const bitrates = [2, 4, 8, 12, 20, 40, 60, 80, 120];
  static const posterScales = [0.85, 1.0, 1.2];
  static const skipIntervals = [5, 10, 15, 30, 60];
  static const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  final int bitrateMbps;
  final double posterScale;
  final bool showTitles;
  final bool showProgress;
  final bool showRatings;
  final bool showQualityBadges;
  final bool hideAvailableRequests;
  final bool reduceMotion;
  final int skipBack;
  final int skipForward;
  final double playbackSpeed;
  final bool showUnreadBadge;

  /// Pauses playback when the TV switches to another app or input.
  final bool pauseInBackground;

  /// TV Home: rest on a movie or show to play its trailer muted.
  final bool autoplayPreviews;

  /// Chapter names, marks and pictures in the player. Off unless the viewer
  /// turns them on: they can give the story away.
  final bool showChapters;

  /// Tell this server when a title won't start, stalls or needs a fallback.
  /// Only sent while the server collects them; off here always wins.
  final bool sendPlaybackReports;
  final SubtitleAppearance? subtitleAppearance;

  /// Maximum streaming bitrate in bits per second.
  int get bitrate => bitrateMbps * 1000000;

  bool get isValid =>
      bitrates.contains(bitrateMbps) &&
      posterScales.contains(posterScale) &&
      skipIntervals.contains(skipBack) &&
      skipIntervals.contains(skipForward) &&
      speeds.contains(playbackSpeed) &&
      (subtitleAppearance?.isValid ?? true);

  DevicePreferences copyWith({
    int? bitrateMbps,
    double? posterScale,
    bool? showTitles,
    bool? showProgress,
    bool? showRatings,
    bool? showQualityBadges,
    bool? hideAvailableRequests,
    bool? reduceMotion,
    int? skipBack,
    int? skipForward,
    double? playbackSpeed,
    bool? showUnreadBadge,
    bool? pauseInBackground,
    bool? autoplayPreviews,
    bool? showChapters,
    bool? sendPlaybackReports,
    SubtitleAppearance? Function()? subtitleAppearance,
  }) => DevicePreferences(
    bitrateMbps: bitrateMbps ?? this.bitrateMbps,
    posterScale: posterScale ?? this.posterScale,
    showTitles: showTitles ?? this.showTitles,
    showProgress: showProgress ?? this.showProgress,
    showRatings: showRatings ?? this.showRatings,
    showQualityBadges: showQualityBadges ?? this.showQualityBadges,
    hideAvailableRequests: hideAvailableRequests ?? this.hideAvailableRequests,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    skipBack: skipBack ?? this.skipBack,
    skipForward: skipForward ?? this.skipForward,
    playbackSpeed: playbackSpeed ?? this.playbackSpeed,
    showUnreadBadge: showUnreadBadge ?? this.showUnreadBadge,
    pauseInBackground: pauseInBackground ?? this.pauseInBackground,
    autoplayPreviews: autoplayPreviews ?? this.autoplayPreviews,
    showChapters: showChapters ?? this.showChapters,
    sendPlaybackReports: sendPlaybackReports ?? this.sendPlaybackReports,
    subtitleAppearance: subtitleAppearance == null
        ? this.subtitleAppearance
        : subtitleAppearance(),
  );

  /// Unknown or invalid saved data falls back to the defaults.
  static DevicePreferences fromJson(Map<String, dynamic> json) {
    T read<T>(String key, T fallback) =>
        json[key] is T ? json[key] as T : fallback;
    double number(String key, double fallback) =>
        (json[key] as num?)?.toDouble() ?? fallback;
    final value = DevicePreferences(
      bitrateMbps: read('bitrateMbps', 40),
      posterScale: number('posterScale', 1),
      showTitles: read('showTitles', true),
      showProgress: read('showProgress', true),
      showRatings: read('showRatings', true),
      showQualityBadges: read('showQualityBadges', true),
      hideAvailableRequests: read('hideAvailableRequests', false),
      reduceMotion: read('reduceMotion', false),
      skipBack: read('skipBack', 10),
      skipForward: read('skipForward', 30),
      playbackSpeed: number('playbackSpeed', 1),
      showUnreadBadge: read('showUnreadBadge', true),
      pauseInBackground: read('pauseInBackground', true),
      autoplayPreviews: read('autoplayPreviews', true),
      showChapters: read('showChapters', false),
      sendPlaybackReports: read('sendPlaybackReports', true),
      subtitleAppearance: SubtitleAppearance.fromJson(
        json['subtitleAppearance'],
      ),
    );
    return value.isValid ? value : const DevicePreferences();
  }

  Map<String, dynamic> toJson() => {
    'bitrateMbps': bitrateMbps,
    'posterScale': posterScale,
    'showTitles': showTitles,
    'showProgress': showProgress,
    'showRatings': showRatings,
    'showQualityBadges': showQualityBadges,
    'hideAvailableRequests': hideAvailableRequests,
    'reduceMotion': reduceMotion,
    'skipBack': skipBack,
    'skipForward': skipForward,
    'playbackSpeed': playbackSpeed,
    'showUnreadBadge': showUnreadBadge,
    'pauseInBackground': pauseInBackground,
    'autoplayPreviews': autoplayPreviews,
    'showChapters': showChapters,
    'sendPlaybackReports': sendPlaybackReports,
    'subtitleAppearance': ?subtitleAppearance?.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is DevicePreferences &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// The current account's [DevicePreferences]. Each server and viewer keeps
/// its own copy, so switching accounts switches preferences too.
class Preferences extends ChangeNotifier {
  Preferences(this._prefs);

  static const _prefix = 'zorofin.prefs.v2.';
  static const _looksPrefix = 'zorofin.looks.v1.';

  final SharedPreferences _prefs;
  String _scope = 'preview';
  DevicePreferences _value = const DevicePreferences();
  bool _saved = false;
  ServerLooks? _looks;

  /// The viewer's preferences with the server's looks applied: its card size
  /// wins when the server sets the same look for every viewer, and is the
  /// starting point until the viewer saves their own otherwise.
  DevicePreferences get value {
    final looks = _looks;
    if (looks == null || (!looks.enforced && _saved)) return _value;
    return _value.copyWith(posterScale: looks.posterScale);
  }

  /// The server's looks for this account, when it has them.
  ServerLooks? get looks => _looks;

  /// True while the server picks the card size (Display shows "Set by your
  /// server" instead of the picker).
  bool get cardSizeFromServer => _looks?.enforced == true;

  int get bitrate => _value.bitrate;
  int get skipBack => _value.skipBack;
  int get skipForward => _value.skipForward;
  bool get showProgress => _value.showProgress;

  /// Loads the preferences for one account. [scope] identifies the server
  /// and viewer; it never contains a token.
  void use(String scope) {
    _scope = scope;
    final text = _prefs.getString('$_prefix$scope');
    var loaded = const DevicePreferences();
    if (text != null) {
      try {
        loaded = DevicePreferences.fromJson(
          jsonDecode(text) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    _value = loaded;
    _saved = text != null;
    _looks = _cachedLooks(scope);
    serverAccent.value = _looks?.accent;
    notifyListeners();
  }

  ServerLooks? _cachedLooks(String scope) {
    final text = _prefs.getString('$_looksPrefix$scope');
    if (text == null) return null;
    try {
      return ServerLooks.fromJson(jsonDecode(text));
    } catch (_) {
      return null;
    }
  }

  /// Applies the server's looks (null: the server has none) and keeps them
  /// for the next start, so the first frame already matches.
  Future<void> useLooks(String scope, ServerLooks? looks) async {
    if (scope != _scope) return;
    final changed = looks != _looks;
    _looks = looks;
    serverAccent.value = looks?.accent;
    if (looks == null) {
      await _prefs.remove('$_looksPrefix$scope');
    } else {
      await _prefs.setString('$_looksPrefix$scope', jsonEncode(looks.toJson()));
    }
    if (changed) notifyListeners();
  }

  Future<void> save(DevicePreferences value) async {
    if (!value.isValid) throw ArgumentError('Invalid preferences');
    if (!await _prefs.setString(
      '$_prefix$_scope',
      jsonEncode(value.toJson()),
    )) {
      throw StateError('Preferences were not saved');
    }
    _value = value;
    _saved = true;
    notifyListeners();
  }

  Future<void> reset() async {
    await _prefs.remove('$_prefix$_scope');
    _value = const DevicePreferences();
    _saved = false;
    notifyListeners();
  }

  static const _tracksPrefix = 'zorofin.tracks.v1.';

  /// Track languages and timing last chosen for a show or movie
  /// ([TrackMemory.keyFor]), for this account on this device.
  TrackMemory? trackMemory(String key) {
    final text = _prefs.getString('$_tracksPrefix$_scope.$key');
    if (text == null) return null;
    try {
      return TrackMemory.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> rememberTracks(String key, TrackMemory memory) async {
    final json = memory.toJson();
    if (json.isEmpty) {
      await _prefs.remove('$_tracksPrefix$_scope.$key');
    } else {
      await _prefs.setString('$_tracksPrefix$_scope.$key', jsonEncode(json));
    }
  }

  /// Removes saved preferences for an account that was forgotten.
  Future<void> forget(String scope) async {
    await _prefs.remove('$_prefix$scope');
    await _prefs.remove('$_looksPrefix$scope');
  }

  static Preferences of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PreferencesScope>()!.notifier!;

  /// For widgets that may render outside the app (tests of single widgets).
  static Preferences? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PreferencesScope>()?.notifier;

  /// Current values, or the defaults outside the app.
  static DevicePreferences valueOf(BuildContext context) =>
      maybeOf(context)?.value ?? const DevicePreferences();
}

class PreferencesScope extends InheritedNotifier<Preferences> {
  const PreferencesScope({
    super.key,
    required Preferences preferences,
    required super.child,
  }) : super(notifier: preferences);
}
