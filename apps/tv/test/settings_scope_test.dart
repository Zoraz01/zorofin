import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/app_state.dart';
import 'package:zorofin_tv/core/preview_catalog.dart';
import 'package:zorofin_tv/core/server_extras.dart';
import 'package:zorofin_tv/core/session_store.dart';
import 'package:zorofin_tv/extras_state.dart';
import 'package:zorofin_tv/ui/screens/profile_screen.dart';

const _label = 'Send playback problem reports to this server';

Future<void> _openPage(WidgetTester tester, bool reports, String page) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final state = AppState(await SessionStore.open(), deviceName: 'Test TV');
  final catalog = PreviewCatalog();
  final extras = ExtrasState(
    catalog: catalog,
    storage: await SharedPreferences.getInstance(),
  )..features = ServerFeatures(playbackReports: reports);
  await tester.pumpWidget(
    MaterialApp(
      home: ExtrasScope(
        extras: extras,
        child: Scaffold(
          body: ProfileScreen(state: state, catalog: catalog),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(page));
  await tester.pumpAndSettle();
}

void main() {
  // Settings opens on its own route, outside the shell's subtree. The switch
  // went missing on TV because the server's features did not follow it there.
  testWidgets(
    'Help & about offers the report switch when the server collects',
    (tester) async {
      await _openPage(tester, true, 'Help & about');
      await tester.scrollUntilVisible(
        find.text(_label),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text(_label), findsOneWidget);
    },
  );

  testWidgets('Help & about hides the report switch when it does not', (
    tester,
  ) async {
    await _openPage(tester, false, 'Help & about');
    expect(find.text('Version', skipOffstage: false), findsOneWidget);
    expect(find.text(_label, skipOffstage: false), findsNothing);
  });

  testWidgets('TV remote can move from Reset to the visible Version footer', (
    tester,
  ) async {
    await _openPage(tester, true, 'Help & about');
    final reset = find.text('Reset app preferences');
    await tester.ensureVisible(reset);
    Focus.of(tester.element(reset)).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final version = find.text('Version');
    expect(Focus.of(tester.element(version)).hasPrimaryFocus, isTrue);
    expect(version.hitTestable(), findsOneWidget);
  });

  // Controls folds into Playback on TV; chapters stay off by default there.
  testWidgets('Playback holds the player controls on TV', (tester) async {
    await _openPage(tester, false, 'Playback');
    expect(find.text('Show chapters', skipOffstage: false), findsOneWidget);
    expect(find.text('Skip backward', skipOffstage: false), findsOneWidget);
    expect(find.text('Save'), findsNothing);
    expect(find.text('Done'), findsNothing);
  });
}
