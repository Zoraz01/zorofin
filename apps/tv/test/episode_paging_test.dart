import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zorofin_tv/ui/player/player_panels.dart';
import 'package:zorofin_tv/ui/widgets/focusable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/catalog.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/preview_catalog.dart';
import 'package:zorofin_tv/ui/screens/detail_screen.dart';

/// A long season served 30 episodes at a time.
class _LongSeason extends PreviewCatalog {
  _LongSeason({this.count = 75, this.secondPageGate});
  final int count;
  final Completer<void>? secondPageGate;
  final starts = <int>[];

  static final all = [
    for (var i = 1; i <= 75; i++)
      MediaItem(
        id: 'e$i',
        name: 'Episode $i',
        type: 'Episode',
        seriesId: 's',
        seasonId: 'season',
        indexNumber: i,
        parentIndexNumber: 1,
      ),
  ];

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
  }) async {
    starts.add(start);
    if (start == 30) await secondPageGate?.future;
    return ItemPage(
      items: all.take(count).skip(start).take(limit).toList(),
      totalRecordCount: count,
    );
  }
}

class _RuntimeSeason extends _LongSeason {
  _RuntimeSeason({required this.watched}) : super(count: 1);
  final bool watched;

  @override
  Future<ItemPage> episodePage(
    String seriesId,
    String seasonId, {
    int start = 0,
    int limit = episodePageSize,
  }) async => ItemPage(
    items: [
      MediaItem(
        id: 'e1',
        name: 'Episode 1',
        type: 'Episode',
        seriesId: 's',
        seasonId: 'season',
        indexNumber: 1,
        parentIndexNumber: 1,
        runTimeTicks: 27000000000,
        userData: UserData(played: watched),
      ),
    ],
    totalRecordCount: 1,
  );
}

class _LaterSeason extends _LongSeason {
  @override
  Future<List<MediaItem>> seasons(String seriesId) async => [
    MediaItem(id: 'empty', name: 'Season 1', type: 'Season', indexNumber: 1),
    MediaItem(id: 'season', name: 'Season 2', type: 'Season', indexNumber: 2),
  ];
  final selected = <String>[];
  @override
  Future<ItemPage> episodePage(
    String seriesId,
    String seasonId, {
    int start = 0,
    int limit = episodePageSize,
  }) async {
    selected.add(seasonId);
    if (seasonId == 'empty') {
      return ItemPage(items: [], totalRecordCount: 0);
    }
    return super.episodePage(seriesId, seasonId, start: start, limit: limit);
  }
}

Widget _browser(
  _LongSeason catalog, {
  required int current,
  bool inPlayer = true,
}) {
  final browser = SeasonEpisodeBrowser(
    catalog: catalog,
    context: _LongSeason.all[current - 1],
    currentEpisodeId: 'e$current',
    inPlayer: inPlayer,
    onOpen: (_) {},
  );
  return MaterialApp(
    shortcuts: {...WidgetsApp.defaultShortcuts, ...selectKeys},
    home: Scaffold(
      body: inPlayer
          ? PlayerOptionsSurface(
              title: 'Episodes',
              fullWidth: true,
              onClose: () {},
              child: browser,
            )
          : browser,
    ),
  );
}

void _expectLabelWithinCard(WidgetTester tester, Finder card, String text) {
  final label = find.descendant(of: card, matching: find.text(text));
  expect(label.hitTestable(), findsOneWidget);
  final bounds = tester.getRect(card), labelBounds = tester.getRect(label);
  expect(labelBounds.left, greaterThanOrEqualTo(bounds.left));
  expect(labelBounds.right, lessThanOrEqualTo(bounds.right));
}

void _expectFullyVisible(WidgetTester tester, int episode, double width) {
  final card = find.byWidgetPredicate(
    (widget) =>
        widget is Focusable &&
        widget.semanticLabel ==
            'Episode $episode, Episode $episode, current episode',
  );
  expect(card, findsOneWidget);
  expect(card.hitTestable(), findsOneWidget);
  final bounds = tester.getRect(card);
  final viewport = tester.getRect(find.byType(ListView));
  expect(bounds.width, closeTo(width, 0.01));
  expect(bounds.left, greaterThanOrEqualTo(viewport.left));
  expect(bounds.right, lessThanOrEqualTo(viewport.right));
  _expectLabelWithinCard(
    tester,
    card,
    width == 300 ? 'Currently playing' : 'Current episode',
  );
}

void main() {
  for (final watched in [false, true]) {
    testWidgets(
      '${watched ? "watched" : "current"} status and runtime fit the player card',
      (tester) async {
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _browser(_RuntimeSeason(watched: watched), current: watched ? 2 : 1),
        );
        await tester.pumpAndSettle();
        final card = find.byWidgetPredicate(
          (widget) =>
              widget is Focusable &&
              widget.semanticLabel ==
                  'Episode 1, Episode 1${watched ? "" : ", current episode"}',
        );
        expect(card.hitTestable(), findsOneWidget);
        _expectLabelWithinCard(tester, card, '45m');
        _expectLabelWithinCard(
          tester,
          card,
          watched ? 'Watched' : 'Currently playing',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final inPlayer in [true, false]) {
    for (final current in [45, 60]) {
      testWidgets(
        'episode $current fully visible after delayed page in ${inPlayer ? "player" : "details"}',
        (tester) async {
          tester.view.physicalSize = Size(current == 60 ? 1280 : 1920, 1080);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final gate = Completer<void>();
          final catalog = _LongSeason(count: 60, secondPageGate: gate);
          await tester.pumpWidget(
            _browser(catalog, current: current, inPlayer: inPlayer),
          );
          await tester.pumpAndSettle();
          expect(catalog.starts, [0, 30]);
          expect(find.text('$current. Episode $current'), findsNothing);
          // The first 30 cards have completed layout before the next page arrives.
          gate.complete();
          await tester.pumpAndSettle();
          _expectFullyVisible(tester, current, inPlayer ? 300 : 380);
          if (inPlayer) {
            expect(
              FocusManager.instance.primaryFocus?.debugLabel,
              'player-current-season',
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('late page never recenters after remote interaction', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gate = Completer<void>();
    final catalog = _LongSeason(count: 60, secondPageGate: gate);
    await tester.pumpWidget(_browser(catalog, current: 45));
    await tester.pumpAndSettle();
    expect(catalog.starts, [0, 30]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final focus = FocusManager.instance.primaryFocus;
    final row = tester.widget<ListView>(find.byType(ListView)).controller!;
    final offset = row.offset;
    gate.complete();
    await tester.pumpAndSettle();
    expect(row.offset, closeTo(offset, 0.01));
    expect(FocusManager.instance.primaryFocus, same(focus));
    expect(find.text('45. Episode 45').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('old account page cannot move the replacement browser', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gate = Completer<void>();
    final original = _LongSeason(count: 60, secondPageGate: gate);
    await tester.pumpWidget(_browser(original, current: 45));
    await tester.pumpAndSettle();
    expect(original.starts, [0, 30]);
    final replacement = _LongSeason(count: 1);
    await tester.pumpWidget(_browser(replacement, current: 1));
    await tester.pumpAndSettle();
    _expectFullyVisible(tester, 1, 300);
    final row = tester.widget<ListView>(find.byType(ListView)).controller!;
    gate.complete();
    await tester.pumpAndSettle();
    _expectFullyVisible(tester, 1, 300);
    expect(row.offset, 0);
    expect(find.text('45. Episode 45'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('series opens on resolved next episode season beyond page one', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final catalog = _LaterSeason();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SeasonEpisodeBrowser(
            catalog: catalog,
            context: MediaItem(id: 's', name: 'Series', type: 'Series'),
            preferredEpisode: _LongSeason.all[39],
            currentEpisodeId: 'e40',
            onOpen: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(catalog.selected, ['season', 'season']);
    expect(catalog.starts, [0, 30]);
    expect(find.text('40. Episode 40'), findsOneWidget);
  });
  testWidgets('series without a target skips empty seasons', (tester) async {
    final catalog = _LaterSeason();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SeasonEpisodeBrowser(
            catalog: catalog,
            context: MediaItem(id: 's', name: 'Series', type: 'Series'),
            onOpen: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(catalog.selected.take(2), ['empty', 'season']);
    expect(find.text('Season 2'), findsOneWidget);
  });
  testWidgets('async player episode browser focuses the current season', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        shortcuts: {...WidgetsApp.defaultShortcuts, ...selectKeys},
        home: Scaffold(
          body: PlayerOptionsSurface(
            title: 'Episodes',
            fullWidth: true,
            onClose: () {},
            child: SeasonEpisodeBrowser(
              catalog: _LongSeason(),
              context: _LongSeason.all[39],
              currentEpisodeId: 'e40',
              inPlayer: true,
              onOpen: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'player-current-season',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Season 1'), findsNWidgets(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('Episodes'), findsOneWidget);
  });

  testWidgets('pages until the current episode loads, then on request', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final catalog = _LongSeason();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SeasonEpisodeBrowser(
            catalog: catalog,
            context: _LongSeason.all[39],
            currentEpisodeId: 'e40',
            onOpen: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(catalog.starts, [0, 30], reason: 'episode 40 is on page two');
    expect(find.text('40. Episode 40'), findsOneWidget);
    expect(find.text('Current episode'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('More episodes'),
      800,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text('More episodes'));
    await tester.pumpAndSettle();
    expect(catalog.starts, [0, 30, 60]);
    expect(find.text('More episodes'), findsNothing);
  });
}
