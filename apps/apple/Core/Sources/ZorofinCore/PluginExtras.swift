import Foundation

/// The Zorofin plugin's optional viewer extras (`GET /Zorofin/Extras`): which of
/// Calendar and Catch Up the operator turned on. Same reader as the web pack
/// (branding/zorofin-extras-pages.js) and the TV apps. Missing route: neither.
public struct PluginExtras: Sendable, Equatable {
    public static let none = PluginExtras()
    /// Upcoming episodes and movie releases from Sonarr and Radarr.
    public var calendar: Bool
    /// One unwatched title at a time: skip, watch later, seen it, or play.
    public var catchUp: Bool
    public var any: Bool { calendar || catchUp }

    public init(calendar: Bool = false, catchUp: Bool = false) {
        self.calendar = calendar; self.catchUp = catchUp
    }

    public static func decode(_ data: Data) -> PluginExtras {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .none }
        return PluginExtras(calendar: json["calendar"] as? Bool == true, catchUp: json["catchUp"] as? Bool == true)
    }
}

/// One Calendar entry: an episode airing or a movie release.
public struct CalendarEvent: Sendable, Equatable, Identifiable {
    public var id: String { "\(kind)-\(day)-\(title)-\(subtitle ?? "")-\(at.timeIntervalSince1970)" }
    /// `episode` or `movie`.
    public var kind: String
    public var title: String
    public var at: Date
    /// The viewer's local day, `yyyy-MM-dd`.
    public var day: String
    public var subtitle: String?
    public var allDay = false
    /// `airing`, `cinema`, `digital` or `physical`.
    public var release = ""
    public var hasFile = false
    public var premiere = false
    public var posterURL: URL?
    public var network: String?
    /// The library item, when the title is already on the server.
    public var itemID: String?

    public var isEpisode: Bool { kind == "episode" }

    public init(kind: String, title: String, at: Date, day: String, subtitle: String? = nil, allDay: Bool = false,
                release: String = "", hasFile: Bool = false, premiere: Bool = false, posterURL: URL? = nil,
                network: String? = nil, itemID: String? = nil) {
        self.kind = kind; self.title = title; self.at = at; self.day = day; self.subtitle = subtitle
        self.allDay = allDay; self.release = release; self.hasFile = hasFile; self.premiere = premiere
        self.posterURL = posterURL; self.network = network; self.itemID = itemID
    }

    /// Nil when the entry has no usable date.
    public init?(json value: Any, calendar: Calendar = .current) {
        guard let value = value as? [String: Any], let kind = value["kind"] as? String,
              kind == "episode" || kind == "movie", let at = value["at"] as? String,
              let title = value["title"] as? String else { return nil }
        let allDay = value["allDay"] as? Bool == true
        let when: Date
        if allDay {
            // Movie releases are dates, not times: they land on that date anywhere.
            let parts = at.prefix(10).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
            when = date
        } else {
            guard let date = Self.instant(at) else { return nil }
            when = date
        }
        let poster = (value["posterUrl"] as? String).flatMap(URL.init(string:))
        let item = value["itemId"] as? String
        self.init(kind: kind, title: title, at: when, day: dayKey(when, calendar: calendar),
                  subtitle: value["subtitle"] as? String, allDay: allDay,
                  release: value["release"] as? String ?? "", hasFile: value["hasFile"] as? Bool == true,
                  premiere: value["premiere"] as? Bool == true,
                  // Only https artwork; the plugin already limits the hosts.
                  posterURL: poster?.scheme == "https" ? poster : nil,
                  network: value["network"] as? String, itemID: item?.isEmpty == false ? item : nil)
    }

    static func instant(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private static let releases = ["airing": "New episode", "cinema": "In cinemas",
                                   "digital": "Digital release", "physical": "On disc"]

    /// "Series premiere", "Season premiere", "New episode", "In cinemas"…
    public var badge: String {
        if premiere {
            return (subtitle ?? "").range(of: #"^S1:E1\b"#, options: .regularExpression) != nil
                ? "Series premiere" : "Season premiere"
        }
        return Self.releases[release] ?? ""
    }
}

/// What the Calendar shows: everything, shows only or movies only.
public enum CalendarFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "Everything", shows = "Shows", movies = "Movies"
    public var id: String { rawValue }
    public var label: String { rawValue }
    public func keeps(_ event: CalendarEvent) -> Bool {
        switch self {
        case .all: true
        case .shows: event.isEpisode
        case .movies: !event.isEpisode
        }
    }
}

public struct CalendarDay: Sendable, Equatable, Identifiable {
    public var id: String { day }
    public var day: String
    public var events: [CalendarEvent]
}

public enum CalendarAgenda {
    /// The four weeks the agenda shows, like the web.
    public static let days = 28

    /// Today onward, grouped by the viewer's local day, in date order.
    public static func group(_ events: [CalendarEvent], filter: CalendarFilter, now: Date,
                             calendar: Calendar = .current) -> [CalendarDay] {
        let today = dayKey(now, calendar: calendar)
        var groups: [String: [CalendarEvent]] = [:]
        for event in events where filter.keeps(event) && event.day >= today {
            groups[event.day, default: []].append(event)
        }
        return groups.keys.sorted().map { key in
            CalendarDay(day: key, events: groups[key]!.sorted { a, b in
                if a.allDay != b.allDay { return !a.allDay }
                return a.at < b.at
            })
        }
    }

    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let months = ["January", "February", "March", "April", "May", "June", "July",
                                 "August", "September", "October", "November", "December"]

    /// "Today · Monday, November 9", "Tomorrow · …", or "Wednesday, November 11".
    public static func label(_ key: String, now: Date, calendar: Calendar = .current) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return key }
        let c = calendar.dateComponents([.weekday, .month, .day], from: date)
        let name = "\(weekdays[(c.weekday ?? 1) - 1]), \(months[(c.month ?? 1) - 1]) \(c.day ?? 1)"
        if key == dayKey(now, calendar: calendar) { return "Today · " + name }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), key == dayKey(tomorrow, calendar: calendar) {
            return "Tomorrow · " + name
        }
        return name
    }
}

public func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

/// Catch Up's four choices; the server log names them the same way.
public enum CatchUpAction: String, Sendable {
    case skip, like, later, watched, watch
}

/// What Catch Up offers.
public enum CatchUpKind: String, CaseIterable, Sendable, Identifiable {
    case all = "Everything", movies = "Movies", shows = "Shows"
    public var id: String { rawValue }
    public var label: String { rawValue }
    public var types: String {
        switch self {
        case .all: "Movie,Series"
        case .movies: "Movie"
        case .shows: "Series"
        }
    }
}

public extension JellyfinClient {
    /// Which extras the operator turned on. Missing plugin or route: none.
    func pluginExtras() async throws -> PluginExtras {
        do {
            let data = try await requestData(["Zorofin", "Extras"], extensionToken: true, expectedStatus: 200)
            return PluginExtras.decode(data)
        } catch let error as ClientError {
            switch error {
            case .unavailable(404), .unavailable(405), .forbidden: return .none
            default: throw error
            }
        }
    }

    /// Upcoming episodes and releases from `start` (the viewer's local day).
    func calendar(start: Date, days: Int = CalendarAgenda.days, calendar: Calendar = .current) async throws -> [CalendarEvent] {
        let data = try await requestData(["Zorofin", "Arr", "Calendar"],
            query: [.init(name: "start", value: dayKey(start, calendar: calendar)), .init(name: "days", value: String(days))],
            extensionToken: true, expectedStatus: 200)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [Any] else { throw ClientError.invalidResponse }
        return items.compactMap { CalendarEvent(json: $0, calendar: calendar) }
    }

    /// Random library titles not yet liked for recommendations; watched state is unrelated.
    func catchUpTitles(_ kind: CatchUpKind) async throws -> [MediaItem] {
        guard let userID = session?.viewer.id else { throw ClientError.missingSession }
        let page = try await request(ItemPage.self, path: ["Users", userID, "Items"], query: [
            .init(name: "IncludeItemTypes", value: kind.types), .init(name: "Recursive", value: "true"),
            .init(name: "SortBy", value: "Random"),
            .init(name: "Limit", value: "60"), .init(name: "HasOverview", value: "true"),
            .init(name: "Fields", value: "Overview,ProductionYear,OfficialRating,CommunityRating,RunTimeTicks,ChildCount,Genres"),
            .init(name: "ImageTypeLimit", value: "1"), .init(name: "EnableImageTypes", value: "Backdrop,Logo,Primary"),
            .init(name: "ExcludeLocationTypes", value: "Virtual")
        ])
        let data = try await requestData(["Zorofin", "Companion", "recommendations", "taste"], extensionToken: true, expectedStatus: 200)
        let liked = try recommendationTasteIDs(data)
        return page.items.filter { !liked.contains($0.id.replacingOccurrences(of: "-", with: "").lowercased()) }
    }

    /// A recommendation preference only. Never changes watched/favorite/watchlist data.
    func likeForRecommendations(_ itemID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["itemId": itemID, "action": "like"])
        let data = try await requestData(["Zorofin", "Companion", "recommendations", "taste"], method: "POST", body: body, extensionToken: true, expectedStatus: 200)
        let ids = try recommendationTasteIDs(data)
        guard ids.contains(itemID.replacingOccurrences(of: "-", with: "").lowercased()) else { throw ClientError.invalidResponse }
    }

    /// "Watch later": the viewer likes the title, which Zorofin treats as
    /// their watchlist (and Seerr's, when the operator links them).
    func likeItem(_ itemID: String) async throws {
        guard let userID = session?.viewer.id else { throw ClientError.missingSession }
        _ = try await requestData(["UserItems", itemID, "Rating"], query: [
            .init(name: "userId", value: userID), .init(name: "likes", value: "true")
        ], method: "POST")
    }

    /// Best effort: the operator's optional Catch Up log.
    func logCatchUp(_ itemID: String, action: CatchUpAction) async {
        guard let body = try? JSONSerialization.data(withJSONObject: ["itemId": itemID, "action": action.rawValue]) else { return }
        _ = try? await requestData(["Zorofin", "Extras", "CatchUp", "Log"], method: "POST", body: body, extensionToken: true)
    }
}

/// Titles skipped in Catch Up, per server account, on this device only (the
/// web keeps them per browser). Newest 500.
public struct CatchUpSkips: Sendable {
    public let key: String
    private let read: @Sendable (String) -> [String]?
    private let write: @Sendable (String, [String]) -> Void

    public init(server: String, viewerID: String,
                read: @escaping @Sendable (String) -> [String]?, write: @escaping @Sendable (String, [String]) -> Void) {
        key = "zorofin-catchup-skips:\(server):\(viewerID)"; self.read = read; self.write = write
    }

    /// Backed by the app's standard defaults.
    public static func standard(server: String, viewerID: String) -> CatchUpSkips {
        CatchUpSkips(server: server, viewerID: viewerID,
                     read: { UserDefaults.standard.stringArray(forKey: $0) },
                     write: { UserDefaults.standard.set($1, forKey: $0) })
    }

    private var all: [String] { read(key) ?? [] }
    public func contains(_ id: String) -> Bool { all.contains(id) }
    public func add(_ id: String) {
        let list = all.filter { $0 != id } + [id]
        write(key, Array(list.suffix(500)))
    }
    public func remove(_ id: String) { write(key, all.filter { $0 != id }) }
    public func clear() { write(key, []) }
}

/// Watched and unwatched titles are eligible; skip is neutral.
public struct CatchUpQueue: Sendable {
    public let items: [MediaItem]
    public private(set) var index = 0

    public init(_ titles: [MediaItem], skips: CatchUpSkips) {
        items = titles.filter { !skips.contains($0.id) }
    }

    public var current: MediaItem? { index < items.count ? items[index] : nil }
    public var done: Bool { current == nil }
    /// "3 of 42".
    public var position: String { "\(index + 1) of \(items.count)" }
    public mutating func next() { if index < items.count { index += 1 } }
    public mutating func restore(_ position: Int) { if items.indices.contains(position) { index = position } }
}

private func recommendationTasteIDs(_ data: Data) throws -> Set<String> {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["schemaVersion"] as? Int == 1, let ids = json["likedItemIds"] as? [String],
          ids.count <= 500, ids.allSatisfy({ !$0.isEmpty }) else { throw ClientError.invalidResponse }
    return Set(ids.map { $0.replacingOccurrences(of: "-", with: "").lowercased() })
}
