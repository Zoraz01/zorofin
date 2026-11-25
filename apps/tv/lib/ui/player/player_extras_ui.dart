import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/player_extras.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import 'player_controls.dart' show timeLabel;

/// One scrub thumbnail cut from a Jellyfin trickplay sheet.
class TrickplayFrame extends StatelessWidget {
  const TrickplayFrame({
    super.key,
    required this.info,
    required this.sheet,
    required this.position,
    required this.width,
  });

  final Trickplay info;

  /// Builds the image for a sheet index (auth headers included).
  final ImageProvider Function(int sheet) sheet;
  final Duration position;
  final double width;

  @override
  Widget build(BuildContext context) {
    final frame = info.frameAt(position);
    final height = width * info.height / info.width;
    return SizedBox(
      width: width,
      height: height,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          minHeight: 0,
          maxWidth: double.infinity,
          maxHeight: double.infinity,
          child: Transform.translate(
            offset: Offset(-frame.column * width, -frame.row * height),
            child: Image(
              image: sheet(frame.sheet),
              width: width * info.tileWidth,
              height: height * info.tileHeight,
              fit: BoxFit.fill,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => const SizedBox(),
            ),
          ),
        ),
      ),
    );
  }
}

/// What floats over the timeline while scrubbing: the frame (when the server
/// made trickplay images), the time, and the chapter it lands in.
class ScrubPreview extends StatelessWidget {
  const ScrubPreview({
    super.key,
    required this.position,
    this.trickplay,
    this.sheet,
    this.chapter,
    this.width = 320,
  });

  final Duration position;
  final Trickplay? trickplay;
  final ImageProvider Function(int sheet)? sheet;
  final String? chapter;
  final double width;

  @override
  Widget build(BuildContext context) {
    final picture = trickplay != null && sheet != null;
    final label = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          timeLabel(position),
          style: Zoro.font(
            20,
            weight: FontWeight.w600,
            color: Colors.white,
          ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
        if (chapter != null)
          Text(
            chapter!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Zoro.font(16, color: const Color(0xD9FFFFFF)),
          ),
      ],
    );
    return IgnorePointer(
      child: Container(
        width: picture ? width + 8 : null,
        constraints: BoxConstraints(maxWidth: width + 8),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xE6141716),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x33FFFFFF)),
          boxShadow: const [
            BoxShadow(color: Color(0x80000000), blurRadius: 18),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (picture)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: TrickplayFrame(
                  info: trickplay!,
                  sheet: sheet!,
                  position: position,
                  width: width,
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: label,
            ),
          ],
        ),
      ),
    );
  }
}

/// "Subtitle timing   ‹ +0.3 s ›". Left and Right (or the chevrons) move it
/// in 0.1 s steps; OK sets it back in sync.
class TimingRow extends StatefulWidget {
  const TimingRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.hint = 'Left: earlier · Right: later · OK: reset',
  });

  final String title;
  final Duration value;
  final ValueChanged<Duration> onChanged;
  final String hint;

  @override
  State<TimingRow> createState() => _TimingRowState();
}

class _TimingRowState extends State<TimingRow> {
  void _step(int direction) {
    final next = widget.value + timingStep * direction;
    if (next.abs() > TrackMemory.maxOffset) return;
    widget.onChanged(next);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _step(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _step(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _chevron(IconData icon, int direction, Color color) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => _step(direction),
    child: Padding(
      padding: const EdgeInsets.all(6),
      child: Icon(icon, color: color, size: 30),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Focus(
      skipTraversal: true,
      onKeyEvent: _key,
      child: Focusable(
        semanticLabel: '${widget.title}, ${timingLabel(widget.value)}',
        onPressed: () => widget.onChanged(Duration.zero),
        builder: (context, focused) {
          final fg = focused ? Zoro.background : Zoro.text;
          final muted = focused ? Zoro.background : Zoro.muted;
          return AnimatedContainer(
            duration: Zoro.focusDuration,
            constraints: const BoxConstraints(minHeight: 60),
            padding: const EdgeInsets.fromLTRB(52, 6, 4, 6),
            decoration: BoxDecoration(
              color: focused ? Zoro.text : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(widget.title, style: Zoro.font(24, color: fg)),
                      AnimatedSize(
                        duration: Zoro.focusDuration,
                        child: focused
                            ? Text(
                                widget.hint,
                                style: Zoro.font(16, color: muted),
                              )
                            : const SizedBox(height: 0),
                      ),
                    ],
                  ),
                ),
                _chevron(Icons.chevron_left_rounded, -1, muted),
                SizedBox(
                  width: 88,
                  child: Text(
                    timingLabel(widget.value),
                    textAlign: TextAlign.center,
                    style:
                        Zoro.font(
                          22,
                          weight: FontWeight.w600,
                          color: widget.value == Duration.zero ? muted : fg,
                        ).copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                  ),
                ),
                _chevron(Icons.chevron_right_rounded, 1, muted),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The chapter strip: stills with names and start times; the playing chapter
/// is focused first.
class ChapterChoices extends StatelessWidget {
  const ChapterChoices({
    super.key,
    required this.chapters,
    required this.current,
    required this.image,
    required this.onSelect,
  });

  final List<Chapter> chapters;
  final int? current;

  /// The still for a chapter, or null when it has none.
  final ImageProvider? Function(int index) image;
  final ValueChanged<Chapter> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 250,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: chapters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 20),
        itemBuilder: (context, i) {
          final chapter = chapters[i];
          final still = image(i);
          final playing = i == current;
          return Focusable(
            autofocus: playing || (current == null && i == 0),
            semanticLabel:
                '${chapter.name}, ${timeLabel(chapter.start)}${playing ? ', playing' : ''}',
            onPressed: () => onSelect(chapter),
            builder: (context, focused) => AnimatedScale(
              scale: focused ? 1.06 : 1,
              duration: Zoro.focusDuration,
              child: SizedBox(
                width: 288,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedContainer(
                      duration: Zoro.focusDuration,
                      height: 162,
                      decoration: BoxDecoration(
                        color: const Color(0x1AFFFFFF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: focused
                              ? Colors.white
                              : (playing ? Zoro.jade : Colors.transparent),
                          width: 3,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: still == null
                          ? Center(
                              child: Text(
                                '${i + 1}',
                                style: Zoro.font(
                                  44,
                                  weight: FontWeight.w600,
                                  color: Zoro.muted,
                                ),
                              ),
                            )
                          : Image(
                              image: still,
                              fit: BoxFit.cover,
                              width: 288,
                              height: 162,
                              errorBuilder: (_, _, _) => const SizedBox(),
                            ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      chapter.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Zoro.font(
                        21,
                        weight: FontWeight.w600,
                        color: focused || playing ? Zoro.text : Zoro.muted,
                      ),
                    ),
                    Text(
                      playing
                          ? 'Playing · ${timeLabel(chapter.start)}'
                          : timeLabel(chapter.start),
                      style: Zoro.font(
                        17,
                        color: playing ? Zoro.jade : Zoro.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
