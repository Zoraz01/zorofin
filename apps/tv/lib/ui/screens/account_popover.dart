import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/session_store.dart';
import '../../core/plugin_extras.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import 'shell.dart';

/// What the viewer picked in the account menu.
sealed class AccountMenuChoice {
  const AccountMenuChoice();
}

class SwitchAccount extends AccountMenuChoice {
  const SwitchAccount(this.account);
  final SavedAccount account;
}

enum AccountMenuPage implements AccountMenuChoice {
  calendar,
  catchUp,
  servers,
  quickConnect,
  watchTogether,
  pickTogether,
  settings,
}

/// The header avatar's menu, dropped below the avatar like the Apple TV
/// `TVProfilePopover` (docs/design/TV_PROFILE_MENU.md): who is watching, a
/// Switch profile strip (other saved profiles, then All for Who's watching),
/// Pick Together, Watch Together, Calendar and Catch Up when available, and
/// Settings last.
Future<AccountMenuChoice?> showAccountPopover(
  BuildContext context, {
  required AppState state,
  required Rect anchor,
  required String serverName,
  required bool watchTogether,
  bool pickTogether = false,
  PluginExtras extras = PluginExtras.none,
}) => showGeneralDialog<AccountMenuChoice>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close account menu',
  barrierColor: const Color(0x2E000000),
  transitionDuration: const Duration(milliseconds: 160),
  transitionBuilder: (context, animation, _, child) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
    child: child,
  ),
  pageBuilder: (context, _, _) => _AccountPopover(
    state: state,
    anchor: anchor,
    serverName: serverName,
    watchTogether: watchTogether,
    pickTogether: pickTogether,
    extras: extras,
  ),
);

class _AccountPopover extends StatelessWidget {
  const _AccountPopover({
    required this.state,
    required this.anchor,
    required this.serverName,
    required this.watchTogether,
    required this.extras,
    this.pickTogether = false,
  });

  /// The server offers Pick Together; this TV hosts.
  final bool pickTogether;

  /// Calendar and Catch Up, when the server offers them.
  final PluginExtras extras;

  final AppState state;
  final Rect anchor;
  final String serverName;
  final bool watchTogether;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48).clamp(0.0, 460.0);
    final left = (anchor.right - width).clamp(24.0, size.width - width - 24);
    final top = anchor.bottom + 14;
    final accounts = state.connections.accounts;
    final current = accounts.where(state.isCurrent).firstOrNull;
    final others = [
      for (final account in accounts)
        if (!state.isCurrent(account)) account,
    ];
    final pop = Navigator.of(context).pop;
    final activities = [
      if (pickTogether)
        _MenuRow(
          'Pick Together',
          Icons.style_rounded,
          () => pop(AccountMenuPage.pickTogether),
        ),
      if (watchTogether)
        _MenuRow(
          'Watch Together',
          Icons.groups_rounded,
          () => pop(AccountMenuPage.watchTogether),
        ),
      if (extras.calendar)
        _MenuRow(
          'Calendar',
          Icons.calendar_month_rounded,
          () => pop(AccountMenuPage.calendar),
        ),
      if (extras.catchUp)
        _MenuRow(
          'Catch Up',
          Icons.view_list_rounded,
          () => pop(AccountMenuPage.catchUp),
        ),
    ];
    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: width,
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              constraints: BoxConstraints(maxHeight: size.height - top - 40),
              decoration: BoxDecoration(
                color: const Color(0xF2232A26),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0x29FFFFFF)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x59000000),
                    blurRadius: 40,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: FocusTraversalGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
                      child: Row(
                        children: [
                          ProfileAvatar(
                            name: current?.viewer.name ?? '',
                            size: 56,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  current?.viewer.name ?? 'Accounts',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Zoro.font(25, weight: FontWeight.w600),
                                ),
                                if (serverName.isNotEmpty)
                                  Text(
                                    serverName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Zoro.font(18, color: Zoro.muted),
                                  ),
                              ],
                            ),
                          ),
                          _Flat(
                            label: 'Close account menu',
                            onPressed: pop,
                            child: (_) => const SizedBox(
                              width: 48,
                              height: 48,
                              child: Icon(Icons.close_rounded, size: 26),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'SWITCH PROFILE',
                            style: Zoro.font(
                              16,
                              weight: FontWeight.w600,
                              color: Zoro.muted,
                            ).copyWith(letterSpacing: 1.2),
                          ),
                          const SizedBox(height: 10),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            clipBehavior: Clip.none,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final (i, account) in others.indexed)
                                  _ProfileTile(
                                    label:
                                        '${account.viewer.name}, ${account.serverName}',
                                    name: account.viewer.name,
                                    autofocus: i == 0,
                                    onPressed: () =>
                                        pop(SwitchAccount(account)),
                                    avatar: ProfileAvatar(
                                      name: account.viewer.name,
                                      size: 72,
                                    ),
                                  ),
                                _ProfileTile(
                                  label: 'All profiles',
                                  name: 'All',
                                  autofocus: others.isEmpty,
                                  onPressed: () => pop(AccountMenuPage.servers),
                                  avatar: Container(
                                    width: 72,
                                    height: 72,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(18),
                                      border: Border.all(
                                        color: Zoro.border,
                                        width: 2,
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.more_horiz_rounded,
                                      size: 30,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (activities.isNotEmpty) ...[
                      const Divider(height: 1, color: Zoro.border),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(children: activities),
                      ),
                    ],
                    const Divider(height: 1, color: Zoro.border),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: _MenuRow(
                        'Settings',
                        Icons.settings_rounded,
                        () => pop(AccountMenuPage.settings),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A full-width row that lights up when focused (Apple `FlatOptionStyle`).
class _Flat extends StatelessWidget {
  const _Flat({
    required this.label,
    required this.onPressed,
    required this.child,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onPressed;

  /// Builds the row in the given foreground colour.
  final Widget Function(Color foreground) child;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Focusable(
    autofocus: autofocus,
    semanticLabel: label,
    onPressed: onPressed,
    builder: (context, focused) => AnimatedContainer(
      duration: Zoro.focusDuration,
      decoration: BoxDecoration(
        color: focused ? Zoro.text : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: IconTheme(
        data: IconThemeData(color: focused ? Zoro.background : Zoro.text),
        child: child(focused ? Zoro.background : Zoro.text),
      ),
    ),
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.title, this.icon, this.onPressed);

  final String title;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => _Flat(
    label: title,
    onPressed: onPressed,
    child: (fg) => Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Icon(icon, size: 28),
          const SizedBox(width: 16),
          Text(title, style: Zoro.font(22, color: fg)),
        ],
      ),
    ),
  );
}

/// One profile in the Switch profile strip: a rounded-square avatar and
/// name, lit when focused.
class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.label,
    required this.name,
    required this.avatar,
    required this.onPressed,
    this.autofocus = false,
  });

  final String label;
  final String name;
  final Widget avatar;
  final VoidCallback onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 10),
    child: _Flat(
      label: label,
      autofocus: autofocus,
      onPressed: onPressed,
      child: (fg) => Container(
        width: 96,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            avatar,
            const SizedBox(height: 8),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Zoro.font(18, color: fg),
            ),
          ],
        ),
      ),
    ),
  );
}
