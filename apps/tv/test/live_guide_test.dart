import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/core/catalog.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/live_guide.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/extras_state.dart';
import 'package:zorofin_tv/phone/phone_live.dart';
import 'package:zorofin_tv/ui/screens/guide_screen.dart';
import 'package:zorofin_tv/ui/theme.dart';

void main() {
  test(
    'guide clips overlap, ignores malformed/other channels, and fills gaps',
    () {
      final start = DateTime(2026, 11, 4, 12);
      LiveProgram p(String name, int a, int b, {String channel = 'one'}) =>
          LiveProgram(
            name: name,
            channelId: channel,
            start: start.add(Duration(minutes: a)),
            end: start.add(Duration(minutes: b)),
          );
      final slots = guideSlots('one', [
        p('Early', -20, 20),
        p('Overlap', 10, 40),
        p('Later', 60, 140),
        p('Other', 40, 60, channel: 'two'),
        p('Bad', 60, 50),
      ], start);
      expect(slots.map((s) => s.program?.name), [
        'Early',
        'Overlap',
        null,
        'Later',
      ]);
      expect(slots.first.start, start);
      expect(slots.last.end, start.add(const Duration(hours: 2)));
      expect(slots.map((s) => s.end.difference(s.start).inMinutes), [
        20,
        20,
        20,
        60,
      ]);
    },
  );
  testWidgets('TV Live opens Programs and keeps Guide mounted when hidden', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final server = ServerAddress.parse('https://example.test');
    final now = DateTime.now().toUtc();
    final catalog = JellyfinCatalog(
      JellyfinClient(
        server: server,
        identity: const ClientIdentity(
          deviceId: 'device',
          deviceName: 'Fixture',
        ),
        session: Session(
          server: server,
          viewer: Viewer(id: 'viewer', name: 'Viewer'),
          token: 'fixture',
          deviceId: 'device',
        ),
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'Items': [
                {
                  'Id': 'channel',
                  'Name': 'Sample Channel',
                  'Type': 'TvChannel',
                  'CurrentProgram': {
                    'Id': 'program',
                    'Name': 'Fixture broadcast',
                    'StartDate': now
                        .subtract(const Duration(minutes: 10))
                        .toIso8601String(),
                    'EndDate': now
                        .add(const Duration(minutes: 10))
                        .toIso8601String(),
                  },
                },
              ],
              'TotalRecordCount': 1,
            }),
            200,
          ),
        ),
      ),
    );
    final extras = ExtrasState(
      catalog: catalog,
      storage: await SharedPreferences.getInstance(),
    );
    addTearDown(extras.dispose);
    final guideKey = GlobalKey();
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: Zoro.theme(),
        home: Scaffold(
          body: LiveBrowseScreen(
            catalog: catalog,
            extras: extras,
            onOpen: (channel) => opened.add(channel.id),
            onPlay: (_) {},
            tvGuideBuilder: (active) => Focus(
              key: guideKey,
              canRequestFocus: active,
              child: const Text('Guide fixture'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Owner rule (Nov 24): Live TV has no On now row.
    expect(find.text('On now'), findsNothing);
    expect(find.text('Fixture broadcast'), findsNothing);
    expect(guideKey.currentState, isNull);
    expect(opened, isEmpty);
    await tester.tap(find.text('Guide'));
    await tester.pumpAndSettle();
    expect(find.text('Guide fixture'), findsOneWidget);
    final guide = guideKey.currentState;
    expect(guide, isNotNull);
    await tester.tap(find.text('Programs'));
    await tester.pumpAndSettle();
    expect(find.text('Guide fixture'), findsNothing);
    expect(guideKey.currentState, same(guide));
    expect(
      guideKey.currentWidget,
      isA<Focus>().having(
        (widget) => widget.canRequestFocus,
        'canRequestFocus',
        false,
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [1280.0, 1920.0]) {
    testWidgets(
      'guide reads metadata, filters channels, and requires Watch live at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1080);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final requests = <http.Request>[];
        final played = <String>[];
        final now = guideWindowStart(DateTime.now());
        final server = ServerAddress.parse('https://example.test/jellyfin');
        final client = JellyfinClient(
          server: server,
          identity: const ClientIdentity(
            deviceId: 'device',
            deviceName: 'Fixture',
          ),
          session: Session(
            server: server,
            viewer: Viewer(id: 'viewer', name: 'Viewer'),
            token: 'fixture-token',
            deviceId: 'device',
          ),
          httpClient: MockClient((q) async {
            requests.add(q);
            final channels = q.url.path.endsWith('/Channels');
            return http.Response(
              jsonEncode({
                'Items': channels
                    ? [
                        {
                          'Id': 'one',
                          'Name':
                              'A very long channel name with readable ellipsis',
                          'ChannelNumber': '101',
                          'Type': 'TvChannel',
                        },
                        {
                          'Id': 'two',
                          'Name': 'Second channel',
                          'ChannelNumber': '102',
                          'Type': 'TvChannel',
                        },
                      ]
                    : [
                        {
                          'Id': 'program',
                          'Name': 'Fixture broadcast',
                          'ChannelId': 'one',
                          'StartDate': now.toUtc().toIso8601String(),
                          'EndDate': now
                              .add(const Duration(hours: 1))
                              .toUtc()
                              .toIso8601String(),
                          'Overview': 'Broadcast details',
                        },
                      ],
                'TotalRecordCount': channels ? 2 : 1,
              }),
              200,
            );
          }),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: Zoro.theme(),
            home: Scaffold(
              body: GuideScreen(
                catalog: JellyfinCatalog(client),
                onPlay:
                    (
                      item, {
                      startTicks = 0,
                      audioIndex,
                      subtitleIndex,
                      burnSubtitles,
                    }) async {
                      played.add(item.id);
                    },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Fixture broadcast'), findsOneWidget);
        expect(played, isEmpty);
        expect(
          requests.every(
            (q) =>
                q.method == 'GET' &&
                q.url.queryParameters['userId'] == 'viewer',
          ),
          isTrue,
        );
        expect(requests.map((q) => q.url.path), [
          '/jellyfin/LiveTv/Channels',
          '/jellyfin/LiveTv/Programs',
        ]);
        await tester.tap(find.text('Fixture broadcast'));
        await tester.pumpAndSettle();
        expect(played, isEmpty);
        await tester.tap(find.text('Watch live'));
        await tester.pumpAndSettle();
        expect(played, ['one']);
        await tester.enterText(find.byType(TextField), 'Second');
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(find.text('102 Second channel'), findsOneWidget);
        expect(find.textContaining('A very long channel'), findsNothing);
        expect(requests.last.url.queryParameters['channelIds'], 'two');
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
