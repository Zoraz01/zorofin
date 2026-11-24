import 'dart:convert';
import 'dart:math';

import 'errors.dart';
import 'jellyfin_client.dart';
import 'media_quality.dart';
import 'models.dart';

/// Small reproducible generator for per-visit layout choices (Apple
/// `HomeRandom`, SplitMix64). Never used for security.
class HomeRandom {
  HomeRandom([int? seed])
    : _state =
          seed ?? Random().nextInt(1 << 32) << 32 | Random().nextInt(1 << 32);

  int _state;

  int next() {
    _state += 0x9E3779B97F4A7C15;
    var value = _state;
    value = (value ^ (value >>> 30)) * 0xBF58476D1CE4E5B9;
    value = (value ^ (value >>> 27)) * 0x94D049BB133111EB;
    return value ^ (value >>> 31);
  }

  int nextInt(int max) => (next() >>> 1) % max;

  void shuffle<T>(List<T> list) {
    for (var i = list.length - 1; i > 0; i--) {
      final j = nextInt(i + 1);
      final t = list[i];
      list[i] = list[j];
      list[j] = t;
    }
  }
}

/// The client-selected Home feature (Apple `HomeBanner`): a highly rated
/// title with the best artwork, chosen once per Home visit.
class HomeBanner {
  HomeBanner({int? seed}) : _random = HomeRandom(seed);

  final HomeRandom _random;
  MediaItem? item;

  void update(
    List<MediaItem> candidates, {
    List<MediaItem> featured = const [],
  }) {
    final preferred = _eligible(featured);
    final available = preferred.isEmpty ? _eligible(candidates) : preferred;
    final rated = available
        .where(
          (i) =>
              (i.communityRating ?? 0).isFinite &&
              (i.communityRating ?? 0) >= 7,
        )
        .toList();
    final pool = rated.isEmpty ? available : rated;
    final best = pool.map(_artworkRank).fold(0, max);
    final seen = <String>{};
    final finalists = [
      for (final i in pool)
        if (_artworkRank(i) == best && seen.add(i.id)) i,
    ];
    final current = finalists.where((i) => i.id == item?.id).firstOrNull;
    if (current != null) {
      item = current;
    } else if (finalists.isEmpty) {
      item = null;
    } else {
      final top = finalists.take(8).toList();
      item = top[_random.nextInt(top.length)];
    }
  }

  static List<MediaItem> _eligible(List<MediaItem> items) => [
    for (final i in items)
      if ((i.type == 'Movie' || i.isSeries) &&
          i.id.trim().isNotEmpty &&
          i.name.trim().isNotEmpty)
        i,
  ];

  static int _artworkRank(MediaItem item) {
    if (item.backdropImageTags.any((t) => t.isNotEmpty)) return 2;
    if ((item.imageTags['Primary'] ?? '').isNotEmpty) return 1;
    return 0;
  }
}

enum HomeRowKind { deliberate, generated }

/// Weighted random order for the unpinned part of Home (Apple
/// `HomeRowOrder`). Rows already placed never move.
class HomeRowOrder {
  HomeRowOrder({int? seed}) : _random = HomeRandom(seed);

  static const pinnedIds = ['shelf-0', 'requests-ready', 'sports-live-events'];

  final HomeRandom _random;
  final List<String> ids = [];
  final Set<String> _seen = {...pinnedIds};

  /// Deliberate rows hold three tickets and generated rows one, sampled
  /// without replacement.
  void append(List<(String, HomeRowKind)> candidates) {
    final pending = [
      for (final c in candidates)
        if (c.$1.isNotEmpty && _seen.add(c.$1)) c,
    ];
    while (pending.isNotEmpty) {
      final total = pending.fold(
        0,
        (sum, c) => sum + (c.$2 == HomeRowKind.deliberate ? 3 : 1),
      );
      var ticket = _random.nextInt(total);
      var selected = 0;
      for (final (i, c) in pending.indexed) {
        ticket -= c.$2 == HomeRowKind.deliberate ? 3 : 1;
        if (ticket < 0) {
          selected = i;
          break;
        }
      }
      ids.add(pending.removeAt(selected).$1);
    }
  }
}

/// Resume points and next episodes as one shelf; a show with an unfinished
/// episode keeps that one (Apple `ContinueWatchingFeed`).
List<MediaItem> continueWatching(
  List<MediaItem> resume,
  List<MediaItem> nextUp, {
  int limit = 40,
}) {
  final ids = <String>{};
  final series = <String>{};
  final selected = <MediaItem>[];
  final cap = limit.clamp(0, 40);
  final candidates = [
    ...resume.where((i) => i.type == 'Movie' || i.isEpisode),
    ...nextUp.where((i) => i.isEpisode && i.userData?.played != true),
  ];
  for (final item in candidates) {
    if (selected.length >= cap) break;
    if (item.id.isEmpty || item.name.isEmpty || ids.contains(item.id)) continue;
    final show = item.isEpisode ? item.seriesId?.trim() : null;
    if (show != null && show.isNotEmpty && series.contains(show)) continue;
    ids.add(item.id);
    if (show != null && show.isNotEmpty) series.add(show);
    selected.add(item);
  }
  return selected;
}

/// A small browse selection from recent movies and shows (Apple
/// `SearchRecommendations`): unwatched, with artwork and rating first,
/// alternating movies and shows.
List<MediaItem> searchRecommendations(List<MediaItem> items, {int limit = 24}) {
  final seen = <String>{};
  double rating(MediaItem i) {
    final r = i.communityRating;
    return r != null && r.isFinite && r >= 0 && r <= 10 ? r : 0;
  }

  final ranked =
      [
        for (final (i, item) in items.indexed)
          if ((item.type == 'Movie' || item.isSeries) &&
              item.id.isNotEmpty &&
              item.name.isNotEmpty &&
              seen.add(item.id))
            (i, item),
      ]..sort((x, y) {
        final a = x.$2, b = y.$2;
        final pa = a.userData?.played == true, pb = b.userData?.played == true;
        if (pa != pb) return pa ? 1 : -1;
        final aa = (a.imageTags['Primary'] ?? '').isNotEmpty;
        final ba = (b.imageTags['Primary'] ?? '').isNotEmpty;
        if (aa != ba) return aa ? -1 : 1;
        final ra = rating(a), rb = rating(b);
        if (ra != rb) return rb.compareTo(ra);
        return x.$1.compareTo(y.$1);
      });
  final movies = [
    for (final r in ranked)
      if (r.$2.type == 'Movie') r.$2,
  ];
  final shows = [
    for (final r in ranked)
      if (r.$2.isSeries) r.$2,
  ];
  final cap = limit.clamp(0, 24);
  final result = <MediaItem>[];
  for (var i = 0; i < max(movies.length, shows.length); i++) {
    if (i < movies.length && result.length < cap) result.add(movies[i]);
    if (i < shows.length && result.length < cap) result.add(shows[i]);
    if (result.length >= cap) break;
  }
  return result;
}

// MARK: Home rows

/// One card in a personal Home row.
class HomeRowCard {
  const HomeRowCard({
    required this.id,
    required this.item,
    this.subtitle = '',
    this.badges = const [],
    this.startsAt,
    this.endsAt,
  });

  factory HomeRowCard.fromJson(Map<String, dynamic> json) => HomeRowCard(
    id: json['id'] as String,
    item: MediaItem.fromJson(json['item'] as Map<String, dynamic>),
    subtitle: json['subtitle'] as String? ?? '',
    badges: [
      for (final b in json['badges'] as List? ?? const [])
        if (b is String) b,
    ],
    startsAt: json['startsAt'] as String?,
    endsAt: json['endsAt'] as String?,
  );

  final String id;
  final MediaItem item;
  final String subtitle;
  final List<String> badges;
  final String? startsAt;
  final String? endsAt;

  static const _formats = {
    '4K',
    '8K',
    '1080p',
    '720p',
    'HDR',
    'HDR10',
    'HDR10+',
    'Dolby Vision',
    'HLG',
  };

  List<String> get qualityBadges => badges.where(_formats.contains).toList();
  List<String> get contextBadges =>
      badges.where((b) => !_formats.contains(b)).toList();

  bool isExpired(DateTime now) {
    final end = jellyfinDate(endsAt);
    return end != null && !end.isAfter(now);
  }

  HomeRowCard withItem(MediaItem value) => HomeRowCard(
    id: id,
    item: value,
    subtitle: subtitle,
    badges: badges,
    startsAt: startsAt,
    endsAt: endsAt,
  );
}

/// A personal row: computed on the device, or from the optional server feed.
class HomeFeedRow {
  const HomeFeedRow({
    required this.id,
    required this.title,
    this.description = '',
    this.state = 'ready',
    this.message,
    this.cards = const [],
  });

  factory HomeFeedRow.fromJson(Map<String, dynamic> json) => HomeFeedRow(
    id: json['id'] as String,
    title: json['title'] as String,
    description: json['description'] as String? ?? '',
    state: json['state'] as String? ?? 'ready',
    message: json['message'] as String?,
    cards: [
      for (final c in json['cards'] as List? ?? const [])
        HomeRowCard.fromJson(c as Map<String, dynamic>),
    ],
  );

  final String id;
  final String title;
  final String description;

  /// ready, empty or unavailable.
  final String state;
  final String? message;
  final List<HomeRowCard> cards;

  HomeFeedRow withCards(List<HomeRowCard> value) => HomeFeedRow(
    id: id,
    title: title,
    description: description,
    state: state,
    message: message,
    cards: value,
  );
}

/// Row ids and titles in the server contract's order.
const homeRowOptions = [
  ('requests-ready', 'Your requests are ready'),
  ('new-episodes', 'New episodes for you'),
  ('short-movies', 'Watch in your available time'),
  ('showcase', '4K / HDR showcase'),
  ('curated', 'Seasonal / curated picks'),
  ('popular', 'Popular on Zorofin this week'),
  ('sports', 'Your teams / starting soon'),
];

/// Followed team names: up to 12, each 3 to 64 characters.
bool validTeams(List<String> teams) =>
    teams.length <= 12 &&
    teams.every((t) {
      final text = t.trim();
      return text.length >= 3 &&
          text.length <= 64 &&
          !RegExp(r'[\x00-\x1F\x7F]').hasMatch(text);
    });

abstract final class ClientHomeRows {
  static const ids = {
    'new-episodes',
    'short-movies',
    'showcase',
    'curated',
    'sports',
  };
  static const shortMovieMinutes = 90;
  static const recentDays = 14;
  static const sportsWindow = Duration(hours: 12);

  /// A followed team's game joins the row this long before it starts.
  static const sportsSoon = Duration(hours: 1);
  static const cardLimit = 20;

  /// Rows in the contract's order. A client row wins unless it failed and
  /// the server still provided one; the server supplies requests and popular.
  static List<HomeFeedRow> merge(
    List<HomeFeedRow> client,
    List<HomeFeedRow>? server,
  ) {
    final own = {for (final r in client.reversed) r.id: r};
    final remote = {for (final r in (server ?? const []).reversed) r.id: r};
    return [
      for (final (id, _) in homeRowOptions)
        if (own[id] case final row?)
          row.state == 'unavailable' &&
                  remote[id] != null &&
                  remote[id]!.state != 'unavailable'
              ? remote[id]!
              : row
        else if (!ids.contains(id) && remote[id] != null)
          remote[id]!,
    ];
  }

  /// Source formats verified from video metadata.
  static List<String> formats(MediaItem item) {
    final sources = item.mediaSources
        .where((s) => s.mediaStreams.isNotEmpty)
        .expand((s) => s.mediaStreams)
        .toList();
    final streams = sources.isEmpty ? item.mediaStreams : sources;
    final badges = <String>[];
    void add(String b) {
      if (!badges.contains(b)) badges.add(b);
    }

    for (final s in streams) {
      if (s.type != 'Video' || s.isAttachedPicture) continue;
      if ((s.width ?? 0) >= 3840) add('4K');
      final range = (s.videoRangeType ?? '').toUpperCase();
      if (range.startsWith('DOVI') && range != 'DOVIINVALID') {
        add('Dolby Vision');
      } else if (range == 'HDR10PLUS') {
        add('HDR10+');
      } else if (range == 'HDR10') {
        add('HDR10');
      } else if (range == 'HLG') {
        add('HLG');
      } else if ((s.videoRange ?? '').toUpperCase() == 'HDR') {
        add('HDR');
      }
    }
    return badges;
  }

  static List<HomeRowCard> shortMovies(
    List<HomeEntry> movies, {
    int minutes = shortMovieMinutes,
  }) {
    final limit = minutes * 600000000;
    return movies
        .where(
          (e) =>
              e.playable &&
              !e.played &&
              (e.item.runTimeTicks ?? 0) > 0 &&
              (e.item.runTimeTicks ?? 0) <= limit,
        )
        .take(cardLimit)
        .map((e) {
          final length = ((e.item.runTimeTicks ?? 0) + 599999999) ~/ 600000000;
          return HomeRowCard(
            id: e.item.id,
            item: e.item,
            subtitle: '$length min',
          );
        })
        .toList();
  }

  static List<HomeRowCard> showcase(List<HomeEntry> movies) => movies
      .where((e) => e.playable)
      .map((e) {
        final badges = formats(e.item);
        return badges.isEmpty
            ? null
            : HomeRowCard(
                id: e.item.id,
                item: e.item,
                subtitle: 'Source format',
                badges: badges,
              );
      })
      .nonNulls
      .take(cardLimit)
      .toList();

  static List<HomeRowCard> newEpisodes(
    List<HomeEntry> episodes, {
    required Set<String> favorites,
    required DateTime now,
  }) {
    final since = now.subtract(const Duration(days: recentDays));
    final seen = <String>{};
    final picks = <(HomeEntry, DateTime)>[];
    for (final e in episodes) {
      final created = e.created;
      final series = e.item.seriesId;
      if (!e.playable ||
          e.played ||
          series == null ||
          !favorites.contains(series) ||
          created == null ||
          created.isBefore(since) ||
          created.isAfter(now) ||
          !seen.add(e.item.id)) {
        continue;
      }
      picks.add((e, created));
    }
    picks.sort((a, b) => b.$2.compareTo(a.$2));
    return [
      for (final p in picks.take(cardLimit))
        HomeRowCard(
          id: p.$1.item.id,
          item: p.$1.item,
          subtitle: 'New in your library',
          badges: const ['New episode'],
        ),
    ];
  }

  static final _notLive = RegExp(
    r'\b(highlights?|replay|classic|preview|studio|sportscenter|news|talk)\b',
    caseSensitive: false,
  );

  static String normalized(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();

  /// Full team names only; "NY" never matches "Sunny".
  static bool teamMatches(String text, List<String> teams) {
    final haystack = ' ${normalized(text)} ';
    return teams.any((team) {
      final needle = normalized(team);
      return needle.isNotEmpty && haystack.contains(' $needle ');
    });
  }

  /// Games for the viewer's teams that are on now or start within the hour.
  /// No teams, no row: generic sports channels never fill it.
  static List<HomeRowCard> sports(
    List<LiveProgram> programs, {
    required List<MediaItem> channels,
    required List<String> teams,
    required DateTime now,
  }) {
    if (teams.isEmpty) return const [];
    final byId = {for (final c in channels.reversed) c.id: c};
    final seen = <String>{};
    final picks = <(HomeRowCard, DateTime)>[];
    for (final p in programs) {
      final start = p.start, end = p.end;
      final channel = byId[p.channelId];
      final id = p.id;
      final sport =
          p.isSports == true ||
          p.genres.any(
            (g) => const ['sport', 'sports'].contains(g.toLowerCase()),
          );
      if (!sport ||
          _notLive.hasMatch(p.name) ||
          start == null ||
          end == null ||
          !end.isAfter(now) ||
          start.isAfter(now.add(sportsSoon)) ||
          !start.isAfter(now.subtract(sportsWindow)) ||
          channel == null ||
          id == null ||
          id.isEmpty ||
          !seen.add(id) ||
          !teamMatches('${p.name} ${p.overview ?? ''}', teams)) {
        continue;
      }
      picks.add((
        HomeRowCard(
          id: id,
          item: channel,
          subtitle: p.name,
          badges: [start.isAfter(now) ? 'Starting soon' : 'On now'],
          startsAt: start.toUtc().toIso8601String(),
          endsAt: end.toUtc().toIso8601String(),
        ),
        start,
      ));
    }
    picks.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final p in picks.take(cardLimit)) p.$1];
  }
}

/// A library item with the facts Home rules need beyond the display model.
class HomeEntry {
  HomeEntry(this.item, Map<String, dynamic> json)
    : created = jellyfinDate(json['DateCreated'] as String?),
      tags = [
        for (final t in json['Tags'] as List? ?? const [])
          if (t is String) t,
      ],
      playable =
          json['LocationType'] != 'Virtual' && json['IsPlaceHolder'] != true;

  final MediaItem item;
  final DateTime? created;
  final List<String> tags;
  final bool playable;

  bool get played => item.userData?.played == true;
}

// MARK: Seasonal and curated programming

class _Theme {
  _Theme(this.title, String collections, {String? match, this.genres})
    : collections = RegExp(collections, caseSensitive: false),
      match = match == null ? null : RegExp(match, caseSensitive: false);

  final String title;
  final RegExp collections;
  final RegExp? match;
  final List<String>? genres;
}

/// Holiday, season and mood shelves (Apple `SeasonalThemes`).
abstract final class SeasonalThemes {
  static final themes = <String, _Theme>{
    'new-year': _Theme(
      'New year, fresh starts',
      'new.year|fresh.starts|new.beginnings',
      match: 'new.year|fresh.start|new.beginning',
    ),
    'valentines': _Theme(
      'Valentine’s picks',
      'valentine|date.night|romantic.comed',
      genres: ['Romance'],
    ),
    'black-history': _Theme(
      'Black History Month',
      'black.history|black.cinema|black.filmmakers',
    ),
    'spring-break': _Theme(
      'Spring break',
      'spring.break',
      match: 'spring.break|road.trip|vacation',
      genres: ['Comedy', 'Adventure', 'Family'],
    ),
    'st-patricks': _Theme(
      'St. Patrick’s Day',
      r'st\.?\s*patrick|irish.cinema|irish.stories',
    ),
    'earth-day': _Theme(
      'Earth Day: wild worlds',
      'earth.day|planet.earth|wildlife|nature.documentar',
      match: 'wildlife|natural.world|rainforest|ocean|conservation',
      genres: ['Documentary'],
    ),
    'mothers-day': _Theme('Mother’s Day', "mother[’']?s.day|mothers.day"),
    'memorial-day': _Theme('Memorial Day weekend', 'memorial.day'),
    'graduation': _Theme(
      'Graduation & new beginnings',
      'graduation|coming.of.age|new.beginnings',
      match: 'graduat(?:e|es|ion|ing)|coming.of.age',
      genres: ['Comedy', 'Drama', 'Family'],
    ),
    'pride': _Theme(
      'Pride stories',
      r'\bpride\b|lgbtq?\+?.cinema|queer.cinema',
    ),
    'juneteenth': _Theme('Juneteenth', 'juneteenth'),
    'fathers-day': _Theme('Father’s Day', "father[’']?s.day|fathers.day"),
    'fourth-july': _Theme(
      'Fourth of July',
      r'(?:fourth|4th).of.july|july.(?:fourth|4th|4)\b|independence.day|stars.and.stripes',
      match: r'(?:fourth|4th).of.july|july.(?:fourth|4th|4)\b|independence.day',
    ),
    'back-to-school': _Theme(
      'Back to school',
      'back.to.school|school.days|campus.classics',
      match: 'high.school|boarding.school|college|campus|classroom|school.year',
      genres: ['Comedy', 'Drama', 'Family', 'Animation'],
    ),
    'labor-day': _Theme(
      'Long-weekend movies',
      'labor.day|long.weekend',
      genres: ['Adventure', 'Comedy'],
    ),
    'halloween': _Theme(
      'Spooky season',
      'halloween|horror|spooky',
      genres: ['Horror'],
    ),
    'thanksgiving': _Theme(
      'Thanksgiving weekend',
      'thanksgiving|friendsgiving',
      match: 'thanksgiving|friendsgiving',
    ),
    'christmas': _Theme(
      'Christmas favorites',
      r'christmas|\bxmas\b',
      match: r'christmas|\bxmas\b',
    ),
    'winter': _Theme(
      'Winter nights',
      'winter|snow.day|snowy',
      match: 'winter|snowbound|snowstorm|snowy|ski.resort',
    ),
    'spring': _Theme(
      'Springtime stories',
      'springtime|spring.favorites|spring.picks',
      match: 'springtime|spring.festival|spring.garden',
    ),
    'summer': _Theme(
      'Summer movie nights',
      'summer|beach|surfing|vacation',
      match: 'summer|beach|surfing|vacation|road.trip',
    ),
    'autumn': _Theme(
      'Autumn evenings',
      'autumn|fall.favorites|fall.picks|cozy.season',
      match: 'autumn|fall.foliage|harvest.festival',
    ),
    'comfort': _Theme(
      'Comfort watches',
      'comfort|ghibli|feel.good',
      genres: ['Family', 'Comedy'],
    ),
    'movie-night': _Theme(
      'Movie night',
      'movie.night|heist|mind.bend|sci.fi|essentials',
      genres: ['Adventure', 'Mystery', 'Science Fiction'],
    ),
    'rainy-day': _Theme(
      'Rainy-day mysteries',
      'rainy.day|whodunit|mystery.night',
      genres: ['Mystery'],
    ),
    'weekend-adventures': _Theme(
      'Weekend adventures',
      'weekend.adventure|adventure.favorites',
      genres: ['Adventure'],
    ),
  };

  /// Days since 1970-01-01 for a civil date; month may overflow.
  static int dayNumber(int year, int month, int day) =>
      DateTime.utc(year, month, day).millisecondsSinceEpoch ~/ 86400000;

  static int today(DateTime now) {
    final local = now.toLocal();
    return dayNumber(local.year, local.month, local.day);
  }

  static int _weekday(int day) => ((day + 4) % 7 + 7) % 7;

  static int nthWeekday(int year, int month, int weekday, int occurrence) {
    final first = dayNumber(year, month, 1);
    return first + (weekday - _weekday(first) + 7) % 7 + (occurrence - 1) * 7;
  }

  /// Ordered themes for today: closest holidays, editorial windows, the
  /// season, then weekly-rotating moods.
  static List<String> plan(DateTime now) {
    final today = SeasonalThemes.today(now);
    final date = DateTime.fromMillisecondsSinceEpoch(
      today * 86400000,
      isUtc: true,
    );
    final year = date.year, month = date.month;
    final candidates = <(String, double)>[];
    void window(String key, int sm, int sd, int em, int ed, [double p = 30]) {
      if (today >= dayNumber(year, sm, sd) &&
          today <= dayNumber(year, em, ed)) {
        candidates.add((key, p));
      }
    }

    void holiday(String key, int day, {int before = 7, int after = 1}) {
      final distance = day - today;
      if (distance <= before && distance >= -after) {
        candidates.add((
          key,
          100 - distance.abs().toDouble() + (distance >= 0 ? 0.5 : 0),
        ));
      }
    }

    window('new-year', 1, 1, 1, 7, 80);
    window('new-year', 12, 27, 12, 31, 80);
    holiday('valentines', dayNumber(year, 2, 14));
    window('black-history', 2, 1, 3, 0);
    window('spring-break', 3, 8, 4, 12);
    holiday('st-patricks', dayNumber(year, 3, 17));
    holiday('earth-day', dayNumber(year, 4, 22));
    holiday('mothers-day', nthWeekday(year, 5, 0, 2));
    final lastMay = dayNumber(year, 5, 31);
    holiday(
      'memorial-day',
      lastMay - (_weekday(lastMay) + 6) % 7,
      before: 3,
      after: 1,
    );
    window('graduation', 5, 15, 6, 20, 35);
    window('pride', 6, 1, 6, 30);
    holiday('juneteenth', dayNumber(year, 6, 19), before: 4, after: 2);
    holiday('fathers-day', nthWeekday(year, 6, 0, 3));
    holiday('fourth-july', dayNumber(year, 7, 4), before: 8, after: 3);
    window('back-to-school', 8, 10, 9, 15, 40);
    holiday('labor-day', nthWeekday(year, 9, 1, 1), before: 3, after: 1);
    window('halloween', 10, 1, 11, 1, 60);
    holiday('thanksgiving', nthWeekday(year, 11, 4, 4), before: 10, after: 3);
    window('christmas', 12, 1, 12, 26, 60);
    final season = month <= 2 || month == 12
        ? 'winter'
        : month <= 5
        ? 'spring'
        : month <= 8
        ? 'summer'
        : 'autumn';
    const moods = ['comfort', 'movie-night', 'rainy-day', 'weekend-adventures'];
    final offset = (today ~/ 7) % moods.length;
    final ranked = [...candidates.indexed]
      ..sort((a, b) {
        if (a.$2.$2 != b.$2.$2) return b.$2.$2.compareTo(a.$2.$2);
        return a.$1.compareTo(b.$1);
      });
    final seen = <String>{};
    return [
      for (final key in [
        ...ranked.map((r) => r.$2.$1),
        season,
        ...moods.sublist(offset),
        ...moods.sublist(0, offset),
      ])
        if (seen.add(key)) key,
    ];
  }

  static bool matchesCollection(String name, String theme) =>
      themes[theme]?.collections.hasMatch(name) ?? false;

  /// Explicit themed tags can carry collection intent; a generic title or
  /// plot alone never establishes an observance.
  static bool metadataMatches(MediaItem item, List<String> tags, String theme) {
    final rule = themes[theme];
    if (rule == null) return false;
    if (tags.any(rule.collections.hasMatch)) return true;
    if (rule.match == null && rule.genres == null) return false;
    final text = [item.name, item.overview ?? '', ...tags].join(' ');
    return (rule.match?.hasMatch(text) ?? true) &&
        (rule.genres == null || item.genres.any(rule.genres!.contains));
  }

  /// Stable within a week for the account, unwatched first.
  static List<MediaItem> rank(
    List<MediaItem> items, {
    required String theme,
    required String viewerId,
    required DateTime now,
  }) {
    final week = today(now) ~/ 7;
    final seen = <String>{};
    final ranked =
        [
          for (final i in items)
            if (seen.add(i.id))
              (i, stableHashInt('$theme|$viewerId|$week|${i.id}')),
        ]..sort((a, b) {
          final pa = a.$1.userData?.played == true;
          final pb = b.$1.userData?.played == true;
          if (pa != pb) return pa ? 1 : -1;
          return a.$2.compareTo(b.$2);
        });
    return [for (final r in ranked.take(ClientHomeRows.cardLimit)) r.$1];
  }

  static String? title(String theme) => themes[theme]?.title;
}

/// FNV-1a 64-bit, compared as unsigned through the sign bit.
int stableHashInt(String text) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(text)) {
    hash = (hash ^ byte) * 0x100000001b3;
  }
  return hash ^ (1 << 63);
}

/// Advances by server results; stops servers that ignore startIndex.
class LibraryPageCursor {
  int offset = 0;
  bool hasMore = true;
  List<String> _previous = const [];

  void accept(ItemPage page, int limit) {
    final ids = page.items.map((i) => i.id).toList();
    if (ids.isEmpty || _sameIds(ids, _previous)) {
      hasMore = false;
      return;
    }
    _previous = ids;
    offset += page.items.length;
    final total = page.totalRecordCount;
    hasMore = total != null ? offset < total : page.items.length >= limit;
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class DiscoveryRow {
  const DiscoveryRow(this.id, this.title, this.items);
  final String id;
  final String title;
  final List<MediaItem> items;
}

class _Lane {
  _Lane(
    this.title,
    this.type, {
    this.genre,
    this.years,
    this.minimumRating,
    this.unplayed = false,
    this.sort = 'CommunityRating,SortName',
  });

  final String title;
  final String type;
  final String? genre;
  final String? years;
  final String? minimumRating;
  final bool unplayed;
  final String sort;
  final cursor = LibraryPageCursor();
}

/// Endless Home rows after the fixed shelves (Apple `DiscoveryFeed`): genre,
/// decade and rating lanes in a random order per visit, with "Because you
/// watched" rows mixed in.
class DiscoveryFeed {
  DiscoveryFeed({int? seed}) : _random = HomeRandom(seed);

  final HomeRandom _random;
  bool hasMore = true;
  List<_Lane> _lanes = [];
  List<(String, String)> _seeds = [];
  bool _initialized = false;
  int _serial = 0;
  int _ordinary = 0;
  final List<List<String>> _recent = [];

  Future<void> _prepare(JellyfinClient client) async {
    final results = await Future.wait([
      _optional(client.discoveryGenres),
      _optional(client.discoveryHistory),
    ]);
    final genres = results[0], history = results[1];
    final seeds = <(String, String)>[];
    final seen = <String>{};
    for (final i in history.items) {
      if (i.userData?.played != true) continue;
      String? id, title;
      if (i.isEpisode && i.seriesId != null && i.seriesName != null) {
        id = i.seriesId;
        title = i.seriesName;
      } else if (i.type == 'Movie' || i.isSeries) {
        id = i.id;
        title = i.name;
      }
      if (id == null || title == null || id.isEmpty || title.isEmpty) continue;
      if (seen.add(id)) seeds.add((id, title));
    }
    _seeds = seeds.take(8).toList();
    _lanes = [
      _Lane('Highly rated movies', 'Movie', minimumRating: '7'),
      _Lane('Shows to discover', 'Series', unplayed: true),
      _Lane(
        "Movies you haven't watched",
        'Movie',
        unplayed: true,
        sort: 'PremiereDate,SortName',
      ),
    ];
    final names = <String>{};
    final genreNames = [
      for (final g in genres.items)
        if (g.name.isNotEmpty &&
            g.name.length <= 80 &&
            !g.name.contains('|') &&
            names.add(g.name.toLowerCase()))
          g.name,
    ];
    for (final (i, name) in genreNames.indexed) {
      _lanes.add(_Lane('$name movies', 'Movie', genre: name));
      _lanes.add(
        _Lane(
          '$name shows',
          'Series',
          genre: name,
          sort: 'PremiereDate,SortName',
        ),
      );
      if (i < 4) {
        final decade = 2020 - i * 10;
        _lanes.add(
          _Lane(
            'Movies from the ${decade}s',
            'Movie',
            years: [for (var y = decade; y < decade + 10; y++) '$y'].join(','),
          ),
        );
      }
    }
    _lanes
      ..add(_Lane('More movies to explore', 'Movie', sort: 'SortName'))
      ..add(_Lane('More shows to explore', 'Series', sort: 'SortName'));
    _random.shuffle(_lanes);
    _initialized = true;
  }

  /// At most two rows from eight page reads per request for more.
  Future<List<DiscoveryRow>> next(
    JellyfinClient client, {
    Set<String> excluding = const {},
  }) async {
    if (!_initialized) await _prepare(client);
    final result = <DiscoveryRow>[];
    var requests = 0;
    while (result.length < 2 && requests < 8 && _lanes.isNotEmpty) {
      final blocked = {...excluding, ..._recent.expand((r) => r)};
      final String title;
      final ItemPage page;
      String? seedId;
      if (_ordinary >= 5 && _seeds.isNotEmpty) {
        final seed = _seeds.removeAt(0);
        page = await client.discoverySimilar(seed.$1);
        seedId = seed.$1;
        title = 'Because you watched ${seed.$2}';
      } else {
        final lane = _lanes.removeAt(0);
        page = await client._discoveryItems(lane);
        lane.cursor.accept(page, 24);
        if (lane.cursor.hasMore) _lanes.add(lane);
        title = lane.title;
      }
      requests++;
      final seen = {...blocked, ?seedId};
      final items = [
        for (final i in page.items)
          if ((i.type == 'Movie' || i.isSeries) &&
              i.id.isNotEmpty &&
              seen.add(i.id))
            i,
      ];
      if (items.isEmpty) continue;
      _serial++;
      result.add(DiscoveryRow('discovery-$_serial', title, items));
      _recent.add(items.map((i) => i.id).toList());
      if (_recent.length > 6) _recent.removeAt(0);
      _ordinary = seedId != null ? 0 : _ordinary + 1;
    }
    hasMore = _lanes.isNotEmpty;
    return result;
  }

  static Future<ItemPage> _optional(Future<ItemPage> Function() fetch) async {
    try {
      return await fetch();
    } on ClientError catch (e) {
      if (e.kind == ClientErrorKind.unauthorized ||
          e.kind == ClientErrorKind.forbidden) {
        rethrow;
      }
      return ItemPage(items: const []);
    } catch (_) {
      return ItemPage(items: const []);
    }
  }
}

// MARK: Jellyfin reads

extension HomeReads on JellyfinClient {
  Map<String, String> _viewer() {
    final current = session;
    if (current == null) {
      throw const ClientError(ClientErrorKind.missingSession);
    }
    return {'userId': current.viewer.id};
  }

  /// Resume and next episodes as one shelf; one failing half keeps the other
  /// unless the session itself is gone.
  Future<({List<MediaItem> items, bool partial})> continueWatchingFeed() async {
    Object? resumeError, nextError;
    final pages = await Future.wait([
      resume().catchError((Object e) {
        resumeError = e;
        return ItemPage(items: const []);
      }),
      nextUp().catchError((Object e) {
        nextError = e;
        return ItemPage(items: const []);
      }),
    ]);
    for (final error in [resumeError, nextError]) {
      if (error is ClientError &&
          const [
            ClientErrorKind.unauthorized,
            ClientErrorKind.forbidden,
            ClientErrorKind.missingSession,
            ClientErrorKind.unsafeUrl,
          ].contains(error.kind)) {
        throw error;
      }
    }
    if (resumeError != null && nextError != null) throw resumeError!;
    return (
      items: continueWatching(pages[0].items, pages[1].items),
      partial: resumeError != null || nextError != null,
    );
  }

  /// A small pool across movies and shows, highest rated first.
  Future<ItemPage> homeBannerItems() => request(
    ItemPage.fromJson,
    ['Items'],
    query: {
      ..._viewer(),
      'recursive': 'true',
      'includeItemTypes': 'Movie,Series',
      'limit': '12',
      'sortBy': 'CommunityRating,SortName',
      'sortOrder': 'Descending',
      'fields': 'Overview,MediaStreams',
      'enableUserData': 'true',
      'enableImageTypes': 'Primary,Backdrop',
      'imageTypeLimit': '1',
      'excludeLocationTypes': 'Virtual',
      'isPlaceHolder': 'false',
    },
  );

  Map<String, String> _discoveryQuery({bool streams = false}) => {
    ..._viewer(),
    'recursive': 'true',
    'limit': '24',
    'fields': streams ? 'Overview,Genres,MediaStreams' : 'Overview,Genres',
    'enableUserData': 'true',
    'enableTotalRecordCount': 'true',
    'imageTypeLimit': '1',
    'excludeLocationTypes': 'Virtual',
    'isPlaceHolder': 'false',
  };

  Future<ItemPage> discoveryGenres() => request(
    ItemPage.fromJson,
    ['Genres'],
    query: {
      ..._discoveryQuery(),
      'includeItemTypes': 'Movie,Series',
      'sortBy': 'SortName',
      'enableImages': 'false',
    },
  );

  Future<ItemPage> discoveryHistory() => request(
    ItemPage.fromJson,
    ['Items'],
    query: {
      ..._discoveryQuery(),
      'includeItemTypes': 'Movie,Episode',
      'isPlayed': 'true',
      'sortBy': 'DatePlayed,SortName',
      'sortOrder': 'Descending',
    },
  );

  Future<ItemPage> discoverySimilar(String id) => request(ItemPage.fromJson, [
    'Items',
    id,
    'Similar',
  ], query: _discoveryQuery(streams: true));

  Future<ItemPage> _discoveryItems(_Lane lane) => request(
    ItemPage.fromJson,
    ['Items'],
    query: {
      ..._discoveryQuery(streams: true),
      'includeItemTypes': lane.type,
      'startIndex': '${lane.cursor.offset}',
      'sortBy': lane.sort,
      'sortOrder': lane.sort == 'SortName' ? 'Ascending' : 'Descending',
      'genres': ?lane.genre,
      'years': ?lane.years,
      'minCommunityRating': ?lane.minimumRating,
      if (lane.unplayed) 'isPlayed': 'false',
    },
  );

  Future<(List<HomeEntry>, ItemPage)> _homeEntries(
    Map<String, String> query,
  ) async {
    final json = await request(
      (j) => j,
      ['Items'],
      query: {..._viewer(), 'recursive': 'true', ...query},
    );
    final raw = json['Items'];
    if (raw is! List) throw const ClientError(ClientErrorKind.invalidResponse);
    final page = ItemPage.fromJson(json);
    final maps = raw.whereType<Map<String, dynamic>>().toList();
    if (maps.length != page.items.length) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return (
      [for (final (i, item) in page.items.indexed) HomeEntry(item, maps[i])],
      page,
    );
  }

  /// Most recent movies for the time, showcase and seasonal rows; at most
  /// 2,000 titles in eight pages.
  Future<List<HomeEntry>> homeMovieCatalog() async {
    final cursor = LibraryPageCursor();
    final result = <HomeEntry>[];
    for (var i = 0; i < 8; i++) {
      final (entries, page) = await _homeEntries({
        'includeItemTypes': 'Movie',
        'sortBy': 'DateCreated,SortName',
        'sortOrder': 'Descending',
        'fields': 'MediaStreams,Genres,Tags,Overview,DateCreated',
        'enableImageTypes': 'Primary,Backdrop,Thumb',
        'imageTypeLimit': '1',
        'limit': '250',
        'startIndex': '${cursor.offset}',
      });
      result.addAll(entries);
      cursor.accept(page, 250);
      if (!cursor.hasMore) break;
    }
    return result;
  }

  Future<List<HomeRowCard>> homeNewEpisodes(DateTime now) async {
    final (shows, _) = await _homeEntries({
      'includeItemTypes': 'Series',
      'isFavorite': 'true',
      'enableImages': 'false',
      'limit': '100',
    });
    final favorites = shows.map((e) => e.item.id).toSet();
    if (favorites.isEmpty) return const [];
    final since = now.subtract(const Duration(days: ClientHomeRows.recentDays));
    final cursor = LibraryPageCursor();
    final episodes = <HomeEntry>[];
    for (var i = 0; i < 3; i++) {
      final (entries, page) = await _homeEntries({
        'includeItemTypes': 'Episode',
        'isPlayed': 'false',
        'sortBy': 'DateCreated',
        'sortOrder': 'Descending',
        'fields': 'DateCreated,MediaStreams',
        'limit': '200',
        'startIndex': '${cursor.offset}',
      });
      episodes.addAll(entries);
      cursor.accept(page, 200);
      final last = entries.lastOrNull?.created;
      if (!cursor.hasMore || last == null || last.isBefore(since)) break;
    }
    return ClientHomeRows.newEpisodes(episodes, favorites: favorites, now: now);
  }

  Future<(String, List<HomeRowCard>)> homeCurated(
    List<HomeEntry> movies,
    DateTime now,
  ) async {
    final viewer = session?.viewer.id ?? '';
    final (collections, _) = await _homeEntries({
      'includeItemTypes': 'BoxSet',
      'enableImages': 'false',
      'limit': '200',
    });
    final children = <String, List<HomeEntry>>{};
    var remaining = 6;
    for (final theme in SeasonalThemes.plan(now)) {
      final title = SeasonalThemes.title(theme);
      if (title == null) continue;
      var picks = <MediaItem>[];
      for (final collection
          in collections
              .where(
                (c) => SeasonalThemes.matchesCollection(c.item.name, theme),
              )
              .take(2)) {
        if (!children.containsKey(collection.item.id)) {
          if (remaining <= 0) break;
          remaining--;
          children[collection.item.id] = (await _homeEntries({
            'parentId': collection.item.id,
            'includeItemTypes': 'Movie',
            'fields': 'MediaStreams,Genres,Tags,Overview',
            'limit': '40',
          })).$1;
        }
        picks.addAll(
          (children[collection.item.id] ?? const <HomeEntry>[])
              .where((e) => e.playable)
              .map((e) => e.item),
        );
      }
      if (picks.isEmpty) {
        picks = [
          for (final m in movies)
            if (m.playable &&
                SeasonalThemes.metadataMatches(m.item, m.tags, theme))
              m.item,
        ];
      }
      if (picks.isNotEmpty) {
        final ranked = SeasonalThemes.rank(
          picks,
          theme: theme,
          viewerId: viewer,
          now: now,
        );
        return (
          title,
          [
            for (final m in ranked)
              HomeRowCard(id: m.id, item: m, subtitle: title),
          ],
        );
      }
    }
    return ('Seasonal picks', const <HomeRowCard>[]);
  }

  Future<List<HomeRowCard>> homeSports(List<String> teams, DateTime now) async {
    final channels = (await liveTvSnapshot()).channels;
    if (channels.isEmpty) return const [];
    final programs = <LiveProgram>[];
    for (var start = 0; start < 1500; start += 500) {
      final json = await request(
        (j) => j,
        ['LiveTv', 'Programs'],
        query: {
          ..._viewer(),
          'isSports': 'true',
          'minEndDate': now.toUtc().toIso8601String(),
          'maxStartDate': now
              .add(ClientHomeRows.sportsSoon)
              .toUtc()
              .toIso8601String(),
          'sortBy': 'StartDate',
          'sortOrder': 'Ascending',
          'fields': 'Overview,Genres',
          'enableImages': 'false',
          'startIndex': '$start',
          'limit': '500',
        },
      );
      final items = (json['Items'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(LiveProgram.fromJson)
          .toList();
      programs.addAll(items);
      if (items.length < 500) break;
    }
    return ClientHomeRows.sports(
      programs,
      channels: channels,
      teams: teams,
      now: now,
    );
  }

  /// Device-side Home rows. A failing row becomes unavailable without hiding
  /// the others; only a lost session propagates.
  Future<List<HomeFeedRow>> clientHomeRows(
    List<String> teams, {
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    Future<(T?, bool)> attempt<T>(Future<T> Function() body) async {
      try {
        return (await body(), true);
      } on ClientError catch (e) {
        if (e.kind == ClientErrorKind.unauthorized) rethrow;
        return (null, false);
      } catch (_) {
        return (null, false);
      }
    }

    final moviesFuture = attempt(homeMovieCatalog);
    final episodesFuture = attempt(() => homeNewEpisodes(at));
    final sportsFuture = attempt(() => homeSports(teams, at));
    final movies = await moviesFuture;
    final curated = await attempt(() => homeCurated(movies.$1 ?? const [], at));

    HomeFeedRow row(
      String id,
      String title,
      (List<HomeRowCard>?, bool) result, {
      required String empty,
    }) {
      final cards = result.$1;
      if (!result.$2 || cards == null) {
        return HomeFeedRow(
          id: id,
          title: title,
          state: 'unavailable',
          message: 'This row could not load. Try again shortly.',
        );
      }
      if (cards.isEmpty) {
        return HomeFeedRow(
          id: id,
          title: title,
          state: 'empty',
          message: empty,
        );
      }
      return HomeFeedRow(id: id, title: title, cards: cards);
    }

    (List<HomeRowCard>?, bool) fromMovies(
      List<HomeRowCard> Function(List<HomeEntry>) rule,
    ) => movies.$2 ? (rule(movies.$1!), true) : (null, false);

    return [
      row(
        'new-episodes',
        'New episodes for you',
        await episodesFuture,
        empty:
            'Favorite a show with the heart button to follow it. New unwatched episodes will appear here.',
      ),
      row(
        'short-movies',
        'Watch in ${ClientHomeRows.shortMovieMinutes} minutes',
        fromMovies(ClientHomeRows.shortMovies),
        empty: 'No unwatched movies fit this time limit.',
      ),
      row(
        'showcase',
        '4K / HDR showcase',
        fromMovies(ClientHomeRows.showcase),
        empty: 'No titles with verified 4K or HDR metadata are available.',
      ),
      row(
        'curated',
        curated.$1?.$1 ?? 'Seasonal picks',
        (curated.$1?.$2, curated.$2),
        empty: 'No matching seasonal or curated titles are available yet.',
      ),
      row(
        'sports',
        'Your teams / starting soon',
        await sportsFuture,
        empty: teams.isEmpty
            ? 'Follow your teams to see their games here.'
            : 'None of your teams are on now or starting soon.',
      ),
    ];
  }

  /// The optional server feed (requests and popular rows).
  Future<List<HomeFeedRow>> homeFeed() async {
    final json = await requestJson(
      ['support', 'home', 'rows'],
      extensionToken: true,
      expectedStatus: 200,
    );
    try {
      final map = json as Map<String, dynamic>;
      if (map['schemaVersion'] != 1) throw const FormatException();
      final rows = [
        for (final r in map['rows'] as List)
          HomeFeedRow.fromJson(r as Map<String, dynamic>),
      ];
      final known = homeRowOptions.map((o) => o.$1).toSet();
      if (rows.length > 7 ||
          rows.map((r) => r.id).toSet().length != rows.length ||
          rows.any(
            (r) =>
                !known.contains(r.id) ||
                !const ['ready', 'empty', 'unavailable'].contains(r.state) ||
                r.cards.length > 20 ||
                r.cards.map((c) => c.id).toSet().length != r.cards.length,
          )) {
        throw const FormatException();
      }
      return rows;
    } catch (_) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
  }

  /// Older Home adapters omit rating and stream fields; fill only display
  /// metadata through ordinary reads, in batches.
  Future<List<HomeFeedRow>> enrichHomeRows(List<HomeFeedRow> rows) async {
    final idPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
    final missing = {
      for (final c in rows.expand((r) => r.cards))
        if (!c.item.isLive &&
            (c.item.communityRating == null ||
                (!c.item.isSeries &&
                    c.item.type != 'Season' &&
                    c.item.quality().thumbnailBadges.isEmpty)) &&
            idPattern.hasMatch(c.item.id))
          c.item.id,
    }.toList()..sort();
    final ids = missing.take(140).toList();
    if (ids.isEmpty) return rows;
    final metadata = <String, MediaItem>{};
    for (var start = 0; start < ids.length; start += 50) {
      final batch = ids.sublist(start, min(start + 50, ids.length));
      try {
        final page = await request(
          ItemPage.fromJson,
          ['Items'],
          query: {
            ..._viewer(),
            'ids': batch.join(','),
            'fields': 'MediaStreams',
            'enableUserData': 'false',
            'limit': '${batch.length}',
          },
        );
        for (final i in page.items) {
          if (batch.contains(i.id)) metadata[i.id] = i;
        }
      } on ClientError catch (e) {
        if (const [
          ClientErrorKind.unauthorized,
          ClientErrorKind.forbidden,
          ClientErrorKind.unsafeUrl,
        ].contains(e.kind)) {
          rethrow;
        }
      }
    }
    return [
      for (final r in rows)
        r.withCards([
          for (final c in r.cards)
            if (metadata[c.item.id] case final detail?)
              c.withItem(c.item.withDetails(detail))
            else
              c,
        ]),
    ];
  }

  /// Followed teams live in Jellyfin display preferences, so they follow
  /// the account to every device. Null means never saved.
  static const teamsPreferencesId = 'zorofin-home';
  static const teamsKey = 'zorofinTeams';

  Future<Map<String, dynamic>> _displayPreferences() => request(
    (j) => j,
    ['DisplayPreferences', teamsPreferencesId],
    query: {..._viewer(), 'client': 'zorofin'},
  );

  Future<List<String>?> savedHomeTeams() async {
    final custom = (await _displayPreferences())['CustomPrefs'];
    final raw = custom is Map ? custom[teamsKey] : null;
    if (raw is! String) return null;
    try {
      final teams = [
        for (final t in jsonDecode(raw) as List)
          if (t is String) t,
      ];
      return validTeams(teams) ? teams : [];
    } catch (_) {
      return [];
    }
  }

  /// Read-modify-write keeps every other client's preferences intact.
  Future<void> saveHomeTeams(List<String> teams) async {
    if (!validTeams(teams)) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    final object = await _displayPreferences();
    final custom = Map<String, dynamic>.from(
      object['CustomPrefs'] as Map? ?? const {},
    );
    custom[teamsKey] = jsonEncode(teams);
    object['CustomPrefs'] = custom;
    object['Id'] ??= teamsPreferencesId;
    object['Client'] ??= 'zorofin';
    await requestText(
      ['DisplayPreferences', teamsPreferencesId],
      query: {..._viewer(), 'client': 'zorofin'},
      method: 'POST',
      body: object,
    );
  }

  /// Teams saved by the older server feed are adopted once.
  Future<List<String>> homeTeams({required bool serverFallback}) async {
    final saved = await savedHomeTeams();
    if (saved != null) return saved;
    if (!serverFallback) return const [];
    try {
      final json = await requestJson(
        ['support', 'home', 'preferences'],
        extensionToken: true,
        expectedStatus: 200,
      );
      final legacy = [
        for (final t in (json as Map)['teams'] as List? ?? const [])
          if (t is String) t,
      ];
      if (!validTeams(legacy)) return const [];
      if (legacy.isNotEmpty) {
        try {
          await saveHomeTeams(legacy);
        } catch (_) {}
      }
      return legacy;
    } catch (_) {
      return const [];
    }
  }

  /// Keeps the older server feed and web Home in step when present.
  Future<void> saveServerHomeTeams(List<String> teams) async {
    await requestJson(
      ['support', 'home', 'preferences'],
      method: 'PUT',
      body: {
        'hiddenRows': const <String>[],
        'teams': teams,
        'minutes': 90,
        'theme': 'automatic',
      },
      extensionToken: true,
      expectedStatus: 200,
    );
  }

  /// Every channel with what it is airing now; at most 4,000 channels.
  Future<LiveTvSnapshot> liveTvSnapshot() async {
    final cursor = LibraryPageCursor();
    final channels = <MediaItem>[];
    for (var i = 0; i < 20; i++) {
      final page = await request(
        ItemPage.fromJson,
        ['LiveTv', 'Channels'],
        query: {
          ..._viewer(),
          'addCurrentProgram': 'true',
          'fields': 'Overview,Genres,Tags',
          'enableUserData': 'true',
          'enableImages': 'true',
          'imageTypeLimit': '1',
          'enableImageTypes': 'Primary,Thumb,Backdrop',
          'limit': '200',
          'startIndex': '${cursor.offset}',
        },
      );
      channels.addAll(page.items.take(max(0, 4000 - channels.length)));
      cursor.accept(page, 200);
      if (!cursor.hasMore || channels.length >= 4000) break;
    }
    return LiveTvSnapshot(channels, DateTime.now());
  }

  /// The optional fixture index from the liveArtwork module.
  Future<LiveArtworkManifest> liveArtworkManifest() async {
    final text = await requestText([
      'live-tv-logos',
      'art',
      'events.json',
    ], authenticated: false);
    try {
      final manifest = LiveArtworkManifest.fromJson(
        jsonDecode(text) as Map<String, dynamic>,
      );
      if (manifest.version != 2) throw const FormatException();
      return manifest;
    } catch (_) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
  }

  /// A fixture image or crest on this server, never another host.
  Uri? liveArtworkUrl(String path) {
    if (!LiveEventArtwork.isSafePath(path)) return null;
    return server.endpoint(['live-tv-logos', 'art', path.split('/').last]);
  }
}

extension on MediaItem {
  MediaItem withDetails(MediaItem detail) => MediaItem(
    id: id,
    name: name,
    type: type,
    overview: overview,
    productionYear: productionYear,
    officialRating: officialRating,
    communityRating: detail.communityRating ?? communityRating,
    runTimeTicks: runTimeTicks,
    imageTags: imageTags,
    backdropImageTags: backdropImageTags,
    parentBackdropItemId: parentBackdropItemId,
    parentBackdropImageTags: parentBackdropImageTags,
    seriesId: seriesId,
    seriesName: seriesName,
    seasonId: seasonId,
    indexNumber: indexNumber,
    parentIndexNumber: parentIndexNumber,
    genres: genres,
    userData: userData,
    mediaSources: mediaSources,
    taglines: taglines,
    channelNumber: channelNumber,
    people: people,
    currentProgram: currentProgram,
    mediaStreams: detail.mediaStreams.isNotEmpty
        ? detail.mediaStreams
        : mediaStreams,
    container: detail.container ?? container,
    endDate: endDate,
  );
}

// MARK: Live events

enum LiveSport {
  football('Football'),
  basketball('Basketball'),
  soccer('Soccer'),
  baseball('Baseball'),
  hockey('Hockey'),
  cricket('Cricket'),
  tennis('Tennis'),
  golf('Golf'),
  racing('Motorsport'),
  combat('Fight night'),
  event('Live event');

  const LiveSport(this.title);
  final String title;

  /// The bundled illustration, the last artwork fallback.
  String get asset => 'assets/images/live-sport-$name.png';

  static LiveSport? parse(Object? value) =>
      values.where((s) => s.name == value).firstOrNull;
}

abstract final class _LiveRules {
  static RegExp regex(String pattern) => RegExp(pattern, caseSensitive: false);

  static String normalized(String text) {
    var folded = text
        .toLowerCase()
        .replaceAll('ø', 'o')
        .replaceAll('æ', 'ae')
        .replaceAll('ß', 'ss')
        .replaceAll('ł', 'l');
    folded = _stripDiacritics(folded);
    return folded.replaceAll(RegExp('[^a-z0-9]+'), ' ').trim();
  }

  static const _accents = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', //
    'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ì': 'i',
    'í': 'i', 'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o', 'ó': 'o',
    'ô': 'o', 'õ': 'o', 'ö': 'o', 'ù': 'u', 'ú': 'u', 'û': 'u',
    'ü': 'u', 'ý': 'y', 'ÿ': 'y',
  };

  static String _stripDiacritics(String text) =>
      text.split('').map((c) => _accents[c] ?? c).join();

  static final versus = regex(r'\s+(?:vs\.?|v\.?|versus|at)\s+');
  static final notTeam = regex(
    r'\b(?:[0-9]{1,2}(?::[0-9]{2})?\s*(?:am|pm)|afc (?:east|west|north|south)|nfc (?:east|west|north|south)|\d*news)\b|^\d+(?::\d+)?(?:\s*(?:am|pm))?$',
  );

  static List<String>? teams(String text) {
    final separators = versus.allMatches(text).toList();
    if (separators.length != 1) return null;
    final m = separators.first;
    final pair = [text.substring(0, m.start), text.substring(m.end)];
    return pair.every((p) => normalized(p).length > 2 && !notTeam.hasMatch(p))
        ? pair
        : null;
  }

  static final livePrefix = regex(r'^live\s*:\s*');
  static final placeholder = regex(r'^(?:[a-z]{2,6}\||threadfin:)');
  static final studio = regex(
    r'\b(sportscenter|sports centre|first take|the herd|jim rome|foxworth|schrager|finebaum|tiki|tierney|sec now|b1g live|mlb (?:now|tonight)|nba today|nfl live|acc pm|matchday live|premier league live|countdown|overreaction|pregame|pre-game|postgame|post-game|highlights?|replays?|rewind|classics?|review|yankeeography|in 60|encore|paid programming|goal zone|mlb central|leadoff|closer|learning center|preview|news|talk show|documentary)\b',
  );
  static final discussion = regex(
    r'\b(?:discussion and analysis|debate show|news and (?:information|updates)|sports (?:news|stories|topics)|rotating panelists|preview show|studio analysis|highlights of|replay of|rebroadcast|delayed coverage)\b',
  );
  static final otherEvent = regex(
    r'\b(olympics?|opening ceremony|closing ceremony|awards|concert|festival|marathon|rugby|volleyball|swimming|cycling|athletics|track and field)\b',
  );
  static final cfl = regex(r'\b(cfl|canadian football league)\b');
  static final sports = <(LiveSport, RegExp)>[
    (
      LiveSport.soccer,
      regex(
        r'\b(soccer|premier league|efl championship|english league championship|english championship|uefa|champions league|europa league|conference league|la liga|bundesliga|serie a|mls|nwsl|fifa|concacaf|copa|ligue 1)\b',
      ),
    ),
    (LiveSport.football, regex(r'\b(football|nfl|cfl|super bowl)\b')),
    (LiveSport.basketball, regex(r'\b(basketball|nba|wnba|fiba|euroleague)\b')),
    (LiveSport.baseball, regex(r'\b(baseball|mlb|world series)\b')),
    (LiveSport.hockey, regex(r'\b(hockey|nhl)\b')),
    (LiveSport.cricket, regex(r'\b(cricket|ipl)\b')),
    (LiveSport.tennis, regex(r'\b(tennis|atp|wta|wimbledon|roland garros)\b')),
    (LiveSport.golf, regex(r'\b(golf|pga|lpga|ryder cup)\b')),
    (
      LiveSport.racing,
      regex(r'\b(formula (?:1|one)|f1|nascar|indycar|grand prix|motogp)\b'),
    ),
    (LiveSport.combat, regex(r'\b(ufc|boxing|mma|wwe|wrestling)\b')),
  ];

  static bool containsBoth(List<String> teams, String evidence) {
    var remaining = ' ${normalized(evidence)} ';
    for (final team in [...teams]..sort((a, b) => b.length - a.length)) {
      final needle = ' ${normalized(team)} ';
      final at = remaining.indexOf(needle);
      if (at < 0) return false;
      remaining = remaining.replaceRange(at, at + needle.length, ' ');
    }
    return true;
  }

  static String cleanTitle(LiveProgram program) {
    final clean = program.name.trim().replaceFirst(livePrefix, '');
    final parts = clean.split(' — ');
    if (parts.length > 1) {
      final pair = teams(parts.last);
      if (pair == null ||
          !containsBoth(
            pair,
            '${program.overview ?? ''} ${program.episodeTitle ?? ''}',
          )) {
        parts.removeLast();
      }
    }
    return parts.join(' — ');
  }
}

/// A sports or event broadcast airing now (Apple `LiveEvent`).
class LiveEvent {
  LiveEvent({
    required this.channel,
    required this.title,
    required this.competition,
    required this.sport,
    required this.start,
    required this.end,
    required this.priority,
    required this.matchup,
    required this.context,
    required this.leagueContext,
    required this.evidence,
  });

  final MediaItem channel;
  String title;
  String competition;
  LiveSport sport;
  final DateTime start;
  final DateTime end;
  final double priority;
  final List<String>? matchup;
  final String context;
  final String leagueContext;
  final String evidence;
  LiveEventArtwork? artwork;

  String get id => channel.id;

  bool isCurrent(DateTime now) => !start.isAfter(now) && now.isBefore(end);

  double progress(DateTime now) =>
      (now.difference(start).inSeconds / end.difference(start).inSeconds).clamp(
        0.0,
        1.0,
      );

  static List<LiveEvent> select(List<MediaItem> channels, DateTime now) {
    final events = <LiveEvent>[];
    for (final channel in channels) {
      final p = channel.currentProgram;
      final start = p?.start, end = p?.end;
      if (channel.id.isEmpty ||
          p == null ||
          p.name.isEmpty ||
          start == null ||
          end == null ||
          start.isAfter(now) ||
          !now.isBefore(end) ||
          end.difference(start).inSeconds > 43200 ||
          p.isRepeat == true ||
          p.isLive == false ||
          !(p.isLive == true || _LiveRules.livePrefix.hasMatch(p.name))) {
        continue;
      }
      final name = _LiveRules.cleanTitle(p);
      final parts = name.split(' — ');
      final base = parts.first;
      final overview = p.overview ?? '';
      if (_LiveRules.placeholder.hasMatch(base) ||
          overview.toLowerCase().startsWith('threadfin:') ||
          _LiveRules.normalized(base) == _LiveRules.normalized(channel.name) ||
          _LiveRules.studio.hasMatch(base) ||
          _LiveRules.discussion.hasMatch(overview)) {
        continue;
      }
      final context = '$base ${p.genres.join(' ')}';
      final featured = p.genres.any(
        (genre) => genre.trim().toLowerCase() == 'featured live event',
      );
      final sport =
          _LiveRules.sports
              .where((s) => s.$2.hasMatch(context))
              .firstOrNull
              ?.$1 ??
          LiveSport.event;
      if (!featured &&
          sport == LiveSport.event &&
          _LiveRules.teams(base) == null &&
          !_LiveRules.otherEvent.hasMatch(base)) {
        continue;
      }
      final matchup = _LiveRules.teams(parts.length > 1 ? parts.last : base);
      final priority = featured
          ? -100.0
          : sport == LiveSport.football && _LiveRules.cfl.hasMatch(base)
          ? 2.5
          : sport.index.toDouble();
      events.add(
        LiveEvent(
          channel: channel,
          title: matchup?.join(' vs ') ?? name,
          competition: matchup != null && parts.length > 1 ? base : sport.title,
          sport: sport,
          start: start,
          end: end,
          priority: priority,
          matchup: matchup,
          context: base,
          leagueContext: context,
          evidence: '$overview ${p.episodeTitle ?? ''}',
        ),
      );
    }
    events.sort((a, b) {
      if (a.priority != b.priority) return a.priority.compareTo(b.priority);
      final fa = a.channel.userData?.isFavorite == true;
      final fb = b.channel.userData?.isFavorite == true;
      if (fa != fb) return fa ? -1 : 1;
      if (a.start != b.start) return a.start.compareTo(b.start);
      return a.channel.name.toLowerCase().compareTo(
        b.channel.name.toLowerCase(),
      );
    });
    final seen = <String>{}, channelIds = <String>{};
    return [
      for (final e in events)
        if (channelIds.add(e.id) &&
            (e.matchup == null ||
                seen.add(
                  '${e.sport}-${_LiveRules.normalized(e.title)}-${e.start.millisecondsSinceEpoch}-${e.end.millisecondsSinceEpoch}',
                )))
          e,
    ];
  }

  /// Programme images only: a channel logo inherited into the programme is
  /// not a picture of the event.
  List<LiveArtworkSource> get artworkSources {
    final sources = <LiveArtworkSource>[];
    final image = artwork?.image;
    if (image != null) sources.add(LiveArtworkSource.catalogue(image));
    final p = channel.currentProgram;
    final id = p?.id;
    if (p != null && id != null && id.isNotEmpty && id != channel.id) {
      final channelTags = {
        ...channel.imageTags.values,
        ...channel.backdropImageTags,
        ...channel.parentBackdropImageTags,
      };
      for (final (kind, tag) in [
        ('Thumb', p.imageTags['Thumb']),
        ('Backdrop', p.backdropImageTags.firstOrNull),
        ('Primary', p.imageTags['Primary']),
      ]) {
        if (tag != null &&
            tag.trim().isNotEmpty &&
            !channelTags.contains(tag)) {
          sources.add(LiveArtworkSource.program(id, kind, tag));
        }
      }
    }
    final logos = artwork?.logos ?? const [];
    if (logos.length == 2) sources.add(LiveArtworkSource.crests(logos));
    return sources;
  }
}

/// Ordered artwork candidates; the bundled illustration is the fallback.
class LiveArtworkSource {
  const LiveArtworkSource.catalogue(String this.path)
    : kind = 'catalogue',
      paths = const [],
      itemId = null,
      imageKind = null,
      tag = null;
  const LiveArtworkSource.program(
    String this.itemId,
    String this.imageKind,
    String this.tag,
  ) : kind = 'program',
      paths = const [],
      path = null;
  const LiveArtworkSource.crests(this.paths)
    : kind = 'crests',
      itemId = null,
      imageKind = null,
      tag = null,
      path = null;

  final String kind;
  final String? path;
  final String? itemId;
  final String? imageKind;
  final String? tag;
  final List<String> paths;
}

class LiveEventArtwork {
  const LiveEventArtwork({
    this.image,
    required this.logos,
    required this.teams,
    required this.sport,
  });

  final String? image;
  final List<String> logos;
  final List<String> teams;
  final LiveSport sport;

  static final _safe = RegExp(
    r'^/live-tv-logos/art/[a-z0-9][a-z0-9-]*\.(png|jpe?g|webp)$',
  );
  static bool isSafePath(String path) => _safe.hasMatch(path);
}

class _Team {
  _Team(Map<String, dynamic> json)
    : id = json['id'] as String,
      name = json['name'] as String,
      aliases = [
        for (final a in json['aliases'] as List)
          if (a is String) a,
      ];
  final String id;
  final String name;
  final List<String> aliases;

  List<String> get normalizedAliases => [
    for (final a in aliases)
      if (_LiveRules.normalized(a).length >= 3) _LiveRules.normalized(a),
  ];
}

class _Fixture {
  _Fixture(Map<String, dynamic> json)
    : sport = LiveSport.parse(json['sport'])!,
      league = json['league'] as String,
      start = json['start'] as String,
      home = _Team(json['home'] as Map<String, dynamic>),
      away = _Team(json['away'] as Map<String, dynamic>),
      image = json['image'] as String?,
      logos = [
        for (final l in json['logos'] as List? ?? const [])
          if (l is String) l,
      ];
  final LiveSport sport;
  final String league;
  final String start;
  final _Team home;
  final _Team away;
  final String? image;
  final List<String> logos;
}

/// Fixture artwork index from the optional liveArtwork module.
class LiveArtworkManifest {
  LiveArtworkManifest.fromJson(Map<String, dynamic> json)
    : version = json['version'] as int,
      _events = [
        for (final e in json['events'] as List)
          _Fixture(e as Map<String, dynamic>),
      ];

  final int version;
  final List<_Fixture> _events;

  static final _unsupported = _LiveRules.regex(
    r'\b(women|womens|female|college|ncaa|youth|under \d+|u\d{2}|u \d{2}|cfl|canadian|cricket|wnba|nwsl)\b',
  );
  static final _leagues = <(String, RegExp)>[
    ('football/nfl', _LiveRules.regex(r'\b(nfl|super bowl)\b')),
    ('basketball/nba', _LiveRules.regex(r'\bnba\b')),
    ('baseball/mlb', _LiveRules.regex(r'\bmlb\b')),
    ('hockey/nhl', _LiveRules.regex(r'\bnhl\b')),
    ('soccer/uefa.europa.conf', _LiveRules.regex(r'\bconference league\b')),
    ('soccer/uefa.europa', _LiveRules.regex(r'\beuropa league\b')),
    (
      'soccer/uefa.champions',
      _LiveRules.regex(r'\b(champions league|uefa champions)\b'),
    ),
    ('soccer/eng.1', _LiveRules.regex(r'\b(premier league|epl)\b')),
    (
      'soccer/eng.2',
      _LiveRules.regex(
        r'\b(efl championship|english league championship|english championship)\b',
      ),
    ),
  ];

  LiveEventArtwork? artworkFor(LiveEvent event) {
    final context = _LiveRules.normalized(event.leagueContext);
    if (version != 2 || _unsupported.hasMatch(context)) return null;
    final league = _leagues
        .where((l) => l.$2.hasMatch(context))
        .firstOrNull
        ?.$1;
    bool matches(String name, _Team team) {
      final n = _LiveRules.normalized(name).replaceFirst(RegExp('^the '), '');
      return team.normalizedAliases.contains(n);
    }

    final candidates = _events.where((f) {
      final start = jellyfinDate(f.start);
      if (f.home.id == f.away.id ||
          (league != null && league != f.league) ||
          !(f.sport == event.sport ||
              (event.sport == LiveSport.event && event.matchup != null)) ||
          start == null ||
          start.difference(event.start).inSeconds.abs() > 10800) {
        return false;
      }
      final pair = event.matchup;
      if (pair != null) {
        return (matches(pair[0], f.away) && matches(pair[1], f.home)) ||
            (matches(pair[0], f.home) && matches(pair[1], f.away));
      }
      return f.away.normalizedAliases.any(
        (first) => f.home.normalizedAliases.any(
          (second) => _LiveRules.containsBoth([first, second], event.evidence),
        ),
      );
    }).toList();
    if (candidates.length != 1) return null;
    final f = candidates.single;
    final image = f.image != null && LiveEventArtwork.isSafePath(f.image!)
        ? f.image
        : null;
    var logos = f.logos;
    if (logos.length != 2 || !logos.every(LiveEventArtwork.isSafePath)) {
      logos = const [];
    }
    var teams = [f.away.name, f.home.name];
    final pair = event.matchup;
    if (pair != null && matches(pair[0], f.home) && matches(pair[1], f.away)) {
      logos = logos.reversed.toList();
      teams = teams.reversed.toList();
    }
    if (image == null && logos.isEmpty) return null;
    return LiveEventArtwork(
      image: image,
      logos: logos,
      teams: teams,
      sport: f.sport,
    );
  }
}

class LiveTvSnapshot {
  LiveTvSnapshot(this.channels, this.fetchedAt);

  final List<MediaItem> channels;
  final DateTime fetchedAt;

  bool isFresh(DateTime now) {
    final age = now.difference(fetchedAt);
    return !age.isNegative && age < const Duration(seconds: 120);
  }

  List<LiveEvent> events(DateTime now, {LiveArtworkManifest? artwork}) {
    if (!isFresh(now)) return const [];
    return [
      for (final event in LiveEvent.select(channels, now))
        event..apply(artwork?.artworkFor(event)),
    ];
  }
}

extension on LiveEvent {
  void apply(LiveEventArtwork? art) {
    artwork = art;
    if (art == null) return;
    if (sport == LiveSport.event) {
      sport = art.sport;
      competition = art.sport.title;
    }
    if (matchup == null) {
      title = art.teams.join(' vs ');
      competition = context.trim();
    }
  }
}
