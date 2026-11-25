import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/catalog.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/preview_catalog.dart';
import 'package:zorofin_tv/ui/screens/detail_screen.dart';

class _PlaybackCatalog extends PreviewCatalog {
  bool watched = false;
  int ticks = 0;
  final seasonsRead = <String>[];
  MediaItem get episode => MediaItem(
    id: 'e',
    name: 'Sample episode',
    type: 'Episode',
    seriesId: 'series',
    seasonId: 's2',
    indexNumber: 1,
    parentIndexNumber: 2,
    runTimeTicks: 100000000,
    userData: UserData(played: watched, playbackPositionTicks: ticks),
  );
  @override
  Future<MediaItem> item(String id) async => episode;
  @override
  Future<List<MediaItem>> similar(MediaItem item) async => [];
  @override
  Future<List<MediaItem>> seasons(String seriesId) async => [
    MediaItem(id: 's1', name: 'Season 1', type: 'Season', indexNumber: 1),
    MediaItem(id: 's2', name: 'Season 2', type: 'Season', indexNumber: 2),
  ];
  @override
  Future<ItemPage> episodePage(
    String seriesId,
    String seasonId, {
    int start = 0,
    int limit = episodePageSize,
  }) async {
    seasonsRead.add(seasonId);
    return ItemPage(items: [episode], totalRecordCount: 1);
  }
}

void main() {
  testWidgets(
    'revision refreshes watched and progress without resetting season',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final catalog = _PlaybackCatalog();
      Widget build(int revision) => MaterialApp(
        home: Scaffold(
          body: SeasonEpisodeBrowser(
            catalog: catalog,
            context: catalog.episode,
            revision: revision,
            onOpen: (_) {},
          ),
        ),
      );
      await tester.pumpWidget(build(0));
      await tester.pumpAndSettle();
      expect(find.text('Season 2'), findsOneWidget);
      expect(find.text('Watched'), findsNothing);
      final state = tester.state(find.byType(SeasonEpisodeBrowser));
      catalog.ticks = 50000000;
      await tester.pumpWidget(build(1));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(SeasonEpisodeBrowser)), same(state));
      expect(
        find.byWidgetPredicate(
          (w) => w is FractionallySizedBox && w.widthFactor == 0.5,
        ),
        findsOneWidget,
      );
      catalog.watched = true;
      catalog.ticks = 0;
      await tester.pumpWidget(build(2));
      await tester.pumpAndSettle();
      expect(find.text('Watched'), findsOneWidget);
      expect(catalog.seasonsRead, ['s2', 's2', 's2']);
      expect(find.text('Season 2'), findsOneWidget);
    },
  );

  testWidgets('detail revision refreshes Resume and uses the server position', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final catalog = _PlaybackCatalog();
    int? startedAt;
    Widget build(int revision) => MaterialApp(
      home: Scaffold(
        body: DetailScreen(
          catalog: catalog,
          item: catalog.episode,
          revision: revision,
          onOpen: (_) {},
          onPlay:
              (
                item, {
                startTicks,
                audioIndex,
                subtitleIndex,
                burnSubtitles,
              }) async {
                startedAt = startTicks;
              },
        ),
      ),
    );
    await tester.pumpWidget(build(0));
    await tester.pumpAndSettle();
    expect(find.text('Resume'), findsNothing);
    catalog.ticks = 50000000;
    await tester.pumpWidget(build(1));
    await tester.pumpAndSettle();
    expect(find.text('Resume'), findsOneWidget);
    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    expect(startedAt, 50000000);
  });
}
