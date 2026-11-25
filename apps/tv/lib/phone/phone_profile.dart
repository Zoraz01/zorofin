import 'dart:async';

import 'package:flutter/material.dart';

import '../core/catalog.dart';
import '../core/errors.dart';
import '../core/public_info.dart';
import '../core/saved_connections.dart';
import '../core/tv_platform.dart';
import '../ui/screens/calendar_screen.dart';
import '../ui/screens/catch_up_screen.dart';
import '../ui/screens/pick_together_screen.dart';
import '../ui/screens/accounts_screen.dart' show QuickConnectScreen;
import '../ui/screens/alert_settings.dart';
import '../ui/screens/settings_screen.dart';
import '../ui/screens/teams_screen.dart';
import '../ui/screens/watch_together_screen.dart';
import '../ui/theme.dart';
import 'phone_connect.dart';
import 'phone_downloads.dart';
import 'phone_extras.dart';
import 'phone_info.dart';
import 'phone_scope.dart';
import 'phone_theme.dart';
import 'phone_widgets.dart';

/// Profile (Apple `ProfileView` on iPhone and iPad). Phones have no avatar
/// menu, so this tab holds it: the viewer, Switch profile, the things you do
/// on this phone, the same six Settings pages as every TV, administration
/// for administrators, then Sign Out. See docs/design/TV_PROFILE_MENU.md.
class PhoneProfileScreen extends StatefulWidget {
  const PhoneProfileScreen({super.key});

  @override
  State<PhoneProfileScreen> createState() => _PhoneProfileScreenState();
}

class _PhoneProfileScreenState extends State<PhoneProfileScreen> {
  bool _administrator = false;
  bool _checked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_checked) {
      _checked = true;
      unawaited(_checkAdministrator());
    }
  }

  /// Administration stays hidden without fresh permission evidence.
  Future<void> _checkAdministrator() async {
    final scope = PhoneScope.of(context);
    final client = scope.catalog.client;
    if (client == null) return;
    final generation = scope.state.generation;
    try {
      final viewer = await client.currentViewer();
      if (!mounted || generation != scope.state.generation) return;
      if (viewer.id != client.session?.viewer.id) return;
      setState(() => _administrator = viewer.isAdministrator);
    } catch (_) {}
  }

  Future<void> _signOut() async {
    final scope = PhoneScope.of(context);
    final preview = scope.catalog.isPreview;
    final ok = await confirmPhone(
      context,
      title: preview
          ? 'Leave the preview?'
          : 'Sign out of ${scope.catalog.serverName}?',
      action: preview ? 'Leave preview' : 'Sign Out',
      detail: preview
          ? null
          : 'Downloads for this account stay on this device until you remove them.',
    );
    if (!ok) return;
    try {
      await scope.state.signOut();
    } on ClientError catch (error) {
      if (mounted) showPhoneMessage(context, error.message);
    }
  }

  void _push(Widget page) => unawaited(PhoneScope.of(context).push(page));

  /// Settings pages are the grouped TV pages, sized for touch here.
  void _settings(
    SettingsPage page, {
    Widget? extraFields,
    List<SettingsLink> links = const [],
  }) {
    final scope = PhoneScope.of(context);
    _push(
      CompactSettings(
        child: SettingsScreen(
          page: page,
          preferences: scope.state.preferences,
          catalog: scope.catalog,
          extraFields: extraFields,
          grouped: true,
          links: links,
        ),
      ),
    );
  }

  void _notificationSettings() {
    final scope = PhoneScope.of(context);
    final client = scope.catalog.client;
    final extras = scope.extras;
    _settings(
      SettingsPage.notifications,
      extraFields:
          extras.features.notificationSettings &&
              !extras.isPreview &&
              client != null
          ? AlertSettingsFields(client: client)
          : null,
    );
  }

  /// Rows that open other screens from inside a Settings page, as on TV.
  List<SettingsLink> _links(SettingsPage page) {
    final scope = PhoneScope.of(context);
    final extras = scope.extras;
    return switch (page) {
      SettingsPage.account => [
        SettingsLink(
          'Quick Connect',
          () => _push(
            CompactSettings(child: QuickConnectScreen(state: scope.state)),
          ),
          icon: Icons.phonelink_ring_rounded,
          subtitle: 'Sign in on another device with a code',
        ),
      ],
      SettingsPage.display => [
        SettingsLink(
          'Your teams',
          () => _push(
            CompactSettings(
              child: TeamsScreen(catalog: scope.catalog, extras: extras),
            ),
          ),
          icon: Icons.sports_basketball_rounded,
        ),
      ],
      SettingsPage.help => [
        if (extras.features.support)
          SettingsLink(
            'Message your server owner',
            () => openSupport(context),
            icon: Icons.support_agent_rounded,
          ),
        SettingsLink(
          'App Support',
          () => openPublicDocument(context, PublicDocument.support),
          icon: Icons.help_outline_rounded,
        ),
        SettingsLink(
          'Privacy Policy',
          () => openPublicDocument(context, PublicDocument.privacy),
          icon: Icons.back_hand_outlined,
        ),
      ],
      _ => const [],
    };
  }

  /// A profile in the strip: switch now when its sign-in is saved, otherwise
  /// open Who's watching to sign in again.
  Future<void> _switchTo(SavedAccount account) async {
    final state = PhoneScope.of(context).state;
    if (account.session == null) {
      return _push(PhoneAccountsScreen(state: state));
    }
    try {
      await state.switchAccount(account.id);
    } on ClientError catch (error) {
      if (!mounted) return;
      showPhoneMessage(context, error.message);
      _push(PhoneAccountsScreen(state: state));
    }
  }

  Future<void> _openWeb(String path) async {
    final client = PhoneScope.of(context).catalog.client;
    if (client == null) return;
    final opened = await TvPlatform.openUrl(
      client.server.url.resolve('web/#/$path'),
    );
    if (!opened && mounted) {
      showPhoneMessage(context, 'Couldn’t open your browser. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = PhoneScope.of(context);
    final catalog = scope.catalog;
    final extras = scope.extras;
    final together = scope.together;
    final media = MediaQuery.of(context);
    final downloads = PhoneDownloads.instance;
    final activeDownloads = downloads.records
        .where((r) => r.state != DownloadState.done)
        .length;
    final accounts = scope.state.connections.accounts;
    final others = [
      for (final account in accounts)
        if (!scope.state.isCurrent(account)) account,
    ];
    final things = [
      _Row(
        'Downloads',
        Icons.download_for_offline_rounded,
        () => _push(const PhoneDownloadsScreen()),
        detail: activeDownloads > 0
            ? '$activeDownloads in progress'
            : downloads.records.isEmpty
            ? null
            : '${downloads.records.length}',
      ),
      if (catalog case final JellyfinCatalog jellyfin
          when extras.features.pickTogether)
        _Row(
          'Pick Together',
          Icons.style_rounded,
          () => _push(
            Scaffold(
              backgroundColor: Zoro.background,
              appBar: AppBar(title: const Text('Pick Together')),
              body: SafeArea(
                child: PickTogetherScreen(
                  catalog: jellyfin,
                  display: false,
                  onOpen: scope.open,
                  onPlay: (item) => scope.play(item),
                ),
              ),
            ),
          ),
        ),
      if (catalog.isPreview || together.canJoin)
        _Row(
          'Watch Together',
          Icons.groups_rounded,
          () => _push(
            CompactSettings(
              child: WatchTogetherScreen(
                group: together,
                preview: catalog.isPreview,
              ),
            ),
          ),
          detail: together.group?.groupName,
        ),
      if (extras.pluginExtras.calendar)
        _Row(
          'Calendar',
          Icons.calendar_month_rounded,
          () => _push(
            CompactSettings(
              child: CalendarScreen(catalog: catalog, onOpen: scope.open),
            ),
          ),
        ),
      if (extras.pluginExtras.catchUp && extras.catchUpSkips != null)
        _Row(
          'Catch Up',
          Icons.view_list_rounded,
          () => _push(
            CompactSettings(
              child: CatchUpScreen(
                catalog: catalog,
                skips: extras.catchUpSkips!,
              ),
            ),
          ),
        ),
    ];
    // The same six pages, in the same order, as Settings on every TV.
    final settings = [
      for (final (page, subtitle) in [
        (SettingsPage.account, 'Photo, password, Quick Connect'),
        (SettingsPage.display, 'Posters, previews, your teams'),
        (SettingsPage.playback, 'Quality, audio, skipping, chapters'),
        (SettingsPage.subtitles, 'Language and look'),
        (SettingsPage.notifications, 'Email and push alerts'),
        (SettingsPage.help, 'Support, privacy, storage, version'),
      ])
        _Row(
          page.tvTitle,
          page.icon,
          page == SettingsPage.notifications
              ? _notificationSettings
              : () => _settings(page, links: _links(page)),
          subtitle: subtitle,
        ),
    ];
    final administration = [
      if (_administrator) ...[
        _Row(
          'Dashboard',
          Icons.speed_rounded,
          () => _openWeb('dashboard'),
          external: true,
        ),
        _Row(
          'Metadata Manager',
          Icons.edit_note_rounded,
          () => _openWeb('metadata'),
          external: true,
        ),
        if (extras.features.accountApprovals)
          _Row(
            'Account approvals',
            Icons.how_to_reg_rounded,
            () => _openWeb('mypreferencesmenu'),
            external: true,
          ),
      ],
    ];
    final sections = [
      ('ON THIS PHONE', things),
      ('SETTINGS', settings),
      ('ADMINISTRATION', administration),
    ];
    return Scaffold(
      backgroundColor: Zoro.background,
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          Phone.gutter,
          media.padding.top + 12,
          Phone.gutter,
          media.padding.bottom + 24,
        ),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Profile',
                    style: Zoro.font(28, weight: FontWeight.w700),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      PhoneAvatar(
                        name: catalog.viewerName,
                        size: 64,
                        photo: catalog.viewerPhoto(width: 192),
                        headers: catalog.imageHeaders,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              catalog.viewerName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Zoro.font(22, weight: FontWeight.w700),
                            ),
                            if (catalog.serverName.isNotEmpty)
                              Text(
                                catalog.serverName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Zoro.font(15, color: Zoro.muted),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const _Header('SWITCH PROFILE'),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final account in others)
                          _ProfileTile(
                            label:
                                '${account.viewer.name}, ${account.serverName}',
                            name: account.viewer.name,
                            onPressed: () => unawaited(_switchTo(account)),
                            avatar: PhoneAvatar(
                              name: account.viewer.name,
                              size: 52,
                              rounded: true,
                            ),
                          ),
                        _ProfileTile(
                          label: 'All profiles',
                          name: 'All',
                          onPressed: () =>
                              _push(PhoneAccountsScreen(state: scope.state)),
                          avatar: Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(13),
                              border: Border.all(color: Zoro.border, width: 2),
                            ),
                            child: const Icon(
                              Icons.more_horiz_rounded,
                              color: Zoro.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  for (final (title, rows) in sections)
                    if (rows.isNotEmpty) ...[
                      _Header(title),
                      _Group(rows: rows),
                      const SizedBox(height: 20),
                    ],
                  PillButton(
                    label: catalog.isPreview ? 'Leave preview' : 'Sign Out',
                    icon: Icons.logout_rounded,
                    expand: true,
                    onPressed: _signOut,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row {
  const _Row(
    this.title,
    this.icon,
    this.onPressed, {
    this.detail,
    this.subtitle,
    this.external = false,
  });

  final String title;
  final IconData icon;
  final VoidCallback onPressed;
  final String? detail;

  /// A line under the title naming what the page holds.
  final String? subtitle;

  /// Opens outside the app (the server's web app in the browser).
  final bool external;
}

/// A small caps label above a group, as on the TV menu.
class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Text(
      text,
      style: Zoro.font(
        12,
        weight: FontWeight.w600,
        color: Zoro.muted,
      ).copyWith(letterSpacing: 1),
    ),
  );
}

/// One profile in the Switch profile strip.
class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.label,
    required this.name,
    required this.avatar,
    required this.onPressed,
  });

  final String label;
  final String name;
  final Widget avatar;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 72,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              avatar,
              const SizedBox(height: 6),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Zoro.font(13, color: Zoro.muted),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// An inset grouped list, like an iOS `Form` section.
class _Group extends StatelessWidget {
  const _Group({required this.rows});

  final List<_Row> rows;

  @override
  Widget build(BuildContext context) => Material(
    color: Zoro.panel,
    borderRadius: BorderRadius.circular(Phone.radius),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        for (final (i, row) in rows.indexed) ...[
          if (i > 0)
            const Divider(height: 1, indent: 56, color: Color(0x22FFFFFF)),
          ListTile(
            minTileHeight: 52,
            leading: Icon(row.icon, color: const Color(0xFF9BD3AD)),
            title: Text(row.title, style: Zoro.font(16)),
            subtitle: row.subtitle == null
                ? null
                : Text(row.subtitle!, style: Zoro.font(13, color: Zoro.muted)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (row.detail != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(
                      row.detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Zoro.font(15, color: Zoro.muted),
                    ),
                  ),
                const SizedBox(width: 4),
                Icon(
                  row.external
                      ? Icons.open_in_new_rounded
                      : Icons.chevron_right_rounded,
                  size: row.external ? 18 : 22,
                  color: Zoro.muted,
                ),
              ],
            ),
            onTap: row.onPressed,
          ),
        ],
      ],
    ),
  );
}
