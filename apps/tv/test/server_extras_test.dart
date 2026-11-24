import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/core/catalog.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/request_routes.dart';
import 'package:zorofin_tv/core/requests.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/core/server_extras.dart';
import 'package:zorofin_tv/extras_state.dart';

const identity = ClientIdentity(deviceId: 'dev-1', deviceName: 'Test TV');

void main() {
  final server = ServerAddress.parse('https://example.com/jf');
  final session = Session(
    server: server,
    viewer: Viewer(id: 'u1', name: 'Zo'),
    token: 'tok',
    deviceId: 'dev-1',
  );

  JellyfinClient client(MockClientHandler handler) => JellyfinClient(
    server: server,
    identity: identity,
    session: session,
    httpClient: MockClient(handler),
  );

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status);

  Map<String, dynamic> manifest(List<String> enabled) => {
    'schemaVersion': 1,
    'features': {
      for (final name in enabled) name: {'version': 1, 'enabled': true},
      'homeRows': {'version': 2, 'enabled': true},
    },
  };

  group('feature discovery', () {
    test('reads the Zorofin manifest with the extension token', () async {
      final seen = <http.Request>[];
      final features = await client((r) async {
        seen.add(r);
        return json(manifest(['support', 'requests']));
      }).discoverFeatures();
      expect(seen.single.url.path, '/jf/Zorofin/Capabilities');
      expect(seen.single.headers['X-Jellyfin-Token'], 'tok');
      expect(features.support, isTrue);
      expect(features.requests, isTrue);
      // Only version 1 counts.
      expect(features.homeRows, isFalse);
      expect(features.hasNotifications, isTrue);
    });

    test('only a missing route falls back to the support adapter', () async {
      final paths = <String>[];
      final features = await client((r) async {
        paths.add(r.url.path);
        return r.url.path.endsWith('Capabilities')
            ? http.Response('', 404)
            : json(manifest(['notifications']));
      }).discoverFeatures();
      expect(paths, ['/jf/Zorofin/Capabilities', '/jf/support/capabilities']);
      expect(features.notifications, isTrue);

      await expectLater(
        client((r) async => http.Response('', 403)).discoverFeatures(),
        throwsA(anything),
      );
    });

    test('plugin Requests (version 2) uses the Zorofin routes', () async {
      final paths = <String>[];
      final c = JellyfinClient(
        server: ServerAddress.parse('https://plugin-v2.example/jf'),
        identity: identity,
        httpClient: MockClient((r) async {
          paths.add(r.url.path);
          if (r.url.path.endsWith('Capabilities')) {
            return json({
              'schemaVersion': 1,
              'features': {
                'requests': {'version': 2, 'enabled': true},
              },
            });
          }
          return json({'active': true, 'userFound': true});
        }),
      );
      final signedIn = c.withSession(
        Session(
          server: c.server,
          viewer: Viewer(id: 'u2', name: 'Zo'),
          token: 'tok',
          deviceId: 'dev-1',
        ),
      );
      expect((await signedIn.discoverFeatures()).requests, isTrue);
      expect(RequestRoutes.of(signedIn), RequestRoutes.zorofin);
      expect(await signedIn.requestAccessAvailable(), isTrue);
      expect(paths.last, '/jf/Zorofin/Requests/user-status');
    });

    test('version 1 keeps Jellyfin Enhanced; others turn Requests off', () {
      expect(RequestRoutes.fromVersion(1), RequestRoutes.enhanced);
      expect(RequestRoutes.fromVersion(3), isNull);
      for (final feature in [
        {'version': 3, 'enabled': true},
        {'version': 2, 'enabled': false},
      ]) {
        final features = ServerFeatures.fromManifest({
          'schemaVersion': 1,
          'features': {'requests': feature},
        });
        expect(features.requests, isFalse);
      }
    });

    test('every Requests route has a plugin path', () {
      const z = RequestRoutes.zorofin;
      expect(
        [
          z.userStatus,
          z.quota,
          z.seasonSettings,
          z.submit,
          z.search,
          z.discover(['movies', 'upcoming']),
          z.title(RequestKind.tv, 20),
          z.activity,
          z.queue,
        ].map((p) => p.join('/')),
        [
          'Zorofin/Requests/user-status',
          'Zorofin/Requests/quota',
          'Zorofin/Requests/settings/partial-requests',
          'Zorofin/Requests/request',
          'Zorofin/Requests/search',
          'Zorofin/Requests/discover/movies/upcoming',
          'Zorofin/Requests/tv/20',
          'Zorofin/Requests/activity',
          'Zorofin/Requests/queue',
        ],
      );
      expect(RequestRoutes.enhanced.queue, [
        'JellyfinEnhanced',
        'arr',
        'queue',
      ]);
    });

    test('an extension 401 does not sign the viewer out', () async {
      var expired = false;
      final c = JellyfinClient(
        server: server,
        identity: identity,
        httpClient: MockClient((r) async => http.Response('', 401)),
      ).withSession(session, onUnauthorized: () => expired = true);
      await expectLater(c.discoverFeatures(), throwsA(anything));
      expect(expired, isFalse);
    });
  });

  group('support', () {
    final report = SupportReport(
      issueType: 'Other',
      description: '  Audio drifts  ',
    );

    test('a ticket needs 202 and a valid reference', () async {
      late http.Request sent;
      final id = await client((r) async {
        sent = r;
        return json({'ticketId': 'Tabc123'}, 202);
      }).submitSupport(report);
      expect(id, 'Tabc123');
      expect(jsonDecode(sent.body)['description'], 'Audio drifts');

      await expectLater(
        client(
          (r) async => json({'ticketId': 'Tabc123'}),
        ).submitSupport(report),
        throwsA(
          isA<SupportException>().having(
            (e) => e.error,
            'error',
            SupportError.outcomeUnknown,
          ),
        ),
      );
      await expectLater(
        client((r) async => http.Response('', 429)).submitSupport(report),
        throwsA(
          isA<SupportException>().having(
            (e) => e.error,
            'error',
            SupportError.rejected,
          ),
        ),
      );
    });

    test('a new reply on the same ticket is a new notification', () {
      const a = SupportReply(
        id: 'Tabc123',
        status: 'open',
        issueType: 'Other',
        message: 'First',
        updatedAt: '2026-10-29T10:00:00Z',
      );
      const b = SupportReply(
        id: 'Tabc123',
        status: 'open',
        issueType: 'Other',
        message: 'Second',
        updatedAt: '2026-10-29T10:00:00Z',
      );
      expect(a.notificationKey, isNot(b.notificationKey));
    });
  });

  group('Live TV capacity', () {
    Map<String, dynamic> status(String state, {bool different = false}) => {
      'limit': 1,
      'state': state,
      'sameChannel': false,
      'differentChannel': different,
      'ownStream': false,
    };

    test('only a different busy channel blocks playback', () async {
      await expectLater(
        client(
          (r) async => json(status('busy', different: true)),
        ).checkLiveTvCapacity('ch1', enabled: true),
        throwsA(isA<LiveTvCapacityException>()),
      );
      await client(
        (r) async => json(status('available')),
      ).checkLiveTvCapacity('ch1', enabled: true);
      // A failing optional service keeps ordinary playback.
      await client(
        (r) async => http.Response('', 500),
      ).checkLiveTvCapacity('ch1', enabled: true);
    });

    test('the policy names the shared limit', () {
      final one = LiveTvAvailability.fromJson(status('available'));
      expect(one.policy, contains('one channel at a time'));
      expect(
        () => LiveTvAvailability.fromJson({
          ...status('available'),
          'differentChannel': true,
        }),
        throwsA(anything),
      );
    });
  });

  group('notification history', () {
    test('the first availability snapshot is already seen', () async {
      SharedPreferences.setMockInitialValues({});
      final store = NotificationHistoryStore(
        await SharedPreferences.getInstance(),
        server: 'https://example.com/jf',
        viewerId: 'u1',
      );
      const old = RequestAvailabilityNotice(
        id: 1,
        kind: RequestKind.movie,
        titleId: 10,
        title: 'Old',
      );
      const fresh = RequestAvailabilityNotice(
        id: 2,
        kind: RequestKind.movie,
        titleId: 11,
        title: 'Fresh',
      );
      var state = await store.receiveRequests([old]);
      expect(state.readRequestIds, {1});
      state = await store.receiveRequests([fresh]);
      expect(state.readRequestIds, {1});
      expect(state.requests.map((n) => n.title), ['Fresh', 'Old']);
      expect(await store.seeRequest(2), {1, 2});
    });

    test('the inbox counts unread replies and badges', () async {
      SharedPreferences.setMockInitialValues({});
      final c = client((r) async {
        if (r.url.path.endsWith('Capabilities')) {
          return json(manifest(['notifications', 'support']));
        }
        if (r.url.path.endsWith('support/notifications')) {
          return json({
            'notifications': [
              {
                'id': 'Tabc123',
                'status': 'open',
                'issueType': 'Other',
                'message': 'We restarted the tuner.',
                'updatedAt': '2026-10-29T10:00:00Z',
              },
            ],
          });
        }
        return http.Response('', 404);
      });
      final extras = ExtrasState(
        catalog: JellyfinCatalog(c),
        storage: await SharedPreferences.getInstance(),
      );
      addTearDown(extras.dispose);
      await extras.checkFeatures();
      await extras.refreshNotifications();
      expect(extras.unreadCount, 1);
      await extras.markReplyRead(extras.replies.single);
      expect(extras.unreadCount, 0);
      expect(extras.hiddenReplies.single.id, 'Tabc123');
    });
  });
}
