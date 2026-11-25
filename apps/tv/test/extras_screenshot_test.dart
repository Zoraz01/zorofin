// Renders Calendar and Catch Up on TV and phone to PNG for review. Skipped
// unless ZOROFIN_SCREENSHOTS names an output folder:
//   ZOROFIN_SCREENSHOTS=/tmp/shots flutter test test/extras_screenshot_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/catalog.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/plugin_extras.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/ui/screens/calendar_screen.dart';
import 'package:zorofin_tv/ui/screens/catch_up_screen.dart';
import 'package:zorofin_tv/ui/screens/settings_screen.dart';
import 'package:zorofin_tv/ui/theme.dart';

final _out = Platform.environment['ZOROFIN_SCREENSHOTS'];

Future<void> _fonts() async {
  final inter = FontLoader('Inter')
    ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
  await inter.load();
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ?? '/opt/sdk/flutter';
  final icons = File(
    '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  final loader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(await icons.readAsBytes())));
  await loader.load();
}

final _now = DateTime(2026, 11, 9, 15);

String _at(int day, int hour) =>
    DateTime(2026, 11, day, hour).toUtc().toIso8601String();

final _calendar = {
  'start': '2026-11-09',
  'days': 28,
  'items': [
    {
      'kind': 'episode',
      'title': 'Sample Detective',
      'subtitle': 'S2:E6 · The Lighthouse',
      'at': _at(9, 21),
      'release': 'airing',
      'network': 'Demo Network',
      'itemId': 'show-1',
    },
    {
      'kind': 'episode',
      'title': 'Open Kitchen',
      'subtitle': 'S1:E1 · First Service',
      'at': _at(9, 22),
      'release': 'airing',
      'premiere': true,
      'network': 'Demo Network',
    },
    {
      'kind': 'movie',
      'title': 'The Long Road Home',
      'subtitle': '2026',
      'at': '2026-11-10',
      'allDay': true,
      'release': 'digital',
      'hasFile': true,
      'network': 'Sample Studio',
      'itemId': 'movie-1',
    },
    {
      'kind': 'episode',
      'title': 'Night Market',
      'subtitle': 'S4:E1 · Back Again',
      'at': _at(12, 20),
      'release': 'airing',
      'premiere': true,
      'network': 'Demo Network',
    },
  ],
};

final _titles = {
  'Items': [
    {
      'Id': 'm1',
      'Name': 'Big Buck Bunny',
      'Type': 'Movie',
      'ProductionYear': 2008,
      'OfficialRating': 'G',
      'CommunityRating': 6.4,
      'Overview':
          'A large and lovable rabbit deals with three tiny bullies, led by a flying squirrel, who are determined to squelch his happiness.',
    },
    for (var i = 0; i < 11; i++)
      {'Id': 'x$i', 'Name': 'Title $i', 'Type': 'Movie', 'Overview': '…'},
  ],
  'TotalRecordCount': 12,
};

Catalog _catalog() {
  final server = ServerAddress.parse('https://demo.example');
  final client = JellyfinClient(
    server: server,
    identity: const ClientIdentity(deviceId: 'shots', deviceName: 'Shots'),
    session: Session(
      server: server,
      viewer: Viewer(id: 'u1', name: 'Viewer'),
      token: 'tok',
      deviceId: 'shots',
    ),
    httpClient: MockClient((request) async {
      final body = request.url.path.contains('Calendar') ? _calendar : _titles;
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
  return JellyfinCatalog(client, serverName: 'Demo');
}

CatchUpSkips _skips() => CatchUpSkips(
  read: (_) => null,
  write: (_, _) {},
  server: 'demo',
  viewerId: 'u1',
);

Future<void> _shot(
  WidgetTester tester,
  Widget page,
  Size size,
  double ratio,
  String name, {
  bool compact = false,
}) async {
  await tester.runAsync(_fonts);
  tester.view.physicalSize = size * ratio;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: Zoro.theme(),
      home: compact ? CompactSettings(child: page) : page,
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile(Uri.file('$_out/$name.png')),
  );
}

void main() {
  testWidgets('TV Calendar', (tester) async {
    await _shot(
      tester,
      CalendarScreen(catalog: _catalog(), onOpen: (_) {}, now: () => _now),
      const Size(1920, 1080),
      1,
      'tv-calendar',
    );
  }, skip: _out == null);
  testWidgets('phone Calendar', (tester) async {
    await _shot(
      tester,
      CalendarScreen(catalog: _catalog(), onOpen: (_) {}, now: () => _now),
      const Size(393, 852),
      3,
      'phone-calendar',
      compact: true,
    );
  }, skip: _out == null);
  testWidgets('TV Catch Up', (tester) async {
    await _shot(
      tester,
      CatchUpScreen(catalog: _catalog(), skips: _skips()),
      const Size(1920, 1080),
      1,
      'tv-catch-up',
    );
  }, skip: _out == null);
  testWidgets('phone Catch Up', (tester) async {
    await _shot(
      tester,
      CatchUpScreen(catalog: _catalog(), skips: _skips()),
      const Size(393, 852),
      3,
      'phone-catch-up',
      compact: true,
    );
  }, skip: _out == null);
}
