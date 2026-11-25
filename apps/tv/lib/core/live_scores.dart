import 'errors.dart';
import 'home.dart';
import 'jellyfin_client.dart';

/// Live scores, Live now order, favorite teams and the game cap from the
/// companion's `sportsEvents` Live now feed
/// (`/Zorofin/Companion/sportsEvents/live`). A port of the web row's matcher
/// (branding/zorofin-live-events.js `gameIndexFor`, `scoreFor`,
/// `arrangeWithFeed`) so every client puts the same score on the same card.
class LiveGameSide {
  const LiveGameSide({
    this.name = '',
    this.short = '',
    this.abbreviation = '',
    this.color = '',
    this.favorite = false,
  });

  factory LiveGameSide.fromJson(Map<String, dynamic> json) => LiveGameSide(
    name: _text(json['name']),
    short: _text(json['short']),
    abbreviation: _text(json['abbreviation']),
    color: _text(json['color']),
    favorite: json['favorite'] == true,
  );

  final String name;
  final String short;
  final String abbreviation;
  final String color;
  final bool favorite;
}

class LiveGame {
  const LiveGame({
    this.id = '',
    this.league = '',
    this.sport = '',
    this.competition = '',
    this.live,
    required this.start,
    required this.state,
    required this.home,
    required this.away,
    this.title = '',
    this.detail = '',
    this.homeScore,
    this.awayScore,
    this.channels = const [],
  });

  /// Null when the entry is unusable (no teams or no start).
  static LiveGame? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final home = value['home'], away = value['away'];
    final start = DateTime.tryParse(_text(value['start']));
    if (home is! Map<String, dynamic> ||
        away is! Map<String, dynamic> ||
        start == null) {
      return null;
    }
    final score = value['score'];
    final channels = value['channels'];
    return LiveGame(
      id: _text(value['id']),
      league: _text(value['league']),
      sport: _text(value['sport']),
      competition: _text(value['competition']),
      live: value['live'] is bool ? value['live'] as bool : null,
      start: start,
      state: _text(value['state']),
      title: _text(value['title']),
      detail: _text(value['detail']),
      home: LiveGameSide.fromJson(home),
      away: LiveGameSide.fromJson(away),
      homeScore: score is Map ? _score(score['home']) : null,
      awayScore: score is Map ? _score(score['away']) : null,
      channels: [
        if (channels is List)
          for (final c in channels)
            if (c is Map && c['name'] is String) c['name'] as String,
      ],
    );
  }

  final String id, league, sport, competition;
  final bool? live;
  final DateTime start;

  /// `pre`, `in` or `post`.
  final String state;
  final String title;
  final String detail;
  final LiveGameSide home;
  final LiveGameSide away;
  final String? homeScore;
  final String? awayScore;

  /// Names of the event channels the companion matched to this game.
  final List<String> channels;

  bool get favorite => home.favorite || away.favorite;
}

class LiveScoresFeed {
  const LiveScoresFeed({
    required this.games,
    this.leagues = const [],
    this.maxGames,
    this.spoilerFree = false,
    this.order = '',
  });
  final int? maxGames;
  final bool spoilerFree;
  final String order;

  /// Null when the server has no successful schedule read yet: keep the
  /// guide-only row.
  static LiveScoresFeed? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    final games = json['games'], leagues = json['leagues'];
    if (games is! List || json['updatedAt'] == null) return null;
    return LiveScoresFeed(
      maxGames: json['maxGames'] is int ? json['maxGames'] as int : null,
      spoilerFree: json['spoilerFree'] == true,
      order: _text(json['order']),
      games: [for (final g in games) ?LiveGame.fromJson(g)],
      leagues: [
        if (leagues is List)
          for (final l in leagues)
            if (l is String) l,
      ],
    );
  }

  /// Already in the operator's order (favorites, Live now, leagues, start)
  /// and cut to their most-games setting.
  final List<LiveGame> games;

  /// ESPN paths of the leagues this server follows.
  final List<String> leagues;
}

/// What a card shows under its art: one row per team, away first.
class LiveScore {
  const LiveScore({
    required this.away,
    required this.awayScore,
    required this.home,
    required this.homeScore,
    required this.detail,
    required this.isFinal,
    this.awayName = '',
    this.homeName = '',
    this.awayColor,
    this.homeColor,
  });

  final String away;
  final String awayScore;
  final String home;
  final String homeScore;
  final String detail;
  final bool isFinal;
  final String awayName;
  final String homeName;

  /// 0xRRGGBB, or null for the neutral edge.
  final int? awayColor;
  final int? homeColor;

  bool get awayLeads =>
      (int.tryParse(awayScore) ?? 0) > (int.tryParse(homeScore) ?? 0);
  bool get homeLeads =>
      (int.tryParse(homeScore) ?? 0) > (int.tryParse(awayScore) ?? 0);

  /// "LIVE · Q3 4:12", or "Final" when the game is over.
  String get status => isFinal
      ? (detail.isEmpty ? 'Final' : detail)
      : 'Live${detail.isEmpty ? '' : ' · $detail'}';

  /// For screen readers: "BKN 64 – 88 DAL · Q3 4:12".
  String get text =>
      '$away $awayScore – $homeScore $home${detail.isEmpty ? '' : ' · $detail'}';
}

abstract final class LiveScores {
  static const _sameGameWindow = Duration(hours: 6);

  /// A guide team name names this side: full or short name (or the end of
  /// one), or the abbreviation.
  static bool sameTeam(String guide, LiveGameSide side) {
    final g = LiveText.normalized(guide);
    if (g.isEmpty) return false;
    for (final value in [side.name, side.short]) {
      final v = LiveText.normalized(value);
      if (v.isEmpty) continue;
      if (g == v ||
          (g.length > 3 && (v.endsWith(' $g') || g.endsWith(' $v')))) {
        return true;
      }
    }
    return LiveText.normalized(side.abbreviation) == g;
  }

  /// The feed game this event is showing: both teams name the same game, or
  /// the companion matched the game to this channel; it started within six
  /// hours of the listing.
  static int gameIndexFor(LiveEvent event, List<LiveGame> games) {
    final named = event.channel.name.split(' — ');
    final channel = LiveText.normalized(event.channel.name);
    final pairs = [
      event.matchup,
      if (named.length > 1) LiveText.teams(named.last),
    ].whereType<List<String>>().where((p) => p.length == 2).toList();
    for (final (i, game) in games.indexed) {
      if (game.start.difference(event.start).abs() > _sameGameWindow) continue;
      final byTeams = pairs.any(
        (pair) =>
            pair.every(
              (t) => sameTeam(t, game.home) || sameTeam(t, game.away),
            ) &&
            !(sameTeam(pair[0], game.home) && sameTeam(pair[1], game.home)) &&
            !(sameTeam(pair[0], game.away) && sameTeam(pair[1], game.away)),
      );
      final byChannel =
          channel.isNotEmpty &&
          game.channels.any((c) => LiveText.normalized(c) == channel);
      if (byTeams || byChannel) return i;
    }
    return -1;
  }

  static final _digits = RegExp(r'^\d{1,3}$');
  static final _hex = RegExp(r'^#[0-9a-fA-F]{6}$');

  static LiveScore? scoreFor(LiveEvent event, List<LiveGame> games) {
    final at = gameIndexFor(event, games);
    return at < 0 ? null : scoreOf(games[at]);
  }

  static LiveScore? scoreOf(LiveGame game) {
    final home = game.homeScore, away = game.awayScore;
    if (game.state == 'pre' || home == null || away == null) return null;
    if (!_digits.hasMatch(home) || !_digits.hasMatch(away)) return null;
    String label(LiveGameSide s) => _cut(
      [
        s.abbreviation,
        s.short,
        s.name,
      ].firstWhere((v) => v.isNotEmpty, orElse: () => ''),
      12,
    );
    String name(LiveGameSide s) =>
        _cut(s.short.isNotEmpty ? s.short : s.name, 24);
    // Soccer is written home first ("Arsenal 1–0 Dortmund"), matching the
    // match art, which puts the home crest on the left.
    final homeFirst = game.sport == 'soccer';
    final first = homeFirst ? game.home : game.away,
        second = homeFirst ? game.away : game.home;
    return LiveScore(
      away: label(first),
      awayScore: homeFirst ? home : away,
      home: label(second),
      homeScore: homeFirst ? away : home,
      detail: _cut(game.detail, 40),
      isFinal: game.state == 'post',
      awayName: name(first),
      homeName: name(second),
      awayColor: color(first.color),
      homeColor: color(second.color),
    );
  }

  /// A team colour, or a light grey for colours that would vanish on the
  /// dark page (Nets black).
  static int? color(String hex) {
    if (!_hex.hasMatch(hex)) return null;
    final n = int.parse(hex.substring(1), radix: 16);
    final luma =
        ((n >> 16) * 299 + ((n >> 8) & 255) * 587 + (n & 255) * 114) / 1000;
    return luma < 40 ? 0xd9dedb : n;
  }

  static final _plainTitle = RegExp(r'^[^<>]{3,80}$');

  /// With a feed, the row follows the operator's settings: feed order (Live
  /// now order and favorite teams), its length and its leagues. Games the
  /// feed covers but left out are dropped; events it can't know about
  /// (boxing, cricket, college) keep their place after. Without a feed the
  /// guide order stays.
  static List<LiveEvent> arrange(List<LiveEvent> events, LiveScoresFeed? feed) {
    if (feed == null) {
      for (final e in events) {
        e
          ..score = null
          ..favoriteTeam = false;
      }
      return events;
    }
    final feedOrder = feed.games.indexed.toList()
      ..sort((a, b) {
        final left = a.$2.live ?? a.$2.state == 'in',
            right = b.$2.live ?? b.$2.state == 'in';
        return left != right ? (left ? -1 : 1) : a.$1.compareTo(b.$1);
      });
    final games = feedOrder
        .take(
          (feed.maxGames ?? feed.games.length)
              .clamp(0, feed.games.length)
              .toInt(),
        )
        .map((g) => g.$2)
        .toList();
    final matched = <(int, LiveEvent)>[], others = <LiveEvent>[];
    for (final event in events) {
      final at = gameIndexFor(event, games);
      if (at >= 0) {
        final game = games[at];
        event
          ..favoriteTeam = game.favorite
          ..score = feed.spoilerFree ? null : scoreOf(game);
        if (event.matchup == null && _plainTitle.hasMatch(game.title)) {
          event.title = game.title;
        }
        // A guide listing without sport words ("Live event") takes the matched
        // game's sport and competition, as the web does.
        final sport = LiveSport.parse(game.sport);
        if (event.sport == LiveSport.event &&
            sport != null &&
            sport != LiveSport.event) {
          event.sport = sport;
          if (game.competition.isNotEmpty) event.competition = game.competition;
        }
        matched.add((at, event));
      } else {
        event
          ..score = null
          ..favoriteTeam = false;
        if (!feed.leagues.contains(leagueFor(event.leagueContext))) {
          others.add(event);
        }
      }
    }
    // Stable: equal positions keep their guide order before the duplicate cut.
    final ordered = [for (final (i, m) in matched.indexed) (m.$1, i, m.$2)]
      ..sort((a, b) {
        if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
        bool preferred(LiveEvent e) => games[a.$1].channels.any(
          (name) =>
              LiveText.normalized(name) == LiveText.normalized(e.channel.name),
        );
        final left = preferred(a.$3), right = preferred(b.$3);
        return left != right ? (left ? -1 : 1) : a.$2.compareTo(b.$2);
      });
    final seen = <int>{};
    return [
      for (final (at, _, event) in ordered)
        if (seen.add(at)) event,
      ...others,
    ];
  }

  /// Strict guide-backed membership, companion settings, artwork last.
  static List<LiveEvent> fromSnapshot(
    LiveTvSnapshot snapshot,
    LiveScoresFeed? feed,
    DateTime now, {
    LiveArtworkManifest? artwork,
  }) {
    if (!snapshot.isFresh(now)) return [];
    final candidates = LiveEvent.select(
      snapshot.channels,
      now,
      deduplicateSimulcasts: feed == null,
    );
    final events = arrange(candidates, feed);
    for (final event in events) {
      event.artwork = artwork?.artworkFor(event);
    }
    return events;
  }

  static final _leagues = <(RegExp, String)>[
    (
      RegExp(
        r'\b(college|ncaa|youth|under \d+|u\d{2}|u \d{2}|cfl|canadian|cricket|wnba|nwsl)\b',
      ),
      'unsupported',
    ),
    (RegExp(r'\b(wsl|women(?: s|s)? super league)\b'), 'soccer/eng.w.1'),
    (RegExp(r'\b(women|womens|female)\b'), 'unsupported'),
    (RegExp(r'\b(nfl|super bowl)\b'), 'football/nfl'),
    (RegExp(r'\bnba\b'), 'basketball/nba'),
    (RegExp(r'\bmlb\b'), 'baseball/mlb'),
    (RegExp(r'\bnhl\b'), 'hockey/nhl'),
    (RegExp(r'\bconference league\b'), 'soccer/uefa.europa.conf'),
    (RegExp(r'\beuropa league\b'), 'soccer/uefa.europa'),
    (RegExp(r'\b(champions league|uefa champions)\b'), 'soccer/uefa.champions'),
    (RegExp(r'\b(serie a|italian soccer)\b'), 'soccer/ita.1'),
    (RegExp(r'\b(ligue 1|french soccer)\b'), 'soccer/fra.1'),
    (RegExp(r'\bscottish\b'), 'unsupported'),
    (RegExp(r'\b(premier league|epl)\b'), 'soccer/eng.1'),
    (
      RegExp(
        r'\b(efl championship|english league championship|english championship)\b',
      ),
      'soccer/eng.2',
    ),
  ];

  /// The ESPN league path a guide listing belongs to, as the web row reads it.
  static String leagueFor(String text) {
    final t = LiveText.normalized(text);
    for (final (pattern, league) in _leagues) {
      if (pattern.hasMatch(t)) return league;
    }
    return '';
  }
}

/// One Live now read per minute per account; a missing route (no companion,
/// module off) backs off for ten minutes.
class LiveScoresCache {
  LiveScoresCache({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const ttl = Duration(seconds: 60);
  static const missingBackoff = Duration(minutes: 10);

  final DateTime Function() _clock;
  Object? _owner;
  LiveScoresFeed? _feed;
  DateTime? _fetched;
  DateTime? _missingUntil;
  Future<LiveScoresFeed?>? _pending;

  /// The last feed read for this account, without a request.
  LiveScoresFeed? feedFor(JellyfinClient client) =>
      Object.hash(client.server, client.session?.token) == _owner
      ? _feed
      : null;

  void reset() {
    _owner = null;
    _feed = null;
    _fetched = null;
    _missingUntil = null;
    _pending = null;
  }

  /// The current feed, refreshed when stale. Never throws.
  Future<LiveScoresFeed?> load(JellyfinClient client) {
    final owner = Object.hash(client.server, client.session?.token);
    if (owner != _owner) {
      reset();
      _owner = owner;
    }
    final now = _clock();
    if (_missingUntil != null && now.isBefore(_missingUntil!)) {
      return Future.value(null);
    }
    if (_fetched != null && now.difference(_fetched!) < ttl) {
      return Future.value(_feed);
    }
    return _pending ??= _read(
      client,
      owner,
    ).whenComplete(() => _pending = null);
  }

  Future<LiveScoresFeed?> _read(JellyfinClient client, Object owner) async {
    try {
      final feed = await client.liveScores();
      if (owner == _owner) {
        _feed = feed;
        _fetched = _clock();
      }
    } on ClientError catch (e) {
      if (owner == _owner) {
        _fetched = _clock();
        if (e.kind == ClientErrorKind.forbidden ||
            e.kind == ClientErrorKind.unauthorized ||
            (e.kind == ClientErrorKind.unavailable && e.status == 404)) {
          _feed = null;
          _missingUntil = _clock().add(missingBackoff);
        }
      }
    } catch (_) {
      if (owner == _owner) _fetched = _clock();
    }
    return owner == _owner ? _feed : null;
  }
}

extension LiveScoresClient on JellyfinClient {
  /// The companion's Live now feed for the rest of today. Throws when the
  /// route is missing (404) or the module refuses (403).
  Future<LiveScoresFeed?> liveScores() async {
    final json = await requestJson(
      ['Zorofin', 'Companion', 'sportsEvents', 'live'],
      query: const {'window': 'today'},
      extensionToken: true,
      expectedStatus: 200,
    );
    return LiveScoresFeed.fromJson(json);
  }
}

String _text(Object? value) => value is String ? value.trim() : '';

String? _score(Object? value) => switch (value) {
  final String s => s.trim(),
  final int n => '$n',
  _ => null,
};

String _cut(String text, int max) =>
    text.length <= max ? text : text.substring(0, max);

/// The words under a scored card, the same on every Flutter client and LG.
extension LiveEventScoreText on LiveEvent {
  /// "NBA · Q4 4:12", "NBA · Final"; null without a score.
  String? get scoreStatus {
    final s = score;
    if (s == null) return null;
    final state = s.isFinal
        ? (s.detail.isEmpty ? 'Final' : s.detail)
        : (s.detail.isEmpty ? 'Live' : s.detail);
    final league = competition.trim();
    return league.isEmpty ? state : '$league · $state';
  }

  /// "Your teams · ESPN · Ch 206" or "ESPN · Ch 206".
  String get channelLine {
    final name =
        channel.name +
        (channel.channelNumber == null ? '' : ' · Ch ${channel.channelNumber}');
    return favoriteTeam ? 'Your teams · $name' : name;
  }
}

/// The card tint for a scored game: a team colour darkened like the site's
/// tints so white text stays clear, or the site's navy. 0xRRGGBB.
int liveScoreTint(LiveScore score) {
  final c = score.homeColor ?? score.awayColor;
  if (c == null) return 0x1E3A5F;
  int dark(int shift) => (((c >> shift) & 0xFF) * 0.45).round() << shift;
  return dark(16) | dark(8) | dark(0);
}
