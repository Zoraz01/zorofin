import Foundation

/// Live scores, Live now order, favorite teams and the game cap from the
/// companion's `sportsEvents` Live now feed (`/Zorofin/Companion/sportsEvents/live`).
/// A port of the web row's matcher (branding/zorofin-live-events.js `gameIndexFor`,
/// `scoreFor`, `arrangeWithFeed`) and of the TV app's `live_scores.dart`, so every
/// client puts the same score on the same card.
public struct LiveGameSide: Sendable, Equatable {
    public var name = "", short = "", abbreviation = "", color = ""
    public var favorite = false
    public init(name: String = "", short: String = "", abbreviation: String = "", color: String = "", favorite: Bool = false) {
        self.name = name; self.short = short; self.abbreviation = abbreviation; self.color = color; self.favorite = favorite
    }
    init(json: [String: Any]) {
        self.init(name: LiveScores.text(json["name"]), short: LiveScores.text(json["short"]),
                  abbreviation: LiveScores.text(json["abbreviation"]), color: LiveScores.text(json["color"]),
                  favorite: json["favorite"] as? Bool == true)
    }
}

public struct LiveGame: Sendable, Equatable {
    public let id: String, league: String, sport: String, competition: String
    public let live: Bool?
    public let start: Date
    /// `pre`, `in` or `post`.
    public let state: String
    public let title: String
    public let detail: String
    public let home: LiveGameSide
    public let away: LiveGameSide
    public let homeScore: String?
    public let awayScore: String?
    /// Names of the event channels the companion matched to this game.
    public let channels: [String]
    public var favorite: Bool { home.favorite || away.favorite }

    public init(start: Date, state: String, title: String = "", detail: String = "", home: LiveGameSide, away: LiveGameSide,
                homeScore: String? = nil, awayScore: String? = nil, channels: [String] = [], id: String = "", league: String = "", sport: String = "", competition: String = "", live: Bool? = nil) {
        self.id = id; self.league = league; self.sport = sport; self.competition = competition; self.live = live
        self.start = start; self.state = state; self.title = title; self.detail = detail; self.home = home; self.away = away
        self.homeScore = homeScore; self.awayScore = awayScore; self.channels = channels
    }

    /// Nil when the entry is unusable (no teams or no start).
    init?(json: Any) {
        guard let json = json as? [String: Any], let home = json["home"] as? [String: Any],
              let away = json["away"] as? [String: Any], let start = HomeRowCard.date(json["start"] as? String) else { return nil }
        let score = json["score"] as? [String: Any]
        self.init(start: start, state: LiveScores.text(json["state"]), title: LiveScores.text(json["title"]),
                  detail: LiveScores.text(json["detail"]), home: LiveGameSide(json: home), away: LiveGameSide(json: away),
                  homeScore: score.flatMap { LiveScores.points($0["home"]) }, awayScore: score.flatMap { LiveScores.points($0["away"]) },
                  channels: (json["channels"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["name"] as? String },
                  id: LiveScores.text(json["id"]), league: LiveScores.text(json["league"]), sport: LiveScores.text(json["sport"]), competition: LiveScores.text(json["competition"]), live: json["live"] as? Bool)
    }
}

public struct LiveScoresFeed: Sendable, Equatable {
    /// Already in the operator's order (favorites, Live now, leagues, start) and
    /// cut to their most-games setting.
    public let games: [LiveGame]
    /// ESPN paths of the leagues this server follows.
    public let leagues: [String]
    public let maxGames: Int?
    public let spoilerFree: Bool
    public let order: String
    public init(games: [LiveGame], leagues: [String] = [], maxGames: Int? = nil, spoilerFree: Bool = false, order: String = "") {
        self.games = games; self.leagues = leagues; self.maxGames = maxGames; self.spoilerFree = spoilerFree; self.order = order
    }

    /// Nil when the server has no successful schedule read yet: keep the guide-only row.
    public static func decode(_ data: Data) throws -> LiveScoresFeed? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClientError.invalidResponse }
        guard let games = json["games"] as? [Any], let updated = json["updatedAt"], !(updated is NSNull) else { return nil }
        return LiveScoresFeed(games: games.compactMap { LiveGame(json: $0) },
                              leagues: (json["leagues"] as? [Any] ?? []).compactMap { $0 as? String },
                              maxGames: json["maxGames"] as? Int, spoilerFree: json["spoilerFree"] as? Bool ?? false, order: LiveScores.text(json["order"]))
    }
}

/// What a card shows under its art: one row per team, away first.
public struct LiveScore: Sendable, Equatable, Hashable {
    public let away: String, awayScore: String, home: String, homeScore: String
    public let detail: String
    public let isFinal: Bool
    public let awayName: String, homeName: String
    /// 0xRRGGBB, or nil for the neutral edge.
    public let awayColor: Int?, homeColor: Int?

    public init(away: String, awayScore: String, home: String, homeScore: String, detail: String, isFinal: Bool,
                awayName: String, homeName: String, awayColor: Int?, homeColor: Int?) {
        self.away = away; self.awayScore = awayScore; self.home = home; self.homeScore = homeScore
        self.detail = detail; self.isFinal = isFinal; self.awayName = awayName; self.homeName = homeName
        self.awayColor = awayColor; self.homeColor = homeColor
    }

    public var awayLeads: Bool { (Int(awayScore) ?? 0) > (Int(homeScore) ?? 0) }
    public var homeLeads: Bool { (Int(homeScore) ?? 0) > (Int(awayScore) ?? 0) }
    /// "Live · Q3 4:12", or "Final" when the game is over.
    public var status: String { isFinal ? (detail.isEmpty ? "Final" : detail) : "Live" + (detail.isEmpty ? "" : " · " + detail) }
    /// For VoiceOver: "BKN 64 – 88 DAL · Q3 4:12".
    public var text: String { "\(away) \(awayScore) – \(homeScore) \(home)" + (detail.isEmpty ? "" : " · " + detail) }
}

public enum LiveScores {
    static let sameGameWindow: TimeInterval = 6 * 3600

    /// A guide team name names this side: full or short name (or the end of one), or the abbreviation.
    public static func sameTeam(_ guide: String, _ side: LiveGameSide) -> Bool {
        let g = LiveRules.normalized(guide)
        guard !g.isEmpty else { return false }
        for value in [side.name, side.short] {
            let v = LiveRules.normalized(value)
            if v.isEmpty { continue }
            if g == v || (g.count > 3 && (v.hasSuffix(" " + g) || g.hasSuffix(" " + v))) { return true }
        }
        return LiveRules.normalized(side.abbreviation) == g
    }

    /// The feed game this event is showing: both teams name the same game, or the
    /// companion matched the game to this channel; it started within six hours of the listing.
    public static func gameIndex(for event: LiveEvent, in games: [LiveGame]) -> Int? {
        let named = event.channel.name.components(separatedBy: " — ")
        let channel = LiveRules.normalized(event.channel.name)
        let pairs = [event.matchup, named.count > 1 ? LiveRules.teams(named.last!) : nil]
            .compactMap { $0 }.filter { $0.count == 2 }
        for (index, game) in games.enumerated() {
            if abs(game.start.timeIntervalSince(event.start)) > sameGameWindow { continue }
            let byTeams = pairs.contains { pair in
                pair.allSatisfy { sameTeam($0, game.home) || sameTeam($0, game.away) }
                    && !(sameTeam(pair[0], game.home) && sameTeam(pair[1], game.home))
                    && !(sameTeam(pair[0], game.away) && sameTeam(pair[1], game.away))
            }
            let byChannel = !channel.isEmpty && game.channels.contains { LiveRules.normalized($0) == channel }
            if byTeams || byChannel { return index }
        }
        return nil
    }

    public static func score(for event: LiveEvent, in games: [LiveGame]) -> LiveScore? {
        gameIndex(for: event, in: games).flatMap { score(of: games[$0]) }
    }

    public static func score(of game: LiveGame) -> LiveScore? {
        guard game.state != "pre", let home = game.homeScore, let away = game.awayScore,
              isPoints(home), isPoints(away) else { return nil }
        func label(_ side: LiveGameSide) -> String {
            cut([side.abbreviation, side.short, side.name].first { !$0.isEmpty } ?? "", 12)
        }
        func name(_ side: LiveGameSide) -> String { cut(side.short.isEmpty ? side.name : side.short, 24) }
        // Soccer is written home first ("Arsenal 1–0 Dortmund"), matching the match art,
        // which puts the home crest on the left.
        let homeFirst = game.sport == "soccer"
        let first = homeFirst ? game.home : game.away, second = homeFirst ? game.away : game.home
        return LiveScore(away: label(first), awayScore: homeFirst ? home : away, home: label(second), homeScore: homeFirst ? away : home,
                         detail: cut(game.detail, 40), isFinal: game.state == "post",
                         awayName: name(first), homeName: name(second),
                         awayColor: color(first.color), homeColor: color(second.color))
    }

    /// A team colour, or a light grey for colours that would vanish on the dark page (Nets black).
    public static func color(_ hex: String) -> Int? {
        guard hex.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil,
              let n = Int(hex.dropFirst(), radix: 16) else { return nil }
        let luma = Double((n >> 16) * 299 + ((n >> 8) & 255) * 587 + (n & 255) * 114) / 1000
        return luma < 40 ? 0xd9dedb : n
    }

    /// With a feed, the row follows the operator's settings: feed order (Live now
    /// order and favorite teams), its length and its leagues. Games the feed covers
    /// but left out are dropped; events it can't know about (boxing, cricket,
    /// college) keep their place after. Without a feed the guide order stays.
    public static func arrange(_ events: [LiveEvent], feed: LiveScoresFeed?) -> [LiveEvent] {
        guard let feed else {
            return events.map { var event = $0; event.score = nil; event.favoriteTeam = false; return event }
        }
        let games = Array(feed.games.enumerated().sorted {
            let left = $0.element.live ?? ($0.element.state == "in"), right = $1.element.live ?? ($1.element.state == "in")
            return left != right ? left : $0.offset < $1.offset
        }.prefix(max(0, feed.maxGames ?? feed.games.count)).map(\.element))
        var matched: [(at: Int, preferred: Bool, order: Int, event: LiveEvent)] = [], others: [LiveEvent] = []
        for (order, original) in events.enumerated() {
            var event = original
            if let at = gameIndex(for: event, in: games) {
                let game = games[at]
                event.favoriteTeam = game.favorite
                event.score = feed.spoilerFree ? nil : score(of: game)
                if event.matchup == nil, game.title.range(of: #"^[^<>]{3,80}$"#, options: .regularExpression) != nil {
                    event.title = game.title
                }
                // A guide listing without sport words ("Live event") takes the matched
                // game's sport and competition, as the web does (Porto–Feyenoord, Nov 24).
                if event.sport == .event, let sport = LiveSport(rawValue: game.sport), sport != .event {
                    event.sport = sport
                    if !game.competition.isEmpty { event.competition = game.competition }
                }
                matched.append((at: at, preferred: game.channels.contains { LiveRules.normalized($0) == LiveRules.normalized(event.channel.name) }, order: order, event: event))
            } else {
                event.score = nil; event.favoriteTeam = false
                if !feed.leagues.contains(league(for: event.leagueContext)) { others.append(event) }
            }
        }
        matched.sort { $0.at != $1.at ? $0.at < $1.at : $0.preferred != $1.preferred ? $0.preferred : $0.order < $1.order }
        var seen: Set<Int> = []
        return matched.filter { seen.insert($0.at).inserted }.map(\.event) + others
    }

    /// Follow the web: strict current guide candidates, companion membership,
    /// order/cap/favorites/scores, then unrelated guide events. Art is visual only.
    public static func events(in snapshot: LiveTVSnapshot, feed: LiveScoresFeed?, at now: Date = .now, artwork: LiveArtworkManifest? = nil) async -> [LiveEvent] {
        guard snapshot.isFresh(at: now) else { return [] }
        let candidates = LiveEvent.select(snapshot.channels, at: now, deduplicateSimulcasts: feed == nil)
        return arrange(candidates, feed: feed).map { original in
            var event = original
            event.artwork = artwork?.artwork(for: event)
            return event
        }
    }

    private static let leagues: [(String, String)] = [
        (#"\b(college|ncaa|youth|under \d+|u\d{2}|u \d{2}|cfl|canadian|cricket|wnba|nwsl)\b"#, "unsupported"),
        (#"\b(wsl|women(?: s|s)? super league)\b"#, "soccer/eng.w.1"),
        (#"\b(women|womens|female)\b"#, "unsupported"),
        (#"\b(nfl|super bowl)\b"#, "football/nfl"),
        (#"\bnba\b"#, "basketball/nba"),
        (#"\bmlb\b"#, "baseball/mlb"),
        (#"\bnhl\b"#, "hockey/nhl"),
        (#"\bconference league\b"#, "soccer/uefa.europa.conf"),
        (#"\beuropa league\b"#, "soccer/uefa.europa"),
        (#"\b(champions league|uefa champions)\b"#, "soccer/uefa.champions"),
        (#"\b(serie a|italian soccer)\b"#, "soccer/ita.1"),
        (#"\b(ligue 1|french soccer)\b"#, "soccer/fra.1"),
        (#"\bscottish\b"#, "unsupported"),
        (#"\b(premier league|epl)\b"#, "soccer/eng.1"),
        (#"\b(efl championship|english league championship|english championship)\b"#, "soccer/eng.2"),
    ]

    /// The ESPN league path a guide listing belongs to, as the web row reads it.
    public static func league(for text: String) -> String {
        let normalized = LiveRules.normalized(text)
        return leagues.first { normalized.range(of: $0.0, options: .regularExpression) != nil }?.1 ?? ""
    }

    static func text(_ value: Any?) -> String { (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    static func points(_ value: Any?) -> String? {
        if let text = value as? String { return text.trimmingCharacters(in: .whitespaces) }
        if let number = value as? Int { return String(number) }
        return nil
    }
    static func isPoints(_ text: String) -> Bool { text.range(of: #"^[0-9]{1,3}$"#, options: .regularExpression) != nil }
    static func cut(_ text: String, _ max: Int) -> String { text.count <= max ? text : String(text.prefix(max)) }
}

/// One Live now read per minute per account; a missing route (no companion,
/// module off) backs off for ten minutes.
public actor LiveScoresCache {
    public static let ttl: TimeInterval = 60
    public static let missingBackoff: TimeInterval = 600
    private let clock: @Sendable () -> Date
    private var owner: String?
    private var feed: LiveScoresFeed?
    private var fetched: Date?
    private var missingUntil: Date?

    public init(clock: @escaping @Sendable () -> Date = { Date() }) { self.clock = clock }

    private static func owner(of client: JellyfinClient) -> String {
        client.server.storageKey + "\n" + (client.session?.token ?? "")
    }

    /// The last feed read for this account, without a request.
    public func feed(for client: JellyfinClient) -> LiveScoresFeed? { owner == Self.owner(of: client) ? feed : nil }

    /// The current feed, refreshed when stale. Never throws.
    public func load(_ client: JellyfinClient) async -> LiveScoresFeed? {
        let key = Self.owner(of: client)
        if key != owner { owner = key; feed = nil; fetched = nil; missingUntil = nil }
        let now = clock()
        if let missingUntil, now < missingUntil { return nil }
        if let fetched, now.timeIntervalSince(fetched) < Self.ttl { return feed }
        fetched = now
        do {
            let read = try await client.liveScores()
            guard key == owner else { return nil }
            feed = read
        } catch let error as ClientError {
            guard key == owner else { return nil }
            if error == .forbidden || error == .unauthorized || error == .unavailable(404) {
                feed = nil; missingUntil = clock().addingTimeInterval(Self.missingBackoff)
            }
        } catch {}
        return key == owner ? feed : nil
    }
}

public extension JellyfinClient {
    /// The companion's Live now feed for the rest of today. Throws when the route
    /// is missing (404) or the module refuses (403).
    func liveScores() async throws -> LiveScoresFeed? {
        let data = try await requestData(["Zorofin", "Companion", "sportsEvents", "live"],
                                         query: [.init(name: "window", value: "today")],
                                         extensionToken: true, expectedStatus: 200)
        return try LiveScoresFeed.decode(data)
    }
}

/// The words and tint of a scored card, the same as the TV apps (`live_scores.dart`).
public extension LiveEvent {
    /// "NBA · Q4 4:12", "NBA · Final"; nil without a score.
    var scoreStatus: String? {
        guard let score else { return nil }
        let state = score.isFinal ? (score.detail.isEmpty ? "Final" : score.detail)
            : (score.detail.isEmpty ? "Live" : score.detail)
        let league = competition.trimmingCharacters(in: .whitespaces)
        return league.isEmpty ? state : league + " · " + state
    }
    /// "Your teams · ESPN · Ch 206" or "ESPN · Ch 206".
    var channelLine: String {
        let name = channel.name + (channel.channelNumber.map { " · Ch " + $0 } ?? "")
        return favoriteTeam ? "Your teams · " + name : name
    }
}

public extension LiveScore {
    /// A team colour darkened like the site's tints so white text stays
    /// clear, or the site's navy. 0xRRGGBB.
    var tint: Int {
        guard let c = homeColor ?? awayColor else { return 0x1e3a5f }
        func dark(_ shift: Int) -> Int { Int((Double((c >> shift) & 0xff) * 0.45).rounded()) << shift }
        return dark(16) | dark(8) | dark(0)
    }
}
