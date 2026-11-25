import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/web_connections.dart';
import 'package:zorofin_tv/core/saved_connections.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/core/errors.dart';

class TestVault implements ConnectionVault {
  String? value;
  bool fail = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String next) async {
    if (fail) throw StateError('offline vault');
    value = next;
  }
}

Session session(String server, [String id = 'viewer']) => Session(
  server: ServerAddress.fromUserInput(server),
  viewer: Viewer(id: id, name: 'Viewer'),
  token: 'test-token',
  deviceId: 'device',
);
void main() {
  test(
    'TV asks for other saved viewers on the active server, including signed-out viewers',
    () async {
      final vault = TestVault();
      final store = WebConnections(vault: vault);
      final a = await store.remember(session('https://one.test'), 'Library');
      await store.remember(session('https://two.test'), 'Library');
      await store.select(a);
      expect((await store.list())['launchId'], a);
      final b = await store.remember(
        session('https://one.test', 'second'),
        'Library',
      );
      await store.signOut(b);
      await store.select(a);
      expect((await store.list())['launchId'], isNull);
      final saved = SavedConnections.fromJson(jsonDecode(vault.value!));
      expect(saved.launchAccount(sharedDevice: false)?.id, a);
    },
  );
  test(
    'saved account selectors contain no credentials or server address',
    () async {
      final vault = TestVault(), store = WebConnections(vault: TestVault());
      final protected = WebConnections(vault: vault);
      await protected.remember(session('https://example.test/base'), 'Library');
      final selector = jsonEncode(await protected.list());
      expect(selector, isNot(contains('test-token')));
      expect(selector, isNot(contains('example.test')));
      expect((await store.list())['accounts'], isEmpty);
    },
  );
  test(
    'concurrent saves preserve distinct server and viewer identities',
    () async {
      final store = WebConnections(vault: TestVault());
      final ids = await Future.wait([
        store.remember(session('https://one.test'), 'Same name'),
        store.remember(session('https://two.test'), 'Same name'),
        store.remember(session('https://one.test', 'other'), 'Same name'),
      ]);
      expect(ids.toSet().length, 3);
      expect(((await store.list())['accounts'] as List).length, 3);
      await store.signOut(ids.first);
      expect((await store.get(ids.first))!.session, isNull);
      expect((await store.get(ids.last))!.session, isNotNull);
    },
  );
  test(
    'failed writes do not erase previous saved accounts or poison later operations',
    () async {
      final vault = TestVault(), store = WebConnections(vault: null);
      expect((await store.list())['supported'], false);
      final active = WebConnections(vault: vault);
      final id = await active.remember(
        session('https://example.test'),
        'Library',
      );
      final previous = vault.value;
      vault.fail = true;
      await expectLater(
        active.signOut(id),
        throwsA(const ClientError(ClientErrorKind.storage)),
      );
      expect(vault.value, previous);
      vault.fail = false;
      await active.signOut(id);
      expect((await active.get(id))!.session, isNull);
    },
  );
  test(
    'corrupt vault data is surfaced instead of silently resetting accounts',
    () async {
      final vault = TestVault()..value = 'broken';
      final store = WebConnections(vault: vault);
      await expectLater(
        store.remember(session('https://example.test'), 'Library'),
        throwsA(const ClientError(ClientErrorKind.storage)),
      );
      expect(vault.value, 'broken');
    },
  );
}
