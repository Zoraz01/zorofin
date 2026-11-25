import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/playback.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import '../widgets/tv_text_field.dart';
import 'player_extras_ui.dart';

/// Compact options card over the playing video (Apple tvOS
/// `PlayerOptionsSurface`): a small rounded panel in the bottom-right corner,
/// above the transport bar, with a title and current-choice focus, and content that sizes to fit and scrolls past the maximum height.
/// [wide] suits channel lists; [fullWidth] suits the episode browser.
class PlayerOptionsSurface extends StatefulWidget {
  const PlayerOptionsSurface({
    super.key,
    required this.title,
    required this.onClose,
    required this.child,
    this.footer,
    this.wide = false,
    this.fullWidth = false,
    this.focusClose = false,
    this.liveSchedule = false,
  });

  final String title;
  final VoidCallback onClose;
  final Widget child;
  final Widget? footer;
  final bool wide;
  final bool fullWidth;
  final bool focusClose;
  final bool liveSchedule;

  /// Space kept clear under the card for the transport bar and option
  /// buttons, on the 1080p design canvas.
  static const controlsClearance = 140.0;

  @override
  State<PlayerOptionsSurface> createState() => _PlayerOptionsSurfaceState();
}

class _PlayerOptionsSurfaceState extends State<PlayerOptionsSurface> {
  final _close = FocusNode(debugLabel: 'player-options-close');

  @override
  void dispose() {
    _close.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      autofocus: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const bottom = PlayerOptionsSurface.controlsClearance;
          final available = constraints.maxWidth - 96;
          final width = widget.fullWidth
              ? available
              : (widget.liveSchedule
                        ? 680.0
                        : widget.wide
                        ? 1180.0
                        : 560.0)
                    .clamp(0.0, available);
          final height =
              (widget.fullWidth
                      ? 460.0
                      : (widget.liveSchedule
                            ? constraints.maxHeight - bottom - 48
                            : widget.wide
                            ? 560.0
                            : 600.0))
                  .clamp(
                    180.0,
                    (constraints.maxHeight - bottom - 48).clamp(
                      180.0,
                      double.infinity,
                    ),
                  );
          const radius = BorderRadius.all(Radius.circular(26));
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onClose,
                  child: const ColoredBox(color: Color(0x1F000000)),
                ),
              ),
              Positioned(
                right: widget.fullWidth ? 48 : 64,
                bottom: bottom,
                width: width,
                child: Container(
                  constraints: BoxConstraints(maxHeight: height),
                  decoration: BoxDecoration(
                    color: const Color(0xF0222925),
                    borderRadius: radius,
                    border: Border.all(color: const Color(0x29FFFFFF)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x59000000),
                        blurRadius: 48,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: radius,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                          child: FocusTraversalGroup(
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Zoro.font(
                                      26,
                                      weight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Focusable(
                                  focusNode: _close,
                                  autofocus: widget.focusClose,
                                  semanticLabel: 'Return to playback',
                                  onPressed: widget.onClose,
                                  builder: (context, focused) =>
                                      AnimatedContainer(
                                        duration: Zoro.focusDuration,
                                        width: 52,
                                        height: 52,
                                        decoration: BoxDecoration(
                                          color: focused
                                              ? Zoro.text
                                              : Colors.transparent,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Icon(
                                          Icons.close_rounded,
                                          size: 24,
                                          color: focused
                                              ? Zoro.background
                                              : Zoro.text,
                                        ),
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const Divider(
                          height: 1,
                          thickness: 1,
                          color: Color(0x1FFFFFFF),
                        ),
                        Flexible(
                          child: FocusTraversalGroup(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [widget.child, ?widget.footer],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Selectable row with a jade check (Apple `PlayerOptionRow`).
class PlayerOptionRow extends StatelessWidget {
  const PlayerOptionRow({
    super.key,
    required this.title,
    required this.selected,
    required this.onPressed,
    this.detail,
  });

  final String title;
  final String? detail;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      autofocus: selected,
      onPressed: onPressed,
      semanticLabel: '$title${selected ? ', selected' : ''}',
      builder: (context, focused) {
        final fg = focused
            ? Zoro.background
            : (selected ? Zoro.text : Zoro.muted);
        return AnimatedContainer(
          duration: Zoro.focusDuration,
          constraints: const BoxConstraints(minHeight: 60),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: focused ? Zoro.text : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: selected
                    ? Icon(
                        Icons.check_rounded,
                        color: focused ? Zoro.background : Zoro.jade,
                      )
                    : null,
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: Zoro.font(
                        24,
                        weight: selected ? FontWeight.w600 : FontWeight.w400,
                        color: fg,
                      ),
                    ),
                    if (detail != null && detail!.isNotEmpty && detail != title)
                      Text(
                        detail!,
                        style: Zoro.font(
                          18,
                          color: focused ? Zoro.background : Zoro.muted,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Note shown while a quality or track change waits for the viewer to return.
class PendingChangeNote extends StatelessWidget {
  const PendingChangeNote({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Text(
      'Changes apply when you return to playback.',
      style: Zoro.font(19, color: Zoro.jade),
    ),
  );
}

class QualityChoices extends StatelessWidget {
  const QualityChoices({
    super.key,
    required this.selected,
    required this.onSelect,
    this.isLive = false,
    this.automatic = false,
    this.ceiling = 40000000,
    this.onAuto,
  });

  final int selected;
  final ValueChanged<int> onSelect;
  final bool isLive;
  final bool automatic;
  final int ceiling;
  final VoidCallback? onAuto;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isLive ? 'Changes restart at live.' : 'Maximum streaming bitrate',
          style: Zoro.font(21, color: Zoro.muted),
        ),
        const SizedBox(height: 20),
        FocusTraversalGroup(
          child: Column(
            children: [
              if (onAuto != null)
                PlayerOptionRow(
                  title: 'Auto · up to ${ceiling ~/ 1000000} Mbps',
                  selected: automatic,
                  onPressed: onAuto!,
                ),
              for (final mbps in const [120, 80, 60, 40, 20, 12, 8, 4, 2])
                PlayerOptionRow(
                  title: '$mbps Mbps',
                  selected: !automatic && selected == mbps * 1000000,
                  onPressed: () => onSelect(mbps * 1000000),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Audio and subtitle choices (Apple tvOS `audioChoices` / `subtitleChoices`
/// behind an Audio | Subtitles segmented picker).
class TrackChoices extends StatefulWidget {
  const TrackChoices({
    super.key,
    required this.streams,
    required this.options,
    required this.onAudio,
    required this.onSubtitles,
    this.isLive = false,
    this.subtitleOffset = Duration.zero,
    this.onSubtitleOffset,
    this.audioOffset = Duration.zero,
    this.onAudioOffset,
  });

  /// Timing controls; null where this player can't shift that track.
  final Duration subtitleOffset;
  final ValueChanged<Duration>? onSubtitleOffset;
  final Duration audioOffset;
  final ValueChanged<Duration>? onAudioOffset;
  final List<MediaStream> streams;
  final PlaybackOptions options;
  final ValueChanged<int?> onAudio;
  final ValueChanged<int> onSubtitles;
  final bool isLive;

  static String language(MediaStream stream) {
    final code = stream.language;
    final name = code == null ? null : _languages[code.toLowerCase()];
    return name ??
        stream.displayTitle ??
        code?.toUpperCase() ??
        'Track ${stream.index}';
  }

  /// Extra detail only when two tracks share a language, so commentary or
  /// codec variants can be told apart.
  static String? detail(MediaStream stream, List<MediaStream> among) {
    if (among.where((s) => language(s) == language(stream)).length < 2) {
      return null;
    }
    return stream.displayTitle ??
        [
          stream.codec?.toUpperCase(),
          if (stream.channels != null) '${stream.channels} channels',
        ].nonNulls.join(' · ');
  }

  static const _languages = {
    'eng': 'English',
    'en': 'English',
    'spa': 'Spanish',
    'es': 'Spanish',
    'fre': 'French',
    'fra': 'French',
    'fr': 'French',
    'ger': 'German',
    'deu': 'German',
    'de': 'German',
    'ita': 'Italian',
    'it': 'Italian',
    'jpn': 'Japanese',
    'ja': 'Japanese',
    'kor': 'Korean',
    'ko': 'Korean',
    'chi': 'Chinese',
    'zho': 'Chinese',
    'zh': 'Chinese',
    'por': 'Portuguese',
    'pt': 'Portuguese',
    'rus': 'Russian',
    'ru': 'Russian',
    'hin': 'Hindi',
    'hi': 'Hindi',
    'urd': 'Urdu',
    'ur': 'Urdu',
    'ara': 'Arabic',
    'ar': 'Arabic',
    'dut': 'Dutch',
    'nld': 'Dutch',
    'nl': 'Dutch',
    'swe': 'Swedish',
    'sv': 'Swedish',
    'pol': 'Polish',
    'pl': 'Polish',
    'tur': 'Turkish',
    'tr': 'Turkish',
  };

  @override
  State<TrackChoices> createState() => _TrackChoicesState();
}

class _TrackChoicesState extends State<TrackChoices> {
  bool _subtitles = false;

  Widget _segment(String label, bool selected, VoidCallback onPressed) =>
      Focusable(
        onPressed: onPressed,
        semanticLabel: '$label${selected ? ', selected' : ''}',
        builder: (context, focused) => AnimatedContainer(
          duration: Zoro.focusDuration,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: focused
                ? Zoro.text
                : (selected ? const Color(0x33FFFFFF) : Colors.transparent),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: Zoro.font(
              22,
              weight: FontWeight.w600,
              color: focused
                  ? Zoro.background
                  : (selected ? Zoro.text : Zoro.muted),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final options = widget.options;
    final audio = widget.streams.where((s) => s.type == 'Audio').toList();
    final subtitles = widget.streams
        .where((s) => s.type == 'Subtitle')
        .toList();
    final language = TrackChoices.language;
    final detail = TrackChoices.detail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.isLive) ...[
          Text(
            'Changes restart at live.',
            style: Zoro.font(20, color: Zoro.muted),
          ),
          const SizedBox(height: 20),
        ],
        FocusTraversalGroup(
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0x14FFFFFF),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _segment(
                    'Audio',
                    !_subtitles,
                    () => setState(() => _subtitles = false),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _segment(
                    'Subtitles',
                    _subtitles,
                    () => setState(() => _subtitles = true),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          _subtitles ? 'Subtitles' : 'Audio',
          style: Zoro.font(28, weight: FontWeight.w600),
        ),
        const SizedBox(height: 14),
        FocusScope(
          key: ValueKey(_subtitles),
          autofocus: true,
          child: Column(
            children: _subtitles
                ? [
                    PlayerOptionRow(
                      title: 'Off',
                      selected: options.subtitleIndex == -1,
                      onPressed: () => widget.onSubtitles(-1),
                    ),
                    for (final s in subtitles)
                      PlayerOptionRow(
                        title: language(s) + (s.isForced ? ' (Forced)' : ''),
                        detail: detail(s, subtitles),
                        selected: options.subtitleIndex == s.index,
                        onPressed: () => widget.onSubtitles(s.index),
                      ),
                    if (widget.onSubtitleOffset != null &&
                        options.subtitleIndex >= 0) ...[
                      const _TimingDivider(),
                      TimingRow(
                        title: 'Subtitle timing',
                        value: widget.subtitleOffset,
                        onChanged: widget.onSubtitleOffset!,
                      ),
                    ],
                  ]
                : [
                    if (audio.length != 1)
                      PlayerOptionRow(
                        title: 'Automatic',
                        selected: options.audioIndex == null,
                        onPressed: () => widget.onAudio(null),
                      ),
                    for (final s in audio)
                      PlayerOptionRow(
                        title: language(s),
                        detail: detail(s, audio),
                        selected:
                            options.audioIndex == s.index ||
                            (audio.length == 1 && options.audioIndex == null),
                        onPressed: () => widget.onAudio(s.index),
                      ),
                    if (widget.onAudioOffset != null) ...[
                      const _TimingDivider(),
                      TimingRow(
                        title: 'Audio timing',
                        value: widget.audioOffset,
                        onChanged: widget.onAudioOffset!,
                      ),
                    ],
                  ],
          ),
        ),
      ],
    );
  }
}

class _TimingDivider extends StatelessWidget {
  const _TimingDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 10),
    child: Divider(height: 1, color: Color(0x1FFFFFFF)),
  );
}

/// "1080p · HEVC · EAC3 6 ch" for the source file's default tracks.
String playbackSourceSummary(List<MediaStream> streams) {
  final video = streams.where((s) => s.type == 'Video').firstOrNull;
  final audio =
      streams.where((s) => s.type == 'Audio' && s.isDefault).firstOrNull ??
      streams.where((s) => s.type == 'Audio').firstOrNull;
  return [
    if (video?.height != null) '${video!.height}p',
    ?video?.codec?.toUpperCase(),
    if (audio != null)
      [
        audio.codec?.toUpperCase(),
        if (audio.channels != null) '${audio.channels} ch',
      ].nonNulls.join(' '),
  ].where((s) => s.isNotEmpty).join(' · ');
}

/// Facts about the current stream (Apple `playbackInformation`).
class PlaybackInformation extends StatelessWidget {
  const PlaybackInformation({super.key, required this.facts, this.source = ''});

  final List<(String, String)> facts;
  final String source;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (title, value) in facts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Text(title, style: Zoro.font(22, color: Zoro.muted)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      value,
                      textAlign: TextAlign.end,
                      style: Zoro.font(22),
                    ),
                  ),
                ],
              ),
            ),
          if (source.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Source file', style: Zoro.font(22, weight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(source, style: Zoro.font(22, color: Zoro.muted)),
            const SizedBox(height: 6),
            Text(
              'Source formats can differ from playback output.',
              style: Zoro.font(18, color: Zoro.muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Bottom-right card when an episode finishes (Apple "Up next").
class UpNextCard extends StatelessWidget {
  const UpNextCard({
    super.key,
    required this.item,
    required this.countdown,
    required this.onPlay,
    required this.onCancel,
  });

  final MediaItem item;
  final int? countdown;
  final VoidCallback onPlay;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 660,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Zoro.panel,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            countdown == null ? 'Up next' : 'Up next in $countdown',
            style: Zoro.font(20, weight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          Text(
            item.displayTitle,
            style: Zoro.font(26, weight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(item.episodeLabel, style: Zoro.font(20, color: Zoro.muted)),
          const SizedBox(height: 18),
          FocusTraversalGroup(
            child: Row(
              children: [
                ZoroButton(
                  label: 'Play now',
                  primary: true,
                  autofocus: true,
                  onPressed: onPlay,
                ),
                const SizedBox(width: 12),
                ZoroButton(label: 'Cancel', onPressed: onCancel),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `7:30 PM`, for guide times.
String clockLabel(DateTime t) {
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$hour:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// Live TV "Channels & guide" (Apple `liveChannelFields`): what is on now and
/// next on this channel, a channel search, and every channel with what it is
/// airing.
class ChannelChoices extends StatefulWidget {
  const ChannelChoices({
    super.key,
    required this.currentId,
    required this.channels,
    required this.onSelect,
    required this.onRetry,
    this.now,
    this.next,
    this.upcoming = const [],
    this.error,
  });

  final String currentId;

  /// Null while loading.
  final List<MediaItem>? channels;
  final LiveProgram? now;
  final LiveProgram? next;
  final List<LiveProgram> upcoming;
  final String? error;
  final ValueChanged<MediaItem> onSelect;
  final VoidCallback onRetry;

  @override
  State<ChannelChoices> createState() => _ChannelChoicesState();
}

class _ChannelChoicesState extends State<ChannelChoices> {
  String _query = '';

  String _title(MediaItem c) => [?c.channelNumber, c.name].join(' · ');

  String? _airing(MediaItem c) {
    final program = c.currentProgram;
    return program != null && program.isAiring(DateTime.now())
        ? program.name
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.now, next = widget.next, channels = widget.channels;
    final query = _query.trim().toLowerCase();
    final shown = (channels ?? const <MediaItem>[])
        .where(
          (c) =>
              query.isEmpty ||
              '${c.name} ${c.channelNumber ?? ''} ${_airing(c) ?? ''}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (now != null) ...[
          Text(
            'Now · ${now.name}',
            style: Zoro.font(23, weight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            '${clockLabel(now.start!)} – ${clockLabel(now.end!)}',
            style: Zoro.font(21, color: Zoro.muted),
          ),
          const SizedBox(height: 10),
        ],
        if (widget.upcoming.isNotEmpty) ...[
          Text(
            'Upcoming on this channel',
            style: Zoro.font(21, weight: FontWeight.w600),
          ),
          for (final program in widget.upcoming)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '${clockLabel(program.start!)} · ${program.name}',
                style: Zoro.font(20, color: Zoro.muted),
              ),
            ),
          const SizedBox(height: 16),
        ] else if (next != null) ...[
          Text('Next · ${next.name}', style: Zoro.font(21, color: Zoro.muted)),
          const SizedBox(height: 16),
        ],
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: TvTextField(
            decoration: const InputDecoration(labelText: 'Find a channel'),
            style: Zoro.font(24),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        const SizedBox(height: 16),
        if (channels == null && widget.error == null)
          Text('Loading channels…', style: Zoro.font(21, color: Zoro.muted)),
        if (widget.error != null) ...[
          Text(widget.error!, style: Zoro.font(21, color: Zoro.muted)),
          const SizedBox(height: 12),
          ZoroButton(label: 'Try again', onPressed: widget.onRetry),
        ],
        FocusTraversalGroup(
          child: Column(
            children: [
              for (final c in shown)
                PlayerOptionRow(
                  title: _title(c),
                  detail: _airing(c),
                  selected: c.id == widget.currentId,
                  onPressed: () => widget.onSelect(c),
                ),
            ],
          ),
        ),
        if (channels != null && channels.isEmpty)
          Text(
            'No channels are available for this account.',
            style: Zoro.font(21, color: Zoro.muted),
          )
        else if (channels != null && shown.isEmpty)
          Text(
            'No matching channels.',
            style: Zoro.font(21, color: Zoro.muted),
          ),
      ],
    );
  }
}
