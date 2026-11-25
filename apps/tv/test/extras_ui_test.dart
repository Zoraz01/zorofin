import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/app_state.dart';
import 'package:zorofin_tv/extras_state.dart';
import 'package:zorofin_tv/core/preview_catalog.dart';
import 'package:zorofin_tv/core/requests.dart';
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
    expect(find.text('SWITCH PROFILE'), findsNothing);

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

  testWidgets('opening a reply marks it seen without waiting for dwell', (
    tester,
  ) async {
    await _preview(tester);
    await tester.tap(find.bySemanticsLabel('Notifications, 2 unread updates'));
    await tester.pump();
    await tester.tap(find.text('Support reply'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Close notifications'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Notifications, 1 unread updates'));
    await tester.pump();
    expect(find.text('Support reply'), findsNothing);
    expect(find.text('Hidden (1)'), findsOneWidget);
    await tester.tap(find.text('Hidden (1)'));
    await tester.pump();
    expect(find.text('Support reply'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('scaled TV inbox only marks mostly visible rows seen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final extras = ExtrasState(
      catalog: PreviewCatalog(),
      storage: await SharedPreferences.getInstance(),
    );
    extras.replies = [];
    extras.requestNotices = [
      for (var i = 1; i <= 8; i++)
        RequestAvailabilityNotice(
          id: i,
          kind: RequestKind.movie,
          titleId: i,
          title: 'Update $i',
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 280,
            height: 200,
            child: FittedBox(
              child: SizedBox(
                width: 560,
                height: 400,
                child: NotificationInbox(
                  extras: extras,
                  onClose: () {},
                  onOpen: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(SeenAfterDwell.dwell * 2);
    await tester.pump();
    expect(extras.requestReadIds, {1, 2});
    await tester.pumpWidget(const SizedBox());
    extras.dispose();
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
    expect(find.text('Notifications'), findsOneWidget);
    await tester.tap(find.text('Help & about'));
    await tester.pumpAndSettle();
    for (final row in ['Privacy Policy', 'App Support', 'Version']) {
      await tester.ensureVisible(find.text(row));
      await tester.pumpAndSettle();
      expect(find.text(row), findsOneWidget);
    }
    await tester.ensureVisible(find.text('Privacy Policy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();
    expect(find.text('Updated November 7, 2026'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();
    // The badge switch lives on Home & display on TV.
    expect(find.text('Show unread badge'), findsNothing);
    expect(
      find.textContaining('does not provide email or push alert settings'),
      findsOneWidget,
    );
  });
}
