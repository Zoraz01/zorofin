import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/errors.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/playback.dart';
import 'package:zorofin_tv/core/server_address.dart';

JellyfinClient reportingClient(
  Future<http.Response> Function(http.Request) handle,
) {
  final server = ServerAddress.parse('https://example.test/jellyfin');
  return JellyfinClient(
    server: server,
    identity: const ClientIdentity(deviceId: 'fixture', deviceName: 'TV'),
    session: Session(
      server: server,
      token: 'fixture-token',
      viewer: Viewer(id: 'viewer', name: 'Viewer'),
      deviceId: 'fixture',
    ),
    httpClient: MockClient(handle),
  );
}

void main() {
  test(
    'stop retries preserve final position, account and base path; close runs once',
    () async {
      final requests = <http.Request>[];
      final payload = <String, Object?>{
        'ItemId': 'episode',
        'PlaySessionId': 'session',
        'PositionTicks': 3600000000,
        'IsPaused': true,
        'LiveStreamId': 'owned',
      };
      final client = reportingClient((r) async {
        requests.add(r);
        if (requests.length == 1) {
          payload['PositionTicks'] = 0;
          return http.Response('', 503);
        }
        return http.Response('', 204);
      });
      await client.reportPlayback('stop', payload);
      expect(requests.map((r) => r.url.path), [
        '/jellyfin/Sessions/Playing/Stopped',
        '/jellyfin/Sessions/Playing/Stopped',
        '/jellyfin/LiveStreams/Close',
      ]);
      expect(requests[0].body, requests[1].body);
      expect(jsonDecode(requests[1].body)['PositionTicks'], 3600000000);
      expect(
        requests.every(
          (r) =>
              r.url.host == 'example.test' &&
              r.headers['Authorization']!.contains('Token="fixture-token"'),
        ),
        isTrue,
      );
    },
  );
  test('three failed transient stop attempts propagate failure', () async {
    var attempts = 0;
    final client = reportingClient((r) async {
      attempts++;
      return http.Response('', 503);
    });
    await expectLater(
      client.reportPlayback('stop', {'ItemId': 'episode'}),
      throwsA(const ClientError(ClientErrorKind.unavailable, 503)),
    );
    expect(attempts, 3);
  });
  for (final status in [401, 403, 400, 500]) {
    test('stop does not retry HTTP $status', () async {
      var attempts = 0;
      final client = reportingClient((r) async {
        attempts++;
        return http.Response('', status);
      });
      await expectLater(
        client.reportPlayback('stop', {}),
        throwsA(isA<ClientError>()),
      );
      expect(attempts, 1);
    });
  }
  test(
    'progress is not retried and invalidated stop cannot start another attempt',
    () async {
      var attempts = 0, current = true;
      final client = reportingClient((r) async {
        attempts++;
        current = false;
        return http.Response('', 503);
      });
      await expectLater(
        client.reportPlayback('progress', {}),
        throwsA(isA<ClientError>()),
      );
      expect(attempts, 1);
      current = true;
      await expectLater(
        client.reportPlayback('stop', {}, isCurrent: () => current),
        throwsA(const ClientError(ClientErrorKind.missingSession)),
      );
      expect(attempts, 2);
    },
  );
}
