import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'player_lifecycle_test.dart' show FakeVideo;
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/preview_catalog.dart';
import 'package:zorofin_tv/ui/widgets/trailer_preview_card.dart';

void main() {
  final originalLookup = TrailerPreviewCard.lookup;
  final originalFactory = TrailerPreviewCard.playerFactory;
  tearDown(() {
    TrailerPreviewCard.lookup = originalLookup;
    TrailerPreviewCard.playerFactory = originalFactory;
  });
  testWidgets('a poster looks up its trailer only after resting two seconds', (
    tester,
  ) async {
    final looked = <String>[];
    TrailerPreviewCard.lookup = (_, item) async {
      looked.add(item.id);
      return null;
    };
    final film = FocusNode(), show = FocusNode(), episode = FocusNode();
    addTearDown(() {
      film.dispose();
      show.dispose();
      episode.dispose();
    });
    final catalog = PreviewCatalog();
    Widget card(String id, String type, FocusNode node) => TrailerPreviewCard(
      item: MediaItem(id: id, name: id, type: type),
      catalog: catalog,
      focusNode: node,
      onPressed: () {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              card('film', 'Movie', film),
              card('show', 'Series', show),
              card('ep', 'Episode', episode),
            ],
          ),
        ),
      ),
    );
    film.requestFocus();
    await tester.pump(const Duration(milliseconds: 1500));
    show.requestFocus();
    await tester.pump(const Duration(milliseconds: 2100));
    episode.requestFocus();
    await tester.pump(const Duration(seconds: 3));
    expect(looked, [
      'show',
    ], reason: 'moving on cancels the dwell; episodes never preview');
  });

  testWidgets(
    'focus widens artwork before lookup and fades in moving video without resizing',
    (tester) async {
      final oldPlatform = VideoPlayerPlatform.instance;
      final platform = FakeVideo()..position = Duration.zero;
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = oldPlatform);
      TrailerPreviewCard.playerFactory = (uri) =>
          VideoPlayerController.networkUrl(uri);
      var lookups = 0;
      TrailerPreviewCard.lookup = (_, item) async {
        lookups++;
        return (
          url: Uri.parse('https://example.invalid/trailer.mp4'),
          subtitlePath: null,
        );
      };
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            child: TrailerPreviewCard(
              item: MediaItem(id: 'film', name: 'Film', type: 'Movie'),
              catalog: PreviewCatalog(),
              onPressed: () {},
              focusNode: node,
            ),
          ),
        ),
      );
      final art = find.byType(ClipRRect).first;
      final poster = tester.getSize(art);
      node.requestFocus();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final wide = tester.getSize(art);
      expect(wide.height, poster.height);
      expect(wide.width / wide.height, closeTo(16 / 9, 0.01));
      expect(lookups, 0);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(lookups, 1);
      final fade = find.ancestor(
        of: find.byType(VideoPlayer),
        matching: find.byType(AnimatedOpacity),
      );
      expect(tester.widget<AnimatedOpacity>(fade).opacity, 0);
      platform.position = const Duration(milliseconds: 100);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(tester.widget<AnimatedOpacity>(fade).opacity, 1);
      expect(tester.getSize(art), wide);
      node.unfocus();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSize(art), poster);
      expect(find.byType(VideoPlayer), findsNothing);
    },
  );
}
