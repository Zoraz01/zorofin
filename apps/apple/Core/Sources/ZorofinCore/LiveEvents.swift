import Foundation

/// Guide facts, not playback sources or a channel-to-scoreboard guess.
public struct LiveProgram: Codable, Hashable, Sendable {
    public var id: String?
    public var channelId: String?
    public var name: String
    public var overview: String?
    public var episodeTitle: String?
    public var startDate: String?
    public var endDate: String?
    public var isLive: Bool?
    public var isSports: Bool?
    public var isRepeat: Bool?
    public var genres: [String]?
    public var imageTags: [String: String]?
    public var backdropImageTags: [String]?
    public init(name: String, startDate: String?, endDate: String?, isLive: Bool? = nil) {
        self.name = name; self.startDate = startDate; self.endDate = endDate; self.isLive = isLive
    }
}

public enum LiveSport: String, Codable, Sendable, CaseIterable {
    case football, basketball, soccer, baseball, hockey, cricket, tennis, golf, racing, combat, event
    public var title: String {
        switch self {
        case .football: "Football"; case .basketball: "Basketball"; case .soccer: "Soccer"
        case .baseball: "Baseball"; case .hockey: "Hockey"; case .cricket: "Cricket"
        case .tennis: "Tennis"; case .golf: "Golf"; case .racing: "Motorsport"
        case .combat: "Fight night"; case .event: "Live event"
        }
    }
    public var symbol: String {
        switch self {
        case .football: "american.football.fill"; case .basketball: "basketball.fill"
        case .soccer: "soccerball"; case .baseball: "baseball.fill"; case .hockey: "hockey.puck.fill"
        case .cricket: "cricket.ball.fill"; case .tennis: "tennisball.fill"; case .golf: "figure.golf"
        case .racing: "flag.checkered"; case .combat: "figure.boxing"; case .event: "dot.radiowaves.left.and.right"
        }
    }
}

enum LiveRules {
    static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern, options: .caseInsensitive) }
    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    static let nonWord = regex("[^a-z0-9]+")
    static func normalized(_ text: String) -> String {
        let folded = text.lowercased().replacingOccurrences(of: "ø", with: "o").replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "ł", with: "l")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return nonWord.stringByReplacingMatches(in: folded, range: NSRange(folded.startIndex..., in: folded), withTemplate: " ")
            .trimmingCharacters(in: .whitespaces)
    }
    static let versus = regex(#"\s+(?:vs\.?|v\.?|versus|at)\s+"#)
    static let notTeam = regex(#"\b(?:[0-9]{1,2}(?::[0-9]{2})?\s*(?:am|pm)|afc (?:east|west|north|south)|nfc (?:east|west|north|south)|\d*news)\b|^\d+(?::\d+)?(?:\s*(?:am|pm))?$"#)
    static func teams(_ text: String) -> [String]? {
        let separators = versus.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard separators.count == 1, let range = Range(separators[0].range, in: text) else { return nil }
        let pair = [String(text[..<range.lowerBound]), String(text[range.upperBound...])]
        return pair.allSatisfy { normalized($0).count > 2 && !matches(notTeam, $0) } ? pair : nil
    }
    static let livePrefix = regex(#"^live\s*:\s*"#)
    static let placeholder = regex(#"^(?:[a-z]{2,6}\||threadfin:)"#)
    static let studio = regex(#"\b(sportscenter|sports centre|first take|the herd|jim rome|foxworth|schrager|finebaum|tiki|tierney|sec now|b1g live|mlb (?:now|tonight)|nba today|nfl live|acc pm|matchday live|premier league live|countdown|overreaction|pregame|pre-game|postgame|post-game|highlights?|replays?|rewind|classics?|review|yankeeography|in 60|encore|paid programming|goal zone|mlb central|leadoff|closer|learning center|preview|news|talk show|documentary)\b"#)
    static let discussion = regex(#"\b(?:discussion and analysis|debate show|news and (?:information|updates)|sports (?:news|stories|topics)|rotating panelists|preview show|studio analysis|highlights of|replay of|rebroadcast|delayed coverage)\b"#)
    static let otherEvent = regex(#"\b(olympics?|opening ceremony|closing ceremony|awards|concert|festival|marathon|rugby|volleyball|swimming|cycling|athletics|track and field)\b"#)
    static let cfl = regex(#"\b(cfl|canadian football league)\b"#)
    static let sports: [(LiveSport, NSRegularExpression)] = [
        (.soccer, regex(#"\b(soccer|premier league|efl championship|english league championship|english championship|uefa|champions league|europa league|conference league|la liga|bundesliga|serie a|mls|nwsl|fifa|concacaf|copa|ligue 1)\b"#)),
        (.football, regex(#"\b(football|nfl|cfl|super bowl)\b"#)),
        (.basketball, regex(#"\b(basketball|nba|wnba|fiba|euroleague)\b"#)),
        (.baseball, regex(#"\b(baseball|mlb|world series)\b"#)), (.hockey, regex(#"\b(hockey|nhl)\b"#)),
        (.cricket, regex(#"\b(cricket|ipl)\b"#)), (.tennis, regex(#"\b(tennis|atp|wta|wimbledon|roland garros)\b"#)),
        (.golf, regex(#"\b(golf|pga|lpga|ryder cup)\b"#)), (.racing, regex(#"\b(formula (?:1|one)|f1|nascar|indycar|grand prix|motogp)\b"#)),
        (.combat, regex(#"\b(ufc|boxing|mma|wwe|wrestling)\b"#))
    ]
    static func containsBoth(_ teams: [String], evidence: String) -> Bool {
        var remaining = " " + normalized(evidence) + " "
        for team in teams.sorted(by: { $0.count > $1.count }) {
            guard let range = remaining.range(of: " " + normalized(team) + " ") else { return false }
            remaining.replaceSubrange(range, with: " ")
        }
        return true
    }
    static func cleanTitle(_ program: LiveProgram) -> String {
        let title = program.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = livePrefix.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
        var parts = clean.components(separatedBy: " — ")
        if parts.count > 1, let last = parts.last {
            if let pair = teams(last), containsBoth(pair, evidence: (program.overview ?? "") + " " + (program.episodeTitle ?? "")) { }
            else { parts.removeLast() }
        }
        return parts.joined(separator: " — ")
    }
}

public struct LiveEvent: Identifiable, Sendable {
    public var id: String { channel.id }
    public let channel: MediaItem
    public var title: String
    public var competition: String
    public var sport: LiveSport
    public let start: Date
    public let end: Date
    let priority: Double
    let matchup: [String]?
    let context: String
    let leagueContext: String
    let evidence: String
    public var artwork: LiveEventArtwork?
    /// From the companion's Live now feed (LiveScores.swift): a score when the
    /// server shows scores, and whether either team is a server favorite.
    public var score: LiveScore?
    public var favoriteTeam = false
    /// Only images attached to this programme's identity are eligible. Jellyfin
    /// may inherit a channel logo into CurrentProgram; shared tags are not a
    /// thumbnail of the event and must not displace verified fixture artwork.
    public var artworkSources: [LiveEventArtworkSource] {
        var sources: [LiveEventArtworkSource] = []
        if let program = channel.currentProgram, let id = program.id,
           !id.isEmpty, id != channel.id {
            let channelTags = Set(Array((channel.imageTags ?? [:]).values)
                + (channel.backdropImageTags ?? []) + (channel.parentBackdropImageTags ?? []))
            let candidates = [("Thumb", program.imageTags?["Thumb"]),
                ("Backdrop", program.backdropImageTags?.first), ("Primary", program.imageTags?["Primary"])]
            for (kind, tag) in candidates {
                if let tag, !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !channelTags.contains(tag) {
                    sources.append(.program(.init(itemID: id, kind: kind, tag: tag)))
                }
            }
        }
        if let image = artwork?.image { sources.append(.catalogue(image)) }
        if let logos = artwork?.logos, logos.count == 2 { sources.append(.crests(logos)) }
        return sources
    }
    public func isCurrent(at now: Date) -> Bool { start <= now && now < end }
    public func progress(at now: Date) -> Double { min(1, max(0, now.timeIntervalSince(start) / end.timeIntervalSince(start))) }

    public static func select(_ channels: [MediaItem], at now: Date, deduplicateSimulcasts: Bool = true) -> [Self] {
        let events = channels.compactMap { channel -> Self? in
            guard !channel.id.isEmpty, let p = channel.currentProgram, !p.name.isEmpty,
                  let start = HomeRowCard.date(p.startDate), let end = HomeRowCard.date(p.endDate),
                  start <= now, now < end, end.timeIntervalSince(start) <= 43_200,
                  p.isRepeat != true, p.isLive != false,
                  p.isLive == true || LiveRules.matches(LiveRules.livePrefix, p.name) else { return nil }
            let name = LiveRules.cleanTitle(p), parts = name.components(separatedBy: " — "), base = parts[0]
            let overview = p.overview ?? ""
            guard !LiveRules.matches(LiveRules.placeholder, base), !overview.lowercased().hasPrefix("threadfin:"),
                  LiveRules.normalized(base) != LiveRules.normalized(channel.name),
                  !LiveRules.matches(LiveRules.studio, base), !LiveRules.matches(LiveRules.discussion, overview) else { return nil }
            let context = base + " " + (p.genres ?? []).joined(separator: " ")
            let featured = (p.genres ?? []).contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "featured live event" }
            let sport = LiveRules.sports.first { LiveRules.matches($0.1, context) }?.0 ?? .event
            guard featured || sport != .event || LiveRules.teams(base) != nil || LiveRules.matches(LiveRules.otherEvent, base) else { return nil }
            let matchup = LiveRules.teams(parts.count > 1 ? parts.last! : base)
            let priority = featured ? -100.0 : sport == .football && LiveRules.matches(LiveRules.cfl, base) ? 2.5 : Double(LiveSport.allCases.firstIndex(of: sport)!)
            return Self(channel: channel, title: matchup?.joined(separator: " vs ") ?? name,
                competition: matchup != nil && parts.count > 1 ? base : sport.title, sport: sport,
                start: start, end: end, priority: priority, matchup: matchup, context: base, leagueContext: context,
                evidence: overview + " " + (p.episodeTitle ?? ""))
        }.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if ($0.channel.userData?.isFavorite == true) != ($1.channel.userData?.isFavorite == true) { return $0.channel.userData?.isFavorite == true }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.channel.name.localizedStandardCompare($1.channel.name) == .orderedAscending
        }
        var seen: Set<String> = [], channelIDs: Set<String> = []
        return events.filter { event in
            guard channelIDs.insert(event.id).inserted else { return false }
            guard deduplicateSimulcasts, event.matchup != nil else { return true }
            return seen.insert("\(event.sport)-\(LiveRules.normalized(event.title))-\(event.start.timeIntervalSince1970)-\(event.end.timeIntervalSince1970)").inserted
        }
    }
}

/// Ordered image candidates; the bundled illustration is the final, local UI fallback.
public enum LiveEventArtworkSource: Hashable, Sendable {
    case catalogue(String)
    case program(LiveProgramImage)
    case crests([String])
}

public struct LiveProgramImage: Hashable, Sendable {
    public let itemID: String
    public let kind: String
    public let tag: String
}

public struct LiveEventArtwork: Sendable {
    public let image: String?
    public let logos: [String]
    public let teams: [String]
    public let sport: LiveSport
    /// A guide image counts as a picture of the event only when it is roughly
    /// 16:9; logos and portraits fall through to crests or the illustration.
    public static func isWidePicture(width: Double, height: Double) -> Bool {
        guard width > 0, height > 0 else { return false }
        return (1.6...1.95).contains(width / height)
    }
    public static func isSafePath(_ path: String) -> Bool {
        path.range(of: #"^/live-tv-logos/art/[a-z0-9][a-z0-9-]*\.(png|jpe?g|webp)$"#, options: .regularExpression) == path.startIndex..<path.endIndex
    }
}

public struct LiveArtworkManifest: Codable, Sendable {
    public let version: Int
    public let events: [Fixture]
    public struct Fixture: Codable, Sendable {
        public let sport: LiveSport
        public let league: String
        public let start: String
        public let home: Team
        public let away: Team
        public let image: String?
        public let logos: [String]?
    }
    public struct Team: Codable, Sendable { public let id: String; public let name: String; public let aliases: [String] }
    private static let unsupported = LiveRules.regex(#"\b(women|womens|female|college|ncaa|youth|under \d+|u\d{2}|u \d{2}|cfl|canadian|cricket|wnba|nwsl)\b"#)
    private static let leagues: [(String, NSRegularExpression)] = [
        ("football/nfl", LiveRules.regex(#"\b(nfl|super bowl)\b"#)), ("basketball/nba", LiveRules.regex(#"\bnba\b"#)),
        ("baseball/mlb", LiveRules.regex(#"\bmlb\b"#)), ("hockey/nhl", LiveRules.regex(#"\bnhl\b"#)),
        ("soccer/uefa.europa.conf", LiveRules.regex(#"\bconference league\b"#)), ("soccer/uefa.europa", LiveRules.regex(#"\beuropa league\b"#)),
        ("soccer/uefa.champions", LiveRules.regex(#"\b(champions league|uefa champions)\b"#)), ("soccer/eng.1", LiveRules.regex(#"\b(premier league|epl)\b"#)),
        ("soccer/eng.2", LiveRules.regex(#"\b(efl championship|english league championship|english championship)\b"#))
    ]
    public func artwork(for event: LiveEvent) -> LiveEventArtwork? {
        let context = LiveRules.normalized(event.leagueContext)
        guard version == 2, !LiveRules.matches(Self.unsupported, context) else { return nil }
        let league = Self.leagues.first { LiveRules.matches($0.1, context) }?.0
        func aliases(_ team: Team) -> [String] { team.aliases.map(LiveRules.normalized).filter { $0.count >= 3 } }
        func matches(_ name: String, _ team: Team) -> Bool {
            let normalized = LiveRules.normalized(name).replacingOccurrences(of: #"^the "#, with: "", options: .regularExpression)
            return aliases(team).contains(normalized)
        }
        let candidates = events.filter { fixture in
            guard fixture.home.id != fixture.away.id, league == nil || league == fixture.league,
                  fixture.sport == event.sport || (event.sport == .event && event.matchup != nil),
                  let start = HomeRowCard.date(fixture.start), abs(start.timeIntervalSince(event.start)) <= 10_800 else { return false }
            if let pair = event.matchup {
                return (matches(pair[0], fixture.away) && matches(pair[1], fixture.home)) || (matches(pair[0], fixture.home) && matches(pair[1], fixture.away))
            }
            return aliases(fixture.away).contains { first in aliases(fixture.home).contains { LiveRules.containsBoth([first, $0], evidence: event.evidence) } }
        }
        guard candidates.count == 1, let fixture = candidates.first else { return nil }
        let image = fixture.image.flatMap { LiveEventArtwork.isSafePath($0) ? $0 : nil }
        var logos = fixture.logos ?? []
        if logos.count != 2 || !logos.allSatisfy(LiveEventArtwork.isSafePath) { logos = [] }
        var teams = [fixture.away.name, fixture.home.name]
        if let pair = event.matchup, matches(pair[0], fixture.home), matches(pair[1], fixture.away) { logos.reverse(); teams.reverse() }
        guard image != nil || !logos.isEmpty else { return nil }
        return LiveEventArtwork(image: image, logos: logos, teams: teams, sport: fixture.sport)
    }
}

public struct LiveTVSnapshot: Codable, Sendable {
    public let channels: [MediaItem]
    public let fetchedAt: Date
    public init(channels: [MediaItem], fetchedAt: Date = .now) { self.channels = channels; self.fetchedAt = fetchedAt }
    public func isFresh(at now: Date) -> Bool { (0..<120).contains(now.timeIntervalSince(fetchedAt)) }
    /// Nonisolated async work stays off SwiftUI's main actor, including guide-date
    /// parsing, ranking and fixture matching. Timeline ticks only filter expiry.
    public func featuredEvents(at now: Date = .now, artwork: LiveArtworkManifest? = nil) async -> [LiveEvent] {
        events(at: now, artwork: artwork)
    }
    public func events(at now: Date, artwork: LiveArtworkManifest? = nil) -> [LiveEvent] {
        guard isFresh(at: now) else { return [] }
        return LiveEvent.select(channels, at: now).map { original in
            var event = original
            event.artwork = artwork?.artwork(for: event)
            if let art = event.artwork {
                if event.sport == .event { event.sport = art.sport; event.competition = art.sport.title }
                if event.matchup == nil { event.title = art.teams.joined(separator: " vs "); event.competition = original.context.trimmingCharacters(in: .whitespaces) }
            }
            return event
        }
    }
}

extension JellyfinClient {
    private var liveCacheKey: String { server.storageKey + "#native-live-events-v1" }
    public func cachedLiveTVSnapshot() async -> LiveTVSnapshot? {
        guard let data = await responseCache?.snapshot(liveCacheKey, policy: .liveEvents) else { return nil }
        return try? JSONDecoder().decode(LiveTVSnapshot.self, from: data)
    }
    public func liveTVSnapshot() async throws -> LiveTVSnapshot {
        let fetch: @Sendable () async throws -> Data = {
            guard let session, session.server == server else { throw ClientError.missingSession }
            var cursor = LibraryPageCursor(), channels: [MediaItem] = []
            // Bounded guide scan; All channels remains independently pageable.
            for _ in 0..<20 {
                try Task.checkCancellation()
                let page = try await request(ItemPage.self, path: ["LiveTv", "Channels"], query: [
                    .init(name: "userId", value: session.viewer.id), .init(name: "addCurrentProgram", value: "true"),
                    .init(name: "fields", value: "Overview,Genres,Tags"), .init(name: "enableUserData", value: "true"),
                    .init(name: "enableImages", value: "true"), .init(name: "imageTypeLimit", value: "1"),
                    .init(name: "enableImageTypes", value: "Primary,Thumb,Backdrop"),
                    .init(name: "limit", value: "200"), .init(name: "startIndex", value: String(cursor.offset))])
                channels += page.items.prefix(max(0, 4_000 - channels.count))
                cursor.accept(page, limit: 200)
                if !cursor.hasMore || channels.count >= 4_000 { break }
            }
            return try JSONEncoder().encode(LiveTVSnapshot(channels: channels))
        }
        let data: Data
        if let responseCache { data = try await responseCache.value(liveCacheKey, policy: .liveEvents, fetch: fetch) }
        else { data = try await fetch() }
        return try JSONDecoder().decode(LiveTVSnapshot.self, from: data)
    }
    public func liveArtworkManifest() async throws -> LiveArtworkManifest {
        // The caller enables this optional catalogue only when the server advertises it.
        guard let session else { throw ClientError.missingSession }
        guard session.server == server else { throw ClientError.unsafeURL }
        let key = server.storageKey + "#native-live-artwork-v2"
        let fetch: @Sendable () async throws -> Data = {
            let data = try await liveResourceData("events.json")
            let manifest = try JSONDecoder().decode(LiveArtworkManifest.self, from: data)
            guard manifest.version == 2 else { throw ClientError.invalidResponse }
            return data
        }
        let data: Data
        if let responseCache { data = try await responseCache.value(key, policy: .liveArtworkIndex, fetch: fetch) }
        else { data = try await fetch() }
        return try JSONDecoder().decode(LiveArtworkManifest.self, from: data)
    }
    public func liveArtworkImage(path: String) async throws -> Data {
        guard let session else { throw ClientError.missingSession }
        guard session.server == server, LiveEventArtwork.isSafePath(path) else { throw ClientError.unsafeURL }
        let fetch: @Sendable () async throws -> Data = {
            try await liveResourceData(String(path.split(separator: "/").last!))
        }
        if let responseCache { return try await responseCache.value(server.storageKey + path, policy: .artwork, fetch: fetch) }
        return try await fetch()
    }
}


/// Programme browsing metadata is separate from proof that a fixture is live.
public struct LiveProgramArtSource: Hashable, Sendable {
    public let itemID: String
    public let kind: String
    public let tag: String
    public let isProgram: Bool
}
public enum LiveProgramListing {
    public static func isCurrent(_ channel: MediaItem, at now: Date) -> Bool {
        guard let p = channel.currentProgram, let start = HomeRowCard.date(p.startDate),
              let end = HomeRowCard.date(p.endDate) else { return false }
        return start <= now && now < end && end > start
    }
    public static func isLive(_ channel: MediaItem, at now: Date) -> Bool {
        guard isCurrent(channel, at: now), let p = channel.currentProgram,
              p.isLive == true, p.isRepeat != true,
              let start = HomeRowCard.date(p.startDate), let end = HomeRowCard.date(p.endDate),
              end.timeIntervalSince(start) <= 43200,
              LiveRules.normalized(p.name) != LiveRules.normalized(channel.name),
              !LiveRules.matches(LiveRules.placeholder, p.name) else { return false }
        return true
    }
    /// A category, not a claim of a live game. Sports networks remain browseable.
    public static func isSports(_ channel: MediaItem) -> Bool {
        let genres = (channel.currentProgram?.genres ?? []) + (channel.genres ?? [])
        return channel.currentProgram?.isSports == true || genres.contains { ["sport", "sports"].contains($0.lowercased()) }
            || channel.name.range(of: #"\b(sports?|espn|nba|nfl|nhl|mlb|bein|eurosport)\b"#, options: .caseInsensitive) != nil
    }
    /// Thumb → Backdrop → Primary for the current programme, then channel art.
    /// Tags inherited from a channel are not programme artwork.
    public static func artwork(_ channel: MediaItem) -> [LiveProgramArtSource] {
        let channelTags = Set(Array((channel.imageTags ?? [:]).values) + (channel.backdropImageTags ?? []) + (channel.parentBackdropImageTags ?? []))
        var result: [LiveProgramArtSource] = []
        if let p = channel.currentProgram, let id = p.id, !id.isEmpty, id != channel.id {
            for (kind, tag) in [("Thumb", p.imageTags?["Thumb"]), ("Backdrop", p.backdropImageTags?.first ?? p.imageTags?["Backdrop"]), ("Primary", p.imageTags?["Primary"])] {
                if let tag, !tag.isEmpty, !channelTags.contains(tag) { result.append(.init(itemID: id, kind: kind, tag: tag, isProgram: true)) }
            }
        }
        for (kind, tag) in [("Backdrop", channel.backdropImageTags?.first), ("Primary", channel.imageTags?["Primary"])] {
            if let tag, !tag.isEmpty { result.append(.init(itemID: channel.id, kind: kind, tag: tag, isProgram: false)) }
        }
        return result
    }
}
