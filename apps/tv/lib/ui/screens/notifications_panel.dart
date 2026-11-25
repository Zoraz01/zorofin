import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/requests.dart';
import '../../core/server_extras.dart';
import '../../extras_state.dart';
import '../theme.dart';
import '../widgets/focusable.dart';

/// The bell's inbox (Apple `NotificationInboxView`): ready requests and
/// support replies. Items seen in this presentation stay in place, then move
/// to Hidden the next time it opens.
class NotificationInbox extends StatefulWidget {
  const NotificationInbox({
    super.key,
    required this.extras,
    required this.onClose,
    required this.onOpen,
  });

  final ExtrasState extras;
  final VoidCallback onClose;
  final ValueChanged<MediaItem> onOpen;

  @override
  State<NotificationInbox> createState() => _NotificationInboxState();
}

class _NotificationInboxState extends State<NotificationInbox> {
  final _sessionRequestIds = <int>{};
  final _sessionReplyKeys = <String>{};
  bool _showHidden = false;
  int? _openingId;
  String? _openError;

  ExtrasState get _extras => widget.extras;

  @override
  void initState() {
    super.initState();
    // After this frame: a refresh notifies listeners, which can't happen while
    // the inbox itself is still being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_extras.refreshNotifications());
    });
  }

  List<RequestAvailabilityNotice> get _newRequests => _extras.requestNotices
      .where(
        (n) =>
            !_extras.isRequestRead(n.id) || _sessionRequestIds.contains(n.id),
      )
      .toList();

  List<RequestAvailabilityNotice> get _oldRequests => _extras.requestNotices
      .where(
        (n) =>
            _extras.isRequestRead(n.id) && !_sessionRequestIds.contains(n.id),
      )
      .toList();

  List<SupportReply> get _newReplies => _extras.replies
      .where(
        (r) =>
            !_extras.isReplyRead(r) ||
            _sessionReplyKeys.contains(r.notificationKey),
      )
      .toList();

  List<SupportReply> get _oldReplies => _extras.readReplies
      .where((r) => !_sessionReplyKeys.contains(r.notificationKey))
      .toList();

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
    });
    try {
      final item = await client.requestNotificationItem(notice);
      await _extras.markRequestRead(notice);
      if (mounted) widget.onOpen(item);
    } catch (_) {
      if (mounted) {
        setState(
          () => _openError =
              'This title couldn\'t be opened. Check its availability in Requests.',
        );
      }
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _extras,
      builder: (context, _) {
        final newRequests = _newRequests;
        final newReplies = _newReplies;
        final oldRequests = _oldRequests;
        final oldReplies = _oldReplies;
        final history = oldRequests.length + oldReplies.length;
        return Material(
          color: Zoro.panel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Notifications',
                        style: Zoro.font(28, weight: FontWeight.w700),
                      ),
                    ),
                    Focusable(
                      autofocus: true,
                      semanticLabel: 'Close notifications',
                      onPressed: widget.onClose,
                      builder: (context, focused) => AnimatedContainer(
                        duration: Zoro.focusDuration,
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: focused
                              ? Zoro.text
                              : Zoro.text.withValues(alpha: 0.06),
                        ),
                        child: Icon(
                          Icons.close_rounded,
                          size: 24,
                          color: focused ? Zoro.background : Zoro.text,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Zoro.border),
              Expanded(
                child: _ViewportMarker(
                  child: ListView(
                    padding: const EdgeInsets.all(18),
                    children: [
                      if (_openError != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            _openError!,
                            style: Zoro.font(20, color: Zoro.muted),
                          ),
                        ),
                      if (_extras.replyError != null ||
                          _extras.requestNoticeError != null)
                        _Row(
                          label: 'Couldn\'t refresh, retry',
                          onPressed: _extras.loadingNotifications
                              ? () {}
                              : () => _extras.refreshNotifications(force: true),
                          child: Row(
                            children: [
                              const Icon(Icons.refresh_rounded, size: 22),
                              const SizedBox(width: 10),
                              Text(
                                'Couldn\'t refresh · Retry',
                                style: Zoro.font(20),
                              ),
                            ],
                          ),
                        ),
                      if (newRequests.isEmpty && newReplies.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 20,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'You\'re all caught up',
                                style: Zoro.font(23, weight: FontWeight.w600),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'New updates will appear here.',
                                style: Zoro.font(19, color: Zoro.muted),
                              ),
                            ],
                          ),
                        ),
                      for (final notice in newRequests)
                        SeenAfterDwell(
                          key: ValueKey('request-${notice.id}'),
                          onSeen: () {
                            _sessionRequestIds.add(notice.id);
                            return _extras.markRequestRead(notice);
                          },
                          child: _requestRow(notice),
                        ),
                      for (final reply in newReplies)
                        SeenAfterDwell(
                          key: ValueKey('reply-${reply.notificationKey}'),
                          onSeen: () {
                            _sessionReplyKeys.add(reply.notificationKey);
                            return _extras.markReplyRead(reply);
                          },
                          child: _replyRow(reply),
                        ),
                      if (history > 0) ...[
                        _Row(
                          label:
                              'Hidden ($history), ${_showHidden ? 'expanded' : 'collapsed'}',
                          onPressed: () =>
                              setState(() => _showHidden = !_showHidden),
                          plain: true,
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Hidden ($history)',
                                  style: Zoro.font(
                                    21,
                                    weight: FontWeight.w600,
                                    color: Zoro.muted,
                                  ),
                                ),
                              ),
                              Icon(
                                _showHidden
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.keyboard_arrow_down_rounded,
                                color: Zoro.muted,
                              ),
                            ],
                          ),
                        ),
                        if (_showHidden) ...[
                          for (final n in oldRequests) _requestRow(n),
                          for (final r in oldReplies) _replyRow(r),
                          if (_extras.hasOlderRequestNotices)
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                'More requests are in Requests → Activity.',
                                style: Zoro.font(18, color: Zoro.muted),
                              ),
                            ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _replyRow(SupportReply reply) => _ReplyRow(
    key: ValueKey('reply-row-${reply.notificationKey}'),
    reply: reply,
    onSeen: () {
      if (!_extras.isReplyRead(reply)) {
        _sessionReplyKeys.add(reply.notificationKey);
      }
      return _extras.markReplyRead(reply);
    },
  );

  Widget _requestRow(RequestAvailabilityNotice notice) {
    final status = _openingId == notice.id
        ? 'Opening…'
        : notice.is4K
        ? 'Ready to watch · 4K'
        : 'Ready to watch';
    final poster = RequestArtwork.absolute(notice.posterUrl);
    return _Row(
      label:
          '${notice.title}, ${notice.is4K ? '4K ' : ''}ready to watch. Open title',
      onPressed: () => _openRequest(notice),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: 54,
              height: 81,
              color: Zoro.background,
              child: poster == null
                  ? const Icon(Icons.movie_rounded, color: Zoro.muted)
                  : Image.network(
                      poster.toString(),
                      fit: BoxFit.cover,
                      excludeFromSemantics: true,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.movie_rounded, color: Zoro.muted),
                    ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notice.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Zoro.font(22, weight: FontWeight.w600),
                ),
                const SizedBox(height: 5),
                Text(status, style: Zoro.font(18, color: Zoro.jade)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: Zoro.muted),
        ],
      ),
    );
  }
}

class _ReplyRow extends StatefulWidget {
  const _ReplyRow({super.key, required this.reply, required this.onSeen});

  final SupportReply reply;
  final Future<void> Function() onSeen;

  @override
  State<_ReplyRow> createState() => _ReplyRowState();
}

class _ReplyRowState extends State<_ReplyRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final reply = widget.reply;
    final media = reply.affectedMedia;
    return _Row(
      label:
          '${reply.sourceLabel}, ${media?.isNotEmpty == true ? media : reply.issueType}. ${reply.message}',
      onPressed: () {
        setState(() => _expanded = !_expanded);
        unawaited(widget.onSeen());
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                reply.isAnnouncement
                    ? Icons.campaign_rounded
                    : Icons.support_agent_rounded,
                size: 22,
                color: Zoro.jade,
              ),
              const SizedBox(width: 8),
              Text(reply.sourceLabel, style: Zoro.font(20, color: Zoro.jade)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            media?.isNotEmpty == true ? media! : reply.issueType,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Zoro.font(20, weight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            reply.message,
            maxLines: _expanded ? null : 3,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: Zoro.font(20, color: Zoro.muted),
          ),
          if (_expanded && !reply.isAnnouncement) ...[
            const SizedBox(height: 6),
            Text(
              'Reference: ${reply.id}',
              style: Zoro.font(20, color: Zoro.muted),
            ),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.onPressed,
    required this.child,
    this.plain = false,
  });

  final String label;
  final VoidCallback onPressed;
  final Widget child;
  final bool plain;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Focusable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, focused) => AnimatedContainer(
        duration: Zoro.focusDuration,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: plain && !focused
              ? Colors.transparent
              : Zoro.background.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: focused ? Zoro.jade : Colors.transparent,
            width: 3,
          ),
        ),
        child: child,
      ),
    ),
  );
}

/// Marks the inbox viewport so rows can measure how much of them is shown.
class _ViewportMarker extends InheritedWidget {
  const _ViewportMarker({required super.child});

  @override
  bool updateShouldNotify(_ViewportMarker oldWidget) => false;
}

/// Laying out a row is not evidence it was seen: it must stay at least 60%
/// inside the inbox viewport for 900 ms (Apple `NotificationSeenModifier`).
class SeenAfterDwell extends StatefulWidget {
  const SeenAfterDwell({super.key, required this.onSeen, required this.child});

  final Future<void> Function() onSeen;
  final Widget child;

  static const dwell = Duration(milliseconds: 900);
  static const poll = Duration(milliseconds: 150);

  @override
  State<SeenAfterDwell> createState() => _SeenAfterDwellState();
}

class _SeenAfterDwellState extends State<SeenAfterDwell> {
  Timer? _timer;
  Duration _visibleFor = Duration.zero;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(SeenAfterDwell.poll, (_) => _check());
  }

  void _check() {
    if (!mounted || _done) return;
    if (_visibleFraction() >= 0.6) {
      _visibleFor += SeenAfterDwell.poll;
      if (_visibleFor >= SeenAfterDwell.dwell) {
        _done = true;
        _timer?.cancel();
        unawaited(widget.onSeen());
      }
    } else {
      _visibleFor = Duration.zero;
    }
  }

  double _visibleFraction() {
    final box = context.findRenderObject() as RenderBox?;
    final marker = context
        .getElementForInheritedWidgetOfExactType<_ViewportMarker>();
    final viewport = marker?.findRenderObject() as RenderBox?;
    if (box == null || viewport == null || !box.attached || !box.hasSize) {
      return 0;
    }
    final rowTop = box.localToGlobal(Offset.zero).dy;
    final rowBottom = box.localToGlobal(Offset(0, box.size.height)).dy;
    final top = viewport.localToGlobal(Offset.zero).dy;
    final bottom = viewport.localToGlobal(Offset(0, viewport.size.height)).dy;
    final shown = (rowBottom.clamp(top, bottom) - rowTop.clamp(top, bottom));
    final height = rowBottom - rowTop;
    return height <= 0 ? 0 : shown / height;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
