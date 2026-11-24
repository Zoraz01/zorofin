import 'models.dart';

/// Why a settings change was not confirmed (Apple `SettingsError`).
enum SettingsError {
  invalidInput('Check the settings and try again.'),
  unconfirmed(
    'The server may have saved the change, but confirmation was lost. Reload settings before trying again.',
  ),
  changedElsewhere(
    'These settings changed on another device. Reload before saving again.',
  );

  const SettingsError(this.message);

  final String message;
}

class SettingsException implements Exception {
  const SettingsException(this.error);

  final SettingsError error;

  @override
  String toString() => error.message;
}

/// The signed-in viewer's account settings from `Users/Me`. Only the keys
/// Zorofin edits are changed; every other configuration field is preserved.
class ViewerSettings {
  ViewerSettings({
    required this.name,
    this.hasImage = false,
    this.hasPassword = true,
    this.canEdit = true,
    this.isAdministrator = false,
    this.syncPlayAccess,
    Map<String, dynamic>? configuration,
  }) : configuration = configuration ?? {};

  final String name;
  final bool hasImage;
  final bool hasPassword;
  final bool canEdit;
  final bool isAdministrator;
  final String? syncPlayAccess;
  final Map<String, dynamic> configuration;

  static const booleanKeys = {
    'PlayDefaultAudioTrack',
    'RememberAudioSelections',
    'RememberSubtitleSelections',
    'EnableNextEpisodeAutoPlay',
  };
  static const languageKeys = {
    'AudioLanguagePreference',
    'SubtitleLanguagePreference',
  };
  static const subtitleModes = [
    ('Default', 'Default'),
    ('Always', 'Always'),
    ('Smart', 'Smart'),
    ('OnlyForced', 'Forced only'),
    ('None', 'Off'),
  ];

  String string(String key, {String fallback = ''}) {
    final value = configuration[key];
    return value is String ? value : fallback;
  }

  bool flag(String key, {bool fallback = false}) {
    final value = configuration[key];
    return value is bool ? value : fallback;
  }

  bool get autoplayNext => flag('EnableNextEpisodeAutoPlay', fallback: true);

  static void validate(Map<String, Object> changes) {
    final pattern = RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z]{2,4})?$');
    for (final MapEntry(:key, :value) in changes.entries) {
      final ok = booleanKeys.contains(key)
          ? value is bool
          : languageKeys.contains(key)
          ? value is String &&
                value.length <= 12 &&
                (value.isEmpty || pattern.hasMatch(value))
          : key == 'SubtitleMode'
          ? subtitleModes.any((m) => m.$1 == value)
          : false;
      if (!ok) throw const SettingsException(SettingsError.invalidInput);
    }
  }

  /// Track choice for a title (Apple `ViewerSettings.playbackOptions`).
  /// Jellyfin's per-viewer defaults on [source] come first, including a
  /// remembered Off choice; language and mode rules are the fallback.
  /// Returns null audio when the file's default should stay implicit so
  /// compatible files can still direct play.
  ({int? audio, int subtitle}) chooseTracks(
    MediaSource? source, {
    int? audioIndex,
  }) {
    final streams = source?.mediaStreams ?? const <MediaStream>[];
    final audio = streams.where((s) => s.type == 'Audio').toList();
    final subtitles = streams.where((s) => s.type == 'Subtitle').toList();
    var chosenAudio = audioIndex;
    if (chosenAudio == null) {
      final serverChoice = audio
          .where((s) => s.index == source?.defaultAudioStreamIndex)
          .firstOrNull;
      final fileDefault =
          audio.where((s) => s.isDefault).firstOrNull ?? audio.firstOrNull;
      var choice = serverChoice;
      if (choice == null && !flag('PlayDefaultAudioTrack', fallback: true)) {
        final preference = string('AudioLanguagePreference');
        choice = audio
            .where((s) => sameLanguage(s.language, preference))
            .firstOrNull;
      }
      if (choice != null && choice.index != fileDefault?.index) {
        chosenAudio = choice.index;
      }
    }
    final selectedAudio =
        audio.where((s) => s.index == chosenAudio).firstOrNull ??
        audio
            .where((s) => s.index == source?.defaultAudioStreamIndex)
            .firstOrNull ??
        audio.where((s) => s.isDefault).firstOrNull ??
        audio.firstOrNull;
    final mode = string('SubtitleMode', fallback: 'Default');
    if (mode == 'None') return (audio: chosenAudio, subtitle: -1);
    final serverChoice = source?.defaultSubtitleStreamIndex;
    if (audioIndex == null &&
        serverChoice != null &&
        (serverChoice == -1 || subtitles.any((s) => s.index == serverChoice))) {
      return (audio: chosenAudio, subtitle: serverChoice);
    }
    final preference = string('SubtitleLanguagePreference');
    final matching = subtitles
        .where((s) => sameLanguage(s.language, preference))
        .toList();
    final forced = subtitles
        .where(
          (s) =>
              s.isForced &&
              sameLanguage(s.language, selectedAudio?.language ?? preference),
        )
        .firstOrNull;
    final remembered = subtitles
        .where((s) => s.index == serverChoice)
        .firstOrNull;
    final MediaStream? selected = switch (mode) {
      'OnlyForced' => forced,
      'Always' => matching.firstOrNull ?? remembered ?? subtitles.firstOrNull,
      'Smart' =>
        sameLanguage(selectedAudio?.language, preference)
            ? forced
            : matching.firstOrNull ?? forced,
      _ => remembered ?? forced,
    };
    return (audio: chosenAudio, subtitle: selected?.index ?? -1);
  }

  static bool sameLanguage(String? first, String second) {
    String normalized(String value) {
      final base = value.toLowerCase().split('-').first;
      return const {
            'en': 'eng',
            'es': 'spa',
            'fr': 'fra',
            'fre': 'fra',
            'de': 'deu',
            'ger': 'deu',
            'ar': 'ara',
            'ur': 'urd',
            'hi': 'hin',
            'ja': 'jpn',
            'ko': 'kor',
            'zh': 'zho',
            'chi': 'zho',
            'pt': 'por',
            'it': 'ita',
            'ru': 'rus',
            'tr': 'tur',
            'nl': 'nld',
            'dut': 'nld',
          }[base] ??
          base;
    }

    if (first == null || first.isEmpty || second.isEmpty) return false;
    return normalized(first) == normalized(second);
  }
}

/// A language choice from `Localization/Cultures`.
class SettingsLanguage {
  const SettingsLanguage(this.id, this.name);

  final String id;
  final String name;
}

extension ViewerSettingsJson on Viewer {
  static ViewerSettings decode(Map<String, dynamic> user, String viewerId) {
    final id = user['Id'];
    final name = user['Name'];
    final configuration = user['Configuration'];
    if (id is! String ||
        id.toLowerCase() != viewerId.toLowerCase() ||
        name is! String ||
        configuration is! Map<String, dynamic>) {
      throw const FormatException('Users/Me');
    }
    final policy = user['Policy'] is Map<String, dynamic>
        ? user['Policy'] as Map<String, dynamic>
        : const <String, dynamic>{};
    return ViewerSettings(
      name: name,
      hasImage: user['PrimaryImageTag'] is String,
      hasPassword: user['HasPassword'] != false,
      canEdit: policy['EnableUserPreferenceAccess'] != false,
      isAdministrator: policy['IsAdministrator'] == true,
      syncPlayAccess: policy['SyncPlayAccess'] as String?,
      configuration: Map.of(configuration),
    );
  }
}
