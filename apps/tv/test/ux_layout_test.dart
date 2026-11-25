import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/library_browse.dart';
import 'package:zorofin_tv/core/preview_catalog.dart';
import 'package:zorofin_tv/ui/theme.dart';
import 'package:zorofin_tv/ui/widgets/episode_status.dart';
import 'package:zorofin_tv/ui/widgets/library_filters.dart';
import 'package:zorofin_tv/ui/widgets/search_results.dart';

void main() {
  for (final width in [320.0, 768.0, 1920.0]) {
    testWidgets('approved controls fit at $width with large text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final out = Platform.environment['ZOROFIN_UX_SCREENSHOTS'];
      if (out != null) {
        await tester.runAsync(() async {
          await (FontLoader(
            'Inter',
          )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
          final flutterRoot = Platform.environment['FLUTTER_ROOT'];
          if (flutterRoot == null) {
            throw StateError(
              'Set FLUTTER_ROOT when rendering UX fixture screenshots.',
            );
          }
          final icons = File(
            '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          );
          await (FontLoader('MaterialIcons')..addFont(
                Future.value(ByteData.sublistView(await icons.readAsBytes())),
              ))
              .load();
        });
      }
      final catalog = PreviewCatalog();
      await tester.pumpWidget(
        MaterialApp(
          theme: Zoro.theme(),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 1500),
              textScaler: TextScaler.linear(width == 320 ? 1.6 : 1),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Fixture preview · UX refinements',
                        style: Zoro.font(18),
                      ),
                      const SizedBox(height: 16),
                      LibraryFilters(
                        options: const LibraryBrowseOptions(),
                        genres: const ['Drama', 'Adventure'],
                        onChanged: (_) {},
                      ),
                      const SizedBox(height: 16),
                      SearchTypeFilters(
                        value: 'Movie,Series',
                        onChanged: (_) {},
                      ),
                      const SizedBox(height: 16),
                      SearchResultRow(
                        item: PreviewCatalog.previewMovies.first,
                        catalog: catalog,
                        onOpen: () {},
                      ),
                      EpisodeStatus(
                        title: 'Episodes unavailable',
                        detail:
                            'Season 2 could not be loaded. Your place is saved.',
                        onRetry: () {},
                        onChooseSeason: () {},
                      ),
                      const SizedBox(height: 16),
                      const EpisodeStatus(
                        title: 'Loading episodes…',
                        detail: 'Season 2',
                        loading: true,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      if (out != null) {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(Uri.file('$out/ux-${width.toInt()}.png')),
        );
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
