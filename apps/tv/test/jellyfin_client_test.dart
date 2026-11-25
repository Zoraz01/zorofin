import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/catalog.dart';
import 'package:zorofin_tv/core/errors.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/playback.dart';
import 'package:zorofin_tv/core/server_address.dart';

const identity = ClientIdentity(deviceId: 'dev-1', deviceName: 'Test "TV"\n');

void main() {
  final server = ServerAddress.parse('https://example.com/jf');
  final session = Session(
    server: server,
    viewer: Viewer(id: 'u1', name: 'Zo'),
    token: 'tok',
    deviceId: 'dev-1',
  );

  JellyfinClient client(MockClientHandler handler, {Session? signedIn}) =>
      JellyfinClient(
        server: server,
        identity: identity,
        session: signedIn,
        httpClient: MockClient(handler),
      );

  test('authorization header strips quotes and control characters', () {
    expect(
      identity.authorization('tok'),
      'MediaBrowser Client="Zorofin", Device="Test TV", DeviceId="dev-1", Version="1.5.0", Token="tok"',
    );
  });

  test(
    'login posts credentials and builds a session for this server',
    () async {
      late http.Request sent;
      final c = client((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'AccessToken': 'abc',
            'User': {'Id': 'u1', 'Name': 'Zo'},
          }),
          200,
        );
      });
      final result = await c.login('zo', 'pw');
      expect(
        sent.url.toString(),
        'https://example.com/jf/Users/AuthenticateByName',
      );
      expect(jsonDecode(sent.body), {'Username': 'zo', 'Pw': 'pw'});
      expect(sent.headers['Authorization'], isNot(contains('Token=')));
      expect(result.token, 'abc');
      expect(result.server, server);
    },
  );

  test('maps HTTP failures to viewer-facing errors', () async {
    final unauthorized = client(
      (_) async => http.Response('', 401),
      signedIn: session,
    );
    await expectLater(
      unauthorized.resume(),
      throwsA(
        isA<ClientError>().having(
          (e) => e.kind,
          'kind',
          ClientErrorKind.unauthorized,
        ),
      ),
    );
    final down = client((_) async => http.Response('', 503), signedIn: session);
    await expectLater(
      down.resume(),
      throwsA(const ClientError(ClientErrorKind.unavailable, 503)),
    );
    final offline = client(
      (_) async => throw http.ClientException('offline'),
      signedIn: session,
    );
    await expectLater(
      offline.resume(),
      throwsA(const ClientError(ClientErrorKind.network)),
    );
  });

  test('refuses authenticated calls without a session', () async {
    final c = client((_) async => http.Response('{}', 200));
    await expectLater(
      c.resume(),
      throwsA(const ClientError(ClientErrorKind.missingSession)),
    );
  });

  test('system info requires a server id', () async {
    final c = client(
      (_) async => http.Response(jsonEncode({'ServerName': 'x'}), 200),
    );
    await expectLater(
      c.systemInfo(),
      throwsA(const ClientError(ClientErrorKind.invalidResponse)),
    );
  });

  test('home keeps working rows when one row fails', () async {
    final c = client((request) async {
      if (request.url.path.endsWith('/Resume')) return http.Response('', 500);
      if (request.url.path.endsWith('/NextUp')) {
        return http.Response(jsonEncode({'Items': []}), 200);
      }
      final type = request.url.queryParameters['includeItemTypes'];
      return http.Response(
        jsonEncode({
          'Items': [
            {'Id': '${type}1', 'Name': 'A $type', 'Type': type},
          ],
        }),
        200,
      );
    }, signedIn: session);
    final rows = await JellyfinCatalog(c).home();
    expect(rows.map((r) => r.title), [
      'Recently Added Movies',
      'Recently Added Shows',
    ]);
  });

  test(
    'catalog fallback includes the next season when Resume is unavailable',
    () async {
      final c = client((request) async {
        if (request.url.path.endsWith('/Resume')) return http.Response('', 503);
        return http.Response(
          jsonEncode({
            'Items': request.url.path.endsWith('/NextUp')
                ? [
                    {
                      'Id': 'premiere',
                      'Name': 'Premiere',
                      'Type': 'Episode',
                      'SeriesId': 'show',
                      'ParentIndexNumber': 4,
                      'IndexNumber': 1,
                    },
                  ]
                : [],
          }),
          200,
        );
      }, signedIn: session);
      final rows = await JellyfinCatalog(c).home();
      expect(rows, hasLength(1));
      expect(rows.single.title, 'Continue Watching');
      expect(rows.single.items.single.id, 'premiere');
      expect(rows.single.items.single.resumeTicks, 0);
    },
  );

  for (final status in [401, 403]) {
    test('catalog does not hide a Next Up session failure ($status)', () async {
      final c = client(
        (request) async => request.url.path.endsWith('/NextUp')
            ? http.Response('', status)
            : http.Response(
                jsonEncode({
                  'Items': [
                    {'Id': 'movie', 'Name': 'Movie', 'Type': 'Movie'},
                  ],
                }),
                200,
              ),
        signedIn: session,
      );
      await expectLater(
        JellyfinCatalog(c).home(),
        throwsA(
          ClientError(
            status == 401
                ? ClientErrorKind.unauthorized
                : ClientErrorKind.forbidden,
          ),
        ),
      );
    });
  }

  test('home surfaces an expired session', () async {
    final c = client((_) async => http.Response('', 401), signedIn: session);
    await expectLater(
      JellyfinCatalog(c).home(),
      throwsA(const ClientError(ClientErrorKind.unauthorized)),
    );
  });

  test('remux negotiation keeps selected source and authenticated HLS', () async {
    final requests = <http.Request>[];
    final c = client((request) async {
      requests.add(request);
      return http.Response(
        jsonEncode({
          'PlaySessionId': 'play',
          'MediaSources': [
            {
              'Id': 'chosen-source',
              'Container': 'mkv',
              'SupportsDirectPlay': false,
              'SupportsDirectStream': false,
              'SupportsTranscoding': true,
              'TranscodingSubProtocol': 'hls',
              'TranscodingUrl':
                  '/jf/Videos/movie/master.m3u8?api_key=old&TranscodeReasons=ContainerNotSupported',
            },
          ],
        }),
        200,
      );
    }, signedIn: session);
    final plan = await c.preparePlayback(
      MediaItem(
        id: 'movie',
        name: 'Fixture',
        type: 'Movie',
        mediaSources: [MediaSource(id: 'chosen-source')],
      ),
      PlaybackOptions(bitrate: 8000000),
    );
    expect(requests, hasLength(1));
    final request = requests.single;
    expect(request.method, 'POST');
    expect(request.url.path, '/jf/Items/movie/PlaybackInfo');
    expect(request.headers['Authorization'], contains('Token="tok"'));
    expect(request.url.queryParameters, isNot(contains('ApiKey')));
    final body = jsonDecode(request.body) as Map;
    expect(body['MediaSourceId'], 'chosen-source');
    expect(body['EnableDirectStream'], true);
    expect(body['EnableDirectPlay'], true);
    expect(body['AllowVideoStreamCopy'], true);
    expect(body['MaxStreamingBitrate'], 8000000);
    final conversions = body['DeviceProfile']['TranscodingProfiles'] as List;
    expect(conversions, isNotEmpty);
    expect(conversions.every((p) => p['Protocol'] == 'hls'), true);
    // The response's DirectStream=false must not block its valid HLS plan.
    expect(plan.sourceId, 'chosen-source');
    expect(plan.method, 'Transcode');
    expect(plan.url.path, '/jf/Videos/movie/master.m3u8');
    expect(plan.url.host, 'example.com');
    expect(plan.url.queryParameters['ApiKey'], 'tok');
    expect(plan.url.queryParameters.containsKey('api_key'), false);
  });

  test(
    'stopping a transcoded stream ends its encode, direct play does not',
    () async {
      final requests = <http.Request>[];
      final c = client((request) async {
        requests.add(request);
        return http.Response('', 204);
      }, signedIn: session);
      PlaybackPlan plan(MediaSource source) => PlaybackPlan.make(
        PlaybackInfo(playSessionId: 'ps', mediaSources: [source]),
        itemId: 'item1',
        client: c,
        options: PlaybackOptions(),
      );
      await c.stopEncoding(
        plan(
          MediaSource(
            id: 'src',
            supportsTranscoding: true,
            transcodingUrl: '/jf/videos/item1/master.m3u8?x=1',
            transcodingSubProtocol: 'hls',
          ),
        ),
      );
      expect(requests, hasLength(1));
      expect(requests.single.method, 'DELETE');
      expect(requests.single.url.path, endsWith('/Videos/ActiveEncodings'));
      expect(requests.single.url.queryParameters['playSessionId'], 'ps');
      expect(requests.single.url.queryParameters['deviceId'], isNotEmpty);
      requests.clear();
      await c.stopEncoding(
        plan(MediaSource(id: 'src', supportsDirectPlay: true)),
      );
      expect(requests, isEmpty);
    },
  );

  group('download permission', () {
    Future<bool> ask(String body, {int status = 200}) => client(
      (_) async => http.Response(body, status),
      signedIn: session,
    ).contentDownloadPermission();
    final me = session.viewer.id;

    test('only an explicit allow for this viewer grants downloads', () async {
      expect(
        await ask(
          jsonEncode({
            'Id': me,
            'Policy': {'EnableContentDownloading': true},
          }),
        ),
        isTrue,
      );
      for (final policy in [
        {'EnableContentDownloading': false},
        <String, Object?>{},
        {'IsAdministrator': true},
        {'EnableContentDownloading': null},
        null,
      ]) {
        expect(
          await ask(jsonEncode({'Id': me, 'Policy': ?policy})),
          isFalse,
          reason: '$policy',
        );
      }
    });

    test('another viewer or an HTTP failure never grants downloads', () async {
      await expectLater(
        ask(
          jsonEncode({
            'Id': 'someone-else',
            'Policy': {'EnableContentDownloading': true},
          }),
        ),
        throwsA(isA<ClientError>()),
      );
      for (final status in [401, 403, 503]) {
        await expectLater(
          ask('{}', status: status),
          throwsA(isA<ClientError>()),
          reason: '$status',
        );
      }
    });
  });

  group('playback plan', () {
    final signedIn = client(
      (_) async => http.Response('{}', 200),
      signedIn: session,
    );
    final options = PlaybackOptions(startTicks: 50);

    test('direct play uses a static stream with the token', () {
      final plan = PlaybackPlan.make(
        PlaybackInfo(
          playSessionId: 'ps',
          mediaSources: [MediaSource(id: 'src', supportsDirectPlay: true)],
        ),
        itemId: 'item1',
        client: signedIn,
        options: options,
      );
      expect(plan.method, 'DirectPlay');
      expect(plan.url.path, '/jf/Videos/item1/stream');
      expect(plan.url.queryParameters['ApiKey'], 'tok');
      expect(plan.url.queryParameters['static'], 'true');
      expect(plan.report(positionTicks: -5, paused: true)['PositionTicks'], 0);
    });

    test('falls back to same-server HLS transcoding', () {
      final plan = PlaybackPlan.make(
        PlaybackInfo(
          playSessionId: 'ps',
          mediaSources: [
            MediaSource(
              id: 'src',
              supportsTranscoding: true,
              transcodingUrl: '/jf/videos/item1/master.m3u8?x=1',
              transcodingSubProtocol: 'hls',
            ),
          ],
        ),
        itemId: 'item1',
        client: signedIn,
        options: options,
      );
      expect(plan.method, 'Transcode');
      expect(plan.url.host, 'example.com');
    });

    test('accepts the HLS playlist negotiated for a remux-only viewer', () {
      final info = PlaybackInfo.fromJson({
        'PlaySessionId': 'play',
        'MediaSources': [
          {
            'Id': 'source',
            'SupportsDirectStream': true,
            'SupportsTranscoding': false,
            'TranscodingUrl':
                '/jf/Videos/movie/master.m3u8?TranscodeReasons=ContainerNotSupported',
          },
        ],
      });
      final plan = PlaybackPlan.make(
        info,
        itemId: 'movie',
        client: signedIn,
        options: options,
      );
      expect(plan.url.path, '/jf/Videos/movie/master.m3u8');
    });

    for (final supportsTranscoding in [true, false]) {
      test(
        'remux permission still rejects HTTP conversion ($supportsTranscoding)',
        () {
          final info = PlaybackInfo.fromJson({
            'PlaySessionId': 'play',
            'MediaSources': [
              {
                'Id': 'source',
                'SupportsDirectPlay': false,
                'SupportsDirectStream': true,
                'SupportsTranscoding': supportsTranscoding,
                'TranscodingSubProtocol': 'http',
                'TranscodingUrl':
                    '/jf/Videos/movie/stream?TranscodeReasons=ContainerNotSupported',
              },
            ],
          });
          expect(
            () => PlaybackPlan.make(
              info,
              itemId: 'movie',
              client: signedIn,
              options: options,
            ),
            throwsA(const ClientError(ClientErrorKind.unsupportedPlayback)),
          );
        },
      );
    }

    test('rejects errors, missing sources and off-server streams', () {
      for (final info in [
        PlaybackInfo(
          playSessionId: 'ps',
          errorCode: 'NoCompatibleStream',
          mediaSources: [MediaSource(id: 's', supportsDirectPlay: true)],
        ),
        PlaybackInfo(playSessionId: 'ps'),
        PlaybackInfo(
          mediaSources: [MediaSource(id: 's', supportsDirectPlay: true)],
        ),
      ]) {
        expect(
          () => PlaybackPlan.make(
            info,
            itemId: 'i',
            client: signedIn,
            options: options,
          ),
          throwsA(const ClientError(ClientErrorKind.unsupportedPlayback)),
        );
      }
      expect(
        () => PlaybackPlan.make(
          PlaybackInfo(
            playSessionId: 'ps',
            mediaSources: [
              MediaSource(
                id: 's',
                supportsTranscoding: true,
                transcodingUrl: 'https://evil.example/a.m3u8',
              ),
            ],
          ),
          itemId: 'i',
          client: signedIn,
          options: options,
        ),
        throwsA(const ClientError(ClientErrorKind.unsafeUrl)),
      );
    });
  });

  test('media item helpers', () {
    final item = MediaItem.fromJson({
      'Id': 'e1',
      'Name': 'Pilot',
      'Type': 'Episode',
      'SeriesName': 'Show',
      'IndexNumber': 2,
      'ParentIndexNumber': 1,
      'RunTimeTicks': 36000000000,
      'UserData': {'PlaybackPositionTicks': 9000000000},
    });
    expect(item.displayTitle, 'Show');
    expect(item.episodeLabel, 'S1 E2 · Pilot');
    expect(item.durationLabel, '1h 0m');
    expect(item.progress, closeTo(0.25, 0.001));
  });
}
