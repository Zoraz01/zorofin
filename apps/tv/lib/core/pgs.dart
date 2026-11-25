import 'dart:typed_data';

/// Blu-ray image subtitles (PGS, `.sup`), decoded on the device so the
/// server can keep direct playing instead of burning them into a transcode.
///
/// Format: a stream of segments, each `PG` + PTS + DTS (90 kHz) + type + size.
/// A display set is a presentation composition (PCS) followed by window (WDS),
/// palette (PDS) and object (ODS) definitions and an end segment. Objects and
/// palettes persist until the next epoch start, so a composition may reuse
/// earlier ones. Pixel data is run-length encoded palette indexes.
class PgsSubtitles {
  PgsSubtitles._(this._sets);

  /// Refuses files that are not PGS rather than drawing garbage.
  factory PgsSubtitles.parse(Uint8List bytes) {
    final sets = <_DisplaySet>[];
    var palettes = <int, Uint32List>{};
    var objects = <int, _ObjectData>{};
    var windows = <int, PgsRect>{};
    _Composition? composition;
    var offset = 0;
    while (offset + 13 <= bytes.length) {
      if (bytes[offset] != 0x50 || bytes[offset + 1] != 0x47) {
        throw const FormatException('Not a PGS subtitle stream');
      }
      final pts = _u32(bytes, offset + 2);
      final type = bytes[offset + 10];
      final size = _u16(bytes, offset + 11);
      final start = offset + 13;
      final end = start + size;
      if (end > bytes.length) break;
      final data = Uint8List.sublistView(bytes, start, end);
      offset = end;
      switch (type) {
        case 0x16: // Presentation composition
          if (data.length < 11) continue;
          final state = data[7];
          if (state != 0) {
            // Epoch start or acquisition point: earlier objects are released.
            palettes = {};
            objects = {};
            windows = {};
          }
          final count = data[10];
          final parts = <_Placement>[];
          var at = 11;
          for (var i = 0; i < count && at + 8 <= data.length; i++) {
            final cropped = (data[at + 3] & 0x80) != 0;
            parts.add(
              _Placement(
                _u16(data, at),
                _u16(data, at + 4),
                _u16(data, at + 6),
                cropped && at + 16 <= data.length
                    ? PgsRect(
                        _u16(data, at + 8),
                        _u16(data, at + 10),
                        _u16(data, at + 12),
                        _u16(data, at + 14),
                      )
                    : null,
              ),
            );
            at += cropped ? 16 : 8;
          }
          composition = _Composition(
            Duration(microseconds: pts * 100 ~/ 9),
            _u16(data, 0),
            _u16(data, 2),
            data[9],
            parts,
          );
        case 0x17: // Window definition
          if (data.isEmpty) continue;
          var at = 1;
          for (var i = 0; i < data[0] && at + 9 <= data.length; i++) {
            windows[data[at]] = PgsRect(
              _u16(data, at + 1),
              _u16(data, at + 3),
              _u16(data, at + 5),
              _u16(data, at + 7),
            );
            at += 9;
          }
        case 0x14: // Palette definition
          if (data.length < 2) continue;
          final palette = Uint32List.fromList(
            palettes[data[0]] ?? Uint32List(256),
          );
          for (var at = 2; at + 5 <= data.length; at += 5) {
            palette[data[at]] = _rgba(
              data[at + 1],
              data[at + 2],
              data[at + 3],
              data[at + 4],
            );
          }
          palettes[data[0]] = palette;
        case 0x15: // Object definition
          if (data.length < 4) continue;
          final id = _u16(data, 0);
          final flags = data[3];
          if ((flags & 0x80) != 0) {
            if (data.length < 11) continue;
            objects[id] = _ObjectData(_u16(data, 7), _u16(data, 9), [
              Uint8List.fromList(data.sublist(11)),
            ]);
          } else {
            objects[id]?.chunks.add(Uint8List.fromList(data.sublist(4)));
          }
        case 0x80: // End of display set
          final c = composition;
          composition = null;
          if (c == null) continue;
          final palette = palettes[c.paletteId];
          final images = <_PendingImage>[
            for (final p in c.placements)
              if (objects[p.objectId] case final object?)
                if (palette != null &&
                    object.width > 0 &&
                    object.height > 0 &&
                    object.width * object.height <= _maxPixels)
                  _PendingImage(p, object, palette),
          ];
          sets.add(_DisplaySet(c.at, c.width, c.height, images));
      }
    }
    if (offset == 0 && bytes.isNotEmpty) {
      throw const FormatException('Not a PGS subtitle stream');
    }
    return PgsSubtitles._(sets);
  }

  static const _maxPixels = 4096 * 2160;

  final List<_DisplaySet> _sets;
  int? _cachedIndex;
  PgsFrame? _cachedFrame;

  int get length => _sets.length;

  /// What should be on screen at [at] on the title's timeline; null when
  /// nothing is. The last frame is cached, since playback asks repeatedly.
  PgsFrame? frameAt(Duration at) {
    var low = 0, high = _sets.length - 1, index = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (_sets[mid].at <= at) {
        index = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    if (index < 0) return null;
    if (index == _cachedIndex) return _cachedFrame;
    final set = _sets[index];
    final frame = set.images.isEmpty
        ? null
        : PgsFrame(index, set.width, set.height, [
            for (final image in set.images) image.decode(),
          ]);
    _cachedIndex = index;
    _cachedFrame = frame;
    return frame;
  }

  static int _u16(Uint8List b, int at) => (b[at] << 8) | b[at + 1];
  static int _u32(Uint8List b, int at) =>
      (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

  /// BT.709 limited-range YCbCr, as Blu-ray uses for HD, to RGBA bytes
  /// packed little-endian (R first in memory).
  static int _rgba(int y, int cr, int cb, int alpha) {
    final luma = 1.164 * (y - 16);
    int clamp(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());
    final r = clamp(luma + 1.793 * (cr - 128));
    final g = clamp(luma - 0.213 * (cb - 128) - 0.533 * (cr - 128));
    final b = clamp(luma + 2.112 * (cb - 128));
    // Flutter's rgba8888 texture expects premultiplied channels, including
    // zero RGB for transparent palette entries that carry a nonzero color.
    int premultiply(int channel) => (channel * alpha + 127) ~/ 255;
    return premultiply(r) |
        (premultiply(g) << 8) |
        (premultiply(b) << 16) |
        (alpha << 24);
  }
}

/// One rectangle on the subtitle's own canvas (usually the video frame).
class PgsRect {
  const PgsRect(this.x, this.y, this.width, this.height);
  final int x, y, width, height;

  @override
  bool operator ==(Object other) =>
      other is PgsRect &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);
}

/// The images on screen for one display set, sized for a [width] x [height]
/// canvas that matches the video frame.
class PgsFrame {
  const PgsFrame(this.index, this.width, this.height, this.images);
  final int index;
  final int width, height;
  final List<PgsImage> images;
}

/// Decoded RGBA pixels (premultiplied alpha) placed at [x], [y].
class PgsImage {
  const PgsImage(this.x, this.y, this.width, this.height, this.rgba);
  final int x, y, width, height;
  final Uint8List rgba;
}

class _Composition {
  _Composition(
    this.at,
    this.width,
    this.height,
    this.paletteId,
    this.placements,
  );
  final Duration at;
  final int width, height, paletteId;
  final List<_Placement> placements;
}

class _Placement {
  const _Placement(this.objectId, this.x, this.y, this.crop);
  final int objectId, x, y;
  final PgsRect? crop;
}

class _ObjectData {
  _ObjectData(this.width, this.height, this.chunks);
  final int width, height;
  final List<Uint8List> chunks;
}

class _DisplaySet {
  _DisplaySet(this.at, this.width, this.height, this.images);
  final Duration at;
  final int width, height;
  final List<_PendingImage> images;
}

class _PendingImage {
  // Snapshot: later segments may replace the object or its chunks; a
  // palette update always makes a new palette list.
  _PendingImage(this.placement, _ObjectData object, this.palette)
    : width = object.width,
      height = object.height,
      chunks = List.of(object.chunks);
  final _Placement placement;
  final int width, height;
  final List<Uint8List> chunks;
  final Uint32List palette;

  PgsImage decode() {
    final pixels = Uint32List(width * height);
    var i = 0;
    final total = pixels.length;
    for (final chunk in chunks) {
      var at = 0;
      while (at < chunk.length && i < total) {
        final first = chunk[at++];
        if (first != 0) {
          pixels[i++] = palette[first];
          continue;
        }
        if (at >= chunk.length) break;
        final second = chunk[at++];
        if (second == 0) continue; // End of line.
        var count = second & 0x3F;
        if ((second & 0x40) != 0) {
          if (at >= chunk.length) break;
          count = (count << 8) | chunk[at++];
        }
        var color = 0;
        if ((second & 0x80) != 0) {
          if (at >= chunk.length) break;
          color = palette[chunk[at++]];
        } else {
          color = palette[0];
        }
        final stop = i + count > total ? total : i + count;
        pixels.fillRange(i, stop, color);
        i = stop;
      }
    }
    var rgba = pixels.buffer.asUint8List();
    var x = placement.x, y = placement.y, w = width, h = height;
    final crop = placement.crop;
    if (crop != null &&
        crop.x + crop.width <= width &&
        crop.y + crop.height <= height &&
        crop.width > 0 &&
        crop.height > 0) {
      final out = Uint8List(crop.width * crop.height * 4);
      for (var row = 0; row < crop.height; row++) {
        final from = ((crop.y + row) * width + crop.x) * 4;
        out.setRange(
          row * crop.width * 4,
          (row + 1) * crop.width * 4,
          rgba,
          from,
        );
      }
      rgba = out;
      w = crop.width;
      h = crop.height;
    }
    return PgsImage(x, y, w, h, rgba);
  }
}
