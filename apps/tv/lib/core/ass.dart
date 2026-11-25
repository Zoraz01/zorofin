/// Styled subtitles (ASS/SSA, common for anime), parsed on the device so
/// colours, fonts sizes, outlines and positions survive. Requesting them as
/// WebVTT drops all of that.
///
/// Supported: script resolution, styles, layers, line breaks, and the common
/// override tags (`\b \i \u \s \fs \c \1c \3c \4c \alpha \1a \3a \an \a \pos
/// \fad \bord \shad \r`). Drawing commands (`\p`) are skipped; animation
/// (`\t`, `\move`) shows the line's starting state. Font names are not
/// honoured: the app's own typeface is used.
class AssSubtitles {
  AssSubtitles._(this.width, this.height, this._events);

  factory AssSubtitles.parse(String text) {
    var section = '';
    var resX = 0, resY = 0;
    final styles = <String, AssStyle>{};
    var styleFormat = <String>[];
    var eventFormat = <String>[];
    final events = <AssEvent>[];
    var order = 0;
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith(';')) continue;
      if (line.startsWith('[') && line.endsWith(']')) {
        section = line.substring(1, line.length - 1).toLowerCase();
        continue;
      }
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final key = line.substring(0, colon).trim().toLowerCase();
      final value = line.substring(colon + 1).trim();
      if (section == 'script info') {
        if (key == 'playresx') resX = int.tryParse(value) ?? 0;
        if (key == 'playresy') resY = int.tryParse(value) ?? 0;
      } else if (section == 'v4+ styles' || section == 'v4 styles') {
        if (key == 'format') {
          styleFormat = _fields(value, -1);
        } else if (key == 'style' && styleFormat.isNotEmpty) {
          final f = _record(styleFormat, _fields(value, styleFormat.length));
          final style = AssStyle._fromFields(f, ssa: section == 'v4 styles');
          styles[style.name.toLowerCase()] = style;
        }
      } else if (section == 'events') {
        if (key == 'format') {
          eventFormat = _fields(value, -1);
        } else if (key == 'dialogue' && eventFormat.isNotEmpty) {
          final f = _record(eventFormat, _fields(value, eventFormat.length));
          final start = _time(f['start']);
          final end = _time(f['end']);
          if (start == null || end == null || end <= start) continue;
          final style =
              styles[(f['style'] ?? '').replaceFirst('*', '').toLowerCase()] ??
              styles['default'] ??
              AssStyle.fallback;
          int margin(String name, int base) {
            final v = int.tryParse(f[name] ?? '') ?? 0;
            return v == 0 ? base : v;
          }

          final event = AssEvent._parse(
            f['text'] ?? '',
            start: start,
            end: end,
            layer: int.tryParse(f['layer'] ?? '') ?? 0,
            order: order++,
            style: style,
            styles: styles,
            marginL: margin('marginl', style.marginL),
            marginR: margin('marginr', style.marginR),
            marginV: margin('marginv', style.marginV),
          );
          if (event != null) events.add(event);
        }
      }
    }
    if (events.isEmpty && styles.isEmpty) {
      throw const FormatException('Not an ASS/SSA subtitle file');
    }
    // Defaults from the ASS specification when a script omits its size.
    if (resX <= 0 && resY <= 0) {
      resX = 384;
      resY = 288;
    } else if (resY <= 0) {
      resY = resX == 1280 ? 1024 : (resX * 3 / 4).round();
    } else if (resX <= 0) {
      resX = resY == 1024 ? 1280 : (resY * 4 / 3).round();
    }
    events.sort((a, b) {
      final layer = a.layer.compareTo(b.layer);
      return layer != 0 ? layer : a.order.compareTo(b.order);
    });
    return AssSubtitles._(resX, resY, events);
  }

  /// The script's own coordinate space (PlayResX/PlayResY).
  final int width, height;
  final List<AssEvent> _events;

  int get length => _events.length;

  /// Every line, lowest layer first.
  List<AssEvent> get events => List.unmodifiable(_events);

  /// A compact form for the LG web player, which draws the lines itself.
  Map<String, Object> toJson() => {
    'width': width,
    'height': height,
    'events': [
      for (final e in _events)
        {
          's': e.start.inMilliseconds,
          'e': e.end.inMilliseconds,
          'a': e.alignment,
          'x': ?e.x,
          'y': ?e.y,
          'ml': e.marginL,
          'mr': e.marginR,
          'mv': e.marginV,
          'box': e.boxed,
          'fi': e.fadeIn.inMilliseconds,
          'fo': e.fadeOut.inMilliseconds,
          'r': [
            for (final r in e.runs)
              {
                't': r.text,
                'fs': r.fontSize,
                'c': r.color,
                'oc': r.outlineColor,
                'bc': r.backColor,
                'b': r.bold,
                'i': r.italic,
                'u': r.underline,
                'st': r.strikeout,
                'o': r.outline,
                'sh': r.shadow,
              },
          ],
        },
    ],
  };

  /// Lines on screen at [at], lowest layer first.
  List<AssEvent> activeAt(Duration at) => [
    for (final e in _events)
      if (e.start <= at && at < e.end) e,
  ];

  /// Splits a Format/Style/Dialogue value; the last field keeps its commas.
  static List<String> _fields(String value, int count) {
    if (count < 0) {
      return [for (final f in value.split(',')) f.trim().toLowerCase()];
    }
    final parts = <String>[];
    var rest = value;
    for (var i = 0; i < count - 1; i++) {
      final comma = rest.indexOf(',');
      if (comma < 0) break;
      parts.add(rest.substring(0, comma).trim());
      rest = rest.substring(comma + 1);
    }
    parts.add(rest.trim());
    return parts;
  }

  static Map<String, String> _record(
    List<String> format,
    List<String> values,
  ) => {
    for (var i = 0; i < format.length && i < values.length; i++)
      format[i]: values[i],
  };

  static Duration? _time(String? value) {
    final m = RegExp(
      r'^(\d+):(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?$',
    ).firstMatch(value?.trim() ?? '');
    if (m == null) return null;
    // Two digits are centiseconds (0:00:01.50 is 1.5 s).
    final fraction = (m.group(4) ?? '0').padRight(3, '0');
    return Duration(
      hours: int.parse(m.group(1)!),
      minutes: int.parse(m.group(2)!),
      seconds: int.parse(m.group(3)!),
      milliseconds: int.parse(fraction),
    );
  }
}

/// A colour as 0xAARRGGBB (Flutter's order, opaque = 0xFF alpha).
typedef AssColor = int;

class AssStyle {
  const AssStyle({
    required this.name,
    this.fontSize = 20,
    this.primary = 0xFFFFFFFF,
    this.outlineColor = 0xFF000000,
    this.backColor = 0x80000000,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikeout = false,
    this.boxed = false,
    this.outline = 2,
    this.shadow = 0,
    this.alignment = 2,
    this.marginL = 10,
    this.marginR = 10,
    this.marginV = 10,
  });

  static const fallback = AssStyle(name: 'Default');

  factory AssStyle._fromFields(Map<String, String> f, {required bool ssa}) {
    int number(String key, int base) =>
        double.tryParse(f[key] ?? '')?.round() ?? base;
    double real(String key, double base) =>
        double.tryParse(f[key] ?? '') ?? base;
    bool flag(String key) => (int.tryParse(f[key] ?? '0') ?? 0) != 0;
    final align = number('alignment', 2);
    return AssStyle(
      name: f['name'] ?? 'Default',
      fontSize: real('fontsize', 20),
      primary:
          parseColor(f['primarycolour'] ?? f['primarycolor']) ?? 0xFFFFFFFF,
      outlineColor:
          parseColor(
            f['outlinecolour'] ?? f['outlinecolor'] ?? f['tertiarycolour'],
          ) ??
          0xFF000000,
      backColor: parseColor(f['backcolour'] ?? f['backcolor']) ?? 0x80000000,
      bold: flag('bold'),
      italic: flag('italic'),
      underline: flag('underline'),
      strikeout: flag('strikeout'),
      boxed: number('borderstyle', 1) == 3,
      outline: real('outline', 2),
      shadow: real('shadow', 0),
      alignment: ssa ? legacyAlignment(align) : align.clamp(1, 9),
      marginL: number('marginl', 10),
      marginR: number('marginr', 10),
      marginV: number('marginv', 10),
    );
  }

  final String name;
  final double fontSize;
  final AssColor primary, outlineColor, backColor;
  final bool bold, italic, underline, strikeout;

  /// BorderStyle 3: an opaque box in the outline colour behind the text.
  final bool boxed;
  final double outline, shadow;

  /// Numpad layout: 1-3 bottom, 4-6 middle, 7-9 top; left, centre, right.
  final int alignment;
  final int marginL, marginR, marginV;

  /// `&HAABBGGRR` (alpha 00 = opaque) or decimal, to 0xAARRGGBB.
  static AssColor? parseColor(String? value) {
    if (value == null) return null;
    final v = value.trim().replaceAll('&', '').replaceAll(RegExp('^[Hh]'), '');
    final n = value.trim().startsWith(RegExp('&?[Hh]'))
        ? int.tryParse(v, radix: 16)
        : int.tryParse(v);
    if (n == null) return null;
    final a = 255 - ((n >> 24) & 255);
    final b = (n >> 16) & 255, g = (n >> 8) & 255, r = n & 255;
    return (a << 24) | (r << 16) | (g << 8) | b;
  }

  /// SSA v4 `\a` / Alignment values (1-3 bottom, +4 top, +8 middle).
  static int legacyAlignment(int v) {
    final column = (v & 3) == 0 ? 2 : (v & 3);
    if ((v & 8) != 0) return column + 3;
    if ((v & 4) != 0) return column + 6;
    return column;
  }
}

/// One styled stretch of text within a line.
class AssRun {
  const AssRun(
    this.text, {
    required this.fontSize,
    required this.color,
    required this.outlineColor,
    required this.backColor,
    required this.bold,
    required this.italic,
    required this.underline,
    required this.strikeout,
    required this.outline,
    required this.shadow,
  });
  final String text;
  final double fontSize;
  final AssColor color, outlineColor, backColor;
  final bool bold, italic, underline, strikeout;
  final double outline, shadow;
}

class AssEvent {
  AssEvent._({
    required this.start,
    required this.end,
    required this.layer,
    required this.order,
    required this.runs,
    required this.alignment,
    required this.boxed,
    required this.marginL,
    required this.marginR,
    required this.marginV,
    this.x,
    this.y,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
  });

  final Duration start, end;
  final int layer, order;

  /// Runs in reading order; `\n` within a run's text is a line break.
  final List<AssRun> runs;
  final int alignment;
  final bool boxed;
  final int marginL, marginR, marginV;

  /// An explicit `\pos` anchor in script coordinates.
  final double? x, y;
  final Duration fadeIn, fadeOut;

  String get plainText => runs.map((r) => r.text).join();

  /// Opacity at [at] from `\fad`.
  double opacityAt(Duration at) {
    final since = at - start, left = end - at;
    var o = 1.0;
    if (fadeIn > Duration.zero && since < fadeIn) {
      o = since.inMicroseconds / fadeIn.inMicroseconds;
    }
    if (fadeOut > Duration.zero && left < fadeOut) {
      final out = left.inMicroseconds / fadeOut.inMicroseconds;
      if (out < o) o = out;
    }
    return o.clamp(0.0, 1.0);
  }

  static AssEvent? _parse(
    String text, {
    required Duration start,
    required Duration end,
    required int layer,
    required int order,
    required AssStyle style,
    required Map<String, AssStyle> styles,
    required int marginL,
    required int marginR,
    required int marginV,
  }) {
    var s = _RunState.from(style);
    var alignment = style.alignment;
    double? x, y;
    var fadeIn = Duration.zero, fadeOut = Duration.zero;
    var drawing = false;
    final runs = <AssRun>[];
    final buffer = StringBuffer();

    void flush() {
      if (buffer.isEmpty) return;
      runs.add(s.run(buffer.toString()));
      buffer.clear();
    }

    var i = 0;
    while (i < text.length) {
      final ch = text[i];
      if (ch == '{') {
        final close = text.indexOf('}', i);
        if (close < 0) {
          buffer.write(text.substring(i));
          break;
        }
        final block = text.substring(i + 1, close);
        i = close + 1;
        if (!block.contains(r'\')) continue; // A comment.
        flush();
        for (final tag in _tags(block)) {
          final name = tag.$1, arg = tag.$2;
          switch (name) {
            case 'b':
              final v = int.tryParse(arg);
              s = s.copy(bold: v == null ? s.base.bold : (v == 1 || v >= 600));
            case 'i':
              s = s.copy(italic: arg.isEmpty ? s.base.italic : arg == '1');
            case 'u':
              s = s.copy(
                underline: arg.isEmpty ? s.base.underline : arg == '1',
              );
            case 's':
              s = s.copy(
                strikeout: arg.isEmpty ? s.base.strikeout : arg == '1',
              );
            case 'fs':
              final v = double.tryParse(arg);
              s = s.copy(fontSize: v == null || v <= 0 ? s.base.fontSize : v);
            case 'c' || '1c':
              s = s.copy(color: _withAlpha(arg, s.color, s.base.primary));
            case '3c':
              s = s.copy(
                outlineColor: _withAlpha(
                  arg,
                  s.outlineColor,
                  s.base.outlineColor,
                ),
              );
            case '4c':
              s = s.copy(
                backColor: _withAlpha(arg, s.backColor, s.base.backColor),
              );
            case 'alpha':
              final a = _alpha(arg);
              if (a != null) {
                s = s.copy(
                  color: _setAlpha(s.color, a),
                  outlineColor: _setAlpha(s.outlineColor, a),
                  backColor: _setAlpha(s.backColor, a),
                );
              }
            case '1a':
              final a = _alpha(arg);
              if (a != null) s = s.copy(color: _setAlpha(s.color, a));
            case '3a':
              final a = _alpha(arg);
              if (a != null) {
                s = s.copy(outlineColor: _setAlpha(s.outlineColor, a));
              }
            case '4a':
              final a = _alpha(arg);
              if (a != null) s = s.copy(backColor: _setAlpha(s.backColor, a));
            case 'bord':
              final v = double.tryParse(arg);
              s = s.copy(outline: v == null || v < 0 ? s.base.outline : v);
            case 'shad':
              final v = double.tryParse(arg);
              s = s.copy(shadow: v == null || v < 0 ? s.base.shadow : v);
            case 'an':
              final v = int.tryParse(arg);
              if (v != null && v >= 1 && v <= 9) alignment = v;
            case 'a':
              final v = int.tryParse(arg);
              if (v != null && v > 0) alignment = AssStyle.legacyAlignment(v);
            case 'pos':
              final p = _numbers(arg);
              if (p.length >= 2) {
                x = p[0];
                y = p[1];
              }
            case 'move':
              final p = _numbers(arg);
              if (p.length >= 2 && x == null) {
                x = p[0];
                y = p[1];
              }
            case 'fad':
              final p = _numbers(arg);
              if (p.length >= 2) {
                fadeIn = Duration(milliseconds: p[0].round());
                fadeOut = Duration(milliseconds: p[1].round());
              }
            case 'r':
              final named = arg.isEmpty ? null : styles[arg.toLowerCase()];
              s = _RunState.from(named ?? style);
            case 'p':
              drawing = (int.tryParse(arg) ?? 0) > 0;
          }
        }
        continue;
      }
      if (ch == r'\' && i + 1 < text.length) {
        final next = text[i + 1];
        if (next == 'N' || next == 'n') {
          if (!drawing) buffer.write('\n');
          i += 2;
          continue;
        }
        if (next == 'h') {
          if (!drawing) buffer.write(' ');
          i += 2;
          continue;
        }
      }
      if (!drawing) buffer.write(ch);
      i++;
    }
    flush();
    if (runs.every((r) => r.text.trim().isEmpty)) return null;
    return AssEvent._(
      start: start,
      end: end,
      layer: layer,
      order: order,
      runs: runs,
      alignment: alignment,
      boxed: style.boxed,
      marginL: marginL,
      marginR: marginR,
      marginV: marginV,
      x: x,
      y: y,
      fadeIn: fadeIn,
      fadeOut: fadeOut,
    );
  }

  static final _tagNames = RegExp(
    r'^(1c|2c|3c|4c|1a|2a|3a|4a|alpha|bord|shad|fade|fad|move|pos|org|clip|iclip|fscx|fscy|fsp|fs|fn|frx|fry|frz|fr|fax|fay|an|be|blur|xbord|ybord|xshad|yshad|kf|ko|k|K|q|t|p|b|i|u|s|c|a|r)',
  );

  /// `\name(args)` or `\nameValue` tags in an override block.
  static Iterable<(String, String)> _tags(String block) sync* {
    var i = 0;
    while (i < block.length) {
      final slash = block.indexOf(r'\', i);
      if (slash < 0) return;
      var j = slash + 1;
      final m = _tagNames.firstMatch(block.substring(j));
      if (m == null) {
        i = j;
        continue;
      }
      final name = m.group(1)!;
      j += name.length;
      String arg;
      if (j < block.length && block[j] == '(') {
        var depth = 0, k = j;
        for (; k < block.length; k++) {
          if (block[k] == '(') depth++;
          if (block[k] == ')' && --depth == 0) break;
        }
        arg = block.substring(j + 1, k.clamp(j + 1, block.length));
        j = k + 1;
      } else {
        final next = block.indexOf(r'\', j);
        arg = block.substring(j, next < 0 ? block.length : next).trim();
        j = next < 0 ? block.length : next;
      }
      yield (name.toLowerCase(), arg);
      i = j;
    }
  }

  static List<double> _numbers(String arg) => [
    for (final p in arg.split(',')) ?double.tryParse(p.trim()),
  ];

  static int? _alpha(String arg) {
    final v = int.tryParse(
      arg.replaceAll('&', '').replaceAll(RegExp('^[Hh]'), ''),
      radix: 16,
    );
    return v == null ? null : 255 - (v & 255);
  }

  static AssColor _setAlpha(AssColor color, int alpha) =>
      (alpha << 24) | (color & 0xFFFFFF);

  /// `\c&HBBGGRR&` keeps the current alpha; empty restores the style colour.
  static AssColor _withAlpha(String arg, AssColor current, AssColor base) {
    if (arg.isEmpty) return base;
    final parsed = AssStyle.parseColor(arg);
    if (parsed == null) return current;
    return (current & 0xFF000000) | (parsed & 0xFFFFFF);
  }
}

class _RunState {
  _RunState(
    this.base, {
    required this.fontSize,
    required this.color,
    required this.outlineColor,
    required this.backColor,
    required this.bold,
    required this.italic,
    required this.underline,
    required this.strikeout,
    required this.outline,
    required this.shadow,
  });

  factory _RunState.from(AssStyle s) => _RunState(
    s,
    fontSize: s.fontSize,
    color: s.primary,
    outlineColor: s.outlineColor,
    backColor: s.backColor,
    bold: s.bold,
    italic: s.italic,
    underline: s.underline,
    strikeout: s.strikeout,
    outline: s.outline,
    shadow: s.shadow,
  );

  final AssStyle base;
  final double fontSize;
  final AssColor color, outlineColor, backColor;
  final bool bold, italic, underline, strikeout;
  final double outline, shadow;

  _RunState copy({
    double? fontSize,
    AssColor? color,
    AssColor? outlineColor,
    AssColor? backColor,
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strikeout,
    double? outline,
    double? shadow,
  }) => _RunState(
    base,
    fontSize: fontSize ?? this.fontSize,
    color: color ?? this.color,
    outlineColor: outlineColor ?? this.outlineColor,
    backColor: backColor ?? this.backColor,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    strikeout: strikeout ?? this.strikeout,
    outline: outline ?? this.outline,
    shadow: shadow ?? this.shadow,
  );

  AssRun run(String text) => AssRun(
    text,
    fontSize: fontSize,
    color: color,
    outlineColor: outlineColor,
    backColor: backColor,
    bold: bold,
    italic: italic,
    underline: underline,
    strikeout: strikeout,
    outline: outline,
    shadow: shadow,
  );
}
