import 'package:zorofin_tv/core/errors.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/plugin_extras.dart';
import 'package:zorofin_tv/core/server_address.dart';

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

Map<String, dynamic> episode(String at, {bool premiere = false}) => {
  'kind': 'episode',
  'title': 'Severance',
  'subtitle': premiere
      ? 'S1:E1 · Good News About Hell'
      : 'S2:E4 · Woe’s Hollow',
  'at': at,
  'allDay': false,
  'release': 'airing',
  'hasFile': false,
  'premiere': premiere,
  'posterUrl': 'https://artworks.thetvdb.com/banners/poster.jpg',
  'network': 'Apple TV+',
};

void main() {
  test('the manifest turns each extra on only when the server says so', () {
    expect(PluginExtras.fromJson({'calendar': true}).calendar, isTrue);
    expect(PluginExtras.fromJson({'calendar': true}).catchUp, isFalse);
    expect(PluginExtras.fromJson({'catchUp': 'yes'}).catchUp, isFalse);
    expect(PluginExtras.fromJson(null).any, isFalse);
  });

  test('a missing plugin route means no extras', () async {
    final c = client((request) async {
      expect(request.url.path, '/jellyfin/Zorofin/Extras');
      return http.Response('', 404);
    });
    expect(await c.pluginExtras(), PluginExtras.none);
  });

  test('calendar events land on the viewer’s local day', () {
    final local = DateTime(2026, 11, 9, 21);
    final e = CalendarEvent.fromJson(episode(local.toUtc().toIso8601String()))!;
    expect(e.day, '2026-11-09');
    expect(e.badge, 'New episode');
    final movie = CalendarEvent.fromJson({
      'kind': 'movie',
      'title': 'Wicked: For Good',
      'subtitle': '2025',
      'at': '2026-11-21',
      'allDay': true,
      'release': 'cinema',
      'posterUrl': 'http://insecure.example/poster.jpg',
      'itemId': 'abc',
    })!;
    expect(movie.day, '2026-11-21');
    expect(movie.badge, 'In cinemas');
    expect(movie.posterUrl, isNull, reason: 'https only');
    expect(movie.itemId, 'abc');
    expect(
      CalendarEvent.fromJson({'kind': 'other', 'title': 'x', 'at': 'y'}),
      isNull,
    );
  });

  test('premieres say which kind', () {
    final at = DateTime(2026, 11, 9, 21).toUtc().toIso8601String();
    expect(
      CalendarEvent.fromJson(episode(at, premiere: true))!.badge,
      'Series premiere',
    );
    final season = {
      ...episode(at, premiere: true),
      'subtitle': 'S3:E1 · Hello',
    };
    expect(CalendarEvent.fromJson(season)!.badge, 'Season premiere');
  });

  test('the agenda groups from today on and filters shows or movies', () {
    final now = DateTime(2026, 11, 9, 12);
    final events = [
      CalendarEvent.fromJson(
        episode(DateTime(2026, 11, 8, 21).toUtc().toIso8601String()),
      )!,
      CalendarEvent.fromJson(
        episode(DateTime(2026, 11, 10, 21).toUtc().toIso8601String()),
      )!,
      CalendarEvent.fromJson({
        'kind': 'movie',
        'title': 'Film',
        'at': '2026-11-10',
        'allDay': true,
        'release': 'digital',
      })!,
      CalendarEvent.fromJson(
        episode(DateTime(2026, 11, 9, 20).toUtc().toIso8601String()),
      )!,
    ];
    final all = CalendarAgenda.group(events, CalendarFilter.all, now);
    expect(all.map((d) => d.day), ['2026-11-09', '2026-11-10']);
    expect(all[1].events.map((e) => e.kind), ['episode', 'movie']);
    expect(
      CalendarAgenda.group(events, CalendarFilter.movies, now).single.day,
      '2026-11-10',
    );
    expect(
      CalendarAgenda.label('2026-11-09', now),
      'Today · Monday, November 9',
    );
    expect(
      CalendarAgenda.label('2026-11-10', now),
      'Tomorrow · Tuesday, November 10',
    );
    expect(CalendarAgenda.label('2026-11-12', now), 'Thursday, November 12');
  });

  test('the calendar reads four weeks from the plugin', () async {
    final c = client((request) async {
      expect(request.url.path, '/jellyfin/Zorofin/Arr/Calendar');
      expect(request.url.queryParameters['start'], '2026-11-09');
      expect(request.url.queryParameters['days'], '28');
      return http.Response(
        jsonEncode({
          'start': '2026-11-09',
          'days': 28,
          'items': [
            episode('2026-11-10T02:00:00Z'),
            {'bad': true},
          ],
        }),
        200,
        // Titles carry curly quotes.
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    expect(await c.calendar(DateTime(2026, 11, 9)), hasLength(1));
  });

  test(
    'Catch Up skips stay per account, retain Jellyfin liked/watched titles and exclude only local skips',
    () {
      final store = <String, List<String>>{};
      CatchUpSkips skips(String viewer) => CatchUpSkips(
        read: (k) => store[k],
        write: (k, v) => store[k] = v,
        server: 'srv',
        viewerId: viewer,
      );
      skips('u1').add('a');
      expect(skips('u1').contains('a'), isTrue);
      expect(skips('u2').contains('a'), isFalse);
      final queue = CatchUpQueue([
        MediaItem(id: 'a', name: 'Skipped'),
        MediaItem(id: 'b', name: 'Liked', userData: UserData(likes: true)),
        MediaItem(id: 'seen', name: 'Seen', userData: UserData(played: true)),
        MediaItem(id: 'c', name: 'New'),
      ], skips('u1'));
      expect(queue.current?.id, 'b');
      expect(queue.position, '1 of 3');
      queue.next();
      queue.next();
      queue.next();
      expect(queue.done, isTrue);
      queue.restore(0);
      expect(queue.current?.id, 'b');
      skips('u1').add('other');
      skips('u1').remove('a');
      expect(skips('u1').contains('other'), isTrue);
      expect(skips('u1').contains('a'), isFalse);
      skips('u1').clear();
      expect(skips('u1').contains('a'), isFalse);
    },
  );

  test(
    'Catch Up taste reads are separate from legacy rating telemetry',
    () async {
      final seen = <String>[];
      final c = client((request) async {
        seen.add('${request.method} ${request.url.path}');
        if (request.url.path.endsWith('/Items')) {
          expect(request.url.queryParameters.containsKey('IsPlayed'), isFalse);
          expect(request.url.queryParameters['IncludeItemTypes'], 'Movie');
          return http.Response(
            jsonEncode({'Items': [], 'TotalRecordCount': 0}),
            200,
          );
        }
        if (request.url.path.endsWith('/taste')) {
          return http.Response(
            jsonEncode({'schemaVersion': 1, 'likedItemIds': []}),
            200,
          );
        }
        if (request.url.path.endsWith('/Log')) {
          expect(jsonDecode(request.body), {'itemId': 'x', 'action': 'later'});
        }
        if (request.url.path.endsWith('/Rating')) {
          expect(request.url.queryParameters, {
            'userId': 'u1',
            'likes': 'true',
          });
        }
        return http.Response('', 204);
      });
      await c.catchUpTitles(CatchUpKind.movies);
      await c.logCatchUp('x', CatchUpAction.later);
      await c.likeItem('x');
      expect(seen, [
        'GET /jellyfin/Users/u1/Items',
        'GET /jellyfin/Zorofin/Companion/recommendations/taste',
        'POST /jellyfin/Zorofin/Extras/CatchUp/Log',
        'POST /jellyfin/UserItems/x/Rating',
      ]);
    },
  );
  test(
    'recommendation Like writes only taste and requires an acknowledged item',
    () async {
      final requests = <http.Request>[];
      var acknowledged = false;
      final c = client((request) async {
        requests.add(request);
        expect(request.method, 'POST');
        expect(
          request.url.path,
          '/jellyfin/Zorofin/Companion/recommendations/taste',
        );
        expect(jsonDecode(request.body), {'itemId': 'AA-BB', 'action': 'like'});
        return http.Response(
          jsonEncode({
            'schemaVersion': 1,
            'likedItemIds': acknowledged ? ['aabb'] : [],
          }),
          200,
        );
      });
      await expectLater(
        c.likeForRecommendations('AA-BB'),
        throwsA(isA<ClientError>()),
      );
      acknowledged = true;
      await c.likeForRecommendations('AA-BB');
      expect(requests.length, 2);
      expect(
        requests.any(
          (r) =>
              r.url.path.contains('Played') ||
              r.url.path.contains('Rating') ||
              r.url.path.contains('Favorite'),
        ),
        false,
      );
    },
  );
}
