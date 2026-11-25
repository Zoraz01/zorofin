import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/errors.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/core/server_extras.dart';

void main() {
  final payload = <String, dynamic>{
    'enabled': true,
    'id': 'notice-1',
    'title': 'Server update',
    'message': 'A message from your server administrator.',
  };
  JellyfinClient client(MockClientHandler handler) {
    final server = ServerAddress.parse('https://example.test/jellyfin');
    return JellyfinClient(
      server: server,
      identity: const ClientIdentity(deviceId: 'test', deviceName: 'Test'),
      session: Session(
        server: server,
        viewer: Viewer(id: 'user', name: 'Viewer'),
        token: 'fixture',
        deviceId: 'test',
      ),
      httpClient: MockClient(handler),
    );
  }

  test(
    'announcement has a distinct stable inbox identity, and edits become unread',
    () {
      final first = announcementMessage(payload)!;
      expect(first.isAnnouncement, true);
      expect(first.sourceLabel, 'Server announcement');
      expect(
        first.notificationKey,
        announcementMessage(payload)!.notificationKey,
      );
      expect(
        first.notificationKey,
        isNot(
          announcementMessage({
            ...payload,
            'title': 'Updated headline',
          })!.notificationKey,
        ),
      );
      expect(
        first.notificationKey,
        isNot(
          announcementMessage({
            ...payload,
            'message': 'Edited message',
          })!.notificationKey,
        ),
      );
    },
  );
  test(
    'disabled, scheduled and expired announcements stay out of the inbox',
    () {
      final now = DateTime.utc(2026, 11, 4);
      expect(announcementMessage({'enabled': false}), null);
      expect(
        announcementMessage({
          ...payload,
          'startAt': '2026-11-05T00:00:00Z',
        }, now: now),
        null,
      );
      expect(
        announcementMessage({
          ...payload,
          'endAt': '2026-11-04T00:00:00Z',
        }, now: now),
        null,
      );
      expect(
        () => announcementMessage({...payload, 'startAt': 'not-a-date'}),
        throwsA(isA<ClientError>()),
      );
    },
  );
  test(
    'optional feed stays on selected server base path with authentication; 404 is empty',
    () async {
      final c = client((r) async {
        expect(r.url.path, '/jellyfin/support/announcement/me');
        expect(r.headers['X-Jellyfin-Token'], 'fixture');
        return http.Response('', 404);
      });
      expect(await c.serverAnnouncements(), isEmpty);
    },
  );
  test(
    'one failed inbox source preserves its cached messages and does not hide the other',
    () async {
      final previous = announcementMessage(payload)!;
      final c = client(
        (r) async => r.url.path.endsWith('/announcement/me')
            ? http.Response('', 503)
            : http.Response(
                jsonEncode({
                  'notifications': [
                    {
                      'id': 'Tabcdef',
                      'status': 'Resolved',
                      'issueType': 'Playback',
                      'message': 'Support answer',
                      'updatedAt': '2026-11-04',
                    },
                  ],
                }),
                200,
              ),
      );
      final result = await c.inboxMessages();
      expect(result.partial, true);
      expect(
        result.keeping([previous]).map((x) => x.message),
        containsAll([previous.message, 'Support answer']),
      );
    },
  );
  test('denied feed does not fall back to an anonymous announcement', () async {
    var calls = 0;
    final c = client((r) async {
      calls++;
      return http.Response('', 401);
    });
    await expectLater(c.serverAnnouncements(), throwsA(isA<ClientError>()));
    expect(calls, 1);
  });
}
