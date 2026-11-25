import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'models.dart';
import 'library_browse.dart';
import 'server_address.dart';
import 'viewer_settings.dart';

/// Identifies this install to Jellyfin. The header format matches the Apple
/// client so server dashboards show one product name.
class ClientIdentity {
  const ClientIdentity({
    required this.deviceId,
    required this.deviceName,
    this.version = '1.5.0',
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

    /// Longer than the usual wait, for files the server has to extract first.
    Duration? wait,
  }) async {
    final timeout = wait ?? this.timeout;
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
      ).timeout(timeout);
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
      // Jellyfin sends ASS/SSA files with no charset; they are UTF-8, not
      // the Latin-1 the HTTP default would assume.
      final type = response.headers['content-type'] ?? '';
      return type.contains('charset')
          ? response.body
          : utf8.decode(response.bodyBytes, allowMalformed: true);
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

  /// Downloads a server-provided media reference (such as a subtitle
  /// DeliveryUrl) as bytes. The address must resolve inside this server;
  /// the token travels in the header, never in the URL.
  Future<Uint8List> requestBytes(
    String reference, {
    int maxBytes = 64 * 1024 * 1024,

    /// Tries again after a timeout or gateway error. The server keeps
    /// extracting a subtitle track after a request gives up, so a later try
    /// gets it once it is ready, even when one wait is too short for a long
    /// film or a proxy cuts the request at 100 seconds.
    int attempts = 1,
  }) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await _requestBytesOnce(reference, maxBytes: maxBytes);
      } on ClientError catch (e) {
        final retryable =
            e.kind == ClientErrorKind.network ||
            (e.kind == ClientErrorKind.unavailable &&
                const {502, 503, 504, 522, 524}.contains(e.status));
        if (!retryable || attempt >= attempts) rethrow;
      }
    }
  }

  Future<Uint8List> _requestBytesOnce(
    String reference, {
    required int maxBytes,
  }) async {
    if (session == null) {
      throw const ClientError(ClientErrorKind.missingSession);
    }
    if (session!.server != server || reference.contains(r'\')) {
      throw const ClientError(ClientErrorKind.unsafeUrl);
    }
    final target = server.url.resolve(
      reference.startsWith('/') ? reference.substring(1) : reference,
    );
    if (!server.contains(target)) {
      throw const ClientError(ClientErrorKind.unsafeUrl);
    }
    const forbidden = {
      'apikey',
      'api_key',
      'x-emby-token',
      'token',
      'access_token',
    };
    final query = {
      for (final e in target.queryParametersAll.entries)
        if (!forbidden.contains(e.key.toLowerCase())) e.key: e.value,
    };
    final uri = Uri(
      scheme: target.scheme,
      host: target.host,
      port: target.hasPort ? target.port : null,
      path: target.path,
      queryParameters: query.isEmpty ? null : query,
    );
    final request = http.Request('GET', uri)
      ..headers['Authorization'] = identity.authorization(session!.token)
      ..followRedirects = false;
    const mediaWait = Duration(seconds: 90);
    final http.StreamedResponse response;
    try {
      // Jellyfin may finish extracting the whole subtitle track before sending
      // response headers, even when video playback has already started.
      response = await _http.send(request).timeout(mediaWait);
    } catch (_) {
      throw const ClientError(ClientErrorKind.network);
    }
    final status = response.statusCode;
    if (status == 401) {
      onUnauthorized?.call();
      throw const ClientError(ClientErrorKind.unauthorized);
    }
    if (status < 200 || status >= 300) {
      throw ClientError(ClientErrorKind.unavailable, status);
    }
    if ((response.contentLength ?? 0) > maxBytes) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.stream.timeout(mediaWait)) {
        bytes.add(chunk);
        if (bytes.length > maxBytes) {
          throw const ClientError(ClientErrorKind.invalidResponse);
        }
      }
    } on ClientError {
      rethrow;
    } catch (_) {
      throw const ClientError(ClientErrorKind.network);
    }
    return bytes.takeBytes();
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

  /// Whether this viewer may download media, asked fresh every time (Apple
  /// `contentDownloadPermission`). A saved login or cache never grants it;
  /// unknown means no, and another viewer's answer can't authorize this one.
  Future<bool> contentDownloadPermission() async {
    final session = this.session;
    if (session == null) {
      throw const ClientError(ClientErrorKind.missingSession);
    }
    final json = await request((json) => json, ['Users', 'Me']);
    if (json['Id'] != session.viewer.id) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    final policy = json['Policy'];
    return policy is Map && policy['EnableContentDownloading'] == true;
  }

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
    LibraryBrowseOptions? options,
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
        'sortBy':
            options?.sort.field ??
            (search == null ? 'DateCreated,SortName' : 'SortName'),
        'sortOrder':
            options?.sort.order ??
            (search == null ? 'Descending' : 'Ascending'),
        if (favorites || options?.unwatched == true)
          'filters': [
            if (favorites) 'IsFavorite',
            if (options?.unwatched == true) 'IsUnplayed',
          ].join(','),
        if (options != null && options.genre.isNotEmpty)
          'genres': options.genre,
        if (search != null)
          'searchTerm': search.length > 256 ? search.substring(0, 256) : search,
      },
    );
  }

  Future<List<String>> libraryGenres(String type) => request(
    (json) =>
        ((json['Items'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((v) => v['Name'])
            .whereType<String>()
            .where((v) => v.isNotEmpty)
            .toSet()
            .toList()
          ..sort(),
    ['Genres'],
    query: {..._user(), 'recursive': 'true', 'includeItemTypes': type},
  );

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

  /// Guide indexing and schedule reads never open a tuner.
  Future<ItemPage> guideChannels({int start = 0}) => request(
    ItemPage.fromJson,
    ['LiveTv', 'Channels'],
    query: {
      ..._user(),
      'startIndex': '${start < 0 ? 0 : start}',
      'limit': '200',
      'sortBy': 'ChannelNumber,SortName',
      'sortOrder': 'Ascending',
      'enableFavoriteSorting': 'false',
      'enableUserData': 'true',
      'addCurrentProgram': 'false',
      'enableImages': 'true',
      'imageTypeLimit': '1',
    },
  );

  Future<List<LiveProgram>> guidePrograms(
    List<String> channelIds,
    DateTime start,
  ) async {
    final ids = channelIds.toSet().toList()..sort();
    if (ids.isEmpty ||
        ids.length > 40 ||
        ids.any((id) => id.isEmpty || id.contains(','))) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    final end = start.add(const Duration(hours: 2));
    final result = <LiveProgram>[], seen = <String>{};
    var offset = 0;
    for (var page = 0; page < 20; page++) {
      final data = await request(
        (json) => json,
        ['LiveTv', 'Programs'],
        query: {
          ..._user(),
          'channelIds': ids.join(','),
          'minEndDate': start.toUtc().toIso8601String(),
          'maxStartDate': end.toUtc().toIso8601String(),
          'startIndex': '$offset',
          'limit': '200',
          'sortBy': 'StartDate,SortName',
          'sortOrder': 'Ascending',
          'enableTotalRecordCount': 'true',
          'enableImages': 'false',
          'fields': 'Overview,Genres',
        },
      );
      final rows = data['Items'];
      if (rows is! List || rows.length > 200) {
        throw const ClientError(ClientErrorKind.invalidResponse);
      }
      var additions = 0;
      for (final row in rows) {
        if (row is! Map<String, dynamic>) {
          throw const ClientError(ClientErrorKind.invalidResponse);
        }
        final p = LiveProgram.fromJson(row);
        final key = [p.id, p.channelId, p.name, p.start, p.end].join('|');
        if (!seen.add(key)) continue;
        additions++;
        if (ids.contains(p.channelId) &&
            p.hasSchedule &&
            p.start!.isBefore(end) &&
            p.end!.isAfter(start)) {
          result.add(p);
        }
      }
      offset += rows.length;
      final total = data['TotalRecordCount'] as int?;
      if (rows.isEmpty ||
          (total == null ? rows.length < 200 : offset >= total)) {
        return result;
      }
      if (additions == 0) {
        throw const ClientError(ClientErrorKind.invalidResponse);
      }
    }
    throw const ClientError(ClientErrorKind.invalidResponse);
  }

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

  /// Bounded, same-server artwork. Never send authenticated URLs to a launcher.
  Future<Uint8List?> recommendationArtwork(Uri uri) async {
    if (session == null || session!.server != server || !server.contains(uri)) {
      throw const ClientError(ClientErrorKind.unsafeUrl);
    }
    final request = http.Request('GET', uri)
      ..headers.addAll(authHeaders)
      ..followRedirects = false;
    final response = await _http.send(request).timeout(timeout);
    if (response.statusCode != 200 ||
        (response.contentLength ?? 0) > 2 * 1024 * 1024) {
      await response.stream.listen(null).cancel();
      return null;
    }
    final bytes = BytesBuilder();
    await for (final chunk in response.stream.timeout(timeout)) {
      bytes.add(chunk);
      if (bytes.length > 2 * 1024 * 1024) return null;
    }
    return bytes.takeBytes();
  }

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
