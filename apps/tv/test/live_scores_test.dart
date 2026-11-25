import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/home.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/live_scores.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/server_address.dart';

// The same cases as the web row (support-agent/tests/live-events.test.js), so
// every client puts the same score on the same card.
final start = DateTime.utc(2026, 11, 9, 0, 30);

LiveEvent event(
  String channel, {
  List<String>? matchup,
  DateTime? at,
  String leagueContext = 'NBA Basketball',
}) => LiveEvent(
  channel: MediaItem(id: channel, name: channel, type: 'TvChannel'),
  title: matchup?.join(' vs ') ?? channel,
  competition: 'NBA',
  sport: LiveSport.basketball,
  start: at ?? start,
  end: (at ?? start).add(const Duration(hours: 3)),
  priority: 0,
  matchup: matchup,
  context: leagueContext,
  leagueContext: leagueContext,
  evidence: '',
);

Map<String, dynamic> side(
  String name,
  String short,
  String abbreviation, {
  bool favorite = false,
  String color = '',
}) => {
  'name': name,
  'short': short,
  'abbreviation': abbreviation,
  'favorite': favorite,
  'color': color,
};

Map<String, dynamic> nets({
  String state = 'in',
  Object? score = const {'home': '88', 'away': '64'},
  String detail = 'Q3 4:12',
  List<Map<String, dynamic>> channels = const [],
}) => {
  'id': 'nba:1',
  'state': state,
  'start': start.toIso8601String(),
  'detail': detail,
  'score': ?score,
  'home': side('Dallas Mavericks', 'Mavericks', 'DAL'),
  'away': side('Brooklyn Nets', 'Nets', 'BKN', color: '#000000'),
  'channels': channels,
};

List<LiveGame> games(List<Map<String, dynamic>> json) => [
  for (final g in json) LiveGame.fromJson(g)!,
];

void main() {
  test(
    'guide membership follows companion cap favorites and spoilers, with other events after',
    () {
      final now = start.add(const Duration(minutes: 30));
      MediaItem channel(String id, {String? title}) => MediaItem(
        id: id,
        name: id,
        type: 'TvChannel',
        currentProgram: LiveProgram(
          name: title ?? 'Live: NBA Basketball — Away $id vs Home $id',
          start: start,
          end: start.add(const Duration(hours: 3)),
          isLive: true,
        ),
      );
      LiveGame game(String id, {bool favorite = false}) => LiveGame(
        start: start,
        state: 'in',
        home: LiveGameSide(
          name: 'Home $id',
          short: 'Home',
          abbreviation: 'H',
          color: '',
          favorite: favorite,
        ),
        away: LiveGameSide(
          name: 'Away $id',
          short: 'Away',
          abbreviation: 'A',
          color: '',
          favorite: false,
        ),
        homeScore: '8',
        awayScore: '6',
        channels: [id],
        id: 'nba:$id',
        league: 'nba',
        sport: 'basketball',
        live: true,
      );
      final guide = LiveTvSnapshot([
        channel('one'),
        channel('two'),
        channel('omitted'),
        channel('boxing', title: 'Live: Top Rank Boxing'),
      ], now);
      final feed = LiveScoresFeed(
        games: [game('two', favorite: true), game('one')],
        leagues: ['basketball/nba'],
        maxGames: 1,
        spoilerFree: true,
      );
      final events = LiveScores.fromSnapshot(guide, feed, now);
      expect(events.map((e) => e.id), ['two', 'boxing']);
      expect(events.first.favoriteTeam, isTrue);
      expect(events.first.score, isNull);
      expect(LiveScores.fromSnapshot(guide, null, now).length, 4);
      expect(
        LiveScores.fromSnapshot(
          guide,
          const LiveScoresFeed(games: [], leagues: ['basketball/nba']),
          now,
        ).map((e) => e.id),
        ['boxing'],
      );
      expect(
        LiveScores.fromSnapshot(LiveTvSnapshot([], now), feed, now),
        isEmpty,
      );
      final simulcast = LiveTvSnapshot([
        channel('a-copy', title: 'Live: NBA Basketball — Away one vs Home one'),
        channel('one'),
      ], now);
      expect(
        LiveScores.fromSnapshot(
          simulcast,
          LiveScoresFeed(games: [game('one')], leagues: ['basketball/nba']),
          now,
        ).single.id,
        'one',
      );
      final settings = LiveScoresFeed.fromJson({
        'updatedAt': '2026-11-09T01:00:00Z',
        'games': [],
        'maxGames': 2,
        'spoilerFree': true,
        'order': 'favorites',
      })!;
      expect(settings.maxGames, 2);
      expect(settings.spoilerFree, isTrue);
      expect(settings.order, 'favorites');
    },
  );
  test('a game both guide teams name gets its score', () {
    final e = event(
      'NBA — Nets At Mavericks',
      matchup: ['Brooklyn Nets', 'Dallas Mavericks'],
    );
    final score = LiveScores.scoreFor(e, games([nets()]))!;
    expect(score.away, 'BKN');
    expect(score.awayScore, '64');
    expect(score.home, 'DAL');
    expect(score.homeScore, '88');
    expect(score.awayName, 'Nets');
    expect(score.homeName, 'Mavericks');
    expect(score.isFinal, isFalse);
    expect(score.homeLeads, isTrue);
    expect(score.awayColor, 0xd9dedb, reason: 'black would vanish');
    expect(score.homeColor, isNull);
    expect(score.status, 'Live · Q3 4:12');
    expect(score.text, 'BKN 64 – 88 DAL · Q3 4:12');
  });

  test('scores need the same game, a started game and plain numbers', () {
    final e = event(
      'NBA — Nets At Mavericks',
      matchup: ['Brooklyn Nets', 'Dallas Mavericks'],
    );
    expect(
      LiveScores.scoreFor(
        event('Sports', matchup: ['Nets', 'Mavericks']),
        games([nets()]),
      ),
      isNotNull,
      reason: 'short names match',
    );
    expect(
      LiveScores.scoreFor(
        event('Test Sports', matchup: ['Brooklyn Nets', 'Miami Heat']),
        games([nets()]),
      ),
      isNull,
      reason: 'one team is not enough',
    );
    expect(
      LiveScores.scoreFor(
        event(
          'NBA — Nets At Mavericks',
          matchup: ['Brooklyn Nets', 'Dallas Mavericks'],
          at: start.add(const Duration(hours: 12)),
        ),
        games([nets()]),
      ),
      isNull,
      reason: 'a different day is not the same game',
    );
    expect(LiveScores.scoreFor(e, games([nets(score: null)])), isNull);
    expect(LiveScores.scoreFor(e, games([nets(state: 'pre')])), isNull);
    expect(
      LiveScores.scoreFor(
        e,
        games([
          nets(score: {'home': '<b>', 'away': '1'}),
        ]),
      ),
      isNull,
    );
    expect(
      LiveScores.scoreFor(
        event('ESPN'),
        games([
          nets(
            channels: [
              {'name': 'ESPN'},
            ],
          ),
        ]),
      )!.isFinal,
      isFalse,
      reason: 'companion channel match works without a matchup',
    );
    final done = LiveScores.scoreFor(
      e,
      games([nets(state: 'post', detail: 'Final')]),
    )!;
    expect(done.isFinal, isTrue);
    expect(done.status, 'Final');
  });

  test('an event channel named after its game matches', () {
    final feed = games([nets()]);
    expect(
      LiveScores.scoreFor(event('NBA — Nets At Mavericks'), feed)!.home,
      'DAL',
    );
    expect(LiveScores.scoreFor(event('NBA — Heat At Kings'), feed), isNull);
    expect(LiveScores.scoreFor(event('NBA 7'), feed), isNull);
  });

  test('the feed sets the row order, its cap and favorite teams', () {
    final feed = LiveScoresFeed(
      games: games([
        {
          'state': 'in',
          'start': start.toIso8601String(),
          'home': side('Sacramento Kings', 'Kings', 'SAC', favorite: true),
          'away': side('Miami Heat', 'Heat', 'MIA'),
        },
        {
          'state': 'in',
          'start': start.toIso8601String(),
          'home': side('Dallas Mavericks', 'Mavericks', 'DAL'),
          'away': side('Brooklyn Nets', 'Nets', 'BKN'),
        },
      ]),
      leagues: ['basketball/nba'],
    );
    List<LiveEvent> events() => [
      event('NBA — Nets At Mavericks'),
      event('NBA — Celtics At Bucks'),
      event('ESPN', leagueContext: 'Boxing'),
      event('NBA — Heat At Kings'),
    ];
    final out = LiveScores.arrange(events(), feed);
    expect(
      out.map((e) => e.channel.name),
      ['NBA — Heat At Kings', 'NBA — Nets At Mavericks', 'ESPN'],
      reason: 'feed order first, game cut by the cap dropped, boxing kept',
    );
    expect(out[0].favoriteTeam, isTrue);
    expect(out[1].favoriteTeam, isFalse);
    expect(out[0].score, isNull, reason: 'spoiler-free feed has no score');
    expect(
      LiveScores.arrange(events(), LiveScoresFeed(games: feed.games)).length,
      4,
      reason: 'leagues the server does not follow stay',
    );
    final guide = events();
    expect(LiveScores.arrange(guide, null), guide);
  });

  test('a feed without a first schedule read keeps the guide row', () {
    expect(LiveScoresFeed.fromJson({'games': [], 'updatedAt': null}), isNull);
    final feed = LiveScoresFeed.fromJson({
      'games': [
        nets(),
        {'home': 'bad'},
      ],
      'updatedAt': '2026-11-09T01:00:00Z',
      'spoilerFree': false,
      'leagues': ['basketball/nba'],
      'maxGames': 20,
      'order': 'league',
    })!;
    expect(feed.games, hasLength(1));
    expect(feed.leagues, ['basketball/nba']);
  });

  group('cache', () {
    final server = ServerAddress.parse('https://media.example/jellyfin');
    JellyfinClient client(MockClientHandler handler, {String token = 'tok'}) =>
        JellyfinClient(
          server: server,
          identity: const ClientIdentity(deviceId: 'tv-1', deviceName: 'TV'),
          session: Session(
            server: server,
            viewer: Viewer(id: 'u1', name: 'Viewer'),
            token: token,
            deviceId: 'tv-1',
          ),
          httpClient: MockClient(handler),
        );

    test('reads once a minute, through the plugin route', () async {
      var now = DateTime.utc(2026, 11, 9, 1);
      var calls = 0;
      final c = client((request) async {
        calls++;
        expect(
          request.url.path,
          '/jellyfin/Zorofin/Companion/sportsEvents/live',
        );
        expect(request.url.queryParameters['window'], 'today');
        expect(request.headers['X-Jellyfin-Token'], 'tok');
        return http.Response(
          jsonEncode({
            'games': [nets()],
            'updatedAt': '2026-11-09T01:00:00Z',
          }),
          200,
        );
      });
      final cache = LiveScoresCache(clock: () => now);
      expect((await cache.load(c))!.games, hasLength(1));
      await cache.load(c);
      expect(calls, 1);
      now = now.add(const Duration(seconds: 61));
      await cache.load(c);
      expect(calls, 2);
    });

    test('a missing module backs off for ten minutes', () async {
      var now = DateTime.utc(2026, 11, 9, 1);
      var calls = 0;
      final c = client((_) async {
        calls++;
        return http.Response('{"error":"Not found"}', 404);
      });
      final cache = LiveScoresCache(clock: () => now);
      expect(await cache.load(c), isNull);
      now = now.add(const Duration(minutes: 5));
      expect(await cache.load(c), isNull);
      expect(calls, 1);
      now = now.add(const Duration(minutes: 6));
      await cache.load(c);
      expect(calls, 2);
    });

    test('another account starts fresh', () async {
      var calls = 0;
      Future<http.Response> handler(http.Request _) async {
        calls++;
        return http.Response('{"error":"admin_only"}', 403);
      }

      final cache = LiveScoresCache();
      await cache.load(client(handler));
      await cache.load(client(handler, token: 'other'));
      expect(calls, 2);
    });
  });

  test('scored cards read league and clock, channel and a dark team tint', () {
    final e = event('ESPN');
    const live = LiveScore(
      away: 'BKN',
      awayScore: '79',
      home: 'DAL',
      homeScore: '88',
      detail: 'Q4 4:12',
      isFinal: false,
      homeColor: 0x0053BC,
    );
    expect(e.scoreStatus, isNull);
    e.score = live;
    expect(e.scoreStatus, 'NBA · Q4 4:12');
    expect(e.channelLine, 'ESPN');
    e.favoriteTeam = true;
    expect(e.channelLine, 'Your teams · ESPN');
    e.score = const LiveScore(
      away: 'BKN',
      awayScore: '79',
      home: 'DAL',
      homeScore: '88',
      detail: '',
      isFinal: true,
    );
    expect(e.scoreStatus, 'NBA · Final');
    expect(liveScoreTint(live), 0x002555);
    expect(liveScoreTint(e.score!), 0x1E3A5F);
  });
}
