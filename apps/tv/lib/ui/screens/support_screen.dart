import 'package:flutter/material.dart';

import '../../core/server_extras.dart';
import '../../extras_state.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import 'settings_screen.dart';

/// Support (Apple `HomeUtilityView(.support)` TV layout): a fixed header with
/// Done over the report form, then the submission status.
class SupportScreen extends StatefulWidget {
  const SupportScreen({
    super.key,
    required this.extras,
    required this.viewerName,
  });

  final ExtrasState extras;
  final String viewerName;

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  late final _media = TextEditingController(text: widget.extras.supportMedia);
  late final _description = TextEditingController(
    text: widget.extras.supportDescription,
  );

  /// Consent is per report and never remembered.
  bool _consent = false;

  ExtrasState get _extras => widget.extras;

  @override
  void initState() {
    super.initState();
    _media.addListener(() => _extras.editSupport(media: _media.text));
    _description.addListener(
      () => _extras.editSupport(description: _description.text),
    );
    _extras.addListener(_sync);
  }

  /// A successful send clears the form in the shared state.
  void _sync() {
    if (_extras.supportMedia.isEmpty && _media.text.isNotEmpty) {
      _media.clear();
    }
    if (_extras.supportDescription.isEmpty && _description.text.isNotEmpty) {
      _description.clear();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _extras.removeListener(_sync);
    _media.dispose();
    _description.dispose();
    super.dispose();
  }

  bool get _canEdit =>
      _extras.submission == SupportSubmission.idle ||
      _extras.submission == SupportSubmission.rejected;

  @override
  Widget build(BuildContext context) {
    final extras = _extras;
    return SettingsScaffold(
      title: 'Support',
      actions: [
        ZoroButton(
          label: 'Done',
          autofocus: !_canEdit || !extras.features.support,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
      children: [
        if (extras.isPreview)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Preview only · No report will be sent',
              style: Zoro.font(18, color: Zoro.jade),
            ),
          ),
        if (!extras.features.support)
          _Status(
            title: 'Support unavailable',
            detail:
                'This server does not currently offer support for your account.',
          )
        else ...[
          Text(
            'How can we help?',
            style: Zoro.font(32, weight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Send an issue to your server’s support agent. Replies appear under the notification bell.',
            style: Zoro.font(22, color: Zoro.muted),
          ),
          const SizedBox(height: 20),
          if (_canEdit) ..._form(extras),
          ..._submissionStatus(extras),
        ],
      ],
    );
  }

  List<Widget> _form(ExtrasState extras) {
    final report = extras.supportReport;
    return [
      SettingsPicker<String>(
        title: 'Issue',
        value: extras.supportIssue,
        options: [for (final issue in supportIssues) (issue, issue)],
        onChanged: (v) => extras.editSupport(issue: v),
      ),
      const SizedBox(height: 10),
      SettingsTextField(
        label: 'Movie, show or channel (optional)',
        controller: _media,
        autofocus: true,
      ),
      _Counter('${_media.text.length}/200'),
      SettingsTextField(label: 'What happened?', controller: _description),
      _Counter('${_description.text.length}/1,500'),
      const SizedBox(height: 12),
      Text(
        'Sending as ${widget.viewerName}',
        style: Zoro.font(22, weight: FontWeight.w600),
      ),
      const SettingsFootnote(
        'Your report, affected title and account context go to this server’s administrators and support service. The service may send them to its configured AI support provider and consult relevant server diagnostics. Ask your server owner about that provider before sending sensitive information. Leave out passwords and payment details.',
      ),
      const SizedBox(height: 8),
      SettingsToggle(
        title:
            'I agree to share this report for server support and possible AI processing',
        value: _consent,
        onChanged: (v) => setState(() => _consent = v),
      ),
      const SizedBox(height: 8),
      SettingsAction(
        title: 'Send report',
        icon: Icons.send_rounded,
        enabled: !extras.isPreview && report.isValid && _consent,
        onPressed: () {
          setState(() => _consent = false);
          extras.sendSupport();
        },
      ),
    ];
  }

  List<Widget> _submissionStatus(
    ExtrasState extras,
  ) => switch (extras.submission) {
    SupportSubmission.idle => const [],
    SupportSubmission.sending => [
      const SizedBox(height: 12),
      Row(
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(width: 16),
          Text('Sending your report…', style: Zoro.font(22)),
        ],
      ),
    ],
    SupportSubmission.accepted => [
      Row(
        children: [
          Icon(Icons.check_circle_rounded, color: Zoro.jade),
          const SizedBox(width: 12),
          Text(
            'Report received',
            style: Zoro.font(24, weight: FontWeight.w600, color: Zoro.jade),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text('Reference: ${extras.ticketId}', style: Zoro.font(18)),
      const SizedBox(height: 8),
      Text(
        'Your server’s support agent will review it. Watch Notifications for a reply.',
        style: Zoro.font(22, color: Zoro.muted),
      ),
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: ZoroButton(
          label: 'Start another report',
          onPressed: extras.startAnotherReport,
        ),
      ),
    ],
    SupportSubmission.rejected => [
      const SizedBox(height: 12),
      Text(
        SupportError.rejected.message,
        style: Zoro.font(22, color: Zoro.muted),
      ),
    ],
    SupportSubmission.uncertain => [
      Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: Zoro.text),
          const SizedBox(width: 12),
          Text(
            'Delivery unconfirmed',
            style: Zoro.font(24, weight: FontWeight.w600),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        SupportError.outcomeUnknown.message,
        style: Zoro.font(22, color: Zoro.muted),
      ),
    ],
  };
}

class _Counter extends StatelessWidget {
  const _Counter(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
    child: Text(text, style: Zoro.font(16, color: Zoro.muted)),
  );
}

class _Status extends StatelessWidget {
  const _Status({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 60),
    child: Column(
      children: [
        const Icon(Icons.support_agent_rounded, size: 56, color: Zoro.muted),
        const SizedBox(height: 16),
        Text(title, style: Zoro.font(28, weight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(
          detail,
          textAlign: TextAlign.center,
          style: Zoro.font(22, color: Zoro.muted),
        ),
      ],
    ),
  );
}
