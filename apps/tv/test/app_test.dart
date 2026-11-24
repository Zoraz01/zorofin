import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/app_state.dart';
import 'package:zorofin_tv/core/session_store.dart';
import 'package:zorofin_tv/main.dart';

Future<AppState> _state() async {
  SharedPreferences.setMockInitialValues({});
  return AppState(await SessionStore.open(), deviceName: 'Test TV');
}

void main() {
  testWidgets('starts on an empty server field with a preview option', (
    tester,
  ) async {
    await tester.pumpWidget(ZorofinTvApp(state: await _state()));
    await tester.pumpAndSettle();
    expect(find.text('Connect to\nyour server.'), findsOneWidget);
    expect(find.text('Explore the app preview'), findsOneWidget);
  });

  testWidgets('a focused field opens the keyboard only when selected', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ZorofinTvApp(state: await _state()));
    await tester.pumpAndSettle();

    // The address field starts focused without the keyboard.
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isFalse);

    // OK opens it; Down closes it and moves on.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);

    // What's typed is echoed at the top, clear of the TV keyboard.
    tester.testTextInput.enterText('192.168.1.20:8096');
    await tester.pumpAndSettle();
    final echo = find.text('192.168.1.20:8096');
    expect(echo, findsNWidgets(2));
    expect(tester.getTopLeft(echo.last).dy, lessThan(120));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(field.focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(echo, findsOneWidget);

    // Back on Android TV hides the keyboard without a key event; the field
    // stops editing so the next Down moves on.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(field.focusNode.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    await tester.pumpAndSettle();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets(
    'preview Home matches the Apple TV layout and remote opens details',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final state = await _state();
      await tester.pumpWidget(ZorofinTvApp(state: state));
      state.openPreview();
      await tester.pumpAndSettle();
      expect(find.text('APP PREVIEW · FICTIONAL LIBRARY'), findsOneWidget);
      for (final tab in ['Home', 'Movies', 'TV Shows', 'Live TV']) {
        expect(find.text(tab), findsOneWidget);
      }
      expect(find.text('Continue Watching'), findsOneWidget);
      expect(
        find.text('Recently Added Movies', skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('The Last Light'), findsWidgets);

      // Hero Play has focus; Right moves to the details button, OK opens it.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('MOVIE'), findsOneWidget);
      expect(find.text('Every ending is a new beginning.'), findsOneWidget);
      expect(find.text('Genres'), findsOneWidget);
      expect(find.text('More Like This'), findsOneWidget);
      expect(find.text('Dolby Vision'), findsOneWidget);
      expect(find.text('Dolby Atmos'), findsOneWidget);

      // Detail Play has focus; preview titles are not playable.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.textContaining('fictional titles'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel(RegExp('^Subtitles, ')));
      await tester.pumpAndSettle();
      expect(find.text('Automatic'), findsOneWidget);
      await tester.tap(find.text('Off'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Subtitles, Off'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('File details'));
      await tester.pumpAndSettle();
      expect(find.text('File format'), findsOneWidget);
      expect(find.textContaining('Source file information'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('MOVIE'), findsNothing);
      expect(
        find.text('Recently Added Movies', skipOffstage: false),
        findsOneWidget,
      );
    },
  );

  testWidgets('series details browse seasons and episodes', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = await _state();
    await tester.pumpWidget(ZorofinTvApp(state: state));
    state.openPreview();
    await tester.pumpAndSettle();
    await tester.tap(find.text('TV Shows'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Orbital').first);
    await tester.pumpAndSettle();

    expect(find.text('SERIES'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Next episode · S1 E1 · Arrival'), findsOneWidget);
    expect(find.text('Seasons & episodes'), findsOneWidget);
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('1. Arrival'), findsOneWidget);
    expect(find.text('Current episode'), findsOneWidget);

    await tester.tap(find.text('2. The Signal'));
    await tester.pumpAndSettle();
    expect(find.text('EPISODE'), findsOneWidget);
    expect(find.text('S1 E2 · The Signal'), findsOneWidget);
    expect(find.text('View series'), findsOneWidget);
  });

  testWidgets('profile settings save device preferences', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = await _state();
    await tester.pumpWidget(ZorofinTvApp(state: state));
    state.openPreview();
    await tester.pumpAndSettle();
    await tester.tap(find.text('P'));
    await tester.pumpAndSettle();
    expect(find.text('Change server'), findsOneWidget);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    for (final row in [
      'Change account',
      'Account',
      'Quick Connect',
      'Display',
      'Playback',
      'Subtitles',
      'Controls',
      'Storage & app',
      'Leave preview',
    ]) {
      expect(find.text(row), findsOneWidget);
    }

    await tester.tap(find.text('Controls'));
    await tester.pumpAndSettle();
    expect(find.text('30 seconds'), findsOneWidget);
    await tester.tap(find.text('Skip forward'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15 seconds').last);
    await tester.pumpAndSettle();
    expect(
      state.preferences.skipForward,
      30,
      reason: 'drafts are not stored before Save',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(state.preferences.skipForward, 15);
    expect(find.text('Saved'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Storage & app'), findsOneWidget);
  });
}
