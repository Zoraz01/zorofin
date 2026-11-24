import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/catalog.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/preview_catalog.dart';
import 'package:zorofin_tv/ui/screens/detail_screen.dart';

/// A long season served 30 episodes at a time.
class _LongSeason extends PreviewCatalog {
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
    return ItemPage(
      items: all.skip(start).take(limit).toList(),
      totalRecordCount: all.length,
    );
  }
}

void main() {
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
