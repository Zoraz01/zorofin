import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/web_frontend.dart';
import 'package:zorofin_tv/core/errors.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/saved_connections.dart';
import 'package:zorofin_tv/core/server_address.dart';

class AvatarVault implements ConnectionVault {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String next) async {
    value = next;
  }
}

http.Response json(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);
const viewer = {
  'Id': 'viewer1',
  'Name': 'Viewer',
  'Policy': {'SyncPlayAccess': 'None'},
};
Future<void> login(WebFrontend app) async {
  await app.call('connect', {
    'address': 'https://example.test/jellyfin',
    'deviceId': 'device',
  });
  await app.call('login', {'username': 'Viewer', 'password': 'test-password'});
}

void main() {
  test('Home contract changes discard a pending plugin response', () async {
    var version = 2;
    final started = Completer<void>(), pending = Completer<http.Response>();
    final app = WebFrontend(
      transport: () => MockClient((r) async {
        if (r.url.path.endsWith('/Public')) return json({'Id': 'server'});
        if (r.url.path.endsWith('/AuthenticateByName')) {
          return json({'AccessToken': 'token', 'User': viewer});
        }
        if (r.url.path.endsWith('/Capabilities')) {
          return json({
            'schemaVersion': 1,
            'features': {
              'homeRows': {'version': version, 'enabled': version != 0},
              'homeSections': {'version': 1, 'enabled': true},
            },
          });
        }
        if (r.url.path.endsWith('/Zorofin/Home/Rows')) {
          started.complete();
          return pending.future;
        }
        if (r.url.path.contains('/DisplayPreferences/')) {
          return json({'CustomPrefs': {}});
        }
        return json({'Items': [], 'TotalRecordCount': 0});
      }),
    );
    await login(app);
    final old = app.call('homeRows', {'snapshot': true});
    await started.future;
    final rejected = expectLater(
      old,
      throwsA(const ClientError(ClientErrorKind.invalidResponse)),
    );
    version = 0;
    final features = await app.call('features', {'refresh': true}) as Map;
    expect(features['homeRowsVersion'], 0);
    pending.complete(
      json({
        'schemaVersion': 1,
        'generatedAt': '2026-11-05T12:00:00Z',
        'preferences': {
          'hiddenRows': [],
          'teams': [],
          'minutes': 90,
          'theme': 'automatic',
        },
        'rows': [],
      }),
    );
    await rejected;
    app.reset();
  });

  test(
    'account switching discards late Home rows and keeps the new server token',
    () async {
      final started = Completer<void>(), pending = Completer<http.Response>();
      final requests = <http.Request>[];
      final app = WebFrontend(
        transport: () => MockClient((r) async {
          requests.add(r);
          if (r.url.path.endsWith('/Public')) return json({'Id': r.url.host});
          if (r.url.path.endsWith('/AuthenticateByName')) {
            return json({'AccessToken': r.url.host, 'User': viewer});
          }
          if (r.url.path.endsWith('/Capabilities')) {
            return json({
              'schemaVersion': 1,
              'features': {
                'homeRows': {'version': 2, 'enabled': true},
              },
            });
          }
          if (r.url.path.endsWith('/Zorofin/Home/Rows')) {
            if (r.url.host == 'example.test') {
              started.complete();
              return pending.future;
            }
            return json({
              'schemaVersion': 1,
              'generatedAt': '2026-11-05T12:00:00Z',
              'preferences': {
                'hiddenRows': [],
                'teams': [],
                'minutes': 90,
                'theme': 'automatic',
              },
              'rows': [],
            });
          }
          return json({'Items': [], 'TotalRecordCount': 0});
        }),
      );
      await login(app);
      final old = app.call('homeRows', {});
      await started.future;
      final rejected = expectLater(
        old,
        throwsA(const ClientError(ClientErrorKind.missingSession)),
      );
      app.reset();
      await app.call('connect', {
        'address': 'https://other.test/base',
        'deviceId': 'device',
      });
      await app.call('login', {'username': 'Viewer', 'password': 'fixture'});
      expect(await app.call('homeRows', {}), isEmpty);
      pending.complete(
        json({
          'schemaVersion': 1,
          'generatedAt': '2026-11-05T12:00:00Z',
          'preferences': {
            'hiddenRows': [],
            'teams': [],
            'minutes': 90,
            'theme': 'automatic',
          },
          'rows': [],
        }),
      );
      await rejected;
      final own = requests
          .where(
            (r) =>
                r.url.host == 'other.test' &&
                r.url.path.endsWith('/Zorofin/Home/Rows'),
          )
          .single;
      expect(own.url.path, '/base/Zorofin/Home/Rows');
      expect(own.headers['X-Jellyfin-Token'], 'other.test');
      app.reset();
    },
  );

  test(
    'saved avatars use each account token and origin; same-server add preserves the vault',
    () async {
      final vault = AvatarVault(), requests = <http.Request>[];
      final app = WebFrontend(
        connectionVault: vault,
        transport: () => MockClient((r) async {
          requests.add(r);
          if (r.url.path.endsWith('/Public')) {
            return json({'Id': 'server', 'ServerName': 'Library'});
          }
          return http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );
      Session saved(String host, String token) => Session(
        server: ServerAddress.fromUserInput(host),
        viewer: Viewer(
          id: 'viewer',
          name: 'Same name',
          primaryImageTag: 'photo',
        ),
        token: token,
        deviceId: 'device',
      );
      final first = await app.connections.remember(
        saved('https://one.test', 'one-token'),
        'Same server name',
      );
      final second = await app.connections.remember(
        saved('https://two.test', 'two-token'),
        'Same server name',
      );
      final snapshot = vault.value;
      expect(await app.image(first, 'saved-viewer', 96), [1, 2, 3]);
      expect(await app.image(second, 'saved-viewer', 96), [1, 2, 3]);
      expect(requests[0].url.host, 'one.test');
      expect(requests[0].headers['Authorization'], contains('one-token'));
      expect(
        requests[0].headers['Authorization'],
        isNot(contains('two-token')),
      );
      expect(requests[1].url.host, 'two.test');
      expect(requests[1].headers['Authorization'], contains('two-token'));
      final picker = await app.call('accounts', {}) as Map;
      expect((picker['servers'] as List).length, 2);
      expect(jsonEncode(picker), isNot(contains('.test')));
      expect(jsonEncode(picker), isNot(contains('-token')));
      final connection =
          await app.call('connectServer', {'id': first, 'deviceId': 'device'})
              as Map;
      expect(connection['needsSignIn'], true);
      expect(connection['viewer'], isNull);
      expect(vault.value, snapshot);
      await expectLater(
        app.call('home', {}),
        throwsA(const ClientError(ClientErrorKind.missingSession)),
      );
      app.reset();
    },
  );
  test(
    'a saved profile\'s spotlight picture uses that profile\'s own session',
    () async {
      final requests = <http.BaseRequest>[];
      final app = WebFrontend(
        connectionVault: AvatarVault(),
        transport: () => MockClient((request) async {
          requests.add(request);
          return http.Response.bytes(
            [4, 5, 6],
            200,
            headers: {'content-type': 'image/jpeg'},
          );
        }),
      );
      Session saved(String host, String token) => Session(
        server: ServerAddress.fromUserInput(host),
        viewer: Viewer(id: 'viewer', name: 'Viewer'),
        token: token,
        deviceId: 'device',
      );
      final first = await app.connections.remember(
        saved('https://one.test', 'one-token'),
        'Library',
      );
      await app.connections.remember(
        saved('https://two.test', 'two-token'),
        'Library',
      );
      expect(await app.image(first, 'saved-art:item1:Backdrop:tag1', 1280), [
        4,
        5,
        6,
      ]);
      expect(requests.single.url.host, 'one.test');
      expect(requests.single.url.path, contains('/Items/item1/Images/Backdrop'));
      expect(requests.single.url.toString(), isNot(contains('one-token')));
      expect(requests.single.headers['Authorization'], contains('one-token'));
      // Only picture kinds are accepted, and unknown accounts get nothing.
      expect(await app.image(first, 'saved-art:item1:Logo:tag1', 1280), isNull);
      expect(await app.image('nobody', 'saved-art:i:Thumb:t', 1280), isNull);
      expect(requests.length, 1);
      app.reset();
    },
  );
  test(
    'late saved avatar data is discarded after the account signs out',
    () async {
      final pending = Completer<http.Response>(), vault = AvatarVault();
      final app = WebFrontend(
        connectionVault: vault,
        transport: () => MockClient((_) => pending.future),
      );
      final id = await app.connections.remember(
        Session(
          server: ServerAddress.fromUserInput('https://example.test'),
          viewer: Viewer(
            id: 'viewer',
            name: 'Viewer',
            primaryImageTag: 'photo',
          ),
          token: 'token',
          deviceId: 'device',
        ),
        'Library',
      );
      final image = app.image(id, 'saved-viewer', 96);
      await Future<void>.delayed(Duration.zero);
      await app.connections.signOut(id);
      pending.complete(http.Response.bytes([1, 2, 3], 200));
      expect(await image, isNull);
      app.reset();
    },
  );

  test('restricted viewer policy prevents Home live-event API calls', () async {
    final paths = <String>[];
    final app = WebFrontend(
      transport: () => MockClient((r) async {
        paths.add(r.url.path);
        if (r.url.path.endsWith('/Public')) return json({'Id': 'server'});
        if (r.url.path.endsWith('/AuthenticateByName')) {
          return json({
            'AccessToken': 'token',
            'User': {
              ...viewer,
              'Policy': {'EnableLiveTvAccess': false},
            },
          });
        }
        return json({}, 404);
      }),
    );
    await login(app);
    expect((await app.call('features', {}) as Map)['liveTV'], false);
    expect(await app.call('liveEvents', {}), isEmpty);
    expect(paths.where((p) => p.contains('/LiveTv/')), isEmpty);
    app.reset();
  });

  test(
    'switching sign-in method rejects late credentials and allows the next attempt',
    () async {
      final pending = Completer<http.Response>();
      var attempts = 0;
      final app = WebFrontend(
        transport: () => MockClient((r) async {
          if (r.url.path.endsWith('/Public')) {
            return json({'Id': 'server', 'ServerName': 'Library'});
          }
          if (r.url.path.endsWith('/AuthenticateByName')) {
            if (++attempts == 1) return pending.future;
            return json({'AccessToken': 'new-token', 'User': viewer});
          }
          return json({});
        }),
      );
      final connection = await app.call('connect', {
        'address': 'https://example.test',
        'deviceId': 'device',
      });
      expect((connection as Map)['serverAddress'], 'https://example.test/');
      final old = app.call('login', {'username': 'Viewer', 'password': 'test'});
      final check = expectLater(
        old,
        throwsA(const ClientError(ClientErrorKind.missingSession)),
      );
      await Future<void>.delayed(Duration.zero);
      await app.call('cancelSignIn', {});
      pending.complete(json({'AccessToken': 'old-token', 'User': viewer}));
      await check;
      await expectLater(
        app.call('home', {}),
        throwsA(const ClientError(ClientErrorKind.missingSession)),
      );
      await app.call('login', {'username': 'Viewer', 'password': 'test'});
      expect((await app.call('identity', {}) as Map)['viewer'], 'Viewer');
      app.reset();
    },
  );

  test('Home order appends stably without duplicating pinned rows', () async {
    final app = WebFrontend();
    await app.call('preview', {});
    final first = List<String>.from(
      await app.call('homeOrder', {
            'reset': true,
            'rows': [
              {'id': 'shelf-0'},
              {'id': 'requests-ready'},
              {'id': 'library'},
              {'id': 'discovery', 'generated': true},
            ],
          })
          as List,
    );
    expect(first.toSet(), {'library', 'discovery'});
    final second =
        await app.call('homeOrder', {
              'rows': [
                {'id': 'library'},
                {'id': 'another', 'generated': true},
              ],
            })
            as List;
    expect(second.take(first.length), first);
    expect(second.last, 'another');
    app.reset();
  });
  test(
    'preview cannot open administrator handoffs or guessed request notices',
    () async {
      final app = WebFrontend();
      await app.call('preview', {});
      // Complete each assertion before reset invalidates this account scope.
      await expectLater(
        app.call('adminHandoff', {'path': 'dashboard'}),
        throwsA(const ClientError(ClientErrorKind.forbidden)),
      );
      await expectLater(
        app.call('openNotice', {'id': 7}),
        throwsA(const ClientError(ClientErrorKind.forbidden)),
      );
      app.reset();
    },
  );

  test(
    'preview uses shared catalog without network or credential output',
    () async {
      final app = WebFrontend(
        transport: () => throw StateError('network forbidden'),
      );
      await app.call('preview', {});
      final home = await app.call('home', {}) as Map;
      expect((home['rows'] as List).length, greaterThan(0));
      expect(jsonEncode(home), isNot(contains('token')));
      final page = await app.call('browse', {'kind': 'shows'}) as Map;
      expect((page['items'] as List).first['type'], 'Series');
      app.reset();
    },
  );
  test('public HTTP is rejected before any transport is created', () async {
    final app = WebFrontend(
      transport: () => throw StateError('network forbidden'),
    );
    await expectLater(
      app.call('connect', {
        'address': 'http://example.test',
        'localHttp': true,
        'deviceId': 'device',
      }),
      throwsA(const ClientError(ClientErrorKind.insecureServer)),
    );
  });
  test(
    'login credentials stay out of identity; paging retains base-path and session',
    () async {
      final requests = <http.Request>[];
      final app = WebFrontend(
        transport: () => MockClient((r) async {
          requests.add(r);
          if (r.url.path.endsWith('/Public')) {
            return json({'Id': 'server', 'ServerName': 'Library'});
          }
          if (r.url.path.endsWith('/AuthenticateByName')) {
            return json({'AccessToken': 'secret-token', 'User': viewer});
          }
          return json({
            'Items': [
              {'Id': 'movie1', 'Name': 'Movie', 'Overview': '<b>Text</b>'},
            ],
            'TotalRecordCount': 200,
          });
        }),
      );
      await login(app);
      final identity = await app.call('identity', {});
      expect(jsonEncode(identity), isNot(contains('secret-token')));
      final page =
          await app.call('browse', {'kind': 'movies', 'start': 60}) as Map;
      expect(page['total'], 200);
      expect((page['items'] as List).first['overview'], 'Text');
      final request = requests.last;
      expect(request.url.path.startsWith('/jellyfin/'), true);
      expect(request.url.queryParameters['startIndex'], '60');
      expect(request.headers['Authorization'], contains('secret-token'));
      expect(request.followRedirects, false);
      app.reset();
    },
  );
  test('late login cannot restore a session after reset', () async {
    final pending = Completer<http.Response>();
    final app = WebFrontend(
      transport: () => MockClient((r) async {
        if (r.url.path.endsWith('/Public')) return json({'Id': 'server'});
        return pending.future;
      }),
    );
    await app.call('connect', {
      'address': 'https://example.test',
      'deviceId': 'device',
    });
    final response = app.call('login', {
      'username': 'Viewer',
      'password': 'test',
    });
    app.reset();
    pending.complete(json({'AccessToken': 'old-token', 'User': viewer}));
    await expectLater(
      response,
      throwsA(const ClientError(ClientErrorKind.missingSession)),
    );
    await expectLater(
      app.call('identity', {}),
      throwsA(const ClientError(ClientErrorKind.missingSession)),
    );
  });
  test('failed server logout still clears local session', () async {
    final app = WebFrontend(
      transport: () => MockClient((r) async {
        if (r.url.path.endsWith('/Public')) return json({'Id': 'server'});
        if (r.url.path.endsWith('/AuthenticateByName')) {
          return json({'AccessToken': 'secret-token', 'User': viewer});
        }
        return json({}, 503);
      }),
    );
    await login(app);
    await expectLater(app.call('logout', {}), throwsA(isA<ClientError>()));
    await expectLater(
      app.call('identity', {}),
      throwsA(const ClientError(ClientErrorKind.missingSession)),
    );
  });
  test(
    'Home bridge keeps the cross-season first suggestion ahead of old resumes',
    () async {
      final app = WebFrontend(
        transport: () => MockClient((r) async {
          if (r.url.path.endsWith('/Public')) return json({'Id': 'server'});
          if (r.url.path.endsWith('/AuthenticateByName')) {
            return json({'AccessToken': 'token', 'User': viewer});
          }
          if (r.url.path.endsWith('/Resume')) {
            return json({
              'Items': [
                for (var i = 0; i < 20; i++)
                  {
                    'Id': 'old-$i',
                    'Name': 'Old $i',
                    'Type': 'Movie',
                    'UserData': {'PlaybackPositionTicks': 100},
                  },
              ],
            });
          }
          if (r.url.path.endsWith('/NextUp')) {
            return json({
              'Items': [
                {
                  'Id': 'premiere',
                  'Name': 'Premiere',
                  'Type': 'Episode',
                  'SeriesId': 'show',
                  'ParentIndexNumber': 4,
                  'IndexNumber': 1,
                },
              ],
            });
          }
          return json({'Items': []});
        }),
      );
      addTearDown(app.reset);
      await login(app);
      final home = await app.call('home', {}) as Map;
      final rows = home['rows'] as List;
      expect(rows, hasLength(1));
      expect(rows.first['title'], 'Continue Watching');
      final items = rows.first['items'] as List;
      expect(items.map((i) => i['id']), [
        'premiere',
        for (var i = 0; i < 20; i++) 'old-$i',
      ]);
      expect(items.first['resumeTicks'], 0);
      expect(items[1]['resumeTicks'], 100);
    },
  );

  test(
    'Home starts independent sources together and requests Resume once',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      final paths = <Uri>[];
      final app = WebFrontend(
        transport: () => MockClient((r) async {
          if (r.url.path.endsWith('/Public')) return json({'Id': 'server'});
          if (r.url.path.endsWith('/AuthenticateByName')) {
            return json({'AccessToken': 'token', 'User': viewer});
          }
          paths.add(r.url);
          if (paths.length == 5) started.complete();
          await release.future;
          if (r.url.queryParameters['includeItemTypes'] == 'Series') {
            return json({}, 503);
          }
          if (r.url.queryParameters['includeItemTypes'] == 'Movie') {
            return json({
              'Items': [
                {'Id': 'movie', 'Name': 'Movie', 'Type': 'Movie'},
              ],
            });
          }
          return json({'Items': []});
        }),
      );
      await login(app);
      final pending = app.call('home', {});
      await started.future.timeout(const Duration(seconds: 2));
      release.complete();
      final home = await pending as Map;
      expect(paths.where((p) => p.path.endsWith('/Resume')), hasLength(1));
      expect(home['partial'], true);
      expect((home['rows'] as List).map((r) => r['title']), [
        'Recently Added Movies',
      ]);
      app.reset();
    },
  );

  test(
    'optional Home failures preserve client rows and share capability discovery',
    () async {
      var manifests = 0, serverRows = 0, movieReads = 0;
      final app = WebFrontend(
        transport: () => MockClient((r) async {
          if (r.url.path.endsWith('/Public')) return json({'Id': 'server'});
          if (r.url.path.endsWith('/AuthenticateByName')) {
            return json({'AccessToken': 'token', 'User': viewer});
          }
          if (r.url.path.endsWith('/Capabilities')) {
            manifests++;
            return json({
              'schemaVersion': 1,
              'features': {
                'homeRows': {'version': 1, 'enabled': true},
              },
            });
          }
          if (r.url.path.endsWith('/support/home/rows')) {
            serverRows++;
            return json({}, 403);
          }
          if (r.url.path.contains('/DisplayPreferences/')) return json({}, 503);
          if (r.url.queryParameters['includeItemTypes'] == 'Movie') {
            movieReads++;
            return json({
              'Items': [
                {
                  'Id': 'short',
                  'Name': 'Short film',
                  'Type': 'Movie',
                  'RunTimeTicks': 36000000000,
                  'CommunityRating': 8,
                  'LocationType': 'FileSystem',
                  'UserData': {'Played': false},
                },
              ],
              'TotalRecordCount': 1,
            });
          }
          return json({'Items': [], 'TotalRecordCount': 0});
        }),
      );
      await login(app);
      final result = await Future.wait([
        app.call('homeRows', {}),
        app.call('features', {}),
      ]);
      expect(manifests, 1);
      expect(serverRows, 1);
      expect(movieReads, 1);
      final rows = result[0] as List;
      expect(
        (rows.singleWhere((r) => r['id'] == 'short-movies')['items'] as List)
            .single['id'],
        'short',
      );
      expect(rows.map((r) => r['id']).toSet().length, rows.length);
      app.reset();
    },
  );

  test('an expired session in Home remains an authentication error', () async {
    final app = WebFrontend(
      transport: () => MockClient((r) async {
        if (r.url.path.endsWith('/Public')) return json({'Id': 'server'});
        if (r.url.path.endsWith('/AuthenticateByName')) {
          return json({'AccessToken': 'token', 'User': viewer});
        }
        if (r.url.path.endsWith('/Resume') ||
            r.url.path.endsWith('/Items') ||
            r.url.path.contains('/DisplayPreferences/') ||
            r.url.path.endsWith('/Capabilities')) {
          return json({}, 401);
        }
        return json({'Items': []});
      }),
    );
    await login(app);
    await expectLater(
      app.call('home', {}),
      throwsA(const ClientError(ClientErrorKind.unauthorized)),
    );
    await expectLater(
      app.call('homeRows', {}),
      throwsA(const ClientError(ClientErrorKind.unauthorized)),
    );
    app.reset();
  });

  test(
    'guide program paging handles short pages and filters unrelated or invalid intervals',
    () async {
      var pages = 0;
      final requests = <http.Request>[];
      final app = WebFrontend(
        transport: () => MockClient((r) async {
          if (r.url.path.endsWith('/Public')) return json({'Id': 'server'});
          if (r.url.path.endsWith('/AuthenticateByName')) {
            return json({'AccessToken': 'secret', 'User': viewer});
          }
          requests.add(r);
          final entries = [
            {
              'Id': 'p',
              'ChannelId': 'c',
              'Name': 'Show',
              'StartDate': '2026-11-04T10:00:00Z',
              'EndDate': '2026-11-04T11:00:00Z',
            },
            {
              'Id': 'bad',
              'ChannelId': 'other',
              'Name': 'Other',
              'StartDate': '2026-11-04T10:00:00Z',
              'EndDate': '2026-11-04T11:00:00Z',
            },
            {
              'Id': 'invalid',
              'ChannelId': 'c',
              'Name': 'Invalid',
              'StartDate': '2026-11-04T11:00:00Z',
              'EndDate': '2026-11-04T10:00:00Z',
            },
          ];
          return json({
            'Items': [entries[pages++]],
            'TotalRecordCount': 3,
          });
        }),
      );
      await login(app);
      final result =
          await app.call('guidePrograms', {
                'ids': ['c'],
                'start': '2026-11-04T10:00:00Z',
              })
              as List;
      expect(result.length, 1);
      expect(result.first['name'], 'Show');
      expect(pages, 3);
      expect(requests.map((r) => r.url.queryParameters['startIndex']), [
        '0',
        '1',
        '2',
      ]);
      expect(
        requests.every(
          (r) =>
              r.method == 'GET' && r.url.queryParameters['userId'] == 'viewer1',
        ),
        true,
      );
      app.reset();
    },
  );
  test(
    'guide rejects a server repeating a page and invalid channel lists',
    () async {
      var pages = 0;
      final app = WebFrontend(
        transport: () => MockClient((r) async {
          if (r.url.path.endsWith('/Public')) return json({'Id': 'server'});
          if (r.url.path.endsWith('/AuthenticateByName')) {
            return json({'AccessToken': 'secret', 'User': viewer});
          }
          pages++;
          return json({
            'Items': [
              {
                'Id': 'p',
                'ChannelId': 'c',
                'Name': 'Show',
                'StartDate': '2026-11-04T10:00:00Z',
                'EndDate': '2026-11-04T11:00:00Z',
              },
            ],
            'TotalRecordCount': 200,
          });
        }),
      );
      await login(app);
      await expectLater(
        app.call('guidePrograms', {
          'ids': ['c'],
          'start': '2026-11-04T10:00:00Z',
        }),
        throwsA(const ClientError(ClientErrorKind.invalidResponse)),
      );
      expect(pages, 2);
      await expectLater(
        app.call('guidePrograms', {
          'ids': ['c,other'],
          'start': '2026-11-04T10:00:00Z',
        }),
        throwsA(const ClientError(ClientErrorKind.invalidResponse)),
      );
      app.reset();
    },
  );
  test(
    'LG Collections use viewer-scoped ordinary Jellyfin pages and reject non-collections',
    () async {
      final reads = <Uri>[];
      final app = WebFrontend(
        transport: () => MockClient((r) async {
          if (r.url.path.endsWith('/Public')) return json({'Id': 'server'});
          if (r.url.path.endsWith('/AuthenticateByName')) {
            return json({'AccessToken': 'token', 'User': viewer});
          }
          if (r.url.path.endsWith('/Items/film')) {
            return json({'Id': 'film', 'Name': 'Film', 'Type': 'Movie'});
          }
          if (r.url.path.endsWith('/Items')) {
            reads.add(r.url);
            expect(r.headers['Authorization'], contains('Token="token"'));
            final parent = r.url.queryParameters['parentId'];
            return json({
              'Items': [
                {
                  'Id': parent == null ? 'box' : 'member',
                  'Name': 'Title',
                  'Type': parent == null ? 'BoxSet' : 'Movie',
                },
              ],
              'TotalRecordCount': 96,
            });
          }
          return json({'Items': [], 'TotalRecordCount': 0});
        }),
      );
      await login(app);
      await app.call('collections', {'start': 48});
      expect(reads.last.queryParameters['includeItemTypes'], 'BoxSet');
      expect(reads.last.queryParameters['startIndex'], '48');
      expect(reads.last.queryParameters['userId'], 'viewer1');
      await app.call('collectionItems', {'id': 'box', 'start': 0});
      expect(reads.last.queryParameters['parentId'], 'box');
      expect(reads.last.queryParameters['recursive'], 'false');
      expect(reads.every((u) => u.path.startsWith('/jellyfin/')), true);
      await expectLater(
        app.call('collectionItems', {'id': 'film'}),
        throwsA(isA<ClientError>()),
      );
      await app.call('reset', {});
    },
  );
}
