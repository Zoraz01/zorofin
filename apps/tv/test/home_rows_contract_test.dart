import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/core/catalog.dart';
import 'package:zorofin_tv/core/errors.dart';
import 'package:zorofin_tv/core/home.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/core/server_extras.dart';
import 'package:zorofin_tv/extras_state.dart';
import 'package:zorofin_tv/ui/screens/home_screen.dart';

Map<String, Object?> feed([List<Object> rows = const []]) => {
  'schemaVersion': 1,
  'generatedAt': '2026-11-05T12:00:00Z',
  'preferences': {
    'hiddenRows': [],
    'teams': ['Boston Celtics'],
    'minutes': 90,
    'theme': 'automatic',
  },
  'rows': rows,
};
Map<String, Object?> row(String id, {String state = 'ready', String? item}) => {
  'id': id,
  'title': 'Server $id',
  'description': '',
  'state': state,
  'cards': [
    if (item != null)
      {
        'id': item,
        'item': {'Id': item, 'Name': item, 'Type': 'Movie'},
        'subtitle': '',
        'badges': [],
      },
  ],
};
http.Response json(Object? value, [int status = 200]) =>
    http.Response(jsonEncode(value), status);
JellyfinClient client(MockClientHandler handler) {
  final server = ServerAddress.parse('https://example.test/jellyfin');
  return JellyfinClient(
    server: server,
    identity: const ClientIdentity(deviceId: 'test', deviceName: 'TV'),
    session: Session(
      server: server,
      viewer: Viewer(id: 'viewer', name: 'Viewer'),
      token: 'viewer-token',
      deviceId: 'test',
    ),
    httpClient: MockClient(handler),
  );
}

http.Response local(http.Request r) {
  if (r.url.path.contains('/DisplayPreferences/')) {
    return json({
      'CustomPrefs': {'zorofinTeams': '["Boston Celtics"]'},
    });
  }
  if (r.url.queryParameters['includeItemTypes'] == 'Movie') {
    return json({
      'Items': [
        {
          'Id': 'local',
          'Name': 'Local short film',
          'Type': 'Movie',
          'RunTimeTicks': 36000000000,
          'LocationType': 'FileSystem',
          'UserData': {'Played': false},
        },
      ],
      'TotalRecordCount': 1,
    });
  }
  return json({'Items': [], 'TotalRecordCount': 0});
}

void main() {
  test(
    'only Home rows v1/v2 are supported; Sections cannot select app routes',
    () {
      for (final version in [0, 1, 2, 3]) {
        final f = ServerFeatures.fromManifest({
          'schemaVersion': 1,
          'features': {
            'homeRows': {'version': version, 'enabled': true},
            'homeSections': {'version': 1, 'enabled': true},
            'support': {'version': 2, 'enabled': true},
            'requests': {'version': 2, 'enabled': true},
          },
        });
        expect(f.homeRowsContract, HomeRowsContract.fromVersion(version));
        expect(f.support, false);
        expect(f.requests, true);
      }
      for (final features in [
        <String, Object>{},
        {
          'homeSections': {'version': 1, 'enabled': true},
        },
        {
          'homeRows': {'version': 2, 'enabled': false},
        },
      ]) {
        expect(
          ServerFeatures.fromManifest({
            'schemaVersion': 1,
            'features': features,
          }).homeRows,
          false,
        );
      }
      expect(
        const ServerFeatures(homeRows: true).homeRowsContract,
        HomeRowsContract.legacy,
      );
      expect(
        const ServerFeatures(homeRowsContract: HomeRowsContract.legacy),
        isNot(const ServerFeatures(homeRowsContract: HomeRowsContract.plugin)),
      );
    },
  );

  for (final contract in HomeRowsContract.values) {
    test(
      'schema 1 uses the authenticated base-path route for $contract',
      () async {
        final requests = <http.Request>[];
        final rows = await client((r) async {
          requests.add(r);
          return json(feed([row('popular', item: 'film')]));
        }).homeFeed(contract: contract);
        expect(rows.single.cards.single.item.id, 'film');
        expect(
          requests.single.url.path,
          '/jellyfin/${contract.path.join('/')}',
        );
        expect(
          requests.single.url.queryParameters,
          contract == HomeRowsContract.plugin
              ? {'fresh': 'true', 'taste': 'true'}
              : isEmpty,
        );
        expect(requests.single.headers['X-Jellyfin-Token'], 'viewer-token');
        expect(
          requests.single.headers['Authorization'],
          contains('viewer-token'),
        );
        expect(requests.single.followRedirects, false);
      },
    );
  }

  test(
    'v2 owns omitted, empty and unavailable rows without local refill',
    () async {
      for (final rows in [
        <Object>[],
        [row('showcase', state: 'empty'), row('sports', state: 'unavailable')],
        [row('popular', item: 'film')],
      ]) {
        final requests = <http.Request>[];
        final loaded = await client((r) async {
          requests.add(r);
          return json(feed(rows));
        }).loadHomeRows(contract: HomeRowsContract.plugin);
        expect(loaded.rows.length, rows.length);
        expect(loaded.serverError, isNull);
        expect(loaded.teams, ['Boston Celtics']);
        expect(
          requests.length,
          1,
          reason: 'No client scan or preference migration on plugin success',
        );
        expect(requests.single.url.path, '/jellyfin/Zorofin/Home/Rows');
      }
    },
  );

  test('legacy merge preserves local rows and has one shelf per ID', () async {
    final loaded = await client(
      (r) async => r.url.path.endsWith('/support/home/rows')
          ? json(
              feed([
                row('short-movies', item: 'server'),
                row('popular', item: 'popular'),
              ]),
            )
          : local(r),
    ).loadHomeRows(contract: HomeRowsContract.legacy);
    expect(
      loaded.rows
          .singleWhere((r) => r.id == 'short-movies')
          .cards
          .single
          .item
          .id,
      'local',
    );
    expect(
      loaded.rows.singleWhere((r) => r.id == 'popular').cards.single.item.id,
      'popular',
    );
    expect(loaded.rows.map((r) => r.id).toSet().length, loaded.rows.length);
  });

  for (final status in [401, 403, 404, 503]) {
    test(
      'v2 $status falls back without legacy probes, then recovers',
      () async {
        var failing = true;
        final requests = <http.Request>[];
        final c = client((r) async {
          requests.add(r);
          if (r.url.path.endsWith('/Zorofin/Home/Rows')) {
            return failing
                ? json({}, status)
                : json(feed([row('popular', item: 'recovered')]));
          }
          return local(r);
        });
        final fallback = await c.loadHomeRows(
          contract: HomeRowsContract.plugin,
        );
        expect(fallback.serverError, isNotNull);
        expect(
          fallback.rows
              .singleWhere((r) => r.id == 'short-movies')
              .cards
              .single
              .item
              .id,
          'local',
        );
        expect(
          requests.any(
            (r) =>
                r.url.path.contains('/support/') ||
                r.url.path.contains('/Sections'),
          ),
          false,
        );
        failing = false;
        final recovered = await c.loadHomeRows(
          contract: HomeRowsContract.plugin,
        );
        expect(recovered.serverError, null);
        expect(recovered.rows.single.cards.single.item.id, 'recovered');
      },
    );
  }

  test('transport timeout falls back and does not cache the failure', () async {
    var failing = true;
    final c = client((r) async {
      if (r.url.path.endsWith('/Zorofin/Home/Rows')) {
        if (failing) throw TimeoutException('fixture timeout');
        return json(feed());
      }
      return local(r);
    });
    expect(
      (await c.loadHomeRows(contract: HomeRowsContract.plugin)).serverError,
      isNotNull,
    );
    failing = false;
    expect(
      (await c.loadHomeRows(contract: HomeRowsContract.plugin)).rows,
      isEmpty,
    );
  });

  test(
    'unknown schema, duplicate IDs and malformed feeds reject safely',
    () async {
      for (final invalid in [
        <String, Object>{'schemaVersion': 2, 'rows': []},
        {
          ...feed(),
          'rows': [row('popular'), row('popular')],
        },
        {
          ...feed(),
          'rows': [row('web-only-row')],
        },
        {
          ...feed(),
          'preferences': {'teams': 'invalid'},
        },
        {
          ...feed(),
          'rows': [row('sports', state: 'invented')],
        },
        {
          ...feed(),
          'rows': [
            {'id': 'popular', 'cards': 'invalid'},
          ],
        },
      ]) {
        await expectLater(
          client(
            (_) async => json(invalid),
          ).homeFeed(contract: HomeRowsContract.plugin),
          throwsA(const ClientError(ClientErrorKind.invalidResponse)),
        );
      }
    },
  );

  test(
    'ordinary-server fallback and teams never probe optional routes',
    () async {
      final requests = <http.Request>[];
      final c = client((r) async {
        requests.add(r);
        return local(r);
      });
      final loaded = await c.loadHomeRows();
      expect(loaded.serverError, null);
      expect(loaded.rows.any((r) => r.id == 'short-movies'), true);
      expect(
        requests.any(
          (r) =>
              r.url.path.contains('/support/') ||
              r.url.path.contains('/Zorofin/'),
        ),
        false,
      );
      await c.saveHomeTeams(['New York Knicks']);
      final saved = requests.last;
      expect(saved.url.path, '/jellyfin/DisplayPreferences/zorofin-home');
      expect(saved.url.queryParameters, {
        'userId': 'viewer',
        'client': 'zorofin',
      });
      expect(
        jsonDecode(saved.body)['CustomPrefs']['zorofinTeams'],
        '["New York Knicks"]',
      );
    },
  );

  test(
    'parallel core authentication failures propagate once without losing handlers',
    () async {
      await expectLater(
        client((_) async => json({}, 401)).loadHomeRows(),
        throwsA(const ClientError(ClientErrorKind.unauthorized)),
      );
    },
  );

  testWidgets('late plugin rows cannot overwrite a changed Home contract', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final pending = Completer<http.Response>();
    final c = client((r) async {
      if (r.url.path.endsWith('/Zorofin/Home/Rows')) return pending.future;
      return local(r);
    });
    final catalog = JellyfinCatalog(c);
    final extras =
        ExtrasState(
            catalog: catalog,
            storage: await SharedPreferences.getInstance(),
          )
          ..features = const ServerFeatures(
            homeRowsContract: HomeRowsContract.plugin,
          );
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          catalog: catalog,
          extras: extras,
          onOpen: (_) {},
          onPlay:
              (
                _, {
                startTicks,
                audioIndex,
                subtitleIndex,
                burnSubtitles,
              }) async {},
          onAllChannels: () {},
        ),
      ),
    );
    await tester.pump();
    extras.features = const ServerFeatures();
    extras.homeChanged();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    pending.complete(json(feed([row('popular', item: 'old-account-film')])));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('old-account-film'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    extras.dispose();
  });
}
