import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/app_state.dart';
import 'package:zorofin_tv/core/session_store.dart';
import 'package:zorofin_tv/phone/phone_app.dart';
import 'package:zorofin_tv/phone/phone_detail.dart';
import 'package:zorofin_tv/phone/phone_downloads.dart';
import 'package:zorofin_tv/phone/phone_theme.dart';
import 'package:zorofin_tv/ui/widgets/media_card.dart';

Future<AppState> _state() async {
  SharedPreferences.setMockInitialValues({});
  return AppState(await SessionStore.open(), deviceName: 'Test Android');
}

/// Logical sizes: a 6.1" phone and an 11" tablet in landscape.
const _phone = Size(393, 852);
const _tablet = Size(1194, 834);

void _use(WidgetTester tester, Size size) {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// Periodic Home refreshes stop once the app is gone.
Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<AppState> _openPreview(WidgetTester tester) async {
  final state = await _state();
  await tester.pumpWidget(ZorofinPhoneApp(state: state));
  await _settle(tester);
  state.openPreview();
  await _settle(tester);
  return state;
}

void main() {
  testWidgets('phone starts on the connect screen with a preview option', (
    tester,
  ) async {
    _use(tester, _phone);
    await tester.pumpWidget(ZorofinPhoneApp(state: await _state()));
    await _settle(tester);
    expect(find.text('Connect to\nyour server.'), findsOneWidget);
    expect(find.text('Explore the app preview'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('phone preview shows Home with the floating dock', (
    tester,
  ) async {
    _use(tester, _phone);
    await _openPreview(tester);
    expect(find.text('APP PREVIEW · FICTIONAL LIBRARY'), findsOneWidget);
    for (final tab in ['Home', 'Search', 'Requests', 'Profile']) {
      expect(find.bySemanticsLabel(tab), findsWidgets, reason: tab);
    }
    expect(find.text('Continue Watching'), findsWidgets);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('dock switches sections and Profile lists settings', (
    tester,
  ) async {
    _use(tester, _phone);
    await _openPreview(tester);

    await tester.tap(find.bySemanticsLabel('Search').last);
    await _settle(tester);
    expect(find.text('Movies, shows and more'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Requests').last);
    await _settle(tester);
    expect(find.text('Search movies and TV shows'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Profile').last);
    await _settle(tester);
    expect(find.text('SWITCH PROFILE'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Downloads'), findsOneWidget);
    // The same six Settings pages as every TV; Quick Connect lives in Account.
    for (final page in [
      'Account',
      'Home & display',
      'Playback',
      'Subtitles',
      'Notifications',
      'Help & about',
    ]) {
      expect(find.text(page), findsOneWidget, reason: page);
    }
    expect(find.text('Quick Connect'), findsNothing);
    expect(find.text('Leave preview'), findsOneWidget);

    // Settings pages are the grouped TV pages at touch sizes: the player
    // controls sit in Playback and changes save as you go.
    await tester.tap(find.text('Playback'));
    await _settle(tester);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('Playback'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('Show chapters'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Show chapters'), findsOneWidget);
    expect(find.text('Save'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await _settle(tester);

    await tester.ensureVisible(find.text('Help & about'));
    await _settle(tester);
    await tester.tap(find.text('Help & about'));
    await _settle(tester);
    expect(find.text('App Support'), findsOneWidget);
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('a title opens details with Play and track choices', (
    tester,
  ) async {
    _use(tester, _phone);
    await _openPreview(tester);

    final detailsButton = find.byTooltip(RegExp(r'^Details for '));
    expect(detailsButton, findsWidgets);
    await tester.tap(detailsButton.first);
    await _settle(tester);
    expect(find.byType(PhoneDetailScreen), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            const ['Play', 'Resume', 'Play next episode'].contains(w.data),
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp('^Mark (un)?watched')), findsWidgets);
    expect(tester.takeException(), isNull);

    // Back returns Home.
    await tester.pageBack();
    await _settle(tester);
    expect(find.byType(PhoneDetailScreen), findsNothing);
    await _close(tester);
  });

  testWidgets('tablet uses the full-width bar and the wide banner', (
    tester,
  ) async {
    _use(tester, _tablet);
    await _openPreview(tester);
    expect(PhoneWindow(_tablet).tablet, isTrue);
    expect(find.text('APP PREVIEW · FICTIONAL LIBRARY'), findsOneWidget);
    expect(find.bySemanticsLabel('Profile'), findsWidgets);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('landscape keeps Home clear of a side navigation bar', (
    tester,
  ) async {
    _use(tester, const Size(852, 393));
    tester.view.padding = const FakeViewPadding(right: 48 * 3);
    await _openPreview(tester);
    final search = tester.getRect(find.byTooltip('Search').first);
    expect(search.right, lessThanOrEqualTo(852 - 48));
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('the keyboard is counted once on Search', (tester) async {
    _use(tester, _phone);
    await _openPreview(tester);
    await tester.tap(find.bySemanticsLabel('Search').last);
    await _settle(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300 * 3);
    await _settle(tester);
    // The page fills down to the keyboard, not the keyboard plus the dock.
    final page = tester.getRect(find.byType(CustomScrollView).last);
    expect(page.bottom, closeTo(852 - 300, 1));
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  test('window classes follow the iPhone and iPad breakpoints', () {
    expect(const PhoneWindow(_phone).tablet, isFalse);
    expect(const PhoneWindow(_phone).gridColumns(), 2);
    expect(const PhoneWindow(Size(852, 393)).wide, isFalse);
    expect(const PhoneWindow(_tablet).wide, isTrue);
    expect(const PhoneWindow(_tablet).gridColumns(), greaterThan(4));
    // A sideways phone gets a short banner that clears the dock.
    expect(const PhoneWindow(Size(852, 393)).landscapePhone, isTrue);
    expect(const PhoneWindow(Size(852, 393)).heroHeight, lessThan(393 * 0.65));
    expect(const PhoneWindow(_phone).landscapePhone, isFalse);
  });

  test('download choices skip conversions bigger than the original', () {
    // A 10 minute, 499 MB file is about 6.7 Mbps.
    final choices = DownloadQuality.choices(
      original: true,
      originalSize: 499000000,
      runtimeSeconds: 600,
    );
    expect(choices, [DownloadQuality.original, DownloadQuality.saver]);
    // Without a size every conversion is offered.
    expect(DownloadQuality.choices(original: false), [
      DownloadQuality.high,
      DownloadQuality.standard,
      DownloadQuality.saver,
    ]);
    // A small file still offers the smallest conversion.
    expect(
      DownloadQuality.choices(
        original: false,
        originalSize: 1000,
        runtimeSeconds: 600,
      ),
      [DownloadQuality.saver],
    );
  });

  testWidgets('landscape details keep the actions above the dock', (
    tester,
  ) async {
    // A 6.7" Android phone on its side.
    _use(tester, const Size(915, 412));
    await _openPreview(tester);
    final dock = tester.getRect(find.bySemanticsLabel('Home').last);
    await tester.tap(find.byTooltip(RegExp(r'^Details for ')).first);
    await _settle(tester);
    final watched = find.bySemanticsLabel(RegExp('^Mark (un)?watched'));
    expect(watched, findsWidgets);
    expect(tester.getRect(watched.first).bottom, lessThan(dock.top));
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('landscape phone keeps Play above the dock', (tester) async {
    _use(tester, const Size(852, 393));
    await _openPreview(tester);
    final play = find.byWidgetPredicate(
      (w) => w is Text && const ['Play', 'Resume'].contains(w.data),
    );
    expect(play, findsWidgets);
    final dock = tester.getRect(find.bySemanticsLabel('Home').last);
    expect(tester.getRect(play.first).bottom, lessThan(dock.top));
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('a long word on preview art shrinks instead of breaking', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 132,
            height: 198,
            child: PreviewArtwork(title: 'Northbound', seed: 'n'),
          ),
        ),
      ),
    );
    final paragraph = tester.renderObject<RenderParagraph>(
      find.text('NORTHBOUND'),
    );
    final boxes = paragraph.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 10),
    );
    expect(boxes.map((b) => b.top).toSet(), hasLength(1));
  });
}
