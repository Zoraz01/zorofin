import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/live_tv_streams.dart';
import '../../core/models.dart';
import '../../core/server_extras.dart';
import '../../extras_state.dart';
import '../theme.dart';
import 'focusable.dart';

/// Phones and tablets lay out at their real size; TVs use the 1920 canvas.
bool liveTvCompact(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 1600;

/// TV focus button, or a touch-sized pill on phones and tablets.
class _LiveButton extends StatelessWidget {
  const _LiveButton({
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool primary;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    if (!liveTvCompact(context)) {
      return ZoroButton(
        label: label,
        primary: primary,
        autofocus: autofocus,
        onPressed: onPressed,
      );
    }
    final style = FilledButton.styleFrom(
      backgroundColor: primary ? Zoro.play : Zoro.panel,
      foregroundColor: primary ? Zoro.background : Zoro.text,
      minimumSize: const Size(64, 44),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      shape: const StadiumBorder(),
      textStyle: Zoro.font(15, weight: FontWeight.w700),
      side: primary ? null : const BorderSide(color: Zoro.border),
    );
    return FilledButton(
      autofocus: autofocus,
      style: style,
      onPressed: onPressed,
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// Live TV stream use on Live TV and channel pages. With the companion's
/// liveTvStreams module it shows which channels are playing (a "Playing now"
/// strip on Live TV, one line on a channel page, with Join / Watch). Otherwise
/// it falls back to the older "Live TV channel limit" panel (Apple
/// `TVLiveTVAvailabilityNotice`). Polls while shown, never in preview.
class LiveTvNotice extends StatefulWidget {
  const LiveTvNotice({super.key, this.channelId, this.onJoin});

  final String? channelId;

  /// Plays a channel that's already on (Join / "Watch ESPN").
  final ValueChanged<MediaItem>? onJoin;

  static const refresh = Duration(seconds: 30);
  static const streamsRefresh = Duration(seconds: 15);

  @override
  State<LiveTvNotice> createState() => _LiveTvNoticeState();
}

class _LiveTvNoticeState extends State<LiveTvNotice> {
  ExtrasState? _extras;
  LiveTvAvailability? _status;
  LiveTvStreams? _streams;
  String? _policy;
  Timer? _timer;
  String _mode = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final extras = ExtrasScope.maybeOf(context);
    final features = extras?.features;
    final mode = features?.liveTvStreams == true
        ? 'streams'
        : features?.liveTVAvailability == true
        ? 'availability'
        : '';
    if (extras != _extras || mode != _mode) {
      _extras = extras;
      _mode = mode;
      _timer?.cancel();
      _timer = null;
      _status = null;
      _streams = null;
      _policy = null;
      if (mode.isNotEmpty && !extras!.isPreview) {
        unawaited(_poll());
        _timer = Timer.periodic(
          mode == 'streams'
              ? LiveTvNotice.streamsRefresh
              : LiveTvNotice.refresh,
          (_) => _poll(),
        );
      }
    }
  }

  @override
  void didUpdateWidget(LiveTvNotice old) {
    super.didUpdateWidget(old);
    if (old.channelId != widget.channelId && _timer != null) {
      _streams = null;
      unawaited(_poll());
    }
  }

  Future<void> _poll() async {
    final client = _extras?.catalog.client;
    if (client == null) return;
    if (_mode == 'streams') {
      LiveTvStreams? fresh;
      try {
        fresh = await client.liveTvStreams(channelId: widget.channelId);
      } catch (_) {}
      if (!mounted || _mode != 'streams') return;
      setState(() => _streams = fresh);
      return;
    }
    LiveTvAvailability? fresh;
    try {
      fresh = await client.liveTvAvailability(channelId: widget.channelId);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _status = fresh;
      if (fresh != null) _policy = fresh.policy;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_mode == 'streams') {
      final streams = _streams;
      if (streams == null) return const SizedBox.shrink();
      final channelId = widget.channelId;
      return channelId == null
          ? LiveTvStreamsStrip(status: streams, onJoin: widget.onJoin)
          : LiveTvStreamsLine(
              status: streams,
              channelId: channelId,
              onJoin: widget.onJoin,
            );
    }
    final policy = _policy;
    if (_extras?.features.liveTVAvailability != true || policy == null) {
      return const SizedBox.shrink();
    }
    final message =
        _status?.message ?? 'Live TV availability could not be checked.';
    final compact = liveTvCompact(context);
    return Semantics(
      container: true,
      label: 'Live TV channel limit. $policy $message',
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(compact ? 16 : 24),
        decoration: BoxDecoration(
          color: Zoro.panel,
          borderRadius: BorderRadius.circular(compact ? 14 : 16),
        ),
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    color: Zoro.text,
                    size: compact ? 20 : 24,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      'Live TV channel limit',
                      style: Zoro.font(
                        compact ? 16 : 24,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: compact ? 6 : 10),
              Text(
                policy,
                style: Zoro.font(compact ? 14 : 22, color: Zoro.muted),
              ),
              SizedBox(height: compact ? 6 : 10),
              Text(
                message,
                style: Zoro.font(compact ? 14 : 22, weight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "LIVE" capsule used on Live TV cards.
class LiveTvLiveBadge extends StatelessWidget {
  const LiveTvLiveBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final compact = liveTvCompact(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 10,
        vertical: compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: const Color(0xE605120A),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Zoro.jade.withValues(alpha: 0.55)),
      ),
      child: Text(
        'LIVE',
        style: Zoro.font(
          compact ? 11 : 15,
          weight: FontWeight.w800,
          color: Zoro.jade,
        ).copyWith(letterSpacing: 1.2),
      ),
    );
  }
}

/// Channel logo from the server, with the channel's initials if it has none.
class LiveTvChannelLogo extends StatelessWidget {
  const LiveTvChannelLogo({
    super.key,
    required this.channelId,
    required this.name,
    this.size = 80,
  });

  final String channelId;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final catalog = ExtrasScope.maybeOf(context)?.catalog;
    final client = catalog?.client;
    final initials = Center(
      child: Text(
        (name.length > 3 ? name.substring(0, 3) : name).toUpperCase(),
        style: Zoro.font(
          size * 0.24,
          weight: FontWeight.w700,
          color: Zoro.muted,
        ),
      ),
    );
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFF0D110F),
          borderRadius: BorderRadius.circular(size * 0.19),
        ),
        child: client == null
            ? initials
            : Padding(
                padding: EdgeInsets.all(size * 0.12),
                child: Image.network(
                  client.image(channelId, width: (size * 3).round()).toString(),
                  headers: catalog!.imageHeaders,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => initials,
                ),
              ),
      ),
    );
  }
}

/// One channel in use: logo, LIVE, channel, show, "2 watching · 18 min left".
class LiveTvStreamSummary extends StatelessWidget {
  const LiveTvStreamSummary({super.key, required this.stream});

  final LiveTvStream stream;

  @override
  Widget build(BuildContext context) {
    final compact = liveTvCompact(context);
    return Row(
      children: [
        LiveTvChannelLogo(
          channelId: stream.channelId,
          name: stream.channelName,
          size: compact ? 52 : 80,
        ),
        SizedBox(width: compact ? 12 : 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const LiveTvLiveBadge(),
                  SizedBox(width: compact ? 8 : 10),
                  Flexible(
                    child: Text(
                      stream.channelName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Zoro.font(
                        compact ? 17 : 26,
                        weight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              if (stream.programmeTitle != null) ...[
                SizedBox(height: compact ? 2 : 5),
                Text(
                  stream.programmeTitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Zoro.font(compact ? 14 : 21),
                ),
              ],
              SizedBox(height: compact ? 2 : 5),
              Text(
                stream.detail(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Zoro.font(compact ? 13 : 18, color: Zoro.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Playing now" on the Live TV screen: each channel using a stream, with
/// Join. Hidden when nothing is playing.
class LiveTvStreamsStrip extends StatelessWidget {
  const LiveTvStreamsStrip({super.key, required this.status, this.onJoin});

  final LiveTvStreams status;
  final ValueChanged<MediaItem>? onJoin;

  @override
  Widget build(BuildContext context) {
    final compact = liveTvCompact(context);
    final cardWidth = compact
        ? (MediaQuery.sizeOf(context).width - 56).clamp(240.0, 420.0)
        : 600.0;
    return Column(
      key: const ValueKey('live-tv-streams'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              for (final (i, stream) in status.streams.indexed) ...[
                if (i > 0) SizedBox(width: compact ? 12 : 24),
                _card(stream, cardWidth, compact),
              ],
            ],
          ),
        ),
        SizedBox(height: compact ? 4 : 10),
        Text(
          status.summary,
          style: Zoro.font(compact ? 13 : 19, color: Zoro.muted),
        ),
      ],
    );
  }

  Widget _card(LiveTvStream stream, double width, bool compact) {
    final join = onJoin;
    return Container(
      width: width,
      padding: EdgeInsets.all(compact ? 14 : 20),
      decoration: BoxDecoration(
        color: Zoro.panel,
        borderRadius: BorderRadius.circular(compact ? 12 : 14),
        border: Border.all(
          color: stream.yours ? Zoro.jade.withValues(alpha: 0.45) : Zoro.border,
        ),
      ),
      child: Row(
        children: [
          Expanded(child: LiveTvStreamSummary(stream: stream)),
          if (join != null) ...[
            SizedBox(width: compact ? 10 : 16),
            Semantics(
              label: stream.yours
                  ? 'You are watching ${stream.channelName}'
                  : 'Join ${stream.channelName}',
              excludeSemantics: true,
              child: _LiveButton(
                label: stream.yours ? 'Watching' : 'Join',
                primary: !stream.yours,
                onPressed: () => join(stream.channel),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One line under a channel's Play button: who's on this channel, or which
/// channel is using the last stream (with "Watch ESPN").
class LiveTvStreamsLine extends StatelessWidget {
  const LiveTvStreamsLine({
    super.key,
    required this.status,
    required this.channelId,
    this.onJoin,
  });

  final LiveTvStreams status;
  final String channelId;
  final ValueChanged<MediaItem>? onJoin;

  @override
  Widget build(BuildContext context) {
    final line = status.channelLine(channelId);
    if (line == null) return const SizedBox.shrink();
    final playing = status.streamFor(channelId) != null;
    final join = status.blocked(channelId)?.join;
    final color = playing ? Zoro.jade : const Color(0xFFE0B44A);
    final onJoin = this.onJoin;
    final compact = liveTvCompact(context);
    return Wrap(
      key: const ValueKey('live-tv-stream-line'),
      spacing: compact ? 12 : 16,
      runSpacing: compact ? 8 : 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 17,
              height: 17,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
            const SizedBox(width: 12),
            Flexible(child: Text(line, style: Zoro.font(compact ? 15 : 22))),
          ],
        ),
        if (join != null && onJoin != null)
          _LiveButton(
            label: 'Watch ${join.channelName}',
            onPressed: () => onJoin(join.channel),
          ),
      ],
    );
  }
}

/// The "Live TV is in use" alert shown when a different channel must wait.
/// Returns the channel to watch instead when the viewer picks "Watch ESPN".
Future<MediaItem?> showLiveTvConflict(
  BuildContext context,
  LiveTvConflict conflict,
) {
  final stream = conflict is LiveTvStreamsConflict
      ? conflict.blocked.join
      : null;
  final join = conflict.join;
  final compact = liveTvCompact(context);
  final width = compact
      ? (MediaQuery.sizeOf(context).width - 32).clamp(260.0, 440.0)
      : 720.0;
  return showDialog<MediaItem>(
    context: context,
    useRootNavigator: true,
    barrierColor: const Color(0xCC000000),
    builder: (context) => Center(
      child: Container(
        width: width,
        padding: EdgeInsets.all(compact ? 22 : 36),
        decoration: BoxDecoration(
          color: Zoro.panel,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Zoro.border),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                conflict.title,
                style: Zoro.font(compact ? 20 : 32, weight: FontWeight.w700),
              ),
              SizedBox(height: compact ? 14 : 20),
              if (stream != null) ...[
                Container(
                  padding: EdgeInsets.all(compact ? 12 : 18),
                  decoration: BoxDecoration(
                    color: const Color(0x0AFFFFFF),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Zoro.border),
                  ),
                  child: LiveTvStreamSummary(stream: stream),
                ),
                SizedBox(height: compact ? 14 : 20),
              ],
              if (conflict is LiveTvStreamsConflict) ...[
                Text(
                  conflict.blocked.text,
                  style: Zoro.font(compact ? 15 : 22),
                ),
                SizedBox(height: compact ? 8 : 12),
                Text(
                  conflict.blocked.hint,
                  style: Zoro.font(compact ? 15 : 22, color: Zoro.muted),
                ),
              ] else
                Text(
                  conflict.message,
                  style: Zoro.font(compact ? 15 : 22, color: Zoro.muted),
                ),
              SizedBox(height: compact ? 20 : 28),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: compact ? 10 : 16,
                runSpacing: 10,
                children: [
                  if (join != null) ...[
                    _LiveButton(
                      label: 'Not now',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    _LiveButton(
                      label: 'Watch ${join.name}',
                      primary: true,
                      autofocus: true,
                      onPressed: () => Navigator.of(context).pop(join),
                    ),
                  ] else
                    _LiveButton(
                      label: 'OK',
                      autofocus: true,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
