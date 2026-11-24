import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'models.dart';
import 'server_address.dart';
import 'viewer_settings.dart';

/// Identifies this install to Jellyfin. The header format matches the Apple
/// client so server dashboards show one product name.
class ClientIdentity {
  const ClientIdentity({
    required this.deviceId,
    required this.deviceName,
    this.version = '0.1.0',
  });

  final String deviceId;
  final String deviceName;
  final String version;

  String authorization([String? token]) {
    // Quoted header values must never inject delimiters or control characters.
    String safe(String v) => String.fromCharCodes(
      v.codeUnits.where((c) => c >= 32 && c < 127 && c != 0x22 && c != 0x5c),
    );
    final fields = [
      ('Client', 'Zorofin'),
      ('Device', deviceName),
      ('DeviceId', deviceId),
      ('Version', version),
      if (token != null) ('Token', token),
    ];
    return 'MediaBrowser ${fields.map((f) => '${f.$1}="${safe(f.$2)}"').join(', ')}';
  }
}

/// Typed Jellyfin API client. Every authenticated request is pinned to the
/// session's own server; nothing is sent to other origins.
class JellyfinClient {
  JellyfinClient({
    required this.server,
    required this.identity,
    this.session,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 20),
    this.onUnauthorized,
  }) : _http = httpClient ?? http.Client();

  final ServerAddress server;
  final ClientIdentity identity;
  final Session? session;
  final Duration timeout;
  final http.Client _http;

  /// Called when the server rejects this session's token.
  final void Function()? onUnauthorized;

  JellyfinClient withSession(
    Session session, {
    void Function()? onUnauthorized,
  }) => JellyfinClient(
    server: server,
    identity: identity,
    session: session,
    httpClient: _http,
    timeout: timeout,
    onUnauthorized: onUnauthorized,
  );

  Map<String, String> get authHeaders => {
    'Authorization': identity.authorization(session?.token),
  };

  Future<String> requestText(
    List<String> path, {
    Map<String, String> query = const {},
    String method = 'GET',
    Object? body,
    bool authenticated = true,
    bool extensionToken = false,
    int? expectedStatus,
  }) async {
    if (authenticated && session == null) {
      throw const ClientError(ClientErrorKind.missingSession);
    }
    if (authenticated && session!.server != server) {
      throw const ClientError(ClientErrorKind.unsafeUrl);
    }
    final request = http.Request(method, server.endpoint(path, query))
      ..headers['Authorization'] = identity.authorization(
        authenticated ? session?.token : null,
      )
      ..headers['Accept'] = 'application/json'
      ..followRedirects = false;
    if (extensionToken) {
      // Zorofin server modules read the viewer's token from this header too.
      final token = authenticated ? session?.token ?? '' : '';
      if (token.isEmpty || token.codeUnits.any((c) => c < 33 || c >= 127)) {
        throw const ClientError(ClientErrorKind.missingSession);
      }
      request.headers['X-Jellyfin-Token'] = token;
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _http.send(request).timeout(timeout),
      );
    } on ClientError {
      rethrow;
    } catch (_) {
      throw const ClientError(ClientErrorKind.network);
    }
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      if (expectedStatus != null && status != expectedStatus) {
        throw const ClientError(ClientErrorKind.invalidResponse);
      }
      return response.body;
    }
    if (status == 401) {
      // An optional server module refusing a call is not a signed-out
      // session; only Jellyfin's own routes end it.
      if (authenticated && !extensionToken) onUnauthorized?.call();
      throw const ClientError(ClientErrorKind.unauthorized);
    }
    if (status == 403) throw const ClientError(ClientErrorKind.forbidden);
    throw ClientError(ClientErrorKind.unavailable, status);
  }

  Future<T> request<T>(
    T Function(Map<String, dynamic>) decode,
    List<String> path, {
    Map<String, String> query = const {},
    String method = 'GET',
    Object? body,
    bool authenticated = true,
    bool extensionToken = false,
    int? expectedStatus,
  }) async {
    final text = await requestText(
      path,
      query: query,
      method: method,
      body: body,
      authenticated: authenticated,
      extensionToken: extensionToken,
      expectedStatus: expectedStatus,
    );
    try {
      return decode(jsonDecode(text) as Map<String, dynamic>);
    } catch (_) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
  }

  /// A JSON body of any shape (lists included); malformed JSON is invalid.
  Future<Object?> requestJson(
    List<String> path, {
    Map<String, String> query = const {},
    String method = 'GET',
    Object? body,
    bool extensionToken = false,
    int? expectedStatus,
  }) async {
    final text = await requestText(
      path,
      query: query,
      method: method,
      body: body,
      extensionToken: extensionToken,
      expectedStatus: expectedStatus,
    );
    try {
      return text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
  }

  Future<PublicSystemInfo> systemInfo() async {
    final info = await request(PublicSystemInfo.fromJson, [
      'System',
      'Info',
      'Public',
    ], authenticated: false);
    if ((info.id ?? '').trim().isEmpty) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return info;
  }

  Session _session(Map<String, dynamic> json) => Session(
    server: server,
    viewer: Viewer.fromJson(json['User'] as Map<String, dynamic>),
    token: json['AccessToken'] as String,
    deviceId: identity.deviceId,
  );

  Future<Session> login(String username, String password) => request(
    _session,
    ['Users', 'AuthenticateByName'],
    method: 'POST',
    body: {'Username': username, 'Pw': password},
    authenticated: false,
  );

  Future<QuickConnectState> initiateQuickConnect() => request(
    QuickConnectState.fromJson,
    ['QuickConnect', 'Initiate'],
    method: 'POST',
    authenticated: false,
  );

  Future<QuickConnectState> quickConnectState(String secret) => request(
    QuickConnectState.fromJson,
    ['QuickConnect', 'Connect'],
    query: {'secret': secret},
    authenticated: false,
  );

  Future<Session> completeQuickConnect(String secret) => request(
    _session,
    ['Users', 'AuthenticateWithQuickConnect'],
    method: 'POST',
    body: {'Secret': secret},
    authenticated: false,
  );

  Future<Viewer> currentViewer() => request(Viewer.fromJson, ['Users', 'Me']);

  Future<void> logout() async {
    await requestText(['Sessions', 'Logout'], method: 'POST');
  }

  Map<String, String> _user() {
    final current = session;
    if (current == null) {
      throw const ClientError(ClientErrorKind.missingSession);
    }
    return {'userId': current.viewer.id};
  }

  Future<ItemPage> items({
    String type = 'Movie,Series',
    int start = 0,
    int limit = 30,
    String? search,
    bool favorites = false,
  }) async {
    return request(
      ItemPage.fromJson,
      ['Items'],
      query: {
        ..._user(),
        'recursive': 'true',
        'limit': '$limit',
        'startIndex': '${start < 0 ? 0 : start}',
        'fields': 'Overview,Genres,MediaStreams',
        'enableImageTypes': 'Primary,Backdrop,Thumb',
        'imageTypeLimit': '1',
        'includeItemTypes': type,
        'sortBy': search == null ? 'DateCreated,SortName' : 'SortName',
        'sortOrder': search == null ? 'Descending' : 'Ascending',
        if (favorites) 'filters': 'IsFavorite',
        if (search != null)
          'searchTerm': search.length > 256 ? search.substring(0, 256) : search,
      },
    );
  }

  Future<ItemPage> resume() async => request(
    ItemPage.fromJson,
    ['UserItems', 'Resume'],
    query: {
      ..._user(),
      'limit': '20',
      'mediaTypes': 'Video',
      'fields': 'Overview,MediaStreams',
      'imageTypeLimit': '1',
    },
  );

  Future<ItemPage> nextUp({String? seriesId}) async => request(
    ItemPage.fromJson,
    ['Shows', 'NextUp'],
    query: {
      ..._user(),
      'limit': '20',
      'fields': 'Overview,MediaStreams',
      'seriesId': ?seriesId,
    },
  );

  Future<MediaItem> item(String id) async => request(
    MediaItem.fromJson,
    ['Items', id],
    query: {
      ..._user(),
      'fields': 'Overview,Genres,Taglines,People,MediaSources,MediaStreams',
    },
  );

  Future<ItemPage> similar(String itemId) async => request(
    ItemPage.fromJson,
    ['Items', itemId, 'Similar'],
    query: {..._user(), 'limit': '12', 'fields': 'Overview,MediaStreams'},
  );

  Future<ItemPage> seasons(String seriesId) async => request(
    ItemPage.fromJson,
    ['Shows', seriesId, 'Seasons'],
    query: {..._user(), 'isMissing': 'false'},
  );

  /// One season's episodes; [limit] pages them (Apple loads 30 at a time).
  Future<ItemPage> episodes(
    String seriesId,
    String seasonId, {
    int start = 0,
    int? limit,
  }) async => request(
    ItemPage.fromJson,
    ['Shows', seriesId, 'Episodes'],
    query: {
      ..._user(),
      'seasonId': seasonId,
      if (limit != null) ...{
        'startIndex': '${start < 0 ? 0 : start}',
        'limit': '${limit.clamp(1, 200)}',
      },
      'fields': 'Overview,MediaStreams',
      'isMissing': 'false',
      'sortBy': 'ParentIndexNumber,IndexNumber,SortName',
    },
  );

  Future<ItemPage> channels({int start = 0, int limit = 30}) async => request(
    ItemPage.fromJson,
    ['LiveTv', 'Channels'],
    query: {
      ..._user(),
      'limit': '${limit.clamp(1, 500)}',
      'startIndex': '$start',
      'addCurrentProgram': 'true',
    },
  );

  /// Up to eight upcoming guide entries for one channel; does not open a tuner.
  Future<List<LiveProgram>> livePrograms(
    String channelId, {
    DateTime? now,
  }) async {
    final at = (now ?? DateTime.now()).toUtc();
    final page = await request(
      (json) => json,
      ['LiveTv', 'Programs'],
      query: {
        ..._user(),
        'channelIds': channelId,
        'minEndDate': at.toIso8601String(),
        'maxStartDate': at.add(const Duration(hours: 12)).toIso8601String(),
        'sortBy': 'StartDate',
        'sortOrder': 'Ascending',
        'limit': '8',
        'enableTotalRecordCount': 'false',
        'enableImages': 'false',
        'fields': 'Overview',
      },
    );
    final items = page['Items'];
    if (items is! List) return [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(LiveProgram.fromJson)
        .where((p) => p.channelId == channelId && p.hasSchedule)
        .toList()
      ..sort((a, b) => a.start!.compareTo(b.start!));
  }

  Future<UserData> favorite(String itemId, bool value) async => request(
    UserData.fromJson,
    ['UserFavoriteItems', itemId],
    query: _user(),
    method: value ? 'POST' : 'DELETE',
  );

  Future<UserData> played(String itemId, bool value) async => request(
    UserData.fromJson,
    ['UserPlayedItems', itemId],
    query: _user(),
    method: value ? 'POST' : 'DELETE',
  );

  // MARK: Account settings (Apple `NativeSettings.swift`).

  Future<ViewerSettings> viewerSettings() async {
    final current = session;
    if (current == null) {
      throw const ClientError(ClientErrorKind.missingSession);
    }
    return request(
      (json) => ViewerSettingsJson.decode(json, current.viewer.id),
      ['Users', 'Me'],
    );
  }

  /// Merges only edited keys into a fresh server snapshot and confirms them
  /// with a readback. A key another device changed meanwhile is a conflict.
  Future<ViewerSettings> saveViewerConfiguration(
    Map<String, Object> changes,
    ViewerSettings baseline,
  ) async {
    ViewerSettings.validate(changes);
    final current = await viewerSettings();
    if (!current.canEdit) throw const ClientError(ClientErrorKind.forbidden);
    if (changes.isEmpty) return current;
    for (final MapEntry(:key, :value) in changes.entries) {
      final now = current.configuration[key];
      if (now != baseline.configuration[key] && now != value) {
        throw const SettingsException(SettingsError.changedElsewhere);
      }
      current.configuration[key] = value;
    }
    await _settingsMutation(['Users', 'Configuration'], current.configuration);
    try {
      final confirmed = await viewerSettings();
      if (changes.entries.every(
        (e) => confirmed.configuration[e.key] == e.value,
      )) {
        return confirmed;
      }
    } catch (_) {}
    throw const SettingsException(SettingsError.unconfirmed);
  }

  /// The explicit user ID makes administrators prove their own password too.
  Future<void> changePassword(String current, String next) async {
    if (next.isEmpty || next.length > 1024 || current.length > 1024) {
      throw const SettingsException(SettingsError.invalidInput);
    }
    if (!(await viewerSettings()).canEdit) {
      throw const ClientError(ClientErrorKind.forbidden);
    }
    await _settingsMutation(
      ['Users', 'Password'],
      {'CurrentPw': current, 'NewPw': next, 'ResetPassword': false},
    );
  }

  Future<void> removeProfileImage() async {
    if (!(await viewerSettings()).canEdit) {
      throw const ClientError(ClientErrorKind.forbidden);
    }
    try {
      await requestText(['UserImage'], query: _user(), method: 'DELETE');
    } on ClientError catch (e) {
      if (_definite(e)) rethrow;
      throw const SettingsException(SettingsError.unconfirmed);
    }
  }

  static bool _definite(ClientError e) => const {
    ClientErrorKind.unauthorized,
    ClientErrorKind.forbidden,
    ClientErrorKind.missingSession,
    ClientErrorKind.unsafeUrl,
  }.contains(e.kind);

  /// Uncertain results are never retried automatically.
  Future<void> _settingsMutation(List<String> path, Object body) async {
    try {
      await requestText(path, query: _user(), method: 'POST', body: body);
    } on ClientError catch (e) {
      if (_definite(e)) rethrow;
      throw const SettingsException(SettingsError.unconfirmed);
    }
  }

  Future<List<SettingsLanguage>> settingsLanguages() async {
    final text = await requestText(['Localization', 'Cultures']);
    final values = jsonDecode(text);
    if (values is! List) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    final result = <SettingsLanguage>[];
    for (final value in values.whereType<Map<String, dynamic>>()) {
      final code =
          value['ThreeLetterISOLanguageName'] ??
          value['TwoLetterISOLanguageName'];
      final name = value['DisplayName'];
      if (code is! String || name is! String) continue;
      if (result.any((l) => l.id == code)) continue;
      result.add(SettingsLanguage(code, name));
    }
    return result
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// Signs another device into this account with its Quick Connect code.
  Future<bool> authorizeQuickConnect(String code) async {
    final text = await requestText(
      ['QuickConnect', 'Authorize'],
      query: {'code': code, ..._user()},
      method: 'POST',
    );
    return text.trim() == 'true';
  }

  /// Profile photo for a viewer on this server.
  Uri userImage(String userId, {String? tag, int width = 256}) =>
      server.endpoint(
        ['Users', userId, 'Images', 'Primary'],
        {'maxWidth': '$width', 'quality': '85', 'tag': ?tag},
      );

  /// Artwork URL on this server. Images are fetched with [authHeaders].
  Uri image(
    String itemId, {
    String kind = 'Primary',
    String? tag,
    required int width,
  }) => server.endpoint(
    ['Items', itemId, 'Images', kind],
    {'maxWidth': '${width.clamp(80, 1920)}', 'quality': '85', 'tag': ?tag},
  );
}
