import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/home.dart';
import 'package:zorofin_tv/ui/screens/home_screen.dart';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF336699),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  test('only roughly 16:9 guide images count as event pictures', () {
    expect(isWideGuidePicture(1280, 720), isTrue);
    expect(isWideGuidePicture(400, 560), isFalse); // headshot
    expect(isWideGuidePicture(512, 512), isFalse); // channel logo
    expect(isWideGuidePicture(1200, 300), isFalse); // wordmark
    expect(isWideGuidePicture(0, 0), isFalse);
  });

  test('reads sizes from PNG, JPEG and WebP headers', () async {
    expect(encodedImageSize(await _png(64, 36)), (64, 36));
    // Minimal JPEG: SOI, an APP0 segment, then SOF0 with height 300 / width 400.
    final jpeg = [
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, //
      0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x2C, 0x01, 0x90, 0x03,
    ];
    expect(encodedImageSize(jpeg), (400, 300));
    final webp = List<int>.filled(30, 0)
      ..setAll(0, 'RIFF'.codeUnits)
      ..setAll(8, 'WEBPVP8X'.codeUnits)
      ..setAll(24, [0x7F, 0x07, 0x00, 0x37, 0x04, 0x00]);
    expect(encodedImageSize(webp), (1920, 1080));
    expect(encodedImageSize([1, 2, 3]), isNull);
  });

  for (final (label, width, height, shows) in [
    ('a wide picture shows', 64, 36, true),
    ('a portrait falls through', 30, 42, false),
  ]) {
    testWidgets(label, (tester) async {
      final bytes = await tester.runAsync(() => _png(width, height));
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: WideGuideImage(
            image: MemoryImage(bytes!),
            orElse: () => const Text('illustration'),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(find.text('illustration'), shows ? findsNothing : findsOneWidget);
      expect(find.byType(Image), shows ? findsOneWidget : findsNothing);
    });
  }
}
