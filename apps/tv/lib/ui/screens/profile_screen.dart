import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../extras_state.dart';
import '../../core/catalog.dart';
import '../../core/public_info.dart';
import '../../core/tv_platform.dart';
import '../../core/errors.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import 'accounts_screen.dart';
import 'public_info_screen.dart';
import 'settings_screen.dart';
import 'shell.dart';

/// TV Settings (Apple `ProfileView` TV layout, docs/design/TV_PROFILE_MENU.md):
/// avatar, viewer and server, then Account, Home & display, Playback,
/// Subtitles, Notifications, Help & about, Manage server for administrators,
/// and Sign Out. Switching profiles, Pick Together, Watch Together, Calendar
/// and Catch Up live in the avatar menu instead.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.state,
    required this.catalog,
    this.onTeams,
    this.onNotifications,
    this.onSupport,
    this.accountApprovals = false,
  });

  final AppState state;
  final Catalog catalog;

  /// Your teams, on Home & display.
  final VoidCallback? onTeams;

  /// Notifications with the server's alert settings; null opens the page
  /// without them.
  final VoidCallback? onNotifications;

  /// Message the server owner, on Help & about, when the server offers it.
  final VoidCallback? onSupport;

  /// The server's account approvals page, offered to administrators.
  final bool accountApprovals;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

/// One Profile row; [after] places module rows within the settings list.
class ProfileRowData {
  const ProfileRowData(
    this.title,
    this.icon,
    this.onPressed, {
    this.after,
    this.subtitle,
  });

  final String title;
  final IconData icon;
  final VoidCallback onPressed;
  final SettingsPage? after;
  final String? subtitle;
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _administrator = false;
  bool _hasStore = false;
  bool _openingStore = false;
  bool _settingRecommendations = false;

  @override
  void initState() {
    super.initState();
    unawaited(_checkAdministrator());
    unawaited(
      TvPlatform.store().then((store) {
        if (mounted) setState(() => _hasStore = store != null);
      }),
    );
  }

  /// Administration stays hidden without fresh permission evidence.
  Future<void> _checkAdministrator() async {
    final client = widget.catalog.client;
    if (client == null) return;
    final generation = widget.state.generation;
    try {
      final viewer = await client.currentViewer();
      if (!mounted || generation != widget.state.generation) return;
      if (viewer.id != client.session?.viewer.id) return;
      setState(() => _administrator = viewer.isAdministrator);
    } catch (_) {}
  }

  Future<void> _toggleRecommendations() async {
    if (_settingRecommendations) return;
    final recommendations = widget.state.recommendations;
    final enabling = !recommendations.enabled;
    if (!enabling) {
      final off = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Turn off Fire TV recommendations?'),
          content: const SizedBox(
            width: 640,
            child: Text(
              'Titles from this account will be removed from the Fire TV home screen.',
            ),
          ),
          actions: [
            ZoroButton(
              label: 'Keep on',
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
            ),
            ZoroButton(
              label: 'Turn off',
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        ),
      );
      if (off != true || !mounted) return;
    }
    if (enabling) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Show recommendations on Fire TV?'),
          content: const SizedBox(
            width: 640,
            child: Text(
              'Titles and artwork from this account will be visible on the Fire TV home screen. Anyone using this TV may see them.',
            ),
          ),
          actions: [
            ZoroButton(
              label: 'Cancel',
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
            ),
            ZoroButton(
              label: 'Enable',
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    setState(() => _settingRecommendations = true);
    final success = await recommendations.setEnabled(enabling);
    if (!mounted) return;
    setState(() => _settingRecommendations = false);
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Recommendations are unavailable. Check the TV notification permissions and try again.',
          ),
        ),
      );
    }
  }

  Future<void> _rate() async {
    if (_openingStore) return;
    _openingStore = true;
    final opened = await TvPlatform.openRating();
    _openingStore = false;
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the store. Try again later.'),
        ),
      );
    }
  }

  Future<void> _signOut() async {
    try {
      await widget.state.signOut();
    } on ClientError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  /// Pushed pages leave the shell's subtree, so the scope goes with them.
  void _push(Widget page) {
    final extras = ExtrasScope.maybeOf(context);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            extras == null ? page : ExtrasScope(extras: extras, child: page),
      ),
    );
  }

  void _settings(SettingsPage page, [List<SettingsLink> links = const []]) =>
      _push(
        SettingsScreen(
          page: page,
          preferences: widget.state.preferences,
          catalog: widget.catalog,
          grouped: true,
          links: links,
        ),
      );

  List<SettingsLink> _links(SettingsPage page) => switch (page) {
    SettingsPage.account => [
      SettingsLink(
        'Quick Connect',
        () => _push(QuickConnectScreen(state: widget.state)),
        icon: Icons.phonelink_ring_rounded,
        subtitle: 'Sign in another device',
      ),
    ],
    SettingsPage.display => [
      // Fire TV only: lives under Home & display so the main Settings list
      // keeps the shared order (checklist H3).
      if (widget.state.recommendations.canEnable)
        SettingsLink(
          'Fire TV home-screen recommendations',
          _toggleRecommendations,
          icon: Icons.tv_rounded,
          subtitle: widget.state.recommendations.enabled
              ? 'On · titles from this account show on the Fire TV home'
              : 'Off · keep this account off the Fire TV home',
        ),
      if (widget.onTeams != null)
        SettingsLink(
          'Your teams',
          widget.onTeams!,
          icon: Icons.sports_basketball_rounded,
        ),
    ],
    SettingsPage.help => [
      if (widget.onSupport != null)
        SettingsLink(
          'Message your server owner',
          widget.onSupport!,
          icon: Icons.support_agent_rounded,
        ),
      SettingsLink(
        'App Support',
        () => _push(const PublicInfoScreen(page: PublicDocument.support)),
        icon: Icons.help_outline_rounded,
      ),
      SettingsLink(
        'Privacy Policy',
        () => _push(const PublicInfoScreen(page: PublicDocument.privacy)),
        icon: Icons.back_hand_outlined,
      ),
      if (_hasStore)
        SettingsLink('Rate Zorofin', _rate, icon: Icons.star_outline_rounded),
    ],
    _ => const [],
  };

  static const _subtitles = {
    SettingsPage.account: 'Photo, password, Quick Connect',
    SettingsPage.display: 'Posters, previews, your teams',
    SettingsPage.playback: 'Quality, audio, skipping, chapters',
    SettingsPage.subtitles: 'Language and look',
    SettingsPage.notifications: 'Email and push alerts',
    SettingsPage.help: 'Support, privacy, storage, version',
  };

  @override
  Widget build(BuildContext context) {
    final catalog = widget.catalog;
    final rows = <ProfileRowData>[
      for (final page in [
        SettingsPage.account,
        SettingsPage.display,
        SettingsPage.playback,
        SettingsPage.subtitles,
        SettingsPage.notifications,
        SettingsPage.help,
      ])
        ProfileRowData(
          page.tvTitle,
          page.icon,
          page == SettingsPage.notifications && widget.onNotifications != null
              ? widget.onNotifications!
              : () => _settings(page, _links(page)),
          subtitle: _subtitles[page],
        ),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(Zoro.gutter, 24, Zoro.gutter, 40),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: FocusTraversalGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ProfileAvatar(
                      name: catalog.viewerName,
                      size: 64,
                      photo: catalog.viewerPhoto(),
                      headers: catalog.imageHeaders,
                    ),
                    const SizedBox(width: 20),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          catalog.viewerName,
                          style: Zoro.font(36, weight: FontWeight.w700),
                        ),
                        if (catalog.serverName.isNotEmpty)
                          Text(
                            catalog.serverName,
                            style: Zoro.font(22, color: Zoro.muted),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                for (final (i, row) in rows.indexed)
                  _ProfileRow(data: row, autofocus: i == 0),
                if (_administrator) ...[
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 14),
                    child: Text(
                      'Administration',
                      style: Zoro.font(28, weight: FontWeight.w700),
                    ),
                  ),
                  _ProfileRow(
                    data: ProfileRowData(
                      'Manage server',
                      Icons.speed_rounded,
                      () => _push(
                        _ManageServerScreen(
                          state: widget.state,
                          accountApprovals: widget.accountApprovals,
                          push: _push,
                        ),
                      ),
                      subtitle: widget.accountApprovals
                          ? 'Dashboard, metadata, approvals'
                          : 'Dashboard, metadata',
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                ZoroButton(
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
    );
  }
}

/// Manage server: the server's own pages, opened on another device.
class _ManageServerScreen extends StatelessWidget {
  const _ManageServerScreen({
    required this.state,
    required this.accountApprovals,
    required this.push,
  });

  final AppState state;
  final bool accountApprovals;
  final void Function(Widget page) push;

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: 'Manage server',
    actions: const [],
    children: [
      for (final (title, path, icon) in [
        ('Dashboard', 'dashboard', Icons.speed_rounded),
        ('Metadata Manager', 'metadata', Icons.edit_note_rounded),
        if (accountApprovals)
          ('Account approvals', 'mypreferencesmenu', Icons.how_to_reg_rounded),
      ])
        SettingsAction(
          title: title,
          icon: icon,
          onPressed: () =>
              push(WebHandoffScreen(title: title, path: path, state: state)),
        ),
    ],
  );
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.data, this.autofocus = false});

  final ProfileRowData data;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Focusable(
        onPressed: data.onPressed,
        autofocus: autofocus,
        semanticLabel: data.title,
        builder: (context, focused) => AnimatedContainer(
          duration: Zoro.focusDuration,
          constraints: const BoxConstraints(minHeight: 66),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: BoxDecoration(
            color: Zoro.panel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: focused ? Zoro.jade : Zoro.border,
              width: focused ? 3 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(data.icon, color: const Color(0xFF9BD3AD), size: 26),
              const SizedBox(width: 26),
              Expanded(child: Text(data.title, style: Zoro.font(24))),
              if (data.subtitle != null)
                Text(data.subtitle!, style: Zoro.font(20, color: Zoro.muted)),
            ],
          ),
        ),
      ),
    );
  }
}
