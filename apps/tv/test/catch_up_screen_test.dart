import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/plugin_extras.dart';
import 'package:zorofin_tv/core/preview_catalog.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/ui/screens/catch_up_screen.dart';
import 'package:zorofin_tv/ui/screens/settings_screen.dart';

class _Catalog extends PreviewCatalog {
  late final JellyfinClient _client;
  final watched = <String>[];
  final liked = <String>[];
  final paths = <String>[];
  Completer<bool>? save;
  _Catalog() {
    final server = ServerAddress.parse('https://media.example/jellyfin');
    _client = JellyfinClient(
      server: server,
      identity: const ClientIdentity(
        deviceId: 'fixture',
        deviceName: 'Fixture',
      ),
      session: Session(
        server: server,
        viewer: Viewer(id: 'viewer', name: 'Viewer'),
        token: 'fixture',
        deviceId: 'fixture',
      ),
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path.endsWith('/Items')) {
          return http.Response(
            jsonEncode({
              'Items': [
                for (final id in ['first', 'second'])
                  {
                    'Id': id,
                    'Name': '$id movie',
                    'Type': 'Movie',
                    'Overview': 'Sample description',
                    'UserData': {'Played': false},
                  },
              ],
              'TotalRecordCount': 2,
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/taste')) {
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({'schemaVersion': 1, 'likedItemIds': []}),
              200,
            );
          }
          final body = jsonDecode(request.body) as Map;
          expect(body['action'], 'like');
          liked.add(body['itemId'] as String);
          if (save != null && !await save!.future) {
            return http.Response('{}', 500);
          }
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'likedItemIds': [body['itemId']],
            }),
            200,
          );
        }
        return http.Response('', 204);
      }),
    );
  }
  @override
  JellyfinClient get client => _client;
  @override
  Uri? artwork(MediaItem item, {required bool landscape, required int width}) =>
      null;
  @override
  Future<bool> setPlayed(MediaItem item, bool value) async {
    watched.add(item.id);
    return save == null ? true : await save!.future;
  }
}

Future<(_Catalog, Map<String, List<String>>)> mount(
  WidgetTester tester, {
  bool phone = true,
}) async {
  await tester.binding.setSurfaceSize(
    phone ? const Size(390, 844) : const Size(1280, 900),
  );
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final catalog = _Catalog(), store = <String, List<String>>{};
  final skips = CatchUpSkips(
    read: (key) => store[key],
    write: (key, value) => store[key] = value,
    server: 'fixture',
    viewerId: 'viewer',
  );
  Widget page = CatchUpScreen(catalog: catalog, skips: skips);
  if (phone) page = CompactSettings(child: page);
  await tester.pumpWidget(MaterialApp(home: page));
  await tester.pumpAndSettle();
  return (catalog, store);
}

void main() {
  testWidgets(
    'phone vertical movement is not a decision; left swipe skips and can be undone',
    (tester) async {
      final (catalog, store) = await mount(tester);
      expect(find.text('Play'), findsNothing);
      expect(find.text('View details'), findsNothing);
      expect(find.text('Watch later'), findsNothing);
      final card = find.byKey(const ValueKey('catch-up-card-first'));
      await tester.drag(card, const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(catalog.watched, isEmpty);
      expect(find.text('first movie'), findsOneWidget);
      await tester.drag(card, const Offset(-150, 0));
      await tester.pumpAndSettle();
      expect(find.text('second movie'), findsOneWidget);
      expect(store.values.single, ['first']);
      expect(catalog.watched, isEmpty);
      await tester.ensureVisible(find.text('Undo skip'));
      await tester.tap(find.text('Undo skip'));
      await tester.pumpAndSettle();
      expect(find.text('first movie'), findsOneWidget);
      expect(store.values.single, isEmpty);
      expect(catalog.paths.any((p) => p.contains('/Rating')), isFalse);
    },
  );
  testWidgets(
    'right swipe saves recommendation Like once; a failed save retains the card for retry',
    (tester) async {
      final (catalog, _) = await mount(tester);
      catalog.save = Completer<bool>();
      await tester.drag(
        find.byKey(const ValueKey('catch-up-card-first')),
        const Offset(150, 0),
      );
      await tester.pump();
      await tester.tap(find.text('Like'), warnIfMissed: false);
      await tester.pump();
      expect(catalog.liked, ['first']);
      expect(catalog.watched, isEmpty);
      catalog.save!.complete(false);
      await tester.pumpAndSettle();
      expect(find.text('first movie'), findsOneWidget);
      expect(find.text('Couldn’t save your like. Try again.'), findsOneWidget);
      catalog.save = null;
      await tester.tap(find.text('Like'));
      await tester.pumpAndSettle();
      expect(find.text('second movie'), findsOneWidget);
      expect(catalog.liked, ['first', 'first']);
      expect(catalog.watched, isEmpty);
      expect(catalog.paths.any((p) => p.contains('/Rating')), isFalse);
    },
  );
  testWidgets('thumb arc commits Like after initial vertical movement', (
    tester,
  ) async {
    final (catalog, _) = await mount(tester);
    final card = find.byKey(const ValueKey('catch-up-card-first'));
    final gesture = await tester.startGesture(tester.getCenter(card));
    await gesture.moveBy(const Offset(0, 28));
    await gesture.moveBy(const Offset(140, 20));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(catalog.liked, ['first']);
    expect(catalog.watched, isEmpty);
    expect(find.text('second movie'), findsOneWidget);
  });
  testWidgets(
    'short directional flick skips; a cancelled gesture makes no choice',
    (tester) async {
      final (catalog, store) = await mount(tester);
      final card = find.byKey(const ValueKey('catch-up-card-first'));
      final cancelled = await tester.startGesture(tester.getCenter(card));
      await cancelled.moveBy(const Offset(100, 0));
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(catalog.liked, isEmpty);
      expect(store, isEmpty);
      await tester.fling(card, const Offset(-60, -20), 1200);
      await tester.pumpAndSettle();
      expect(store.values.single, ['first']);
      expect(catalog.watched, isEmpty);
    },
  );
  testWidgets('a two-finger gesture never chooses a title', (tester) async {
    final (catalog, store) = await mount(tester);
    final card = find.byKey(const ValueKey('catch-up-card-first'));
    final point = tester.getCenter(card);
    final first = await tester.startGesture(point, pointer: 1);
    final second = await tester.startGesture(
      point + const Offset(8, 8),
      pointer: 2,
    );
    await first.moveBy(const Offset(145, 10));
    await second.up();
    await first.up();
    await tester.pumpAndSettle();
    expect(catalog.liked, isEmpty);
    expect(store, isEmpty);
    expect(card, findsOneWidget);
  });

  testWidgets(
    'TV keeps remote choices without phone swipe gestures or playback actions',
    (tester) async {
      final (catalog, _) = await mount(tester, phone: false);
      expect(find.byKey(const ValueKey('catch-up-card-first')), findsNothing);
      expect(find.text('Skip'), findsOneWidget);
      expect(find.text('Like'), findsOneWidget);
      expect(find.text('View details'), findsNothing);
      expect(find.text('Watch later'), findsNothing);
      expect(find.text('Play'), findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'catch-up-skip');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(catalog.watched, isEmpty);
      expect(catalog.liked, ['first']);
      expect(find.text('second movie'), findsOneWidget);
    },
  );
}
