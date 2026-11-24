import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/catalog.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import 'accounts_screen.dart';
import 'settings_screen.dart';
import 'shell.dart';

/// Profile (Apple `ProfileView` TV layout): avatar, viewer and server, the
/// account and settings rows, administration for administrators, utilities,
/// then Sign Out.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.state,
    required this.catalog,
    this.moduleRows = const [],
    this.utilityRows = const [],
    this.accountApprovals = false,
  });

  final AppState state;
  final Catalog catalog;

  /// Rows from Zorofin server modules, after Display (Your teams, Watch
  /// together) and in the utility group (Support, Notifications).
  final List<ProfileRowData> moduleRows;
  final List<ProfileRowData> utilityRows;

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

  @override
  void initState() {
    super.initState();
    unawaited(_checkAdministrator());
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

  void _push(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  void _settings(SettingsPage page) => _push(
    SettingsScreen(
      page: page,
      preferences: widget.state.preferences,
      catalog: widget.catalog,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final catalog = widget.catalog;
    final rows = <ProfileRowData>[
      ProfileRowData(
        'Change account',
        Icons.people_alt_rounded,
        () => _push(AccountsScreen(state: widget.state)),
      ),
      ProfileRowData(
        SettingsPage.account.title,
        SettingsPage.account.icon,
        () => _settings(SettingsPage.account),
      ),
      ProfileRowData(
        'Quick Connect',
        Icons.phonelink_ring_rounded,
        () => _push(QuickConnectScreen(state: widget.state)),
      ),
      // Watch together sits after Quick Connect, as on Apple.
      ...widget.moduleRows.where((r) => r.after == SettingsPage.account),
      for (final page in [
        SettingsPage.display,
        SettingsPage.playback,
        SettingsPage.subtitles,
        SettingsPage.controls,
        SettingsPage.storage,
      ]) ...[
        ProfileRowData(page.title, page.icon, () => _settings(page)),
        ...widget.moduleRows.where((r) => r.after == page),
      ],
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
                      'Dashboard',
                      Icons.speed_rounded,
                      () => _push(
                        WebHandoffScreen(
                          title: 'Dashboard',
                          path: 'dashboard',
                          state: widget.state,
                        ),
                      ),
                    ),
                  ),
                  _ProfileRow(
                    data: ProfileRowData(
                      'Metadata Manager',
                      Icons.edit_note_rounded,
                      () => _push(
                        WebHandoffScreen(
                          title: 'Metadata Manager',
                          path: 'metadata',
                          state: widget.state,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                if (_administrator && widget.accountApprovals)
                  _ProfileRow(
                    utility: true,
                    data: ProfileRowData(
                      'Account approvals',
                      Icons.how_to_reg_rounded,
                      () => _push(
                        WebHandoffScreen(
                          title: 'Account approvals',
                          path: 'mypreferencesmenu',
                          state: widget.state,
                        ),
                      ),
                    ),
                  ),
                for (final row in widget.utilityRows)
                  _ProfileRow(data: row, utility: true),
                const SizedBox(height: 16),
                ZoroButton(
                  label: catalog.isPreview ? 'Leave preview' : 'Sign Out',
                  icon: Icons.logout_rounded,
                  expand: true,
                  onPressed: widget.state.signOut,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.data,
    this.autofocus = false,
    this.utility = false,
  });

  final ProfileRowData data;
  final bool autofocus;
  final bool utility;

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
            color: utility ? Zoro.panel.withValues(alpha: 0.6) : Zoro.panel,
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
