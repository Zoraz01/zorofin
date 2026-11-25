import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/playback.dart';
import 'package:zorofin_tv/core/playback_capabilities.dart';
import 'package:zorofin_tv/core/server_address.dart';

void main() {
  for (final invalid in [false, true]) {
    test(
      'live tuner is opened explicitly and released ${invalid ? "after a rejected plan" : "even when stop reporting fails"}',
      () async {
        final server = ServerAddress.parse('https://example.test/jf');
        final calls = <String>[];
        final client = JellyfinClient(
          server: server,
          identity: const ClientIdentity(deviceId: 'test', deviceName: 'TV'),
          session: Session(
            server: server,
            token: 'token',
            viewer: Viewer(id: 'viewer', name: 'Viewer'),
            deviceId: 'test',
          ),
          httpClient: MockClient((r) async {
            calls.add('${r.method} ${r.url.path}');
            Object result = {};
            if (r.url.path.endsWith('/PlaybackInfo')) {
              result = {
                'PlaySessionId': 'play',
                'MediaSources': [
                  {
                    'Id': 'source',
                    'RequiresOpening': true,
                    'OpenToken': 'opaque-open-token',
                  },
                ],
              };
              if (r.method == 'POST') {
                final body = jsonDecode(r.body);
                expect(body['AutoOpenLiveStream'], false);
                expect(body['EnableDirectStream'], true);
                expect(
                  (body['DeviceProfile']['TranscodingProfiles'] as List)
                      .first['Container'],
                  'mp4',
                );
              }
            } else if (r.url.path.endsWith('/Open')) {
              final body = jsonDecode(r.body);
              expect(body['OpenToken'], 'opaque-open-token');
              expect(body['EnableDirectStream'], true);
              expect(body['ItemId'], 'channel');
              // Jellyfin filters these live sources to TS profiles before negotiation.
              final compatible =
                  (body['DeviceProfile']['TranscodingProfiles'] as List)
                      .where((p) => p['Container'] == 'ts')
                      .toList();
              expect(compatible, hasLength(1));
              expect(compatible.single['Protocol'], 'hls');
              expect(compatible.single['VideoCodec'], 'h264');
              expect(compatible.single['AudioCodec'], 'aac');
              result = {
                'MediaSource': {
                  'Id': 'source',
                  'LiveStreamId': 'live',
                  'RequiresClosing': true,
                  'SupportsTranscoding': true,
                  'TranscodingSubProtocol': 'hls',
                  'TranscodingUrl': invalid
                      ? 'https://untrusted.test/stream.m3u8'
                      : '/jf/Videos/channel/master.m3u8',
                },
              };
            } else if (r.url.path.endsWith('/Stopped')) {
              return http.Response('', 503);
            }
            return http.Response(jsonEncode(result), 200);
          }),
        );
        final prepare = client.preparePlayback(
          MediaItem(id: 'channel', name: 'Channel', type: 'TvChannel'),
          PlaybackOptions(
            subtitleIndex: -1,
            capabilities: PlaybackCapabilities.fromJson({
              'platform': 'lg',
              'packaged': true,
              'sdkVersion': '10.0.0',
              'uhd': true,
            }),
          ),
        );
        if (invalid) {
          await expectLater(prepare, throwsA(anything));
        } else {
          final plan = await prepare;
          expect(plan.liveStreamId, 'live');
          expect(plan.method, 'Transcode');
          await expectLater(
            client.reportPlayback(
              'stop',
              plan.report(positionTicks: 0, paused: true),
            ),
            throwsA(anything),
          );
        }
        expect(calls.where((c) => c.endsWith('/Open')).length, 1);
        expect(calls.where((c) => c.endsWith('/Close')).length, 1);
      },
    );
  }
}
