import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:zorofin_tv/core/catalog.dart';
import 'package:zorofin_tv/core/device_playback.dart';
import 'package:zorofin_tv/core/errors.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/playback.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/ui/player/in_app_player.dart';
import 'package:zorofin_tv/ui/player/player_controls.dart';
import 'package:zorofin_tv/ui/screens/player_screen.dart';
import 'package:zorofin_tv/ui/theme.dart';
import 'package:zorofin_tv/ui/widgets/focusable.dart';

class FakeVideo extends VideoPlayerPlatform {
  FakeVideo({this.duration = const Duration(minutes: 5)});
  final Duration duration;
  int creates = 0, disposes = 0, plays = 0, pauses = 0, seeks = 0;
  final sources = <String>[];
  Completer<void>? seekReply, disposeReply;
  Duration position = const Duration(seconds: 10);
  @override
  Future<void> init() async {}
  final streams = <int, StreamController<VideoEvent>>{};
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = ++creates;
    sources.add(options.dataSource.uri ?? '');
    final stream = StreamController<VideoEvent>();
    streams[id] = stream;
    stream.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: duration,
        size: const Size(1920, 1080),
      ),
    );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => streams[playerId]!.stream;
  @override
  Future<void> dispose(int playerId) async {
    disposes++;
    await disposeReply?.future;
  }

  @override
  Future<void> play(int playerId) async {
    plays++;
  }

  @override
  Future<void> pause(int playerId) async {
    pauses++;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> seekTo(int playerId, Duration value) async {
    seeks++;
    position = value;
    await seekReply?.future;
  }

  @override
  Future<Duration> getPosition(int playerId) async => position;
  @override
  Future<void> setMixWithOthers(bool value) async {}
  @override
  Future<void> setAllowBackgroundPlayback(bool value) async {}
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(color: Colors.blue);
}

RecordingClient? lastRecordingClient;

class RecordingClient extends JellyfinClient {
  RecordingClient({
    required super.server,
    required super.identity,
    required super.session,
    required this.reports,
  });
  final List<String> reports;
  @override
  Future<String> requestText(
    List<String> path, {
    Map<String, String> query = const {},
    String method = 'GET',
    Object? body,
    bool authenticated = true,
    bool extensionToken = false,
    int? expectedStatus,
    Duration? wait,
  }) async {
    if (offline) throw const ClientError(ClientErrorKind.network);
    reports.add('/${path.join('/')}');
    return '{}';
  }

  /// The server stops answering, as when the network drops.
  bool offline = false;
}

class FakeCatalog extends JellyfinCatalog {
  FakeCatalog(super.client, {this.transcode = false});
  final bool transcode;
  @override
  Future<List<MediaItem>> seasons(String seriesId) async => [
    MediaItem(id: 'season', name: 'Season 1', type: 'Season', indexNumber: 1),
  ];
  @override
  Future<ItemPage> episodePage(
    String seriesId,
    String seasonId, {
    int start = 0,
    int limit = episodePageSize,
  }) async => ItemPage(
    items: [
      MediaItem(
        id: 'other-episode',
        name: 'Test episode',
        type: 'Episode',
        seriesId: 'series',
        seasonId: 'season',
        indexNumber: 1,
        parentIndexNumber: 1,
      ),
    ],
    totalRecordCount: 1,
  );
  @override
  Future<PlaybackPlan> prepare(MediaItem item, PlaybackOptions options) async =>
      PlaybackPlan.make(
        PlaybackInfo(
          playSessionId: 'test-play',
          mediaSources: [
            MediaSource(
              id: 'source',
              supportsDirectPlay: !transcode,
              supportsTranscoding: true,
              transcodingUrl: '/Videos/movie/master.m3u8',
              transcodingSubProtocol: 'hls',
            ),
          ],
        ),
        itemId: item.id,
        client: client,
        options: options,
      );
}

Future<FakeVideo> openPlayerForStateTest(
  WidgetTester tester, {
  required Duration duration,
  bool live = false,
  bool episode = false,
  bool transcode = false,
  int startTicks = 0,
}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final previous = VideoPlayerPlatform.instance;
  final video = FakeVideo(duration: duration);
  VideoPlayerPlatform.instance = video;
  addTearDown(() => VideoPlayerPlatform.instance = previous);
  final server = ServerAddress.parse('https://example.com');
  final reports = <String>[];
  final catalog = FakeCatalog(
    lastRecordingClient = RecordingClient(
      server: server,
      identity: const ClientIdentity(
        deviceId: 'test-device',
        deviceName: 'Test TV',
      ),
      session: Session(
        server: server,
        viewer: Viewer(id: 'u', name: 'Viewer'),
        token: 'test-token',
        deviceId: 'test-device',
      ),
      reports: reports,
    ),
    transcode: transcode,
  );
  final host = GlobalKey<InAppPlayerHostState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: Zoro.theme(),
      shortcuts: {...WidgetsApp.defaultShortcuts, ...selectKeys, ...backKeys},
      home: InAppPlayerHost(
        key: host,
        child: const Scaffold(body: Text('Browse library')),
      ),
    ),
  );
  unawaited(
    host.currentState!.open(
      (presentation) => PlayerScreen(
        presentation: presentation,
        catalog: catalog,
        item: MediaItem(
          id: 'movie',
          name: 'Test movie',
          type: live
              ? 'TvChannel'
              : episode
              ? 'Episode'
              : 'Movie',
          seriesId: episode ? 'series' : null,
          seasonId: episode ? 'season' : null,
          parentIndexNumber: episode ? 1 : null,
        ),
        subtitleIndex: -1,
        startTicks: startTicks,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return video;
}

void main() {
  testWidgets(
    'Android retries a failed stream once with the compatible profile',
    (tester) async {
      const channel = MethodChannel('org.zorofin.tv/platform');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'playbackCapabilities'
            ? {
                'platform': 'android',
                'videos': {
                  'h264': {
                    'width': 1920,
                    'height': 1080,
                    'fps': 60,
                    'level': 42,
                  },
                },
              }
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final video = await openPlayerForStateTest(
        tester,
        duration: const Duration(minutes: 5),
        startTicks: 400000000,
      );
      expect(video.sources, hasLength(1));
      video.streams[1]!.addError(
        PlatformException(code: 'VideoError', message: 'Fixture failure'),
      );
      await tester.pump();
      // Closing the failed player cancels its event stream in the root zone.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      // One more try, as HLS, at the same place.
      expect(video.sources, hasLength(2));
      expect(video.sources.last, contains('master.m3u8'));
      expect(video.position, const Duration(seconds: 40));
      expect(find.text('Unable to play'), findsNothing);
      // A second failure is shown, not retried for ever.
      video.streams[2]!.addError(
        PlatformException(code: 'VideoError', message: 'Fixture HLS failure'),
      );
      await tester.pumpAndSettle();
      expect(video.sources, hasLength(2));
      expect(find.text('Unable to play'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    },
    skip: DevicePlayback.isSamsungTv,
  );
  testWidgets(
    'a dropped connection waits for the server and resumes at the same place',
    (tester) async {
      final video = await openPlayerForStateTest(
        tester,
        duration: const Duration(minutes: 5),
        startTicks: 400000000,
      );
      final client = lastRecordingClient!;
      client.offline = true;
      video.streams[1]!.addError(
        PlatformException(code: 'VideoError', message: 'Source error'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(find.text('Unable to play'), findsNothing);
      // Still away after two checks: keep waiting, no new stream.
      await tester.pump(const Duration(seconds: 7));
      expect(video.sources, hasLength(1));
      client.offline = false;
      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      // The same kind of stream again, at the same place.
      expect(video.sources, hasLength(2));
      expect(video.sources.last, contains('static=true'));
      expect(video.position, const Duration(seconds: 40));
      expect(find.text('Reconnecting…'), findsNothing);
      expect(find.text('Unable to play'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    },
  );
  testWidgets(
    'Samsung direct play retries once with HLS at the same position',
    (tester) async {
      final video = await openPlayerForStateTest(
        tester,
        duration: const Duration(minutes: 5),
        startTicks: 400000000,
      );
      expect(video.sources.single, contains('static=true'));
      video.streams[1]!.addError(
        PlatformException(
          code: 'VideoError',
          message: 'Fixture decoder failure',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(
        video.sources,
        hasLength(2),
        reason:
            'closed players: ${video.disposes}, errors: ${find.text('Unable to play').evaluate().length}',
      );
      expect(video.sources.last, contains('master.m3u8'));
      expect(video.position, const Duration(seconds: 40));
      video.streams[2]!.addError(
        PlatformException(code: 'VideoError', message: 'Fixture HLS failure'),
      );
      await tester.pumpAndSettle();
      expect(video.sources, hasLength(2));
      expect(find.text('Unable to play'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    },
    skip: !DevicePlayback.isSamsungTv,
  );
  testWidgets(
    'Samsung prevents overlapping native seeks and closes when disposal stalls',
    (tester) async {
      final video = await openPlayerForStateTest(
        tester,
        duration: const Duration(minutes: 5),
      );
      final seeks = video.seeks;
      final seek = Completer<void>();
      video.seekReply = seek;
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaFastForward);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaFastForward);
      await tester.pump();
      expect(video.seeks, seeks + 1);
      seek.complete();
      await tester.pump();
      final dispose = Completer<void>();
      video.disposeReply = dispose;
      tester.widget<PlayerControls>(find.byType(PlayerControls)).onClose();
      await tester.pump();
      // The video event subscription cancels in the root zone.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(video.disposes, 1);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsNothing);
      dispose.complete();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    },
    skip: !DevicePlayback.isSamsungTv,
  );
  testWidgets(
    'HLS resume seeks the decoder instead of adding a display offset',
    (tester) async {
      final video = await openPlayerForStateTest(
        tester,
        duration: const Duration(minutes: 50),
        transcode: true,
        startTicks: 19200000000,
      );
      expect(video.position, const Duration(minutes: 32));
      expect(video.plays, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    },
  );
  testWidgets('platform Back closes the season dropdown before its panel', (
    tester,
  ) async {
    await openPlayerForStateTest(
      tester,
      duration: const Duration(minutes: 5),
      episode: true,
    );
    await tester.tap(find.bySemanticsLabel('Seasons and episodes'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Season 1'), findsNWidgets(2));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('Seasons & episodes'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Seasons & episodes'), findsNothing);
    expect(find.byType(PlayerControls), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  });
  for (final duration in [Duration.zero, const Duration(seconds: 5)]) {
    testWidgets('Live TV with duration $duration stays resumable', (
      tester,
    ) async {
      final video = await openPlayerForStateTest(
        tester,
        duration: duration,
        live: true,
      );
      // The plugin clamps live positions to a zero or stale buffer duration and
      // marks completion even though this is an ongoing live stream.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(
        tester.widget<PlayerControls>(find.byType(PlayerControls)).phase,
        PlayerPhase.playing,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      final opacity = find.ancestor(
        of: find.byType(PlayerControls),
        matching: find.byType(AnimatedOpacity),
      );
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
      await tester.pumpAndSettle();
      expect(
        tester.widget<PlayerControls>(find.byType(PlayerControls)).phase,
        PlayerPhase.paused,
      );
      final plays = video.plays;
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
      await tester.pumpAndSettle();
      expect(video.plays, greaterThan(plays));
      expect(
        tester.widget<PlayerControls>(find.byType(PlayerControls)).phase,
        PlayerPhase.playing,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    });
  }

  testWidgets('finite video completion still offers replay', (tester) async {
    final video = await openPlayerForStateTest(
      tester,
      duration: const Duration(minutes: 5),
    );
    video.streams[1]!.add(VideoEvent(eventType: VideoEventType.completed));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PlayerControls>(find.byType(PlayerControls)).phase,
      PlayerPhase.ended,
    );
    expect(find.bySemanticsLabel('Watch again'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  });
  testWidgets('actual player retains decoder and remote actions while minimized', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final previous = VideoPlayerPlatform.instance;
    final video = FakeVideo();
    VideoPlayerPlatform.instance = video;
    addTearDown(() => VideoPlayerPlatform.instance = previous);
    final server = ServerAddress.parse('https://example.com');
    final reports = <String>[];
    final catalog = FakeCatalog(
      RecordingClient(
        server: server,
        identity: const ClientIdentity(
          deviceId: 'test-device',
          deviceName: 'Test TV',
        ),
        session: Session(
          server: server,
          viewer: Viewer(id: 'u', name: 'Viewer'),
          token: 'test-token',
          deviceId: 'test-device',
        ),
        reports: reports,
      ),
    );
    final host = GlobalKey<InAppPlayerHostState>();
    final libraryFocus = FocusNode();
    addTearDown(libraryFocus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Zoro.theme(),
        shortcuts: {...WidgetsApp.defaultShortcuts, ...selectKeys, ...backKeys},
        home: InAppPlayerHost(
          key: host,
          child: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 100,
                  bottom: 32,
                  width: 300,
                  height: 64,
                  child: TextButton(
                    autofocus: true,
                    focusNode: libraryFocus,
                    onPressed: () {},
                    child: const Text('Browse library'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    unawaited(
      host.currentState!.open(
        (presentation) => PlayerScreen(
          presentation: presentation,
          catalog: catalog,
          item: MediaItem(id: 'movie', name: 'Test movie', type: 'Movie'),
          subtitleIndex: -1,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(video.creates, 1);
    expect(find.bySemanticsLabel('Mini-player'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Mini-player'));
    await tester.pumpAndSettle();
    expect(video.creates, 1);
    expect(video.disposes, 0);
    expect(find.bySemanticsLabel('Expand player'), findsOneWidget);
    expect(libraryFocus.hasFocus, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(libraryFocus.hasFocus, false);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(libraryFocus.hasFocus, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final pauses = video.pauses;
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(video.pauses, greaterThan(pauses));
    // Select must activate the focused mini-player control, not the hidden
    // full-screen surface's generic play/pause key handler.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final focusedLabels = <String>[];
    FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
      if (e.widget is Semantics) {
        focusedLabels.add((e.widget as Semantics).properties.label ?? 'none');
      }
      return true;
    });
    expect(
      focusedLabels,
      contains('Expand player'),
      reason:
          'Remote Right should reach Expand; focus=${FocusManager.instance.primaryFocus}',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Mini-player'), findsOneWidget);
    expect(video.creates, 1);
    await tester.tap(find.bySemanticsLabel('Mini-player'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Close mini-player'));
    await tester.pumpAndSettle();
    // Stream cancellation can complete in the root zone. Yield that zone
    // before pumping the widget's pending disposal continuation.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    for (var i = 0; i < 10 && video.disposes == 0; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(
      video.disposes,
      1,
      reason:
          'reports=$reports active=${host.currentState!.hasPlayer} pauses=${video.pauses}',
    );
    expect(reports, contains('/Sessions/Playing/Stopped'));
    expect(host.currentState!.hasPlayer, false);
  });
}
