import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/app_state.dart';
import 'package:zorofin_tv/core/session_store.dart';
import 'package:zorofin_tv/main.dart';

void main() {
  testWidgets('preview search recommends, finds and reports no match', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SessionStore.open(), deviceName: 'Test TV');
    await tester.pumpWidget(ZorofinTvApp(state: state));
    state.openPreview();
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel(RegExp('^Search')).first);
    await tester.pumpAndSettle();
    expect(find.text('Recommended'), findsOneWidget);

    await tester.tap(find.byType(EditableText));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'North');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Northbound'), findsWidgets);
    expect(find.text('Recommended'), findsNothing);

    await tester.tap(find.byType(EditableText));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'zzzz');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('No matching titles'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Recommended'), findsOneWidget);
  });
}
