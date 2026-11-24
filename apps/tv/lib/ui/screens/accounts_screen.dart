import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/errors.dart';
import '../../core/session_store.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import 'connect_screen.dart';
import 'settings_screen.dart';
import 'shell.dart';
import 'sign_in_screen.dart';

/// Who's watching? (Apple `SavedServersView`): every saved account as an
/// avatar, name and server address. Shared by app start, the account menu
/// and Profile. Manage accounts turns the list into an editing mode.
class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  bool _managing = false;
  String? _busyId;
  String? _error;

  AppState get _state => widget.state;
  SavedConnections get _connections => _state.connections;
  bool get _signedIn => _state.catalog != null;

  @override
  void initState() {
    super.initState();
    _state.addListener(_changed);
  }

  @override
  void dispose() {
    _state.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (_connections.accounts.isEmpty) _managing = false;
    setState(() {});
  }

  void _close() {
    if (_signedIn && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _signIn({SavedServer? server, SavedAccount? account}) async {
    final address = account?.server ?? server?.address;
    final route = address == null
        ? MaterialPageRoute<void>(
            builder: (_) => ConnectScreen(state: _state, adding: true),
          )
        : MaterialPageRoute<void>(
            builder: (_) => SignInScreen(
              state: _state,
              client: _state.clientFor(address),
              serverName: account?.serverName ?? server?.name ?? '',
              username: account?.viewer.name ?? '',
              expectedViewerId: account?.viewer.id,
            ),
          );
    await Navigator.of(context).push(route);
  }

  Future<void> _addAccount() async {
    final servers = _connections.servers;
    if (servers.length == 1) return _signIn(server: servers.first);
    final chosen = await showDialog<SavedServer>(
      context: context,
      barrierColor: const Color(0xCC000000),
      builder: (context) => _ChoiceDialog(
        title: 'Add account to a server',
        children: [
          for (final (i, server) in servers.indexed)
            ZoroButton(
              label: '${server.name} · ${server.address.url}',
              autofocus: i == 0,
              expand: true,
              onPressed: () => Navigator.of(context).pop(server),
            ),
        ],
      ),
    );
    if (chosen != null) await _signIn(server: chosen);
  }

  Future<void> _choose(SavedAccount account) async {
    if (_busyId != null) return;
    if (_managing) return _manage(account);
    if (_state.isCurrent(account)) return _close();
    if (account.session == null) return _signIn(account: account);
    setState(() {
      _busyId = account.id;
      _error = null;
    });
    try {
      await _state.switchAccount(account.id);
    } on ClientError catch (e) {
      if (!mounted) return;
      if (e.kind == ClientErrorKind.unauthorized) {
        setState(
          () => _error =
              '${account.viewer.name} needs to sign in again on ${account.serverName}.',
        );
        await _signIn(account: account);
      } else {
        setState(() => _error = '${account.serverName}: ${e.message}');
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _manage(SavedAccount account) async {
    final action = await showDialog<String>(
      context: context,
      barrierColor: const Color(0xCC000000),
      builder: (context) => _ChoiceDialog(
        title: '${account.viewer.name} on ${account.serverName}',
        children: [
          ZoroButton(
            label: 'Sign in again',
            autofocus: true,
            expand: true,
            onPressed: () => Navigator.of(context).pop('signin'),
          ),
          ZoroButton(
            label: 'Remove from device',
            expand: true,
            onPressed: () => Navigator.of(context).pop('remove'),
          ),
          ZoroButton(
            label: 'Cancel',
            expand: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'signin') return _signIn(account: account);
    if (action != 'remove') return;
    if (!await confirmDialog(
      context,
      'Remove saved account?',
      'Remove',
      detail:
          'Remove ${account.viewer.name} from ${account.serverName} on this device? Their server account, library and other saved sign-ins stay unchanged.',
    )) {
      return;
    }
    setState(() => _busyId = account.id);
    try {
      await _state.removeAccount(account.id);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _connections.accounts;
    final preferred =
        accounts.where(_state.isCurrent).firstOrNull ?? accounts.firstOrNull;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_signedIn)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Zoro.gutter,
                16,
                Zoro.gutter,
                0,
              ),
              child: Align(
                alignment: Alignment.centerRight,
                child: ZoroButton(label: 'Done', onPressed: _close),
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(Zoro.gutter),
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: FocusTraversalGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _managing ? 'Manage accounts' : 'Who’s watching?',
                          style: Zoro.font(42, weight: FontWeight.w700),
                        ),
                        const SizedBox(height: 18),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              _error!,
                              style: Zoro.font(
                                22,
                                color: const Color(0xFFFFB74D),
                              ),
                            ),
                          ),
                        for (final account in accounts)
                          _AccountRow(
                            account: account,
                            current: _state.isCurrent(account),
                            busy: _busyId == account.id,
                            editing: _managing,
                            autofocus: account == preferred,
                            headers: account.session == null
                                ? const {}
                                : _state
                                      .clientFor(account.server)
                                      .withSession(account.session!)
                                      .authHeaders,
                            photo: account.viewer.primaryImageTag == null
                                ? null
                                : _state
                                      .clientFor(account.server)
                                      .userImage(
                                        account.viewer.id,
                                        tag: account.viewer.primaryImageTag,
                                      ),
                            onPressed: () => _choose(account),
                          ),
                        if (accounts.isEmpty)
                          Text(
                            'Add an account to get started.',
                            style: Zoro.font(24, color: Zoro.muted),
                          ),
                        if (_connections.servers.isNotEmpty && !_managing)
                          _UtilityButton(
                            label: 'Add account',
                            icon: Icons.add_rounded,
                            onPressed: _addAccount,
                          ),
                        const SizedBox(height: 22),
                        Row(
                          children: [
                            _UtilityButton(
                              label: 'Add server',
                              autofocus: accounts.isEmpty,
                              onPressed: () => _signIn(),
                            ),
                            if (accounts.isNotEmpty) ...[
                              const SizedBox(width: 36),
                              _UtilityButton(
                                label: _managing
                                    ? 'Finish editing'
                                    : 'Manage accounts',
                                onPressed: () => setState(() {
                                  _managing = !_managing;
                                  _error = null;
                                }),
                              ),
                            ],
                            if (!_signedIn) ...[
                              const SizedBox(width: 36),
                              _UtilityButton(
                                label: 'Explore the app preview',
                                onPressed: _state.openPreview,
                              ),
                            ],
                          ],
                        ),
                      ],
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
}

/// One focus target per account; only the avatar shows the focus ring.
class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.account,
    required this.current,
    required this.busy,
    required this.editing,
    required this.autofocus,
    required this.onPressed,
    this.photo,
    this.headers = const {},
  });

  final SavedAccount account;
  final bool current;
  final bool busy;
  final bool editing;
  final bool autofocus;
  final VoidCallback onPressed;
  final Uri? photo;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final value = busy
        ? 'Connecting'
        : current
        ? 'Current account'
        : account.session == null
        ? 'Sign in again'
        : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Focusable(
        autofocus: autofocus,
        onPressed: onPressed,
        semanticLabel:
            '${editing ? 'Manage ' : ''}${account.viewer.name}, ${account.server.url}${value.isEmpty ? '' : ', $value'}',
        builder: (context, focused) => Row(
          children: [
            AnimatedScale(
              scale: Zoro.lift(context, focused, 1.04),
              duration: Zoro.focusDuration,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(96 * 0.22 + 5),
                      border: Border.all(
                        color: focused ? Zoro.text : Colors.transparent,
                        width: 3,
                      ),
                    ),
                    child: ProfileAvatar(
                      name: account.viewer.name,
                      size: 96,
                      photo: photo,
                      headers: headers,
                    ),
                  ),
                  if (busy)
                    const Positioned.fill(
                      child: Center(
                        child: CircularProgressIndicator(color: Zoro.text),
                      ),
                    ),
                  if (!busy && (editing || current))
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: const BoxDecoration(
                          color: Zoro.jade,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          editing ? Icons.edit_rounded : Icons.check_rounded,
                          size: 20,
                          color: Zoro.background,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 28),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    account.viewer.name,
                    style: Zoro.font(30, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    account.server.url.toString(),
                    style: Zoro.font(19, color: Zoro.muted),
                  ),
                  if (account.session == null)
                    Text(
                      'Sign in again',
                      style: Zoro.font(18, color: Zoro.jade),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Quiet text action with a focus underline (Apple `AccountUtilityButtonStyle`).
class _UtilityButton extends StatelessWidget {
  const _UtilityButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Focusable(
    autofocus: autofocus,
    onPressed: onPressed,
    semanticLabel: label,
    builder: (context, focused) => Container(
      constraints: const BoxConstraints(minHeight: Zoro.target),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            SizedBox(
              width: 96 + 10,
              height: 72,
              child: Icon(
                icon,
                size: 32,
                color: focused ? Zoro.text : Zoro.muted,
              ),
            ),
          if (icon != null) const SizedBox(width: 18),
          Container(
            padding: const EdgeInsets.only(bottom: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: focused ? Zoro.text : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: Text(
              label,
              style: Zoro.font(
                icon == null ? 24 : 26,
                weight: FontWeight.w500,
                color: focused ? Zoro.text : Zoro.muted,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ChoiceDialog extends StatelessWidget {
  const _ChoiceDialog({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 760,
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: Zoro.panel,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: FocusTraversalGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Zoro.font(30, weight: FontWeight.w700)),
              const SizedBox(height: 24),
              for (final child in children)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: child,
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Signs another device in with its Quick Connect code (Apple
/// `ProfileQuickConnectView`).
class QuickConnectScreen extends StatefulWidget {
  const QuickConnectScreen({super.key, required this.state});

  final AppState state;

  @override
  State<QuickConnectScreen> createState() => _QuickConnectScreenState();
}

class _QuickConnectScreenState extends State<QuickConnectScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _status;

  bool get _valid => RegExp(r'^\d{6}$').hasMatch(_code.text);

  @override
  void initState() {
    super.initState();
    _code.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _authorize() async {
    final client = widget.state.catalog?.client;
    if (!_valid || _busy || client == null) return;
    final generation = widget.state.generation;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final accepted = await client.authorizeQuickConnect(_code.text);
      if (!mounted || generation != widget.state.generation) return;
      setState(
        () => _status = accepted
            ? 'Device authorized. You can continue on your other device.'
            : 'That code could not be authorized. Check the code on your other device.',
      );
      if (accepted) _code.clear();
    } catch (_) {
      if (mounted) {
        setState(
          () => _status =
              'Authorization could not be confirmed. Check your other device before trying again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = widget.state.catalog;
    final preview = catalog?.isPreview ?? true;
    return SettingsScaffold(
      title: 'Quick Connect',
      actions: [
        ZoroButton(
          label: 'Done',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text(
            'Sign in another device',
            style: Zoro.font(28, weight: FontWeight.w700),
          ),
        ),
        SettingsFootnote(
          'Enter the Quick Connect code shown on your other device. Authorizing it signs that device into ${catalog?.viewerName ?? ''}’s account.',
        ),
        const SizedBox(height: 12),
        SettingsTextField(
          label: 'Six-digit code',
          controller: _code,
          enabled: !_busy && !preview,
          autofocus: !preview,
          keyboardType: TextInputType.number,
          onSubmitted: (_) => _authorize(),
        ),
        SettingsAction(
          title: _busy ? 'Authorizing…' : 'Authorize',
          enabled: _valid && !_busy && !preview,
          onPressed: _authorize,
        ),
        if (_status != null) SettingsFootnote(_status!),
        if (preview)
          const SettingsFootnote(
            'Connect your server to authorize another device.',
          ),
      ],
    );
  }
}

/// Opens a page on the server's web app. TVs have no supported embedded
/// browser, so the credential-free address is shown for a phone or computer
/// (Apple tvOS `ProfileWebHandoff`).
class WebHandoffScreen extends StatelessWidget {
  const WebHandoffScreen({
    super.key,
    required this.title,
    required this.path,
    required this.state,
  });

  final String title;

  /// Web app route, such as `dashboard` or `metadata`.
  final String path;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final client = state.catalog?.client;
    final url = client?.server.url.resolve('web/#/$path');
    return SettingsScaffold(
      title: title,
      actions: [
        ZoroButton(
          label: 'Done',
          autofocus: true,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
      children: [
        if (url == null)
          const SettingsFootnote(
            'Connect your server to manage these settings.',
          )
        else ...[
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Manage your server',
              style: Zoro.font(26, weight: FontWeight.w600),
            ),
          ),
          SettingsFootnote(
            'This page opens in your server’s web app. Check that you’re signed in as ${state.catalog?.viewerName ?? ''}; your browser may ask you to sign in.',
          ),
          const SettingsFootnote('Open this page on your phone or computer:'),
          Padding(
            padding: const EdgeInsets.all(8),
            child: SelectableText(url.toString(), style: Zoro.font(26)),
          ),
        ],
      ],
    );
  }
}
