import 'errors.dart';
import 'jellyfin_client.dart';
import 'live_tv_streams.dart';
import 'models.dart';
import 'request_routes.dart';
import 'viewer_settings.dart';

/// Optional Zorofin server modules, scoped to the connected server and the
/// signed-in viewer (Apple `ServerFeatures`). Plain Jellyfin has none.
enum HomeRowsContract {
  legacy(1),
  plugin(2);

  const HomeRowsContract(this.version);
  final int version;
  List<String> get path => this == plugin
      ? ['Zorofin', 'Home', 'Rows']
      : ['support', 'home', 'rows'];
  static HomeRowsContract? fromVersion(Object? version) => switch (version) {
    1 => legacy,
    2 => plugin,
    _ => null,
  };
}

class ServerFeatures {
  const ServerFeatures({
    this.support = false,
    this.notifications = false,
    this.requests = false,
    bool homeRows = false,
    HomeRowsContract? homeRowsContract,
    this.liveArtwork = false,
    this.enhancedSettings = false,
    this.accountApprovals = false,
    this.notificationSettings = false,
    this.liveTVAvailability = false,
    this.liveTvStreams = false,
    this.sportsEvents = false,
    this.notificationReads = false,
    this.pickTogether = false,
    this.playbackReports = false,
  }) : homeRowsContract =
           homeRowsContract ?? (homeRows ? HomeRowsContract.legacy : null);

  /// Fictional preview only. Real connections discover their own modules.
  static const preview = ServerFeatures(
    support: true,
    notifications: true,
    requests: true,
    homeRows: true,
    liveArtwork: true,
    enhancedSettings: true,
    accountApprovals: true,
    notificationSettings: true,
  );

  final bool support;
  final bool notifications;
  final bool requests;
  final HomeRowsContract? homeRowsContract;
  bool get homeRows => homeRowsContract != null;
  bool get legacyHomeRows => homeRowsContract == HomeRowsContract.legacy;
  final bool liveArtwork;
  final bool enhancedSettings;
  final bool accountApprovals;
  final bool notificationSettings;
  final bool liveTVAvailability;

  /// The companion names the channels using Live TV streams.
  final bool liveTvStreams;
  final bool sportsEvents;
  final bool notificationReads;

  /// The companion's pickTogether module (schemaVersion 1): group swiping.
  /// TVs host and show the session; phones vote.
  final bool pickTogether;

  /// The plugin collects playback problem reports (version 1). Absent when
  /// the owner switched collection off; the app then sends nothing.
  final bool playbackReports;

  /// Versions are negotiated per module; homeSections never enables app rows.
  factory ServerFeatures.fromManifest(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 || json['features'] is! Map) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    final features = json['features'] as Map;
    bool supports(String name) {
      final feature = features[name];
      return feature is Map &&
          feature['version'] == 1 &&
          feature['enabled'] == true;
    }

    final home = features['homeRows'];
    final contract = home is Map && home['enabled'] == true
        ? HomeRowsContract.fromVersion(home['version'])
        : null;
    return ServerFeatures(
      support: supports('support'),
      notifications: supports('notifications'),
      requests: RequestRoutes.fromManifest(features) != null,
      homeRowsContract: contract,
      liveArtwork: supports('liveArtwork'),
      enhancedSettings: supports('enhancedSettings'),
      accountApprovals: supports('accountApprovals'),
      notificationSettings: supports('notificationSettings'),
      liveTVAvailability: supports('liveTVAvailability'),
      liveTvStreams: supports('liveTvStreams'),
      sportsEvents: supports('sportsEvents'),
      notificationReads: supports('notificationReads'),
      pickTogether: supports('pickTogether'),
      playbackReports: supports('playbackReports'),
    );
  }

  bool get hasNotifications => notifications || requests;

  @override
  bool operator ==(Object other) =>
      other is ServerFeatures &&
      other.support == support &&
      other.notifications == notifications &&
      other.requests == requests &&
      other.homeRowsContract == homeRowsContract &&
      other.liveArtwork == liveArtwork &&
      other.enhancedSettings == enhancedSettings &&
      other.accountApprovals == accountApprovals &&
      other.notificationSettings == notificationSettings &&
      other.liveTVAvailability == liveTVAvailability &&
      other.liveTvStreams == liveTvStreams &&
      other.sportsEvents == sportsEvents &&
      other.notificationReads == notificationReads &&
      other.pickTogether == pickTogether &&
      other.playbackReports == playbackReports;

  @override
  int get hashCode => Object.hash(
    support,
    notifications,
    requests,
    homeRowsContract,
    liveArtwork,
    enhancedSettings,
    accountApprovals,
    notificationSettings,
    liveTVAvailability,
    liveTvStreams,
    sportsEvents,
    notificationReads,
    pickTogether,
    playbackReports,
  );
}

/// A stable 64-bit FNV-1a hash; identities only, never security.
String stableHash(String text) {
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.from(0x100000001b3);
  for (final unit in text.codeUnits) {
    hash = ((hash ^ BigInt.from(unit & 0xff)) * prime).toUnsigned(64);
    hash = ((hash ^ BigInt.from(unit >> 8)) * prime).toUnsigned(64);
  }
  // Preserve the existing native signed hexadecimal keys, including their
  // leading minus sign. Changing the representation would orphan saved state.
  return hash.toSigned(64).toRadixString(16).padLeft(16, '0');
}

final _ticketId = RegExp(r'^T[a-z0-9]{6,20}$');

/// A support agent's reply to one of the viewer's reports.
class SupportReply {
  const SupportReply({
    required this.id,
    required this.status,
    required this.issueType,
    required this.message,
    required this.updatedAt,
    this.affectedMedia,
  });

  factory SupportReply.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final status = json['status'];
    final issueType = json['issueType'];
    final message = json['message'];
    final updatedAt = json['updatedAt'];
    final media = json['affectedMedia'];
    if (id is! String ||
        status is! String ||
        issueType is! String ||
        message is! String ||
        updatedAt is! String ||
        (media != null && media is! String)) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return SupportReply(
      id: id,
      status: status,
      issueType: issueType,
      message: message,
      updatedAt: updatedAt,
      affectedMedia: media as String?,
    );
  }

  final String id;
  final String status;
  final String issueType;
  final String? affectedMedia;
  final String message;
  final String updatedAt;

  /// Announcements use a separate ID namespace in the existing inbox/history
  /// row format. They must never be acknowledged as support tickets.
  bool get isAnnouncement => id.startsWith('announcement:');
  String get sourceLabel =>
      isAnnouncement ? 'Server announcement' : 'Support reply';

  /// A later response on the same ticket is a new notification, even when a
  /// server repeats a timestamp for two different messages.
  String get notificationKey =>
      '$id-${stableHash('$id\n$updatedAt\n$message')}';

  Map<String, dynamic> toJson() => {
    'id': id,
    'status': status,
    'issueType': issueType,
    'affectedMedia': ?affectedMedia,
    'message': message,
    'updatedAt': updatedAt,
  };
}

/// Independent inbox sources: a failed refresh retains that source's old rows.
class ServerInbox {
  const ServerInbox(this.replies, this.announcements);
  final List<SupportReply>? replies;
  final List<SupportReply>? announcements;
  bool get partial => replies == null || announcements == null;
  List<SupportReply> keeping(List<SupportReply> previous) => [
    ...?announcements,
    if (announcements == null) ...previous.where((r) => r.isAnnouncement),
    ...?replies,
    if (replies == null) ...previous.where((r) => !r.isAnnouncement),
  ];
}

/// Normalize the authenticated server announcement into the inbox row format.
/// Content stays plain text; server-supplied markup is never executed.
SupportReply? announcementMessage(Map<String, dynamic> json, {DateTime? now}) {
  if (json['enabled'] == false) return null;
  final id = json['id'], title = json['title'], message = json['message'];
  if (json['enabled'] != true ||
      id is! String ||
      !RegExp(r'^[A-Za-z0-9._-]{1,80}$').hasMatch(id) ||
      title is! String ||
      title.trim().isEmpty ||
      title.length > 80 ||
      message is! String ||
      message.trim().isEmpty ||
      message.length > 320) {
    throw const ClientError(ClientErrorKind.invalidResponse);
  }
  DateTime? date(String key) {
    final value = json[key];
    if (value == null || value == '') return null;
    final parsed = value is String ? DateTime.tryParse(value) : null;
    if (parsed == null) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return parsed;
  }

  final start = date('startAt'),
      end = date('endAt'),
      current = now ?? DateTime.now();
  if ((start != null && current.isBefore(start)) ||
      (end != null && !current.isBefore(end))) {
    return null;
  }
  return SupportReply(
    id: 'announcement:$id-${stableHash(title)}',
    status: 'Server announcement',
    issueType: title,
    message: message,
    updatedAt: json['startAt'] as String? ?? '',
  );
}

/// The support form's content, trimmed and bounded (Apple `SupportReport`).
class SupportReport {
  SupportReport({
    required String issueType,
    required String description,
    String affectedMedia = '',
  }) : issueType = issueType.trim(),
       description = description.trim(),
       affectedMedia = affectedMedia.trim();

  final String issueType;
  final String description;
  final String affectedMedia;

  bool get isValid =>
      issueType.isNotEmpty &&
      issueType.length <= 64 &&
      description.isNotEmpty &&
      description.length <= 1500 &&
      affectedMedia.length <= 200;

  Map<String, String> toJson() => {
    'issueType': issueType,
    'description': description,
    'affectedMedia': affectedMedia,
  };
}

enum SupportError {
  invalidReport,
  rejected,
  outcomeUnknown;

  String get message => switch (this) {
    invalidReport =>
      'Choose an issue and add a description of up to 1,500 characters. The title field allows 200 characters.',
    rejected =>
      'The server did not accept this report. Check your connection and account access before trying again.',
    outcomeUnknown =>
      'Delivery could not be confirmed. Your report may have arrived. Check Notifications or contact your server owner before sending it again.',
  };
}

class SupportException implements Exception {
  const SupportException(this.error);
  final SupportError error;
  String get message => error.message;
}

/// The server's email and ntfy alert settings for this viewer.
class RequestAlertSettings {
  const RequestAlertSettings({
    required this.accountId,
    required this.emailEnabled,
    required this.maskedAddress,
    required this.pushEnabled,
    required this.pushServer,
    this.pushTopic,
    this.message,
    this.credentials,
  });

  factory RequestAlertSettings.fromJson(Map<String, dynamic> json) {
    final account = json['account'];
    final email = json['email'];
    final push = json['push'];
    if (account is! Map ||
        account['id'] is! String ||
        email is! Map ||
        email['enabled'] is! bool ||
        email['maskedAddress'] is! String ||
        push is! Map ||
        push['enabled'] is! bool ||
        push['server'] is! String) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    final credentials = json['credentials'];
    return RequestAlertSettings(
      accountId: account['id'] as String,
      emailEnabled: email['enabled'] as bool,
      maskedAddress: email['maskedAddress'] as String,
      pushEnabled: push['enabled'] as bool,
      pushServer: push['server'] as String,
      pushTopic: push['topic'] as String?,
      message: json['message'] as String?,
      credentials: credentials is Map
          ? (
              server: '${credentials['server'] ?? ''}',
              topic: '${credentials['topic'] ?? ''}',
              username: '${credentials['username'] ?? ''}',
              password: '${credentials['password'] ?? ''}',
            )
          : null,
    );
  }

  final String accountId;
  final bool emailEnabled;
  final String maskedAddress;
  final bool pushEnabled;
  final String pushServer;
  final String? pushTopic;
  final String? message;

  /// Shown once, when push is set up or its password is replaced.
  final ({String server, String topic, String username, String password})?
  credentials;

  RequestAlertSettings withoutCredentials() => RequestAlertSettings(
    accountId: accountId,
    emailEnabled: emailEnabled,
    maskedAddress: maskedAddress,
    pushEnabled: pushEnabled,
    pushServer: pushServer,
    pushTopic: pushTopic,
    message: message,
  );
}

enum RequestAlertAction {
  saveEmail('email/save'),
  removeEmail('email/remove'),
  testEmail('email/test'),
  createPush('push/create'),
  resetPush('push/reset'),
  removePush('push/remove'),
  testPush('push/test');

  const RequestAlertAction(this.path);
  final String path;
}

/// Viewer-safe Live TV capacity: no other viewer, channel or upstream.
class LiveTvAvailability {
  const LiveTvAvailability({
    required this.limit,
    required this.state,
    this.sameChannel = false,
    this.differentChannel = false,
    this.ownStream = false,
  });

  factory LiveTvAvailability.fromJson(Map<String, dynamic> json) {
    final limit = json['limit'];
    final state = json['state'];
    final same = json['sameChannel'];
    final different = json['differentChannel'];
    final own = json['ownStream'];
    if (limit is! int ||
        limit <= 0 ||
        limit > 1000 ||
        !const ['available', 'busy', 'unknown'].contains(state) ||
        same is! bool ||
        different is! bool ||
        own is! bool ||
        (same && different) ||
        (state != 'busy' && (same || different || own))) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return LiveTvAvailability(
      limit: limit,
      state: state as String,
      sameChannel: same,
      differentChannel: different,
      ownStream: own,
    );
  }

  final int limit;

  /// available, busy or unknown.
  final String state;
  final bool sameChannel;
  final bool differentChannel;
  final bool ownStream;

  bool get blocksPlayback =>
      state == 'busy' && differentChannel && !sameChannel && !ownStream;

  String get policy => limit == 1
      ? 'Live TV supports one channel at a time. Multiple people can watch the same channel. A different channel must wait.'
      : 'Live TV has a shared limit of $limit channels at a time.';

  String get message {
    if (sameChannel) return 'This channel is already playing. You can join it.';
    if (ownStream) return 'You can switch channels on this device.';
    if (state == 'busy') {
      return 'Live TV is in use. A different channel must wait until the current connection is free.';
    }
    if (state == 'available') return 'Live TV is available.';
    return 'Live TV availability could not be checked.';
  }
}

/// Starting a channel would need a Live TV stream and none is free.
abstract class LiveTvConflict implements Exception {
  const LiveTvConflict();
  String get title => 'Live TV is in use';
  String get message;

  /// A channel the viewer could watch instead, when there is exactly one.
  MediaItem? get join => null;
}

class LiveTvCapacityException extends LiveTvConflict {
  const LiveTvCapacityException(this.status);
  final LiveTvAvailability status;
  @override
  String get message => '${status.message} ${status.policy}';
}

/// From the companion's stream status, which names the channel in use.
class LiveTvStreamsConflict extends LiveTvConflict {
  const LiveTvStreamsConflict(this.blocked);
  final LiveTvBlocked blocked;
  @override
  String get title => blocked.title;
  @override
  String get message => '${blocked.text} ${blocked.hint}';
  @override
  MediaItem? get join => blocked.join?.channel;
}

final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

extension ServerExtras on JellyfinClient {
  /// Discovers modules from the viewer's own server after sign-in. Only a
  /// missing route tries the older support adapter; a denied or malformed
  /// manifest fails closed.
  Future<ServerFeatures> discoverFeatures() async {
    final session = this.session;
    if (session == null) {
      throw const ClientError(ClientErrorKind.missingSession);
    }
    if (session.server != server) {
      throw const ClientError(ClientErrorKind.unsafeUrl);
    }
    for (final path in const [
      ['Zorofin', 'Capabilities'],
      ['support', 'capabilities'],
    ]) {
      try {
        final json = await requestJson(
          path,
          extensionToken: true,
          expectedStatus: 200,
        );
        if (json is! Map<String, dynamic>) {
          throw const ClientError(ClientErrorKind.invalidResponse);
        }
        final features = ServerFeatures.fromManifest(json);
        RequestRoutes.remember(
          this,
          RequestRoutes.fromManifest(json['features'] as Map),
        );
        return features;
      } on ClientError catch (e) {
        if (e.kind == ClientErrorKind.unavailable && e.status == 404) continue;
        rethrow;
      }
    }
    RequestRoutes.remember(this, null);
    return const ServerFeatures();
  }

  Future<List<SupportReply>> supportReplies() async {
    final json = await requestJson(
      ['support', 'notifications'],
      extensionToken: true,
      expectedStatus: 200,
    );
    final list = json is Map ? json['notifications'] : null;
    if (list is! List) throw const ClientError(ClientErrorKind.invalidResponse);
    final replies = [
      for (final entry in list)
        if (entry is Map<String, dynamic>)
          SupportReply.fromJson(entry)
        else
          throw const ClientError(ClientErrorKind.invalidResponse),
    ];
    final ids = replies.map((r) => r.id).toSet();
    if (ids.length != replies.length ||
        replies.any((r) => !_ticketId.hasMatch(r.id))) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return replies;
  }

  /// Optional legacy announcement adapter, always on the selected server.
  Future<List<SupportReply>> serverAnnouncements() async {
    try {
      final json = await requestJson(
        ['support', 'announcement', 'me'],
        extensionToken: true,
        expectedStatus: 200,
      );
      if (json is! Map<String, dynamic>) {
        throw const ClientError(ClientErrorKind.invalidResponse);
      }
      final notice = announcementMessage(json);
      return [?notice];
    } on ClientError catch (e) {
      if (e.kind == ClientErrorKind.unavailable && e.status == 404) return [];
      rethrow;
    }
  }

  Future<ServerInbox> inboxMessages() async {
    Future<List<SupportReply>?> source(Future<List<SupportReply>> work) async {
      try {
        return await work;
      } on ClientError catch (e) {
        if (e.kind == ClientErrorKind.unauthorized ||
            e.kind == ClientErrorKind.forbidden) {
          rethrow;
        }
        return null;
      } catch (_) {
        return null;
      }
    }

    final values = await Future.wait([
      source(supportReplies()),
      source(serverAnnouncements()),
    ]);
    return ServerInbox(values[0], values[1]);
  }

  /// One POST only: a lost receipt must never silently create a duplicate.
  Future<String> submitSupport(SupportReport report) async {
    if (!report.isValid) {
      throw const SupportException(SupportError.invalidReport);
    }
    try {
      final json = await requestJson(
        ['support', 'ticket'],
        method: 'POST',
        body: report.toJson(),
        extensionToken: true,
        expectedStatus: 202,
      );
      final id = json is Map ? json['ticketId'] : null;
      if (id is! String || !_ticketId.hasMatch(id)) {
        throw const SupportException(SupportError.outcomeUnknown);
      }
      return id;
    } on ClientError catch (e) {
      final rejected =
          e.kind == ClientErrorKind.unauthorized ||
          e.kind == ClientErrorKind.forbidden ||
          (e.kind == ClientErrorKind.unavailable &&
              const [400, 404, 413, 429].contains(e.status));
      throw SupportException(
        rejected ? SupportError.rejected : SupportError.outcomeUnknown,
      );
    }
  }

  Future<RequestAlertSettings> requestAlertSettings() async => _alerts(
    await requestJson(
      ['support', 'request-alerts'],
      extensionToken: true,
      expectedStatus: 200,
    ),
  );

  Future<RequestAlertSettings> updateRequestAlerts(
    RequestAlertAction action, {
    String email = '',
  }) async {
    if (action == RequestAlertAction.saveEmail &&
        (email.length > 254 || !_email.hasMatch(email))) {
      throw const SettingsException(SettingsError.invalidInput);
    }
    try {
      return _alerts(
        await requestJson(
          ['support', 'request-alerts', ...action.path.split('/')],
          method: 'POST',
          body: action == RequestAlertAction.saveEmail
              ? {'email': email}
              : <String, String>{},
          extensionToken: true,
          expectedStatus: 200,
        ),
      );
    } on ClientError catch (e) {
      if (const [
        ClientErrorKind.unauthorized,
        ClientErrorKind.forbidden,
        ClientErrorKind.missingSession,
        ClientErrorKind.unsafeUrl,
      ].contains(e.kind)) {
        rethrow;
      }
      throw const SettingsException(SettingsError.unconfirmed);
    }
  }

  RequestAlertSettings _alerts(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    final result = RequestAlertSettings.fromJson(json);
    if (result.accountId != session?.viewer.id) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return result;
  }

  Future<LiveTvAvailability> liveTvAvailability({String? channelId}) async {
    final json = await requestJson(
      ['support', 'live-tv', 'status'],
      query: {'deviceId': identity.deviceId, 'channelId': ?channelId},
      extensionToken: true,
      expectedStatus: 200,
    );
    if (json is! Map<String, dynamic>) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return LiveTvAvailability.fromJson(json);
  }

  /// A fresh conflict blocks before a tuner opens. A missing or failing
  /// optional service keeps ordinary playback.
  /// Prefers the companion's stream status ([streams]), which names the
  /// channel in use; falls back to the older availability check ([enabled]).
  Future<void> checkLiveTvCapacity(
    String channelId, {
    required bool enabled,
    bool streams = false,
  }) async {
    if (!enabled && !streams) return;
    try {
      if (streams) {
        final status = await liveTvStreams(channelId: channelId);
        final blocked = status.blocked(channelId);
        if (blocked != null) throw LiveTvStreamsConflict(blocked);
        return;
      }
      final status = await liveTvAvailability(channelId: channelId);
      if (status.blocksPlayback) throw LiveTvCapacityException(status);
    } on LiveTvConflict {
      rethrow;
    } catch (_) {}
  }
}
