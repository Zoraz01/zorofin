import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/errors.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/pgs.dart';
import 'package:zorofin_tv/core/server_address.dart';

/// Builds `.sup` segments the way Blu-ray authoring tools write them.
class _Sup {
  final _out = BytesBuilder();

  void segment(int seconds, int type, List<int> data) {
    final pts = seconds * 90000;
    _out.add([
      0x50, 0x47, //
      pts >> 24 & 255, pts >> 16 & 255, pts >> 8 & 255, pts & 255,
      0, 0, 0, 0,
      type,
      data.length >> 8, data.length & 255,
      ...data,
    ]);
  }

  static List<int> u16(int v) => [v >> 8 & 255, v & 255];

  void displaySet(
    int seconds, {
    required int state,
    List<(int id, int x, int y, List<int>? crop)> objects = const [],
    int paletteId = 0,
    List<(int index, int y, int cr, int cb, int a)>? palette,
    (int id, int width, int height, List<int> rle)? object,
  }) {
    segment(seconds, 0x16, [
      ...u16(1920),
      ...u16(1080),
      0x10,
      ...u16(1),
      state,
      0,
      paletteId,
      objects.length,
      for (final (id, x, y, crop) in objects) ...[
        ...u16(id),
        0,
        crop == null ? 0 : 0x80,
        ...u16(x),
        ...u16(y),
        if (crop != null)
          for (final v in crop) ...u16(v),
      ],
    ]);
    if (objects.isNotEmpty) {
      segment(seconds, 0x17, [
        1,
        0,
        ...u16(0),
        ...u16(0),
        ...u16(1920),
        ...u16(1080),
      ]);
    }
    if (palette != null) {
      segment(seconds, 0x14, [
        paletteId,
        0,
        for (final (i, y, cr, cb, a) in palette) ...[i, y, cr, cb, a],
      ]);
    }
    if (object != null) {
      final (id, w, h, rle) = object;
      final length = rle.length + 4;
      segment(seconds, 0x15, [
        ...u16(id),
        0,
        0xC0,
        length >> 16 & 255,
        length >> 8 & 255,
        length & 255,
        ...u16(w),
        ...u16(h),
        ...rle,
      ]);
    }
    segment(seconds, 0x80, []);
  }

  Uint8List get bytes => _out.toBytes();
}

/// RGBA bytes of pixel [i].
List<int> _px(PgsImage image, int i) => image.rgba.sublist(i * 4, i * 4 + 4);

void main() {
  // White (Y 235, neutral chroma) opaque at index 1, transparent at 0.
  const white = (1, 235, 128, 128, 255);
  // A 4x2 object: row 1 = colour 1 then a run of three of colour 1,
  // row 2 = two transparent (short run of 0) then two of colour 1.
  const rle = [1, 0, 0x83, 1, 0, 0, 0, 2, 0, 0x82, 1, 0, 0];

  test('decodes a subtitle, its placement and when it clears', () {
    final sup = _Sup()
      ..displaySet(
        10,
        state: 0x80,
        objects: [(0, 100, 900, null)],
        palette: [white],
        object: (0, 4, 2, rle),
      )
      ..displaySet(13, state: 0);
    final pgs = PgsSubtitles.parse(sup.bytes);
    expect(pgs.length, 2);
    expect(pgs.frameAt(const Duration(seconds: 9)), isNull);
    final frame = pgs.frameAt(const Duration(seconds: 11))!;
    expect((frame.width, frame.height), (1920, 1080));
    final image = frame.images.single;
    expect((image.x, image.y, image.width, image.height), (100, 900, 4, 2));
    expect(_px(image, 0), [255, 255, 255, 255]);
    expect(_px(image, 3), [255, 255, 255, 255]);
    expect(_px(image, 4), [0, 0, 0, 0]);
    expect(_px(image, 5), [0, 0, 0, 0]);
    expect(_px(image, 6), [255, 255, 255, 255]);
    expect(identical(pgs.frameAt(const Duration(seconds: 12)), frame), isTrue);
    expect(pgs.frameAt(const Duration(seconds: 13)), isNull);
  });

  test('a palette-only update reuses the earlier object', () {
    final sup = _Sup()
      ..displaySet(
        1,
        state: 0x80,
        objects: [(0, 0, 0, null)],
        palette: [white],
        object: (0, 4, 2, rle),
      )
      // Fade: same object, half-transparent palette, no new object.
      ..displaySet(
        2,
        state: 0,
        objects: [(0, 0, 0, null)],
        palette: [(1, 235, 128, 128, 128)],
      );
    final pgs = PgsSubtitles.parse(sup.bytes);
    expect(
      _px(pgs.frameAt(const Duration(seconds: 1))!.images.single, 0)[3],
      255,
    );
    expect(
      _px(pgs.frameAt(const Duration(seconds: 2))!.images.single, 0)[3],
      128,
    );
  });

  test('a new epoch forgets earlier objects', () {
    final sup = _Sup()
      ..displaySet(
        1,
        state: 0x80,
        objects: [(0, 0, 0, null)],
        palette: [white],
        object: (0, 4, 2, rle),
      )
      ..displaySet(
        2,
        state: 0x80,
        objects: [(0, 0, 0, null)],
        palette: [white],
      );
    final pgs = PgsSubtitles.parse(sup.bytes);
    expect(pgs.frameAt(const Duration(seconds: 2)), isNull);
  });

  test('cropping keeps only the visible part of the object', () {
    final sup = _Sup()
      ..displaySet(
        1,
        state: 0x80,
        objects: [
          (0, 50, 60, [2, 1, 2, 1]),
        ],
        palette: [white],
        object: (0, 4, 2, rle),
      );
    final image = PgsSubtitles.parse(
      sup.bytes,
    ).frameAt(const Duration(seconds: 1))!.images.single;
    expect((image.x, image.y, image.width, image.height), (50, 60, 2, 1));
    expect(_px(image, 0), [255, 255, 255, 255]);
  });

  test('BT.709 colours convert from limited-range YCbCr', () {
    final sup = _Sup()
      ..displaySet(
        1,
        state: 0x80,
        objects: [(0, 0, 0, null)],
        // Studio-range black and BT.709 red.
        palette: [(1, 16, 128, 128, 255), (2, 63, 240, 102, 255)],
        object: (0, 2, 1, [1, 2, 0, 0]),
      );
    final image = PgsSubtitles.parse(
      sup.bytes,
    ).frameAt(const Duration(seconds: 1))!.images.single;
    expect(_px(image, 0), [0, 0, 0, 255]);
    final red = _px(image, 1);
    expect(red[0], greaterThan(245));
    expect(red[1], lessThan(10));
    expect(red[2], lessThan(10));
  });

  test(
    'transparent and translucent palette entries produce valid Flutter RGBA pixels',
    () {
      final sup = _Sup()
        ..displaySet(
          1,
          state: 0x80,
          objects: [(0, 0, 0, null)],
          palette: [
            (0, 32, 117, 240, 0),
            (1, 235, 128, 128, 128),
            (2, 235, 128, 128, 255),
          ],
          object: (0, 3, 1, [0, 1, 1, 2, 0, 0]),
        );
      final image = PgsSubtitles.parse(
        sup.bytes,
      ).frameAt(const Duration(seconds: 1))!.images.single;
      expect(_px(image, 0), [0, 0, 0, 0]);
      expect(_px(image, 1), [128, 128, 128, 128]);
      expect(_px(image, 2), [255, 255, 255, 255]);
    },
  );

  test('refuses data that is not PGS', () {
    expect(
      () => PgsSubtitles.parse(Uint8List.fromList('WEBVTT\n\n'.codeUnits)),
      throwsFormatException,
    );
  });

  group('requestBytes', () {
    final server = ServerAddress.parse('https://example.com/jf');
    final session = Session(
      server: server,
      viewer: Viewer(id: 'u1', name: 'Zo'),
      token: 'tok',
      deviceId: 'dev-1',
    );
    JellyfinClient client(MockClientHandler handler) => JellyfinClient(
      server: server,
      identity: const ClientIdentity(deviceId: 'dev-1', deviceName: 'TV'),
      session: session,
      httpClient: MockClient(handler),
    );

    test(
      'fetches a DeliveryUrl on this server with the header token',
      () async {
        late http.BaseRequest sent;
        final bytes =
            await client((request) async {
              sent = request;
              return http.Response.bytes([1, 2, 3], 200);
            }).requestBytes(
              '/Videos/a/b/Subtitles/3/0/Stream.pgssub?api_key=leak&x=1',
            );
        expect(bytes, [1, 2, 3]);
        expect(
          sent.url.toString(),
          'https://example.com/jf/Videos/a/b/Subtitles/3/0/Stream.pgssub?x=1',
        );
        expect(sent.headers['Authorization'], contains('Token="tok"'));
      },
    );

    test('a cold bitmap track can arrive after the API timeout', () async {
      final sup = _Sup()
        ..displaySet(
          3,
          state: 0x80,
          objects: [(0, 0, 0, null)],
          palette: [white],
          object: (0, 1, 1, [1, 0, 0]),
        );
      final coldClient = JellyfinClient(
        server: server,
        session: session,
        identity: const ClientIdentity(deviceId: 'dev-1', deviceName: 'TV'),
        timeout: const Duration(milliseconds: 5),
        httpClient: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 43));
          return http.Response.bytes(sup.bytes, 200);
        }),
      );
      final bytes = await coldClient.requestBytes(
        '/Videos/a/b/Subtitles/3/0/Stream.pgssub',
      );
      final cue = PgsSubtitles.parse(bytes).frameAt(const Duration(seconds: 3));
      expect(cue?.images.length, 1);
    });

    test(
      'a track still extracting is fetched again after a gateway cut',
      () async {
        var calls = 0;
        final c = client((_) async {
          calls++;
          return calls < 3
              ? http.Response('', 524)
              : http.Response.bytes([7, 8], 200);
        });
        expect(await c.requestBytes('/Videos/a.sup', attempts: 4), [7, 8]);
        expect(calls, 3);
        calls = 0;
        await expectLater(
          c.requestBytes('/Videos/a.sup'),
          throwsA(isA<ClientError>()),
        );
        expect(calls, 1, reason: 'one attempt unless asked');
      },
    );

    test('does not retry a missing track', () async {
      var calls = 0;
      final c = client((_) async {
        calls++;
        return http.Response('', 404);
      });
      await expectLater(
        c.requestBytes('/Videos/a.sup', attempts: 4),
        throwsA(isA<ClientError>()),
      );
      expect(calls, 1);
    });

    test('refuses other hosts, traversal and oversized bodies', () async {
      final c = client(
        (_) async => http.Response.bytes(List.filled(10, 0), 200),
      );
      for (final bad in [
        'https://evil.example/x.sup',
        '//evil.example/x.sup',
        '/Videos/%2e%2e/%2e%2e/admin',
        r'/Videos\x',
      ]) {
        await expectLater(
          c.requestBytes(bad),
          throwsA(isA<ClientError>()),
          reason: bad,
        );
      }
      await expectLater(
        c.requestBytes('/Videos/a.sup', maxBytes: 5),
        throwsA(isA<ClientError>()),
      );
    });
  });
}
