import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/library_browse.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/requests.dart';
import 'package:zorofin_tv/core/server_address.dart';

void main() {
  test(
    'library options reach server before paging and defaults stay unchanged',
    () async {
      final sent = <http.Request>[];
      final server = ServerAddress.parse('https://example.test/base');
      final client = JellyfinClient(
        server: server,
        identity: const ClientIdentity(
          deviceId: 'fixture',
          deviceName: 'Fixture',
        ),
        session: Session(
          server: server,
          viewer: Viewer(id: 'viewer', name: 'Fixture'),
          token: 'fixture',
          deviceId: 'fixture',
        ),
        httpClient: MockClient((r) async {
          sent.add(r);
          return http.Response(
            jsonEncode({'Items': [], 'TotalRecordCount': 0}),
            200,
          );
        }),
      );
      await client.items(
        type: 'Series',
        start: 60,
        favorites: true,
        options: const LibraryBrowseOptions(
          sort: LibrarySort.year,
          genre: 'Science Fiction',
          unwatched: true,
        ),
      );
      final query = sent.last.url.queryParameters;
      expect(query['sortBy'], 'ProductionYear,SortName');
      expect(query['genres'], 'Science Fiction');
      expect(query['startIndex'], '60');
      expect(query['filters'], 'IsFavorite,IsUnplayed');
      expect(query['includeItemTypes'], 'Series');
      await client.items(type: 'Movie');
      expect(sent.last.url.queryParameters['sortBy'], 'DateCreated,SortName');
      expect(sent.last.url.queryParameters.containsKey('genres'), isFalse);
      expect(sent.last.url.queryParameters.containsKey('filters'), isFalse);
      await client.items(search: 'North', type: 'Series', start: 30);
      expect(sent.last.url.queryParameters['searchTerm'], 'North');
      expect(sent.last.url.queryParameters['includeItemTypes'], 'Series');
      expect(sent.last.url.queryParameters['startIndex'], '30');
    },
  );
  test('download zero, unknown, import and pending approval stay truthful', () {
    const zero = RequestDownload(
      tmdbId: 10,
      source: 'sonarr',
      status: 'downloading',
      progress: 0,
    );
    expect(zero.label, 'Downloading · 0%');
    expect(const RequestDownload(status: 'downloading').label, 'Downloading');
    expect(
      const RequestDownload(status: 'completed', progress: 100).label,
      'Adding to library',
    );
    const approved = RequestActivityItem(
      id: 1,
      type: 'tv',
      tmdbId: 10,
      requestStatus: 2,
      mediaStatus: 'Processing',
    );
    const pending = RequestActivityItem(
      id: 2,
      type: 'tv',
      tmdbId: 10,
      requestStatus: 1,
      mediaStatus: 'Pending',
    );
    final queue = RequestQueue([zero]);
    expect(approved.statusLabel, 'Processing');
    expect(queue.download(approved), same(zero));
    expect(pending.statusLabel, 'Pending approval');
    expect(queue.download(pending), isNull);
  });
}
