import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/session_store.dart';
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
  servers,
  quickConnect,
  watchTogether,
  settings,
}

/// The header avatar's menu, dropped below the avatar like the Apple TV
/// 1.1 `TVProfilePopover`: saved accounts first, then Change server, Quick
/// Connect and Watch together, with Settings at the bottom.
Future<AccountMenuChoice?> showAccountPopover(
  BuildContext context, {
  required AppState state,
  required Rect anchor,
  required String serverName,
  required bool watchTogether,
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
  ),
);

class _AccountPopover extends StatelessWidget {
  const _AccountPopover({
    required this.state,
    required this.anchor,
    required this.serverName,
    required this.watchTogether,
  });

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
    final pop = Navigator.of(context).pop;
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
                            size: 40,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              serverName.isEmpty ? 'Accounts' : serverName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Zoro.font(25, weight: FontWeight.w600),
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
                    const Divider(height: 1, color: Zoro.border),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.all(16),
                        children: [
                          for (final account in accounts)
                            _AccountRow(
                              account: account,
                              current: state.isCurrent(account),
                              autofocus:
                                  account == (current ?? accounts.firstOrNull),
                              onPressed: () => pop(
                                state.isCurrent(account)
                                    ? null
                                    : SwitchAccount(account),
                              ),
                            ),
                          if (accounts.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                'No saved accounts',
                                style: Zoro.font(20, color: Zoro.muted),
                              ),
                            ),
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Divider(height: 1, color: Zoro.border),
                          ),
                          _MenuRow(
                            'Change server',
                            Icons.dns_rounded,
                            () => pop(AccountMenuPage.servers),
                            autofocus: accounts.isEmpty,
                          ),
                          _MenuRow(
                            'Quick Connect',
                            Icons.phonelink_ring_rounded,
                            () => pop(AccountMenuPage.quickConnect),
                          ),
                          if (watchTogether)
                            _MenuRow(
                              'Watch together',
                              Icons.groups_rounded,
                              () => pop(AccountMenuPage.watchTogether),
                            ),
                        ],
                      ),
                    ),
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
  const _MenuRow(
    this.title,
    this.icon,
    this.onPressed, {
    this.autofocus = false,
  });

  final String title;
  final IconData icon;
  final VoidCallback onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => _Flat(
    label: title,
    autofocus: autofocus,
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

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.account,
    required this.current,
    required this.autofocus,
    required this.onPressed,
  });

  final SavedAccount account;
  final bool current;
  final bool autofocus;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: _Flat(
      label:
          '${account.viewer.name}, ${account.serverName}'
          '${current ? ', current account' : ''}',
      autofocus: autofocus,
      onPressed: onPressed,
      child: (fg) => Container(
        constraints: const BoxConstraints(minHeight: 72),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            ProfileAvatar(name: account.viewer.name, size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    account.viewer.name,
                    style: Zoro.font(
                      22,
                      weight: current ? FontWeight.w600 : FontWeight.w400,
                      color: fg,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Opacity(
                    opacity: 0.7,
                    child: Text(
                      account.session == null
                          ? 'Sign in again'
                          : account.serverName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Zoro.font(17, color: fg),
                    ),
                  ),
                ],
              ),
            ),
            if (current)
              Icon(
                Icons.check_rounded,
                color: fg == Zoro.text ? Zoro.jade : fg,
              ),
          ],
        ),
      ),
    ),
  );
}
