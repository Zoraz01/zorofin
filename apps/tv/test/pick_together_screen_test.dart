import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/catalog.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/pick_together.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/ui/screens/pick_together_screen.dart';

Map<String, Object?> view({
  String status = 'lobby',
  int version = 2,
  bool host = true,
  List<Map<String, Object?>> members = const [],
  List<Map<String, Object?>> matches = const [],
  int round = 1,
}) => {
  'schemaVersion': 1,
  'id': 'b' * 32,
  'code': 'ABCDEF',
  'kind': 'movie',
  'status': status,
  'round': round,
  'version': version,
  'host': host,
  'seat': 'me1',
  'members': members,
  'matches': matches,
};

(JellyfinCatalog, List<http.Request>) fixture(
  Object? Function(http.Request) answer, {
  String viewerId = 'viewer',
}) {
  final requests = <http.Request>[];
  final server = ServerAddress.parse('https://example.test');
  final client = JellyfinClient(
    server: server,
    identity: const ClientIdentity(deviceId: 'fixture', deviceName: 'Test'),
    session: Session(
      server: server,
      viewer: Viewer(id: viewerId, name: 'Viewer'),
      token: 'fixture-token',
      deviceId: 'fixture',
    ),
    httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode(answer(request)), 200);
    }),
  );
  return (JellyfinCatalog(client), requests);
}

void main() {
  test(
    'a phone joins by code, gets the deck once per round and swipes',
    () async {
      final (catalog, requests) = fixture((r) {
        final path = r.url.path;
        if (path.endsWith('/join')) return view(host: false);
        if (path.endsWith('/deck')) {
          return {
            'version': 3,
            'status': 'swiping',
            'round': 1,
            'cards': [
              {'itemId': 'aa11', 'title': 'Fargo'},
              {'itemId': 'bb22', 'title': 'Ali'},
            ],
          };
        }
        if (path.endsWith('/swipes')) {
          return {
            'version': 4,
            'match': {'itemId': 'aa11', 'title': 'Fargo', 'likes': 2, 'of': 2},
          };
        }
        return view(host: false, status: 'swiping', version: 3);
      });
      final pick = PickTogetherController(catalog.client, display: false);
      await pick.join('abc def');
      expect(jsonDecode(requests.last.body), {'code': 'ABCDEF'});
      expect(pick.session!.host, isFalse);
      await pick.refresh();
      expect(pick.deck.map((c) => c.title), ['Fargo', 'Ali']);
      await pick.refresh();
      expect(requests.where((r) => r.url.path.endsWith('/deck')).length, 1);
      final match = await pick.swipe(pick.deck.first, like: true);
      expect(match?.title, 'Fargo');
      expect(jsonDecode(requests.last.body), {
        'itemId': 'aa11',
        'choice': 'like',
        'seat': 'me1',
      });
      expect(pick.deck.map((c) => c.title), ['Ali']);
      expect(
        pick.celebrate(match),
        isNull,
        reason: 'a match moment plays once',
      );
    },
  );

  test('a TV hosts as a display and never asks for a deck', () async {
    final (catalog, requests) = fixture(
      (r) => r.url.path.endsWith('/sessions')
          ? view()
          : view(status: 'swiping', version: 3),
    );
    final pick = PickTogetherController(catalog.client, display: true);
    await pick.create('series');
    expect(jsonDecode(requests.single.body), {
      'kind': 'series',
      'display': true,
    });
    await pick.refresh();
    expect(requests.any((r) => r.url.path.endsWith('/deck')), isFalse);
    expect(requests.last.url.queryParameters, {'seat': 'me1', 'since': '2'});
  });

  test('a 404 ends the group on this device', () async {
    final server = ServerAddress.parse('https://example.test');
    final client = JellyfinClient(
      server: server,
      identity: const ClientIdentity(deviceId: 'f', deviceName: 'Test'),
      session: Session(
        server: server,
        viewer: Viewer(id: 'v', name: 'V'),
        token: 'fixture-token',
        deviceId: 'f',
      ),
      httpClient: MockClient(
        (r) async => r.url.path.endsWith('/sessions')
            ? http.Response(jsonEncode(view()), 200)
            : http.Response('{"error":"not_found"}', 404),
      ),
    );
    final pick = PickTogetherController(client, display: true);
    await pick.create('movie');
    await pick.refresh();
    expect(pick.session, isNull);
    expect(pick.error, 'This session has ended.');
  });

  testWidgets('TV start, lobby code and Start waiting for two phones', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (catalog, _) = fixture(
      (r) => view(
        members: [
          {'seat': 'tv', 'name': 'TV', 'display': true, 'host': true},
          {'seat': 'p1', 'name': 'Alex'},
        ],
      ),
      viewerId: 'tv-viewer',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PickTogetherScreen(
          catalog: catalog,
          display: true,
          onOpen: (_) {},
          onPlay: (_) {},
        ),
      ),
    );
    expect(find.text('What are we watching?'), findsOneWidget);
    await tester.tap(find.text('Movies'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('ABC DEF'), findsOneWidget);
    expect(find.text('Joined · 1'), findsOneWidget);
    expect(
      find.text(
        'Start unlocks when two people have joined. The TV never swipes.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('phone results show matches with their tally', (tester) async {
    MediaItem? opened;
    final (catalog, _) = fixture(
      (r) => r.url.path.endsWith('/deck')
          ? {'version': 5, 'status': 'swiping', 'round': 1, 'cards': []}
          : view(
              status: 'swiping',
              version: 5,
              members: [
                {
                  'seat': 'me1',
                  'name': 'Alex',
                  'you': true,
                  'swiped': 20,
                  'total': 20,
                  'done': true,
                },
                {'seat': 'p2', 'name': 'Sam', 'swiped': 9, 'total': 20},
              ],
              matches: [
                {'itemId': 'aa11', 'title': 'Fargo', 'likes': 2, 'of': 2},
              ],
            ),
      viewerId: 'phone-viewer',
    );
    final pick = PickTogetherScreen.controllerFor(catalog, display: false);
    await pick.join('ABCDEF');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PickTogetherScreen(
            catalog: catalog,
            display: false,
            onOpen: (item) => opened = item,
            onPlay: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.text('You’re done. Waiting for everyone else…'),
      findsOneWidget,
    );
    expect(find.text('Matches · everyone liked'), findsOneWidget);
    expect(find.text('2 of 2'), findsOneWidget);
    await tester.tap(find.text('Fargo'));
    expect(opened?.id, 'aa11');
    await tester.pumpWidget(const SizedBox());
  });
}
