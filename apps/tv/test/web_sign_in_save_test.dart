import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/saved_connections.dart';
import 'package:zorofin_tv/core/web_frontend.dart';

// The protected-vault interface is in memory here. Actual ciphertext storage is
// covered by the LG secure-storage suite and the extracted-package validation.
class SignInVault implements ConnectionVault {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String next) async {
    value = next;
  }
}

void main() {
  for (final method in ['password', 'quick']) {
    test(
      '$method sign-in saves and restores through the protected vault interface',
      () async {
        final vault = SignInVault();
        var token = 'fixture-session-one';
        WebFrontend makeApp() => WebFrontend(
          connectionVault: vault,
          vaultAvailable: () => true,
          transport: () => MockClient((request) async {
            const viewer = {
              'Id': 'viewer',
              'Name': 'Viewer',
              'Policy': {'SyncPlayAccess': 'None'},
            };
            final Object body;
            if (request.url.path.endsWith('/Public')) {
              body = {'Id': 'fixture-server', 'ServerName': 'Fixture library'};
            } else if (request.url.path.endsWith('/AuthenticateByName') ||
                request.url.path.endsWith('/AuthenticateWithQuickConnect')) {
              body = {'AccessToken': token, 'User': viewer};
            } else if (request.url.path.contains('/QuickConnect/')) {
              body = {
                'Code': '123456',
                'Secret': 'fixture-quick-secret',
                'Authenticated': true,
              };
            } else if (request.url.path.endsWith('/Users/Me')) {
              body = viewer;
            } else {
              throw StateError(
                'Unexpected sign-in fixture request: ${request.url.path}',
              );
            }
            return http.Response(jsonEncode(body), 200);
          }),
        );
        Future<void> authenticate(WebFrontend app) async {
          if (method == 'password') {
            await app.call('login', {
              'username': 'Viewer',
              'password': 'fixture-password',
            });
          } else {
            await app.call('quickStart', {});
            final result = await app.call('quickCheck', {}) as Map;
            expect(result['authenticated'], true);
          }
        }

        final app = makeApp();
        addTearDown(app.reset);
        await app.call('connect', {
          'address': 'https://example.test/jellyfin',
          'deviceId': 'fixture-device',
        });
        await authenticate(app);
        expect(
          vault.value,
          isNull,
          reason: 'authentication alone is not a vault write',
        );
        final saved = await app.call('rememberAccount', {}) as Map;
        final id = saved['savedAccountId'] as String;
        expect(id, isNotEmpty);
        expect(jsonEncode(saved), isNot(contains(token)));
        expect(vault.value, isNot(contains('fixture-password')));
        expect(vault.value, isNot(contains('fixture-quick-secret')));
        app.reset();

        final reopened = makeApp();
        addTearDown(reopened.reset);
        final restored =
            await reopened.call('selectAccount', {'id': id}) as Map;
        expect(restored['savedAccountId'], id);
        expect(restored['viewer'], 'Viewer');
        // Reauthentication updates this account instead of making a duplicate.
        token = 'fixture-session-two';
        await authenticate(reopened);
        final refreshed = await reopened.call('rememberAccount', {}) as Map;
        expect(refreshed['savedAccountId'], id);
        final records = SavedConnections.fromJson(
          jsonDecode(vault.value!) as Map<String, dynamic>,
        );
        expect(records.accounts, hasLength(1));
        expect(records.accounts.single.session!.token, token);
      },
    );
  }
}
