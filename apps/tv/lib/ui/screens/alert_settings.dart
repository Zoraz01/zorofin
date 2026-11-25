import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/errors.dart';
import '../../core/jellyfin_client.dart';
import '../../core/server_extras.dart';
import '../../core/viewer_settings.dart';
import 'settings_screen.dart';

/// Email and push alert sections of Notification settings (Apple
/// `notificationFields`), for servers with the notificationSettings module.
class AlertSettingsFields extends StatefulWidget {
  const AlertSettingsFields({super.key, required this.client});

  final JellyfinClient client;

  @override
  State<AlertSettingsFields> createState() => _AlertSettingsFieldsState();
}

class _AlertSettingsFieldsState extends State<AlertSettingsFields> {
  RequestAlertSettings? _alerts;
  bool _loading = true;
  bool _busy = false;
  String? _status;
  String? _error;
  final _email = TextEditingController();

  @override
  void initState() {
    super.initState();
    _email.addListener(() => setState(() {}));
    unawaited(_load());
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final alerts = await widget.client.requestAlertSettings();
      if (mounted) setState(() => _alerts = alerts);
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _message(Object error) => switch (error) {
    SettingsException(:final error) => error.message,
    ClientError e => e.message,
    _ => 'Notification settings could not be loaded. Try again.',
  };

  Future<void> _action(RequestAlertAction action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final result = await widget.client.updateRequestAlerts(
        action,
        email: _email.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _alerts = result;
        _status = result.message ?? 'Notification settings updated.';
        if (action == RequestAlertAction.saveEmail) _email.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _alerts = _alerts?.withoutCredentials();
        _error = _message(e);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm(
    RequestAlertAction action,
    String title,
    String button, {
    String? detail,
  }) async {
    if (await confirmDialog(context, title, button, detail: detail)) {
      await _action(action);
    }
  }

  @override
  Widget build(BuildContext context) {
    final alerts = _alerts;
    final children = <Widget>[
      if (_status != null) SettingsFootnote(_status!),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
          child: Text(
            _error!,
            style: settingsFont(context, 20, color: const Color(0xFFFF8A80)),
          ),
        ),
    ];
    if (alerts == null) {
      if (_loading) {
        children.add(const SettingsFootnote('Loading notification settings…'));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    final credentials = alerts.credentials;
    children.addAll([
      const SettingsSectionHeader('Email alerts'),
      if (alerts.emailEnabled)
        SettingsInfo(title: 'Current address', value: alerts.maskedAddress),
      SettingsTextField(
        label: 'Email address',
        controller: _email,
        enabled: !_busy,
        keyboardType: TextInputType.emailAddress,
      ),
      SettingsAction(
        title: alerts.emailEnabled ? 'Update email' : 'Enable email alerts',
        enabled: !_busy && _email.text.contains('@'),
        onPressed: () => _action(RequestAlertAction.saveEmail),
      ),
      if (alerts.emailEnabled) ...[
        SettingsAction(
          title: 'Send test email',
          enabled: !_busy,
          onPressed: () => _action(RequestAlertAction.testEmail),
        ),
        SettingsAction(
          title: 'Turn off email alerts',
          destructive: true,
          enabled: !_busy,
          onPressed: () => _confirm(
            RequestAlertAction.removeEmail,
            'Turn off email alerts?',
            'Turn off email alerts',
          ),
        ),
      ],
      const SettingsSectionHeader('Push through your server'),
      const SettingsFootnote(
        'These alerts use your server’s ntfy service. They are separate from the app’s inbox.',
      ),
      if (alerts.pushEnabled) ...[
        const SettingsInfo(title: 'Status', value: 'Enabled'),
        if (alerts.pushTopic != null)
          SettingsInfo(title: 'Topic', value: alerts.pushTopic!),
        SettingsFootnote(alerts.pushServer),
        SettingsAction(
          title: 'Send test notification',
          enabled: !_busy,
          onPressed: () => _action(RequestAlertAction.testPush),
        ),
        SettingsAction(
          title: 'Replace push password',
          enabled: !_busy,
          onPressed: () => _confirm(
            RequestAlertAction.resetPush,
            'Replace push password?',
            'Replace password',
            detail:
                'The previous push password will stop working. Save the new password when it appears.',
          ),
        ),
        SettingsAction(
          title: 'Turn off push alerts',
          destructive: true,
          enabled: !_busy,
          onPressed: () => _confirm(
            RequestAlertAction.removePush,
            'Turn off push alerts?',
            'Turn off push alerts',
          ),
        ),
      ] else
        SettingsAction(
          title: 'Set up push alerts',
          enabled: !_busy,
          onPressed: () => _action(RequestAlertAction.createPush),
        ),
      if (credentials != null) ...[
        const SettingsFootnote(
          'Save these details in your ntfy app. The password is shown only now.',
        ),
        SettingsInfo(title: 'Server', value: credentials.server),
        SettingsInfo(title: 'Topic', value: credentials.topic),
        SettingsInfo(title: 'Username', value: credentials.username),
        SettingsInfo(title: 'Password', value: credentials.password),
      ],
    ]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
