import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../core/pgs.dart';

/// Draws a decoded Blu-ray subtitle frame. Place it in a box with the video's
/// aspect ratio: the frame's own canvas is the video frame, so it is scaled
/// to fill the box exactly.
class PgsOverlay extends StatefulWidget {
  const PgsOverlay(this.frame, {super.key});

  final PgsFrame? frame;

  @override
  State<PgsOverlay> createState() => _PgsOverlayState();
}

class _PgsOverlayState extends State<PgsOverlay> {
  PgsFrame? _shown;
  List<(PgsImage, ui.Image)> _images = const [];
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _decode(widget.frame);
  }

  @override
  void didUpdateWidget(PgsOverlay old) {
    super.didUpdateWidget(old);
    if (!identical(widget.frame, _shown)) _decode(widget.frame);
  }

  Future<void> _decode(PgsFrame? frame) async {
    final request = ++_request;
    _shown = frame;
    if (frame == null) {
      _replace(const []);
      return;
    }
    final decoded = <(PgsImage, ui.Image)>[];
    for (final image in frame.images) {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        image.rgba,
        image.width,
        image.height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      decoded.add((image, await completer.future));
    }
    if (!mounted || request != _request) {
      for (final (_, image) in decoded) {
        image.dispose();
      }
      return;
    }
    _replace(decoded);
  }

  void _replace(List<(PgsImage, ui.Image)> next) {
    final old = _images;
    if (mounted) setState(() => _images = next);
    for (final (_, image) in old) {
      image.dispose();
    }
  }

  @override
  void dispose() {
    _request++;
    for (final (_, image) in _images) {
      image.dispose();
    }
    _images = const [];
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frame = _shown;
    if (frame == null || _images.isEmpty) return const SizedBox.expand();
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _PgsPainter(frame.width, frame.height, _images),
      ),
    );
  }
}

class _PgsPainter extends CustomPainter {
  _PgsPainter(this.width, this.height, this.images);

  final int width, height;
  final List<(PgsImage, ui.Image)> images;

  @override
  void paint(Canvas canvas, Size size) {
    if (width <= 0 || height <= 0) return;
    final sx = size.width / width, sy = size.height / height;
    final paint = Paint()..filterQuality = FilterQuality.medium;
    for (final (placement, image) in images) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(
          placement.x * sx,
          placement.y * sy,
          placement.width * sx,
          placement.height * sy,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PgsPainter old) =>
      !identical(old.images, images) ||
      old.width != width ||
      old.height != height;
}
