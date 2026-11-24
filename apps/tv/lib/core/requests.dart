import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'errors.dart';
import 'jellyfin_client.dart';
import 'models.dart';
import 'request_routes.dart';
import 'server_extras.dart';

/// Requests through the server's Jellyfin Enhanced proxy to Seerr (Apple
/// `Requests.swift`). Shown only when the server advertises Requests; the
/// server derives the viewer from the normal Jellyfin authorization.

enum RequestKind {
  movie,
  tv;

  static RequestKind? parse(Object? value) => switch (value) {
    'movie' => movie,
    'tv' => tv,
    _ => null,
  };
}

/// Availability and progress, separate from the viewer's selection.
enum RequestSeasonState {
  missing('Not available'),
  partlyAvailable('Partly available'),
  pendingApproval('Awaiting approval'),
  requested('Requested'),
  available('Available to watch'),
  unknown('Status unavailable');

  const RequestSeasonState(this.label);
  final String label;

  bool get requestable => this == missing || this == partlyAvailable;
}

int? _int(Object? v) => v is num ? v.toInt() : null;
String? _string(Object? v) => v is String ? v : null;
bool? _bool(Object? v) => v is bool ? v : null;
List<Map<String, dynamic>> _maps(Object? v) => [
  if (v is List)
    for (final e in v)
      if (e is Map<String, dynamic>) e,
];

class RequestSeason {
  const RequestSeason({
    required this.seasonNumber,
    this.name,
    this.episodeCount,
    this.status,
    this.status4k,
  });

  factory RequestSeason.fromJson(Map<String, dynamic> json) => RequestSeason(
    seasonNumber: _int(json['seasonNumber']) ?? -1,
    name: _string(json['name']),
    episodeCount: _int(json['episodeCount']),
    status: _int(json['status']),
    status4k: _int(json['status4k']),
  );

  final int seasonNumber;
  final String? name;
  final int? episodeCount;
  final int? status;
  final int? status4k;

  String get displayName =>
      name ?? (seasonNumber == 0 ? 'Specials' : 'Season $seasonNumber');
}

class RequestReceipt {
  const RequestReceipt({this.id, this.status, this.is4k, this.seasons});

  factory RequestReceipt.fromJson(Map<String, dynamic> json) => RequestReceipt(
    id: _int(json['id']),
    status: _int(json['status']),
    is4k: _bool(json['is4k']),
    seasons: json['seasons'] is List
        ? _maps(json['seasons']).map(RequestSeason.fromJson).toList()
        : null,
  );

  final int? id;
  final int? status;
  final bool? is4k;
  final List<RequestSeason>? seasons;
}

class RequestMediaInfo {
  const RequestMediaInfo({
    this.status,
    this.status4k,
    this.jellyfinMediaId,
    this.jellyfinMediaId4k,
    this.seasons,
    this.requests,
  });

  factory RequestMediaInfo.fromJson(Map<String, dynamic> json) =>
      RequestMediaInfo(
        status: _int(json['status']),
        status4k: _int(json['status4k']),
        jellyfinMediaId: _string(json['jellyfinMediaId']),
        jellyfinMediaId4k: _string(json['jellyfinMediaId4k']),
        seasons: json['seasons'] is List
            ? _maps(json['seasons']).map(RequestSeason.fromJson).toList()
            : null,
        requests: json['requests'] is List
            ? _maps(json['requests']).map(RequestReceipt.fromJson).toList()
            : null,
      );

  final int? status;
  final int? status4k;
  final String? jellyfinMediaId;
  final String? jellyfinMediaId4k;
  final List<RequestSeason>? seasons;
  final List<RequestReceipt>? requests;

  static String label(int? status) => switch (status) {
    null || 1 => 'Not requested',
    2 => 'Pending approval',
    3 => 'Requested',
    4 => 'Partly available',
    5 => 'Available',
    6 => 'Unavailable',
    7 => 'Removed',
    _ => 'Status unavailable',
  };
}

class RequestTitle {
  RequestTitle({
    required this.id,
    this.mediaType,
    this.title,
    this.name,
    this.overview,
    this.posterPath,
    this.releaseDate,
    this.firstAirDate,
    this.seasons,
    this.tvdbId,
    this.mediaInfo,
  });

  factory RequestTitle.fromJson(Map<String, dynamic> json) {
    final external = json['externalIds'];
    final info = json['mediaInfo'];
    return RequestTitle(
      id: _int(json['id']) ?? 0,
      mediaType: _string(json['mediaType']),
      title: _string(json['title']),
      name: _string(json['name']),
      overview: _string(json['overview']),
      posterPath: _string(json['posterPath']),
      releaseDate: _string(json['releaseDate']),
      firstAirDate: _string(json['firstAirDate']),
      seasons: json['seasons'] is List
          ? _maps(json['seasons']).map(RequestSeason.fromJson).toList()
          : null,
      tvdbId: external is Map ? _int(external['tvdbId']) : null,
      mediaInfo: info is Map<String, dynamic>
          ? RequestMediaInfo.fromJson(info)
          : null,
    );
  }

  final int id;
  String? mediaType;
  final String? title;
  final String? name;
  final String? overview;
  final String? posterPath;
  final String? releaseDate;
  final String? firstAirDate;
  final List<RequestSeason>? seasons;
  final int? tvdbId;
  final RequestMediaInfo? mediaInfo;

  String get displayTitle => title ?? name ?? 'Untitled';
  RequestKind? get kind => mediaType == null
      ? (name == null ? RequestKind.movie : RequestKind.tv)
      : RequestKind.parse(mediaType);
  String get identity => '${kind?.name ?? 'unknown'}-$id';
  String get year {
    final date = releaseDate ?? firstAirDate ?? '';
    return date.length >= 4 ? date.substring(0, 4) : date;
  }

  String status({bool is4K = false}) =>
      RequestMediaInfo.label(is4K ? mediaInfo?.status4k : mediaInfo?.status);

  RequestSeasonState seasonState(int number, {bool is4K = false}) {
    final season =
        mediaInfo?.seasons
            ?.where((s) => s.seasonNumber == number)
            .firstOrNull ??
        seasons?.where((s) => s.seasonNumber == number).firstOrNull;
    final status = is4K ? season?.status4k : season?.status;
    if (status == 5) return RequestSeasonState.available;
    final receipts = (mediaInfo?.requests ?? []).where(
      (r) =>
          (r.is4k ?? false) == is4K &&
          (r.seasons ?? []).any((s) => s.seasonNumber == number),
    );
    if (status == 3 || receipts.any((r) => r.status == 2)) {
      return RequestSeasonState.requested;
    }
    if (status == 2 || receipts.any((r) => r.status == 1)) {
      return RequestSeasonState.pendingApproval;
    }
    if (status == 4) return RequestSeasonState.partlyAvailable;
    if (status != null) {
      return const [1, 6, 7].contains(status)
          ? RequestSeasonState.missing
          : RequestSeasonState.unknown;
    }
    // A series-wide status cannot prove which seasons can play.
    final overall = is4K ? mediaInfo?.status4k : mediaInfo?.status;
    return overall == 5
        ? RequestSeasonState.unknown
        : RequestSeasonState.missing;
  }

  /// One request flow: a version in either quality is not offered again.
  RequestSeasonState requestSeasonState(int number) {
    final standard = seasonState(number);
    final high = seasonState(number, is4K: true);
    for (final state in const [
      RequestSeasonState.available,
      RequestSeasonState.requested,
      RequestSeasonState.pendingApproval,
      RequestSeasonState.partlyAvailable,
    ]) {
      if (standard == state || high == state) return state;
    }
    return standard == RequestSeasonState.unknown ||
            high == RequestSeasonState.unknown
        ? RequestSeasonState.unknown
        : RequestSeasonState.missing;
  }

  List<RequestSeason> eligibleSeasons({
    bool is4K = false,
    bool specials = false,
  }) => (seasons ?? [])
      .where(
        (s) =>
            s.seasonNumber >= (specials ? 0 : 1) &&
            (s.episodeCount ?? 0) > 0 &&
            seasonState(s.seasonNumber, is4K: is4K).requestable,
      )
      .toList();
}

class RequestPage {
  const RequestPage(this.results, {this.totalPages});
  final List<RequestTitle> results;
  final int? totalPages;
}

class RequestQuotaLimit {
  const RequestQuotaLimit({this.limit, this.used, this.days, this.restricted});

  factory RequestQuotaLimit.fromJson(Map<String, dynamic> json) =>
      RequestQuotaLimit(
        limit: _int(json['limit']),
        used: _int(json['used']),
        days: _int(json['days']),
        restricted: _bool(json['restricted']),
      );

  final int? limit;
  final int? used;
  final int? days;
  final bool? restricted;

  int? get remaining {
    final limit = this.limit;
    final used = this.used;
    if (limit == null || limit <= 0 || used == null) return null;
    return limit - used < 0 ? 0 : limit - used;
  }
}

class RequestQuota {
  const RequestQuota({this.movie, this.tv});

  factory RequestQuota.fromJson(Map<String, dynamic> json) => RequestQuota(
    movie: json['movie'] is Map<String, dynamic>
        ? RequestQuotaLimit.fromJson(json['movie'] as Map<String, dynamic>)
        : null,
    tv: json['tv'] is Map<String, dynamic>
        ? RequestQuotaLimit.fromJson(json['tv'] as Map<String, dynamic>)
        : null,
  );

  final RequestQuotaLimit? movie;
  final RequestQuotaLimit? tv;
  RequestQuotaLimit? limit(RequestKind kind) =>
      kind == RequestKind.movie ? movie : tv;
}

class RequestSeasonSettings {
  const RequestSeasonSettings({
    this.partialRequestsEnabled,
    this.enableSpecialEpisodes,
  });

  factory RequestSeasonSettings.fromJson(Map<String, dynamic> json) =>
      RequestSeasonSettings(
        partialRequestsEnabled: _bool(json['partialRequestsEnabled']),
        enableSpecialEpisodes: _bool(json['enableSpecialEpisodes']),
      );

  final bool? partialRequestsEnabled;
  final bool? enableSpecialEpisodes;
}

class RequestActivityItem {
  const RequestActivityItem({
    required this.id,
    this.type,
    this.tmdbId,
    this.title,
    this.posterUrl,
    this.mediaStatus,
    this.requestStatus,
    this.requestedBy,
    this.isComingSoon,
    this.isOrphaned,
  });

  factory RequestActivityItem.fromJson(Map<String, dynamic> json) =>
      RequestActivityItem(
        id: _int(json['id']) ?? 0,
        type: _string(json['type']),
        tmdbId: _int(json['tmdbId']),
        title: _string(json['title']),
        posterUrl: _string(json['posterUrl']),
        mediaStatus: _string(json['mediaStatus']),
        requestStatus: _int(json['requestStatus']),
        requestedBy: _string(json['requestedBy']),
        isComingSoon: _bool(json['isComingSoon']),
        isOrphaned: _bool(json['isOrphaned']),
      );

  final int id;
  final String? type;
  final int? tmdbId;
  final String? title;
  final String? posterUrl;
  final String? mediaStatus;
  final int? requestStatus;
  final String? requestedBy;
  final bool? isComingSoon;
  final bool? isOrphaned;

  RequestKind? get kind => RequestKind.parse(type);

  String get statusLabel {
    if (requestStatus == 1) return 'Pending approval';
    if (requestStatus == 3) return 'Declined';
    if (requestStatus == 4) return 'Request failed';
    if (mediaStatus == 'Available') return 'Available';
    if (isOrphaned == true) return 'Needs attention';
    if (isComingSoon == true) return 'Waiting for release';
    return switch (mediaStatus) {
      'Partially Available' => 'Partly available',
      'Pending' => 'Pending approval',
      'Processing' || 'Approved' => 'Requested',
      'Deleted' => 'Removed',
      'Failed' => 'Request failed',
      'Declined' => 'Declined',
      _ => 'Status unavailable',
    };
  }
}

class RequestActivityPage {
  const RequestActivityPage(this.requests, {this.totalPages});
  final List<RequestActivityItem> requests;
  final int? totalPages;
}

class RequestDownload {
  const RequestDownload({this.tmdbId, this.source, this.progress, this.status});

  factory RequestDownload.fromJson(Map<String, dynamic> json) =>
      RequestDownload(
        tmdbId: _int(json['tmdbId']),
        source: _string(json['source']),
        progress: (json['progress'] as num?)?.toDouble(),
        status: _string(json['status']),
      );

  final int? tmdbId;
  final String? source;
  final double? progress;
  final String? status;

  String get label {
    final text = (status ?? '').toLowerCase();
    if (text.contains('error') ||
        text.contains('warning') ||
        text.contains('failed')) {
      return 'Download needs attention';
    }
    if (text.contains('import') || (progress ?? 0) >= 100) {
      return 'Adding to library';
    }
    if (text.contains('paused')) return 'Download paused';
    final p = progress;
    if (p != null && p.isFinite && p > 0) {
      return 'Downloading · ${p.clamp(0, 99).toInt()}%';
    }
    return 'Download queued';
  }
}

class RequestQueue {
  const RequestQueue(this.items);
  final List<RequestDownload> items;

  /// Only joined to records the request API lets this viewer see.
  String? label(RequestActivityItem item) {
    final id = item.tmdbId;
    final kind = item.kind;
    if (item.requestStatus != 2 ||
        item.mediaStatus == 'Available' ||
        id == null ||
        kind == null) {
      return null;
    }
    final source = kind == RequestKind.movie ? 'radarr' : 'sonarr';
    return items
        .where((d) => d.tmdbId == id && d.source?.toLowerCase() == source)
        .firstOrNull
        ?.label;
  }
}

enum RequestFailure implements Exception {
  unavailable(
    'Requests is unavailable for this account. Contact your server owner.',
  ),
  invalidSelection(
    'These choices changed. Reload the title and select missing seasons.',
  ),
  alreadyRequested(
    'This title or selection is already available or requested. Refresh its status.',
  ),
  quota(
    'This selection exceeds your request limit. Try fewer seasons or wait for your limit to reset.',
  ),
  unconfirmed(
    'Delivery is unconfirmed. Check request activity or refresh this title. This app will not send it again automatically.',
  ),
  rejected(
    'The server did not accept this request. Refresh the title and check your permissions or request limit.',
  ),
  storage(
    'The app could not save the request receipt. No new request will be sent until storage is available.',
  ),
  inProgress(
    'This request may still be processing. Wait a minute, then refresh its status before allowing another attempt.',
  );

  const RequestFailure(this.message);
  final String message;
}

/// What one request asks for. TV seasons are sorted and unique.
class RequestIntent {
  RequestIntent({
    required this.kind,
    required this.id,
    this.is4k = false,
    Iterable<int> seasons = const [],
    int? tvdbId,
  }) : seasons = kind == RequestKind.tv
           ? (seasons.toSet().toList()..sort())
           : null,
       tvdbId = kind == RequestKind.tv && (tvdbId ?? 0) > 0 ? tvdbId : null;

  factory RequestIntent.fromJson(Map<String, dynamic> json) => RequestIntent(
    kind: RequestKind.parse(json['mediaType']) ?? RequestKind.movie,
    id: _int(json['mediaId']) ?? 0,
    is4k: json['is4k'] == true,
    seasons: [
      if (json['seasons'] is List)
        for (final s in json['seasons'] as List)
          if (s is int) s,
    ],
    tvdbId: _int(json['tvdbId']),
  );

  final RequestKind kind;
  final int id;
  final bool is4k;
  final List<int>? seasons;
  final int? tvdbId;

  Map<String, dynamic> toJson() => {
    'mediaType': kind.name,
    'mediaId': id,
    'is4k': is4k,
    'seasons': ?seasons,
    'tvdbId': ?tvdbId,
  };

  bool overlaps(RequestIntent other) =>
      kind == other.kind &&
      id == other.id &&
      is4k == other.is4k &&
      (kind == RequestKind.movie ||
          (seasons ?? [])
              .toSet()
              .intersection((other.seasons ?? []).toSet())
              .isNotEmpty);

  @override
  bool operator ==(Object other) =>
      other is RequestIntent &&
      other.kind == kind &&
      other.id == id &&
      other.is4k == is4k &&
      _sameList(other.seasons, seasons);

  @override
  int get hashCode =>
      Object.hash(kind, id, is4k, Object.hashAll(seasons ?? []));

  static bool _sameList(List<int>? a, List<int>? b) =>
      (a ?? []).length == (b ?? []).length &&
      Iterable<int>.generate((a ?? []).length).every((i) => a![i] == b![i]);

  void validate(
    RequestTitle title, {
    RequestSeasonSettings? settings,
    RequestQuota? quota,
  }) {
    if (id <= 0 || title.id != id || title.kind != kind) {
      throw RequestFailure.invalidSelection;
    }
    if (kind == RequestKind.movie) {
      final status =
          (is4k ? title.mediaInfo?.status4k : title.mediaInfo?.status) ?? 1;
      if (!const [1, 6, 7].contains(status) ||
          (title.mediaInfo?.requests ?? []).any(
            (r) => (r.is4k ?? false) == is4k && const [1, 2].contains(r.status),
          )) {
        throw RequestFailure.alreadyRequested;
      }
    } else {
      if (settings == null) throw RequestFailure.unavailable;
      final eligible = title
          .eligibleSeasons(
            is4K: is4k,
            specials: settings.enableSpecialEpisodes == true,
          )
          .map((s) => s.seasonNumber)
          .toSet();
      final selected = (seasons ?? []).toSet();
      if (selected.isEmpty ||
          !eligible.containsAll(selected) ||
          (settings.partialRequestsEnabled != true &&
              (selected.length != eligible.length))) {
        throw RequestFailure.invalidSelection;
      }
    }
    final limit = quota?.limit(kind);
    final remaining = limit?.remaining;
    final needed = kind == RequestKind.movie ? 1 : (seasons?.length ?? 0);
    if (limit?.restricted == true ||
        (remaining != null && remaining < needed)) {
      throw RequestFailure.quota;
    }
  }
}

/// Public TMDB artwork only, loaded without Jellyfin credentials.
abstract final class RequestArtwork {
  static final _path = RegExp(r'^/[A-Za-z0-9_-]+\.(jpg|png|webp)$');
  static final _absolute = RegExp(
    r'^/t/p/(w[0-9]+|original)/[A-Za-z0-9_-]+\.(jpg|png|webp)$',
  );

  static Uri? path(String? path) => path != null && _path.hasMatch(path)
      ? Uri.parse('https://image.tmdb.org/t/p/w342$path')
      : null;

  static Uri? absolute(String? value) {
    final url = value == null ? null : Uri.tryParse(value);
    if (url == null ||
        url.scheme != 'https' ||
        url.host != 'image.tmdb.org' ||
        url.hasPort ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        !_absolute.hasMatch(url.path)) {
      return null;
    }
    return path('/${url.pathSegments.last}');
  }
}

enum RequestDiscoverySection {
  recommended('Recommended to request'),
  trending('Trending now'),
  movies('Popular movies'),
  tv('Popular TV shows'),
  upcoming('Coming soon');

  const RequestDiscoverySection(this.title);
  final String title;
}

class RequestDiscoveryRow {
  const RequestDiscoveryRow(this.section, this.titles, {this.failed = false});
  final RequestDiscoverySection section;
  final List<RequestTitle> titles;
  final bool failed;
}

/// A request that became ready to watch, for the notification inbox.
class RequestAvailabilityNotice {
  const RequestAvailabilityNotice({
    required this.id,
    required this.kind,
    required this.titleId,
    required this.title,
    this.posterUrl,
    this.is4K = false,
  });

  factory RequestAvailabilityNotice.fromJson(Map<String, dynamic> json) =>
      RequestAvailabilityNotice(
        id: _int(json['id']) ?? 0,
        kind: RequestKind.parse(json['kind']) ?? RequestKind.movie,
        titleId: _int(json['titleId']) ?? 0,
        title: _string(json['title']) ?? '',
        posterUrl: _string(json['posterUrl']),
        is4K: json['is4K'] == true,
      );

  final int id;
  final RequestKind kind;
  final int titleId;
  final String title;
  final String? posterUrl;
  final bool is4K;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'titleId': titleId,
    'title': title,
    'posterUrl': ?posterUrl,
    'is4K': is4K,
  };

  static RequestAvailabilityNotice? from(
    RequestActivityItem activity,
    RequestTitle detail,
  ) {
    final kind = activity.kind;
    final title = activity.title?.trim() ?? '';
    final receipt = detail.mediaInfo?.requests
        ?.where((r) => r.id == activity.id)
        .firstOrNull;
    final is4K = receipt?.is4k;
    if (activity.id <= 0 ||
        !const [2, 5].contains(activity.requestStatus) ||
        kind == null ||
        activity.tmdbId != detail.id ||
        title.isEmpty ||
        receipt == null ||
        !const [2, 5].contains(receipt.status) ||
        is4K == null ||
        !isAvailable(detail, receipt, is4K: is4K)) {
      return null;
    }
    return RequestAvailabilityNotice(
      id: activity.id,
      kind: kind,
      titleId: detail.id,
      title: activity.title!,
      posterUrl: RequestArtwork.absolute(activity.posterUrl)?.toString(),
      is4K: is4K,
    );
  }

  /// A show can be partly available while every season of this request is
  /// ready; another season being ready never fulfils it.
  static bool isAvailable(
    RequestTitle title,
    RequestReceipt receipt, {
    required bool is4K,
  }) {
    final status = is4K ? title.mediaInfo?.status4k : title.mediaInfo?.status;
    if (!const [4, 5].contains(status)) return false;
    final seasons = receipt.seasons;
    if (title.kind == RequestKind.tv && seasons != null && seasons.isNotEmpty) {
      return seasons.every((requested) {
        final season = title.mediaInfo?.seasons
            ?.where((s) => s.seasonNumber == requested.seasonNumber)
            .firstOrNull;
        if (requested.seasonNumber < 0 || season == null) return false;
        return (is4K ? season.status4k : season.status) == 5;
      });
    }
    return status == 5;
  }
}

List<RequestTitle> uniqueRequestTitles(
  Iterable<RequestTitle> titles,
  int limit,
) {
  final seen = <String>{};
  return titles
      .where((t) => t.id > 0 && t.kind != null && seen.add(t.identity))
      .take(limit)
      .toList();
}

extension Requests on JellyfinClient {
  RequestRoutes get _routes => RequestRoutes.of(this);

  Future<Map<String, dynamic>> _object(
    List<String> path, {
    Map<String, String> query = const {},
  }) async {
    final json = await requestJson(path, query: query);
    if (json is! Map<String, dynamic>) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return json;
  }

  Future<bool> requestAccessAvailable() async {
    final json = await _object(_routes.userStatus);
    return json['active'] == true && json['userFound'] == true;
  }

  Future<RequestQuota> requestQuota() async =>
      RequestQuota.fromJson(await _object(_routes.quota));

  Future<RequestSeasonSettings> requestSeasonSettings() async =>
      RequestSeasonSettings.fromJson(await _object(_routes.seasonSettings));

  Future<RequestPage> requestTitles({
    String category = 'trending',
    String query = '',
    int page = 1,
  }) async {
    final term = query.trim();
    final bounded = term.length > 256 ? term.substring(0, 256) : term;
    if (!const ['trending', 'movies', 'tv', 'upcoming'].contains(category) ||
        page < 1 ||
        page > 500) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    final path = bounded.isEmpty
        ? _routes.discover(
            category == 'upcoming' ? ['movies', 'upcoming'] : [category],
          )
        : _routes.search;
    final json = await _object(
      path,
      query: {'page': '$page', if (bounded.isNotEmpty) 'query': bounded},
    );
    return RequestPage(
      _maps(json['results']).map(RequestTitle.fromJson).toList(),
      totalPages: _int(json['totalPages']),
    );
  }

  Future<RequestTitle> requestTitle(RequestKind kind, int id) async {
    if (id <= 0) throw const ClientError(ClientErrorKind.invalidResponse);
    final title = RequestTitle.fromJson(await _object(_routes.title(kind, id)));
    if (title.id != id) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    title.mediaType = kind.name;
    return title;
  }

  Future<RequestActivityPage> requestActivity({
    bool mine = true,
    int page = 1,
    String filter = 'all',
    int take = 24,
  }) async {
    if (page < 1 ||
        page > 500 ||
        !const [
          'all',
          'pending',
          'approved',
          'processing',
          'available',
        ].contains(filter)) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    final json = await _object(
      _routes.activity,
      query: {
        'userOnly': '$mine',
        'take': '$take',
        'skip': '${(page - 1) * take}',
        'filter': filter,
      },
    );
    return RequestActivityPage(
      _maps(json['requests']).map(RequestActivityItem.fromJson).toList(),
      totalPages: _int(json['totalPages']),
    );
  }

  Future<RequestQueue> requestQueue() async {
    final json = await _object(_routes.queue);
    return RequestQueue(
      _maps(json['items']).map(RequestDownload.fromJson).toList(),
    );
  }

  /// Optional personalized feed; only a ready feed renders.
  Future<List<RequestTitle>> requestRecommendations() async {
    final json = await requestJson(
      ['support', 'recommendations'],
      extensionToken: true,
      expectedStatus: 200,
    );
    if (json is! Map || json['state'] != 'ready') return const [];
    final titles = <RequestTitle>[];
    for (final item in _maps(json['items'])) {
      final id = _int(item['tmdbId']) ?? 0;
      final name = _string(item['title'])?.trim() ?? '';
      final poster = RequestArtwork.absolute(_string(item['posterUrl']));
      if (id <= 0 || name.isEmpty || poster == null) continue;
      final year = item['year'];
      final value = year is int ? year : int.tryParse('${year ?? ''}');
      titles.add(
        RequestTitle(
          id: id,
          mediaType: 'movie',
          title: name,
          overview: _string(item['overview']),
          posterPath: '/${poster.pathSegments.last}',
          releaseDate: value != null && value >= 1800 && value <= 3000
              ? '$value'
              : null,
        ),
      );
    }
    return uniqueRequestTitles(titles, 20);
  }

  /// Independent rows that fail independently; reads only.
  Future<List<RequestDiscoveryRow>> requestDiscovery({
    required bool includeRecommendations,
    void Function(RequestDiscoveryRow row)? onRow,
  }) async {
    final sections = RequestDiscoverySection.values.where(
      (s) => includeRecommendations || s != RequestDiscoverySection.recommended,
    );
    final rows = await Future.wait([
      for (final section in sections)
        () async {
          RequestDiscoveryRow row;
          try {
            final titles = section == RequestDiscoverySection.recommended
                ? await requestRecommendations()
                : (await requestTitles(category: section.name)).results;
            row = RequestDiscoveryRow(section, uniqueRequestTitles(titles, 20));
          } on ClientError catch (e) {
            if (e.kind == ClientErrorKind.unavailable &&
                e.status == 404 &&
                section == RequestDiscoverySection.recommended) {
              row = RequestDiscoveryRow(section, const []);
            } else {
              row = RequestDiscoveryRow(section, const [], failed: true);
            }
          }
          onRow?.call(row);
          return row;
        }(),
    ]);
    return rows;
  }

  /// The viewer's latest 100 requests that became ready to watch. Read IDs
  /// skip detail reads for notifications already acknowledged.
  Future<({List<RequestAvailabilityNotice> notices, bool hasOlder})>
  requestAvailabilityNotifications({Set<int> readIds = const {}}) async {
    final candidates = <RequestActivityItem>[];
    final seen = <int>{};
    var totalPages = 1;
    for (var page = 1; page <= 2; page++) {
      final result = await requestActivity(page: page, take: 50);
      totalPages = (result.totalPages ?? 1) < 1 ? 1 : result.totalPages!;
      if (result.requests.length > 50 || totalPages > 10000) {
        throw const ClientError(ClientErrorKind.invalidResponse);
      }
      candidates.addAll(
        result.requests.where(
          (r) =>
              r.id > 0 &&
              !readIds.contains(r.id) &&
              seen.add(r.id) &&
              const [2, 5].contains(r.requestStatus) &&
              r.kind != null &&
              (r.tmdbId ?? 0) > 0,
        ),
      );
      if (page >= totalPages) break;
    }
    final groups = <String, List<RequestActivityItem>>{};
    for (final c in candidates) {
      groups.putIfAbsent('${c.type}-${c.tmdbId}', () => []).add(c);
    }
    final resolved = <int, RequestAvailabilityNotice>{};
    final batches = groups.values.toList();
    for (var start = 0; start < batches.length; start += 4) {
      final batch = batches.skip(start).take(4);
      final notices = await Future.wait([
        for (final activities in batch)
          requestTitle(activities.first.kind!, activities.first.tmdbId!).then(
            (detail) => [
              for (final a in activities)
                ?RequestAvailabilityNotice.from(a, detail),
            ],
          ),
      ]);
      for (final n in notices.expand((n) => n)) {
        resolved[n.id] = n;
      }
    }
    return (
      notices: [for (final c in candidates) ?resolved[c.id]],
      hasOlder: totalPages > 2,
    );
  }

  /// Re-resolved at the tap so current permissions decide; never plays.
  Future<MediaItem> requestNotificationItem(
    RequestAvailabilityNotice notice,
  ) async {
    final title = await requestTitle(notice.kind, notice.titleId);
    final receipt = title.mediaInfo?.requests
        ?.where((r) => r.id == notice.id)
        .firstOrNull;
    if (receipt == null ||
        !const [2, 5].contains(receipt.status) ||
        receipt.is4k != notice.is4K ||
        !RequestAvailabilityNotice.isAvailable(
          title,
          receipt,
          is4K: notice.is4K,
        )) {
      throw StateError('no longer available');
    }
    final id = notice.is4K
        ? title.mediaInfo?.jellyfinMediaId4k
        : title.mediaInfo?.jellyfinMediaId;
    if (id == null || id.isEmpty) throw StateError('library link missing');
    return item(id);
  }

  Future<RequestReceipt> postRequest(RequestIntent intent) async {
    final json = await requestJson(
      _routes.submit,
      method: 'POST',
      body: intent.toJson(),
    );
    if (json is! Map<String, dynamic>) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return RequestReceipt.fromJson(json);
  }
}

/// A durable guard, not an invented idempotency contract: saved before each
/// send and never replayed. Holds media IDs, seasons and times only.
class RequestJournalEntry {
  RequestJournalEntry({
    required this.id,
    required this.intent,
    required this.created,
    this.receiptId,
  });

  factory RequestJournalEntry.fromJson(Map<String, dynamic> json) =>
      RequestJournalEntry(
        id: json['id'] as String,
        intent: RequestIntent.fromJson(json['intent'] as Map<String, dynamic>),
        created: DateTime.parse(json['created'] as String),
        receiptId: _int(json['receiptId']),
      );

  final String id;
  final RequestIntent intent;
  final DateTime created;
  int? receiptId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'intent': intent.toJson(),
    'created': created.toUtc().toIso8601String(),
    'receiptId': ?receiptId,
  };
}

class RequestJournal {
  RequestJournal(
    this._prefs, {
    required String server,
    required String viewerId,
  }) : _key = 'zorofin.request-receipts.v1.${stableHash('$server\n$viewerId')}';

  final SharedPreferences _prefs;
  final String _key;
  static final _inFlight = <String>{};
  static var _serial = 0;

  List<RequestJournalEntry> entries() {
    final raw = _prefs.getString(_key);
    if (raw == null) return [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          RequestJournalEntry.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      throw RequestFailure.storage;
    }
  }

  Future<void> _save(List<RequestJournalEntry> entries) async {
    final ok = await _prefs.setString(
      _key,
      jsonEncode([for (final e in entries) e.toJson()]),
    );
    if (!ok) throw RequestFailure.storage;
  }

  Future<RequestJournalEntry> begin(RequestIntent intent) async {
    final saved = entries();
    final existing = saved.where((e) => e.intent.overlaps(intent)).firstOrNull;
    if (existing != null) {
      throw existing.receiptId == null
          ? RequestFailure.unconfirmed
          : RequestFailure.alreadyRequested;
    }
    final entry = RequestJournalEntry(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_serial++}',
      intent: intent,
      created: DateTime.now(),
    );
    await _save([...saved, entry]);
    _inFlight.add(entry.id);
    return entry;
  }

  Future<void> accepted(String id, int receiptId) async {
    final saved = entries();
    final entry = saved.where((e) => e.id == id).firstOrNull;
    if (entry == null) throw RequestFailure.storage;
    entry.receiptId = receiptId;
    await _save(saved);
    _inFlight.remove(id);
  }

  Future<void> rejected(String id) async {
    await _save(entries().where((e) => e.id != id).toList());
    _inFlight.remove(id);
  }

  void finishedUnconfirmed(String id) => _inFlight.remove(id);

  /// Only after the viewer acknowledges uncertain delivery. Sends nothing.
  Future<void> clearUnconfirmed(Set<RequestIntent> intents) async {
    final saved = entries();
    final clearing = saved.where(
      (e) => e.receiptId == null && intents.contains(e.intent),
    );
    if (clearing.any(
      (e) =>
          _inFlight.contains(e.id) ||
          DateTime.now().difference(e.created) < const Duration(minutes: 1),
    )) {
      throw RequestFailure.inProgress;
    }
    await _save(
      saved
          .where((e) => e.receiptId != null || !intents.contains(e.intent))
          .toList(),
    );
  }

  Future<void> reconcile(RequestTitle title) async {
    final saved = entries();
    var changed = false;
    for (final entry in saved) {
      final intent = entry.intent;
      if (intent.id != title.id || intent.kind != title.kind) continue;
      final match = title.mediaInfo?.requests?.where((r) {
        final seasons = (r.seasons ?? []).map((s) => s.seasonNumber).toSet();
        return (r.id ?? 0) > 0 &&
            (r.is4k ?? false) == intent.is4k &&
            const [1, 2, 5].contains(r.status) &&
            (intent.kind == RequestKind.movie ||
                seasons.containsAll(intent.seasons ?? []));
      }).firstOrNull;
      if (match != null && entry.receiptId != match.id) {
        entry.receiptId = match.id;
        changed = true;
      }
    }
    final terminal = {
      for (final r in title.mediaInfo?.requests ?? <RequestReceipt>[])
        if (const [3, 4].contains(r.status) && r.id != null) r.id!,
    };
    final remaining = saved
        .where(
          (e) =>
              !(e.intent.id == title.id &&
                  e.intent.kind == title.kind &&
                  e.receiptId != null &&
                  terminal.contains(e.receiptId)),
        )
        .toList();
    if (changed || remaining.length != saved.length) await _save(remaining);
  }
}

/// Fresh access, detail, quota and season checks before the single POST.
class RequestSubmissionService {
  RequestSubmissionService(this.client, this.journal);

  final JellyfinClient client;
  final RequestJournal journal;

  Future<void> allowAnotherAttempt(RequestKind kind, int id) async {
    if (!await client.requestAccessAvailable()) {
      throw RequestFailure.unavailable;
    }
    final title = await client.requestTitle(kind, id);
    final quota = await client.requestQuota();
    final settings = kind == RequestKind.tv
        ? await client.requestSeasonSettings()
        : null;
    final entries = journal.entries().where(
      (e) =>
          e.receiptId == null &&
          e.intent.id == id &&
          e.intent.kind == kind &&
          !e.intent.is4k,
    );
    for (final entry in entries) {
      entry.intent.validate(title, settings: settings, quota: quota);
    }
    await journal.clearUnconfirmed(entries.map((e) => e.intent).toSet());
  }

  Future<RequestReceipt> submit(RequestIntent intent) async {
    if (!await client.requestAccessAvailable()) {
      throw RequestFailure.unavailable;
    }
    final title = await client.requestTitle(intent.kind, intent.id);
    final quota = await client.requestQuota();
    final settings = intent.kind == RequestKind.tv
        ? await client.requestSeasonSettings()
        : null;
    intent.validate(title, settings: settings, quota: quota);
    final entry = await journal.begin(intent);
    try {
      final receipt = await client.postRequest(intent);
      final id = receipt.id;
      if (id == null || id <= 0) throw RequestFailure.unconfirmed;
      await journal.accepted(entry.id, id);
      return receipt;
    } catch (error) {
      journal.finishedUnconfirmed(entry.id);
      // Only these explicit responses establish rejection; conflicts, 5xx,
      // malformed bodies and disconnects can have side effects upstream.
      if (error is ClientError &&
          (error.kind == ClientErrorKind.unauthorized ||
              error.kind == ClientErrorKind.forbidden ||
              (error.kind == ClientErrorKind.unavailable &&
                  const [400, 404, 422, 429].contains(error.status)))) {
        await journal.rejected(entry.id);
        throw RequestFailure.rejected;
      }
      throw RequestFailure.unconfirmed;
    }
  }
}
