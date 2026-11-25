import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/playback_reports.dart';
import 'package:zorofin_tv/core/preferences.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/core/server_extras.dart';

void main() {
  final server = ServerAddress.parse('https://example.com');
  late List<http.Request> sent;
  var status = 204;
  JellyfinClient client() => JellyfinClient(
    server: server,
    identity: const ClientIdentity(deviceId: 'd', deviceName: 'Den TV'),
    session: Session(
      server: server,
      viewer: Viewer(id: 'u', name: 'Viewer'),
      token: 'token',
      deviceId: 'd',
    ),
    httpClient: MockClient((request) async {
      sent.add(request);
      return http.Response('', status);
    }),
  );
  final episode = MediaItem(
    id: 'e1',
    name: 'Pilot',
    type: 'Episode',
    seriesName: 'Big Show',
  );

  setUp(() {
    sent = [];
    status = 204;
    PlaybackReporter.reset();
  });

  test('sends one problem to the viewer\'s own server', () async {
    final reporter = PlaybackReporter(
      client: client(),
      platform: 'Android TV',
      enabled: () => true,
    );
    await reporter.send(
      PlaybackProblem.startFailed,
      item: episode,
      method: playbackReportMethod('Transcode'),
      reason: 'x' * 400,
      startTook: const Duration(seconds: 12),
      position: const Duration(minutes: 3),
    );
    final request = sent.single;
    expect(request.method, 'POST');
    expect(
      request.url.toString(),
      'https://example.com/Zorofin/PlaybackReports',
    );
    final body = jsonDecode(request.body) as Map;
    expect(body['kind'], 'start_failed');
    expect(body['itemId'], 'e1');
    expect(body['title'], 'Big Show: Pilot');
    expect(body['platform'], 'Android TV');
    expect(body['appVersion'], '1.5.0');
    expect(body['device'], 'Den TV');
    expect(body['method'], 'transcode');
    expect((body['reason'] as String).length, 300);
    expect(body['startMs'], 12000);
    expect(body['positionSeconds'], 180);
  });

  test('sends nothing when the server or the viewer has it off', () async {
    var server = false, viewer = true;
    final reporter = PlaybackReporter(
      client: client(),
      platform: 'Android TV',
      enabled: () => server && viewer,
    );
    await reporter.send(PlaybackProblem.stalled);
    server = true;
    viewer = false;
    await reporter.send(PlaybackProblem.stalled);
    expect(sent, isEmpty);
    viewer = true;
    await reporter.send(PlaybackProblem.stalled);
    expect(sent, hasLength(1));
  });

  test(
    'goes quiet once the server stops collecting, and never throws',
    () async {
      final reporter = PlaybackReporter(
        client: client(),
        platform: 'Android TV',
        enabled: () => true,
      );
      status = 500;
      await reporter.send(PlaybackProblem.stopped);
      status = 404;
      await reporter.send(PlaybackProblem.stopped);
      status = 204;
      await reporter.send(PlaybackProblem.stopped);
      expect(sent, hasLength(2));
    },
  );

  test('a failure loop cannot flood the server', () async {
    final reporter = PlaybackReporter(
      client: client(),
      platform: 'Android TV',
      enabled: () => true,
    );
    for (var i = 0; i < PlaybackReporter.maxPerSession + 10; i++) {
      await reporter.send(PlaybackProblem.fallback);
    }
    expect(sent, hasLength(PlaybackReporter.maxPerSession));
  });

  test('slow starts and long buffering are reported; quick ones are not', () {
    fakeAsync((async) {
      final problems = PlayerProblems(
        PlaybackReporter(
          client: client(),
          platform: 'Android TV',
          enabled: () => true,
        ),
        now: () => DateTime(2026, 11, 24).add(async.elapsed),
      );
      problems.opening();
      async.elapse(const Duration(seconds: 2));
      problems.started(episode, 'direct');
      async.flushMicrotasks();
      expect(sent, isEmpty);

      problems.opening();
      async.elapse(const Duration(seconds: 11));
      problems.started(episode, 'transcode');
      async.flushMicrotasks();
      expect(jsonDecode(sent.single.body)['kind'], 'slow_start');
      expect(jsonDecode(sent.single.body)['startMs'], 11000);

      // A short buffer (a seek) is not a stall.
      problems.buffering(true, episode, 'direct', () => Duration.zero);
      async.elapse(const Duration(seconds: 4));
      problems.buffering(false, episode, 'direct', () => Duration.zero);
      async.elapse(const Duration(seconds: 20));
      expect(sent, hasLength(1));

      problems.buffering(
        true,
        episode,
        'direct',
        () => const Duration(minutes: 10),
      );
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(jsonDecode(sent.last.body)['kind'], 'stalled');
      expect(jsonDecode(sent.last.body)['positionSeconds'], 600);
      problems.dispose();
    });
  });

  test('the server switch and the viewer switch are read as expected', () {
    ServerFeatures features(Map<String, dynamic> list) =>
        ServerFeatures.fromManifest({'schemaVersion': 1, 'features': list});
    expect(features({}).playbackReports, isFalse);
    expect(
      features({
        'playbackReports': {'version': 1, 'enabled': true},
      }).playbackReports,
      isTrue,
    );
    expect(const DevicePreferences().sendPlaybackReports, isTrue);
    final off = const DevicePreferences().copyWith(sendPlaybackReports: false);
    expect(
      DevicePreferences.fromJson(off.toJson()).sendPlaybackReports,
      isFalse,
    );
  });
}
