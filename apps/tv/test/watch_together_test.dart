import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/app_state.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/core/session_store.dart';
import 'package:zorofin_tv/core/sync_play.dart';
import 'package:zorofin_tv/main.dart';
import 'package:zorofin_tv/watch_together.dart';

class _FakeSocket implements SyncPlayConnection {
  final controller = StreamController<Map<String, dynamic>>();
  final sent = <String>[];
  bool closed = false;

  @override
  Stream<Map<String, dynamic>> get messages => controller.stream;

  @override
  void send(String text) => sent.add(text);

  @override
  Future<void> close() async {
    closed = true;
    await controller.close();
  }
}

class _FakePlayer implements GroupPlayer {
  final commands = <(String, int)>[];

  @override
  String get syncItemId => 'm1';

  @override
  int syncPositionTicks = 0;

  @override
  bool get isPlaying => false;

  @override
  bool get groupPlaybackSuspended => false;

  @override
  Future<void> applyGroupCommand(String command, int ticks) async =>
      commands.add((command, ticks));

  @override
  void applyGroupStop() => commands.add(('Stop', 0));
}

void main() {
  final server = ServerAddress.parse('https://example.com/jf');
  final session = Session(
    server: server,
    viewer: Viewer(id: 'u1', name: 'Zo'),
    token: 'tok',
    deviceId: 'dev-1',
  );

  late List<(String, Map<String, dynamic>?)> posts;
  late String access;

  JellyfinClient client() => JellyfinClient(
    server: server,
    identity: const ClientIdentity(deviceId: 'dev-1', deviceName: 'Test TV'),
    session: session,
    httpClient: MockClient((r) async {
      final path = r.url.path;
      if (r.method == 'POST' && path.contains('/SyncPlay/')) {
        final body = r.body.isEmpty ? null : jsonDecode(r.body);
        posts.add((path.split('/').last, body as Map<String, dynamic>?));
        if (path.endsWith('/New')) {
          return http.Response(
            jsonEncode({
              'GroupId': 'g2',
              'GroupName': 'Friday',
              'State': 'Idle',
              'Participants': ['Zo'],
            }),
            200,
          );
        }
        return http.Response('', 204);
      }
      if (path.endsWith('/Users/Me')) {
        return http.Response(
          jsonEncode({
            'Id': 'u1',
            'Name': 'Zo',
            'Policy': {'SyncPlayAccess': access},
          }),
          200,
        );
      }
      if (path.endsWith('/SyncPlay/List')) {
        return http.Response(
          jsonEncode([
            {
              'GroupId': 'g1',
              'GroupName': 'Movie night',
              'State': 'Idle',
              'Participants': ['Ann'],
            },
          ]),
          200,
        );
      }
      if (path.endsWith('/GetUtcTime')) {
        final now = DateTime.now().toUtc().toIso8601String();
        return http.Response(
          jsonEncode({
            'RequestReceptionTime': now,
            'ResponseTransmissionTime': now,
          }),
          200,
        );
      }
      if (path.endsWith('/Items/m1')) {
        return http.Response(
          jsonEncode({'Id': 'm1', 'Name': 'Northbound', 'Type': 'Movie'}),
          200,
        );
      }
      return http.Response('', 404);
    }),
  );

  setUp(() {
    posts = [];
    access = 'CreateAndJoinGroups';
  });

  Map<String, dynamic> update(String type, Object? data) => {
    'MessageType': 'SyncPlayGroupUpdate',
    'Data': {'GroupId': 'g1', 'Type': type, 'Data': data},
  };

  test('group access follows the account policy', () async {
    final group = WatchTogether(connector: (_) async => _FakeSocket())
      ..configure(client());
    await group.refresh();
    expect(group.canCreate, isTrue);
    expect(group.groups.single.groupName, 'Movie night');

    access = 'None';
    await group.refresh();
    expect(group.canJoin, isFalse);
    expect(group.groups, isEmpty);
  });

  test('joining waits for the socket, then follows the queue', () async {
    final socket = _FakeSocket();
    final group = WatchTogether(connector: (_) async => socket)
      ..configure(client());
    await group.refresh();

    final joining = group.join(group.groups.single);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(posts.single.$1, 'Join');
    expect(posts.single.$2, {'GroupId': 'g1'});
    expect(group.isJoined, isFalse);
    await group.receive(
      update('GroupJoined', {
        'GroupId': 'g1',
        'GroupName': 'Movie night',
        'State': 'Waiting',
        'Participants': ['Ann', 'Zo'],
      }),
    );
    await joining;
    expect(group.isJoined, isTrue);
    expect(group.error, isNull);

    await group.receive(
      update('PlayQueue', {
        'Reason': 'NewPlaylist',
        'LastUpdate': DateTime.now().toUtc().toIso8601String(),
        'Playlist': [
          {'ItemId': 'm1', 'PlaylistItemId': 'p1'},
        ],
        'PlayingItemIndex': 0,
        'StartPositionTicks': 600000000,
        'IsPlaying': false,
      }),
    );
    final request = group.takePlaybackRequest()!;
    expect(request.item.name, 'Northbound');
    expect(request.startTicks, 600000000);

    final player = _FakePlayer()..syncPositionTicks = 600000000;
    await group.playerReady(player, 'm1');
    expect(
      posts.map((p) => p.$1),
      containsAllInOrder(['SetIgnoreWait', 'Ready']),
    );
    expect(posts.last.$2!['PlaylistItemId'], 'p1');

    final now = DateTime.now().toUtc();
    await group.receive({
      'MessageType': 'SyncPlayCommand',
      'Data': {
        'GroupId': 'g1',
        'PlaylistItemId': 'p1',
        'When': now.add(const Duration(milliseconds: 50)).toIso8601String(),
        'PositionTicks': 600000000,
        'Command': 'Unpause',
        'EmittedAt': now.toIso8601String(),
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(player.commands.single.$1, 'Unpause');
    expect(player.commands.single.$2, greaterThanOrEqualTo(600000000));

    // Commands for another group are ignored; leaving clears everything.
    await group.receive(update('GroupLeft', null));
    expect(group.isJoined, isFalse);
    expect(group.currentItem, isNull);
  });

  test('a lost socket leaves the group and says so', () async {
    final socket = _FakeSocket();
    final group = WatchTogether(connector: (_) async => socket)
      ..configure(client());
    await group.refresh();
    await group.create('Friday');
    expect(group.group?.groupName, 'Friday');
    await socket.controller.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(group.isJoined, isFalse);
    expect(group.error, contains('interrupted'));
    expect(posts.last.$1, 'Leave');
  });

  test('SyncPlay only allows its own actions', () {
    expect(() => client().syncPlay('Delete'), throwsA(isA<Object>()));
  });

  testWidgets('preview Profile offers Watch together', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SessionStore.open(), deviceName: 'Test TV');
    await tester.pumpWidget(ZorofinTvApp(state: state));
    state.openPreview();
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(RegExp('^Account menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Watch together'));
    await tester.tap(find.text('Watch together'));
    await tester.pumpAndSettle();
    expect(
      find.text('Connect to your Jellyfin server to create or join a group.'),
      findsOneWidget,
    );
  });
}
