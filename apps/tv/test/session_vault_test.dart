import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/app_state.dart';
import 'package:zorofin_tv/core/errors.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/core/session_store.dart';

class FakeVault implements ConnectionVault {
  String? value;
  bool failRead = false, failWrite = false, discardWrite = false;
  @override
  Future<String?> read() async {
    if (failRead) throw StateError('read');
    return value;
  }

  @override
  Future<void> write(String text) async {
    if (failWrite) throw StateError('write');
    if (!discardWrite) value = text;
  }
}

Session session(String host, String token) => Session(
  server: ServerAddress.parse('https://$host.example'),
  viewer: Viewer(id: 'same-user', name: 'Viewer'),
  token: token,
  deviceId: 'device',
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeVault vault;
  setUp(() {
    vault = FakeVault();
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'migrates all accounts, keeps server isolation and active choice',
    () async {
      final saved = SavedConnections();
      saved.remember(session('one', 'token-one'), 'One');
      final active = saved.remember(session('two', 'token-two'), 'Two');
      SharedPreferences.setMockInitialValues({
        'zorofin.connections.v1': jsonEncode(saved.toJson()),
        'zorofin.device.v1': 'device',
      });
      final store = await SessionStore.open(vault: vault);
      expect(store.load().activeId, active);
      expect(store.load().accounts.map((a) => a.session!.token), [
        'token-one',
        'token-two',
      ]);
      expect(store.prefs.containsKey('zorofin.connections.v1'), false);
      expect(store.deviceId(), 'device');
      final reopened = await SessionStore.open(vault: vault);
      expect(reopened.load().activeId, active);
    },
  );

  test(
    'failed writes and failed verification preserve the legacy session',
    () async {
      final text = jsonEncode(session('one', 'token').toJson());
      SharedPreferences.setMockInitialValues({'zorofin.session.v1': text});
      vault.failWrite = true;
      await expectLater(
        SessionStore.open(vault: vault),
        throwsA(const ClientError(ClientErrorKind.storage)),
      );
      expect(
        (await SharedPreferences.getInstance()).getString('zorofin.session.v1'),
        text,
      );
      vault.failWrite = false;
      vault.discardWrite = true;
      await expectLater(
        SessionStore.open(vault: vault),
        throwsA(const ClientError(ClientErrorKind.storage)),
      );
      expect(
        (await SharedPreferences.getInstance()).getString('zorofin.session.v1'),
        text,
      );
      vault.discardWrite = false;
      expect((await SessionStore.open(vault: vault)).load().accounts.length, 1);
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          'zorofin.session.v1',
        ),
        false,
      );
    },
  );

  test(
    'unreadable vault does not reset data or fall back to preferences',
    () async {
      vault.value = 'corrupt';
      SharedPreferences.setMockInitialValues({
        'zorofin.session.v1': jsonEncode(session('one', 'old').toJson()),
      });
      await expectLater(
        SessionStore.open(vault: vault),
        throwsA(const ClientError(ClientErrorKind.storage)),
      );
      expect(vault.value, 'corrupt');
      vault.failRead = true;
      await expectLater(
        SessionStore.open(vault: vault),
        throwsA(const ClientError(ClientErrorKind.storage)),
      );
      expect(vault.value, 'corrupt');
    },
  );

  test(
    'verified encrypted state wins over a stale interrupted migration',
    () async {
      final saved = SavedConnections()..remember(session('one', 'new'), 'One');
      vault.value = jsonEncode(saved.toJson());
      SharedPreferences.setMockInitialValues({
        'zorofin.session.v1': jsonEncode(session('one', 'old').toJson()),
      });
      final store = await SessionStore.open(vault: vault);
      expect(store.load().accounts.single.session!.token, 'new');
      expect(store.prefs.containsKey('zorofin.session.v1'), false);
    },
  );

  test(
    'temporary sign-in is not persisted and sign-out removes saved token',
    () async {
      final store = await SessionStore.open(vault: vault);
      final state = AppState(store, deviceName: 'TV');
      await state.signedIn(session('one', 'temporary'), remember: false);
      expect(vault.value, isNot(contains('temporary')));
      await state.signedIn(session('one', 'remembered'));
      final id = state.connections.activeId!;
      // Expiration avoids a real network logout in this unit test.
      await state.expire(id);
      expect(vault.value, isNot(contains('remembered')));
      expect(state.connections.accounts.single.session, isNull);
      expect((await SessionStore.open(vault: vault)).load().active, isNull);
      expect(
        store.prefs.getKeys().where((k) => k.contains('connections')),
        isEmpty,
      );
    },
  );

  test('failed save does not add a phantom signed-in account', () async {
    final state = AppState(
      await SessionStore.open(vault: vault),
      deviceName: 'TV',
    );
    vault.failWrite = true;
    await expectLater(
      state.signedIn(session('one', 'unsaved')),
      throwsA(const ClientError(ClientErrorKind.storage)),
    );
    expect(state.connections.accounts, isEmpty);
    expect(state.catalog, isNull);
    vault.failWrite = false;
    await state.signedIn(session('one', 'saved'));
    expect(state.connections.accounts.single.session!.token, 'saved');
  });

  test(
    'queued cleanup cannot be overwritten by an earlier account write',
    () async {
      final store = await SessionStore.open(vault: vault);
      final saved = SavedConnections();
      final id = saved.remember(session('one', 'remove-me'), 'One');
      final first = store.save(saved);
      saved.signOut(id);
      final second = store.save(saved);
      await Future.wait([first, second]);
      expect(vault.value, isNot(contains('remove-me')));
    },
  );
}
