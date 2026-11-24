import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/errors.dart';
import '../../core/models.dart';
import '../../core/server_address.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import 'sign_in_screen.dart';
import '../widgets/tv_text_field.dart';

/// First page: an empty server address field. No server is bundled; the app
/// works with any Jellyfin server the viewer enters.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.state, this.adding = false});

  final AppState state;

  /// Opened from Who's watching to add a server; offers Cancel instead of
  /// the preview.
  final bool adding;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _address = TextEditingController();

  /// HTTPS unless the viewer picks HTTP for a server on their own network
  /// (Apple's tvOS scheme selector).
  bool _http = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final input = _address.text.trim();
      final typed = input.toLowerCase();
      final schemeTyped = typed.contains('://');
      final http = typed.startsWith('http://') || (_http && !schemeTyped);
      // Local HTTP is allowed only for private-network addresses.
      var server = ServerAddress.fromUserInput(
        http && !schemeTyped ? 'http://$input' : input,
        allowsLocalHttp: http,
      );
      var client = widget.state.clientFor(server);
      PublicSystemInfo info;
      try {
        info = await client.systemInfo();
      } on ClientError catch (e) {
        // A home server typed as a bare IP (192.168.1.20:8096) usually has
        // no certificate, so fall back to HTTP for private addresses only.
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
        MaterialPageRoute(
          builder: (_) => SignInScreen(
            state: widget.state,
            client: client,
            serverName: info.serverName ?? '',
          ),
        ),
      );
    } on ClientError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _scheme(String label, bool http, String semantics) => Expanded(
    child: Semantics(
      selected: _http == http,
      label: semantics,
      excludeSemantics: true,
      child: ZoroButton(
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
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(64),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 850),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Image.asset(
                  'assets/images/wordmark.png',
                  height: 64,
                  semanticLabel: 'Zorofin',
                ),
                const SizedBox(height: 40),
                Text(
                  'Connect to\nyour server.',
                  style: Zoro.font(48, weight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                Text(
                  'Enter your Jellyfin server address. You’ll sign in next.',
                  style: Zoro.font(24, color: Zoro.muted),
                ),
                const SizedBox(height: 22),
                Text(
                  'Server address',
                  style: Zoro.font(16, weight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _scheme('HTTPS', false, 'HTTPS, secure connection'),
                    const SizedBox(width: 16),
                    _scheme('HTTP', true, 'HTTP, local network only'),
                  ],
                ),
                const SizedBox(height: 10),
                TvTextField(
                  controller: _address,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  autocorrect: false,
                  style: Zoro.font(26),
                  decoration: const InputDecoration(
                    hintText: 'Address, port or path',
                  ),
                  onSubmitted: (_) => _next(),
                ),
                const SizedBox(height: 10),
                Text(
                  _http
                      ? 'HTTP is unencrypted and only works for local servers. Add a port or path if needed.'
                      : 'No need to type https://. Add a port or path if needed, or paste a full URL.',
                  style: Zoro.font(18, color: Zoro.muted),
                ),
                const SizedBox(height: 22),
                ZoroButton(
                  label: _busy ? 'Connecting…' : 'Next',
                  primary: true,
                  expand: true,
                  onPressed: _next,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: Zoro.font(22, color: const Color(0xFFFF8A80)),
                  ),
                ],
                const SizedBox(height: 22),
                if (widget.adding)
                  ZoroButton(
                    label: 'Cancel',
                    expand: true,
                    onPressed: () => Navigator.of(context).maybePop(),
                  )
                else ...[
                  ZoroButton(
                    label: 'Explore the app preview',
                    expand: true,
                    onPressed: widget.state.openPreview,
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Preview uses fictional titles.',
                      style: Zoro.font(16, color: Zoro.muted),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
