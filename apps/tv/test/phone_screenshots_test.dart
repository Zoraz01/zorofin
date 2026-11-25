// Renders phone and tablet screens to PNG for review. Skipped unless
// ZOROFIN_SCREENSHOTS names an output folder:
//   ZOROFIN_SCREENSHOTS=/tmp/shots flutter test test/phone_screenshots_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/app_state.dart';
import 'package:zorofin_tv/core/session_store.dart';
import 'package:zorofin_tv/phone/phone_app.dart';

final _out = Platform.environment['ZOROFIN_SCREENSHOTS'];

Future<void> _fonts() async {
  final inter = FontLoader('Inter')
    ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
  await inter.load();
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ?? '/opt/sdk/flutter';
  final icons = File(
    '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  final loader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(await icons.readAsBytes())));
  await loader.load();
}

Future<void> _shot(WidgetTester tester, String name) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await expectLater(
    find.byType(ZorofinPhoneApp),
    matchesGoldenFile(Uri.file('$_out/$name.png')),
  );
}

Future<void> _run(WidgetTester tester, Size size, String prefix) async {
  await tester.runAsync(_fonts);
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 120, bottom: 60);
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final state = AppState(await SessionStore.open(), deviceName: 'Shots');
  await tester.pumpWidget(ZorofinPhoneApp(state: state));
  await _shot(tester, '${prefix}01-connect');
  state.openPreview();
  await _shot(tester, '${prefix}02-home');
  await tester.tap(find.byTooltip(RegExp(r'^Details for ')).first);
  await _shot(tester, '${prefix}03-details');
  await tester.pageBack();
  await _shot(tester, '${prefix}02-home');
  for (final (tab, file) in [
    ('Search', '04-search'),
    ('Requests', '05-requests'),
    ('Profile', '06-profile'),
  ]) {
    await tester.tap(find.bySemanticsLabel(tab).last);
    await _shot(tester, '$prefix$file');
  }
  await tester.tap(find.text('Downloads'));
  await _shot(tester, '${prefix}07-downloads');
  await tester.pageBack();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(find.text('Home & display'));
  await _shot(tester, '${prefix}08-display-settings');
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('phone screens', (tester) async {
    await _run(tester, const Size(393, 852), 'phone-');
  }, skip: _out == null);
  testWidgets('tablet screens', (tester) async {
    await _run(tester, const Size(1194, 834), 'tablet-');
  }, skip: _out == null);
}
