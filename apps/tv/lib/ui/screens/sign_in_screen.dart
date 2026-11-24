import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/errors.dart';
import '../../core/jellyfin_client.dart';
import '../../core/models.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import 'settings_screen.dart';
import '../widgets/tv_text_field.dart';

/// Second page: username/password or Quick Connect, which avoids typing a
/// password with a remote.
class SignInScreen extends StatefulWidget {
  const SignInScreen({
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

  /// Prefilled when signing a saved account in again.
  final String username;

  /// Signing in again must return the same viewer, so another person's
  /// sign-in never replaces a saved account.
  final String? expectedViewerId;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  late final _user = TextEditingController(text: widget.username);
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _quickCode;
  bool _remember = true;

  /// Bumped to cancel a running sign-in or Quick Connect wait.
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
    final id = ++_operation;
    final session = await widget.client.login(
      _user.text.trim(),
      _password.text,
    );
    _password.clear();
    if (id == _operation) await _finish(session);
  });

  /// Polls every 2 seconds for up to 2 minutes, as on Apple.
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
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(64),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 850),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ZoroButton(
                  label: 'Server',
                  icon: Icons.chevron_left_rounded,
                  onPressed: () {
                    _cancel();
                    Navigator.of(context).maybePop();
                  },
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    const Icon(Icons.dns_rounded, color: Zoro.text, size: 30),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        name,
                        style: Zoro.font(28, weight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  widget.client.server.url.toString(),
                  style: Zoro.font(20, color: Zoro.muted),
                ),
                const SizedBox(height: 22),
                Text('Sign in', style: Zoro.font(40, weight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  'Use an account on this server.',
                  style: Zoro.font(24, color: Zoro.muted),
                ),
                const SizedBox(height: 22),
                if (code != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Zoro.panel,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Approve this device',
                          style: Zoro.font(24, weight: FontWeight.w700),
                        ),
                        const SizedBox(height: 12),
                        Semantics(
                          label:
                              'Quick Connect code ${code.split('').join(' ')}',
                          excludeSemantics: true,
                          child: Text(
                            code,
                            style: Zoro.font(
                              56,
                              weight: FontWeight.w600,
                            ).copyWith(letterSpacing: 7),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'In an already signed-in Jellyfin app, open Quick Connect and enter this code.',
                          style: Zoro.font(20, color: Zoro.muted),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: Zoro.jade,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text('Waiting for approval…', style: Zoro.font(20)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ZoroButton(
                          label: 'Cancel',
                          autofocus: true,
                          onPressed: _cancel,
                        ),
                      ],
                    ),
                  )
                else ...[
                  ZoroButton(
                    label: 'Use Quick Connect',
                    icon: Icons.link_rounded,
                    primary: true,
                    expand: true,
                    autofocus: widget.username.isEmpty,
                    onPressed: _quickConnect,
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      const Expanded(child: Divider(color: Zoro.border)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          'or sign in',
                          style: Zoro.font(16, color: Zoro.muted),
                        ),
                      ),
                      const Expanded(child: Divider(color: Zoro.border)),
                    ],
                  ),
                  const SizedBox(height: 18),
                  TvTextField(
                    controller: _user,
                    enabled: !_busy,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    style: Zoro.font(26),
                    decoration: const InputDecoration(hintText: 'Username'),
                  ),
                  const SizedBox(height: 16),
                  TvTextField(
                    controller: _password,
                    enabled: !_busy,
                    autofocus: widget.username.isNotEmpty,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    style: Zoro.font(26),
                    decoration: const InputDecoration(hintText: 'Password'),
                    onSubmitted: (_) => _signIn(),
                  ),
                  const SizedBox(height: 16),
                  ZoroButton(
                    label: _busy ? 'Signing in…' : 'Sign in',
                    expand: true,
                    onPressed: _signIn,
                  ),
                ],
                const SizedBox(height: 16),
                SettingsToggle(
                  title: 'Keep this account on this device',
                  value: _remember,
                  enabled: !_busy,
                  onChanged: (v) => setState(() => _remember = v),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: Zoro.font(22, color: const Color(0xFFFF8A80)),
                  ),
                ],
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    'Your password is never saved.',
                    style: Zoro.font(16, color: Zoro.muted),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
