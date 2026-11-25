import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/core/catalog.dart';
import 'package:zorofin_tv/core/home_recommendations.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/core/session_store.dart';

class FixtureClient extends JellyfinClient {
  FixtureClient(Session session)
    : super(
        server: session.server,
        session: session,
        identity: const ClientIdentity(
          deviceId: 'fixture-device',
          deviceName: 'Test',
        ),
      );
  @override
  Future<Viewer> currentViewer() async => session!.viewer;
}

class FixtureCatalog extends JellyfinCatalog {
  FixtureCatalog(Session session) : super(FixtureClient(session));
  int loads = 0;
  final opened = <String>[];
  Completer<List<HomeRow>>? delayed;
  final entered = Completer<void>();
  @override
  Future<List<HomeRow>> home() async {
    loads++;
    if (!entered.isCompleted) entered.complete();
    if (delayed != null) return delayed!.future;
    return [
      HomeRow('Recent', [
        for (var i = 0; i < 8; i++)
          MediaItem(id: 'item-$i', name: 'Fixture film $i', type: 'Movie'),
      ]),
    ];
  }

  @override
  Uri? backdrop(MediaItem item, {required int width}) => null;
  @override
  Uri? artwork(MediaItem item, {required bool landscape, required int width}) =>
      null;
  @override
  Future<MediaItem> item(String id) async {
    opened.add(id);
    return MediaItem(id: id, name: 'Fixture film', type: 'Movie');
  }
}

SavedAccount account(String id) {
  final server = ServerAddress.parse('https://$id.example');
  final viewer = Viewer(id: 'viewer', name: 'Fixture');
  return SavedAccount(
    id: id,
    server: server,
    serverName: 'Fixture',
    viewer: viewer,
    session: Session(
      server: server,
      viewer: viewer,
      token: 'fictional-token-$id',
      deviceId: 'fixture-device',
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late bool permission;
  late HomeRecommendations recommendations;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    permission = true;
    messenger.setMockMethodCallHandler(HomeRecommendations.channel, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'available' => true,
        'permission' => permission,
        'publish' => true,
        _ => null,
      };
    });
    recommendations = HomeRecommendations(
      await SharedPreferences.getInstance(),
    );
  });
  tearDown(() {
    recommendations.dispose();
    messenger.setMockMethodCallHandler(HomeRecommendations.channel, null);
  });
  Future<void> openCard(String owner, String item) async {
    final done = Completer<void>();
    await messenger.handlePlatformMessage(
      HomeRecommendations.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('open', {'accountId': owner, 'itemId': item}),
      ),
      (_) => done.complete(),
    );
    await done.future;
  }

  test('default off performs no library lookup and shares nothing', () async {
    final a = account('a');
    final catalog = FixtureCatalog(a.session!);
    await recommendations.use(a, catalog);
    expect(recommendations.enabled, false);
    expect(catalog.loads, 0);
    expect(calls.where((c) => c.method == 'publish'), isEmpty);
    expect(calls.lastWhere((c) => c.method == 'scope').arguments, null);
  });
  test(
    'opt-in shares at most five safe cards; disable and switch clear them',
    () async {
      final a = account('a');
      final catalog = FixtureCatalog(a.session!);
      await recommendations.use(a, catalog);
      expect(await recommendations.setEnabled(true), true);
      final payload =
          calls.lastWhere((c) => c.method == 'publish').arguments as Map;
      expect((payload['cards'] as List).length, 5);
      expect(jsonEncode(payload), isNot(contains('fictional-token')));
      expect(jsonEncode(payload), isNot(contains('.example')));
      expect(payload['accountId'], 'a');
      await recommendations.setEnabled(false);
      expect(calls.lastWhere((c) => c.method == 'scope').arguments, null);
      await recommendations.use(
        account('b'),
        FixtureCatalog(account('b').session!),
      );
      expect(recommendations.enabled, false);
      expect(calls.lastWhere((c) => c.method == 'scope').arguments, null);
    },
  );
  test(
    'declined notification permission does not save consent or publish',
    () async {
      final a = account('a');
      await recommendations.use(a, FixtureCatalog(a.session!));
      permission = false;
      expect(await recommendations.setEnabled(true), false);
      expect(recommendations.enabled, false);
      expect(calls.where((c) => c.method == 'publish'), isEmpty);
    },
  );
  test(
    'late account A fetch cannot publish after switching to account B',
    () async {
      final a = account('a');
      final catalog = FixtureCatalog(a.session!)
        ..delayed = Completer<List<HomeRow>>();
      await recommendations.use(a, catalog);
      final enabling = recommendations.setEnabled(true);
      await catalog.entered.future;
      final b = account('b');
      await recommendations.use(b, FixtureCatalog(b.session!));
      catalog.delayed!.complete([
        HomeRow('Recent', [
          MediaItem(id: 'old', name: 'Old profile film', type: 'Movie'),
        ]),
      ]);
      await enabling;
      expect(calls.where((c) => c.method == 'publish'), isEmpty);
      expect(calls.lastWhere((c) => c.method == 'scope').arguments, null);
    },
  );
  test('cards cannot open another account or a disabled profile', () async {
    final a = account('a');
    final catalog = FixtureCatalog(a.session!);
    await recommendations.use(a, catalog);
    await recommendations.setEnabled(true);
    await openCard('b', 'item-1');
    expect(catalog.opened, isEmpty);
    await openCard('a', 'item-1');
    expect(recommendations.takeOpening()?.id, 'item-1');
    await recommendations.setEnabled(false);
    await openCard('a', 'item-2');
    expect(catalog.opened, ['item-1']);
    expect(recommendations.takeOpening(), null);
    await recommendations.use(null, null);
    expect(calls.lastWhere((c) => c.method == 'scope').arguments, null);
  });
  test(
    'a warm open during initialization waits for platform availability',
    () async {
      recommendations.dispose();
      final ready = Completer<bool>();
      messenger.setMockMethodCallHandler(HomeRecommendations.channel, (
        call,
      ) async {
        calls.add(call);
        return switch (call.method) {
          'available' => ready.future,
          'permission' => true,
          'publish' => true,
          _ => null,
        };
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('zorofin.homeRecommendations.v1.a', true);
      recommendations = HomeRecommendations(prefs);
      final a = account('a');
      final catalog = FixtureCatalog(a.session!);
      final using = recommendations.use(a, catalog);
      final opening = openCard('a', 'item-1');
      ready.complete(true);
      await Future.wait([using, opening]);
      expect(recommendations.takeOpening()?.id, 'item-1');
      expect(catalog.opened, ['item-1']);
    },
  );
}
