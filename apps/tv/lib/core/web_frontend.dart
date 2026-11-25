// Renderer-independent adapter for the LG DOM client. No Flutter imports.
import 'dart:typed_data';
import 'dart:async';
import 'saved_connections.dart';
import 'web_connections.dart';
import 'requests.dart';
import '../watch_together.dart';
import 'package:http/http.dart' as http;
import 'catalog.dart';
import 'library_browse.dart';
import 'team_suggestions.dart';
import 'errors.dart';
import 'home.dart';
import 'jellyfin_client.dart';
import 'live_scores.dart';
import 'live_tv_streams.dart';
import 'notification_reads.dart';
import 'media_quality.dart';
import 'models.dart';
import 'playback.dart';
import 'player_extras.dart';
import 'adaptive_quality.dart';
import 'ass.dart';
import 'playback_capabilities.dart';
import 'playback_reports.dart';
import 'pick_together.dart';
import 'trailer_previews.dart';
import 'preview_catalog.dart';
import 'profile_spotlight.dart';
import 'server_address.dart';
import 'server_extras.dart';
import 'plugin_extras.dart';
import 'viewer_settings.dart';

/// Every asynchronous operation belongs to one scope. Replacing an account
/// invalidates its responses and caches; credentials never cross to the DOM.
class WebFrontend {
  WebFrontend({
    http.Client Function()? transport,
    this.readLocal,
    this.writeLocal,
    this.onGroupChanged,
    this.onGroupCommand,
    this.playbackCapabilities,
    ConnectionVault? connectionVault,
    bool Function()? vaultAvailable,
  }) : transport = transport ?? http.Client.new,
       connections = WebConnections(
         vault: connectionVault,
         isAvailable: vaultAvailable,
       );
  final Future<PlaybackCapabilities> Function()? playbackCapabilities;
  final WebConnections connections;
  final http.Client Function() transport;
  final String? Function(String)? readLocal;
  final Future<bool> Function(String, String)? writeLocal;
  final void Function()? onGroupChanged;
  final Future<void> Function(String, int)? onGroupCommand;
  _Scope? _scope;
  int _generation = 0;

  void reset() {
    _generation++;
    _scope?.group.dispose();
    _scope?.transport?.close();
    _scope = null;
  }

  Future<Object?> call(String method, Map<String, dynamic> p) async {
    if (method == 'accounts') return connections.list();
    // What a saved profile was last watching, for the Who's watching
    // backdrop. Read with that profile's own session; only titles and
    // opaque picture references reach the DOM.
    if (method == 'profileSpotlight') {
      final id = p['id'] as String;
      final generation = _generation;
      final account = await connections.get(id);
      final session = account?.session;
      if (session == null) return null;
      final network = transport();
      try {
        final spot = await _savedClient(session, network).profileSpotlight();
        final current = await connections.get(id);
        if (generation != _generation ||
            current?.session?.token != session.token ||
            spot == null) {
          return null;
        }
        String? ref(SpotlightImage? i) =>
            i == null ? null : 'saved-art:${i.itemId}:${i.kind}:${i.tag}';
        return {
          'line': spot.line,
          'progress': spot.progress,
          'backdrop': ref(spot.backdrop),
          'thumb': ref(spot.thumbnail),
        };
      } finally {
        network.close();
      }
    }
    if (method == 'forgetAccount') {
      final id = p['id'] as String;
      final account = await connections.remove(id);
      if (_scope?.savedAccountId == id) reset();
      await _revoke(account?.session);
      return null;
    }
    if (method == 'selectAccount' ||
        method == 'connectAccount' ||
        method == 'connectServer') {
      reset();
      final turn = _generation;
      final account = await connections.get(p['id'] as String);
      if (turn != _generation || account == null) {
        throw const ClientError(ClientErrorKind.missingSession);
      }
      final session = account.session;
      final connecting = call('connect', {
        'address': account.server.url.toString(),
        'localHttp': account.server.allowsLocalHttp,
        'deviceId': session?.deviceId ?? p['deviceId'] as String,
      });
      final connectGeneration = _generation;
      await connecting;
      if (connectGeneration != _generation) {
        throw const ClientError(ClientErrorKind.missingSession);
      }
      final scope = _scope!;
      if (method == 'connectServer') {
        return {
          'needsSignIn': true,
          'serverName': scope.serverName,
          'serverAddress': account.server.url.toString(),
        };
      }
      scope.savedAccountId = account.id;
      if (method == 'connectAccount' || session == null) {
        return {
          'needsSignIn': true,
          'serverName': scope.serverName,
          'serverAddress': account.server.url.toString(),
          'viewer': account.viewer.name,
        };
      }
      try {
        final viewer = await scope.client!.withSession(session).currentViewer();
        _check(scope, connectGeneration);
        if (viewer.id != session.viewer.id) {
          throw const ClientError(ClientErrorKind.invalidResponse);
        }
        await _accept(
          scope,
          Session(
            server: session.server,
            viewer: viewer,
            token: session.token,
            deviceId: session.deviceId,
          ),
        );
        await connections.select(account.id);
        _check(scope, connectGeneration);
        return scope.identity;
      } on ClientError catch (e) {
        if (e.kind != ClientErrorKind.unauthorized) rethrow;
        await connections.signOut(account.id);
        _check(scope, connectGeneration);
        return {
          'needsSignIn': true,
          'serverName': scope.serverName,
          'serverAddress': account.server.url.toString(),
          'viewer': account.viewer.name,
        };
      }
    }
    if (method == 'reset') {
      reset();
      return null;
    }
    if (method == 'preview') {
      reset();
      _scope = _Scope(generation: _generation, catalog: PreviewCatalog());
      return _scope!.identity;
    }
    if (method == 'connect') {
      reset();
      final generation = _generation;
      final server = ServerAddress.fromUserInput(
        p['address'] as String,
        allowsLocalHttp: p['localHttp'] == true,
      );
      final network = transport();
      final client = JellyfinClient(
        server: server,
        httpClient: network,
        identity: ClientIdentity(
          deviceId: p['deviceId'] as String,
          deviceName: 'LG TV',
          version: const String.fromEnvironment(
            'ZOROFIN_VERSION',
            defaultValue: '1.5.0',
          ),
        ),
      );
      final scope = _Scope(
        generation: generation,
        client: client,
        transport: network,
      );
      _scope = scope;
      final info = await client.systemInfo();
      _check(scope, generation);
      scope.serverName = info.serverName ?? 'Jellyfin';
      return {
        'serverName': scope.serverName,
        'serverAddress': server.url.toString(),
      };
    }
    final scope = _scope;
    if (scope == null) throw const ClientError(ClientErrorKind.missingSession);
    final generation = _generation;
    if (method == 'logout') {
      // Clear immediately, then revoke with a separate connection. An offline
      // server must not leave the old account visible on this device.
      final old = scope.client;
      final session = old?.session;
      final savedId = scope.savedAccountId;
      reset();
      try {
        if (savedId != null) await connections.signOut(savedId);
      } catch (_) {
        await _revoke(session);
        rethrow;
      }
      if (old != null && session != null) {
        final network = transport();
        try {
          await JellyfinClient(
            server: old.server,
            identity: old.identity,
            session: session,
            httpClient: network,
          ).logout();
        } finally {
          network.close();
        }
      }
      return null;
    }
    final reportClient = const {'report', 'prepare'}.contains(method)
        ? scope.client
        : null;
    void checkResponse() {
      _check(scope, generation);
      if (reportClient != null && !identical(reportClient, scope.client)) {
        throw const ClientError(ClientErrorKind.missingSession);
      }
    }

    try {
      final result = await _dispatch(scope, method, p);
      checkResponse();
      return result;
    } catch (_) {
      // A late 401 from the old account must not expire the new DOM session.
      checkResponse();
      rethrow;
    }
  }

  void _check(_Scope scope, int generation) {
    if (!identical(scope, _scope) || generation != _generation) {
      throw const ClientError(ClientErrorKind.missingSession);
    }
  }

  JellyfinClient _savedClient(Session session, http.Client network) =>
      JellyfinClient(
        server: session.server,
        session: session,
        identity: ClientIdentity(
          deviceId: session.deviceId,
          deviceName: 'LG TV',
        ),
        httpClient: network,
      );

  Future<Uint8List?> image(String id, String kind, int width) async {
    if (kind == 'saved-viewer') {
      final generation = _generation;
      final account = await connections.get(id);
      final session = account?.session;
      if (session == null ||
          generation != _generation ||
          session.viewer.primaryImageTag == null) {
        return null;
      }
      final network = transport();
      try {
        final client = _savedClient(session, network);
        final data = await client.recommendationArtwork(
          client.userImage(
            session.viewer.id,
            tag: session.viewer.primaryImageTag,
            width: width.clamp(80, 512),
          ),
        );
        final current = await connections.get(id);
        if (generation != _generation ||
            current?.session?.token != session.token) {
          return null;
        }
        return data;
      } finally {
        network.close();
      }
    }
    // `saved-art:<itemId>:<Kind>:<tag>`: a saved profile's spotlight picture,
    // fetched from that profile's own server with its own session.
    if (kind.startsWith('saved-art:')) {
      final parts = kind.split(':');
      if (parts.length != 4 ||
          !const {'Backdrop', 'Thumb', 'Primary'}.contains(parts[2])) {
        return null;
      }
      final generation = _generation;
      final session = (await connections.get(id))?.session;
      if (session == null || generation != _generation) return null;
      final network = transport();
      try {
        final client = _savedClient(session, network);
        final data = await client.recommendationArtwork(
          client.image(
            parts[1],
            kind: parts[2],
            tag: parts[3],
            width: width.clamp(80, 1920),
          ),
        );
        final current = await connections.get(id);
        if (generation != _generation ||
            current?.session?.token != session.token) {
          return null;
        }
        return data;
      } finally {
        network.close();
      }
    }
    final scope = _scope;
    if (scope == null) return null;
    final generation = _generation;
    final catalog = scope.catalog;
    final client = scope.client;
    if (catalog == null || client?.session == null) return null;
    if (kind == 'viewer') {
      final viewer = await client!.currentViewer();
      _check(scope, generation);
      if (viewer.id != client.session?.viewer.id ||
          viewer.primaryImageTag == null) {
        return null;
      }
      final bytes = await client.recommendationArtwork(
        client.userImage(
          viewer.id,
          tag: viewer.primaryImageTag,
          width: width.clamp(80, 512),
        ),
      );
      _check(scope, generation);
      return bytes;
    }
    if (kind == 'event-crest-0' || kind == 'event-crest-1') {
      final sources =
          scope.liveEvents[id]?.artworkSources ?? <LiveArtworkSource>[];
      final crests = sources.where((v) => v.kind == 'crests').firstOrNull;
      final index = kind.endsWith('0') ? 0 : 1;
      if (crests == null || crests.paths.length != 2) return null;
      final uri = client!.liveArtworkUrl(crests.paths[index]);
      if (uri == null) return null;
      final bytes = await client.recommendationArtwork(uri);
      _check(scope, generation);
      return bytes;
    }
    if (kind == 'event') {
      final event = scope.liveEvents[id];
      if (event == null) return null;
      for (final source in event.artworkSources) {
        final uri = source.kind == 'catalogue'
            ? client!.liveArtworkUrl(source.path!)
            : source.kind == 'program'
            ? client!.image(
                source.itemId!,
                kind: source.imageKind!,
                tag: source.tag,
                width: width.clamp(80, 1920),
              )
            : null;
        if (uri == null) continue;
        try {
          final bytes = await client!.recommendationArtwork(uri);
          _check(scope, generation);
          // A guide image that isn't a 16:9 picture is usually a channel
          // logo or a headshot; crests or the illustration read better.
          if (bytes != null &&
              (source.kind != 'program' || await _isWidePicture(bytes))) {
            return bytes;
          }
        } catch (e) {
          _rethrowSessionError(e);
        }
      }
      return null;
    }
    // Player stills: `chapter:<index>:<tag>` and
    // `trickplay:<width>:<sheet>[:<mediaSourceId>]`, fetched with the
    // account's headers like every other picture.
    if (kind.startsWith('chapter:') || kind.startsWith('trickplay:')) {
      final parts = kind.split(':');
      final first = parts.length > 1 ? int.tryParse(parts[1]) : null;
      if (first == null || first < 0 || parts.length < 3) return null;
      final Uri uri;
      if (parts[0] == 'chapter') {
        uri = client!.chapterImage(id, first, parts[2]);
      } else {
        final sheet = int.tryParse(parts[2]);
        if (sheet == null || sheet < 0) return null;
        uri = client!.server.endpoint(
          ['Videos', id, 'Trickplay', '$first', '$sheet.jpg'],
          {
            if (parts.length > 3 && parts[3].isNotEmpty)
              'mediaSourceId': parts[3],
          },
        );
      }
      final bytes = await client.recommendationArtwork(uri);
      _check(scope, generation);
      return bytes;
    }
    final item = await scope.find(id);
    // On now cards (Apple `MobileProgramArtwork`): the programme's own image,
    // then the channel's backdrop or logo.
    if (kind == 'program') {
      for (final source in LiveProgramListing.artwork(item)) {
        final uri = client!.image(
          source.itemId,
          kind: source.kind,
          tag: source.tag,
          width: width.clamp(80, 1920),
        );
        try {
          final bytes = await client.recommendationArtwork(uri);
          _check(scope, generation);
          // Programme headshots and logos aren't wide stills: skip to the
          // channel's own art, as web and Roku do.
          if (bytes != null &&
              (!source.isProgram || await _isWidePicture(bytes))) {
            return bytes;
          }
        } catch (e) {
          _rethrowSessionError(e);
        }
      }
      return null;
    }
    final uri = kind == 'backdrop'
        ? catalog.backdrop(item, width: width.clamp(80, 1920))
        : catalog.artwork(
            item,
            landscape: kind == 'landscape',
            width: width.clamp(80, 1920),
          );
    if (uri == null) return null;
    final bytes = await client!.recommendationArtwork(uri);
    _check(scope, generation);
    return bytes;
  }

  static Future<bool> _isWidePicture(Uint8List bytes) async {
    final size = encodedImageSize(bytes);
    return size != null && isWideGuidePicture(size.$1, size.$2);
  }

  Future<Object?> _dispatch(
    _Scope s,
    String method,
    Map<String, dynamic> p,
  ) async {
    final client = s.client;
    if (method == 'cancelSignIn') {
      s.authAttempt++;
      s.quick = null;
      return null;
    }
    void checkAttempt(int attempt) {
      if (attempt != s.authAttempt) {
        throw const ClientError(ClientErrorKind.missingSession);
      }
    }

    if (method == 'quickStart') {
      final attempt = ++s.authAttempt;
      final quick = await client!.initiateQuickConnect();
      checkAttempt(attempt);
      s.quick = quick;
      return {'code': s.quick!.code};
    }
    if (method == 'quickCheck') {
      final attempt = s.authAttempt;
      final quick = s.quick;
      if (quick == null) {
        throw const ClientError(ClientErrorKind.invalidResponse);
      }
      final state = await client!.quickConnectState(quick.secret);
      checkAttempt(attempt);
      if (!state.authenticated) return {'authenticated': false};
      final session = await client.completeQuickConnect(quick.secret);
      checkAttempt(attempt);
      await _accept(s, session);
      s.quick = null;
      return {'authenticated': true, ...s.identity};
    }
    if (method == 'login') {
      final attempt = ++s.authAttempt;
      s.quick = null;
      final session = await client!.login(
        p['username'] as String,
        p['password'] as String,
      );
      checkAttempt(attempt);
      await _accept(s, session);
      return s.identity;
    }
    final catalog = s.catalog;
    if (catalog == null) {
      throw const ClientError(ClientErrorKind.missingSession);
    }
    switch (method) {
      case 'rememberAccount':
        final session = client?.session;
        if (session == null) {
          throw const ClientError(ClientErrorKind.missingSession);
        }
        final id = await connections.remember(session, s.serverName);
        if (!identical(s, _scope)) {
          await connections.signOut(id);
          throw const ClientError(ClientErrorKind.missingSession);
        }
        s.savedAccountId = id;
        return s.identity;
      case 'identity':
        return s.identity;
      case 'features':
        final f = await s.loadFeatures(force: p['refresh'] == true);
        await s.loadViewerExtras(force: p['refresh'] == true);
        _check(s, _generation);
        return {
          'liveTV': client?.session?.viewer.canAccessLiveTV ?? true,
          'requests': f.requests,
          'support': f.support,
          'notifications': f.hasNotifications,
          'serverAnnouncements': f.notifications,
          'homeRows': f.homeRows,
          'homeRowsVersion': f.homeRowsContract?.version ?? 0,
          'liveArtwork': f.liveArtwork,
          'sportsEvents': f.sportsEvents,
          'notificationReads': f.notificationReads,
          'enhancedSettings': f.enhancedSettings,
          'notificationSettings': f.notificationSettings,
          'accountApprovals': f.accountApprovals,
          'liveTVAvailability': f.liveTVAvailability,
          'liveTvStreams': f.liveTvStreams,
          'pickTogether': f.pickTogether,
          'playbackReports': f.playbackReports,
          'calendar': s.pluginExtras.calendar,
          'catchUp': s.pluginExtras.catchUp,
          if (s.looksLoaded) 'looks': s.looks,
        };
      case 'calendar':
        await s.loadViewerExtras();
        if (client == null || !s.pluginExtras.calendar) {
          throw const ClientError(ClientErrorKind.forbidden);
        }
        final start =
            DateTime.tryParse(p['start'] as String? ?? '') ?? DateTime.now();
        return [
          for (final e in await client.calendar(start))
            {
              'kind': e.kind,
              'title': e.title,
              'subtitle': e.subtitle,
              'day': e.day,
              'at': e.at.toIso8601String(),
              'allDay': e.allDay,
              'badge': e.badge,
              'itemId': e.itemId,
            },
        ];
      case 'catchUpTitles':
        await s.loadViewerExtras();
        if (client == null || !s.pluginExtras.catchUp) {
          throw const ClientError(ClientErrorKind.forbidden);
        }
        final kind = CatchUpKind.values.firstWhere(
          (v) => v.name == p['kind'],
          orElse: () => CatchUpKind.all,
        );
        final titles = await client.catchUpTitles(kind);
        s.catchUpIds = titles.map((v) => v.id).toSet();
        return [for (final item in titles) s.item(item)];
      case 'catchUpAction':
        await s.loadViewerExtras();
        final id = p['id'] as String;
        if (client == null ||
            !s.pluginExtras.catchUp ||
            !s.catchUpIds.contains(id)) {
          throw const ClientError(ClientErrorKind.forbidden);
        }
        final action = CatchUpAction.values
            .where((v) => v.wire == p['action'])
            .firstOrNull;
        if (action != CatchUpAction.skip && action != CatchUpAction.like) {
          throw const ClientError(ClientErrorKind.invalidResponse);
        }
        if (action == CatchUpAction.like) {
          await client.likeForRecommendations(id);
        }
        if (action == CatchUpAction.skip) {
          unawaited(client.logCatchUp(id, action!));
        }
        return null;
      case 'groupRefresh':
        await s.group.refresh();
        return s.groupState();
      case 'groupState':
        return s.groupState();
      case 'groupCreate':
        await s.group.create(p['name'] as String);
        return s.groupState();
      case 'groupJoin':
        final selected = s.group.groups
            .where((g) => g.id == p['id'])
            .firstOrNull;
        if (selected != null) await s.group.join(selected);
        return s.groupState();
      case 'groupLeave':
        await s.group.leave();
        return s.groupState();
      case 'groupBrowse':
        s.group.requestBrowse();
        return null;
      case 'groupContinue':
        await s.group.continueWatching();
        return null;
      case 'groupTake':
        final request = s.group.takePlaybackRequest();
        return request == null
            ? null
            : {
                'id': request.id,
                'item': s.item(request.item),
                'startTicks': request.startTicks,
              };
      case 'groupSelect':
        await s.group.selectForPlayback(
          await s.find(p['id'] as String),
          p['startTicks'] as int? ?? 0,
        );
        return null;
      case 'groupPause':
        await s.group.requestPause(p['paused'] == true);
        return null;
      case 'groupSeek':
        await s.group.requestSeek(MediaTime.duration(p['ticks'] as int));
        return null;
      case 'groupNext':
        await s.group.nextItem();
        return null;
      case 'groupPlayer':
        final player = s.player;
        if (player == null) return null;
        player.syncItemId = p['id'] as String;
        player.syncPositionTicks = p['ticks'] as int? ?? 0;
        player.isPlaying = p['playing'] == true;
        player.groupPlaybackSuspended = p['suspended'] == true;
        if (p['ready'] == true) {
          await s.group.playerReady(player, player.syncItemId);
        }
        if (p['closed'] == true) await s.group.playerClosed(player);
        if (p['buffering'] is bool) {
          await s.group.reportReadiness(buffering: p['buffering'] == true);
        }
        if (p['drift'] == true) await s.group.correctDrift(player);
        return null;
      case 'notificationReads':
        if (client == null || !s.features.notificationReads) return null;
        final reads = await client.notificationReads();
        _check(s, _generation);
        return reads.toJson();
      case 'markNotificationReads':
        if (client == null || !s.features.notificationReads) {
          throw const ClientError(ClientErrorKind.forbidden);
        }
        final requests = (p['requests'] as List? ?? []).cast<int>();
        final replies = [
          for (final raw in p['replies'] as List? ?? [])
            SupportReply(
              id: (raw as Map)['id'] as String,
              status: '',
              issueType: '',
              message: '',
              updatedAt: raw['updatedAt'] as String,
            ),
        ];
        final reads = await client.markNotificationReads(
          requests: requests,
          replies: replies,
          initialize: p['initialize'] == true,
        );
        _check(s, _generation);
        return reads.toJson();
      case 'supportReplies':
        if (!s.features.support) return [];
        return [
          for (final reply in await client!.supportReplies())
            {...reply.toJson(), 'key': reply.notificationKey},
        ];
      case 'serverAnnouncements':
        if (!s.features.notifications) return [];
        return [
          for (final message in await client!.serverAnnouncements())
            {...message.toJson(), 'key': message.notificationKey},
        ];
      case 'requestNotices':
        if (!s.features.requests) return {'items': [], 'hasOlder': false};
        final result = await client!.requestAvailabilityNotifications(
          readIds: (p['readIds'] as List? ?? []).whereType<int>().toSet(),
        );
        s.requestNotices.addAll({for (final n in result.notices) n.id: n});
        while (s.requestNotices.length > 200) {
          s.requestNotices.remove(s.requestNotices.keys.first);
        }
        return {
          'items': result.notices.map((n) => n.toJson()).toList(),
          'hasOlder': result.hasOlder,
        };
      case 'openNotice':
        final notice = s.requestNotices[p['id']];
        if (client == null || notice == null || !s.features.requests) {
          throw const ClientError(ClientErrorKind.forbidden);
        }
        return s.item(await client.requestNotificationItem(notice));
      case 'supportSend':
        if (!s.features.support) {
          throw const ClientError(ClientErrorKind.forbidden);
        }
        return await client!.submitSupport(
          SupportReport(
            issueType: p['type'] as String,
            description: p['description'] as String,
            affectedMedia: p['media'] as String? ?? '',
          ),
        );
      case 'alerts':
      case 'saveAlerts':
        if (!s.features.notificationSettings) {
          throw const ClientError(ClientErrorKind.forbidden);
        }
        final alerts = method == 'alerts'
            ? await client!.requestAlertSettings()
            : await client!.updateRequestAlerts(
                RequestAlertAction.values.byName(p['action'] as String),
                email: p['email'] as String? ?? '',
              );
        return {
          'emailEnabled': alerts.emailEnabled,
          'email': alerts.maskedAddress,
          'pushEnabled': alerts.pushEnabled,
          'message': alerts.message,
        };
      case 'requestTitles':
        if (!s.features.requests) {
          throw const ClientError(ClientErrorKind.forbidden);
        }
        final page = await client!.requestTitles(
          category: p['category'] as String? ?? 'trending',
          query: p['query'] as String? ?? '',
          page: p['page'] as int? ?? 1,
        );
        return {
          'items': page.results.map(s.requestTitle).toList(),
          'pages': page.totalPages,
        };
      case 'requestDetail':
        if (!s.features.requests) {
          throw const ClientError(ClientErrorKind.forbidden);
        }
        final kind = RequestKind.values.byName(p['kind'] as String);
        final title = await client!.requestTitle(kind, p['id'] as int);
        if (s.requests != null) await s.requests!.journal.reconcile(title);
        final quota = await client.requestQuota();
        final settings = kind == RequestKind.tv
            ? await client.requestSeasonSettings()
            : null;
        final pending =
            s.requests?.journal
                .entries()
                .where(
                  (e) =>
                      e.intent.id == title.id &&
                      e.intent.kind == kind &&
                      e.receiptId == null,
                )
                .isNotEmpty ??
            false;
        RequestDownload? download;
        RequestActivityItem? activity;
        try {
          activity = (await client.requestActivity()).requests
              .where((v) => v.tmdbId == title.id && v.kind == kind)
              .firstOrNull;
          if (activity != null) {
            download = (await client.requestQueue()).download(activity);
          }
        } catch (_) {}
        bool requestable = !pending;
        if (kind == RequestKind.movie) {
          try {
            RequestIntent(
              kind: kind,
              id: title.id,
            ).validate(title, quota: quota);
            requestable = requestable && title.mediaInfo?.status4k != 5;
          } catch (_) {
            requestable = false;
          }
        }
        return {
          ...s.requestTitle(title),
          'progressStatus': download?.label ?? activity?.statusLabel,
          'downloadProgress': download?.progress?.isFinite == true
              ? download!.progress!.clamp(0, 100)
              : null,
          'requestable': requestable,
          'remaining': quota.limit(kind)?.remaining,
          'quotaDays': quota.limit(kind)?.days,
          'unconfirmed': pending,
          'partialSeasons': settings?.partialRequestsEnabled == true,
          'specials': settings?.enableSpecialEpisodes == true,
          'libraryId':
              title.mediaInfo?.jellyfinMediaId ??
              title.mediaInfo?.jellyfinMediaId4k,
        };
      case 'requestSubmit':
        if (!s.features.requests || s.requests == null) {
          throw const ClientError(ClientErrorKind.forbidden);
        }
        final receipt = await s.requests!.submit(RequestIntent.fromJson(p));
        return {'id': receipt.id, 'status': receipt.status};
      case 'requestRetry':
        if (s.requests == null) {
          throw const ClientError(ClientErrorKind.forbidden);
        }
        await s.requests!.allowAnotherAttempt(
          RequestKind.values.byName(p['kind'] as String),
          p['id'] as int,
        );
        return null;
      case 'requestActivity':
        if (!s.features.requests) {
          throw const ClientError(ClientErrorKind.forbidden);
        }
        final page = await client!.requestActivity(
          page: p['page'] as int? ?? 1,
          mine: p['mine'] != false,
          filter: p['filter'] as String? ?? 'all',
        );
        RequestQueue? queue;
        try {
          queue = await client.requestQueue();
        } catch (_) {}
        return {
          'items': [
            for (final item in page.requests)
              {
                'id': item.id,
                'title': item.title,
                'kind': item.kind?.name,
                'mediaId': item.tmdbId,
                'status': item.statusLabel,
                'poster': RequestArtwork.absolute(item.posterUrl)?.toString(),
                'download': queue?.label(item),
                'requestedBy': p['mine'] == false ? item.requestedBy : null,
              },
          ],
          'pages': page.totalPages,
        };
      case 'home':
        s.discovery = DiscoveryFeed();
        List<HomeRow> rows;
        var featured = <MediaItem>[];
        final failures = <Object>[];
        var resumePartial = false;
        if (client == null) {
          rows = await catalog.home();
        } else {
          Future<List<MediaItem>> safe(Future<List<MediaItem>> result) async {
            try {
              return await result;
            } catch (e) {
              _rethrowSessionError(e);
              failures.add(e);
              return [];
            }
          }

          // Resume is requested once. Hero and shelves load in parallel, and a
          // failed optional source cannot erase otherwise usable library rows.
          final sources = await Future.wait([
            safe(
              client.continueWatchingFeed().then((feed) {
                resumePartial = feed.partial;
                return feed.items;
              }),
            ),
            safe(client.homeBannerItems().then((page) => page.items)),
            safe(client.items(type: 'Movie').then((page) => page.items)),
            safe(client.items(type: 'Series').then((page) => page.items)),
          ]);
          featured = sources[1];
          rows = [
            HomeRow('Continue Watching', sources[0], landscape: true),
            HomeRow('Recently Added Movies', sources[2]),
            HomeRow('Recently Added Shows', sources[3]),
          ];
          if (failures.isNotEmpty && sources.every((items) => items.isEmpty)) {
            throw failures.first;
          }
        }
        s.banner.update([for (final r in rows) ...r.items], featured: featured);
        return {
          'hero': s.banner.item == null ? null : s.item(s.banner.item!),
          'partial': resumePartial || failures.isNotEmpty,
          'rows': [
            for (final row in rows)
              if (row.items.isNotEmpty)
                {
                  'title': row.title,
                  'landscape': row.landscape,
                  'items': row.items.map(s.item).toList(),
                },
          ],
        };
      case 'homeOrder':
        if (p['reset'] == true) s.homeOrder = HomeRowOrder();
        s.homeOrder.append([
          for (final candidate in p['rows'] as List? ?? [])
            (
              (candidate as Map)['id'] as String,
              candidate['generated'] == true
                  ? HomeRowKind.generated
                  : HomeRowKind.deliberate,
            ),
        ]);
        return s.homeOrder.ids;
      case 'liveEvents':
        if (client == null || !client.session!.viewer.canAccessLiveTV) {
          return [];
        }
        await s.loadFeatures();
        final artFuture = s.features.liveArtwork
            ? client
                  .liveArtworkManifest()
                  .then<LiveArtworkManifest?>((v) => v)
                  .catchError((Object e) {
                    _rethrowSessionError(e);
                    return null;
                  })
            : Future<LiveArtworkManifest?>.value(null);
        final results = await Future.wait<Object?>([
          client.liveTvSnapshot(),
          artFuture,
        ]);
        // Live now order, favorite teams, the game cap and scores from the
        // companion (live_scores.dart); never fails the row.
        final feed = s.features.sportsEvents
            ? await s.liveScores.load(client)
            : null;
        final now = DateTime.now();
        final events = LiveScores.fromSnapshot(
          results[0] as LiveTvSnapshot,
          feed,
          now,
          artwork: results[1] as LiveArtworkManifest?,
        );
        s.liveEvents = {for (final e in events) e.id: e};
        return [
          for (final e in events)
            {
              ...s.item(e.channel),
              'eventTitle': e.title,
              'competition': e.competition,
              'start': e.start.toIso8601String(),
              'end': e.end.toIso8601String(),
              'fetchedAt': now.toIso8601String(),
              'sport': e.sport.name,
              // "Paramount+ Event 2 · Ch 1007", as web and Apple caption it.
              'channelLine': e.channelLine,
              'hasCrests': e.artworkSources.any((v) => v.kind == 'crests'),
              'favoriteTeam': e.favoriteTeam,
              if (e.score case final score?)
                'score': {
                  'status': score.status,
                  'caption': e.scoreStatus,
                  'channel': e.channelLine,
                  'tint':
                      '#${liveScoreTint(score).toRadixString(16).padLeft(6, '0')}',
                  'final': score.isFinal,
                  'text': score.text,
                  'teams': [
                    for (final (code, name, points, color, lead) in [
                      (
                        score.away,
                        score.awayName,
                        score.awayScore,
                        score.awayColor,
                        score.awayLeads,
                      ),
                      (
                        score.home,
                        score.homeName,
                        score.homeScore,
                        score.homeColor,
                        score.homeLeads,
                      ),
                    ])
                      {
                        'code': code,
                        'name': name == code ? '' : name,
                        'points': points,
                        'color': color == null
                            ? null
                            : '#${color.toRadixString(16).padLeft(6, '0')}',
                        'lead': lead,
                      },
                  ],
                },
            },
        ];
      case 'homeRows':
        if (client == null) return [];
        // Capability discovery is shared with the shell; Home must not depend
        // on whether its background discovery happened to finish first.
        try {
          await s.loadFeatures(force: p['refresh'] == true);
        } catch (e) {
          _rethrowSessionError(e);
        }
        final contract = s.features.homeRowsContract,
            revision = s.homeContractRevision;
        final loaded = await client.loadHomeRows(
          contract: contract,
          fresh: p['fresh'] == true,
        );
        var rows = loaded.rows;
        try {
          rows = await client.enrichHomeRows(rows);
        } catch (e) {
          _rethrowSessionError(e);
        }
        if (revision != s.homeContractRevision ||
            contract != s.features.homeRowsContract) {
          throw const ClientError(ClientErrorKind.invalidResponse);
        }
        final result = [
          for (final r in rows)
            {
              'id': r.id,
              'title': r.title,
              'state': r.state,
              'message': r.message,
              'items': [
                for (final c in r.cards)
                  {
                    ...s.item(c.item),
                    'subtitle': c.subtitle,
                    if (r.id == 'sports' && c.game != null) ...{
                      'matchup': c.game!.teams,
                      'crestUrls': [
                        for (final path in c.game!.paths)
                          client.server.endpoint(path.split('/')).toString(),
                      ],
                      'startsAt': c.startsAt,
                    },
                    'badges': c.badges,
                    'label': ?homeCardLabel(c, r.id),
                  },
              ],
            },
        ];
        return p['snapshot'] == true
            ? {
                'rows': result,
                'contractVersion': contract?.version ?? 0,
                'retry': loaded.serverError != null,
              }
            : result;
      case 'discover':
        if (client == null) return {'rows': [], 'hasMore': false};
        final rows = await s.discovery.next(
          client,
          excluding: (p['excluding'] as List? ?? []).cast<String>().toSet(),
        );
        return {
          'rows': [
            for (final r in rows)
              {
                'id': r.id,
                'title': r.title,
                'items': r.items.map(s.item).toList(),
              },
          ],
          'hasMore': s.discovery.hasMore,
        };
      case 'collections':
      case 'collectionItems':
        if (client == null) return {'items': [], 'total': 0};
        final parentId = method == 'collectionItems' ? p['id'] as String : null;
        if (parentId != null && (await s.find(parentId)).type != 'BoxSet') {
          throw const ClientError(ClientErrorKind.invalidResponse);
        }
        return s.page(
          await client.collectionPage(
            parentId: parentId,
            start: (p['start'] as int? ?? 0).clamp(0, 1000000),
          ),
        );
      case 'browse':
        final kind = LibraryKind.values.byName(p['kind'] as String);
        return s.page(
          await catalog.browseFiltered(
            kind,
            start: (p['start'] as int? ?? 0).clamp(0, 1000000),
            favorites: p['favorites'] == true,
            options: LibraryBrowseOptions(
              sort:
                  LibrarySort.values
                      .where((v) => v.name == p['sort'])
                      .firstOrNull ??
                  LibrarySort.recentlyAdded,
              genre: (p['genre'] as String? ?? '').substring(
                0,
                (p['genre'] as String? ?? '').length.clamp(0, 128),
              ),
              unwatched: p['unwatched'] == true,
            ),
          ),
        );
      case 'libraryGenres':
        return catalog.libraryGenres(
          LibraryKind.values.byName(p['kind'] as String),
        );
      case 'teamSuggestions':
        return [
          for (final team in teamSuggestions)
            {'name': team.name, 'league': team.league},
        ];
      case 'searchPage':
        final type = p['type'] as String? ?? 'Movie,Series';
        if (!const ['Movie,Series', 'Movie', 'Series'].contains(type)) {
          throw const ClientError(ClientErrorKind.invalidResponse);
        }
        return s.page(
          await catalog.searchPage(
            (p['query'] as String? ?? '').trim(),
            type: type,
            start: (p['start'] as int? ?? 0).clamp(0, 1000000),
          ),
        );
      case 'search':
        final query = (p['query'] as String? ?? '').trim();
        return (query.isEmpty
                ? await catalog.recommendations()
                : await catalog.search(query))
            .map(s.item)
            .toList();
      case 'item':
        return s.item(await catalog.item(p['id'] as String));
      case 'trailer':
        // Home trailer previews: a direct-play local trailer, or null.
        if (client == null) return null;
        final known = s.items[p['id']];
        if (known == null) return null;
        final trailer = await client.previewTrailer(known);
        _check(s, _generation);
        return trailer == null
            ? null
            : {'url': trailer.url, 'subtitleUrl': trailer.subtitleUrl};
      case 'pickCreate':
      case 'pickState':
      case 'pickHost':
      case 'pickLeave':
        if (client == null || !s.features.pickTogether) {
          return {'error': 'Pick Together isn’t available on this server.'};
        }
        Map<String, Object?> card(PickTogetherCard c) => {
          ...s.item(MediaItem.fromJson(c.itemJson)),
          'tally': c.tally,
        };
        try {
          final id = p['id'] as String? ?? '', seat = p['seat'] as String?;
          final PickTogetherSession? view = switch (method) {
            'pickCreate' => await client.createPickTogether(
              p['kind'] as String? ?? '',
            ),
            'pickState' => await client.pickTogetherState(
              id,
              seat: seat,
              since: p['since'] as int?,
            ),
            'pickHost' => await client.pickTogetherHost(
              id,
              p['action'] as String? ?? '',
              seat: seat,
            ),
            _ => null,
          };
          if (method == 'pickLeave') {
            await client.pickTogetherLeave(id, seat: seat);
          }
          _check(s, _generation);
          return view == null
              ? {'unchanged': true}
              : {
                  ...view.toBridge(card),
                  if (view.status == 'lobby' || view.status == 'preparing')
                    'joinMatrix': pickInviteMatrix(client.server, view.code),
                };
        } on ClientError catch (e) {
          if (e.kind == ClientErrorKind.missingSession ||
              e.kind == ClientErrorKind.unsafeUrl) {
            rethrow;
          }
          return {
            'error': pickTogetherMessage(e),
            'ended': pickTogetherEnded(e),
          };
        }
      case 'seasons':
        return (await catalog.seasons(
          p['seriesId'] as String,
        )).map(s.item).toList();
      case 'episodes':
        return s.page(
          await catalog.episodePage(
            p['seriesId'] as String,
            p['seasonId'] as String,
            start: p['start'] as int? ?? 0,
          ),
        );
      case 'similar':
        return (await catalog.similar(
          await s.find(p['id'] as String),
        )).map(s.item).toList();
      case 'next':
        final item = await s.find(p['id'] as String);
        final next = item.isEpisode
            ? await catalog.episodeAfter(item)
            : await catalog.nextEpisode(item);
        return next == null ? null : s.item(next);
      case 'favorite':
        final item = await s.find(p['id'] as String);
        return await catalog.setFavorite(item, p['value'] == true);
      case 'played':
        return await catalog.setPlayed(
          await s.find(p['id'] as String),
          p['value'] == true,
        );
      case 'adminHandoff':
        if (client == null) throw const ClientError(ClientErrorKind.forbidden);
        final viewer = await client.currentViewer();
        final path = p['path'] as String;
        if (viewer.id != client.session?.viewer.id ||
            !viewer.isAdministrator ||
            ![
              'dashboard',
              'metadata',
              if (s.features.accountApprovals) 'mypreferencesmenu',
            ].contains(path)) {
          throw const ClientError(ClientErrorKind.forbidden);
        }
        return {'url': client.server.url.resolve('web/#/$path').toString()};
      case 'settings':
        return s.settings(await catalog.viewerSettings());
      case 'saveSettings':
        final baseline = await catalog.viewerSettings();
        return s.settings(
          await catalog.saveViewerConfiguration(
            (p['changes'] as Map).cast<String, Object>(),
            baseline,
          ),
        );
      case 'languages':
        return [
          for (final l in await catalog.settingsLanguages())
            {'id': l.id, 'name': l.name},
        ];
      case 'authorizeQuickConnect':
        return await client!.authorizeQuickConnect(p['code'] as String);
      case 'removePhoto':
        await client!.removeProfileImage();
        return null;
      case 'password':
        await client!.changePassword(
          p['current'] as String,
          p['next'] as String,
        );
        return null;
      case 'teams':
        await s.loadFeatures(force: true);
        return client == null
            ? <String>[]
            : await client.homeTeams(serverFallback: s.features.legacyHomeRows);
      case 'saveTeams':
        await s.loadFeatures(force: true);
        final teams = (p['teams'] as List).cast<String>();
        await client!.saveHomeTeams(teams);
        if (s.features.legacyHomeRows) {
          try {
            await client.saveServerHomeTeams(teams);
          } catch (_) {}
        }
        if (s.features.homeRowsContract == HomeRowsContract.plugin) {
          // Rebuild the server's copy now so Home shows the new teams.
          try {
            await client.homeFeed(
              contract: HomeRowsContract.plugin,
              fresh: true,
            );
          } catch (_) {}
        }
        return null;
      case 'liveStreamsSummary':
        if (client == null ||
            !client.session!.viewer.canAccessLiveTV ||
            !s.features.liveTvStreams) {
          return null;
        }
        final streams = await client.liveTvStreams();
        _check(s, _generation);
        return {
          'summary': streams.summary,
          'inUse': streams.inUse,
          'limit': streams.limit,
        };
      case 'liveStatus':
        if (client != null && s.features.liveTvStreams) {
          final streams = await client.liveTvStreams(
            channelId: p['id'] as String?,
          );
          _check(s, _generation);
          return {'message': streams.summary, 'policy': ''};
        }
        if (client == null || !s.features.liveTVAvailability) return null;
        final status = await client.liveTvAvailability(
          channelId: p['id'] as String?,
        );
        return {'message': status.message, 'policy': status.policy};
      case 'liveNow':
        if (client == null || !client.session!.viewer.canAccessLiveTV) {
          return {
            'fetchedAt': DateTime.now().toIso8601String(),
            'items': <Object>[],
          };
        }
        final snapshot = await client.liveTvSnapshot();
        _check(s, _generation);
        final now = DateTime.now();
        return {
          'fetchedAt': snapshot.fetchedAt.toIso8601String(),
          'items': [
            if (snapshot.isFresh(now))
              for (final channel in snapshot.channels)
                if (channel.currentProgram?.isAiring(now) == true)
                  {
                    ...s.item(channel),
                    // Apple/web On now: LIVE only for a real live airing.
                    'live': LiveProgramListing.isLive(channel, now),
                  },
          ],
        };
      case 'guideChannels':
        if (client == null) {
          return s.page(await catalog.browse(LibraryKind.live));
        }
        return s.page(
          await client.guideChannels(start: p['start'] as int? ?? 0),
        );
      case 'guidePrograms':
        if (client == null) return <Object>[];
        final start = DateTime.tryParse(p['start'] as String? ?? '');
        if (start == null) {
          throw const ClientError(ClientErrorKind.invalidResponse);
        }
        return [
          for (final v in await client.guidePrograms(
            (p['ids'] as List).cast<String>(),
            start,
          ))
            s.program(v),
        ];
      case 'programs':
        return [
          for (final v in await client!.livePrograms(p['id'] as String))
            s.program(v),
        ];
      case 'prepare':
        if (client == null) {
          throw const ClientError(ClientErrorKind.unsupportedPlayback);
        }
        // Never evict an unacknowledged stop just to start another stream.
        if (s.plans.length + s.preparing >= 32) {
          throw const ClientError(ClientErrorKind.playbackSync);
        }
        s.preparing++;
        try {
          var item = await catalog.item(p['id'] as String);
          s.items[item.id] = item;
          if (item.isSeries || item.type == 'Season') {
            final next = await catalog.nextEpisode(item);
            if (next == null) {
              throw const ClientError(ClientErrorKind.unsupportedPlayback);
            }
            item = next;
          }
          if (item.isLive && s.group.isJoined) {
            throw const ClientError(ClientErrorKind.unsupportedPlayback);
          }
          if (item.isLive && s.features.liveTVAvailability) {
            await client.checkLiveTvCapacity(item.id, enabled: true);
          }
          final settings = await catalog.viewerSettings();
          final tracks = settings.chooseTracks(item.mediaSources.firstOrNull);
          // What the viewer last picked for this show, kept by the TV app.
          final memory = p['remembered'] is Map && !item.isLive
              ? TrackMemory.fromJson(
                  Map<String, dynamic>.from(p['remembered'] as Map),
                )
              : null;
          final itemStreams =
              item.mediaSources.firstOrNull?.mediaStreams ?? item.mediaStreams;
          final remembered = memory?.pick(itemStreams);
          var options = PlaybackOptions(
            capabilities: p['compatibility'] == true
                ? const PlaybackCapabilities()
                : await playbackCapabilities?.call() ??
                      const PlaybackCapabilities(),
            startTicks: p['startTicks'] as int? ?? item.resumeTicks,
            bitrate: p['bitrate'] as int? ?? 40000000,
            audioIndex: p.containsKey('audioIndex')
                ? p['audioIndex'] as int?
                : remembered?.audio ?? tracks.audio,
            subtitleIndex:
                p['subtitleIndex'] as int? ??
                remembered?.subtitle ??
                (item.isLive ? -1 : PlaybackOptions.automatic),
            burnSubtitles: p['burnSubtitles'] == true,
          );
          if (p['subtitleIndex'] == null && (remembered?.subtitle ?? -1) >= 0) {
            options = options.copyWith(
              burnSubtitles: options.burnsIn(
                itemStreams
                    .where(
                      (v) =>
                          v.type == 'Subtitle' &&
                          v.index == remembered!.subtitle,
                    )
                    .firstOrNull,
              ),
            );
          }
          var plan = await client.preparePlayback(item, options);
          if (options.subtitleIndex == PlaybackOptions.automatic) {
            final selected = settings.chooseTracks(
              plan.source,
              audioIndex: options.audioIndex,
            );
            final subtitle = plan.streams
                .where(
                  (v) => v.type == 'Subtitle' && v.index == selected.subtitle,
                )
                .firstOrNull;
            options = options.copyWith(
              audioIndex: () => selected.audio,
              subtitleIndex: subtitle?.index ?? -1,
              burnSubtitles: options.burnsIn(subtitle),
            );
            if (options.needsTranscode) {
              plan = await client.preparePlayback(item, options);
            }
          }
          if (!identical(client, s.client) || !identical(s, _scope)) {
            if (plan.liveStreamId != null) {
              await client.closeLive(plan.liveStreamId!);
            }
            throw const ClientError(ClientErrorKind.missingSession);
          }
          final key = '${s.generation}:${s.nextPlanId++}';
          s.plans[key] = plan;
          s.planOptions[key] = options;
          return {
            'key': key,
            'item': s.item(item),
            'url': plan.url.toString(),
            'method': plan.method,
            'mimeType': plan.mimeType,
            'capabilities': options.capabilities.name,
            'diagnostics': PlaybackDiagnostics.fromPlan(plan).toJson(),
            'startTicks': options.startTicks,
            'audioIndex': options.audioIndex,
            'subtitleIndex': options.subtitleIndex,
            'burnSubtitles': options.burnSubtitles,
            'autoplayNext': settings.autoplayNext,
            'streams': plan.streams.map(s.stream).toList(),
            'bitrate': options.bitrate,
          };
        } finally {
          s.preparing--;
        }
      case 'adaptQuality':
        final plan = s.plans[p['key']];
        if (plan == null) return null;
        final ceiling = (p['ceiling'] as int? ?? plan.options.bitrate).clamp(
          2000000,
          120000000,
        );
        if (s.adaptiveItem != plan.itemId || s.adaptive?.ceiling != ceiling) {
          s.adaptiveItem = plan.itemId;
          s.adaptive = AdaptiveQuality(ceiling);
        }
        final next = s.adaptive!.sample(
          now: (p['now'] as num).toDouble(),
          position: (p['position'] as num).toDouble(),
          bitrate: plan.options.bitrate,
          sourceBitrate: plan.source?.bitrate,
          enabled: p['enabled'] == true && !s.group.isJoined,
          ready: p['ready'] == true,
          paused: p['paused'] != false,
          seeking: p['seeking'] == true,
          buffering: p['buffering'] == true,
          bufferedAhead: (p['bufferedAhead'] as num? ?? 0).toDouble(),
        );
        return {'bitrate': next, 'reason': s.adaptive!.reason};
      case 'playbackInfo':
        final plan = s.plans[p['key']];
        if (plan == null || client == null) return null;
        final result = await client.playbackDiagnostics(plan);
        return result.toJson();
      case 'subtitleSelection':
        final key = p['key'] as String;
        final plan = s.plans[key];
        final options = s.planOptions[key];
        final index = p['index'] as int;
        if (plan == null ||
            options == null ||
            options.burnSubtitles ||
            (index != -1 &&
                plan.subtitlePath(index) == null &&
                plan.imageSubtitleUrl(index) == null)) {
          throw const ClientError(ClientErrorKind.invalidResponse);
        }
        s.planOptions[key] = options.copyWith(subtitleIndex: index);
        return null;
      case 'report':
        final key = p['key'] as String;
        final event = p['event'] as String;
        if (!{'start', 'progress', 'stop'}.contains(event)) {
          throw const ClientError(ClientErrorKind.invalidResponse);
        }
        if (s.acknowledgedStops.contains(key)) {
          return null;
        }
        final plan = s.plans[key];
        if (plan == null) {
          // Unknown keys (including keys from another account) are not saved.
          throw const ClientError(ClientErrorKind.invalidResponse);
        }
        final payload = {
          ...plan.report(
            positionTicks: p['positionTicks'] as int? ?? 0,
            paused: p['paused'] == true,
            canSeek: p['canSeek'] != false,
          ),
          'AudioStreamIndex': s.planOptions[key]?.audioIndex,
          'SubtitleStreamIndex': s.planOptions[key]?.subtitleIndex,
        };
        if (event == 'stop') {
          final frozen = s.stopPayloads.putIfAbsent(
            key,
            () => Map<String, Object?>.unmodifiable(payload),
          );
          final pending = s.stopRequests[key];
          if (pending != null) {
            await pending;
            return null;
          }
          final request = client!.reportPlayback(
            event,
            frozen,
            isCurrent: () =>
                identical(s, _scope) && identical(client, s.client),
          );
          s.stopRequests[key] = request;
          try {
            await request;
            // Keep all retry state on failure; only acknowledgement releases it.
            s.items.remove(plan.itemId);
            s.plans.remove(key);
            s.planOptions.remove(key);
            s.stopPayloads.remove(key);
            s.acknowledgedStops.add(key);
            if (s.acknowledgedStops.length > 64) {
              s.acknowledgedStops.remove(s.acknowledgedStops.first);
            }
          } finally {
            s.stopRequests.remove(key);
          }
        } else if (!s.stopPayloads.containsKey(key)) {
          await client!.reportPlayback(event, payload);
        }
        return null;
      case 'playerExtras':
        final plan = s.plans[p['key']];
        if (plan == null || client == null) return null;
        final extras = await client.playerExtras(
          plan.itemId,
          mediaSourceId: plan.source?.id,
        );
        _check(s, _generation);
        final trickplay = extras.trickplay;
        return {
          'chapters': [
            for (final chapter in extras.chapters)
              {
                'start': chapter.start.inMilliseconds / 1000,
                'name': chapter.name,
                'tag': chapter.imageTag,
                'index': chapter.imageIndex,
              },
          ],
          'trickplay': trickplay == null
              ? null
              : {
                  'width': trickplay.width,
                  'height': trickplay.height,
                  'tileWidth': trickplay.tileWidth,
                  'tileHeight': trickplay.tileHeight,
                  'count': trickplay.count,
                  'interval': trickplay.interval.inMilliseconds / 1000,
                  'source': plan.source?.id,
                },
        };
      case 'playbackReport':
        // The page checks the viewer's own switch; the server's is here.
        final problem = PlaybackProblem.values
            .where((v) => v.kind == p['kind'])
            .firstOrNull;
        if (client == null || problem == null || !s.features.playbackReports) {
          return null;
        }
        final startMs = p['startMs'], at = p['positionSeconds'];
        await PlaybackReporter(
          client: client,
          platform: 'LG TV',
          enabled: () => true,
        ).send(
          problem,
          itemId: '${p['itemId'] ?? ''}',
          itemTitle: '${p['title'] ?? ''}',
          method: '${p['method'] ?? ''}',
          reason: '${p['reason'] ?? ''}',
          startTook: startMs is num
              ? Duration(milliseconds: startMs.round())
              : null,
          position: at is num ? Duration(seconds: at.round()) : null,
        );
        return null;
      case 'serverReachable':
        // Any answer will do: the player asks this after a stream breaks, to
        // tell a dropped connection from a stream that cannot play.
        if (client == null) return false;
        try {
          await client
              .requestText(const [
                'System',
                'Info',
                'Public',
              ], authenticated: false)
              .timeout(const Duration(seconds: 4));
          return true;
        } catch (_) {
          return false;
        }
      case 'introSegments':
        if (client == null) return [];
        final markers = await client.introSegments(p['id'] as String);
        _check(s, _generation);
        return [
          for (final marker in markers)
            {
              'start': marker.start.inMilliseconds / 1000,
              'end': marker.end.inMilliseconds / 1000,
            },
        ];
      case 'subtitles':
        final plan = s.plans[p['key']];
        final image = plan?.imageSubtitleUrl(p['index'] as int);
        if (image != null) {
          // The server's own PGS address; the player draws it on a canvas.
          final uri = client!.server.url.resolve(
            image.startsWith('/') ? image.substring(1) : image,
          );
          if (!client.server.contains(uri)) {
            throw const ClientError(ClientErrorKind.unsafeUrl);
          }
          return {
            'format': 'pgs',
            'url': client.server
                .mediaUrl(uri.toString(), client.session!.token)
                .toString(),
          };
        }
        final styled = plan?.styledSubtitlePath(p['index'] as int);
        if (styled != null) {
          // Parsed here once; the player draws the lines with their styling.
          try {
            final text = await client!.requestText(styled);
            return {'format': 'ass', ...AssSubtitles.parse(text).toJson()};
          } catch (_) {
            // Fall back to the plain WebVTT conversion below.
          }
        }
        final path = plan?.subtitlePath(p['index'] as int);
        if (path == null) return null;
        // Stream.vtt is intentionally an API filename, not a general user path.
        final uri = client!.server.url.resolve(
          'Videos/${plan!.itemId}/${plan.sourceId}/Subtitles/${p['index']}/0/Stream.vtt',
        );
        if (!client.server.contains(uri)) {
          throw const ClientError(ClientErrorKind.unsafeUrl);
        }
        return {
          'format': 'vtt',
          'url': client.server
              .mediaUrl(uri.toString(), client.session!.token)
              .toString(),
        };
      default:
        throw const ClientError(ClientErrorKind.invalidResponse);
    }
  }

  Future<void> _revoke(Session? session) async {
    if (session == null) return;
    final network = transport();
    try {
      await JellyfinClient(
        server: session.server,
        session: session,
        identity: ClientIdentity(
          deviceId: session.deviceId,
          deviceName: 'LG TV',
          version: const String.fromEnvironment(
            'ZOROFIN_VERSION',
            defaultValue: '1.5.0',
          ),
        ),
        httpClient: network,
      ).logout();
    } catch (_) {
      // Forgetting locally succeeds even if the server is unavailable.
    } finally {
      network.close();
    }
  }

  static void _rethrowSessionError(Object error) {
    if (error is ClientError &&
        const [
          ClientErrorKind.unauthorized,
          ClientErrorKind.missingSession,
          ClientErrorKind.unsafeUrl,
        ].contains(error.kind)) {
      throw error;
    }
  }

  Future<void> _accept(_Scope s, Session session) async {
    _check(s, _generation);
    s.plans.clear();
    s.planOptions.clear();
    s.stopPayloads.clear();
    s.stopRequests.clear();
    s.acknowledgedStops.clear();
    s.client = s.client!.withSession(session);
    s.catalog = JellyfinCatalog(s.client!, serverName: s.serverName);
    s.player = _WebGroupPlayer((command, ticks) async {
      if (identical(s, _scope)) await onGroupCommand?.call(command, ticks);
    });
    s.group.configure(s.client);
    s.group.addListener(() {
      if (identical(s, _scope)) onGroupChanged?.call();
    });
    if (readLocal != null && writeLocal != null) {
      s.requests = RequestSubmissionService(
        s.client!,
        RequestJournal(
          read: readLocal!,
          write: writeLocal!,
          server: session.server.url.toString(),
          viewerId: session.viewer.id,
        ),
      );
    }
  }
}

class _Scope {
  _Scope({required this.generation, this.client, this.transport, this.catalog});
  final int generation;
  int nextPlanId = 0, preparing = 0;
  JellyfinClient? client;
  final http.Client? transport;
  Catalog? catalog;
  String serverName = '';
  String? savedAccountId;
  QuickConnectState? quick;
  int authAttempt = 0;
  PluginExtras pluginExtras = PluginExtras.none;
  Map<String, dynamic>? looks;
  bool looksLoaded = false;
  Set<String> catchUpIds = {};
  DateTime? _viewerExtrasAt;
  Future<void>? _viewerExtrasPending;
  Future<void> loadViewerExtras({bool force = false}) {
    if (!force &&
        _viewerExtrasAt != null &&
        DateTime.now().difference(_viewerExtrasAt!) <
            const Duration(seconds: 60)) {
      return Future.value();
    }
    return _viewerExtrasPending ??= (() async {
      try {
        try {
          pluginExtras = await client?.pluginExtras() ?? PluginExtras.none;
        } catch (_) {
          pluginExtras = PluginExtras.none;
        }
        if (client == null) {
          looks = null;
          looksLoaded = true;
        } else {
          try {
            final value = await client!.requestJson([
              'Zorofin',
              'Web',
              'ui',
              'looks.json',
            ], expectedStatus: 200);
            looks = value is Map<String, dynamic> && value['version'] == 1
                ? {
                    for (final key in [
                      'version',
                      'colors',
                      'accent',
                      'cardSize',
                      'enforced',
                    ])
                      key: value[key],
                  }
                : null;
            looksLoaded = true;
          } on ClientError catch (e) {
            if (e.kind == ClientErrorKind.forbidden ||
                (e.kind == ClientErrorKind.unavailable &&
                    (e.status == 404 || e.status == 405))) {
              looks = null;
              looksLoaded = true;
            }
            // On a temporary failure, the same account retains its last look.
          } catch (_) {}
        }
        _viewerExtrasAt = DateTime.now();
      } finally {
        _viewerExtrasPending = null;
      }
    })();
  }

  ServerFeatures features = const ServerFeatures();
  Future<ServerFeatures>? _featuresPending;
  DateTime? _featuresFetchedAt;
  int homeContractRevision = 0;
  Future<ServerFeatures> loadFeatures({bool force = false}) {
    if (!force &&
        _featuresFetchedAt != null &&
        DateTime.now().difference(_featuresFetchedAt!) <
            const Duration(seconds: 60)) {
      return Future.value(features);
    }
    return _featuresPending ??= (() async {
      try {
        final next = client == null
            ? const ServerFeatures()
            : await client!.discoverFeatures();
        if (next.homeRowsContract != features.homeRowsContract) {
          homeContractRevision++;
        }
        features = next;
        _featuresFetchedAt = DateTime.now();
        return features;
      } catch (e) {
        if (e is ClientError &&
            const [
              ClientErrorKind.unauthorized,
              ClientErrorKind.forbidden,
              ClientErrorKind.invalidResponse,
            ].contains(e.kind)) {
          if (features.homeRows) homeContractRevision++;
          features = const ServerFeatures();
        }
        if (e is ClientError &&
            const [
              ClientErrorKind.missingSession,
              ClientErrorKind.unsafeUrl,
            ].contains(e.kind)) {
          rethrow;
        }
        // Discovery is optional. Let ordinary Jellyfin reads decide whether
        // the viewer's session actually expired; a denied module cannot log out.
        return features;
      } finally {
        _featuresPending = null;
      }
    })();
  }

  final group = WatchTogether();
  _WebGroupPlayer? player;
  RequestSubmissionService? requests;
  HomeRowOrder homeOrder = HomeRowOrder();
  Map<String, LiveEvent> liveEvents = {};
  final liveScores = LiveScoresCache();
  Map<int, RequestAvailabilityNotice> requestNotices = {};
  final banner = HomeBanner();
  DiscoveryFeed discovery = DiscoveryFeed();
  final items = <String, MediaItem>{};
  AdaptiveQuality? adaptive;
  String? adaptiveItem;
  final plans = <String, PlaybackPlan>{};
  final planOptions = <String, PlaybackOptions>{};
  final stopPayloads = <String, Map<String, Object?>>{};
  final stopRequests = <String, Future<void>>{};
  final acknowledgedStops = <String>{};
  Map<String, Object?> get identity => {
    'viewer': catalog?.viewerName ?? '',
    'savedAccountId': savedAccountId,
    'serverName': serverName,
    'preview': catalog?.isPreview ?? false,
    'syncPlayAccess': client?.session?.viewer.syncPlayAccess,
    'preferencesKey': client?.session == null
        ? null
        : stableHash('${client!.server.url}\n${client!.session!.viewer.id}'),
  };
  Future<MediaItem> find(String id) async =>
      items[id] ?? await catalog!.item(id);
  Map<String, Object?> item(MediaItem v) {
    items.remove(v.id);
    items[v.id] = v;
    while (items.length > 1200) {
      items.remove(items.keys.first);
    }
    final q = v.quality();
    return {
      'id': v.id,
      'name': v.name,
      'title': v.displayTitle,
      'type': v.type,
      'overview': v.plainOverview ?? '',
      'year': v.productionYear,
      'rating': v.officialRating,
      'score': v.communityRating,
      'duration': v.durationLabel,
      'ticks': v.runTimeTicks,
      'resumeTicks': v.resumeTicks,
      'progress': v.progress,
      'favorite': v.userData?.isFavorite == true,
      'played': v.userData?.played == true,
      'episodeLabel': v.episodeLabel,
      'seriesId': v.episodeSeriesId,
      'seasonId': v.seasonId,
      'episode': v.indexNumber,
      'season': v.parentIndexNumber,
      'channelNumber': v.channelNumber,
      'genres': v.genres,
      'badges': q.badges,
      'thumbnailBadges': q.thumbnailBadges,
      'streams':
          (v.mediaSources.firstOrNull?.mediaStreams.isNotEmpty == true
                  ? v.mediaSources.first.mediaStreams
                  : v.mediaStreams)
              .map(stream)
              .toList(),
      'files': [
        for (final f in v.fileQualities)
          [
            for (final fact in f.facts) [fact.$1, fact.$2],
          ],
      ],
      'people': [
        for (final person in v.people)
          {...item(person.asItem), 'role': person.role ?? person.type},
      ],
      'program': v.currentProgram == null ? null : program(v.currentProgram!),
      'art':
          v.imageTags.isNotEmpty ||
          v.backdropImageTags.isNotEmpty ||
          v.parentBackdropImageTags.isNotEmpty,
    };
  }

  Map<String, Object?> groupState() => {
    'joined': group.isJoined,
    'connected': group.connected,
    'busy': group.busy,
    'canCreate': group.canCreate,
    'canJoin': group.canJoin,
    'error': group.error,
    'pending': group.playbackRequest != null,
    'group': group.group == null
        ? null
        : {
            'id': group.group!.id,
            'name': group.group!.groupName,
            'participants': group.group!.participants,
          },
    'groups': [
      for (final g in group.groups)
        {'id': g.id, 'name': g.groupName, 'participants': g.participants},
    ],
  };
  Map<String, Object?> requestTitle(RequestTitle t) => {
    'id': t.id,
    'kind': t.kind?.name,
    'name': t.displayTitle,
    'year': t.year,
    'overview': t.overview,
    'status': t.status(),
    'available': t.mediaInfo?.status == 5 || t.mediaInfo?.status4k == 5,
    'tvdbId': t.tvdbId,
    'seasons': [
      for (final season in t.seasons ?? <RequestSeason>[])
        {
          'number': season.seasonNumber,
          'name': season.name,
          'episodes': season.episodeCount,
          'state': t.requestSeasonState(season.seasonNumber).name,
          'eligible': t.requestSeasonState(season.seasonNumber).requestable,
        },
    ],
    'poster': RequestArtwork.path(t.posterPath)?.toString(),
  };
  Map<String, Object?> page(ItemPage p) => {
    'items': p.items.map(item).toList(),
    'total': p.totalRecordCount,
  };
  Map<String, Object?> program(LiveProgram p) => {
    'id': p.id,
    'channelId': p.channelId,
    'episodeTitle': p.episodeTitle,
    'name': p.name,
    'start': p.start?.toIso8601String(),
    'end': p.end?.toIso8601String(),
    'overview': p.overview,
  };
  Map<String, Object?> stream(MediaStream s) => {
    'index': s.index,
    'type': s.type,
    'name': s.displayTitle ?? s.language ?? s.codec ?? s.type,
    'language': s.language,
    'codec': s.codec,
    'text': s.isTextSubtitle,
    'pgs': s.isPgs,
    'default': s.isDefault,
    'forced': s.isForced,
  };
  Map<String, Object?> settings(ViewerSettings v) => {
    'name': v.name,
    'hasImage': v.hasImage,
    'hasPassword': v.hasPassword,
    'canEdit': v.canEdit,
    'administrator': v.isAdministrator,
    'syncPlayAccess': v.syncPlayAccess,
    'configuration': v.configuration,
  };
}

class _WebGroupPlayer implements GroupPlayer {
  _WebGroupPlayer(this.command);
  final Future<void> Function(String, int) command;
  @override
  String syncItemId = '';
  @override
  int syncPositionTicks = 0;
  @override
  bool isPlaying = false;
  @override
  bool groupPlaybackSuspended = false;
  @override
  Future<void> applyGroupCommand(String action, int ticks) =>
      command(action, ticks);
  @override
  void applyGroupStop() {
    command('Stop', 0);
  }
}
