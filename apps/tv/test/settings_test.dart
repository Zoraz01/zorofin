import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/app_state.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/media_quality.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/preferences.dart';
import 'package:zorofin_tv/core/server_address.dart';
import 'package:zorofin_tv/core/session_store.dart';
import 'package:zorofin_tv/core/viewer_settings.dart';

const identity = ClientIdentity(deviceId: 'dev-1', deviceName: 'Test TV');

Session _session(String server, String viewer, {String token = 'tok'}) =>
    Session(
      server: ServerAddress.parse(server),
      viewer: Viewer(id: viewer, name: viewer.toUpperCase()),
      token: token,
      deviceId: 'dev-1',
    );

void main() {
  test('device preferences are kept per server and viewer', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = Preferences(await SharedPreferences.getInstance());
    prefs.use('https://a.example/\nu1');
    await prefs.save(
      prefs.value.copyWith(
        skipForward: 15,
        posterScale: 1.2,
        subtitleAppearance: () =>
            const SubtitleAppearance(size: 125, yellow: true),
      ),
    );
    prefs.use('https://b.example/\nu1');
    expect(prefs.value, const DevicePreferences());
    prefs.use('https://a.example/\nu1');
    expect(prefs.value.skipForward, 15);
    expect(prefs.value.posterScale, 1.2);
    expect(prefs.value.subtitleAppearance?.yellow, true);
    expect(
      () => prefs.save(prefs.value.copyWith(skipBack: 7)),
      throwsArgumentError,
    );
    await prefs.reset();
    expect(prefs.value, const DevicePreferences());
  });

  test('saved accounts stay separate across servers and sign-outs', () {
    final connections = SavedConnections();
    final a = connections.remember(_session('https://a.example', 'u1'), 'A');
    final b = connections.remember(_session('https://b.example', 'u1'), 'B');
    expect(a, isNot(b), reason: 'same viewer ID on two servers');
    expect(connections.activeId, b);
    expect(connections.servers.length, 2);
    final again = connections.remember(
      _session('https://a.example', 'u1', token: 'new'),
      'A',
    );
    expect(again, a);
    expect(connections.accounts.length, 2);

    connections.signOut(a);
    expect(connections.activeId, isNull);
    expect(connections.accounts.first.session, isNull);
    expect(connections.accounts.first.viewer.name, 'U1');

    final restored = SavedConnections.fromJson(
      jsonDecode(jsonEncode(connections.toJson())) as Map<String, dynamic>,
    );
    expect(restored.accounts.map((a) => a.serverName), ['A', 'B']);
    connections.remove(b);
    expect(connections.accounts.length, 1);
  });

  test('a legacy single session becomes the first saved account', () async {
    SharedPreferences.setMockInitialValues({
      'zorofin.session.v1': jsonEncode(
        _session('https://a.example', 'u1').toJson(),
      ),
    });
    final store = await SessionStore.open();
    final state = AppState(store, deviceName: 'TV')..restore();
    expect(state.connections.accounts.length, 1);
    expect(state.catalog, isNotNull);
    await state.signOut();
    expect(state.catalog, isNull);
    expect(state.connections.accounts.single.session, isNull);
  });

  test('an account not kept on this device is never saved', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await SessionStore.open();
    final state = AppState(store, deviceName: 'TV');
    await state.signedIn(
      _session('https://a.example', 'u1'),
      serverName: 'Home',
      remember: false,
    );
    expect(state.catalog, isNotNull);
    expect(state.connections.accounts, isEmpty);
    final reopened = AppState(await SessionStore.open(), deviceName: 'TV')
      ..restore();
    expect(reopened.catalog, isNull);
    await state.expire(AppState.transientId);
    expect(state.catalog, isNull);
  });

  group('account track defaults', () {
    final source = MediaSource(
      id: 's',
      defaultAudioStreamIndex: 1,
      mediaStreams: [
        MediaStream(index: 1, type: 'Audio', language: 'eng', isDefault: true),
        MediaStream(index: 2, type: 'Audio', language: 'spa'),
        MediaStream(index: 3, type: 'Subtitle', language: 'eng'),
        MediaStream(
          index: 4,
          type: 'Subtitle',
          language: 'eng',
          isForced: true,
        ),
        MediaStream(index: 5, type: 'Subtitle', language: 'spa'),
      ],
    );
    ViewerSettings settings(Map<String, dynamic> configuration) =>
        ViewerSettings(name: 'x', configuration: configuration);

    test('server defaults win, including a remembered Off', () {
      final withServer = MediaSource(
        id: 's',
        defaultAudioStreamIndex: 2,
        defaultSubtitleStreamIndex: -1,
        mediaStreams: source.mediaStreams,
      );
      final choice = settings({
        'SubtitleMode': 'Always',
      }).chooseTracks(withServer);
      expect(choice.audio, 2);
      expect(choice.subtitle, -1);
    });

    test('the file default audio stays implicit for direct play', () {
      expect(settings({}).chooseTracks(source).audio, isNull);
    });

    test('language and mode rules are the fallback', () {
      final source2 = MediaSource(id: 's', mediaStreams: source.mediaStreams);
      expect(
        settings({
          'SubtitleMode': 'Always',
          'SubtitleLanguagePreference': 'spa',
        }).chooseTracks(source2).subtitle,
        5,
      );
      expect(
        settings({'SubtitleMode': 'OnlyForced'}).chooseTracks(source2).subtitle,
        4,
      );
      expect(
        settings({
          'SubtitleMode': 'Smart',
          'SubtitleLanguagePreference': 'en',
        }).chooseTracks(source2).subtitle,
        4,
        reason: 'audio already matches the preferred language',
      );
      expect(
        settings({
          'PlayDefaultAudioTrack': false,
          'AudioLanguagePreference': 'es',
        }).chooseTracks(source2).audio,
        2,
      );
      expect(
        settings({'SubtitleMode': 'None'}).chooseTracks(source2).subtitle,
        -1,
      );
    });
  });

  group('account settings on the server', () {
    final server = ServerAddress.parse('https://example.com/jf');
    final session = Session(
      server: server,
      viewer: Viewer(id: 'u1', name: 'Zo'),
      token: 'tok',
      deviceId: 'dev-1',
    );
    Map<String, dynamic> me(Map<String, dynamic> configuration) => {
      'Id': 'u1',
      'Name': 'Zo',
      'HasPassword': true,
      'Policy': {'EnableUserPreferenceAccess': true},
      'Configuration': configuration,
    };

    test('saves only edited keys and confirms them', () async {
      var stored = <String, dynamic>{
        'SubtitleMode': 'Default',
        'GroupedFolders': ['x'],
      };
      final posted = <Map<String, dynamic>>[];
      final client = JellyfinClient(
        server: server,
        identity: identity,
        session: session,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/Users/Me')) {
            return http.Response(jsonEncode(me(stored)), 200);
          }
          expect(request.url.path, '/jf/Users/Configuration');
          expect(request.url.queryParameters['userId'], 'u1');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          posted.add(body);
          stored = body;
          return http.Response('', 204);
        }),
      );
      final baseline = await client.viewerSettings();
      final saved = await client.saveViewerConfiguration({
        'SubtitleMode': 'Always',
      }, baseline);
      expect(saved.string('SubtitleMode'), 'Always');
      expect(posted.single['GroupedFolders'], ['x']);
    });

    test('a change made elsewhere is a conflict, not an overwrite', () async {
      final client = JellyfinClient(
        server: server,
        identity: identity,
        session: session,
        httpClient: MockClient(
          (request) async =>
              http.Response(jsonEncode(me({'SubtitleMode': 'Smart'})), 200),
        ),
      );
      final baseline = ViewerSettings(
        name: 'Zo',
        configuration: {'SubtitleMode': 'Default'},
      );
      await expectLater(
        client.saveViewerConfiguration({'SubtitleMode': 'Always'}, baseline),
        throwsA(
          isA<SettingsException>().having(
            (e) => e.error,
            'error',
            SettingsError.changedElsewhere,
          ),
        ),
      );
      expect(
        () => ViewerSettings.validate({'SubtitleMode': 'Loud'}),
        throwsA(isA<SettingsException>()),
      );
    });

    test('password and Quick Connect use the viewer id', () async {
      final requests = <http.Request>[];
      final client = JellyfinClient(
        server: server,
        identity: identity,
        session: session,
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/Users/Me')) {
            return http.Response(jsonEncode(me({})), 200);
          }
          if (request.url.path.endsWith('/QuickConnect/Authorize')) {
            return http.Response('true', 200);
          }
          return http.Response('', 204);
        }),
      );
      await client.changePassword('old', 'new');
      final password = requests.last;
      expect(password.url.path, '/jf/Users/Password');
      expect(password.url.queryParameters['userId'], 'u1');
      expect(jsonDecode(password.body), {
        'CurrentPw': 'old',
        'NewPw': 'new',
        'ResetPassword': false,
      });
      expect(await client.authorizeQuickConnect('123456'), true);
      expect(requests.last.url.queryParameters, {
        'code': '123456',
        'userId': 'u1',
      });
    });
  });

  test('quality badges describe the source file only', () {
    final item = MediaItem(
      id: 'm',
      name: 'M',
      mediaSources: [
        MediaSource(
          container: 'mkv',
          size: 12500000000,
          bitrate: 24000000,
          mediaStreams: [
            MediaStream(
              index: 0,
              type: 'Video',
              codec: 'hevc',
              width: 3840,
              height: 1600,
              videoRangeType: 'DOVIWithHDR10',
              bitDepth: 10,
              frameRate: 23.976,
            ),
            MediaStream(
              index: 1,
              type: 'Audio',
              codec: 'truehd',
              channels: 8,
              audioSpatialFormat: 'DolbyAtmos',
              isDefault: true,
            ),
          ],
        ),
      ],
    );
    final quality = item.quality();
    expect(quality.thumbnailBadges, ['4K', 'DV']);
    expect(quality.badges, [
      '4K',
      'Dolby Vision',
      'MKV',
      'HEVC',
      'Dolby Atmos',
      'TrueHD',
      '8 channels',
    ]);
    expect(quality.facts.first, ('File format', 'MKV'));
    expect(quality.facts, contains(('File size', '12.5 GB')));
    expect(quality.facts, contains(('Frame rate', '23.976 fps')));

    final invalid = MediaQuality.of(null, [
      MediaStream(
        index: 0,
        type: 'Video',
        width: 1920,
        height: 1080,
        videoRangeType: 'DOVIInvalid',
      ),
    ]);
    expect(invalid.thumbnailBadges, ['1080p']);
    expect(
      MediaItem(id: 's', name: 'S', type: 'Series').quality().badges,
      isEmpty,
    );
  });
}
