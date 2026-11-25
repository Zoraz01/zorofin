import Foundation

// Pick Together (schemaVersion 1): several people swipe the same short list of
// titles and see what everyone liked. Contract: docs/handoffs/PICK_TOGETHER_APPS_HANDOFF.md
// and server/zorofin-companion/src/modules/pickTogether. Phones vote; TVs host
// and display (`display: true`) and never vote or fetch a deck.

public enum PickTogetherKind: String, Sendable, CaseIterable, Identifiable {
    case movie, series
    public var id: String { rawValue }
    public var label: String { self == .movie ? "Movies" : "Shows" }
    public var singular: String { self == .movie ? "Movie" : "Show" }
}

/// Server statuses. `results` is a client view, never a server status.
public enum PickTogetherStatus: String, Sendable {
    case lobby, preparing, swiping, empty, ended, failed, unknown
    public var isOver: Bool { self == .ended || self == .failed }
}

public enum PickTogetherChoice: String, Sendable { case like, skip }

public struct PickTogetherCard: Sendable, Equatable, Identifiable {
    public var id: String { itemID }
    public var itemID: String
    public var type: String
    public var title: String
    public var year: Int?
    public var runtimeMinutes: Int?
    public var officialRating: String?
    public var communityRating: Double?
    public var genres: [String]
    public var seasons: Int?
    public var imageTag: String?
    /// Deck only: why this title is here for this seat ("You requested this").
    public var reason: String?
    /// Deck only: `watched`, `partway` or nil.
    public var seen: String?
    /// Matches and Almost only.
    public var likes: Int?
    public var of: Int?

    public init(itemID: String, type: String = "Movie", title: String, year: Int? = nil, runtimeMinutes: Int? = nil,
                officialRating: String? = nil, communityRating: Double? = nil, genres: [String] = [], seasons: Int? = nil,
                imageTag: String? = nil, reason: String? = nil, seen: String? = nil, likes: Int? = nil, of: Int? = nil) {
        self.itemID = itemID; self.type = type; self.title = title; self.year = year; self.runtimeMinutes = runtimeMinutes
        self.officialRating = officialRating; self.communityRating = communityRating; self.genres = genres
        self.seasons = seasons; self.imageTag = imageTag; self.reason = reason; self.seen = seen
        self.likes = likes; self.of = of
    }

    init?(json: Any?) {
        guard let value = json as? [String: Any], let id = value["itemId"] as? String, PickTogether.validItemID(id),
              let title = value["title"] as? String, !title.isEmpty else { return nil }
        func text(_ key: String) -> String? { (value[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func int(_ key: String) -> Int? { (value[key] as? NSNumber).map(\.intValue) }
        self.init(itemID: id, type: text("type") ?? "Movie", title: String(title.prefix(300)), year: int("year"),
                  runtimeMinutes: int("runtimeMinutes"), officialRating: text("officialRating"),
                  communityRating: (value["communityRating"] as? NSNumber).map(\.doubleValue),
                  genres: (value["genres"] as? [String] ?? []).prefix(6).map { String($0.prefix(40)) },
                  seasons: int("seasons"), imageTag: text("imageTag"), reason: text("reason"), seen: text("seen"),
                  likes: int("likes"), of: int("of"))
    }

    /// "2026 · PG-13 · 1h 52m" or "2019 · TV-MA · 3 seasons".
    public var metadata: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let officialRating { parts.append(officialRating) }
        if type == "Series", let seasons, seasons > 0 { parts.append(seasons == 1 ? "1 season" : "\(seasons) seasons") }
        else if let minutes = runtimeMinutes, minutes > 0 { parts.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m") }
        return parts.joined(separator: " · ")
    }
    /// "3 of 3".
    public var tally: String? { likes.flatMap { likes in of.map { "\(likes) of \($0)" } } }
    /// A media item for the ordinary catalog and player paths.
    public var mediaItem: MediaItem {
        var item = MediaItem(id: itemID, name: title, type: type == "Series" ? "Series" : "Movie", productionYear: year)
        item.officialRating = officialRating; item.communityRating = communityRating; item.genres = genres
        if let imageTag { item.imageTags = ["Primary": imageTag] }
        if let runtimeMinutes { item.runTimeTicks = Int64(runtimeMinutes) * 600_000_000 }
        return item
    }
}

public struct PickTogetherMember: Sendable, Equatable, Identifiable {
    public var id: String { seat }
    public var seat: String
    public var name: String
    public var display: Bool
    public var host: Bool
    public var you: Bool
    public var swiped: Int
    public var total: Int
    public var done: Bool
    public init(seat: String, name: String, display: Bool = false, host: Bool = false, you: Bool = false,
                swiped: Int = 0, total: Int = 0, done: Bool = false) {
        self.seat = seat; self.name = name; self.display = display; self.host = host; self.you = you
        self.swiped = swiped; self.total = total; self.done = done
    }
    /// Two letters for an avatar.
    public var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
    public var progress: Double { total > 0 ? min(1, Double(swiped) / Double(total)) : 0 }
}

public struct PickTogetherSession: Sendable, Equatable, Identifiable {
    public var id: String
    public var code: String
    public var kind: PickTogetherKind
    public var status: PickTogetherStatus
    public var round: Int
    public var version: Int
    /// The calling account hosts the session.
    public var host: Bool
    /// The seat the server resolved for this call. Carry it on every later call.
    public var seat: String?
    public var display: Bool
    public var members: [PickTogetherMember]
    public var voters: Int
    public var poolSize: Int
    public var matches: [PickTogetherCard]
    public var almost: [PickTogetherCard]

    public init(id: String, code: String, kind: PickTogetherKind, status: PickTogetherStatus, round: Int = 0, version: Int = 1,
                host: Bool = false, seat: String? = nil, display: Bool = false, members: [PickTogetherMember] = [],
                voters: Int = 0, poolSize: Int = 0, matches: [PickTogetherCard] = [], almost: [PickTogetherCard] = []) {
        self.id = id; self.code = code; self.kind = kind; self.status = status; self.round = round; self.version = version
        self.host = host; self.seat = seat; self.display = display; self.members = members; self.voters = voters
        self.poolSize = poolSize; self.matches = matches; self.almost = almost
    }

    init?(json: Any?) {
        guard let value = json as? [String: Any], value["schemaVersion"] as? Int == 1,
              let id = value["id"] as? String, PickTogether.validSessionID(id),
              let code = (value["code"] as? String).flatMap(PickTogetherCode.normalize),
              let kind = (value["kind"] as? String).flatMap(PickTogetherKind.init(rawValue:)),
              let version = value["version"] as? Int else { return nil }
        let members: [PickTogetherMember] = (value["members"] as? [[String: Any]] ?? []).prefix(12).compactMap { member in
            guard let seat = member["seat"] as? String, PickTogether.validSeatID(seat) else { return nil }
            let name = (member["name"] as? String).map { String($0.prefix(40)) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Guest"
            return PickTogetherMember(seat: seat, name: name, display: member["display"] as? Bool == true,
                                      host: member["host"] as? Bool == true, you: member["you"] as? Bool == true,
                                      swiped: max(0, member["swiped"] as? Int ?? 0), total: max(0, member["total"] as? Int ?? 0),
                                      done: member["done"] as? Bool == true)
        }
        let seat = (value["seat"] as? String).flatMap { PickTogether.validSeatID($0) ? $0 : nil }
        self.init(id: id, code: code, kind: kind,
                  status: (value["status"] as? String).flatMap(PickTogetherStatus.init(rawValue:)) ?? .unknown,
                  round: max(0, value["round"] as? Int ?? 0), version: version, host: value["host"] as? Bool == true,
                  seat: seat, display: value["display"] as? Bool == true, members: members,
                  voters: max(0, value["voters"] as? Int ?? members.filter { !$0.display }.count),
                  poolSize: max(0, value["poolSize"] as? Int ?? 0),
                  matches: (value["matches"] as? [Any] ?? []).compactMap { PickTogetherCard(json: $0) },
                  almost: (value["almost"] as? [Any] ?? []).compactMap { PickTogetherCard(json: $0) })
    }

    /// Voting members only (a TV display is not a voter).
    public var voterMembers: [PickTogetherMember] { members.filter { !$0.display } }
    /// A match needs at least two voters (the server only matches with 2+), so Start waits for two.
    public func canStart(asDisplay: Bool) -> Bool { host && status == .lobby && voters >= 2 }
    public var you: PickTogetherMember? { members.first { $0.seat == seat } }
}

public struct PickTogetherDeck: Sendable, Equatable {
    public var status: PickTogetherStatus
    public var round: Int
    public var version: Int
    public var cards: [PickTogetherCard]
}

public struct PickTogetherSwipeResult: Sendable, Equatable {
    public var version: Int
    public var match: PickTogetherCard?
}

/// Short, actionable messages for the documented error codes.
public enum PickTogetherError: Error, Equatable, Sendable, LocalizedError {
    case codeNotFound, sessionFull, tooManySeats, notMember, hostOnly, notSwiping, displayOnly, busy
    case alreadyStarted, noVoters, gone, invalidCode, server(Int), invalidResponse

    init(status: Int, data: Data) {
        let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        switch code {
        case "code_not_found": self = .codeNotFound
        case "session_full": self = .sessionFull
        case "too_many_seats": self = .tooManySeats
        case "not_a_member", "seat_not_found": self = .notMember
        case "host_only": self = .hostOnly
        case "not_swiping": self = .notSwiping
        case "display_cannot_vote", "display_has_no_deck": self = .displayOnly
        case "busy": self = .busy
        case "already_started": self = .alreadyStarted
        case "no_voters": self = .noVoters
        case "not_found": self = .gone
        default: self = status == 403 ? .notMember : status == 404 ? .gone : .server(status)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .codeNotFound: "No session uses that code. Check it and try again."
        case .sessionFull: "This session is full."
        case .tooManySeats: "This account already has three seats in this session."
        case .notMember: "You’re no longer in this session."
        case .hostOnly: "Only the host can do that."
        case .notSwiping: "Swiping hasn’t started yet."
        case .displayOnly: "This screen shows the session. Vote from a phone."
        case .busy: "The server is busy. Try again in a moment."
        case .alreadyStarted: "Swiping has already started."
        case .noVoters: "Wait for someone to join first."
        case .gone: "This session has ended."
        case .invalidCode: "Enter the six-character code."
        case .server: "Couldn’t reach Pick Together. Try again."
        case .invalidResponse: "The server sent something unexpected. Try again."
        }
    }
    /// The session is gone for this seat: stop polling and go back to the start.
    public var endsSession: Bool { self == .notMember || self == .gone }
}

public enum PickTogetherCode {
    static let alphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    /// Case- and space-insensitive, exactly six characters from the server's alphabet.
    public static func normalize(_ text: String) -> String? {
        let code = text.uppercased().filter { $0.isLetter || $0.isNumber }
        guard code.count == 6, code.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return code
    }
    /// "ABC DEF" for reading across a room.
    public static func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
}

public enum PickTogetherLink {
    /// `<server>/web/#/home?zorofin=catchup&pick=CODE`. No credentials, ever.
    public static func joinURL(server: ServerAddress, code: String) -> URL? {
        guard let code = PickTogetherCode.normalize(code) else { return nil }
        var base = server.url.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base)/web/#/home?zorofin=catchup&pick=\(code)")
    }

    /// A code from a pasted join link or a bare code. A link must point at the
    /// connected server (same origin and base path); otherwise it is ignored.
    public static func code(from text: String, server: ServerAddress?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = PickTogetherCode.normalize(trimmed), !trimmed.contains("/") { return code }
        guard let url = URL(string: trimmed), let server, url.scheme == "https" || url.scheme == "http",
              url.host?.lowercased() == server.url.host?.lowercased(), url.port == server.url.port,
              url.scheme == server.url.scheme else { return nil }
        var base = server.url.path
        while base.hasSuffix("/") { base.removeLast() }
        guard url.path == base + "/web/" || url.path == base + "/web" || url.path == base + "/web/index.html",
              let fragment = url.fragment, let query = fragment.split(separator: "?", maxSplits: 1).last,
              fragment.contains("?") else { return nil }
        let items = URLComponents(string: "?" + query)?.queryItems ?? []
        guard items.first(where: { $0.name == "zorofin" })?.value == "catchup",
              let pick = items.first(where: { $0.name == "pick" })?.value else { return nil }
        return PickTogetherCode.normalize(pick)
    }
}

enum PickTogether {
    static func validSessionID(_ id: String) -> Bool { id.count == 32 && id.allSatisfy(\.isHexDigit) }
    static func validSeatID(_ id: String) -> Bool { (1...64).contains(id.count) && id.allSatisfy { $0.isLetter || $0.isNumber } }
    static func validItemID(_ id: String) -> Bool { (1...64).contains(id.count) && id.allSatisfy { $0.isHexDigit || $0 == "-" } }
    static let root = ["Zorofin", "Companion", "pickTogether"]
}

/// One session's latest state on this device: version ordering, deck refreshes
/// and match moments that fire once. Pure, so the rules have tests.
public struct PickTogetherTracker: Sendable, Equatable {
    public private(set) var session: PickTogetherSession?
    /// Status and round the deck was last fetched for.
    private var deckKey: String?
    private var celebrated: Set<String> = []

    public init() {}

    /// Applies a full session view. Older versions and other sessions are ignored.
    /// Returns true when the view was taken.
    @discardableResult
    public mutating func apply(_ view: PickTogetherSession) -> Bool {
        if let session, session.id == view.id, view.version < session.version { return false }
        if let session, session.id != view.id { reset() }
        var view = view
        // A refresh from a different seat of the same account must not move this device's seat.
        if let seat = session?.seat, session?.id == view.id, view.seat != seat { view.seat = seat }
        session = view
        return true
    }

    /// `{ unchanged: true }` keeps the full session as it was.
    public func isCurrent(version: Int) -> Bool { session?.version == version }

    /// A voting seat needs a deck when the status or round moves into swiping.
    public var needsDeck: Bool {
        guard let session, !session.display, session.status == .swiping || session.status == .empty else { return false }
        return deckKey != "\(session.round)-\(session.status.rawValue)"
    }
    public mutating func deckFetched(_ deck: PickTogetherDeck) {
        deckKey = "\(deck.round)-\(deck.status.rawValue)"
    }

    /// Matches this device has not celebrated yet (a match moment plays once per title per round).
    public mutating func newMatch(_ card: PickTogetherCard?) -> PickTogetherCard? {
        guard let card, let session else { return nil }
        let key = "\(session.round)-\(card.itemID)"
        guard !celebrated.contains(key) else { return nil }
        celebrated.insert(key)
        return card
    }
    /// Marks every match already on screen as seen, so polling never replays them.
    public mutating func absorbMatches() {
        guard let session else { return }
        for card in session.matches { celebrated.insert("\(session.round)-\(card.itemID)") }
    }

    public mutating func reset() { session = nil; deckKey = nil; celebrated = [] }
}

public extension JellyfinClient {
    private func pickCall(_ path: [String], query: [URLQueryItem] = [], method: String = "GET",
                          body: [String: Any]? = nil) async throws -> Any {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let (status, data) = try await extensionCall(PickTogether.root + path, query: query, method: method, body: payload)
        guard (200..<300).contains(status) else { throw PickTogetherError(status: status, data: data) }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw PickTogetherError.invalidResponse }
        return json
    }
    private func pickSession(_ json: Any) throws -> PickTogetherSession {
        guard let view = PickTogetherSession(json: json) else { throw PickTogetherError.invalidResponse }
        return view
    }
    private func sessionPath(_ id: String, _ action: String? = nil) throws -> [String] {
        guard PickTogether.validSessionID(id) else { throw PickTogetherError.gone }
        return ["sessions", id] + (action.map { [$0] } ?? [])
    }

    /// A TV creates with `display: true` and never votes.
    func createPickTogether(kind: PickTogetherKind, display: Bool) async throws -> PickTogetherSession {
        try pickSession(try await pickCall(["sessions"], method: "POST", body: ["kind": kind.rawValue, "display": display]))
    }

    func joinPickTogether(code: String) async throws -> PickTogetherSession {
        guard let code = PickTogetherCode.normalize(code) else { throw PickTogetherError.invalidCode }
        return try pickSession(try await pickCall(["join"], method: "POST", body: ["code": code]))
    }

    /// Nil means `{ unchanged: true }` for `since`.
    func pickTogetherState(_ id: String, seat: String?, since: Int?) async throws -> PickTogetherSession? {
        var query: [URLQueryItem] = []
        if let seat { query.append(.init(name: "seat", value: seat)) }
        if let since { query.append(.init(name: "since", value: String(since))) }
        let json = try await pickCall(try sessionPath(id), query: query)
        if let value = json as? [String: Any], value["unchanged"] as? Bool == true { return nil }
        return try pickSession(json)
    }

    func pickTogetherDeck(_ id: String, seat: String?) async throws -> PickTogetherDeck {
        let json = try await pickCall(try sessionPath(id, "deck"), query: seat.map { [.init(name: "seat", value: $0)] } ?? [])
        guard let value = json as? [String: Any], let version = value["version"] as? Int else { throw PickTogetherError.invalidResponse }
        return PickTogetherDeck(status: (value["status"] as? String).flatMap(PickTogetherStatus.init(rawValue:)) ?? .unknown,
                                round: value["round"] as? Int ?? 0, version: version,
                                cards: (value["cards"] as? [Any] ?? []).prefix(40).compactMap { PickTogetherCard(json: $0) })
    }

    /// Session swipes only: never recommendation taste, played state, favorites or the watchlist.
    func pickTogetherSwipe(_ id: String, seat: String?, itemID: String, choice: PickTogetherChoice) async throws -> PickTogetherSwipeResult {
        var body: [String: Any] = ["itemId": itemID, "choice": choice.rawValue]
        if let seat { body["seat"] = seat }
        let json = try await pickCall(try sessionPath(id, "swipes"), method: "POST", body: body)
        guard let value = json as? [String: Any], let version = value["version"] as? Int else { throw PickTogetherError.invalidResponse }
        return PickTogetherSwipeResult(version: version, match: PickTogetherCard(json: value["match"]))
    }

    /// Host actions: `start`, `next-round`, `end`.
    func pickTogetherHost(_ id: String, seat: String?, action: PickTogetherHostAction) async throws -> PickTogetherSession {
        var body: [String: Any] = [:]
        if let seat { body["seat"] = seat }
        return try pickSession(try await pickCall(try sessionPath(id, action.rawValue), method: "POST", body: body))
    }

    /// The caller's seat goes in the query; the body names the seat to remove.
    func pickTogetherRemove(_ id: String, seat: String?, target: String) async throws -> PickTogetherSession {
        guard PickTogether.validSeatID(target) else { throw PickTogetherError.notMember }
        return try pickSession(try await pickCall(try sessionPath(id, "remove"), query: seat.map { [.init(name: "seat", value: $0)] } ?? [],
                                                  method: "POST", body: ["seat": target]))
    }

    func pickTogetherLeave(_ id: String, seat: String?) async throws {
        var body: [String: Any] = [:]
        if let seat { body["seat"] = seat }
        _ = try await pickCall(try sessionPath(id, "leave"), method: "POST", body: body)
    }
}

public enum PickTogetherHostAction: String, Sendable {
    case start, nextRound = "next-round", end
}
