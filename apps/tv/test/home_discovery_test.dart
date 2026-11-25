import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/home.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/server_address.dart';

// Shared Flutter/DOM regressions; run when the owner resumes testing.
void main() {
  test(
    'Shared categories appear once, fill sparse pages, and lead with highly rated movies',
    () async {
      final server = ServerAddress.parse('https://example.test/jellyfin');
      final reads = <Uri>[];
      final transport = MockClient((request) async {
        reads.add(request.url);
        expect(
          request.headers['Authorization'],
          contains('Token="fixture-token"'),
        );
        final q = request.url.queryParameters;
        Map<String, Object?> page(
          List<Map<String, Object?>> items,
          int total,
        ) => {'Items': items, 'TotalRecordCount': total};
        Map<String, Object?> movie(String id) => {
          'Id': id,
          'Name': id,
          'Type': q['includeItemTypes'] == 'Series' ? 'Series' : 'Movie',
          'CommunityRating': 8,
        };
        Object result;
        if (request.url.path.endsWith('/Genres')) {
          expect(q['includeItemTypes'], 'Movie');
          result = page([
            {'Id': 'g1', 'Name': 'Action'},
            {'Id': 'g2', 'Name': 'Drama'},
          ], 2);
        } else if (q['isPlayed'] == 'true') {
          result = page([], 0);
        } else {
          final start = int.parse(q['startIndex'] ?? '0');
          if (q['genres'] == 'Drama') {
            result = page([for (var i = 0; i < 3; i++) movie('drama-$i')], 3);
          } else if (q['genres'] == 'Action') {
            result = page([
              for (var i = start; i < (start == 0 ? 24 : 30); i++)
                movie('action-$i'),
            ], 30);
          } else {
            final key =
                '${q['includeItemTypes']}-${q['minCommunityRating']}-${q['years']}-${q['sortBy']}';
            result = page([for (var i = 0; i < 24; i++) movie('$key-$i')], 72);
          }
        }
        return http.Response(jsonEncode(result), 200);
      });
      final client = JellyfinClient(
        server: server,
        identity: const ClientIdentity(deviceId: 'fixture', deviceName: 'Test'),
        session: Session(
          server: server,
          viewer: Viewer(id: 'viewer', name: 'Viewer'),
          token: 'fixture-token',
          deviceId: 'fixture',
        ),
        httpClient: transport,
      );
      final feed = DiscoveryFeed(seed: 3);
      final rows = <DiscoveryRow>[];
      for (var n = 0; n < 30 && feed.hasMore; n++) {
        rows.addAll(
          await feed.next(
            client,
            excluding: {for (var i = 0; i < 22; i++) 'action-$i'},
          ),
        );
      }
      expect(feed.hasMore, false);
      expect(rows.first.title, 'Highly rated movies');
      expect(rows.map((r) => r.title).toSet().length, rows.length);
      expect(
        rows.every((r) => r.items.length >= 6 && r.items.length <= 20),
        true,
      );
      // Genre rows may be movies or shows depending on the seed.
      expect(rows.where((r) => r.title.startsWith('Drama ')), isEmpty);
      expect(
        rows.singleWhere((r) => r.title.startsWith('Action ')).items.length,
        8,
      );
      expect(
        reads
            .where((u) => u.queryParameters['minCommunityRating'] == '7')
            .length,
        1,
      );
      final ids = rows.expand((r) => r.items.map((i) => i.id)).toList();
      expect(ids.toSet().length, ids.length);
      transport.close();
    },
  );
}
