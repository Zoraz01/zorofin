import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/catalog.dart';
import 'core/notification_reads.dart';
import 'core/errors.dart';
import 'core/plugin_extras.dart';
import 'core/requests.dart';
import 'core/server_extras.dart';
import 'core/session_store.dart';
import 'core/viewer_settings.dart';

/// Requests can be left out of a build (`--dart-define=ZOROFIN_REQUESTS=false`)
/// for a store submission that should not offer them yet.
const requestsBuildEnabled = bool.fromEnvironment(
  'ZOROFIN_REQUESTS',
  defaultValue: true,
);

/// Support issue types, in Apple's order.
const supportIssues = [
  'Playback / buffering problem',
  'Live TV issue',
  'Download not appearing / slow',
  'Request a 4K movie upgrade',
  'Subtitle or captions problem',
  'Corrupted video or audio',
  'Feature request',
  'Other',
];

enum SupportSubmission { idle, sending, accepted, rejected, uncertain }

/// The device-local inbox history for one server and viewer (Apple
/// `NotificationHistory`).
class NotificationHistory {
  NotificationHistory({
    this.requestsInitialized = false,
    List<RequestAvailabilityNotice>? requests,
    Set<int>? readRequestIds,
    List<SupportReply>? hiddenReplies,
    Set<String>? seenReplyKeys,
  }) : requests = requests ?? [],
       readRequestIds = readRequestIds ?? {},
       hiddenReplies = hiddenReplies ?? [],
       seenReplyKeys = seenReplyKeys ?? {};

  factory NotificationHistory.fromJson(Map<String, dynamic> json) =>
      NotificationHistory(
        requestsInitialized: json['requestsInitialized'] == true,
        requests: [
          for (final e in json['requests'] as List? ?? const [])
            RequestAvailabilityNotice.fromJson(e as Map<String, dynamic>),
        ],
        readRequestIds: {
          for (final e in json['readRequestIds'] as List? ?? const []) e as int,
        },
        hiddenReplies: [
          for (final e in json['hiddenReplies'] as List? ?? const [])
            SupportReply.fromJson(e as Map<String, dynamic>),
        ],
        seenReplyKeys: {
          for (final e in json['seenReplyKeys'] as List? ?? const [])
            e as String,
        },
      );

  bool requestsInitialized;
  List<RequestAvailabilityNotice> requests;
  final Set<int> readRequestIds;
  List<SupportReply> hiddenReplies;
  final Set<String> seenReplyKeys;

  Map<String, dynamic> toJson() => {
    'requestsInitialized': requestsInitialized,
    'requests': [for (final r in requests) r.toJson()],
    'readRequestIds': readRequestIds.toList(),
    'hiddenReplies': [for (final r in hiddenReplies) r.toJson()],
    'seenReplyKeys': seenReplyKeys.toList(),
  };
}

class NotificationHistoryStore {
  NotificationHistoryStore(
    this._prefs, {
    required String server,
    required String viewerId,
  }) : _key =
           'zorofin.notification-history.v1.${stableHash('$server\n$viewerId')}';

  final SharedPreferences _prefs;
  final String _key;

  NotificationHistory load() {
    final raw = _prefs.getString(_key);
    if (raw == null) return NotificationHistory();
    try {
      final state = NotificationHistory.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (state.requests.length > 100 ||
          state.hiddenReplies.length > 30 ||
          state.readRequestIds.length > 20000 ||
          state.seenReplyKeys.length > 1000) {
        return NotificationHistory();
      }
      return state;
    } catch (_) {
      return NotificationHistory();
    }
  }

  /// Call only after a complete availability check. The first snapshot is
  /// history, so an existing library doesn't arrive as a wall of unread items.
  Future<NotificationHistory> receiveRequests(
    List<RequestAvailabilityNotice> notices, {
    bool initializeSnapshot = true,
  }) async {
    final state = load();
    if (!state.requestsInitialized) {
      if (initializeSnapshot) {
        state.readRequestIds.addAll(notices.map((n) => n.id));
      }
      state.requestsInitialized = true;
    }
    final incoming = notices.map((n) => n.id).toSet();
    state.requests = [
      ...notices,
      ...state.requests.where((n) => !incoming.contains(n.id)),
    ].take(100).toList();
    await _save(state);
    return state;
  }

  Future<Set<int>> seeRequest(int id) async {
    final state = load()..readRequestIds.add(id);
    await _save(state);
    return state.readRequestIds;
  }

  Future<NotificationHistory> seeReply(SupportReply reply) async {
    final state = load();
    state.seenReplyKeys.add(reply.notificationKey);
    state.hiddenReplies = [
      reply,
      ...state.hiddenReplies.where(
        (r) => r.notificationKey != reply.notificationKey,
      ),
    ].take(30).toList();
    await _save(state);
    return state;
  }

  Future<void> _save(NotificationHistory state) async {
    if (!await _prefs.setString(_key, jsonEncode(state.toJson()))) {
      throw const SettingsException(SettingsError.unconfirmed);
    }
  }
}

/// Zorofin server modules for the signed-in catalog (Apple `AppModel`'s
/// extension state): features, the notification inbox and the support form.
/// One instance lives with each signed-in shell, so an account change
/// discards it and every late result with it.
class ExtrasState extends ChangeNotifier {
  ExtrasState({
    required this.catalog,
    required SharedPreferences storage,
    this.loopInterval = const Duration(seconds: 30),
  }) : _storage = storage {
    final session = catalog.client?.session;
    if (session != null) {
      _history = NotificationHistoryStore(
        storage,
        server: session.server.storageKey,
        viewerId: session.viewer.id,
      );
    }
    if (catalog.isPreview) _loadPreview();
  }

  final Catalog catalog;
  final SharedPreferences _storage;
  final Duration loopInterval;
  NotificationHistoryStore? _history;
  Timer? _timer;
  bool _disposed = false;

  ServerFeatures features = const ServerFeatures();

  /// Calendar and Catch Up, when the operator turned them on in the plugin.
  PluginExtras pluginExtras = PluginExtras.none;
  bool featuresChecked = false;
  String? featureError;

  List<SupportReply> replies = [];
  List<SupportReply> hiddenReplies = [];
  final Set<String> seenReplyKeys = {};
  String? replyError;
  bool loadingReplies = false;
  DateTime _lastReplyCheck = DateTime.fromMillisecondsSinceEpoch(0);

  List<RequestAvailabilityNotice> requestNotices = [];
  final Set<int> requestReadIds = {};
  bool hasOlderRequestNotices = false;
  String? requestNoticeError;
  bool loadingRequestNotices = false;
  DateTime _lastRequestCheck = DateTime.fromMillisecondsSinceEpoch(0);

  String supportIssue = supportIssues.first;
  String supportMedia = '';
  String supportDescription = '';
  SupportSubmission submission = SupportSubmission.idle;
  String? ticketId;

  bool get isPreview => catalog.isPreview;

  /// Catch Up's skipped titles for this account, on this device.
  CatchUpSkips? get catchUpSkips {
    final session = catalog.client?.session;
    if (session == null) return null;
    return CatchUpSkips(
      read: _storage.getStringList,
      write: (key, value) => unawaited(_storage.setStringList(key, value)),
      server: session.server.storageKey,
      viewerId: session.viewer.id,
    );
  }

  bool get requestsEnabled => features.requests && requestsBuildEnabled;
  NotificationReadState? accountNotificationReads;

  bool get hasNotifications => features.notifications || requestsEnabled;
  bool get loadingNotifications => loadingReplies || loadingRequestNotices;

  SharedPreferences get storage => _storage;

  RequestSubmissionService? _requestService;

  /// Fresh checks and the on-device receipt journal for request submission.
  RequestSubmissionService? get requestService {
    final client = catalog.client;
    final session = client?.session;
    if (client == null || session == null) return null;
    return _requestService ??= RequestSubmissionService(
      client,
      RequestJournal(
        read: _storage.getString,
        write: _storage.setString,
        server: session.server.storageKey,
        viewerId: session.viewer.id,
      ),
    );
  }

  /// Bumped after a request is sent so Requests and Home reload.
  int requestRevision = 0;

  void requestSent() {
    requestRevision++;
    homeRevision++;
    _changed();
  }

  /// Bumped when Home should reload, such as after saving teams.
  int homeRevision = 0;

  void homeChanged() {
    homeRevision++;
    _changed();
  }

  bool isRequestRead(int id) =>
      requestReadIds.contains(id) ||
      (features.notificationReads &&
          accountNotificationReads?.requests.contains(id) == true);
  bool isReplyRead(SupportReply reply) =>
      seenReplyKeys.contains(reply.notificationKey) ||
      (features.notificationReads &&
          !reply.isAnnouncement &&
          accountNotificationReads?.replies.contains(reply.accountReadKey) ==
              true);
  List<RequestAvailabilityNotice> get unreadRequestNotices =>
      requestNotices.where((n) => !isRequestRead(n.id)).toList();
  List<SupportReply> get unreadReplies =>
      replies.where((r) => !isReplyRead(r)).toList();
  List<SupportReply> get readReplies {
    final seen = <String>{};
    return [
      ...replies.where(isReplyRead),
      ...hiddenReplies,
    ].where((r) => seen.add(r.notificationKey)).toList();
  }

  int get unreadCount => unreadReplies.length + unreadRequestNotices.length;

  SupportReport get supportReport => SupportReport(
    issueType: supportIssue,
    description: supportDescription,
    affectedMedia: supportMedia,
  );

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _loadPreview() {
    features = ServerFeatures.preview;
    featuresChecked = true;
    requestNotices = [
      const RequestAvailabilityNotice(
        id: 1,
        kind: RequestKind.movie,
        titleId: 1,
        title: 'The Last Lighthouse',
      ),
    ];
    replies = [
      const SupportReply(
        id: 'Tpreview1',
        status: 'resolved',
        issueType: 'Playback / buffering problem',
        message:
            'This is a sample support reply. Real replies from your server appear here.',
        updatedAt: '2026-10-16T12:00:00Z',
      ),
    ];
  }

  /// Foreground loop: features, then notifications, every 30 seconds while
  /// the shell is open.
  void start() {
    if (isPreview || _timer != null || _disposed) return;
    unawaited(_tick());
    _timer = Timer.periodic(loopInterval, (_) => unawaited(_tick()));
  }

  Future<void> _tick() async {
    await checkFeatures();
    if (_disposed) return;
    if (hasNotifications) await refreshNotifications();
  }

  bool _checkingFeatures = false;

  Future<void> checkFeatures() async {
    final client = catalog.client;
    if (client == null || isPreview || _disposed || _checkingFeatures) return;
    _checkingFeatures = true;
    try {
      final result = await client.discoverFeatures();
      if (_disposed) return;
      features = result;
      if (!features.notificationReads) accountNotificationReads = null;
      // Optional; a failure keeps what was last known.
      try {
        pluginExtras = await client.pluginExtras();
      } on ClientError catch (e) {
        if (e.kind == ClientErrorKind.unauthorized) {
          pluginExtras = PluginExtras.none;
        }
      } catch (_) {}
      if (_disposed) return;
      if (!features.notifications) {
        replies = [];
        hiddenReplies = [];
        seenReplyKeys.clear();
        replyError = null;
      }
      if (!requestsEnabled) {
        requestNotices = [];
        requestReadIds.clear();
        requestNoticeError = null;
        hasOlderRequestNotices = false;
      }
      featureError = null;
    } catch (e) {
      if (_disposed) return;
      if (e is ClientError &&
          const [
            ClientErrorKind.unauthorized,
            ClientErrorKind.forbidden,
            ClientErrorKind.invalidResponse,
          ].contains(e.kind)) {
        features = const ServerFeatures();
        pluginExtras = PluginExtras.none;
        replies = [];
        hiddenReplies = [];
        requestNotices = [];
      }
      featureError =
          'Server extras could not be checked. Your library is still available.';
    }
    _checkingFeatures = false;
    featuresChecked = true;
    _changed();
  }

  Future<void> refreshNotifications({bool force = false}) async {
    final client = catalog.client;
    if (features.notificationReads && !isPreview && client != null) {
      NotificationReadState? remote;
      try {
        remote = await client.notificationReads();
      } catch (_) {}
      if (_disposed) return;
      accountNotificationReads = remote;
    } else {
      accountNotificationReads = null;
    }
    _changed();
    await Future.wait([
      _refreshReplies(force: force),
      _refreshRequestNotices(force: force),
    ]);
  }

  Future<void> _refreshReplies({required bool force}) async {
    final client = catalog.client;
    final history = _history;
    if (!features.notifications ||
        loadingReplies ||
        isPreview ||
        client == null ||
        history == null) {
      return;
    }
    if (!force &&
        DateTime.now().difference(_lastReplyCheck) <
            const Duration(seconds: 120)) {
      return;
    }
    loadingReplies = true;
    _lastReplyCheck = DateTime.now();
    _changed();
    try {
      final saved = history.load();
      hiddenReplies = saved.hiddenReplies;
      seenReplyKeys.addAll(saved.seenReplyKeys);
      final result = await client.inboxMessages();
      if (_disposed || !features.notifications) return;
      replies = result.keeping(replies);
      replyError = result.partial
          ? 'Some messages could not be refreshed.'
          : null;
    } catch (e) {
      if (_disposed) return;
      if (e is ClientError &&
          (e.kind == ClientErrorKind.unauthorized ||
              e.kind == ClientErrorKind.forbidden)) {
        replies = [];
        hiddenReplies = [];
      }
      replyError = 'Messages could not be refreshed.';
    } finally {
      loadingReplies = false;
      _changed();
    }
  }

  Future<void> _refreshRequestNotices({required bool force}) async {
    final client = catalog.client;
    final history = _history;
    if (!requestsEnabled ||
        loadingRequestNotices ||
        isPreview ||
        client == null ||
        history == null) {
      return;
    }
    if (!force &&
        DateTime.now().difference(_lastRequestCheck) <
            const Duration(seconds: 120)) {
      return;
    }
    loadingRequestNotices = true;
    _lastRequestCheck = DateTime.now();
    _changed();
    try {
      final saved = history.load();
      requestReadIds.addAll(saved.readRequestIds);
      if (requestNotices.isEmpty) requestNotices = saved.requests;
      // Cached ready items already have a history entry; pending requests are
      // rechecked and only a real transition adds an item.
      final account = features.notificationReads
          ? accountNotificationReads
          : null;
      final result = await client.requestAvailabilityNotifications(
        readIds: account == null
            ? {
                ...saved.requests.map((n) => n.id),
                if (saved.requestsInitialized) ...saved.readRequestIds,
              }
            : <int>{},
      );
      if (_disposed || !requestsEnabled) return;
      final updated = await history.receiveRequests(
        result.notices,
        initializeSnapshot: account?.initialized != true,
      );
      if (_disposed) return;
      requestReadIds.addAll(updated.readRequestIds);
      requestNotices = updated.requests;
      hasOlderRequestNotices = result.hasOlder;
      requestNoticeError = null;
      if (account != null && features.notificationReads) {
        final ready = result.notices.map((n) => n.id).toSet();
        final migration = account.initialized
            ? updated.readRequestIds
                  .intersection(ready)
                  .difference(account.requests)
            : ready;
        if (!account.initialized || migration.isNotEmpty) {
          try {
            final synced = await client.markNotificationReads(
              requests: migration.toList(),
              initialize: !account.initialized,
            );
            if (_disposed || !features.notificationReads) return;
            accountNotificationReads =
                (accountNotificationReads ?? const NotificationReadState())
                    .merging(synced);
          } catch (_) {
            /* Local history survives; the next complete refresh retries. */
          }
        }
      }
    } catch (e) {
      if (_disposed) return;
      if (e is ClientError &&
          (e.kind == ClientErrorKind.unauthorized ||
              e.kind == ClientErrorKind.forbidden)) {
        requestNotices = [];
      }
      requestNoticeError =
          'Request updates could not be refreshed. Try again shortly.';
    } finally {
      loadingRequestNotices = false;
      _changed();
    }
  }

  Future<void> markRequestRead(RequestAvailabilityNotice notice) async {
    if (requestReadIds.contains(notice.id) && !features.notificationReads) {
      return;
    }
    final history = _history;
    if (isPreview || history == null) {
      requestReadIds.add(notice.id);
      _changed();
      return;
    }
    try {
      final savedIds = await history.seeRequest(notice.id);
      if (_disposed) return;
      requestReadIds.addAll(savedIds);
      requestNoticeError = null;
      _changed();
      final client = catalog.client;
      if (features.notificationReads &&
          accountNotificationReads?.requests.contains(notice.id) != true &&
          client != null) {
        try {
          final synced = await client.markNotificationReads(
            requests: [notice.id],
          );
          if (_disposed || !features.notificationReads) return;
          accountNotificationReads =
              (accountNotificationReads ?? const NotificationReadState())
                  .merging(synced);
        } catch (_) {
          /* Keep local read; a later sighting retries the POST. */
        }
      }
    } catch (_) {
      requestNoticeError =
          'This update could not be marked as read. Please try again.';
    }
    _changed();
  }

  Future<void> markReplyRead(SupportReply reply) async {
    if (seenReplyKeys.contains(reply.notificationKey) &&
        !features.notificationReads) {
      return;
    }
    final history = _history;
    if (isPreview || history == null) {
      seenReplyKeys.add(reply.notificationKey);
      if (!hiddenReplies.any(
        (r) => r.notificationKey == reply.notificationKey,
      )) {
        hiddenReplies = [reply, ...hiddenReplies];
      }
      _changed();
      return;
    }
    try {
      final saved = await history.seeReply(reply);
      if (_disposed) return;
      seenReplyKeys.addAll(saved.seenReplyKeys);
      hiddenReplies = saved.hiddenReplies;
      replyError = null;
      _changed();
      final client = catalog.client;
      if (features.notificationReads &&
          !reply.isAnnouncement &&
          accountNotificationReads?.replies.contains(reply.accountReadKey) !=
              true &&
          client != null) {
        try {
          final synced = await client.markNotificationReads(replies: [reply]);
          if (_disposed || !features.notificationReads) return;
          accountNotificationReads =
              (accountNotificationReads ?? const NotificationReadState())
                  .merging(synced);
        } catch (_) {
          /* Keep local read; a later sighting retries the POST. */
        }
      }
    } catch (_) {
      replyError =
          'This message could not be marked as read. Please try again.';
    }
    _changed();
  }

  void editSupport({String? issue, String? media, String? description}) {
    if (issue != null) supportIssue = issue;
    if (media != null) supportMedia = media;
    if (description != null) supportDescription = description;
    _changed();
  }

  /// One submission at a time; it survives closing the Support page and is
  /// discarded with this state on an account change.
  Future<void> sendSupport() async {
    final client = catalog.client;
    final report = supportReport;
    if (!features.support || isPreview || client == null || !report.isValid) {
      return;
    }
    if (submission != SupportSubmission.idle &&
        submission != SupportSubmission.rejected) {
      return;
    }
    submission = SupportSubmission.sending;
    _changed();
    try {
      ticketId = await client.submitSupport(report);
      if (_disposed) return;
      submission = SupportSubmission.accepted;
      supportDescription = '';
      supportMedia = '';
    } on SupportException catch (e) {
      if (_disposed) return;
      submission = e.error == SupportError.rejected
          ? SupportSubmission.rejected
          : SupportSubmission.uncertain;
    } catch (_) {
      if (_disposed) return;
      submission = SupportSubmission.uncertain;
    }
    _changed();
  }

  void startAnotherReport() {
    submission = SupportSubmission.idle;
    ticketId = null;
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// The shell's [ExtrasState] for the screens it hosts. Pages pushed on the
/// app navigator are outside it and take the state as a parameter.
class ExtrasScope extends InheritedNotifier<ExtrasState> {
  const ExtrasScope({
    super.key,
    required ExtrasState extras,
    required super.child,
  }) : super(notifier: extras);

  static ExtrasState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ExtrasScope>()?.notifier;
}
