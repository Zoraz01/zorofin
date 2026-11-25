import 'dart:async';

import 'package:flutter/material.dart';

import '../../extras_state.dart';
import '../../core/app_info.dart';
import '../../core/catalog.dart';
import '../../core/errors.dart';
import '../../core/media_quality.dart';
import '../../core/preferences.dart';
import '../../core/viewer_settings.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import '../widgets/subtitle_text.dart';
import 'shell.dart';
import '../widgets/tv_text_field.dart';

/// Phone and tablet layouts show the same settings pages at touch sizes:
/// smaller type, shorter rows, an app bar and system dialogs.
class CompactSettings extends InheritedWidget {
  const CompactSettings({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CompactSettings>() != null;

  @override
  bool updateShouldNotify(CompactSettings oldWidget) => false;
}

/// Settings type: TV sizes, or about two thirds of them on phones.
TextStyle settingsFont(
  BuildContext context,
  double size, {
  FontWeight weight = FontWeight.w400,
  Color color = Zoro.text,
}) => Zoro.font(
  CompactSettings.of(context) ? (size * .68).roundToDouble() : size,
  weight: weight,
  color: color,
);

enum SettingsPage {
  account('Account', Icons.person_rounded),
  display('Display', Icons.desktop_windows_outlined),
  playback('Playback', Icons.play_circle_fill_rounded),
  subtitles('Subtitles', Icons.closed_caption_rounded),
  controls('Controls', Icons.sports_esports_outlined),
  notifications('Notification settings', Icons.tune_rounded),
  storage('Storage & app', Icons.storage_rounded),

  /// TV only: support, privacy, problem reports, storage and version.
  help('Help & about', Icons.help_outline_rounded);

  const SettingsPage(this.title, this.icon);

  final String title;
  final IconData icon;

  /// Pages that read the account's server settings.
  bool get usesAccount =>
      this == account || this == playback || this == subtitles;

  /// The name on the TV Settings list (docs/design/TV_PROFILE_MENU.md).
  String get tvTitle => switch (this) {
    display => 'Home & display',
    notifications => 'Notifications',
    _ => title,
  };
}

/// A row on a TV settings page that opens another screen (Quick Connect,
/// Your teams, Support, Privacy Policy).
class SettingsLink {
  const SettingsLink(this.title, this.onPressed, {this.icon, this.subtitle});

  final String title;
  final VoidCallback onPressed;
  final IconData? icon;
  final String? subtitle;
}

/// One settings page (Apple `NativeSettingsView` TV layout): the title with
/// Save and Done above a form of sections. Opening a page only reads; edits
/// are drafted and stored on Save, or by a named action such as Update
/// password.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.page,
    required this.preferences,
    required this.catalog,
    this.extraFields,
    this.grouped = false,
    this.links = const [],
  });

  final SettingsPage page;
  final Preferences preferences;
  final Catalog catalog;

  /// The grouped Settings used on TVs and the phone Profile tab: Controls
  /// folds into Playback, trailer previews and the unread badge sit on Home &
  /// display, problem reports on Help & about, and changes save as you go
  /// (no Save or Done).
  final bool grouped;

  /// Rows that open other screens, shown in this page's own section.
  final List<SettingsLink> links;

  /// Server delivery settings for Notification settings, when the server
  /// provides them.
  final Widget? extraFields;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final Preferences _prefs = widget.preferences;
  late DevicePreferences _draft = _prefs.value;
  ViewerSettings? _baseline;
  Map<String, dynamic> _configuration = {};
  List<SettingsLanguage> _languages = [];
  bool _loadingAccount = false;
  bool _busy = false;
  String? _status;
  String? _error;
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirmation = TextEditingController();
  Timer? _autosave;

  Catalog get _catalog => widget.catalog;
  bool get _grouped => widget.grouped;

  Map<String, Object> get _changes {
    final baseline = _baseline;
    if (baseline == null) return {};
    return {
      for (final e in _configuration.entries)
        if (baseline.configuration[e.key] != e.value && e.value != null)
          e.key: e.value as Object,
    };
  }

  bool get _canSave =>
      (_draft != _prefs.value || _changes.isNotEmpty) && !_busy;

  bool get _dirty =>
      _draft != _prefs.value ||
      _changes.isNotEmpty ||
      _current.text.isNotEmpty ||
      _new.text.isNotEmpty ||
      _confirmation.text.isNotEmpty;

  bool get _canEditAccount =>
      _baseline?.canEdit == true && !_busy && !_loadingAccount;

  @override
  void initState() {
    super.initState();
    for (final field in [_current, _new, _confirmation]) {
      field.addListener(() => setState(() {}));
    }
    if (widget.page.usesAccount) unawaited(_reload());
  }

  @override
  void dispose() {
    // Leaving mid-pause still keeps the last change.
    if (_autosave?.isActive ?? false) {
      _autosave!.cancel();
      unawaited(_saveQuietly());
    }
    // Passwords are never kept after leaving the page.
    for (final field in [_current, _new, _confirmation]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loadingAccount = true;
      _error = null;
    });
    try {
      final settings = await _catalog.viewerSettings();
      var languages = const <SettingsLanguage>[];
      if (widget.page != SettingsPage.account) {
        try {
          languages = await _catalog.settingsLanguages();
        } catch (_) {
          // Language names are optional; saved codes still show.
        }
      }
      if (!mounted) return;
      setState(() {
        _baseline = settings;
        _configuration = Map.of(settings.configuration);
        _languages = languages;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _loadingAccount = false);
    }
  }

  String _message(Object error) => switch (error) {
    SettingsException(:final error) => error.message,
    ClientError(kind: ClientErrorKind.forbidden) =>
      'Your server owner has disabled account preference changes.',
    ClientError e => e.message,
    _ => 'Something went wrong. Reload settings and try again.',
  };

  /// Runs one action at a time; the page shows it as busy right away.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _run(() async {
    if (_draft != _prefs.value) await _prefs.save(_draft);
    final changes = _changes;
    if (changes.isNotEmpty) {
      final confirmed = await _catalog.saveViewerConfiguration(
        changes,
        _baseline!,
      );
      _baseline = confirmed;
      _configuration = Map.of(confirmed.configuration);
    }
    if (mounted) setState(() => _status = 'Saved');
  });

  Future<void> _changePassword() => _run(() async {
    final client = _catalog.client;
    if (client == null) return;
    await client.changePassword(_current.text, _new.text);
    _current.clear();
    _new.clear();
    _confirmation.clear();
    if (mounted) setState(() => _status = 'Password updated');
  });

  Future<void> _removePhoto() async {
    if (!await _confirm('Remove profile photo?', 'Remove photo')) return;
    await _run(() async {
      await _catalog.client?.removeProfileImage();
      await _reload();
      if (mounted) setState(() => _status = 'Photo removed');
    });
  }

  Future<void> _clearCache() async {
    if (!await _confirm(
      'Clear this account’s cache?',
      'Clear cache',
      detail:
          'Downloaded artwork for this account will be removed. Your sign-in and server media are kept.',
    )) {
      return;
    }
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    if (mounted) setState(() => _status = 'Cache cleared');
  }

  /// Grouped pages save a moment after the last change, without disabling the
  /// form, so focus stays on the row being changed.
  void _scheduleSave() {
    if (!_grouped) return;
    _autosave?.cancel();
    _autosave = Timer(const Duration(milliseconds: 600), _saveQuietly);
  }

  Future<void> _saveQuietly() async {
    try {
      if (_draft != _prefs.value) await _prefs.save(_draft);
      final changes = _changes;
      if (changes.isNotEmpty && _baseline != null) {
        final confirmed = await _catalog.saveViewerConfiguration(
          changes,
          _baseline!,
        );
        if (!mounted) return;
        setState(() {
          _baseline = confirmed;
          _configuration = Map.of(confirmed.configuration);
        });
      } else if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    }
  }

  Future<void> _done() async {
    if (_autosave?.isActive ?? false) {
      _autosave!.cancel();
      await _saveQuietly();
      if (!mounted) return;
    }
    if (!_dirty ||
        await _confirm('Discard unsaved changes?', 'Discard changes')) {
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _reset() async {
    if (!await _confirm(
      'Reset app preferences?',
      'Reset app preferences',
      detail:
          'Only app preferences for this account on this device will reset. Server preferences and saved sign-ins are kept.',
    )) {
      return;
    }
    await _run(() async {
      await _prefs.reset();
      if (!mounted) return;
      setState(() {
        _draft = _prefs.value;
        _status = 'App preferences reset';
      });
    });
  }

  Future<bool> _confirm(String title, String action, {String? detail}) =>
      confirmDialog(context, title, action, detail: detail);

  void _edit(DevicePreferences value) {
    setState(() {
      _draft = value;
      _status = null;
    });
    _scheduleSave();
  }

  void _setConfig(String key, Object value) {
    setState(() {
      _configuration[key] = value;
      _status = null;
    });
    _scheduleSave();
  }

  List<Widget> _links() => [
    for (final link in widget.links)
      SettingsAction(
        title: link.title,
        icon: link.icon,
        subtitle: link.subtitle,
        onPressed: link.onPressed,
      ),
  ];

  Widget _flag(String title, String key, {bool fallback = false}) {
    final value = _configuration[key];
    return SettingsToggle(
      title: title,
      value: value is bool ? value : fallback,
      enabled: _canEditAccount,
      onChanged: (v) => _setConfig(key, v),
    );
  }

  Widget _languagePicker(String title, String key) {
    final current = _configuration[key] is String
        ? _configuration[key] as String
        : '';
    return SettingsPicker<String>(
      title: title,
      value: current,
      enabled: _canEditAccount,
      options: [
        ('', 'No preference'),
        if (current.isNotEmpty && !_languages.any((l) => l.id == current))
          (current, current),
        for (final l in _languages) (l.id, l.name),
      ],
      onChanged: (v) => _setConfig(key, v),
    );
  }

  List<Widget> _accountStatus() => [
    if (_loadingAccount) const SettingsFootnote('Loading account preferences…'),
    if (_baseline?.canEdit == false)
      const SettingsFootnote(
        'Your server owner has disabled account preference changes.',
      ),
  ];

  List<Widget> _fields() => switch (widget.page) {
    SettingsPage.account => _accountFields(),
    SettingsPage.display => _displayFields(),
    SettingsPage.playback => _playbackFields(),
    SettingsPage.subtitles => _subtitleFields(),
    SettingsPage.controls => _controlFields(),
    SettingsPage.notifications => _notificationFields(),
    SettingsPage.storage => _storageFields(),
    SettingsPage.help => _helpFields(),
  };

  /// TV Help & about: links, problem reports, then storage and version.
  List<Widget> _helpFields() => [
    if (widget.links.isNotEmpty) ...[
      const SettingsSectionHeader('Help'),
      ..._links(),
    ],
    if (_reportsOffered) ...[
      const SettingsSectionHeader('Problem reports'),
      ..._reportsToggle(),
    ],
    ..._storageFields(),
  ];

  bool get _reportsOffered =>
      ExtrasScope.maybeOf(context)?.features.playbackReports ?? false;

  List<Widget> _reportsToggle() => [
    SettingsToggle(
      title: 'Send playback problem reports to this server',
      value: _draft.sendPlaybackReports,
      onChanged: (v) => _edit(_draft.copyWith(sendPlaybackReports: v)),
    ),
    const SettingsFootnote(
      'When a title won\'t start or keeps buffering, the app tells your server owner the title, app version and what went wrong. Nothing leaves your server.',
    ),
  ];

  List<Widget> _accountFields() {
    final client = _catalog.client;
    final preview = _catalog.isPreview;
    final editable = _canEditAccount && !preview;
    final passwordReady =
        editable &&
        _new.text.isNotEmpty &&
        _new.text == _confirmation.text &&
        (_baseline?.hasPassword != true || _current.text.isNotEmpty);
    final name = _baseline?.name ?? _catalog.viewerName;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
        child: Row(
          children: [
            ProfileAvatar(
              name: name,
              size: 72,
              photo: _baseline?.hasImage == false
                  ? null
                  : _catalog.viewerPhoto(),
              headers: _catalog.imageHeaders,
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: settingsFont(context, 30, weight: FontWeight.w700),
                  ),
                  if (_catalog.serverName.isNotEmpty)
                    Text(
                      _catalog.serverName,
                      style: settingsFont(context, 22, color: Zoro.muted),
                    ),
                  if (client != null)
                    Text(
                      client.server.url.toString(),
                      style: settingsFont(context, 18, color: Zoro.muted),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      if (_baseline?.hasImage == true)
        SettingsAction(
          title: 'Remove photo',
          destructive: true,
          enabled: editable,
          onPressed: _removePhoto,
        ),
      SettingsFootnote(
        CompactSettings.of(context)
            ? 'To choose a new profile photo, use your server’s web app.'
            : 'To choose a new profile photo, use Zorofin on your phone or your server’s web app.',
      ),
      const SettingsSectionHeader('Change password'),
      SettingsTextField(
        label: 'Current password',
        controller: _current,
        obscure: true,
        enabled: editable,
      ),
      SettingsTextField(
        label: 'New password',
        controller: _new,
        obscure: true,
        enabled: editable,
      ),
      SettingsTextField(
        label: 'Confirm new password',
        controller: _confirmation,
        obscure: true,
        enabled: editable,
      ),
      SettingsAction(
        title: 'Update password',
        enabled: passwordReady,
        onPressed: _changePassword,
      ),
      if (_new.text.isNotEmpty &&
          _confirmation.text.isNotEmpty &&
          _new.text != _confirmation.text)
        const SettingsFootnote('The new passwords don’t match.'),
      const SettingsFootnote(
        'Other devices may need to sign in again after you change your password.',
      ),
      if (widget.links.isNotEmpty) ...[
        const SettingsSectionHeader('Other devices'),
        ..._links(),
      ],
      ..._accountStatus(),
    ];
  }

  List<Widget> _displayFields() => [
    const SettingsSectionHeader('On this device'),
    // The server's "Same look for every viewer" picks the card size.
    if (_prefs.cardSizeFromServer)
      const SettingsInfo(title: 'Poster size', value: 'Set by your server')
    else
      SettingsPicker<double>(
        title: 'Poster size',
        value: _draft.posterScale,
        options: const [
          (0.85, 'Compact'),
          (1.0, 'Comfortable'),
          (1.2, 'Large'),
        ],
        onChanged: (v) => _edit(_draft.copyWith(posterScale: v)),
      ),
    SettingsToggle(
      title: 'Show titles under posters',
      value: _draft.showTitles,
      onChanged: (v) => _edit(_draft.copyWith(showTitles: v)),
    ),
    SettingsToggle(
      title: 'Show watching progress',
      value: _draft.showProgress,
      onChanged: (v) => _edit(_draft.copyWith(showProgress: v)),
    ),
    SettingsToggle(
      title: 'Show ratings',
      value: _draft.showRatings,
      onChanged: (v) => _edit(_draft.copyWith(showRatings: v)),
    ),
    SettingsToggle(
      title: 'Show quality badges',
      value: _draft.showQualityBadges,
      onChanged: (v) => _edit(_draft.copyWith(showQualityBadges: v)),
    ),
    SettingsToggle(
      title: 'Hide available titles in Requests',
      value: _draft.hideAvailableRequests,
      onChanged: (v) => _edit(_draft.copyWith(hideAvailableRequests: v)),
    ),
    const SettingsFootnote(
      'Keep discovery and search focused on titles you can request. Partly available shows remain visible.',
    ),
    SettingsToggle(
      title: 'Reduce motion',
      value: _draft.reduceMotion,
      onChanged: (v) => _edit(_draft.copyWith(reduceMotion: v)),
    ),
    SettingsFootnote(
      CompactSettings.of(context)
          ? 'Your device’s accessibility preferences are always respected.'
          : 'Your TV’s accessibility preferences are always respected.',
    ),
    if (_grouped) ...[
      const SettingsSectionHeader('Home'),
      _autoplayToggle(),
      SettingsToggle(
        title: 'Show unread badge',
        value: _draft.showUnreadBadge,
        onChanged: (v) => _edit(_draft.copyWith(showUnreadBadge: v)),
      ),
      ..._links(),
    ],
  ];

  Widget _autoplayToggle() => SettingsToggle(
    title: 'Autoplay trailer previews on Home',
    value: _draft.autoplayPreviews,
    onChanged: (v) => _edit(_draft.copyWith(autoplayPreviews: v)),
  );

  List<Widget> _playbackFields() => [
    const SettingsSectionHeader('On this device'),
    SettingsPicker<int>(
      title: 'Streaming quality',
      value: _draft.bitrateMbps,
      options: [for (final v in DevicePreferences.bitrates) (v, '$v Mbps')],
      onChanged: (v) => _edit(_draft.copyWith(bitrateMbps: v)),
    ),
    SettingsPicker<double>(
      title: 'Default speed',
      value: _draft.playbackSpeed,
      options: [for (final v in DevicePreferences.speeds) (v, speedLabel(v))],
      onChanged: (v) => _edit(_draft.copyWith(playbackSpeed: v)),
    ),
    const SettingsFootnote(
      'Streaming quality is a maximum bitrate. Your server and connection determine the available quality.',
    ),
    const SettingsSectionHeader('Account defaults'),
    _languagePicker('Preferred audio', 'AudioLanguagePreference'),
    _flag(
      'Prefer the original default audio track',
      'PlayDefaultAudioTrack',
      fallback: true,
    ),
    _flag(
      'Remember audio selections',
      'RememberAudioSelections',
      fallback: true,
    ),
    _flag('Play the next episode automatically', 'EnableNextEpisodeAutoPlay'),
    // Grouped Settings fold Controls into Playback.
    if (_grouped) ...[
      const SettingsSectionHeader('In the player'),
      ..._playerControls(),
    ],
    ..._accountStatus(),
  ];

  List<Widget> _subtitleFields() {
    final appearance = _draft.subtitleAppearance;
    void style(SubtitleAppearance value) =>
        _edit(_draft.copyWith(subtitleAppearance: () => value));
    final mode = _configuration['SubtitleMode'] is String
        ? _configuration['SubtitleMode'] as String
        : 'Default';
    return [
      const SettingsSectionHeader('Appearance on this device'),
      SettingsToggle(
        title: 'Use system subtitle appearance',
        value: appearance == null,
        onChanged: (v) => _edit(
          _draft.copyWith(
            subtitleAppearance: () => v ? null : const SubtitleAppearance(),
          ),
        ),
      ),
      if (appearance != null) ...[
        SettingsPicker<int>(
          title: 'Text size',
          value: appearance.size,
          options: const [
            (80, 'Small'),
            (100, 'Medium'),
            (125, 'Large'),
            (150, 'Extra large'),
          ],
          onChanged: (v) => style(appearance.copyWith(size: v)),
        ),
        SettingsPicker<bool>(
          title: 'Text color',
          value: appearance.yellow,
          options: const [(false, 'White'), (true, 'Yellow')],
          onChanged: (v) => style(appearance.copyWith(yellow: v)),
        ),
        SettingsPicker<double>(
          title: 'Background',
          value: appearance.backgroundOpacity,
          options: const [(0.0, 'None'), (0.65, 'Translucent'), (1.0, 'Black')],
          onChanged: (v) => style(appearance.copyWith(backgroundOpacity: v)),
        ),
        SettingsToggle(
          title: 'Bold text',
          value: appearance.bold,
          onChanged: (v) => style(appearance.copyWith(bold: v)),
        ),
      ],
      Container(
        height: 150,
        margin: const EdgeInsets.symmetric(vertical: 6),
        alignment: Alignment.bottomCenter,
        padding: const EdgeInsets.only(bottom: 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: const LinearGradient(
            colors: [Color(0xFF24543E), Color(0xFF0B1F2A)],
          ),
        ),
        child: SubtitleText(
          'Your next great watch.',
          appearance: appearance,
          baseSize: 34,
        ),
      ),
      const SettingsFootnote(
        'Applies to supported text subtitles. Image-based or burned-in subtitles keep their original appearance.',
      ),
      const SettingsSectionHeader('Account defaults'),
      _languagePicker('Preferred language', 'SubtitleLanguagePreference'),
      SettingsPicker<String>(
        title: 'Subtitle mode',
        value: mode,
        enabled: _canEditAccount,
        options: ViewerSettings.subtitleModes,
        onChanged: (v) => _setConfig('SubtitleMode', v),
      ),
      _flag(
        'Remember subtitle selections',
        'RememberSubtitleSelections',
        fallback: true,
      ),
      const SettingsFootnote(
        'Smart uses subtitles when the audio differs from your preferred subtitle language. Forced only shows required translations. A track chosen on a title overrides these defaults.',
      ),
      ..._accountStatus(),
    ];
  }

  List<Widget> _controlFields() => [
    const SettingsSectionHeader('On this device'),
    ..._playerControls(),
    _autoplayToggle(),
    // Only offered while this server collects them.
    if (_reportsOffered) ..._reportsToggle(),
  ];

  List<Widget> _playerControls() => [
    SettingsPicker<int>(
      title: 'Skip backward',
      value: _draft.skipBack,
      options: [
        for (final v in DevicePreferences.skipIntervals) (v, '$v seconds'),
      ],
      onChanged: (v) => _edit(_draft.copyWith(skipBack: v)),
    ),
    SettingsPicker<int>(
      title: 'Skip forward',
      value: _draft.skipForward,
      options: [
        for (final v in DevicePreferences.skipIntervals) (v, '$v seconds'),
      ],
      onChanged: (v) => _edit(_draft.copyWith(skipForward: v)),
    ),
    const SettingsFootnote(
      'These intervals apply to the backward and forward buttons in the player.',
    ),
    SettingsToggle(
      title: 'Pause when leaving the app',
      value: _draft.pauseInBackground,
      onChanged: (v) => _edit(_draft.copyWith(pauseInBackground: v)),
    ),
    SettingsToggle(
      title: 'Show chapters',
      value: _draft.showChapters,
      onChanged: (v) => _edit(_draft.copyWith(showChapters: v)),
    ),
    const SettingsFootnote(
      'Chapter names and pictures in the player can give the story away. Off by default.',
    ),
  ];

  List<Widget> _notificationFields() => [
    // Grouped Settings keep the badge on Home & display.
    if (!_grouped) ...[
      const SettingsSectionHeader('In the app'),
      SettingsToggle(
        title: 'Show unread badge',
        value: _draft.showUnreadBadge,
        onChanged: (v) => _edit(_draft.copyWith(showUnreadBadge: v)),
      ),
    ],
    ?widget.extraFields,
    if (widget.extraFields == null)
      SettingsFootnote(
        _grouped
            ? 'This server does not provide email or push alert settings.'
            : 'This server does not provide email or push alert settings. The unread badge applies to the app’s inbox.',
      ),
  ];

  List<Widget> _storageFields() {
    final cache = PaintingBinding.instance.imageCache;
    return [
      const SettingsSectionHeader('This account on this device'),
      SettingsInfo(
        title: 'Cached artwork',
        value: MediaQuality.fileSize(cache.currentSizeBytes),
      ),
      SettingsAction(
        title: 'Clear cache',
        destructive: true,
        enabled: !_busy,
        onPressed: _clearCache,
      ),
      SettingsAction(
        title: 'Reset app preferences',
        destructive: true,
        enabled: !_busy,
        onPressed: _reset,
      ),
      const SettingsSectionHeader('Zorofin'),
      const SettingsInfo(title: 'App', value: 'Jellyfin client'),
      const SettingsInfo(title: 'Version', value: appVersion, focusOnTv: true),
      const SettingsFootnote(
        'Connect to a server you already use. Your server manages your library and account.',
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: {
        BackIntent: CallbackAction<BackIntent>(onInvoke: (_) => _done()),
      },
      child: PopScope(
        canPop: !_dirty,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _done();
        },
        child: SettingsScaffold(
          title: _grouped ? widget.page.tvTitle : widget.page.title,
          // Grouped pages save as you go; Back leaves.
          actions: _grouped
              ? const []
              : CompactSettings.of(context)
              ? [
                  if (_canSave || _busy)
                    TextButton(
                      onPressed: _busy ? null : _save,
                      style: TextButton.styleFrom(foregroundColor: Zoro.jade),
                      child: Text(_busy ? 'Saving…' : 'Save'),
                    ),
                ]
              : [
                  if (_canSave || _busy) ...[
                    ZoroButton(
                      label: _busy ? 'Saving…' : 'Save',
                      primary: true,
                      onPressed: _save,
                    ),
                    const SizedBox(width: 12),
                  ],
                  ZoroButton(label: 'Done', onPressed: _done),
                ],
          children: [
            if (_catalog.isPreview)
              const SettingsFootnote('Preview changes stay in this preview.'),
            if (_error != null) ...[
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _error!,
                  style: settingsFont(
                    context,
                    22,
                    color: const Color(0xFFFFB74D),
                  ),
                ),
              ),
              if (widget.page.usesAccount)
                SettingsAction(
                  title: 'Reload from server',
                  enabled: !_busy,
                  onPressed: _reload,
                ),
            ],
            if (_status != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                child: Text(
                  _status!,
                  style: settingsFont(context, 22, color: Zoro.jade),
                ),
              ),
            ..._fields(),
          ],
        ),
      ),
    );
  }
}

/// The TV settings layout: a left-aligned title with actions at the right,
/// above a centered form column.
class SettingsScaffold extends StatelessWidget {
  const SettingsScaffold({
    super.key,
    required this.title,
    required this.actions,
    required this.children,
  });

  final String title;
  final List<Widget> actions;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (CompactSettings.of(context)) {
      return Scaffold(
        backgroundColor: Zoro.background,
        appBar: AppBar(
          backgroundColor: Zoro.background,
          surfaceTintColor: Colors.transparent,
          title: Text(
            title,
            style: settingsFont(context, 26, weight: FontWeight.w600),
          ),
          actions: [...actions, const SizedBox(width: 8)],
        ),
        body: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return _tv(context);
  }

  Widget _tv(BuildContext context) => Scaffold(
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Zoro.gutter, 24, Zoro.gutter, 16),
          child: FocusTraversalGroup(
            child: Row(
              children: [
                Text(
                  title,
                  style: settingsFont(context, 32, weight: FontWeight.w700),
                ),
                const Spacer(),
                ...actions,
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(Zoro.gutter, 8, Zoro.gutter, 40),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: FocusTraversalGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

String speedLabel(double speed) =>
    '${speed.toString().replaceAll(RegExp(r'\.0$'), '')}×';

/// A centered confirmation like the Apple confirmation dialogs; Cancel has
/// focus so an accidental OK does nothing destructive.
Future<bool> confirmDialog(
  BuildContext context,
  String title,
  String action, {
  String? detail,
}) async {
  if (CompactSettings.of(context)) {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: detail == null ? null : Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return result ?? false;
  }
  final result = await showDialog<bool>(
    context: context,
    barrierColor: const Color(0xCC000000),
    builder: (context) => Center(
      child: Container(
        width: 720,
        padding: const EdgeInsets.all(36),
        decoration: BoxDecoration(
          color: Zoro.panel,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: settingsFont(context, 32, weight: FontWeight.w700),
              ),
              if (detail != null) ...[
                const SizedBox(height: 12),
                Text(
                  detail,
                  style: settingsFont(context, 22, color: Zoro.muted),
                ),
              ],
              const SizedBox(height: 28),
              Row(
                children: [
                  ZoroButton(
                    label: action,
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                  const SizedBox(width: 12),
                  ZoroButton(
                    label: 'Cancel',
                    autofocus: true,
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return result ?? false;
}

class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 16, 8, 10),
    child: Text(
      title.toUpperCase(),
      style: settingsFont(
        context,
        18,
        weight: FontWeight.w600,
        color: Zoro.muted,
      ).copyWith(letterSpacing: 1),
    ),
  );
}

class SettingsFootnote extends StatelessWidget {
  const SettingsFootnote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
    child: Text(text, style: settingsFont(context, 18, color: Zoro.muted)),
  );
}

/// A settings row: panel fill, white fill on focus like a tvOS form cell.
/// Disabled rows stay focusable so the remote never skips them silently.
class _Cell extends StatelessWidget {
  const _Cell({
    required this.onPressed,
    required this.builder,
    this.label,
    this.focusNode,
    this.enabled = true,
  });

  final VoidCallback onPressed;
  final Widget Function(Color foreground, Color secondary) builder;
  final String? label;
  final FocusNode? focusNode;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (CompactSettings.of(context)) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Semantics(
          button: true,
          enabled: enabled,
          label: label,
          excludeSemantics: label != null,
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Material(
              color: Zoro.panel,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: enabled ? onPressed : null,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 52),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  alignment: Alignment.centerLeft,
                  child: builder(Zoro.text, Zoro.muted),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return _tv(context);
  }

  Widget _tv(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Focusable(
      onPressed: enabled ? onPressed : () {},
      focusNode: focusNode,
      semanticLabel: label,
      builder: (context, focused) => Opacity(
        opacity: enabled ? 1 : 0.45,
        child: AnimatedScale(
          scale: Zoro.lift(context, focused, 1.01),
          duration: Zoro.focusDuration,
          child: AnimatedContainer(
            duration: Zoro.focusDuration,
            constraints: const BoxConstraints(minHeight: 72),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: focused ? Zoro.text : Zoro.panel,
              borderRadius: BorderRadius.circular(14),
            ),
            child: builder(
              focused ? Zoro.background : Zoro.text,
              focused ? const Color(0xFF3A433D) : Zoro.muted,
            ),
          ),
        ),
      ),
    ),
  );
}

class SettingsToggle extends StatelessWidget {
  const SettingsToggle({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => _Cell(
    label: '$title, ${value ? 'on' : 'off'}',
    enabled: enabled,
    onPressed: () => onChanged(!value),
    builder: (fg, secondary) => Row(
      children: [
        Expanded(
          child: Text(title, style: settingsFont(context, 24, color: fg)),
        ),
        Text(
          value ? 'On' : 'Off',
          style: settingsFont(
            context,
            24,
            weight: FontWeight.w600,
            color: value
                ? (fg == Zoro.text ? Zoro.jade : const Color(0xFF14743A))
                : secondary,
          ),
        ),
      ],
    ),
  );
}

/// Shows the current value; OK expands the choices underneath.
class SettingsPicker<T> extends StatefulWidget {
  const SettingsPicker({
    super.key,
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  final bool enabled;

  @override
  State<SettingsPicker<T>> createState() => _SettingsPickerState<T>();
}

class _SettingsPickerState<T> extends State<SettingsPicker<T>> {
  bool _open = false;
  final _cell = FocusNode(debugLabel: 'settings-picker');
  final _selected = FocusNode(debugLabel: 'settings-picker-selected');

  @override
  void dispose() {
    _cell.dispose();
    _selected.dispose();
    super.dispose();
  }

  /// Opening moves focus to the current value; choosing returns it to the row.
  void _toggle(bool open) {
    setState(() => _open = open);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) (open ? _selected : _cell).requestFocus();
    });
  }

  String get _label =>
      widget.options.where((o) => o.$1 == widget.value).firstOrNull?.$2 ?? '';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Cell(
          label: '${widget.title}, $_label',
          focusNode: _cell,
          enabled: widget.enabled,
          onPressed: () => _toggle(!_open),
          builder: (fg, secondary) => Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: settingsFont(context, 24, color: fg),
                ),
              ),
              Text(_label, style: settingsFont(context, 24, color: secondary)),
              const SizedBox(width: 10),
              Icon(
                _open
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                color: secondary,
              ),
            ],
          ),
        ),
        if (_open && widget.enabled)
          Padding(
            padding: const EdgeInsets.only(left: 32, bottom: 6),
            child: FocusTraversalGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (value, label) in widget.options)
                    _Cell(
                      focusNode: value == widget.value ? _selected : null,
                      label: label,
                      onPressed: () {
                        widget.onChanged(value);
                        _toggle(false);
                      },
                      builder: (fg, secondary) => Row(
                        children: [
                          SizedBox(
                            width: 32,
                            child: value == widget.value
                                ? Icon(
                                    Icons.check_rounded,
                                    color: fg == Zoro.text ? Zoro.jade : fg,
                                  )
                                : null,
                          ),
                          Text(
                            label,
                            style: settingsFont(context, 24, color: fg),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class SettingsAction extends StatelessWidget {
  const SettingsAction({
    super.key,
    required this.title,
    required this.onPressed,
    this.destructive = false,
    this.enabled = true,
    this.icon,
    this.subtitle,
  });

  final String title;
  final VoidCallback onPressed;
  final bool destructive;
  final bool enabled;
  final IconData? icon;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => _Cell(
    label: title,
    enabled: enabled,
    onPressed: onPressed,
    builder: (fg, secondary) {
      final color = destructive && fg == Zoro.text
          ? const Color(0xFFFF8A80)
          : fg;
      return Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: color, size: 26),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Text(title, style: settingsFont(context, 24, color: color)),
          ),
          if (subtitle != null)
            Text(subtitle!, style: settingsFont(context, 22, color: secondary)),
        ],
      );
    },
  );
}

/// A label and value that is not editable.
class SettingsInfo extends StatelessWidget {
  const SettingsInfo({
    super.key,
    required this.title,
    required this.value,
    this.focusOnTv = false,
  });

  final String title;
  final String value;
  final bool focusOnTv;

  @override
  Widget build(BuildContext context) {
    if (!focusOnTv || CompactSettings.of(context)) return _row(context, false);
    return Focus(
      onFocusChange: (focused) {
        if (focused) {
          Scrollable.ensureVisible(
            context,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          );
        }
      },
      child: Builder(
        builder: (context) => _row(context, Focus.of(context).hasFocus),
      ),
    );
  }

  Widget _row(BuildContext context, bool focused) => Container(
    constraints: BoxConstraints(
      minHeight: CompactSettings.of(context) ? 48 : 64,
    ),
    margin: const EdgeInsets.only(bottom: 6),
    padding: EdgeInsets.symmetric(
      horizontal: CompactSettings.of(context) ? 16 : 24,
      vertical: CompactSettings.of(context) ? 10 : 12,
    ),
    decoration: BoxDecoration(
      color: Zoro.panel.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(14),
      border: focused ? Border.all(color: Colors.white, width: 2) : null,
    ),
    child: Row(
      children: [
        Expanded(child: Text(title, style: settingsFont(context, 24))),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: settingsFont(context, 24, color: Zoro.muted),
          ),
        ),
      ],
    ),
  );
}

class SettingsTextField extends StatelessWidget {
  const SettingsTextField({
    super.key,
    required this.label,
    required this.controller,
    this.obscure = false,
    this.enabled = true,
    this.keyboardType,
    this.onSubmitted,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController controller;
  final bool obscure;
  final bool enabled;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: CompactSettings.of(context)
        ? TextField(
            controller: controller,
            enabled: enabled,
            obscureText: obscure,
            autofocus: autofocus,
            autocorrect: false,
            enableSuggestions: !obscure,
            keyboardType: keyboardType,
            onSubmitted: onSubmitted,
            style: settingsFont(context, 24),
            decoration: InputDecoration(labelText: label),
          )
        : TvTextField(
            controller: controller,
            enabled: enabled,
            obscureText: obscure,
            autofocus: autofocus,
            autocorrect: false,
            enableSuggestions: !obscure,
            keyboardType: keyboardType,
            onSubmitted: onSubmitted,
            style: settingsFont(context, 24),
            decoration: InputDecoration(labelText: label),
          ),
  );
}
