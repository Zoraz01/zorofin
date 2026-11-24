import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../widgets/focusable.dart';

enum PlayerPhase { preparing, playing, paused, buffering, ended, failed }

enum PlayerPanel { episodes, channels, quality, tracks, information }

/// `1:02:03` or `4:05`, as the Apple player's `PlayerTimeline.timeLabel`.
String timeLabel(Duration d) {
  final total = d.isNegative ? 0 : d.inSeconds;
  final h = total ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// The Apple TV custom player chrome (`CustomPlayerControls`): close, title
/// and episodes along the top, centered skip / play / skip transport, and
/// the timeline with quality, audio & subtitles and info along the bottom.
class PlayerControls extends StatelessWidget {
  const PlayerControls({
    super.key,
    required this.title,
    required this.subtitle,
    required this.phase,
    required this.position,
    required this.duration,
    required this.playFocus,
    required this.onClose,
    required this.onTogglePlay,
    required this.onSkip,
    required this.onPanel,
    required this.onScrubStart,
    required this.onScrubMove,
    required this.onScrubCommit,
    required this.onScrubCancel,
    required this.onInteract,
    this.scrubPosition,
    this.skipBack = 10,
    this.skipForward = 30,
    this.canSeek = true,
    this.hasEpisodes = false,
    this.hasTracks = false,
    this.isLive = false,
    this.behindLive,
    this.onGoLive,
  });

  final String title;
  final String subtitle;
  final PlayerPhase phase;
  final Duration position;
  final Duration? duration;
  final Duration? scrubPosition;
  final int skipBack;
  final int skipForward;
  final bool canSeek;
  final bool hasEpisodes;
  final bool hasTracks;
  final bool isLive;

  /// How far a time-shifted broadcast is behind live; null at the live edge
  /// or when the stream has no rewind window.
  final Duration? behindLive;

  /// Shown on Live TV when paused or behind live.
  final VoidCallback? onGoLive;
  final FocusNode playFocus;
  final VoidCallback onClose;
  final VoidCallback onTogglePlay;
  final ValueChanged<int> onSkip;
  final ValueChanged<PlayerPanel> onPanel;
  final VoidCallback onScrubStart;
  final ValueChanged<Duration> onScrubMove;
  final VoidCallback onScrubCommit;
  final VoidCallback onScrubCancel;

  /// Any focus change or press keeps the controls on screen.
  final VoidCallback onInteract;

  bool get _playing =>
      phase == PlayerPhase.playing || phase == PlayerPhase.buffering;
  bool get _ready =>
      phase != PlayerPhase.preparing && phase != PlayerPhase.failed;
  Duration get _shown => scrubPosition ?? position;

  @override
  Widget build(BuildContext context) {
    final seekable = canSeek && _ready && phase != PlayerPhase.ended;
    return Stack(
      fit: StackFit.expand,
      children: [
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.3, 0.55, 1],
                colors: [
                  Color(0xB8000000),
                  Colors.transparent,
                  Colors.transparent,
                  Color(0xE0000000),
                ],
              ),
            ),
          ),
        ),
        Center(
          child: FocusTraversalGroup(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isLive)
                  PlayerIconButton(
                    icon: _skipIcon(skipBack, forward: false),
                    label: 'Back $skipBack seconds',
                    size: 30,
                    enabled: seekable,
                    onFocus: onInteract,
                    onPressed: () => onSkip(-skipBack),
                  ),
                const SizedBox(width: 36),
                PlayerIconButton(
                  icon: phase == PlayerPhase.ended
                      ? Icons.replay_rounded
                      : (_playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded),
                  label: phase == PlayerPhase.ended
                      ? (isLive ? 'Reconnect' : 'Watch again')
                      : (_playing ? 'Pause' : 'Play'),
                  size: 38,
                  emphasis: true,
                  enabled: _ready,
                  focusNode: playFocus,
                  onFocus: onInteract,
                  onPressed: onTogglePlay,
                ),
                const SizedBox(width: 36),
                if (!isLive)
                  PlayerIconButton(
                    icon: _skipIcon(skipForward, forward: true),
                    label: 'Forward $skipForward seconds',
                    size: 30,
                    enabled: seekable,
                    onFocus: onInteract,
                    onPressed: () => onSkip(skipForward),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
          child: Column(
            children: [
              FocusTraversalGroup(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PlayerIconButton(
                      icon: Icons.chevron_left_rounded,
                      label: 'Close player',
                      size: 28,
                      onFocus: onInteract,
                      onPressed: onClose,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Zoro.font(
                                28,
                                weight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                            if (subtitle.isNotEmpty) ...[
                              const SizedBox(height: 5),
                              Text(
                                subtitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Zoro.font(
                                  20,
                                  color: const Color(0xBFFFFFFF),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (isLive)
                      PlayerIconButton(
                        icon: Icons.list_alt_rounded,
                        label: 'Channels',
                        enabled: phase != PlayerPhase.preparing,
                        onFocus: onInteract,
                        onPressed: () => onPanel(PlayerPanel.channels),
                      )
                    else if (hasEpisodes)
                      PlayerIconButton(
                        icon: Icons.video_library_outlined,
                        label: 'Seasons and episodes',
                        onFocus: onInteract,
                        onPressed: () => onPanel(PlayerPanel.episodes),
                      ),
                  ],
                ),
              ),
              const Spacer(),
              if (phase == PlayerPhase.preparing ||
                  phase == PlayerPhase.buffering)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        phase == PlayerPhase.preparing
                            ? (isLive
                                  ? 'Connecting to channel…'
                                  : 'Preparing video…')
                            : 'Buffering…',
                        style: Zoro.font(20, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              FocusTraversalGroup(
                child: Row(
                  children: [
                    if (isLive) ...[
                      const Icon(Icons.circle, size: 12, color: Zoro.jade),
                      const SizedBox(width: 8),
                      Text(
                        phase == PlayerPhase.paused
                            ? 'Paused'
                            : behindLive == null
                            ? 'Live'
                            : 'Live TV',
                        style: Zoro.font(18, color: Zoro.jade),
                      ),
                      if (behindLive != null) ...[
                        const SizedBox(width: 12),
                        Text(
                          '${timeLabel(behindLive!)} behind',
                          style: _timeStyle,
                        ),
                      ],
                      if (onGoLive != null) ...[
                        const SizedBox(width: 16),
                        PlayerIconButton(
                          icon: Icons.skip_next_rounded,
                          label: 'Go live',
                          enabled: _ready && phase != PlayerPhase.ended,
                          onFocus: onInteract,
                          onPressed: onGoLive!,
                        ),
                      ],
                      const SizedBox(width: 16),
                      Expanded(
                        child: canSeek
                            ? TimelineBar(
                                position: _shown,
                                duration: duration,
                                active: scrubPosition != null,
                                enabled: seekable,
                                onFocus: onInteract,
                                onBegin: onScrubStart,
                                onMove: onScrubMove,
                                onCommit: onScrubCommit,
                                onCancel: onScrubCancel,
                              )
                            : const SizedBox(),
                      ),
                    ] else ...[
                      Text(timeLabel(_shown), style: _timeStyle),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TimelineBar(
                          position: _shown,
                          duration: duration,
                          active: scrubPosition != null,
                          enabled: seekable,
                          onFocus: onInteract,
                          onBegin: onScrubStart,
                          onMove: onScrubMove,
                          onCommit: onScrubCommit,
                          onCancel: onScrubCancel,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Text(
                        duration == null
                            ? '--:--'
                            : '−${timeLabel(duration! - _shown)}',
                        style: _timeStyle,
                      ),
                    ],
                    const SizedBox(width: 32),
                    PlayerIconButton(
                      icon: Icons.tune_rounded,
                      label: 'Quality',
                      enabled: phase != PlayerPhase.preparing,
                      onFocus: onInteract,
                      onPressed: () => onPanel(PlayerPanel.quality),
                    ),
                    const SizedBox(width: 24),
                    PlayerIconButton(
                      icon: Icons.closed_caption_outlined,
                      label: 'Subtitles and audio',
                      enabled: hasTracks && phase != PlayerPhase.preparing,
                      onFocus: onInteract,
                      onPressed: () => onPanel(PlayerPanel.tracks),
                    ),
                    const SizedBox(width: 24),
                    PlayerIconButton(
                      icon: Icons.info_outline_rounded,
                      label: 'Playback info',
                      onFocus: onInteract,
                      onPressed: () => onPanel(PlayerPanel.information),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static IconData _skipIcon(int seconds, {required bool forward}) =>
      switch ((seconds, forward)) {
        (5, false) => Icons.replay_5_rounded,
        (10, false) => Icons.replay_10_rounded,
        (30, false) => Icons.replay_30_rounded,
        (5, true) => Icons.forward_5_rounded,
        (10, true) => Icons.forward_10_rounded,
        (30, true) => Icons.forward_30_rounded,
        (_, false) => Icons.fast_rewind_rounded,
        (_, true) => Icons.fast_forward_rounded,
      };

  static final _timeStyle = Zoro.font(
    18,
    color: const Color(0xD9FFFFFF),
  ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}

/// Icon control in the Apple `CinematicButtonStyle`: no chrome until focused,
/// then a translucent white fill and a white outline. The emphasized Play
/// button sits in a dark circle.
class PlayerIconButton extends StatelessWidget {
  const PlayerIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.size = 22,
    this.emphasis = false,
    this.enabled = true,
    this.focusNode,
    this.onFocus,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final double size;
  final bool emphasis;
  final bool enabled;
  final FocusNode? focusNode;
  final VoidCallback? onFocus;

  @override
  Widget build(BuildContext context) {
    final extent = emphasis ? 84.0 : 64.0;
    final radius = BorderRadius.circular(emphasis ? 42 : 10);
    final circle = size >= 30 && !emphasis;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Focusable(
        focusNode: focusNode,
        semanticLabel: label,
        onFocus: onFocus,
        onPressed: enabled ? onPressed : () {},
        builder: (context, focused) => AnimatedContainer(
          duration: Zoro.focusDuration,
          width: extent,
          height: extent,
          decoration: BoxDecoration(
            borderRadius: circle ? BorderRadius.circular(extent / 2) : radius,
            color: focused
                ? const Color(0x33FFFFFF)
                : (emphasis || circle
                      ? const Color(0x73000000)
                      : Colors.transparent),
            border: Border.all(
              color: focused ? Colors.white : Colors.transparent,
              width: 2,
            ),
          ),
          child: Icon(icon, size: size, color: Colors.white),
        ),
      ),
    );
  }
}

/// Playback position (Apple `CustomTimelineBar`). On a remote, OK enters
/// seek mode and pauses; Left and Right move 10 seconds; OK seeks; leaving
/// the bar or Back cancels. Outside seek mode, arrows move focus as usual.
class TimelineBar extends StatefulWidget {
  const TimelineBar({
    super.key,
    required this.position,
    required this.duration,
    required this.active,
    required this.onBegin,
    required this.onMove,
    required this.onCommit,
    required this.onCancel,
    this.enabled = true,
    this.onFocus,
    this.focusNode,
  });

  final FocusNode? focusNode;
  final Duration position;
  final Duration? duration;
  final bool active;
  final bool enabled;
  final VoidCallback onBegin;
  final ValueChanged<Duration> onMove;
  final VoidCallback onCommit;
  final VoidCallback onCancel;
  final VoidCallback? onFocus;

  @override
  State<TimelineBar> createState() => _TimelineBarState();
}

class _TimelineBarState extends State<TimelineBar> {
  static const _step = Duration(seconds: 10);
  bool _focused = false;

  double get _fraction {
    final total = widget.duration?.inMilliseconds ?? 0;
    if (total <= 0) return 0;
    return (widget.position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!widget.enabled || event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (selectKeys.keys.any((a) => a is SingleActivator && a.trigger == key)) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      widget.active ? widget.onCommit() : widget.onBegin();
      return KeyEventResult.handled;
    }
    if (widget.active &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      final total = widget.duration;
      var target =
          widget.position +
          (key == LogicalKeyboardKey.arrowLeft ? -_step : _step);
      if (target.isNegative) target = Duration.zero;
      if (total != null && target > total) target = total;
      widget.onMove(target);
      return KeyEventResult.handled;
    }
    // Up and Down leave the bar; seek mode cancels on focus loss.
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final big = widget.active || _focused;
    return Semantics(
      slider: true,
      label: 'Playback position',
      value: timeLabel(widget.position),
      child: Focus(
        focusNode: widget.focusNode,
        onKeyEvent: _key,
        onFocusChange: (value) {
          setState(() => _focused = value);
          if (value) widget.onFocus?.call();
          if (!value && widget.active) widget.onCancel();
        },
        child: SizedBox(
          height: 48,
          child: LayoutBuilder(
            builder: (context, size) {
              final width = size.maxWidth;
              final knob = big ? 16.0 : 10.0;
              return Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: big ? 5 : 3,
                    decoration: BoxDecoration(
                      color: const Color(0x40FFFFFF),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  Container(
                    width: width * _fraction,
                    height: big ? 5 : 3,
                    decoration: BoxDecoration(
                      color: Zoro.jade,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  Positioned(
                    left: (width * _fraction - knob / 2).clamp(0, width - knob),
                    child: Container(
                      width: knob,
                      height: knob,
                      decoration: BoxDecoration(
                        color: Zoro.jade,
                        shape: BoxShape.circle,
                        border: _focused && !widget.active
                            ? Border.all(color: Colors.white, width: 2)
                            : null,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
