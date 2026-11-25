import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/errors.dart';
import 'package:zorofin_tv/core/web_frontend.dart';

http.Response json(Object body) => http.Response(jsonEncode(body), 200);
WebFrontend frontend(
  List<http.Request> requests,
  Future<http.Response> Function(http.Request) stop,
) => WebFrontend(
  transport: () => MockClient((r) async {
    requests.add(r);
    if (r.url.path.endsWith('/Public')) {
      return json({'Id': r.url.host});
    }
    if (r.url.path.endsWith('/AuthenticateByName')) {
      return json({
        'AccessToken': r.url.host,
        'User': {'Id': 'viewer', 'Name': 'Viewer'},
      });
    }
    // Use the complete Users/Me contract so the tests reach playback reporting.
    if (r.url.path.endsWith('/Me')) {
      return json({'Id': 'viewer', 'Name': 'Viewer', 'Configuration': {}});
    }
    if (r.url.path.endsWith('/PlaybackInfo')) {
      return json({
        'PlaySessionId': 'same-server-generated-id',
        'MediaSources': [
          {'Id': 'source', 'SupportsDirectPlay': true},
        ],
      });
    }
    if (r.url.path.endsWith('/Stopped')) {
      return stop(r);
    }
    if (r.url.path.endsWith('/Items/episode')) {
      return json({
        'Id': 'episode',
        'Name': 'Episode',
        'Type': 'Episode',
        'RunTimeTicks': 3600000000,
      });
    }
    return json({});
  }),
);
Future<void> signIn(WebFrontend app, [String host = 'one.test']) async {
  await app.call('connect', {
    'address': 'https://$host/jellyfin',
    'deviceId': 'device',
  });
  await app.call('login', {'username': 'Viewer', 'password': 'fixture'});
}

Future<String> prepare(WebFrontend app) async =>
    (await app.call('prepare', {'id': 'episode', 'subtitleIndex': -1})
            as Map)['key']
        as String;
Map<String, Object> stopped(String key, [int ticks = 3600000000]) => {
  'key': key,
  'event': 'stop',
  'positionTicks': ticks,
  'paused': true,
};

void main() {
  test(
    'failed completion remains retryable with its original final position',
    () async {
      final requests = <http.Request>[];
      var attempts = 0;
      final app = frontend(
        requests,
        (r) async => http.Response('', ++attempts <= 3 ? 503 : 204),
      );
      addTearDown(app.reset);
      await signIn(app);
      final key = await prepare(app);
      await expectLater(
        app.call('report', stopped(key)),
        throwsA(isA<ClientError>()),
      );
      await app.call('report', {
        'key': key,
        'event': 'progress',
        'positionTicks': 0,
      });
      expect(requests.where((r) => r.url.path.endsWith('/Progress')), isEmpty);
      await app.call('report', stopped(key, 0));
      final stops = requests
          .where((r) => r.url.path.endsWith('/Stopped'))
          .toList();
      expect(stops, hasLength(4));
      expect(stops.map((r) => r.body).toSet(), hasLength(1));
      expect(jsonDecode(stops.last.body)['PositionTicks'], 3600000000);
      expect(
        jsonDecode(stops.last.body)['PlaySessionId'],
        'same-server-generated-id',
      );
      await app.call('report', stopped(key));
      expect(attempts, 4, reason: 'acknowledged duplicate is idempotent');
    },
  );
  test('concurrent completion and close share one request', () async {
    final requests = <http.Request>[], gate = Completer<http.Response>();
    final began = Completer<void>();
    final app = frontend(requests, (r) {
      began.complete();
      return gate.future;
    });
    addTearDown(app.reset);
    await signIn(app);
    final key = await prepare(app);
    final first = app.call('report', stopped(key));
    await began.future;
    final second = app.call('report', stopped(key, 0));
    gate.complete(http.Response('', 204));
    await Future.wait([first, second]);
    expect(
      requests.where((r) => r.url.path.endsWith('/Stopped')),
      hasLength(1),
    );
  });
  test('old key and late 401 cannot affect a replacement account', () async {
    final requests = <http.Request>[], gate = Completer<http.Response>();
    final began = Completer<void>();
    final app = frontend(requests, (r) {
      if (r.url.host == 'one.test') {
        began.complete();
        return gate.future;
      }
      return Future.value(http.Response('', 204));
    });
    addTearDown(app.reset);
    await signIn(app);
    final oldKey = await prepare(app);
    final old = app.call('report', stopped(oldKey));
    await began.future;
    final rejected = expectLater(
      old,
      throwsA(const ClientError(ClientErrorKind.missingSession)),
    );
    await signIn(app, 'two.test');
    final newKey = await prepare(app);
    expect(newKey, isNot(oldKey));
    gate.complete(http.Response('', 401));
    await rejected;
    await expectLater(
      app.call('report', stopped(oldKey)),
      throwsA(const ClientError(ClientErrorKind.invalidResponse)),
    );
    await app.call('report', stopped(newKey));
    final current = requests
        .where(
          (r) => r.url.path.endsWith('/Stopped') && r.url.host == 'two.test',
        )
        .toList();
    expect(current, hasLength(1));
    expect(
      current.single.headers['Authorization'],
      contains('Token="two.test"'),
    );
  });
}
