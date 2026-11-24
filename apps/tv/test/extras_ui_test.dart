import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/app_state.dart';
import 'package:zorofin_tv/core/session_store.dart';
import 'package:zorofin_tv/main.dart';
import 'package:zorofin_tv/ui/screens/notifications_panel.dart';

Future<AppState> _preview(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final state = AppState(await SessionStore.open(), deviceName: 'Test TV');
  await tester.pumpWidget(ZorofinTvApp(state: state));
  state.openPreview();
  await tester.pumpAndSettle();
  return state;
}

void main() {
  testWidgets('Back on Search returns Home without leaving the app', (
    tester,
  ) async {
    await _preview(tester);
    await tester.tap(find.bySemanticsLabel('Search').first);
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsOneWidget);
    expect(await simulateKeyDownEvent(LogicalKeyboardKey.escape), isTrue);
    expect(await simulateKeyUpEvent(LogicalKeyboardKey.escape), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsNothing);
  });

  testWidgets('Back closes the account menu without leaving the app', (
    tester,
  ) async {
    await _preview(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Account menu')).first);
    await tester.pumpAndSettle();

    // Android TV leaves the app on an unhandled Back key up, so both edges
    // of a Back that closed the menu must count as handled.
    expect(await simulateKeyDownEvent(LogicalKeyboardKey.escape), isTrue);
    await tester.pumpAndSettle();
    expect(await simulateKeyUpEvent(LogicalKeyboardKey.escape), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Change server'), findsNothing);

    // Back from Home's content goes to the Home tab first, as on Apple TV.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(await simulateKeyDownEvent(LogicalKeyboardKey.escape), isTrue);
    expect(await simulateKeyUpEvent(LogicalKeyboardKey.escape), isTrue);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<Semantics>()
          ?.properties
          .label,
      'Home',
    );

    // With nothing left to close, Back reaches the platform again.
    expect(await simulateKeyDownEvent(LogicalKeyboardKey.escape), isFalse);
    expect(await simulateKeyUpEvent(LogicalKeyboardKey.escape), isFalse);
  });

  testWidgets('the account menu opens under the avatar on a 2x TV', (
    tester,
  ) async {
    // Android TVs usually report 960x540 at 2x, so the 1920x1080 canvas is
    // scaled down by half.
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SessionStore.open(), deviceName: 'Test TV');
    await tester.pumpWidget(ZorofinTvApp(state: state));
    state.openPreview();
    await tester.pumpAndSettle();

    final avatar = tester.getRect(
      find.bySemanticsLabel(RegExp('^Account menu')).first,
    );
    await tester.tap(find.bySemanticsLabel(RegExp('^Account menu')).first);
    await tester.pumpAndSettle();
    final close = tester.getRect(
      find.bySemanticsLabel('Close account menu').last,
    );
    expect(close.top, greaterThanOrEqualTo(avatar.bottom));
    expect(close.top - avatar.bottom, lessThan(30));
    expect((close.right - avatar.right).abs(), lessThan(20));
  });

  testWidgets('the bell shows unread updates and the inbox hides seen ones', (
    tester,
  ) async {
    await _preview(tester);
    expect(find.bySemanticsLabel('Support'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Notifications, 2 unread updates'),
      findsOneWidget,
    );
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Notifications, 2 unread updates'));
    await tester.pumpAndSettle();
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('The Last Lighthouse'), findsOneWidget);
    expect(find.text('Ready to watch'), findsOneWidget);
    expect(find.text('Support reply'), findsOneWidget);

    // Rows count as seen after a dwell, but stay put while the inbox is open.
    await tester.pump(SeenAfterDwell.dwell * 2);
    await tester.pumpAndSettle();
    expect(find.text('The Last Lighthouse'), findsOneWidget);
    expect(find.text('Hidden (2)'), findsNothing);

    // Back closes the inbox; reopening files seen items under Hidden.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(NotificationInbox), findsNothing);
    expect(
      find.bySemanticsLabel('Notifications, 0 unread updates'),
      findsOneWidget,
    );
    await tester.tap(find.bySemanticsLabel('Notifications, 0 unread updates'));
    await tester.pumpAndSettle();
    expect(find.text('You\'re all caught up'), findsOneWidget);
    expect(find.text('Hidden (2)'), findsOneWidget);
    await tester.tap(find.text('Hidden (2)'));
    await tester.pumpAndSettle();
    expect(find.text('The Last Lighthouse'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Close notifications'));
    await tester.pumpAndSettle();
    expect(find.byType(NotificationInbox), findsNothing);
  });

  testWidgets('support previews the form without sending', (tester) async {
    await _preview(tester);
    await tester.tap(find.bySemanticsLabel('Support'));
    await tester.pumpAndSettle();
    expect(find.text('Preview only · No report will be sent'), findsOneWidget);
    expect(find.text('How can we help?'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('^Issue, Playback / buffering problem')),
      findsOneWidget,
    );
    await tester.tap(find.byType(EditableText).last);
    await tester.pump();
    await tester.enterText(find.byType(EditableText).last, 'Stalls');
    await tester.pumpAndSettle();
    expect(find.text('6/1,500'), findsOneWidget);
    expect(find.textContaining('Sending as'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('How can we help?'), findsNothing);
  });

  testWidgets('Profile lists the server modules and public pages', (
    tester,
  ) async {
    await _preview(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Account menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    for (final row in [
      'Notification settings',
      'Privacy Policy',
      'App Support',
    ]) {
      await tester.ensureVisible(find.text(row));
      await tester.pumpAndSettle();
      expect(find.text(row), findsOneWidget);
    }
    await tester.ensureVisible(find.text('Privacy Policy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();
    expect(find.text('Updated October 25, 2026'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Notification settings'));
    await tester.pumpAndSettle();
    expect(find.text('Show unread badge'), findsOneWidget);
    expect(
      find.textContaining('does not provide email or push alert settings'),
      findsOneWidget,
    );
  });
}
