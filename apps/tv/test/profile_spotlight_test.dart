import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/profile_spotlight.dart';
import 'package:zorofin_tv/core/profile_spotlight_store.dart';
import 'package:zorofin_tv/ui/widgets/profile_backdrop.dart';

MediaItem _episode(String id, {String? backdrop, String? still}) => MediaItem(
  id: id,
  name: 'The Long Dark',
  type: 'Episode',
  seriesName: 'Northbound',
  parentIndexNumber: 2,
  indexNumber: 4,
  runTimeTicks: 1000,
  userData: UserData(playbackPositionTicks: 300),
  parentBackdropItemId: backdrop == null ? null : 'show',
  parentBackdropImageTags: backdrop == null ? const [] : [backdrop],
  imageTags: still == null ? const {} : {'Primary': still},
);

void main() {
  test('show backdrop leads and the episode still is the thumbnail', () {
    final spot = ProfileSpotlight.pick([
      _episode('e1', backdrop: 'b', still: 's'),
    ])!;
    expect(spot.title, 'Northbound');
    expect(spot.detail, 'S2 E4 · The Long Dark');
    expect(spot.line, 'Northbound · S2 E4 · The Long Dark');
    expect(spot.backdrop, const SpotlightImage('show', 'Backdrop', 'b'));
    expect(spot.thumbnail, const SpotlightImage('e1', 'Primary', 's'));
    expect(spot.progress, closeTo(0.3, 1e-9));
  });

  test('first item with art wins; no art still names the title', () {
    expect(
      ProfileSpotlight.pick([_episode('bare'), _episode('art', backdrop: 'b')])!
          .itemId,
      'art',
    );
    expect(ProfileSpotlight.pick(const []), isNull);
    expect(ProfileSpotlight.pick([_episode('bare')])!.backdrop, isNull);
  });

  test('store round-trips, prunes removed accounts and clears', () async {
    SharedPreferences.setMockInitialValues({'unrelated': 'keep'});
    final prefs = await SharedPreferences.getInstance();
    final store = ProfileSpotlightStore(prefs);
    final spot = ProfileSpotlight.pick([_episode('e', backdrop: 'b')])!;
    await store.save('kept', spot);
    await store.save('gone', spot);
    expect(store.load('kept')!.backdrop, spot.backdrop);
    await store.prune({'kept'});
    expect(store.load('gone'), isNull);
    expect(store.load('kept'), isNotNull);
    expect(prefs.getString('unrelated'), 'keep');
    await store.save('kept', null);
    expect(store.load('kept'), isNull);
  });

  test('scene avatar matches Apple, LG and Roku (sum of bytes mod 7)', () {
    const id = '8C5A3F2E9B6D4E1FA0B2C3D4E5F60718';
    expect(sceneAvatarFor(id), sceneAvatarFor(id.toLowerCase()));
    expect(sceneAvatarFor('a'), sceneAvatars[97 % 7]);
    expect(sceneAvatarAsset('a'), 'assets/images/scene-${sceneAvatars[6]}.jpg');
  });

  testWidgets('spotlight card shows who was watching what', (tester) async {
    final spot = ProfileSpotlight.pick([_episode('e', backdrop: 'b')])!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileSpotlightCard(name: 'Maya', spotlight: spot, tv: true),
        ),
      ),
    );
    expect(find.text('Maya was watching'), findsOneWidget);
    expect(find.text('Northbound · S2 E4 · The Long Dark'), findsOneWidget);
  });
}
