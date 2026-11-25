import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/catalog.dart';
import 'package:zorofin_tv/core/errors.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/preview_catalog.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/ui/screens/collections_screen.dart';

class _CollectionsCatalog extends PreviewCatalog {
  _CollectionsCatalog(this.read);
  final Future<ItemPage> Function(int) read;
  @override
  Future<ItemPage> collections({String? parentId, int start = 0}) =>
      read(start);
}

MediaItem box(String id) => MediaItem(id: id, name: id, type: 'BoxSet');

// Deferred with the owner-paused 1.4 validation lane; no device claims.
void main() {
  test(
    'collection reads are authenticated, bounded and validate parent type',
    () async {
      final reads = <http.Request>[];
      final server = ServerAddress.parse('https://example.test/jellyfin');
      final transport = MockClient((request) async {
        reads.add(request);
        return http.Response(
          jsonEncode(
            request.url.path.endsWith('/film')
                ? {'Id': 'film', 'Name': 'Film', 'Type': 'Movie'}
                : {'Items': [], 'TotalRecordCount': 0},
          ),
          200,
        );
      });
      addTearDown(transport.close);
      final client = JellyfinClient(
        server: server,
        identity: const ClientIdentity(deviceId: 'fixture', deviceName: 'Test'),
        session: Session(
          server: server,
          viewer: Viewer(id: 'viewer', name: 'Viewer'),
          token: 'fixture-token',
          deviceId: 'fixture',
        ),
        httpClient: transport,
      );
      final catalog = JellyfinCatalog(client);
      await catalog.collections(start: -10);
      final q = reads.single.url.queryParameters;
      expect(reads.single.method, 'GET');
      expect(reads.single.headers['Authorization'], contains('fixture-token'));
      expect(q['userId'], 'viewer');
      expect(q['includeItemTypes'], 'BoxSet');
      expect(q['startIndex'], '0');
      expect(q['limit'], '48');
      expect(q['recursive'], 'true');
      await expectLater(
        catalog.collections(parentId: 'film'),
        throwsA(isA<ClientError>()),
      );
      expect(reads.length, 2); // item validation only; no member request.
      expect(reads.every((r) => r.method == 'GET'), isTrue);
    },
  );
  testWidgets('late collection results cannot cross a catalog/account change', (
    tester,
  ) async {
    final old = Completer<ItemPage>();
    final first = _CollectionsCatalog((_) => old.future);
    final second = _CollectionsCatalog(
      (_) async => ItemPage(items: [box('new-account')]),
    );
    Widget page(Catalog catalog) => MaterialApp(
      home: Scaffold(
        body: CollectionsHomeShelf(
          catalog: catalog,
          mobile: true,
          onOpen: (_) {},
          onBrowseAll: () {},
        ),
      ),
    );
    await tester.pumpWidget(page(first));
    await tester.pumpWidget(page(second));
    await tester.pump();
    expect(find.text('new-account'), findsWidgets);
    old.complete(ItemPage(items: [box('old-account')]));
    await tester.pump();
    expect(find.text('old-account'), findsNothing);
    expect(find.text('Browse all'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'a repeated collection page stops paging without duplicate posters',
    (tester) async {
      final offsets = <int>[];
      final catalog = _CollectionsCatalog((start) async {
        offsets.add(start);
        return ItemPage(items: [box('one')], totalRecordCount: 4);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CollectionsScreen(
            catalog: catalog,
            mobile: true,
            onOpen: (_) {},
            onBack: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.ensureVisible(find.text('More titles'));
      await tester.tap(find.text('More titles'));
      await tester.pump();
      expect(offsets, [0, 1]);
      expect(find.text('More titles'), findsNothing);
      expect(find.byKey(const ValueKey('one')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
