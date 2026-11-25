import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/core/session_store.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/core/sync_play_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  SavedConnections saved() => SavedConnections()
    ..remember(
      Session(
        server: ServerAddress.parse('https://media.example'),
        viewer: Viewer(id: 'viewer', name: 'Viewer'),
        token: 'private-test-token',
        deviceId: 'test-device',
      ),
      'Library',
    );

  test(
    'temporary web sessions never persist tokens and expire on reopen',
    () async {
      final store = await SessionStore.open(persistentConnections: false);
      expect(store.supportsPersistentSignIn, false);
      await store.save(saved());
      expect(store.load().accounts.single.session!.token, 'private-test-token');
      expect(
        store.prefs.getKeys().where(
          (k) => k.contains('session') || k.contains('connections'),
        ),
        isEmpty,
      );
      final reopened = await SessionStore.open(persistentConnections: false);
      expect(reopened.load().accounts, isEmpty);
    },
  );

  test(
    'temporary sessions migrate old token storage into memory and remove it',
    () async {
      SharedPreferences.setMockInitialValues({
        'zorofin.connections.v1': jsonEncode(saved().toJson()),
      });
      final store = await SessionStore.open(persistentConnections: false);
      expect(store.load().accounts.single.session!.token, 'private-test-token');
      expect(store.prefs.containsKey('zorofin.connections.v1'), false);
      expect(
        (await SessionStore.open(persistentConnections: false)).load().accounts,
        isEmpty,
      );
    },
  );

  test(
    'both socket transports reject malformed, binary and oversized events',
    () async {
      final result = await decodeSyncPlayMessages(
        Stream.fromIterable([
          'not-json',
          '[]',
          [1, 2],
          'x' * (1024 * 1024 + 1),
          '{"MessageType":"SyncPlayGroupUpdate","Data":{"GroupId":"one"}}',
        ]),
      ).toList();
      expect(result, [
        {
          'MessageType': 'SyncPlayGroupUpdate',
          'Data': {'GroupId': 'one'},
        },
      ]);
    },
  );
}
