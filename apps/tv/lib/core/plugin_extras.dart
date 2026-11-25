import 'errors.dart';
import 'jellyfin_client.dart';
import 'models.dart';

/// The Zorofin plugin's optional viewer extras (`GET /Zorofin/Extras`): which of
/// Calendar and Catch Up the operator turned on. Same reader as the web pack
/// (branding/zorofin-extras-pages.js). Missing route: neither.
class PluginExtras {
  const PluginExtras({this.calendar = false, this.catchUp = false});

  factory PluginExtras.fromJson(Object? json) => json is Map<String, dynamic>
      ? PluginExtras(
          calendar: json['calendar'] == true,
          catchUp: json['catchUp'] == true,
        )
      : const PluginExtras();

  static const none = PluginExtras();

  /// Upcoming episodes and movie releases from Sonarr and Radarr.
  final bool calendar;

  /// One unwatched title at a time: skip, watch later, seen it, or play.
  final bool catchUp;

  bool get any => calendar || catchUp;

  @override
  bool operator ==(Object other) =>
      other is PluginExtras &&
      other.calendar == calendar &&
      other.catchUp == catchUp;

  @override
  int get hashCode => Object.hash(calendar, catchUp);
}

/// One Calendar entry: an episode airing or a movie release.
class CalendarEvent {
  const CalendarEvent({
    required this.kind,
    required this.title,
    required this.at,
    required this.day,
    this.subtitle,
    this.allDay = false,
    this.release = '',
    this.hasFile = false,
    this.premiere = false,
    this.posterUrl,
    this.network,
    this.itemId,
  });

  /// Null when the entry has no usable date.
  static CalendarEvent? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final kind = value['kind'], at = value['at'], title = value['title'];
    if ((kind != 'episode' && kind != 'movie') ||
        at is! String ||
        title is! String) {
      return null;
    }
    final allDay = value['allDay'] == true;
    final DateTime when;
    final String day;
    if (allDay) {
      // Movie releases are dates, not times: they land on that date anywhere.
      final date = DateTime.tryParse(
        at.length >= 10 ? at.substring(0, 10) : at,
      );
      if (date == null) return null;
      when = DateTime(date.year, date.month, date.day);
      day = dayKey(when);
    } else {
      final parsed = DateTime.tryParse(at);
      if (parsed == null) return null;
      when = parsed.toLocal();
      day = dayKey(when);
    }
    final poster = value['posterUrl'];
    final posterUri = poster is String ? Uri.tryParse(poster) : null;
    return CalendarEvent(
      kind: kind as String,
      title: title,
      at: when,
      day: day,
      subtitle: value['subtitle'] is String
          ? value['subtitle'] as String
          : null,
      allDay: allDay,
      release: value['release'] is String ? value['release'] as String : '',
      hasFile: value['hasFile'] == true,
      premiere: value['premiere'] == true,
      // Only https artwork; the plugin already limits the hosts.
      posterUrl: posterUri != null && posterUri.scheme == 'https'
          ? posterUri
          : null,
      network: value['network'] is String ? value['network'] as String : null,
      itemId:
          value['itemId'] is String && (value['itemId'] as String).isNotEmpty
          ? value['itemId'] as String
          : null,
    );
  }

  /// `episode` or `movie`.
  final String kind;
  final String title;
  final DateTime at;

  /// The viewer's local day, `yyyy-MM-dd`.
  final String day;
  final String? subtitle;
  final bool allDay;

  /// `airing`, `cinema`, `digital` or `physical`.
  final String release;
  final bool hasFile;
  final bool premiere;
  final Uri? posterUrl;
  final String? network;

  /// The library item, when the title is already on the server.
  final String? itemId;

  bool get isEpisode => kind == 'episode';

  static const _releases = {
    'airing': 'New episode',
    'cinema': 'In cinemas',
    'digital': 'Digital release',
    'physical': 'On disc',
  };

  /// "Series premiere", "Season premiere", "New episode", "In cinemas"…
  String get badge {
    if (premiere) {
      return RegExp(r'^S1:E1\b').hasMatch(subtitle ?? '')
          ? 'Series premiere'
          : 'Season premiere';
    }
    return _releases[release] ?? '';
  }
}

/// What the Calendar shows: everything, shows only or movies only.
enum CalendarFilter {
  all('Everything'),
  shows('Shows'),
  movies('Movies');

  const CalendarFilter(this.label);
  final String label;

  bool keeps(CalendarEvent e) => switch (this) {
    all => true,
    shows => e.isEpisode,
    movies => !e.isEpisode,
  };
}

class CalendarDay {
  const CalendarDay(this.day, this.events);
  final String day;
  final List<CalendarEvent> events;
}

abstract final class CalendarAgenda {
  /// The four weeks the agenda shows, like the web.
  static const days = 28;

  /// Today onward, grouped by the viewer's local day, in date order.
  static List<CalendarDay> group(
    List<CalendarEvent> events,
    CalendarFilter filter,
    DateTime now,
  ) {
    final today = dayKey(now);
    final groups = <String, List<CalendarEvent>>{};
    for (final e in events) {
      if (!filter.keeps(e) || e.day.compareTo(today) < 0) continue;
      groups.putIfAbsent(e.day, () => []).add(e);
    }
    final keys = groups.keys.toList()..sort();
    return [
      for (final k in keys)
        CalendarDay(
          k,
          groups[k]!..sort((a, b) {
            if (a.allDay != b.allDay) return a.allDay ? 1 : -1;
            return a.at.compareTo(b.at);
          }),
        ),
    ];
  }

  static const _weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  /// "Today · Monday, November 9", "Tomorrow · …", or "Wednesday, November 11".
  static String label(String key, DateTime now) {
    final d = DateTime.tryParse(key);
    if (d == null) return key;
    final name =
        '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}';
    if (key == dayKey(now)) return 'Today · $name';
    if (key == dayKey(DateTime(now.year, now.month, now.day + 1))) {
      return 'Tomorrow · $name';
    }
    return name;
  }
}

String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Catch Up's four choices; the server log names them the same way.
enum CatchUpAction {
  skip('skip'),
  like('like'),
  later('later'),
  watched('watched'),
  watch('watch');

  const CatchUpAction(this.wire);
  final String wire;
}

/// What Catch Up offers.
enum CatchUpKind {
  all('Everything', 'Movie,Series'),
  movies('Movies', 'Movie'),
  shows('Shows', 'Series');

  const CatchUpKind(this.label, this.types);
  final String label;
  final String types;
}

extension PluginExtrasClient on JellyfinClient {
  /// Which extras the operator turned on. Missing plugin or route: none.
  Future<PluginExtras> pluginExtras() async {
    try {
      final json = await requestJson(
        ['Zorofin', 'Extras'],
        extensionToken: true,
        expectedStatus: 200,
      );
      return PluginExtras.fromJson(json);
    } on ClientError catch (e) {
      if (e.kind == ClientErrorKind.unavailable &&
          (e.status == 404 || e.status == 405)) {
        return PluginExtras.none;
      }
      if (e.kind == ClientErrorKind.forbidden) return PluginExtras.none;
      rethrow;
    }
  }

  /// Upcoming episodes and releases from `start` (the viewer's local day).
  Future<List<CalendarEvent>> calendar(
    DateTime start, {
    int days = CalendarAgenda.days,
  }) async {
    final json = await requestJson(
      ['Zorofin', 'Arr', 'Calendar'],
      query: {'start': dayKey(start), 'days': '$days'},
      extensionToken: true,
      expectedStatus: 200,
    );
    final items = json is Map<String, dynamic> ? json['items'] : null;
    if (items is! List) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return [for (final i in items) ?CalendarEvent.fromJson(i)];
  }

  /// Random watched/unwatched titles, excluding shared recommendation likes.
  Future<List<MediaItem>> catchUpTitles(CatchUpKind kind) async {
    final userId = session?.viewer.id;
    if (userId == null) throw const ClientError(ClientErrorKind.missingSession);
    final page = await request(
      ItemPage.fromJson,
      ['Users', userId, 'Items'],
      query: {
        'IncludeItemTypes': kind.types,
        'Recursive': 'true',
        'SortBy': 'Random',
        'Limit': '60',
        'HasOverview': 'true',
        'Fields':
            'Overview,ProductionYear,OfficialRating,CommunityRating,RunTimeTicks,ChildCount,Genres',
        'ImageTypeLimit': '1',
        'EnableImageTypes': 'Backdrop,Logo,Primary',
        'ExcludeLocationTypes': 'Virtual',
      },
    );
    final liked = _recommendationTasteIds(
      await requestJson(
        ['Zorofin', 'Companion', 'recommendations', 'taste'],
        extensionToken: true,
        expectedStatus: 200,
      ),
    );
    return page.items
        .where(
          (item) => !liked.contains(item.id.replaceAll('-', '').toLowerCase()),
        )
        .toList();
  }

  /// Pure recommendation preference; never changes Jellyfin user-data flags.
  Future<void> likeForRecommendations(String itemId) async {
    final liked = _recommendationTasteIds(
      await requestJson(
        ['Zorofin', 'Companion', 'recommendations', 'taste'],
        method: 'POST',
        body: {'itemId': itemId, 'action': 'like'},
        extensionToken: true,
        expectedStatus: 200,
      ),
    );
    if (!liked.contains(itemId.replaceAll('-', '').toLowerCase())) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
  }

  /// "Watch later": the viewer likes the title, which Zorofin treats as
  /// their watchlist (and Seerr's, when the operator links them).
  Future<void> likeItem(String itemId) async {
    final userId = session?.viewer.id;
    if (userId == null) throw const ClientError(ClientErrorKind.missingSession);
    await requestText(
      ['UserItems', itemId, 'Rating'],
      method: 'POST',
      query: {'userId': userId, 'likes': 'true'},
    );
  }

  /// Best effort: the operator's optional Catch Up log.
  Future<void> logCatchUp(String itemId, CatchUpAction action) async {
    try {
      await requestText(
        ['Zorofin', 'Extras', 'CatchUp', 'Log'],
        method: 'POST',
        body: {'itemId': itemId, 'action': action.wire},
        extensionToken: true,
      );
    } catch (_) {}
  }
}

/// Titles skipped in Catch Up, per server account, on this device only (the
/// web keeps them per browser). Newest 500.
class CatchUpSkips {
  CatchUpSkips({
    required this.read,
    required this.write,
    required String server,
    required String viewerId,
  }) : key = 'zorofin-catchup-skips:$server:$viewerId';

  final List<String>? Function(String key) read;
  final void Function(String key, List<String> value) write;
  final String key;

  List<String> get _all => read(key) ?? const [];

  bool contains(String id) => _all.contains(id);

  void add(String id) {
    final list = [..._all.where((x) => x != id), id];
    write(key, list.length > 500 ? list.sublist(list.length - 500) : list);
  }

  void remove(String id) =>
      write(key, _all.where((value) => value != id).toList());
  void clear() => write(key, const []);
}

/// Watched and unwatched titles are eligible; skip is neutral.
class CatchUpQueue {
  CatchUpQueue(List<MediaItem> titles, CatchUpSkips skips)
    : items = [
        for (final t in titles)
          if (!skips.contains(t.id)) t,
      ];

  final List<MediaItem> items;
  int index = 0;

  MediaItem? get current => index < items.length ? items[index] : null;
  bool get done => current == null;

  /// "3 of 42".
  String get position => '${index + 1} of ${items.length}';

  void next() {
    if (index < items.length) index++;
  }

  void restore(int position) {
    if (position >= 0 && position < items.length) index = position;
  }
}

Set<String> _recommendationTasteIds(Object? value) {
  if (value is! Map ||
      value['schemaVersion'] != 1 ||
      value['likedItemIds'] is! List) {
    throw const ClientError(ClientErrorKind.invalidResponse);
  }
  final ids = value['likedItemIds'] as List;
  if (ids.length > 500 || ids.any((id) => id is! String || id.isEmpty)) {
    throw const ClientError(ClientErrorKind.invalidResponse);
  }
  return ids
      .cast<String>()
      .map((id) => id.replaceAll('-', '').toLowerCase())
      .toSet();
}
