import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/app_state.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/requests.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/core/session_store.dart';
import 'package:zorofin_tv/main.dart';

const identity = ClientIdentity(deviceId: 'dev-1', deviceName: 'Test TV');

void main() {
  final server = ServerAddress.parse('https://example.com/jf');
  final session = Session(
    server: server,
    viewer: Viewer(id: 'u1', name: 'Zo'),
    token: 'tok',
    deviceId: 'dev-1',
  );

  group('submission', () {
    late List<http.Request> posts;
    late http.Response Function() postResponse;
    late Map<String, dynamic> movie;

    JellyfinClient client() => JellyfinClient(
      server: server,
      identity: identity,
      session: session,
      httpClient: MockClient((r) async {
        final path = r.url.path;
        if (path.endsWith('user-status')) {
          return http.Response(
            jsonEncode({'active': true, 'userFound': true}),
            200,
          );
        }
        if (path.endsWith('quota')) {
          return http.Response(
            jsonEncode({
              'movie': {'limit': 5, 'used': 1, 'days': 7},
            }),
            200,
          );
        }
        if (path.endsWith('/movie/42')) {
          return http.Response(jsonEncode(movie), 200);
        }
        if (path.endsWith('/request') && r.method == 'POST') {
          posts.add(r);
          return postResponse();
        }
        return http.Response('', 404);
      }),
    );

    Future<RequestSubmissionService> service() async {
      SharedPreferences.setMockInitialValues({});
      final c = client();
      return RequestSubmissionService(
        c,
        RequestJournal(
          await SharedPreferences.getInstance(),
          server: server.url.toString(),
          viewerId: 'u1',
        ),
      );
    }

    setUp(() {
      posts = [];
      movie = {'id': 42, 'title': 'Northbound', 'mediaType': 'movie'};
      postResponse = () =>
          http.Response(jsonEncode({'id': 7, 'status': 1}), 201);
    });

    test('checks the title and limit, then posts once', () async {
      final s = await service();
      final receipt = await s.submit(
        RequestIntent(kind: RequestKind.movie, id: 42),
      );
      expect(receipt.id, 7);
      expect(jsonDecode(posts.single.body), {
        'mediaType': 'movie',
        'mediaId': 42,
        'is4k': false,
      });
      // The receipt blocks a duplicate on this device.
      await expectLater(
        s.submit(RequestIntent(kind: RequestKind.movie, id: 42)),
        throwsA(RequestFailure.alreadyRequested),
      );
      expect(posts, hasLength(1));
    });

    test('a lost response is unconfirmed and never resent', () async {
      postResponse = () => http.Response('', 502);
      final s = await service();
      await expectLater(
        s.submit(RequestIntent(kind: RequestKind.movie, id: 42)),
        throwsA(RequestFailure.unconfirmed),
      );
      await expectLater(
        s.submit(RequestIntent(kind: RequestKind.movie, id: 42)),
        throwsA(RequestFailure.unconfirmed),
      );
      expect(posts, hasLength(1));
      // Another attempt is allowed only after a minute has passed.
      await expectLater(
        s.allowAnotherAttempt(RequestKind.movie, 42),
        throwsA(RequestFailure.inProgress),
      );
    });

    test('an explicit refusal clears the receipt', () async {
      postResponse = () => http.Response('', 429);
      final s = await service();
      await expectLater(
        s.submit(RequestIntent(kind: RequestKind.movie, id: 42)),
        throwsA(RequestFailure.rejected),
      );
      expect(s.journal.entries(), isEmpty);
    });

    test('an available movie cannot be requested', () async {
      movie['mediaInfo'] = {'status': 5};
      final s = await service();
      await expectLater(
        s.submit(RequestIntent(kind: RequestKind.movie, id: 42)),
        throwsA(RequestFailure.alreadyRequested),
      );
      expect(posts, isEmpty);
    });
  });

  test('TV requests need every missing season unless partial is on', () {
    final title = RequestTitle(
      id: 9,
      mediaType: 'tv',
      seasons: const [
        RequestSeason(seasonNumber: 1, episodeCount: 8),
        RequestSeason(seasonNumber: 2, episodeCount: 8),
      ],
      mediaInfo: const RequestMediaInfo(
        status: 4,
        seasons: [RequestSeason(seasonNumber: 1, status: 5)],
      ),
    );
    const whole = RequestSeasonSettings(partialRequestsEnabled: false);
    RequestIntent intent(List<int> seasons) =>
        RequestIntent(kind: RequestKind.tv, id: 9, seasons: seasons);
    intent([2]).validate(title, settings: whole);
    expect(
      () => intent([1, 2]).validate(title, settings: whole),
      throwsA(RequestFailure.invalidSelection),
    );
    expect(
      () => intent([2]).validate(
        title,
        settings: whole,
        quota: const RequestQuota(tv: RequestQuotaLimit(limit: 3, used: 3)),
      ),
      throwsA(RequestFailure.quota),
    );
  });

  test('artwork comes only from TMDB', () {
    expect(
      RequestArtwork.path('/abc.jpg').toString(),
      'https://image.tmdb.org/t/p/w342/abc.jpg',
    );
    expect(RequestArtwork.path('../x.jpg'), isNull);
    expect(
      RequestArtwork.absolute('https://evil.example/t/p/w500/abc.jpg'),
      isNull,
    );
  });

  testWidgets('preview Requests browses and opens a title', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SessionStore.open(), deviceName: 'Test TV');
    await tester.pumpWidget(ZorofinTvApp(state: state));
    state.openPreview();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Requests'));
    await tester.pumpAndSettle();
    expect(find.text('Discover'), findsOneWidget);
    expect(find.text('My requests'), findsOneWidget);
    expect(find.text('Trending now'), findsOneWidget);

    await tester.tap(find.text('Northbound').first);
    await tester.pumpAndSettle();
    expect(find.text('Request movie'), findsOneWidget);
    expect(find.textContaining('fictional title'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Browse request categories'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coming soon'));
    await tester.pumpAndSettle();
    expect(find.text('Coming soon'), findsOneWidget);
    expect(find.text('Wild Blue'), findsWidgets);
  });
}
