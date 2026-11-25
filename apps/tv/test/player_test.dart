import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/catalog.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/playback.dart';
import 'package:zorofin_tv/core/preview_catalog.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/ui/player/player_controls.dart';
import 'package:zorofin_tv/ui/player/player_panels.dart';
import 'package:zorofin_tv/ui/screens/player_screen.dart';
import 'package:zorofin_tv/ui/theme.dart';
import 'package:zorofin_tv/ui/widgets/focusable.dart';

Widget _app(Widget child) => MaterialApp(
  theme: Zoro.theme(),
  shortcuts: {...WidgetsApp.defaultShortcuts, ...selectKeys, ...backKeys},
  home: Scaffold(body: child),
);

void main() {
  testWidgets(
    'loading and ready controls keep the same timeline and transport geometry',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final play = FocusNode();
      addTearDown(play.dispose);
      Future<void> pump(
        PlayerPhase phase,
        Duration? duration,
        Duration position,
      ) async {
        await tester.pumpWidget(
          _app(
            PlayerControls(
              title: 'Sample series',
              subtitle: 'S1 E2 · Sample episode',
              phase: phase,
              position: position,
              duration: duration,
              playFocus: play,
              hasEpisodes: true,
              onClose: () {},
              onTogglePlay: () {},
              onSkip: (_) {},
              onPanel: (_) {},
              onScrubStart: () {},
              onScrubMove: (_) {},
              onScrubCommit: () {},
              onScrubCancel: () {},
              onInteract: () {},
            ),
          ),
        );
        await tester.pump();
      }

      await pump(PlayerPhase.preparing, null, Duration.zero);
      final rail = tester.getRect(find.byType(TimelineBar));
      final title = tester.getRect(find.text('Sample series'));
      expect(
        tester.widget<TimelineBar>(find.byType(TimelineBar)).enabled,
        false,
      );
      await pump(
        PlayerPhase.playing,
        const Duration(hours: 2),
        const Duration(hours: 1),
      );
      expect(tester.getRect(find.byType(TimelineBar)), rail);
      expect(tester.getRect(find.text('Sample series')), title);
      expect(
        tester.widget<TimelineBar>(find.byType(TimelineBar)).enabled,
        true,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final platform in [TargetPlatform.android, TargetPlatform.linux]) {
    testWidgets(
      'fullscreen player background on $platform',
      (tester) async {
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final server = ServerAddress.parse('https://example.com');
        final catalog = JellyfinCatalog(
          JellyfinClient(
            server: server,
            identity: const ClientIdentity(deviceId: 'd', deviceName: 'TV'),
            session: Session(
              server: server,
              viewer: Viewer(id: 'u1', name: 'Sample viewer'),
              token: 'test-token',
              deviceId: 'd',
            ),
            httpClient: MockClient(
              (_) async =>
                  http.Response('{"ErrorCode":"NoCompatibleStream"}', 200),
            ),
          ),
        );
        const boundary = Key('player-composition');
        await tester.pumpWidget(
          _app(
            RepaintBoundary(
              key: boundary,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Color(0xFFFF00FF)),
                  PlayerScreen(
                    catalog: catalog,
                    item: MediaItem(id: 'm1', name: 'Sample'),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final image = await tester.runAsync(
          () => tester
              .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
              .toImage(),
        );
        final bytes = await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        // A corner outside the video/error card represents a letterbox margin.
        expect(
          bytes!.buffer.asUint8List().sublist(0, 4),
          platform == TargetPlatform.android
              ? [0, 0, 0, 255]
              : [255, 0, 255, 255],
          reason:
              'Android must hide the library; native webOS retains its video plane.',
        );
        image!.dispose();
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  test('time labels match the Apple player', () {
    expect(timeLabel(const Duration(seconds: 65)), '1:05');
    expect(
      timeLabel(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
    expect(timeLabel(const Duration(seconds: -4)), '0:00');
  });

  test('choosing tracks asks the server to transcode with them', () {
    final plain = PlaybackProfile.request('u1', PlaybackOptions());
    expect(plain['EnableDirectPlay'], true);
    expect(
      plain.containsKey('SubtitleStreamIndex'),
      false,
      reason: 'automatic subtitles let the server apply account defaults',
    );
    final off = PlaybackProfile.request(
      'u1',
      PlaybackOptions(subtitleIndex: -1),
    );
    expect(off['SubtitleStreamIndex'], -1);
    final text = PlaybackProfile.request(
      'u1',
      PlaybackOptions(subtitleIndex: 3),
    );
    expect(
      text['EnableDirectPlay'],
      true,
      reason: 'text subtitles are drawn by the app',
    );
    expect(plain.containsKey('AudioStreamIndex'), false);

    final chosen = PlaybackProfile.request(
      'u1',
      PlaybackOptions(
        audioIndex: 2,
        subtitleIndex: 4,
        burnSubtitles: true,
        bitrate: 8000000,
      ),
    );
    expect(chosen['EnableDirectPlay'], false);
    expect(chosen['AudioStreamIndex'], 2);
    expect(chosen['SubtitleStreamIndex'], 4);
    expect(chosen['MaxStreamingBitrate'], 8000000);

    final copy = PlaybackOptions(
      audioIndex: 2,
    ).copyWith(audioIndex: () => null);
    expect(copy.audioIndex, isNull);
    expect(
      PlaybackOptions(
        bitrate: 8000000,
      ).sameStream(PlaybackOptions(bitrate: 8000000, startTicks: 99)),
      true,
    );
  });

  test('up next follows the season order and stops at the end', () async {
    final catalog = PreviewCatalog();
    final episodes = PreviewCatalog.previewEpisodes;
    expect((await catalog.episodeAfter(episodes[0]))?.name, 'The Signal');
    expect(await catalog.episodeAfter(episodes.last), isNull);
  });

  test('live guide keeps this channel, sorted, with schedules', () async {
    final server = ServerAddress.parse('https://example.com');
    late Uri sent;
    final client = JellyfinClient(
      server: server,
      identity: const ClientIdentity(deviceId: 'd', deviceName: 'TV'),
      session: Session(
        server: server,
        viewer: Viewer(id: 'u1', name: 'Zo'),
        token: 't',
        deviceId: 'd',
      ),
      httpClient: MockClient((request) async {
        sent = request.url;
        return http.Response(
          jsonEncode({
            'Items': [
              {
                'Name': 'Late',
                'ChannelId': 'c1',
                'StartDate': '2026-10-29T20:00:00Z',
                'EndDate': '2026-10-29T21:00:00Z',
              },
              {
                'Name': 'Other',
                'ChannelId': 'c2',
                'StartDate': '2026-10-29T19:00:00Z',
                'EndDate': '2026-10-29T20:00:00Z',
              },
              {
                'Name': 'Early',
                'ChannelId': 'c1',
                'StartDate': '2026-10-29T19:00:00Z',
                'EndDate': '2026-10-29T20:00:00Z',
              },
              {'Name': 'Broken', 'ChannelId': 'c1', 'StartDate': 'nope'},
            ],
          }),
          200,
        );
      }),
    );
    final at = DateTime.utc(2026, 10, 29, 19, 30);
    final programs = await client.livePrograms('c1', now: at);
    expect(sent.path, '/LiveTv/Programs');
    expect(sent.queryParameters['channelIds'], 'c1');
    expect(programs.map((p) => p.name), ['Early', 'Late']);
    expect(programs.first.isAiring(at.toLocal()), true);
    expect(programs.last.isAiring(at.toLocal()), false);
  });

  testWidgets('controls show the title, times and remote seek mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final play = FocusNode();
    addTearDown(play.dispose);
    final events = <String>[];
    Duration? scrub;

    Future<void> pump() => tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => PlayerControls(
            title: 'Orbital',
            subtitle: 'S1 E2 · The Signal',
            phase: PlayerPhase.playing,
            position: const Duration(minutes: 1, seconds: 5),
            duration: const Duration(minutes: 45),
            scrubPosition: scrub,
            hasEpisodes: true,
            hasTracks: true,
            playFocus: play,
            onClose: () => events.add('close'),
            onTogglePlay: () => events.add('toggle'),
            onSkip: (s) => events.add('skip $s'),
            onPanel: (p) => events.add(p.name),
            onScrubStart: () =>
                setState(() => scrub = const Duration(minutes: 1, seconds: 5)),
            onScrubMove: (t) => setState(() => scrub = t),
            onScrubCommit: () => events.add('seek ${scrub!.inSeconds}'),
            onScrubCancel: () => events.add('cancel'),
            onInteract: () {},
          ),
        ),
      ),
    );
    await pump();
    expect(find.text('Orbital'), findsOneWidget);
    expect(find.text('S1 E2 · The Signal'), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget);
    expect(find.text('−43:55'), findsOneWidget);

    play.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(events, ['toggle', 'skip 30']);

    // Down from the transport reaches the timeline; OK, Right, Right, OK seeks.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('1:25'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(events.last, 'seek 85');
  });

  testWidgets('track panel lists languages and marks the selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    int? audio = -9;
    await tester.pumpWidget(
      _app(
        TrackChoices(
          streams: [
            MediaStream(
              index: 1,
              type: 'Audio',
              language: 'eng',
              codec: 'aac',
              channels: 2,
            ),
            MediaStream(
              index: 2,
              type: 'Audio',
              language: 'eng',
              codec: 'ac3',
              channels: 6,
            ),
            MediaStream(
              index: 3,
              type: 'Subtitle',
              language: 'spa',
              isForced: true,
            ),
          ],
          options: PlaybackOptions(subtitleIndex: 3),
          onAudio: (i) => audio = i,
          onSubtitles: (_) {},
        ),
      ),
    );
    expect(find.text('Automatic'), findsOneWidget);
    expect(find.text('English'), findsNWidgets(2));
    expect(find.text('AC3 · 6 channels'), findsOneWidget);
    expect(find.text('Spanish (Forced)'), findsNothing);
    await tester.tap(find.text('AC3 · 6 channels'));
    expect(audio, 2);
    // Subtitles sit behind the segmented picker, like Apple TV.
    await tester.tap(find.text('Subtitles').first);
    await tester.pump();
    expect(find.text('Spanish (Forced)'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('options open as a compact card above the controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var closed = false;
    int? chosen;
    await tester.pumpWidget(
      _app(
        Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.indigo)),
            Positioned.fill(
              child: PlayerOptionsSurface(
                title: 'Quality',
                onClose: () => closed = true,
                child: QualityChoices(
                  selected: 8000000,
                  onSelect: (value) => chosen = value,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    final card = tester.getRect(
      find
          .ancestor(of: find.text('Quality'), matching: find.byType(Container))
          .last,
    );
    expect(card.width, 560);
    expect(card.right, 1920 - 64);
    expect(card.bottom, 1080 - PlayerOptionsSurface.controlsClearance);
    expect(card.height, lessThan(700));
    expect(find.text('Maximum streaming bitrate'), findsOneWidget);
    // The current quality takes focus first; Select keeps that choice.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(chosen, 8000000);
    expect(closed, isFalse);
    await tester.tap(find.bySemanticsLabel('Return to playback'));
    expect(closed, isTrue);
  });

  testWidgets('audio and subtitle segments start on the selected track', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    int? audio;
    int? subtitle;
    await tester.pumpWidget(
      _app(
        PlayerOptionsSurface(
          title: 'Tracks',
          onClose: () {},
          child: TrackChoices(
            streams: [
              MediaStream(index: 1, type: 'Audio', language: 'eng'),
              MediaStream(index: 2, type: 'Audio', language: 'spa'),
              MediaStream(index: 3, type: 'Subtitle', language: 'eng'),
            ],
            options: PlaybackOptions(audioIndex: 2, subtitleIndex: -1),
            onAudio: (v) => audio = v,
            onSubtitles: (v) => subtitle = v,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(audio, 2);
    await tester.tap(find.text('Subtitles').first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(subtitle, -1);
    await tester.tap(find.text('Audio').first);
    await tester.pumpAndSettle();
    audio = null;
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(audio, 2);
  });

  testWidgets('read-only playback info keeps Close focused', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var closed = false;
    await tester.pumpWidget(
      _app(
        PlayerOptionsSurface(
          title: 'Playback info',
          focusClose: true,
          onClose: () => closed = true,
          child: const PlaybackInformation(
            facts: [('Playback', 'Direct play')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(closed, true);
  });

  testWidgets('a failed stream offers Try again and Close', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = ServerAddress.parse('https://example.com');
    final catalog = JellyfinCatalog(
      JellyfinClient(
        server: server,
        identity: const ClientIdentity(deviceId: 'd', deviceName: 'TV'),
        session: Session(
          server: server,
          viewer: Viewer(id: 'u1', name: 'Zo'),
          token: 't',
          deviceId: 'd',
        ),
        httpClient: MockClient(
          (_) async => http.Response('{"ErrorCode":"NoCompatibleStream"}', 200),
        ),
      ),
    );
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => ZoroButton(
            label: 'Open',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PlayerScreen(
                  catalog: catalog,
                  item: MediaItem(id: 'm1', name: 'Tideline'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Unable to play'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
  });
}
