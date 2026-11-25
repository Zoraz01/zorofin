import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/requests.dart';
import '../core/server_extras.dart';
import '../extras_state.dart';
import '../ui/theme.dart';
import 'phone_scope.dart';
import 'phone_theme.dart';
import 'phone_widgets.dart';

/// Bell with the unread count (Apple `MobileNotificationButton`); opens the
/// inbox as a sheet.
class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = PhoneScope.of(context);
    return ListenableBuilder(
      listenable: scope.extras,
      builder: (context, _) {
        final extras = scope.extras;
        final count = extras.unreadCount;
        final showBadge =
            scope.state.preferences.value.showUnreadBadge && count > 0;
        return RoundIconButton(
          icon: Icons.notifications_none_rounded,
          label: 'Notifications, $count unread updates',
          fill: Colors.transparent,
          badge: showBadge ? (count > 99 ? '99+' : '$count') : null,
          onPressed: () => openNotifications(context),
        );
      },
    );
  }
}

Future<void> openNotifications(BuildContext context) {
  final scope = PhoneScope.of(context);
  return showModalBottomSheet<void>(
    context: context,
    // Above the dock, which sits over pushed pages.
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheet) => FractionallySizedBox(
      heightFactor: 0.85,
      child: PhoneInbox(
        extras: scope.extras,
        onOpen: (item) {
          Navigator.of(sheet).pop();
          scope.open(item);
        },
      ),
    ),
  );
}

/// Request availability updates and support replies (Apple notifications
/// panel), newest first, with earlier updates on request.
class PhoneInbox extends StatefulWidget {
  const PhoneInbox({super.key, required this.extras, required this.onOpen});

  final ExtrasState extras;
  final ValueChanged<MediaItem> onOpen;

  @override
  State<PhoneInbox> createState() => _PhoneInboxState();
}

class _PhoneInboxState extends State<PhoneInbox> {
  final _sessionRequestIds = <int>{};
  final _sessionReplyKeys = <String>{};
  bool _showHidden = false;
  int? _openingId;
  String? _openError;

  ExtrasState get _extras => widget.extras;

  @override
  void initState() {
    super.initState();
    unawaited(_extras.refreshNotifications());
  }

  Future<void> _openRequest(RequestAvailabilityNotice notice) async {
    if (_openingId != null) return;
    final client = _extras.catalog.client;
    if (_extras.isPreview || client == null) {
      setState(
        () => _openError = 'Connect your server to open requested titles.',
      );
      return;
    }
    setState(() {
      _openingId = notice.id;
      _openError = null;
      _sessionRequestIds.add(notice.id);
    });
    try {
      final item = await client.requestNotificationItem(notice);
      await _extras.markRequestRead(notice);
      if (mounted) widget.onOpen(item);
    } catch (_) {
      if (mounted) {
        setState(
          () => _openError =
              'This title couldn’t be opened. Check its availability in Requests.',
        );
      }
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  Widget _request(RequestAvailabilityNotice notice, {required bool unread}) =>
      ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 40,
            height: 60,
            child: notice.posterUrl == null
                ? const ColoredBox(color: Zoro.background)
                : Image.network(
                    notice.posterUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const ColoredBox(color: Zoro.background),
                  ),
          ),
        ),
        title: Text(
          notice.title,
          style: Zoro.font(16, weight: FontWeight.w600),
        ),
        subtitle: Text(
          notice.is4K ? 'Ready to watch in 4K' : 'Ready to watch',
          style: Zoro.font(13, weight: FontWeight.w600, color: Zoro.jade),
        ),
        trailing: _openingId == notice.id
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : unread
            ? Icon(Icons.circle, size: 10, color: Zoro.jade)
            : null,
        onTap: () => _openRequest(notice),
      );

  Widget _reply(SupportReply reply, {required bool unread}) => ListTile(
    leading: CircleAvatar(
      backgroundColor: Zoro.avatar,
      child: Icon(Icons.support_agent_rounded, color: Zoro.jade),
    ),
    title: Text(reply.issueType, style: Zoro.font(16, weight: FontWeight.w600)),
    subtitle: Text(reply.message, style: Zoro.font(14, color: Zoro.muted)),
    trailing: unread ? Icon(Icons.circle, size: 10, color: Zoro.jade) : null,
    onTap: () {
      setState(() => _sessionReplyKeys.add(reply.notificationKey));
      unawaited(_extras.markReplyRead(reply));
    },
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _extras,
    builder: (context, _) {
      final newRequests = _extras.requestNotices
          .where(
            (n) =>
                !_extras.isRequestRead(n.id) ||
                _sessionRequestIds.contains(n.id),
          )
          .toList();
      final oldRequests = _extras.requestNotices
          .where(
            (n) =>
                _extras.isRequestRead(n.id) &&
                !_sessionRequestIds.contains(n.id),
          )
          .toList();
      final newReplies = _extras.replies
          .where(
            (r) =>
                !_extras.isReplyRead(r) ||
                _sessionReplyKeys.contains(r.notificationKey),
          )
          .toList();
      final oldReplies = _extras.readReplies
          .where((r) => !_sessionReplyKeys.contains(r.notificationKey))
          .toList();
      final history = oldRequests.length + oldReplies.length;
      final empty = newRequests.isEmpty && newReplies.isEmpty;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Notifications',
                    style: Zoro.font(22, weight: FontWeight.w700),
                  ),
                ),
                if (_extras.loadingNotifications)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                if (_openError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      _openError!,
                      style: Zoro.font(14, color: const Color(0xFFFF8A80)),
                    ),
                  ),
                for (final error in [
                  _extras.requestNoticeError,
                  _extras.replyError,
                ].nonNulls)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 4,
                    ),
                    child: Text(error, style: Zoro.font(14, color: Zoro.muted)),
                  ),
                if (empty)
                  const PhoneStatus(
                    title: 'You’re all caught up',
                    detail:
                        'Requested titles that become available and replies from support appear here.',
                    icon: Icons.notifications_none_rounded,
                  ),
                for (final n in newRequests) _request(n, unread: true),
                for (final r in newReplies)
                  _reply(r, unread: !_extras.isReplyRead(r)),
                if (history > 0) ...[
                  ListTile(
                    title: Text(
                      _showHidden
                          ? 'Hide earlier updates'
                          : 'Earlier updates ($history)',
                      style: Zoro.font(
                        15,
                        weight: FontWeight.w600,
                        color: Zoro.jade,
                      ),
                    ),
                    onTap: () => setState(() => _showHidden = !_showHidden),
                  ),
                  if (_showHidden) ...[
                    for (final n in oldRequests) _request(n, unread: false),
                    for (final r in oldReplies) _reply(r, unread: false),
                  ],
                ],
                if (_extras.hasOlderRequestNotices)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'Older request updates are in Requests.',
                      style: Zoro.font(13, color: Zoro.muted),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

Future<void> openSupport(BuildContext context) {
  final scope = PhoneScope.of(context);
  return scope.push(
    PhoneSupportScreen(
      extras: scope.extras,
      viewerName: scope.catalog.viewerName,
    ),
  );
}

/// Support report form (Apple `SupportView`): issue, optional title and
/// description, the AI processing notice and consent, then the result.
class PhoneSupportScreen extends StatefulWidget {
  const PhoneSupportScreen({
    super.key,
    required this.extras,
    required this.viewerName,
  });

  final ExtrasState extras;
  final String viewerName;

  @override
  State<PhoneSupportScreen> createState() => _PhoneSupportScreenState();
}

class _PhoneSupportScreenState extends State<PhoneSupportScreen> {
  late final _media = TextEditingController(text: widget.extras.supportMedia);
  late final _description = TextEditingController(
    text: widget.extras.supportDescription,
  );
  bool _agreed = false;

  ExtrasState get _extras => widget.extras;

  @override
  void dispose() {
    _media.dispose();
    _description.dispose();
    super.dispose();
  }

  Widget _form() {
    final valid = SupportReport(
      issueType: _extras.supportIssue,
      description: _description.text,
      affectedMedia: _media.text,
    ).isValid;
    return ListView(
      padding: const EdgeInsets.all(Phone.gutter + 4),
      children: [
        if (_extras.isPreview)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Preview only · No report will be sent',
              style: Zoro.font(13, weight: FontWeight.w600, color: Zoro.jade),
            ),
          ),
        Text('How can we help?', style: Zoro.font(26, weight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(
          'Send an issue to your server’s support agent. Replies appear under the notification bell.',
          style: Zoro.font(15, color: Zoro.muted),
        ),
        const SizedBox(height: 20),
        DropdownButtonFormField<String>(
          initialValue: _extras.supportIssue,
          decoration: const InputDecoration(labelText: 'Issue'),
          dropdownColor: Zoro.panel,
          items: [
            for (final issue in supportIssues)
              DropdownMenuItem(value: issue, child: Text(issue)),
          ],
          onChanged: (v) => _extras.editSupport(issue: v),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _media,
          maxLength: 200,
          decoration: const InputDecoration(
            labelText: 'Movie, show or channel (optional)',
          ),
          onChanged: (v) => _extras.editSupport(media: v),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _description,
          maxLength: 1500,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(labelText: 'What happened?'),
          onChanged: (v) {
            _extras.editSupport(description: v);
            setState(() {});
          },
        ),
        const SizedBox(height: 8),
        Text(
          'Sending as ${widget.viewerName}',
          style: Zoro.font(14, weight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'Your report, affected title and account context go to this server’s administrators and support service. The service may send them to its configured AI support provider and consult relevant server diagnostics. Ask your server owner about that provider before sending sensitive information. Leave out passwords and payment details.',
          style: Zoro.font(13, color: Zoro.muted).copyWith(height: 1.4),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          activeColor: Zoro.jade,
          checkColor: Zoro.background,
          value: _agreed,
          onChanged: (v) => setState(() => _agreed = v ?? false),
          title: Text(
            'I agree to share this report for server support and possible AI processing',
            style: Zoro.font(14),
          ),
        ),
        const SizedBox(height: 12),
        PillButton(
          label: 'Send report',
          primary: true,
          expand: true,
          busy: _extras.submission == SupportSubmission.sending,
          onPressed: valid && _agreed && !_extras.isPreview
              ? () => unawaited(_extras.sendSupport())
              : null,
        ),
        if (_extras.submission == SupportSubmission.rejected)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'The server didn’t accept this report. Check the details and try again.',
              style: Zoro.font(14, color: const Color(0xFFFF8A80)),
            ),
          ),
      ],
    );
  }

  Widget _result() {
    final accepted = _extras.submission == SupportSubmission.accepted;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(
          accepted ? Icons.check_circle_rounded : Icons.help_outline_rounded,
          size: 48,
          color: accepted ? Zoro.jade : Zoro.muted,
        ),
        const SizedBox(height: 12),
        Text(
          accepted ? 'Report received' : 'Delivery unconfirmed',
          style: Zoro.font(24, weight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        if (accepted && _extras.ticketId != null)
          Text('Reference: ${_extras.ticketId}', style: Zoro.font(15)),
        const SizedBox(height: 8),
        Text(
          accepted
              ? 'Your server’s support agent will review it. Watch Notifications for a reply.'
              : 'The connection ended before the server confirmed your report. Check Notifications for a reply before sending it again.',
          style: Zoro.font(15, color: Zoro.muted),
        ),
        const SizedBox(height: 20),
        PillButton(
          label: 'Start another report',
          onPressed: _extras.startAnotherReport,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: Zoro.background,
      title: Text('Support', style: Zoro.font(18, weight: FontWeight.w600)),
    ),
    body: ListenableBuilder(
      listenable: _extras,
      builder: (context, _) {
        if (!_extras.features.support && !_extras.isPreview) {
          return const PhoneStatus(
            title: 'Support unavailable',
            detail:
                'This server does not currently offer support for your account.',
          );
        }
        return switch (_extras.submission) {
          SupportSubmission.accepted ||
          SupportSubmission.uncertain => _result(),
          _ => _form(),
        };
      },
    ),
  );
}
