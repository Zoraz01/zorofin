import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/errors.dart';
import '../core/jellyfin_client.dart';
import '../core/models.dart';
import '../core/public_info.dart';
import '../core/saved_connections.dart';
import '../core/profile_spotlight.dart';
import '../core/server_address.dart';
import '../ui/theme.dart';
import '../ui/widgets/profile_backdrop.dart';
import 'phone_info.dart';
import 'phone_theme.dart';
import 'phone_widgets.dart';

/// First page (Apple `ConnectView` on iPhone): the server address with an
/// HTTPS/HTTP choice, then sign-in on the next page. The field starts empty;
/// no server address is bundled.
class PhoneConnectScreen extends StatefulWidget {
  const PhoneConnectScreen({
    super.key,
    required this.state,
    this.adding = false,
  });

  final AppState state;

  /// Opened from Who's watching to add a server, rather than as the first page.
  final bool adding;

  @override
  State<PhoneConnectScreen> createState() => _PhoneConnectScreenState();
}

class _PhoneConnectScreenState extends State<PhoneConnectScreen> {
  final _address = TextEditingController();
  bool _http = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_busy || _address.text.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final input = _address.text.trim();
      final typed = input.toLowerCase();
      final schemeTyped = typed.contains('://');
      final http = typed.startsWith('http://') || (_http && !schemeTyped);
      var server = ServerAddress.fromUserInput(
        http && !schemeTyped ? 'http://$input' : input,
        allowsLocalHttp: http,
      );
      var client = widget.state.clientFor(server);
      PublicSystemInfo info;
      try {
        info = await client.systemInfo();
      } on ClientError catch (e) {
        // A bare local address also tries HTTP, as on iPhone.
        if (e.kind != ClientErrorKind.network ||
            schemeTyped ||
            http ||
            !ServerAddress.isLocalHost(server.url.host)) {
          rethrow;
        }
        server = ServerAddress.fromUserInput(
          'http://$input',
          allowsLocalHttp: true,
        );
        client = widget.state.clientFor(server);
        info = await client.systemInfo();
        if (mounted) setState(() => _http = true);
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PhoneSignInScreen(
            state: widget.state,
            client: client,
            serverName: info.serverName ?? '',
          ),
        ),
      );
    } on ClientError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _scheme(String label, bool http, String hint) => Expanded(
    child: Semantics(
      selected: _http == http,
      label: hint,
      excludeSemantics: true,
      child: PillButton(
        label: label,
        icon: _http == http
            ? Icons.check_circle_rounded
            : Icons.circle_outlined,
        primary: _http == http,
        expand: true,
        onPressed: () => setState(() => _http = http),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: widget.adding ? AppBar(backgroundColor: Zoro.background) : null,
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Image.asset(
                  'assets/images/wordmark.png',
                  height: 38,
                  semanticLabel: 'Zorofin',
                ),
                const SizedBox(height: 32),
                Text(
                  'Connect to\nyour server.',
                  style: Zoro.font(34, weight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(
                  'Enter your Jellyfin server address. You’ll sign in next.',
                  style: Zoro.font(16, color: Zoro.muted),
                ),
                const SizedBox(height: 24),
                Text(
                  'Server address',
                  style: Zoro.font(14, weight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _scheme('HTTPS', false, 'HTTPS, secure connection'),
                    const SizedBox(width: 12),
                    _scheme('HTTP', true, 'HTTP, local network only'),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _address,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: Zoro.font(17),
                  decoration: const InputDecoration(
                    hintText: 'jellyfin.example.com',
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _next(),
                ),
                if (_http) ...[
                  const SizedBox(height: 8),
                  Text(
                    'HTTP is only for servers on your home network. Your password is sent unencrypted.',
                    style: Zoro.font(13, color: Zoro.muted),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: Zoro.font(15, color: const Color(0xFFFF8A80)),
                  ),
                ],
                const SizedBox(height: 20),
                PillButton(
                  label: 'Next',
                  primary: true,
                  expand: true,
                  busy: _busy,
                  onPressed: _address.text.trim().isEmpty ? null : _next,
                ),
                if (!widget.adding) ...[
                  const SizedBox(height: 12),
                  PillButton(
                    label: 'Explore the app preview',
                    expand: true,
                    onPressed: widget.state.openPreview,
                  ),
                ],
                const SizedBox(height: 24),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () =>
                          openPublicDocument(context, PublicDocument.privacy),
                      child: Text(
                        'Privacy Policy',
                        style: Zoro.font(14, color: Zoro.muted),
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          openPublicDocument(context, PublicDocument.support),
                      child: Text(
                        'App Support',
                        style: Zoro.font(14, color: Zoro.muted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Sign-in page: Quick Connect or username and password, with Keep this
/// account on this device.
class PhoneSignInScreen extends StatefulWidget {
  const PhoneSignInScreen({
    super.key,
    required this.state,
    required this.client,
    this.serverName = '',
    this.username = '',
    this.expectedViewerId,
  });

  final AppState state;
  final JellyfinClient client;
  final String serverName;
  final String username;

  /// Signing in again for a saved account must stay that viewer.
  final String? expectedViewerId;

  @override
  State<PhoneSignInScreen> createState() => _PhoneSignInScreenState();
}

class _PhoneSignInScreenState extends State<PhoneSignInScreen> {
  late final _user = TextEditingController(text: widget.username);
  final _password = TextEditingController();
  bool _busy = false;
  bool _passwordMode = true;
  String? _error;
  String? _quickCode;
  late bool _remember = widget.state.supportsPersistentSignIn;
  int _operation = 0;

  @override
  void dispose() {
    _operation++;
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ClientError catch (e) {
      if (mounted) {
        setState(
          () => _error = e.kind == ClientErrorKind.unauthorized
              ? 'That username or password was not accepted by this server. Try again.'
              : e.message,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish(Session session) async {
    final expected = widget.expectedViewerId;
    if (expected != null && session.viewer.id != expected) {
      if (mounted) {
        setState(
          () => _error =
              'That sign-in belongs to a different account. Sign in as the selected account, or use Add account to keep another viewer.',
        );
      }
      return;
    }
    await widget.state.signedIn(
      session,
      serverName: widget.serverName,
      remember: _remember,
    );
  }

  Future<void> _signIn() => _run(() async {
    FocusScope.of(context).unfocus();
    final id = ++_operation;
    final session = await widget.client.login(
      _user.text.trim(),
      _password.text,
    );
    _password.clear();
    if (id == _operation) await _finish(session);
  });

  Future<void> _quickConnect() => _run(() async {
    final id = ++_operation;
    _password.clear();
    final challenge = await widget.client.initiateQuickConnect();
    if (!mounted || id != _operation) return;
    setState(() => _quickCode = challenge.code);
    try {
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!mounted || id != _operation) return;
        final state = await widget.client.quickConnectState(challenge.secret);
        if (!state.authenticated) continue;
        final session = await widget.client.completeQuickConnect(
          challenge.secret,
        );
        if (id == _operation) await _finish(session);
        return;
      }
      if (mounted && id == _operation) {
        setState(
          () => _error = 'This code expired. Start Quick Connect again.',
        );
      }
    } finally {
      if (mounted && id == _operation) setState(() => _quickCode = null);
    }
  });

  void _cancel() {
    _operation++;
    setState(() {
      _quickCode = null;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.serverName.isEmpty
        ? widget.client.server.url.host
        : widget.serverName;
    final code = _quickCode;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Zoro.background,
        leading: IconButton(
          tooltip: 'Change server',
          icon: const Icon(Icons.chevron_left_rounded, size: 30),
          onPressed: () {
            _cancel();
            Navigator.of(context).maybePop();
          },
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.dns_rounded, size: 22),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          name,
                          style: Zoro.font(19, weight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.client.server.url.toString(),
                    style: Zoro.font(14, color: Zoro.muted),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Sign in',
                    style: Zoro.font(32, weight: FontWeight.w700),
                  ),
                  const SizedBox(height: 20),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('Password')),
                      ButtonSegment(value: false, label: Text('Quick Connect')),
                    ],
                    selected: {_passwordMode},
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      selectedBackgroundColor: Zoro.jade,
                      selectedForegroundColor: Zoro.background,
                      foregroundColor: Zoro.text,
                      side: const BorderSide(color: Zoro.border),
                    ),
                    onSelectionChanged: (value) {
                      _cancel();
                      setState(() => _passwordMode = value.first);
                    },
                  ),
                  const SizedBox(height: 20),
                  if (_passwordMode) ...[
                    TextField(
                      controller: _user,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.username],
                      style: Zoro.font(17),
                      decoration: const InputDecoration(labelText: 'Username'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      textInputAction: TextInputAction.go,
                      autofillHints: const [AutofillHints.password],
                      style: Zoro.font(17),
                      decoration: const InputDecoration(labelText: 'Password'),
                      onSubmitted: (_) => _signIn(),
                    ),
                  ] else if (code != null) ...[
                    Text(
                      'On a device that’s signed in, open Quick Connect and enter this code.',
                      style: Zoro.font(15, color: Zoro.muted),
                    ),
                    const SizedBox(height: 14),
                    SelectableText(
                      code,
                      style: Zoro.font(
                        40,
                        weight: FontWeight.w700,
                        color: Zoro.jade,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(),
                  ] else
                    Text(
                      'Get a code here, then approve it from another device where you’re already signed in.',
                      style: Zoro.font(15, color: Zoro.muted),
                    ),
                  if (widget.state.supportsPersistentSignIn) ...[
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Keep this account on this device',
                        style: Zoro.font(16),
                      ),
                      value: _remember,
                      onChanged: (v) => setState(() => _remember = v),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: Zoro.font(15, color: const Color(0xFFFF8A80)),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (_passwordMode)
                    PillButton(
                      label: 'Sign in',
                      primary: true,
                      expand: true,
                      busy: _busy,
                      onPressed: _signIn,
                    )
                  else if (code == null)
                    PillButton(
                      label: 'Get a code',
                      primary: true,
                      expand: true,
                      busy: _busy,
                      onPressed: _quickConnect,
                    )
                  else
                    PillButton(
                      label: 'Cancel',
                      expand: true,
                      onPressed: _cancel,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Who's watching (Apple `SavedServersView`): saved accounts by server, with
/// add, remove and sign in again.
class PhoneAccountsScreen extends StatefulWidget {
  const PhoneAccountsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<PhoneAccountsScreen> createState() => _PhoneAccountsScreenState();
}

class _PhoneAccountsScreenState extends State<PhoneAccountsScreen> {
  AppState get _state => widget.state;
  String? _busyId;
  String? _error;
  bool _managing = false;
  late final ProfileSpotlights _spotlights = ProfileSpotlights(_state);

  @override
  void initState() {
    super.initState();
    _state.addListener(_changed);
    _spotlights.addListener(_changed);
    _spotlights.load();
  }

  @override
  void dispose() {
    _state.removeListener(_changed);
    _spotlights.removeListener(_changed);
    _spotlights.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (_state.connections.accounts.isEmpty) _managing = false;
    _spotlights.load();
    setState(() {});
  }

  bool get _signedIn => _state.catalog != null;

  void _close() {
    if (_signedIn && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _signIn({SavedServer? server, SavedAccount? account}) async {
    final address = account?.server ?? server?.address;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => address == null
            ? PhoneConnectScreen(state: _state, adding: true)
            : PhoneSignInScreen(
                state: _state,
                client: _state.clientFor(address),
                serverName: account?.serverName ?? server?.name ?? '',
                username: account?.viewer.name ?? '',
                expectedViewerId: account?.viewer.id,
              ),
      ),
    );
  }

  Future<void> _choose(SavedAccount account) async {
    if (_busyId != null) return;
    if (_state.isCurrent(account)) return _close();
    if (account.session == null) return _signIn(account: account);
    setState(() {
      _busyId = account.id;
      _error = null;
    });
    try {
      await _state.switchAccount(account.id);
      if (mounted) _close();
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
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '${account.viewer.name} on ${account.serverName}',
                style: Zoro.font(17, weight: FontWeight.w600),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.login_rounded),
              title: const Text('Sign in again'),
              onTap: () => Navigator.of(context).pop('signin'),
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: Color(0xFFFF8A80),
              ),
              title: const Text(
                'Remove from device',
                style: TextStyle(color: Color(0xFFFF8A80)),
              ),
              onTap: () => Navigator.of(context).pop('remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'signin') return _signIn(account: account);
    if (action != 'remove') return;
    final confirmed = await confirmPhone(
      context,
      title: 'Remove saved account?',
      detail:
          'Remove ${account.viewer.name} from ${account.serverName} on this device? Their server account, library and other saved sign-ins stay unchanged.',
      action: 'Remove',
    );
    if (!confirmed) return;
    setState(() => _busyId = account.id);
    try {
      await _state.removeAccount(account.id);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _addAccount() async {
    final servers = _state.connections.servers;
    if (servers.isEmpty) return _signIn();
    final chosen = await showModalBottomSheet<Object>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final server in servers)
              ListTile(
                leading: const Icon(Icons.dns_rounded),
                title: Text(server.name),
                subtitle: Text(server.address.url.toString()),
                onTap: () => Navigator.of(context).pop(server),
              ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('Another server'),
              onTap: () => Navigator.of(context).pop('new'),
            ),
          ],
        ),
      ),
    );
    if (chosen is SavedServer) await _signIn(server: chosen);
    if (chosen == 'new') await _signIn();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _state.connections.accounts;
    if (!_managing && accounts.isNotEmpty) return _backdropLayout(accounts);
    final servers = _state.connections.servers;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Zoro.background,
        automaticallyImplyLeading: false,
        title: Text(
          accounts.isEmpty ? 'Who’s watching?' : 'Manage accounts',
          style: Zoro.font(22, weight: FontWeight.w700),
        ),
        actions: [
          if (accounts.isNotEmpty)
            TextButton(
              onPressed: () => setState(() => _managing = false),
              child: const Text('Finish'),
            )
          else if (_signedIn)
            TextButton(onPressed: _close, child: const Text('Done')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Phone.gutter),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _error!,
                style: Zoro.font(15, color: const Color(0xFFFF8A80)),
              ),
            ),
          for (final server in servers) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Text(
                server.name,
                style: Zoro.font(
                  14,
                  weight: FontWeight.w600,
                  color: Zoro.muted,
                ),
              ),
            ),
            for (final account in server.accounts)
              Card(
                color: Zoro.panel,
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Phone.radius),
                  side: BorderSide(
                    color: _state.isCurrent(account) ? Zoro.jade : Zoro.border,
                  ),
                ),
                child: ListTile(
                  minTileHeight: 64,
                  leading: PhoneAvatar(
                    name: account.viewer.name,
                    size: 42,
                    rounded: true,
                  ),
                  title: Text(
                    account.viewer.name,
                    style: Zoro.font(17, weight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    account.session == null
                        ? 'Sign in again'
                        : _state.isCurrent(account)
                        ? 'Watching now'
                        : account.server.url.host,
                    style: Zoro.font(13, color: Zoro.muted),
                  ),
                  trailing: _busyId == account.id
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          tooltip: 'Manage ${account.viewer.name}',
                          icon: const Icon(Icons.more_horiz_rounded),
                          onPressed: () => _manage(account),
                        ),
                  onTap: () => _choose(account),
                ),
              ),
          ],
          const SizedBox(height: 16),
          PillButton(
            label: 'Add account',
            icon: Icons.person_add_alt_1_rounded,
            expand: true,
            onPressed: _addAccount,
          ),
          if (!_signedIn) ...[
            const SizedBox(height: 12),
            PillButton(
              label: 'Explore the app preview',
              expand: true,
              onPressed: _state.openPreview,
            ),
          ],
        ],
      ),
    );
  }

  /// Who's watching with the current profile's show as the backdrop. The
  /// phone opens the last-used profile, so this appears on first launch and
  /// from Profile; the ring marks the profile in use.
  Widget _backdropLayout(List<SavedAccount> accounts) {
    final shown =
        accounts.where(_state.isCurrent).firstOrNull ?? accounts.first;
    final spot = _spotlights[shown.id];
    final top = MediaQuery.paddingOf(context).top;
    final artHeight = MediaQuery.sizeOf(context).height * 0.36;
    return Scaffold(
      backgroundColor: Zoro.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          ProfileBackdrop(
            tv: false,
            artKey: '${shown.id}-${spot?.backdrop?.cacheKey ?? 'none'}',
            image: _spotlights.imageFor(shown, spot?.backdrop, width: 1280),
            fallbackAsset: sceneAvatarAsset(shown.viewer.id),
          ),
          ListView(
            padding: EdgeInsets.fromLTRB(24, top + artHeight, 24, 32),
            children: [
              Text(
                'Who’s watching?',
                style: Zoro.font(32, weight: FontWeight.w700),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: Zoro.font(15, color: const Color(0xFFFF8A80)),
                  ),
                ),
              const SizedBox(height: 16),
              SizedBox(
                height: 54,
                child: spot == null
                    ? null
                    : ProfileSpotlightCard(
                        name: shown.viewer.name,
                        spotlight: spot,
                        tv: false,
                        thumbnail: _spotlights.imageFor(
                          shown,
                          spot.thumbnail,
                          width: 320,
                        ),
                      ),
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 10,
                runSpacing: 18,
                children: [
                  for (final account in accounts)
                    Semantics(
                      button: true,
                      label:
                          '${account.viewer.name}${_state.isCurrent(account) ? ', current account' : account.session == null ? ', sign in again' : ''}',
                      excludeSemantics: true,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () => _choose(account),
                        onLongPress: () => _manage(account),
                        child: ProfileTile(
                          account: account,
                          size: 92,
                          tv: false,
                          ringed: _state.isCurrent(account),
                          busy: _busyId == account.id,
                          photo: account.viewer.primaryImageTag == null
                              ? null
                              : _state
                                    .clientFor(account.server)
                                    .userImage(
                                      account.viewer.id,
                                      tag: account.viewer.primaryImageTag,
                                    ),
                          headers: account.session == null
                              ? const {}
                              : _state
                                    .clientFor(account.server)
                                    .withSession(account.session!)
                                    .authHeaders,
                        ),
                      ),
                    ),
                  Semantics(
                    button: true,
                    label: 'Add account',
                    excludeSemantics: true,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: _addAccount,
                      child: const AddProfileTile(
                        size: 92,
                        tv: false,
                        ringed: false,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  PillButton(
                    label: 'Manage accounts',
                    icon: Icons.edit_rounded,
                    onPressed: () => setState(() {
                      _managing = true;
                      _error = null;
                    }),
                  ),
                  if (!_signedIn)
                    PillButton(
                      label: 'Explore the app preview',
                      onPressed: _state.openPreview,
                    ),
                ],
              ),
            ],
          ),
          if (_signedIn)
            Positioned(
              top: top + 8,
              right: 12,
              child: TextButton(onPressed: _close, child: const Text('Done')),
            ),
        ],
      ),
    );
  }
}

Future<bool> confirmPhone(
  BuildContext context, {
  required String title,
  required String action,
  String? detail,
  bool destructive = true,
}) async {
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
          style: TextButton.styleFrom(
            foregroundColor: destructive ? const Color(0xFFFF8A80) : Zoro.jade,
          ),
          child: Text(action),
        ),
      ],
    ),
  );
  return result ?? false;
}
