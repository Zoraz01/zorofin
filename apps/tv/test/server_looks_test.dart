import 'dart:convert';
import 'package:flutter/painting.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/preferences.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/core/server_looks.dart';
import 'package:zorofin_tv/ui/theme.dart';

final server = ServerAddress.parse('https://media.example/jellyfin');

JellyfinClient client(MockClientHandler handler) => JellyfinClient(
  server: server,
  identity: const ClientIdentity(deviceId: 'tv-1', deviceName: 'TV'),
  session: Session(
    server: server,
    viewer: Viewer(id: 'u1', name: 'Viewer'),
    token: 'tok',
    deviceId: 'tv-1',
  ),
  httpClient: MockClient(handler),
);

// The companion's looks.json (server/zorofin-companion/test/web-ui.test.js).
Map<String, dynamic> looks({
  String colors = 'ocean',
  String accent = '#3d9cff',
  String cardSize = 'large',
  bool enforced = true,
}) => {
  'version': 1,
  'colors': colors,
  'accent': accent,
  'cardSize': cardSize,
  'logo': 'zorofin',
  'enforced': enforced,
};

void main() {
  tearDown(() => serverAccent.value = null);

  test('looks map to the apps accent and poster size steps', () {
    final ocean = ServerLooks.fromJson(looks())!;
    expect(ocean.accent, const Color(0xFF3D9CFF));
    expect(ocean.posterScale, 1.2);
    expect(ocean.enforced, isTrue);
    expect(ServerLooks.fromJson(looks(cardSize: 'compact'))!.posterScale, 0.85);
    expect(ServerLooks.fromJson(looks(cardSize: 'huge'))!.posterScale, 1.0);
    // Zorofin green keeps the apps' own green.
    expect(
      ServerLooks.fromJson(looks(colors: 'zorofin', accent: '#42d779'))!.accent,
      isNull,
    );
    expect(
      ServerLooks.fromJson(looks(colors: 'custom', accent: '#42D779'))!.accent,
      isNull,
    );
    expect(ServerLooks.fromJson(looks(accent: 'blue'))!.accent, isNull);
    expect(ServerLooks.fromJson({...looks(), 'version': 2}), isNull);
    expect(ServerLooks.fromJson(null), isNull);
    // Older looks without the switch: one look for every viewer.
    expect(
      ServerLooks.fromJson({...looks()}..remove('enforced'))!.enforced,
      isTrue,
    );
    expect(ServerLooks.fromJson(looks(enforced: false))!.enforced, isFalse);
  });

  test('a dark accent is lightened so dark button labels stay readable', () {
    final navy = ServerLooks.fromJson(
      looks(colors: 'custom', accent: '#102a6b'),
    )!.accent!;
    expect(navy.computeLuminance(), greaterThanOrEqualTo(0.22));
    final hsl = HSLColor.fromColor(navy);
    expect(
      hsl.hue,
      closeTo(HSLColor.fromColor(const Color(0xFF102A6B)).hue, 1),
    );
    // Bright presets are kept as they are.
    expect(readableAccent(const Color(0xFFF5A524)), const Color(0xFFF5A524));
  });

  test(
    'the client reads looks.json and treats a missing file as none',
    () async {
      final on = client((request) async {
        expect(request.url.path, '/jellyfin/Zorofin/Web/ui/looks.json');
        return http.Response(jsonEncode(looks()), 200);
      });
      expect((await on.serverLooks())!.cardSize, 'large');
      final missing = client((_) async => http.Response('', 404));
      expect(await missing.serverLooks(), isNull);
    },
  );

  test(
    'server card size wins when enforced and is a default otherwise',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = Preferences(await SharedPreferences.getInstance());
      prefs.use('server|u1');
      expect(prefs.value.posterScale, 1.0);

      await prefs.useLooks('server|u1', ServerLooks.fromJson(looks()));
      expect(prefs.value.posterScale, 1.2);
      expect(prefs.cardSizeFromServer, isTrue);
      expect(Zoro.jade, const Color(0xFF3D9CFF));
      expect(Zoro.play, const Color(0xFF3D9CFF));

      // Enforced: the viewer's own saved size doesn't change what they see.
      await prefs.save(const DevicePreferences(posterScale: 0.85));
      expect(prefs.value.posterScale, 1.2);

      // A default only: the viewer's saved choice wins.
      await prefs.useLooks(
        'server|u1',
        ServerLooks.fromJson(looks(enforced: false)),
      );
      expect(prefs.cardSizeFromServer, isFalse);
      expect(prefs.value.posterScale, 0.85);
      await prefs.reset();
      expect(prefs.value.posterScale, 1.2);

      // Looks for another account never land on this one.
      await prefs.useLooks(
        'other|u2',
        ServerLooks.fromJson(looks(cardSize: 'compact')),
      );
      expect(prefs.value.posterScale, 1.2);
    },
  );

  test('looks are kept per account for the next start', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = await SharedPreferences.getInstance();
    final prefs = Preferences(storage)..use('server|u1');
    await prefs.useLooks('server|u1', ServerLooks.fromJson(looks()));

    final next = Preferences(storage)..use('server|u1');
    expect(next.value.posterScale, 1.2);
    expect(Zoro.jade, const Color(0xFF3D9CFF));

    next.use('other|u2');
    expect(next.value.posterScale, 1.0);
    expect(Zoro.jade, Zoro.defaultAccent);

    next.use('server|u1');
    await next.useLooks('server|u1', null);
    expect(Zoro.jade, Zoro.defaultAccent);
    expect(Preferences(storage).looks, isNull);
    await next.forget('server|u1');
  });
}
