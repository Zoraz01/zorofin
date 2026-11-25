import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/preview_catalog.dart';
import 'package:zorofin_tv/core/notification_reads.dart';
import 'package:zorofin_tv/core/requests.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/core/server_extras.dart';
import 'package:zorofin_tv/extras_state.dart';

JellyfinClient readsClient(MockClientHandler handler) {
  final server = ServerAddress.parse('https://media.example/base');
  return JellyfinClient(
    server: server,
    identity: const ClientIdentity(deviceId: 'fixture', deviceName: 'Fixture'),
    session: Session(
      server: server,
      viewer: Viewer(id: 'viewer', name: 'Viewer'),
      token: 'fixture-token',
      deviceId: 'fixture',
    ),
    httpClient: MockClient(handler),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'merged badges and histories follow account reads and fall back to local state',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final extras = ExtrasState(catalog: PreviewCatalog(), storage: prefs);
      extras.features = const ServerFeatures(
        notifications: true,
        requests: true,
        notificationReads: true,
      );
      extras.requestReadIds.clear();
      extras.seenReplyKeys.clear();
      extras.hiddenReplies = [];
      extras.requestNotices = [
        const RequestAvailabilityNotice(
          id: 1,
          kind: RequestKind.movie,
          titleId: 10,
          title: 'Sample',
        ),
      ];
      const reply = SupportReply(
        id: 'Tfixture',
        status: 'answered',
        issueType: 'Playback',
        message: 'First',
        updatedAt: '2026-11-09T20:00:00.000Z',
      );
      extras.replies = [reply];
      extras.accountNotificationReads = NotificationReadState(
        initialized: true,
        requests: {1},
        replies: {reply.accountReadKey},
      );
      expect(extras.unreadCount, 0);
      expect(extras.readReplies.single.id, 'Tfixture');
      extras.replies = [
        const SupportReply(
          id: 'Tfixture',
          status: 'answered',
          issueType: 'Playback',
          message: 'Later',
          updatedAt: '2026-11-09T20:00:00.001Z',
        ),
      ];
      expect(extras.unreadCount, 1);
      extras.accountNotificationReads = null;
      expect(extras.unreadCount, 2);
      extras.dispose();
    },
  );
  test(
    'account keys preserve the exact reply timestamp and distinguish a later reply',
    () async {
      final client = readsClient((r) async {
        expect(r.url.path, '/base/Zorofin/Notifications/Read');
        expect(r.headers['Authorization'], contains('fixture-token'));
        return http.Response(
          jsonEncode({
            'initialized': true,
            'requests': [41],
            'replies': ['Tfixture|2026-11-09T20:00:00.000Z'],
          }),
          200,
        );
      });
      final state = await client.notificationReads();
      const reply = SupportReply(
        id: 'Tfixture',
        status: 'answered',
        issueType: 'Playback',
        message: 'Read',
        updatedAt: '2026-11-09T20:00:00.000Z',
      );
      expect(state.initialized, isTrue);
      expect(state.requests, {41});
      expect(state.replies, contains(reply.accountReadKey));
      expect(
        state.replies,
        isNot(contains('Tfixture|2026-11-09T20:00:00.001Z')),
      );
    },
  );
  test(
    '500-item batches initialize only after the last successful write',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final client = readsClient((r) async {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        bodies.add(body);
        expect(
          (body['requests'] as List).length + (body['replies'] as List).length,
          lessThanOrEqualTo(500),
        );
        expect(body.containsKey('viewerId'), isFalse);
        return http.Response(
          jsonEncode({
            'initialized': body['initialize'],
            'requests': body['requests'],
            'replies': [
              for (final reply in body['replies'] as List)
                '${reply['id']}|${reply['updatedAt']}',
            ],
          }),
          200,
        );
      });
      const time = '2026-11-09T20:00:00.000+00:00';
      final result = await client.markNotificationReads(
        requests: List.generate(1001, (i) => i + 1),
        replies: [
          const SupportReply(
            id: 'Tfixture',
            status: 'answered',
            issueType: 'Playback',
            message: 'Read',
            updatedAt: time,
          ),
        ],
        initialize: true,
      );
      expect(bodies.length, 4);
      expect(bodies.map((b) => b['initialize']), [false, false, false, true]);
      expect(result.requests.length, 1001);
      expect(result.replies, {'Tfixture|$time'});
    },
  );
  test('initialized account skips local first-snapshot auto-read', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance(),
        history = NotificationHistoryStore(
          prefs,
          server: 'fixture',
          viewerId: 'viewer',
        );
    const notice = RequestAvailabilityNotice(
      id: 1,
      kind: RequestKind.movie,
      titleId: 10,
      title: 'Sample',
    );
    final state = await history.receiveRequests([
      notice,
    ], initializeSnapshot: false);
    expect(state.requestsInitialized, isTrue);
    expect(state.readRequestIds, isEmpty);
    expect(await history.seeRequest(1), {1});
    expect(
      NotificationHistoryStore(
        prefs,
        server: 'fixture',
        viewerId: 'other',
      ).load().readRequestIds,
      isEmpty,
    );
  });
}
