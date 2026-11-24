import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/app_state.dart';
import 'package:zorofin_tv/core/home.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/preview_catalog.dart';
import 'package:zorofin_tv/core/session_store.dart';
import 'package:zorofin_tv/main.dart';
import 'package:zorofin_tv/ui/screens/home_screen.dart';

MediaItem _movie(
  String id, {
  double? rating,
  bool backdrop = false,
  String type = 'Movie',
}) => MediaItem(
  id: id,
  name: 'Title $id',
  type: type,
  communityRating: rating,
  backdropImageTags: backdrop ? ['b-$id'] : const [],
);

MediaItem _episode(String id, String series, {bool played = false}) =>
    MediaItem(
      id: id,
      name: 'Episode $id',
      type: 'Episode',
      seriesId: series,
      userData: UserData(played: played),
    );

MediaItem _channel(String id, String name, LiveProgram program) =>
    MediaItem(id: id, name: name, type: 'TvChannel', currentProgram: program);

void main() {
  test('featured finale ranks first only during its live window', () {
    final now = DateTime.utc(2026, 11, 25, 2);
    final finale = _channel(
      'finale',
      'ABC',
      LiveProgram.fromJson({
        'Name': 'Live: Dancing with the Stars: Finale',
        'StartDate': '2026-11-25T01:00:00Z',
        'EndDate': '2026-11-25T04:00:00Z',
        'IsLive': true,
        'Genres': ['Featured live event'],
      }),
    );
    final nba = _channel(
      'nba',
      'Sports',
      LiveProgram.fromJson({
        'Name': 'Live: NBA Basketball',
        'StartDate': '2026-11-25T01:00:00Z',
        'EndDate': '2026-11-25T04:00:00Z',
        'IsLive': true,
      }),
    );
    expect(LiveEvent.select([nba, finale], now).first.channel.id, 'finale');
    expect(LiveEvent.select([finale], DateTime.utc(2026, 11, 25, 4)), isEmpty);
    expect(LiveEvent.select([finale], DateTime.utc(2026, 11, 25, 0)), isEmpty);
  });
  group('banner', () {
    test('prefers rated titles with backdrops and keeps its pick', () {
      final banner = HomeBanner(seed: 3);
      final candidates = [
        _movie('a', rating: 8.1, backdrop: true),
        _movie('b', rating: 6, backdrop: true),
        _movie('c', rating: 9),
        _movie('d', rating: 7.5, backdrop: true),
      ];
      banner.update(candidates);
      expect(['a', 'd'], contains(banner.item!.id));
      final first = banner.item!.id;
      for (var i = 0; i < 5; i++) {
        banner.update(candidates.reversed.toList());
        expect(banner.item!.id, first);
      }
    });

    test('server featured titles win over the library', () {
      final banner = HomeBanner(seed: 1)
        ..update(
          [_movie('a', rating: 9, backdrop: true)],
          featured: [_movie('f', type: 'Series')],
        );
      expect(banner.item!.id, 'f');
    });
  });

  test('row order never moves placed rows or pinned ones', () {
    final order = HomeRowOrder(seed: 7)
      ..append([
        ('shelf-0', HomeRowKind.deliberate),
        ('shelf-2', HomeRowKind.deliberate),
        ('discovery-1', HomeRowKind.generated),
      ]);
    expect(order.ids, hasLength(2));
    expect(order.ids, isNot(contains('shelf-0')));
    final placed = [...order.ids];
    order.append([
      ('shelf-2', HomeRowKind.deliberate),
      ('shelf-3', HomeRowKind.deliberate),
    ]);
    expect(order.ids.take(2), placed);
    expect(order.ids.last, 'shelf-3');
  });

  test('continue watching keeps one episode per show', () {
    final rows = continueWatching(
      [_movie('m'), _episode('e1', 's1'), _episode('e2', 's1')],
      [
        _episode('e3', 's1'),
        _episode('e4', 's2'),
        _episode('e5', 's3', played: true),
      ],
    );
    expect(rows.map((i) => i.id), ['m', 'e1', 'e4']);
  });

  test('teams must be 3 to 64 characters, up to 12', () {
    expect(validTeams(['New York Knicks']), isTrue);
    expect(validTeams(['NY']), isFalse);
    expect(validTeams(List.filled(13, 'Team')), isFalse);
    expect(ClientHomeRows.teamMatches('Knicks at Celtics', ['Knicks']), isTrue);
    expect(ClientHomeRows.teamMatches('Knickerbocker', ['Knick']), isFalse);
  });

  test('sports row: only your teams, on now or starting within the hour', () {
    final now = DateTime.utc(2026, 10, 27, 18);
    final channel = MediaItem(
      id: 'ch',
      name: 'TNT Sports 1',
      type: 'TvChannel',
    );
    LiveProgram program(String id, String name, int startMinutes) =>
        LiveProgram(
          id: id,
          channelId: 'ch',
          name: name,
          isSports: true,
          start: now.add(Duration(minutes: startMinutes)),
          end: now.add(Duration(minutes: startMinutes + 150)),
        );
    final programs = [
      program('generic', 'TNT Sports 1', -30),
      program('now', 'Washington Wizards at Boston Celtics', -30),
      program('soon', 'Manchester United vs Chelsea', 45),
      program('tonight', 'Washington Commanders at Dallas Cowboys', 300),
    ];
    List<String> ids(List<String> teams) => ClientHomeRows.sports(
      programs,
      channels: [channel],
      teams: teams,
      now: now,
    ).map((c) => c.id).toList();
    expect(ids(const []), isEmpty);
    expect(
      ids(const [
        'Washington Wizards',
        'Manchester United',
        'Washington Commanders',
      ]),
      ['now', 'soon'],
    );
  });

  test('client rows follow the contract order; server fills gaps', () {
    final merged = ClientHomeRows.merge(
      [
        const HomeFeedRow(id: 'sports', title: 'Sports'),
        const HomeFeedRow(
          id: 'new-episodes',
          title: 'New',
          state: 'unavailable',
        ),
      ],
      [
        const HomeFeedRow(id: 'popular', title: 'Popular'),
        const HomeFeedRow(id: 'new-episodes', title: 'Server new'),
      ],
    );
    expect(merged.map((r) => r.title), ['Server new', 'Popular', 'Sports']);
  });

  test('seasonal plan puts the nearest holiday first', () {
    expect(SeasonalThemes.plan(DateTime.utc(2026, 10, 29)).first, 'halloween');
    expect(SeasonalThemes.plan(DateTime.utc(2026, 12, 20)).first, 'christmas');
    final july = SeasonalThemes.plan(DateTime.utc(2026, 7, 2));
    expect(july.first, 'fourth-july');
    expect(july, contains('summer'));
  });

  test('live events need a live, current sports program', () {
    final now = DateTime.utc(2026, 10, 29, 20);
    LiveProgram program(String name, {bool live = true, bool? repeat}) =>
        LiveProgram(
          name: name,
          start: now.subtract(const Duration(minutes: 30)),
          end: now.add(const Duration(hours: 2)),
          isLive: live,
          isRepeat: repeat,
        );
    final events = LiveEvent.select([
      _channel('1', 'Sports 1', program('NBA Basketball: Knicks vs Celtics')),
      _channel('2', 'Sports 2', program('NFL Football', repeat: true)),
      _channel('3', 'News', program('Evening News', live: false)),
      _channel('4', 'Sports 4', program('Premier League Soccer')),
    ], now);
    expect(events.map((e) => e.id), containsAll(['1', '4']));
    expect(events.map((e) => e.id), isNot(contains('2')));
    expect(events.map((e) => e.id), isNot(contains('3')));
    final knicks = events.firstWhere((e) => e.id == '1');
    expect(knicks.sport, LiveSport.basketball);
    expect(knicks.isCurrent(now), isTrue);
    expect(knicks.progress(now), closeTo(0.2, 0.01));
  });

  testWidgets('preview Home shows live events and Your teams', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SessionStore.open(), deviceName: 'Test TV');
    await tester.pumpWidget(ZorofinTvApp(state: state));
    state.openPreview();
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Sports & live events'),
      300,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    expect(find.text('Sports & live events'), findsOneWidget);
    expect(find.text('All channels'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel(RegExp('^Account menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Your teams'));
    await tester.tap(find.text('Your teams'));
    await tester.pumpAndSettle();
    expect(find.text('See your teams on Home'), findsOneWidget);
    await tester.tap(find.byType(EditableText));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'NY');
    await tester.pumpAndSettle();
    expect(
      find.text('Use up to 12 team names, each between 3 and 64 characters.'),
      findsOneWidget,
    );
  });

  testWidgets('a poster row with a length line clears the next row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HomeRowShelf(
                row: HomeFeedRow(
                  id: 'short-movies',
                  title: 'Watch in 90 minutes',
                  cards: [
                    for (final id in ['1', '2'])
                      HomeRowCard(
                        id: id,
                        item: MediaItem(
                          id: id,
                          name: 'Title $id',
                          type: 'Movie',
                          productionYear: 2012,
                        ),
                        subtitle: '77 min',
                      ),
                  ],
                ),
                catalog: PreviewCatalog(),
                now: now,
                onOpen: (_) {},
              ),
              const Text('Next row'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final length = tester.getBottomLeft(find.text('77 min').first).dy;
    expect(
      length,
      lessThanOrEqualTo(tester.getTopLeft(find.text('Next row')).dy),
    );
  });
}
