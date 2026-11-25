import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/live_tv_streams.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/core/server_extras.dart';
import 'package:zorofin_tv/ui/widgets/live_tv_notice.dart';

final espn = 'e' * 32;
final fox = 'f' * 32;

// The companion's response, including fields the apps ignore.
Map<String, dynamic> full() => {
  'version': 1,
  'state': 'full',
  'limit': 1,
  'inUse': 1,
  'free': 0,
  'otherUse': 0,
  'message': '1 of 1 Live TV stream in use: ESPN.',
  'streams': [
    {
      'channelId': espn,
      'channelName': 'ESPN',
      'channelNumber': '206',
      'programme': {
        'title': 'SportsCenter',
        'endsAt': '2026-11-07T16:00:00.0000000Z',
      },
      'startedAt': '2026-11-07T15:00:00.000Z',
      'viewers': 2,
      'paused': false,
      'yours': false,
    },
  ],
  'request': {
    'channelId': fox,
    'playing': false,
    'canStart': false,
    'reason': 'full',
    'message': '',
  },
};

void main() {
  final server = ServerAddress.parse('https://media.example/jellyfin');
  JellyfinClient client(MockClientHandler handler) => JellyfinClient(
    server: server,
    identity: const ClientIdentity(deviceId: 'tv-1', deviceName: 'Fire TV'),
    session: Session(
      server: server,
      viewer: Viewer(id: 'u1', name: 'Viewer'),
      token: 'tok',
      deviceId: 'tv-1',
    ),
    httpClient: MockClient(handler),
  );

  test('names the channel using the only stream', () {
    final status = LiveTvStreams.fromJson(full());
    expect(
      status.summary,
      '1 of 1 Live TV stream in use. Anyone can join a channel that’s already playing.',
    );
    expect(status.channelLine(fox), 'ESPN is using the only Live TV stream.');
    expect(
      status.channelLine(espn),
      'Already playing for 2 people. Joining doesn’t use another stream.',
    );
    final blocked = status.blocked(fox)!;
    expect(blocked.text, 'ESPN is using the only Live TV stream right now.');
    expect(
      blocked.hint,
      'You can watch ESPN instead, or try again when a stream is free.',
    );
    expect(blocked.join?.channel.isLive, isTrue);
    expect(status.blocked(espn), isNull);
    expect(
      status.streams.single.detail(DateTime.utc(2026, 11, 7, 15, 42)),
      '2 watching · 18 min left',
    );
  });

  test('free streams block nothing', () {
    final status = LiveTvStreams(
      limit: 2,
      inUse: 1,
      free: 1,
      streams: [LiveTvStream(channelId: espn, channelName: 'ESPN')],
    );
    expect(status.blocked(fox), isNull);
    expect(status.channelLine(fox), isNull);
    expect(
      status.summary,
      '1 of 2 Live TV streams in use. 1 stream free for another channel.',
    );
  });

  test('two full streams and another app are listed together', () {
    final status = LiveTvStreams(
      limit: 3,
      inUse: 3,
      free: 0,
      otherUse: 1,
      streams: [
        LiveTvStream(channelId: espn, channelName: 'ESPN'),
        const LiveTvStream(channelId: 'c', channelName: 'CNN'),
      ],
    );
    expect(
      status.blocked(fox)!.text,
      'ESPN, CNN and another app are using all 3 Live TV streams right now.',
    );
    expect(status.blocked(fox)!.join, isNull);
  });

  test('rejects an unknown version', () {
    expect(
      () => LiveTvStreams.fromJson({...full(), 'version': 2}),
      throwsA(anything),
    );
  });

  test('a conflict names the channel to watch instead', () async {
    final seen = <http.Request>[];
    final call = client((r) async {
      seen.add(r);
      return http.Response(jsonEncode(full()), 200);
    }).checkLiveTvCapacity(fox, enabled: false, streams: true);
    await expectLater(
      call,
      throwsA(
        isA<LiveTvStreamsConflict>().having(
          (c) => c.join?.name,
          'join',
          'ESPN',
        ),
      ),
    );
    expect(
      seen.single.url.path,
      '/jellyfin/Zorofin/Companion/liveTvStreams/status',
    );
    expect(seen.single.url.queryParameters['channelId'], fox);
  });

  test('a missing module leaves playback alone', () async {
    await client(
      (r) async => http.Response('', 404),
    ).checkLiveTvCapacity(fox, enabled: false, streams: true);
  });

  testWidgets('strip, line and dialog use the shared wording', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final status = LiveTvStreams.fromJson(full());
    MediaItem? joined;
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return Column(
                children: [
                  LiveTvStreamsStrip(status: status, onJoin: (i) => joined = i),
                  LiveTvStreamsLine(
                    status: status,
                    channelId: fox,
                    onJoin: (i) => joined = i,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    expect(find.text('SportsCenter'), findsOneWidget);
    expect(find.text('ESPN is using the only Live TV stream.'), findsOneWidget);
    await tester.tap(find.text('Join'));
    expect(joined?.id, espn);
    joined = null;
    await tester.tap(find.text('Watch ESPN'));
    expect(joined?.id, espn);

    final choice = showLiveTvConflict(
      context,
      LiveTvStreamsConflict(status.blocked(fox)!),
    );
    await tester.pumpAndSettle();
    expect(find.text('Live TV is in use'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    await tester.tap(find.text('Watch ESPN').last);
    await tester.pumpAndSettle();
    expect((await choice)?.id, espn);
  });

  testWidgets('phones get the touch-sized strip, line and dialog', (
    tester,
  ) async {
    for (final size in const [Size(360, 740), Size(800, 412)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final status = LiveTvStreams.fromJson(full());
      MediaItem? joined;
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Builder(
                builder: (c) {
                  context = c;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LiveTvStreamsStrip(
                        status: status,
                        onJoin: (i) => joined = i,
                      ),
                      LiveTvStreamsLine(
                        status: status,
                        channelId: fox,
                        onJoin: (i) => joined = i,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: '$size');
      expect(liveTvCompact(context), isTrue);
      // The card fits the screen instead of the 600 px TV card.
      final card = tester.getSize(
        find
            .ancestor(
              of: find.text('SportsCenter'),
              matching: find.byType(Container),
            )
            .last,
      );
      expect(card.width, lessThanOrEqualTo(size.width - 40), reason: '$size');
      expect(tester.getSize(find.text('ESPN').first).height, lessThan(30));
      await tester.tap(find.text('Join'));
      expect(joined?.id, espn);

      final choice = showLiveTvConflict(
        context,
        LiveTvStreamsConflict(status.blocked(fox)!),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$size dialog');
      final dialog = tester.getRect(
        find
            .ancestor(
              of: find.text('Live TV is in use'),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(dialog.width, lessThanOrEqualTo(size.width - 32));
      expect(dialog.left, greaterThanOrEqualTo(0));
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(await choice, isNull);
    }
    tester.view.reset();
  });
}
