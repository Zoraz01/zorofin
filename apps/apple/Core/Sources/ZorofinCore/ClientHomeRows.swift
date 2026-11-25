import Foundation

/// Home rows computed on the device from ordinary, viewer-scoped Jellyfin reads.
/// They work on any Jellyfin server; no Zorofin service or third-party plugin is
/// involved. Rules follow `support-agent/home-rows.js` and `curated-seasons.js`.
/// Legacy v1 merges the optional requests/popularity feed. Supported plugin v2
/// owns the app rows instead; this computation remains the ordinary-server and
/// error fallback. See docs/CLIENT_HOME_ROWS.md.
public enum ClientHomeRows {
    public static let ids: Set<String> = ["new-episodes", "short-movies", "showcase", "curated", "sports"]
    static let shortMovieMinutes = 90
    static let recentDays = 14.0
    static let sportsWindow: TimeInterval = 12 * 3_600
    static let cardLimit = 20

    /// Pinned-row order matches the server contract so shuffling stays identical.
    /// A client row wins unless it failed and the server still provided one.
    public static func feed(client rows: [HomeRow], server: HomeFeed?, teams: [String], at now: Date = .now) -> HomeFeed {
        let own = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remote = Dictionary((server?.rows ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let merged: [HomeRow] = HomePreferences.rowOptions.compactMap { option in
            if let row = own[option.id] {
                if row.state == "unavailable", let fallback = remote[option.id], fallback.state != "unavailable" { return fallback }
                return row
            }
            return ids.contains(option.id) ? nil : remote[option.id]
        }
        var preferences = server?.preferences.automatic ?? HomePreferences()
        preferences.teams = teams
        return HomeFeed(generatedAt: ISO8601DateFormatter().string(from: now), preferences: preferences, rows: merged)
    }

    // MARK: Row rules

    struct Facts: Decodable, Sendable {
        var id: String
        var dateCreated: String?
        var tags: [String]?
        var locationType: String?
        var isPlaceHolder: Bool?
    }
    struct Entry: Sendable {
        var item: MediaItem
        var facts: Facts
        var created: Date? { ClientHomeRows.date(facts.dateCreated) }
        var playable: Bool { facts.locationType != "Virtual" && facts.isPlaceHolder != true }
        var played: Bool { item.userData?.played == true }
    }

    /// Source formats verified from video metadata, never inferred from a title or codec.
    static func formats(_ item: MediaItem) -> [String] {
        let sources = item.mediaSources?.compactMap(\.mediaStreams) ?? []
        let streams = sources.isEmpty ? (item.mediaStreams ?? []) : sources.flatMap { $0 }
        var badges: [String] = []
        func add(_ badge: String) { if !badges.contains(badge) { badges.append(badge) } }
        for stream in streams where stream.type == "Video" && stream.isAttachedPic != true {
            if (stream.width ?? 0) >= 3_840 { add("4K") }
            let range = stream.videoRangeType?.uppercased() ?? ""
            if range.hasPrefix("DOVI") && range != "DOVIINVALID" { add("Dolby Vision") }
            else if range == "HDR10PLUS" { add("HDR10+") }
            else if range == "HDR10" { add("HDR10") }
            else if range == "HLG" { add("HLG") }
            else if stream.videoRange?.uppercased() == "HDR" { add("HDR") }
        }
        return badges
    }

    static func shortMovies(_ movies: [Entry], minutes: Int = shortMovieMinutes) -> [HomeRowCard] {
        let limit = Int64(minutes) * 600_000_000
        return movies.filter { $0.playable && !$0.played && ($0.item.runTimeTicks ?? 0) > 0 && ($0.item.runTimeTicks ?? 0) <= limit }
            .prefix(cardLimit).map { entry in
                let length = Int(((entry.item.runTimeTicks ?? 0) + 599_999_999) / 600_000_000)
                return HomeRowCard(id: entry.item.id, item: entry.item, subtitle: "\(length) min")
            }
    }

    static func showcase(_ movies: [Entry]) -> [HomeRowCard] {
        movies.filter(\.playable).compactMap { entry -> HomeRowCard? in
            let badges = formats(entry.item)
            return badges.isEmpty ? nil : HomeRowCard(id: entry.item.id, item: entry.item, subtitle: "Source format", badges: badges)
        }.prefix(cardLimit).map { $0 }
    }

    static func newEpisodes(_ episodes: [Entry], favorites: Set<String>, at now: Date) -> [HomeRowCard] {
        let since = now.addingTimeInterval(-recentDays * 86_400)
        var seen: Set<String> = []
        return episodes.compactMap { entry -> (Entry, Date)? in
            guard entry.playable, !entry.played, let series = entry.item.seriesId, favorites.contains(series),
                  let created = entry.created, created >= since, created <= now, seen.insert(entry.item.id).inserted else { return nil }
            return (entry, created)
        }.sorted { $0.1 > $1.1 }.prefix(cardLimit)
            .map { HomeRowCard(id: $0.0.item.id, item: $0.0.item, subtitle: "New in your library", badges: ["New episode"]) }
    }

    struct GuideProgram: Decodable, Sendable {
        var id: String?
        var channelId: String?
        var name: String
        var overview: String?
        var startDate: String?
        var endDate: String?
        var isSports: Bool?
        var genres: [String]?
    }
    private static let notLive = try! NSRegularExpression(
        pattern: #"\b(highlights?|replay|classic|preview|studio|sportscenter|news|talk)\b"#, options: [.caseInsensitive])
    private static let separators = try! NSRegularExpression(pattern: #"[^\p{L}\p{N}]+"#)

    static func normalized(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        let range = NSRange(folded.startIndex..., in: folded)
        return separators.stringByReplacingMatches(in: folded, range: range, withTemplate: " ")
            .trimmingCharacters(in: .whitespaces)
    }
    /// Full team names only; "NY" can never match "Sunny".
    static func teamMatches(_ text: String, teams: [String]) -> Bool {
        let haystack = " " + normalized(text) + " "
        return teams.contains { team in
            let needle = normalized(team)
            return !needle.isEmpty && haystack.contains(" " + needle + " ")
        }
    }

    static func sports(_ programs: [GuideProgram], channels: [MediaItem], teams: [String], at now: Date) -> [HomeRowCard] {
        let byID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        return programs.compactMap { program -> (HomeRowCard, Date)? in
            guard program.isSports == true || (program.genres ?? []).contains(where: { ["sport", "sports"].contains($0.lowercased()) }),
                  notLive.firstMatch(in: program.name, range: NSRange(program.name.startIndex..., in: program.name)) == nil,
                  let start = date(program.startDate), let end = date(program.endDate),
                  end > now, start <= now.addingTimeInterval(sportsWindow), start > now.addingTimeInterval(-sportsWindow),
                  let channelID = program.channelId, let channel = byID[channelID],
                  let id = program.id, !id.isEmpty, seen.insert(id).inserted,
                  teams.isEmpty || teamMatches(program.name + " " + (program.overview ?? ""), teams: teams) else { return nil }
            return (HomeRowCard(id: id, item: channel, subtitle: program.name, badges: [start <= now ? "On now" : "Starting soon"],
                startsAt: program.startDate, endsAt: program.endDate), start)
        }.sorted { $0.1 < $1.1 }.prefix(cardLimit).map(\.0)
    }

    /// Jellyfin sends up to seven fractional digits, which ISO8601DateFormatter rejects.
    static func date(_ text: String?) -> Date? {
        guard var text, !text.isEmpty else { return nil }
        if let dot = text.firstIndex(of: "."), dot > (text.firstIndex(of: "T") ?? text.startIndex) {
            let end = text[dot...].dropFirst().firstIndex { !$0.isNumber } ?? text.endIndex
            text.removeSubrange(dot..<end)
        }
        if !text.hasSuffix("Z") && text.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) == nil { text += "Z" }
        return ISO8601DateFormatter().date(from: text)
    }
}

// MARK: Seasonal and curated programming

public enum SeasonalThemes {
    struct Theme: Sendable {
        let title: String
        let collections: NSRegularExpression
        let match: NSRegularExpression?
        let genres: [String]?
        init(_ title: String, _ collections: String, match: String? = nil, genres: [String]? = nil) {
            self.title = title
            self.collections = try! NSRegularExpression(pattern: collections, options: [.caseInsensitive])
            self.match = match.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
            self.genres = genres
        }
    }
    // Collection names/tags are editorial evidence. Broad genre fallbacks are only
    // used for moods where the genre itself describes the shelf, never identities.
    static let themes: [String: Theme] = [
        "new-year": Theme("New year, fresh starts", "new.year|fresh.starts|new.beginnings", match: "new.year|fresh.start|new.beginning"),
        "valentines": Theme("Valentine’s picks", "valentine|date.night|romantic.comed", genres: ["Romance"]),
        "black-history": Theme("Black History Month", "black.history|black.cinema|black.filmmakers"),
        "spring-break": Theme("Spring break", "spring.break", match: "spring.break|road.trip|vacation", genres: ["Comedy", "Adventure", "Family"]),
        "st-patricks": Theme("St. Patrick’s Day", #"st\.?\s*patrick|irish.cinema|irish.stories"#),
        "earth-day": Theme("Earth Day: wild worlds", "earth.day|planet.earth|wildlife|nature.documentar",
            match: "wildlife|natural.world|rainforest|ocean|conservation", genres: ["Documentary"]),
        "mothers-day": Theme("Mother’s Day", "mother[’']?s.day|mothers.day"),
        "memorial-day": Theme("Memorial Day weekend", "memorial.day"),
        "graduation": Theme("Graduation & new beginnings", "graduation|coming.of.age|new.beginnings",
            match: "graduat(?:e|es|ion|ing)|coming.of.age", genres: ["Comedy", "Drama", "Family"]),
        "pride": Theme("Pride stories", #"\bpride\b|lgbtq?\+?.cinema|queer.cinema"#),
        "juneteenth": Theme("Juneteenth", "juneteenth"),
        "fathers-day": Theme("Father’s Day", "father[’']?s.day|fathers.day"),
        "fourth-july": Theme("Fourth of July", #"(?:fourth|4th).of.july|july.(?:fourth|4th|4)\b|independence.day|stars.and.stripes"#,
            match: #"(?:fourth|4th).of.july|july.(?:fourth|4th|4)\b|independence.day"#),
        "back-to-school": Theme("Back to school", "back.to.school|school.days|campus.classics",
            match: "high.school|boarding.school|college|campus|classroom|school.year", genres: ["Comedy", "Drama", "Family", "Animation"]),
        "labor-day": Theme("Long-weekend movies", "labor.day|long.weekend", genres: ["Adventure", "Comedy"]),
        "halloween": Theme("Spooky season", "halloween|horror|spooky", genres: ["Horror"]),
        "thanksgiving": Theme("Thanksgiving weekend", "thanksgiving|friendsgiving", match: "thanksgiving|friendsgiving"),
        "christmas": Theme("Christmas favorites", #"christmas|\bxmas\b"#, match: #"christmas|\bxmas\b"#),
        "winter": Theme("Winter nights", "winter|snow.day|snowy", match: "winter|snowbound|snowstorm|snowy|ski.resort"),
        "spring": Theme("Springtime stories", "springtime|spring.favorites|spring.picks", match: "springtime|spring.festival|spring.garden"),
        "summer": Theme("Summer movie nights", "summer|beach|surfing|vacation", match: "summer|beach|surfing|vacation|road.trip"),
        "autumn": Theme("Autumn evenings", "autumn|fall.favorites|fall.picks|cozy.season", match: "autumn|fall.foliage|harvest.festival"),
        "comfort": Theme("Comfort watches", "comfort|ghibli|feel.good", genres: ["Family", "Comedy"]),
        "movie-night": Theme("Movie night", "movie.night|heist|mind.bend|sci.fi|essentials", genres: ["Adventure", "Mystery", "Science Fiction"]),
        "rainy-day": Theme("Rainy-day mysteries", "rainy.day|whodunit|mystery.night", genres: ["Mystery"]),
        "weekend-adventures": Theme("Weekend adventures", "weekend.adventure|adventure.favorites", genres: ["Adventure"])
    ]

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    /// Days since 1970-01-01 for a civil date; month is 1-based and may overflow.
    static func dayNumber(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let date = utc.date(from: DateComponents(year: year, month: month, day: day))!
        return Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }
    /// The viewer's local calendar date, as a UTC day number.
    static func today(_ now: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return dayNumber(parts.year!, parts.month!, parts.day!)
    }
    private static func weekday(_ day: Int) -> Int { ((day + 4) % 7 + 7) % 7 } // 1970-01-01 was a Thursday; 0 = Sunday.
    static func nthWeekday(_ year: Int, _ month: Int, _ weekday: Int, _ occurrence: Int) -> Int {
        let first = dayNumber(year, month, 1)
        return first + (weekday - Self.weekday(first) + 7) % 7 + (occurrence - 1) * 7
    }

    /// Ordered candidate themes for today: closest holidays, editorial windows,
    /// the season, then weekly-rotating evergreen moods.
    public static func plan(at now: Date, timeZone: TimeZone = .current) -> [String] {
        let today = today(now, timeZone: timeZone)
        let year = utc.component(.year, from: Date(timeIntervalSince1970: Double(today) * 86_400))
        let month = utc.component(.month, from: Date(timeIntervalSince1970: Double(today) * 86_400))
        var candidates: [(key: String, priority: Double)] = []
        func window(_ key: String, _ startMonth: Int, _ startDay: Int, _ endMonth: Int, _ endDay: Int, _ priority: Double = 30) {
            if today >= dayNumber(year, startMonth, startDay) && today <= dayNumber(year, endMonth, endDay) { candidates.append((key, priority)) }
        }
        func holiday(_ key: String, _ day: Int, before: Int = 7, after: Int = 1) {
            let distance = day - today
            if distance <= before && distance >= -after { candidates.append((key, 100 - Double(abs(distance)) + (distance >= 0 ? 0.5 : 0))) }
        }
        // Actual holiday dates, not shifted workplace observances. Seasonal windows
        // are editorial US/northern-hemisphere defaults, not local school schedules.
        window("new-year", 1, 1, 1, 7, 80); window("new-year", 12, 27, 12, 31, 80)
        holiday("valentines", dayNumber(year, 2, 14))
        window("black-history", 2, 1, 3, 0)
        window("spring-break", 3, 8, 4, 12)
        holiday("st-patricks", dayNumber(year, 3, 17))
        holiday("earth-day", dayNumber(year, 4, 22))
        holiday("mothers-day", nthWeekday(year, 5, 0, 2))
        let lastMay = dayNumber(year, 5, 31)
        holiday("memorial-day", lastMay - (weekday(lastMay) + 6) % 7, before: 3, after: 1)
        window("graduation", 5, 15, 6, 20, 35)
        window("pride", 6, 1, 6, 30)
        holiday("juneteenth", dayNumber(year, 6, 19), before: 4, after: 2)
        holiday("fathers-day", nthWeekday(year, 6, 0, 3))
        holiday("fourth-july", dayNumber(year, 7, 4), before: 8, after: 3)
        window("back-to-school", 8, 10, 9, 15, 40)
        holiday("labor-day", nthWeekday(year, 9, 1, 1), before: 3, after: 1)
        window("halloween", 10, 1, 11, 1, 60)
        holiday("thanksgiving", nthWeekday(year, 11, 4, 4), before: 10, after: 3)
        window("christmas", 12, 1, 12, 26, 60)
        let season = month <= 2 || month == 12 ? "winter" : month <= 5 ? "spring" : month <= 8 ? "summer" : "autumn"
        let moods = ["comfort", "movie-night", "rainy-day", "weekend-adventures"]
        let offset = (today / 7) % moods.count
        let ranked = candidates.enumerated().sorted { a, b in
            a.element.priority != b.element.priority ? a.element.priority > b.element.priority : a.offset < b.offset
        }.map(\.element.key)
        var seen: Set<String> = []
        return (ranked + [season] + Array(moods[offset...]) + Array(moods[..<offset])).filter { seen.insert($0).inserted }
    }

    private static func test(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    static func matchesCollection(_ name: String, theme: String) -> Bool {
        themes[theme].map { test($0.collections, name) } ?? false
    }
    /// Explicit themed tags can carry collection-only intent, but a generic title
    /// or plot never establishes an identity/observance-specific collection.
    static func metadataMatches(_ item: MediaItem, tags: [String], theme: String) -> Bool {
        guard let rule = themes[theme] else { return false }
        if tags.contains(where: { test(rule.collections, $0) }) { return true }
        guard rule.match != nil || rule.genres != nil else { return false }
        let text = ([item.name, item.overview ?? ""] + tags).joined(separator: " ")
        return (rule.match.map { test($0, text) } ?? true) &&
            (rule.genres.map { genres in (item.genres ?? []).contains(where: genres.contains) } ?? true)
    }
    /// Stable within a week for the account, unwatched first; browsing never reshuffles.
    static func rank(_ items: [MediaItem], theme: String, viewerID: String, at now: Date, timeZone: TimeZone) -> [MediaItem] {
        let week = today(now, timeZone: timeZone) / 7
        func hash(_ text: String) -> UInt64 {
            text.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        }
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
            .map { ($0, hash("\(theme)|\(viewerID)|\(week)|\($0.id)")) }
            .sorted { a, b in
                let playedA = a.0.userData?.played == true, playedB = b.0.userData?.played == true
                return playedA != playedB ? !playedA : a.1 < b.1
            }.prefix(ClientHomeRows.cardLimit).map(\.0)
    }
    public static func title(_ theme: String) -> String? { themes[theme]?.title }
}

// MARK: Jellyfin reads

extension JellyfinClient {
    private func homeEntries(_ query: [URLQueryItem]) async throws -> (entries: [ClientHomeRows.Entry], page: ItemPage) {
        guard let session else { throw ClientError.missingSession }
        let path = ["Items"]
        let full = [URLQueryItem(name: "userId", value: session.viewer.id), .init(name: "recursive", value: "true")] + query
        let data = try await requestData(path, query: full, cachePolicy: .library)
        struct FactsPage: Decodable { var items: [ClientHomeRows.Facts] }
        do {
            let page = try Wire.decoder().decode(ItemPage.self, from: data)
            let facts = try Wire.decoder().decode(FactsPage.self, from: data).items
            guard facts.count == page.items.count else { throw ClientError.invalidResponse }
            return (zip(page.items, facts).map { ClientHomeRows.Entry(item: $0, facts: $1) }, page)
        } catch {
            if let url = try? server.endpoint(path, query: full) { await responseCache?.remove(url.absoluteString, policy: .library) }
            throw ClientError.invalidResponse
        }
    }

    /// Most recent movies, shared by the 90-minute, showcase and seasonal rows.
    /// Bounded to 2,000 titles in eight cached pages.
    func homeMovieCatalog() async throws -> [ClientHomeRows.Entry] {
        var cursor = LibraryPageCursor(), result: [ClientHomeRows.Entry] = []
        for _ in 0..<8 {
            try Task.checkCancellation()
            let (entries, page) = try await homeEntries([
                .init(name: "includeItemTypes", value: "Movie"), .init(name: "sortBy", value: "DateCreated,SortName"),
                .init(name: "sortOrder", value: "Descending"), .init(name: "fields", value: "MediaStreams,Genres,Tags,Overview,DateCreated"),
                .init(name: "enableImageTypes", value: "Primary,Backdrop,Thumb"), .init(name: "imageTypeLimit", value: "1"),
                .init(name: "limit", value: "250"), .init(name: "startIndex", value: String(cursor.offset))])
            result += entries
            cursor.accept(page, limit: 250)
            if !cursor.hasMore { break }
        }
        return result
    }

    func homeNewEpisodes(at now: Date) async throws -> [HomeRowCard] {
        let (shows, _) = try await homeEntries([
            .init(name: "includeItemTypes", value: "Series"), .init(name: "isFavorite", value: "true"),
            .init(name: "enableImages", value: "false"), .init(name: "limit", value: "100")])
        let favorites = Set(shows.map(\.item.id))
        guard !favorites.isEmpty else { return [] }
        let since = now.addingTimeInterval(-ClientHomeRows.recentDays * 86_400)
        var cursor = LibraryPageCursor(), episodes: [ClientHomeRows.Entry] = []
        // Newest unwatched episodes library-wide, stopping once older than 14 days.
        for _ in 0..<3 {
            try Task.checkCancellation()
            let (entries, page) = try await homeEntries([
                .init(name: "includeItemTypes", value: "Episode"), .init(name: "isPlayed", value: "false"),
                .init(name: "sortBy", value: "DateCreated"), .init(name: "sortOrder", value: "Descending"),
                .init(name: "fields", value: "DateCreated,MediaStreams"), .init(name: "limit", value: "200"),
                .init(name: "startIndex", value: String(cursor.offset))])
            episodes += entries
            cursor.accept(page, limit: 200)
            if !cursor.hasMore || (entries.last?.created).map({ $0 < since }) ?? true { break }
        }
        return ClientHomeRows.newEpisodes(episodes, favorites: favorites, at: now)
    }

    func homeCurated(movies: [ClientHomeRows.Entry], at now: Date, timeZone: TimeZone) async throws -> (title: String, cards: [HomeRowCard]) {
        guard let session else { throw ClientError.missingSession }
        let (collections, _) = try await homeEntries([
            .init(name: "includeItemTypes", value: "BoxSet"), .init(name: "enableImages", value: "false"), .init(name: "limit", value: "200")])
        var children: [String: [ClientHomeRows.Entry]] = [:], remaining = 6
        for theme in SeasonalThemes.plan(at: now, timeZone: timeZone) {
            guard let title = SeasonalThemes.title(theme) else { continue }
            var picks: [MediaItem] = []
            for collection in collections.filter({ SeasonalThemes.matchesCollection($0.item.name, theme: theme) }).prefix(2) {
                if children[collection.item.id] == nil {
                    guard remaining > 0 else { break }
                    remaining -= 1
                    children[collection.item.id] = try await homeEntries([
                        .init(name: "parentId", value: collection.item.id), .init(name: "includeItemTypes", value: "Movie"),
                        .init(name: "fields", value: "MediaStreams,Genres,Tags,Overview"), .init(name: "limit", value: "40")]).entries
                }
                picks += (children[collection.item.id] ?? []).filter(\.playable).map(\.item)
            }
            // Library metadata fills only an empty themed collection selection. A
            // missing holiday falls through to an honestly named season/mood shelf.
            if picks.isEmpty {
                picks = movies.filter { $0.playable && SeasonalThemes.metadataMatches($0.item, tags: $0.facts.tags ?? [], theme: theme) }.map(\.item)
            }
            if !picks.isEmpty {
                let ranked = SeasonalThemes.rank(picks, theme: theme, viewerID: session.viewer.id, at: now, timeZone: timeZone)
                return (title, ranked.map { HomeRowCard(id: $0.id, item: $0, subtitle: title) })
            }
        }
        return ("Seasonal picks", [])
    }

    func homeSports(teams: [String], at now: Date) async throws -> [HomeRowCard] {
        guard let session else { throw ClientError.missingSession }
        let channels = try await liveTVSnapshot().channels
        guard !channels.isEmpty else { return [] }
        struct GuidePage: Decodable { var items: [ClientHomeRows.GuideProgram]; var totalRecordCount: Int? }
        var programs: [ClientHomeRows.GuideProgram] = []
        for start in stride(from: 0, to: 1_500, by: 500) {
            try Task.checkCancellation()
            let page = try await request(GuidePage.self, path: ["LiveTv", "Programs"], query: [
                .init(name: "userId", value: session.viewer.id), .init(name: "isSports", value: "true"),
                .init(name: "minEndDate", value: now.ISO8601Format()),
                .init(name: "maxStartDate", value: now.addingTimeInterval(ClientHomeRows.sportsWindow).ISO8601Format()),
                .init(name: "sortBy", value: "StartDate"), .init(name: "sortOrder", value: "Ascending"),
                .init(name: "fields", value: "Overview,Genres"), .init(name: "enableImages", value: "false"),
                .init(name: "startIndex", value: String(start)), .init(name: "limit", value: "500")])
            programs += page.items
            if page.items.count < 500 { break }
        }
        return ClientHomeRows.sports(programs, channels: channels, teams: teams, at: now)
    }

    /// Builds the device-side rows. A failing row becomes "unavailable" without
    /// hiding the others; only authentication loss and cancellation propagate.
    public func clientHomeRows(teams: [String], at now: Date = .now, timeZone: TimeZone = .current) async throws -> [HomeRow] {
        func attempt<T: Sendable>(_ body: () async throws -> T) async throws -> Result<T, any Error> {
            do { return .success(try await body()) }
            catch is CancellationError { throw CancellationError() }
            catch ClientError.unauthorized { throw ClientError.unauthorized }
            catch { return .failure(error) }
        }
        async let movieResult = attempt { try await homeMovieCatalog() }
        async let episodeResult = attempt { try await homeNewEpisodes(at: now) }
        async let sportsResult = attempt { try await homeSports(teams: teams, at: now) }
        let movies = try await movieResult
        let curated = try await attempt { try await homeCurated(movies: (try? movies.get()) ?? [], at: now, timeZone: timeZone) }

        func row(_ id: String, _ title: String, _ result: Result<[HomeRowCard], any Error>, empty: String) -> HomeRow {
            switch result {
            case .success(let cards) where cards.isEmpty:
                HomeRow(id: id, title: title, description: "", state: "empty", message: empty, cards: [])
            case .success(let cards): HomeRow(id: id, title: title, description: "", cards: cards)
            case .failure: HomeRow(id: id, title: title, description: "", state: "unavailable",
                message: "This row could not load. Try again shortly.", cards: [])
            }
        }
        return [
            row("new-episodes", "New episodes for you", try await episodeResult,
                empty: "Favorite a show with the heart button to follow it. New unwatched episodes will appear here."),
            row("short-movies", "Watch in \(ClientHomeRows.shortMovieMinutes) minutes", movies.map { ClientHomeRows.shortMovies($0) },
                empty: "No unwatched movies fit this time limit."),
            row("showcase", "4K / HDR showcase", movies.map(ClientHomeRows.showcase),
                empty: "No titles with verified 4K or HDR metadata are available."),
            row("curated", (try? curated.get().title) ?? "Seasonal picks", curated.map { $0.cards },
                empty: "No matching seasonal or curated titles are available yet."),
            row("sports", "Your teams / starting soon", try await sportsResult,
                empty: teams.isEmpty ? "No upcoming sports are listed." : "No broadcasts for your teams are listed in the next 12 hours.")
        ]
    }
}

// MARK: Followed teams in the viewer's Jellyfin account

extension JellyfinClient {
    static let teamsPreferencesID = "zorofin-home"
    static let teamsKey = "zorofinTeams"
    private func teamsQuery() throws -> [URLQueryItem] {
        guard let session else { throw ClientError.missingSession }
        return [.init(name: "userId", value: session.viewer.id), .init(name: "client", value: "zorofin")]
    }
    private func displayPreferences() async throws -> [String: Any] {
        let data = try await requestData(["DisplayPreferences", Self.teamsPreferencesID], query: teamsQuery())
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClientError.invalidResponse }
        return object
    }
    /// Teams live in Jellyfin's per-user display preferences, so they follow the
    /// account to every device on any server. `nil` means never saved there.
    public func savedHomeTeams() async throws -> [String]? {
        let custom = try await displayPreferences()["CustomPrefs"] as? [String: Any]
        guard let raw = custom?[Self.teamsKey] as? String else { return nil }
        guard let teams = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else { return [] }
        var value = HomePreferences(); value.teams = teams
        return value.isValid ? teams : []
    }
    /// Read-modify-write keeps every other client's display preferences intact.
    public func saveHomeTeams(_ teams: [String]) async throws {
        var value = HomePreferences(); value.teams = teams
        guard value.isValid else { throw ClientError.invalidResponse }
        var object = try await displayPreferences()
        var custom = object["CustomPrefs"] as? [String: Any] ?? [:]
        custom[Self.teamsKey] = String(decoding: try JSONEncoder().encode(teams), as: UTF8.self)
        object["CustomPrefs"] = custom
        object["Id"] = object["Id"] ?? Self.teamsPreferencesID
        object["Client"] = object["Client"] ?? "zorofin"
        _ = try await requestData(["DisplayPreferences", Self.teamsPreferencesID], query: teamsQuery(), method: "POST",
            body: try JSONSerialization.data(withJSONObject: object))
        await responseCache?.invalidateMetadata()
    }
    /// One-time adoption of teams saved by the older Zorofin server feed.
    public func homeTeams(serverFallback: Bool) async throws -> [String] {
        if let saved = try await savedHomeTeams() { return saved }
        guard serverFallback, let legacy = try? await homePreferences().teams else { return [] }
        if !legacy.isEmpty { try? await saveHomeTeams(legacy) }
        return legacy
    }
}
