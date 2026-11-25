import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/ass.dart';
import 'package:zorofin_tv/ui/widgets/ass_overlay.dart';

const script = '''
[Script Info]
; A comment
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,64,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,40,40,50,1
Style: Sign,Arial,48,&H0000FFFF,&H000000FF,&H00202020,&H00000000,-1,0,0,0,100,100,0,0,3,4,0,8,10,10,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.50,Default,,0,0,0,,Hello, {\\i1}world{\\i0}!\\NSecond line
Dialogue: 1,0:00:02.00,0:00:03.00,Sign,,0,0,0,,{\\an7\\pos(100,200)\\c&H0000FF&\\fs30}Top sign
Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,{\\fad(500,250)\\b1\\1a&H80&}Fading
Dialogue: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 10{\\p0}
Dialogue: 0,0:00:09.00,0:00:10.00,Default,,0,0,0,,{a translator note}Plain {\\r}reset {\\3c&HFF0000&\\bord0}no outline
Comment: 0,0:00:01.00,0:00:04.50,Default,,0,0,0,,Not shown
''';

void main() {
  final subs = AssSubtitles.parse(script);

  test('reads the script size, styles and dialogue timing', () {
    expect((subs.width, subs.height), (1920, 1080));
    expect(
      subs.length,
      4,
    ); // The drawing-only line and the comment are skipped.
    expect(subs.activeAt(const Duration(milliseconds: 999)), isEmpty);
    expect(
      subs.activeAt(const Duration(seconds: 1)).single.plainText,
      'Hello, world!\nSecond line',
    );
    expect(subs.activeAt(const Duration(milliseconds: 4500)), isEmpty);
  });

  test('keeps style colours, outline, margins and inline italics', () {
    final line = subs.activeAt(const Duration(seconds: 1)).single;
    expect(line.alignment, 2);
    expect((line.marginL, line.marginR, line.marginV), (40, 40, 50));
    expect(line.runs.map((r) => r.text), [
      'Hello, ',
      'world',
      '!\nSecond line',
    ]);
    expect(line.runs.map((r) => r.italic), [false, true, false]);
    final first = line.runs.first;
    expect(first.fontSize, 64);
    expect(first.color, 0xFFFFFFFF);
    expect(first.outlineColor, 0xFF000000);
    expect(first.backColor, 0x7F000000);
    expect(first.outline, 3);
    expect(first.shadow, 1);
  });

  test(
    'applies position, alignment, colour and size overrides above layer 0',
    () {
      final lines = subs.activeAt(const Duration(milliseconds: 2500));
      expect(lines.map((l) => l.layer), [0, 1]);
      final sign = lines.last;
      expect((sign.x, sign.y, sign.alignment), (100.0, 200.0, 7));
      expect(sign.boxed, isTrue);
      final run = sign.runs.single;
      expect(run.text, 'Top sign');
      expect(run.color, 0xFFFF0000); // &H0000FF& is BGR red.
      expect(run.fontSize, 30);
      expect(run.bold, isTrue);
    },
  );

  test('fades in and out and applies alpha overrides', () {
    final line = subs.activeAt(const Duration(seconds: 5)).single;
    expect(line.runs.single.bold, isTrue);
    expect(line.runs.single.color >> 24, 0x7F);
    expect(line.opacityAt(const Duration(seconds: 5)), 0);
    expect(
      line.opacityAt(const Duration(milliseconds: 5250)),
      closeTo(.5, .01),
    );
    expect(line.opacityAt(const Duration(milliseconds: 5600)), 1);
    expect(
      line.opacityAt(const Duration(milliseconds: 5875)),
      closeTo(.5, .01),
    );
  });

  test('skips comments in braces and resets with \\r', () {
    final line = subs.activeAt(const Duration(seconds: 9)).single;
    expect(line.plainText, 'Plain reset no outline');
    expect(line.runs.last.outlineColor, 0xFF0000FF);
    expect(line.runs.last.outline, 0);
  });

  test('older SSA scripts use legacy alignment and default resolution', () {
    final ssa = AssSubtitles.parse('''
[Script Info]
ScriptType: v4.00

[V4 Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
Style: Default,Arial,20,16777215,65535,0,0,0,0,1,2,0,6,10,10,10,0,0

[Events]
Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: Marked=0,0:00:01.5,0:00:02.25,Default,,0000,0000,0000,,Top centre
''');
    expect((ssa.width, ssa.height), (384, 288));
    final line = ssa.activeAt(const Duration(milliseconds: 1500)).single;
    expect(line.alignment, 8);
    expect(line.runs.single.color, 0xFFFFFFFF);
    expect(ssa.activeAt(const Duration(milliseconds: 2250)), isEmpty);
  });

  test('serializes compactly for the LG web player', () {
    final json = subs.toJson();
    expect((json['width'], json['height']), (1920, 1080));
    final events = json['events'] as List;
    expect(events, hasLength(4));
    final sign = events.firstWhere((e) => (e as Map)['x'] != null) as Map;
    expect(
      (sign['x'], sign['y'], sign['a'], sign['box']),
      (100.0, 200.0, 7, true),
    );
    expect(((sign['r'] as List).single as Map)['c'], 0xFFFF0000);
  });

  test('refuses files that are not ASS', () {
    expect(
      () => AssSubtitles.parse('WEBVTT\n\n00:01.000 --> 00:02.000\nHi'),
      throwsFormatException,
    );
  });

  testWidgets('draws lines scaled to the video box', (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 640,
            height: 360,
            child: AssOverlay(
              script: subs,
              lines: subs.activeAt(const Duration(milliseconds: 2500)),
              at: const Duration(milliseconds: 2500),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('Second line'), findsWidgets);
    final sign = tester.getTopLeft(find.textContaining('Top sign').first);
    final box = tester.getTopLeft(find.byType(AssOverlay));
    // \pos(100,200) with \an7 anchors the top-left at a third of the
    // script size, inside the 4 px box padding.
    expect(sign.dx - box.dx, closeTo(100 / 3 + 4 / 3, 1));
    expect(sign.dy - box.dy, closeTo(200 / 3 + 4 / 3, 1));
    final span =
        tester.widget<Text>(find.textContaining('Top sign').last).textSpan!
            as TextSpan;
    expect(span.children!.single.style!.fontSize, 10);
  });
}
