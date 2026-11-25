import 'package:flutter/material.dart';

import '../../core/ass.dart';

/// Draws styled (ASS/SSA) subtitle lines. Place it in a box with the video's
/// aspect ratio: script coordinates are scaled to that box, as libass does.
class AssOverlay extends StatelessWidget {
  const AssOverlay({
    super.key,
    required this.script,
    required this.lines,
    required this.at,
  });

  final AssSubtitles script;
  final List<AssEvent> lines;
  final Duration at;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return const SizedBox.expand();
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, size) {
          final sx = size.maxWidth / script.width;
          final sy = size.maxHeight / script.height;
          final children = <Widget>[];
          // Unpositioned lines that share an alignment stack instead of
          // overlapping: later bottom lines go above, later top lines below.
          final groups = <int, List<AssEvent>>{};
          for (final line in lines) {
            if (line.x != null && line.y != null) {
              final col = (line.alignment - 1) % 3;
              final row = (line.alignment - 1) ~/ 3;
              children.add(
                Positioned(
                  left: line.x! * sx,
                  top: line.y! * sy,
                  child: FractionalTranslation(
                    translation: Offset(
                      -col / 2,
                      row == 0 ? -1 : (row == 1 ? -.5 : 0),
                    ),
                    child: _line(line, sy),
                  ),
                ),
              );
            } else {
              groups.putIfAbsent(line.alignment, () => []).add(line);
            }
          }
          groups.forEach((alignment, group) {
            final col = (alignment - 1) % 3;
            final row = (alignment - 1) ~/ 3;
            final first = group.first;
            final ordered = row == 0 ? group.reversed.toList() : group;
            children.add(
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    first.marginL * sx,
                    row == 1 ? 0 : first.marginV * sy,
                    first.marginR * sx,
                    row == 1 ? 0 : first.marginV * sy,
                  ),
                  child: Align(
                    alignment: Alignment(
                      col - 1.0,
                      row == 0 ? 1 : (row == 1 ? 0 : -1),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: [
                        CrossAxisAlignment.start,
                        CrossAxisAlignment.center,
                        CrossAxisAlignment.end,
                      ][col],
                      children: [for (final line in ordered) _line(line, sy)],
                    ),
                  ),
                ),
              ),
            );
          });
          return Stack(clipBehavior: Clip.hardEdge, children: children);
        },
      ),
    );
  }

  Widget _line(AssEvent line, double scale) {
    final align = [
      TextAlign.left,
      TextAlign.center,
      TextAlign.right,
    ][(line.alignment - 1) % 3];
    TextStyle base(AssRun run) => TextStyle(
      fontSize: run.fontSize * scale,
      height: 1.15,
      fontWeight: run.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: run.italic ? FontStyle.italic : FontStyle.normal,
      decoration: TextDecoration.combine([
        if (run.underline) TextDecoration.underline,
        if (run.strikeout) TextDecoration.lineThrough,
      ]),
    );
    final fill = Text.rich(
      TextSpan(
        children: [
          for (final run in line.runs)
            TextSpan(
              text: run.text,
              style: base(run).copyWith(
                color: Color(run.color),
                decorationColor: Color(run.color),
                shadows: run.shadow > 0 && !line.boxed
                    ? [
                        Shadow(
                          color: Color(run.backColor),
                          offset: Offset(
                            run.shadow * scale,
                            run.shadow * scale,
                          ),
                        ),
                      ]
                    : null,
              ),
            ),
        ],
      ),
      textAlign: align,
      softWrap: line.x == null,
    );
    final outlined = !line.boxed && line.runs.any((r) => r.outline > 0);
    Widget body = outlined
        ? Stack(
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    for (final run in line.runs)
                      TextSpan(
                        text: run.text,
                        style: base(run).copyWith(
                          foreground: Paint()
                            ..style = PaintingStyle.stroke
                            ..strokeJoin = StrokeJoin.round
                            ..strokeWidth = run.outline * 2 * scale
                            ..color = Color(run.outlineColor),
                        ),
                      ),
                  ],
                ),
                textAlign: align,
                softWrap: line.x == null,
              ),
              fill,
            ],
          )
        : fill;
    if (line.boxed) {
      final run = line.runs.first;
      body = DecoratedBox(
        decoration: BoxDecoration(color: Color(run.outlineColor)),
        child: Padding(
          padding: EdgeInsets.all(run.outline * scale),
          child: body,
        ),
      );
    }
    final opacity = line.opacityAt(at);
    return opacity >= 1 ? body : Opacity(opacity: opacity, child: body);
  }
}
