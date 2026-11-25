// Renders the TV and phone sports rows with live scores to PNG for review.
// Skipped unless ZOROFIN_SCREENSHOTS names an output folder:
//   ZOROFIN_SCREENSHOTS=/tmp/shots flutter test test/live_scores_screenshot_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/home.dart';
import 'package:zorofin_tv/core/live_scores.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/preview_catalog.dart';
import 'package:zorofin_tv/phone/phone_widgets.dart';
import 'package:zorofin_tv/ui/screens/home_screen.dart';
import 'package:zorofin_tv/ui/theme.dart';

final _out = Platform.environment['ZOROFIN_SCREENSHOTS'];

Future<void> _fonts() async {
  final inter = FontLoader('Inter')
    ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
  await inter.load();
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ?? '/opt/sdk/flutter';
  final icons = File(
    '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  final loader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(await icons.readAsBytes())));
  await loader.load();
}

final _now = DateTime.now();

LiveEvent _event(
  String id,
  String channel,
  LiveSport sport,
  List<String> teams,
) {
  final program = LiveProgram(
    name: teams.join(' vs '),
    start: _now.subtract(const Duration(minutes: 70)),
    end: _now.add(const Duration(minutes: 80)),
    isLive: true,
  );
  return LiveEvent(
    channel: MediaItem(
      id: id,
      name: channel,
      type: 'TvChannel',
      channelNumber: id,
      currentProgram: program,
    ),
    title: teams.join(' vs '),
    competition: sport.title,
    sport: sport,
    start: program.start!,
    end: program.end!,
    priority: 0,
    matchup: teams,
    context: sport.title,
    leagueContext: sport.title,
    evidence: '',
  );
}

Map<String, dynamic> _side(
  String name,
  String short,
  String code,
  String color, {
  bool favorite = false,
}) => {
  'name': name,
  'short': short,
  'abbreviation': code,
  'color': color,
  'favorite': favorite,
};

List<LiveEvent> _events() {
  final start = _now.subtract(const Duration(minutes: 70)).toIso8601String();
  final feed = LiveScoresFeed(
    games: [
      for (final g in [
        {
          'state': 'in',
          'detail': 'Q3 4:12',
          'score': {'home': '88', 'away': '79'},
          'home': _side('Dallas Mavericks', 'Mavericks', 'DAL', '#0053bc'),
          'away': _side(
            'Brooklyn Nets',
            'Nets',
            'BKN',
            '#000000',
            favorite: true,
          ),
        },
        {
          'state': 'in',
          'detail': "2nd 67'",
          'score': {'home': '1', 'away': '2'},
          'home': _side('Arsenal', 'Arsenal', 'ARS', '#ef0107'),
          'away': _side('Chelsea', 'Chelsea', 'CHE', '#034694'),
        },
        {
          'state': 'post',
          'detail': 'Final',
          'score': {'home': '24', 'away': '27'},
          'home': _side('Kansas City Chiefs', 'Chiefs', 'KC', '#e31837'),
          'away': _side('Buffalo Bills', 'Bills', 'BUF', '#00338d'),
        },
      ])
        LiveGame.fromJson({...g, 'start': start})!,
    ],
  );
  return LiveScores.arrange([
    _event('206', 'ESPN', LiveSport.basketball, [
      'Brooklyn Nets',
      'Dallas Mavericks',
    ]),
    _event('210', 'USA Network', LiveSport.soccer, ['Chelsea', 'Arsenal']),
    _event('212', 'CBS', LiveSport.football, [
      'Buffalo Bills',
      'Kansas City Chiefs',
    ]),
  ], feed);
}

void main() {
  testWidgets('TV row', (tester) async {
    await tester.runAsync(_fonts);
    tester.view.physicalSize = const Size(1500, 560) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: Zoro.theme(),
        home: Scaffold(
          backgroundColor: Zoro.background,
          body: Padding(
            padding: const EdgeInsets.only(top: 30),
            child: LiveEventsShelf(
              events: _events(),
              catalog: PreviewCatalog(),
              now: _now,
              onOpen: (_) {},
              onAllChannels: () {},
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile(Uri.file('$_out/tv-live-scores.png')),
    );
  }, skip: _out == null);

  testWidgets('phone row', (tester) async {
    await tester.runAsync(_fonts);
    tester.view.physicalSize = const Size(430, 380) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: Zoro.theme(),
        home: Scaffold(
          backgroundColor: Zoro.background,
          body: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: PhoneLiveEventsShelf(
              events: _events(),
              catalog: PreviewCatalog(),
              now: _now,
              onOpen: (_) {},
              onAllChannels: () {},
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile(Uri.file('$_out/phone-live-scores.png')),
    );
  }, skip: _out == null);
}
