import Foundation

public struct HomePreferences: Codable, Sendable, Equatable {
    public var hiddenRows: [String] = []
    public var teams: [String] = []
    public var minutes: Int = 90
    public var theme: String = "automatic"
    public init() {}
    public static let rowOptions: [(id: String, title: String)] = [
        ("requests-ready", "Your requests are ready"), ("new-episodes", "New episodes for you"),
        ("short-movies", "Watch in your available time"), ("showcase", "4K / HDR showcase"),
        ("curated", "Seasonal / curated picks"), ("popular", "Popular on Zorofin this week"),
        ("sports", "Your teams / starting soon")
    ]
    /// Native Home is automatic; only followed teams remain viewer-editable.
    public var automatic: Self {
        var value = Self()
        value.teams = teams
        return value
    }
    public var isValid: Bool {
        [30, 60, 90, 120, 180].contains(minutes) &&
        ["automatic", "halloween", "eid", "comfort", "movie-night"].contains(theme) &&
        hiddenRows.allSatisfy { id in Self.rowOptions.contains { $0.id == id } } &&
        teams.count <= 12 && teams.allSatisfy {
            let text = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.count >= 3 && text.utf16.count <= 64 && text.rangeOfCharacter(from: .controlCharacters) == nil
        }
    }
}

public struct HomeFeed: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let preferences: HomePreferences
    public let rows: [HomeRow]
    public init(schemaVersion: Int = 1, generatedAt: String, preferences: HomePreferences, rows: [HomeRow]) {
        self.schemaVersion = schemaVersion; self.generatedAt = generatedAt; self.preferences = preferences; self.rows = rows
    }
}
public struct HomeRow: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let description: String
    public let state: String
    public let message: String?
    public let cards: [HomeRowCard]
    public init(id: String, title: String, description: String, state: String = "ready", message: String? = nil, cards: [HomeRowCard]) {
        self.id = id; self.title = title; self.description = description; self.state = state; self.message = message; self.cards = cards
    }
}
public struct HomeRowCard: Codable, Sendable, Identifiable {
    public let id: String
    public let item: MediaItem
    public let subtitle: String
    public let badges: [String]
    public let startsAt: String?
    public let endsAt: String?
    public init(id: String, item: MediaItem, subtitle: String, badges: [String] = [], startsAt: String? = nil, endsAt: String? = nil) {
        self.id = id; self.item = item; self.subtitle = subtitle; self.badges = badges; self.startsAt = startsAt; self.endsAt = endsAt
    }
    /// Legacy extension rows advertise available formats across file versions.
    /// Keep those supplied labels separate from the native first-file metadata.
    public var qualityBadges: [String] {
        let formats: Set<String> = ["4K", "8K", "1080p", "720p", "HDR", "HDR10", "HDR10+", "Dolby Vision", "HLG"]
        return badges.filter { formats.contains($0) }
    }
    public var contextBadges: [String] { badges.filter { !qualityBadges.contains($0) } }
    public static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    public func isExpired(at date: Date) -> Bool { Self.date(endsAt).map { $0 <= date } ?? false }
}

extension JellyfinClient {
    public func homeFeed() async throws -> HomeFeed {
        let data = try await requestData(["support", "home", "rows"], extensionToken: true, expectedStatus: 200, cachePolicy: .home)
        do {
            let feed = try Wire.decoder().decode(HomeFeed.self, from: data)
            guard feed.schemaVersion == 1, feed.preferences.isValid, feed.rows.count <= 7,
                  Set(feed.rows.map(\.id)).count == feed.rows.count,
                  feed.rows.allSatisfy({ row in
                      HomePreferences.rowOptions.contains { $0.id == row.id } &&
                      ["ready", "empty", "unavailable"].contains(row.state) && row.cards.count <= 20 &&
                      Set(row.cards.map(\.id)).count == row.cards.count
                  }) else { throw ClientError.invalidResponse }
            return feed
        } catch {
            if let url = try? server.endpoint(["support", "home", "rows"]) {
                await responseCache?.remove(url.absoluteString, policy: .home)
            }
            throw error
        }
    }
    /// Older Home adapters intentionally omit rating and stream fields. Enrich
    /// only display metadata through ordinary, viewer-scoped Jellyfin reads.
    /// Batches are cached; no request is made for every poster or scroll event.
    public func enrichHomeFeed(_ feed: HomeFeed) async throws -> HomeFeed {
        guard let session else { throw ClientError.missingSession }
        let missing = feed.rows.flatMap(\.cards).filter { card in
            !card.item.isLive && (card.item.communityRating == nil ||
                (!card.item.isSeries && card.item.type != "Season" && card.item.quality().thumbnailBadges.isEmpty))
        }.map { $0.item.id }.filter {
            $0.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
        }
        let ids = Array(Set(missing).sorted().prefix(140))
        guard !ids.isEmpty else { return feed }
        var metadata: [String: MediaItem] = [:]
        for start in stride(from: 0, to: ids.count, by: 50) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            do {
                let page = try await request(ItemPage.self, path: ["Items"], query: [
                    .init(name: "userId", value: session.viewer.id),
                    .init(name: "ids", value: batch.joined(separator: ",")),
                    .init(name: "fields", value: "MediaStreams"),
                    .init(name: "enableUserData", value: "false"),
                    .init(name: "limit", value: String(batch.count))], cachePolicy: .library)
                let requested = Set(batch)
                for item in page.items where requested.contains(item.id) { metadata[item.id] = item }
            } catch is CancellationError { throw CancellationError() }
            catch let error as ClientError where error == .unauthorized || error == .forbidden || error == .unsafeURL { throw error }
            catch { /* Keep the available row when optional metadata is unavailable. */ }
        }
        return HomeFeed(schemaVersion: feed.schemaVersion, generatedAt: feed.generatedAt, preferences: feed.preferences,
            rows: feed.rows.map { row in
                HomeRow(id: row.id, title: row.title, description: row.description, state: row.state, message: row.message,
                    cards: row.cards.map { card in
                        var item = card.item
                        if let detail = metadata[item.id] {
                            item.communityRating = detail.communityRating ?? item.communityRating
                            item.mediaStreams = detail.mediaStreams ?? item.mediaStreams
                            item.container = detail.container ?? item.container
                        }
                        return HomeRowCard(id: card.id, item: item, subtitle: card.subtitle, badges: card.badges,
                            startsAt: card.startsAt, endsAt: card.endsAt)
                    })
            })
    }

    /// Restore legacy row choices once when needed, preserving the latest saved teams.
    /// Read fresh preferences before writing: the feed may be a cached snapshot.
    public func automaticHomeFeed() async throws -> HomeFeed {
        let feed = try await homeFeed()
        guard feed.preferences != feed.preferences.automatic else { return feed }
        let current = try await homePreferences()
        try Task.checkCancellation()
        if current != current.automatic {
            _ = try await saveHomePreferences(current.automatic)
        } else if let url = try? server.endpoint(["support", "home", "rows"]) {
            await responseCache?.remove(url.absoluteString, policy: .home)
        }
        // Bounded refetch, never a migration loop if a server ignores the update.
        let automaticFeed = try await homeFeed()
        guard automaticFeed.preferences == automaticFeed.preferences.automatic else { throw ClientError.invalidResponse }
        return automaticFeed
    }
    public func homePreferences() async throws -> HomePreferences {
        let data = try await requestData(["support", "home", "preferences"], extensionToken: true, expectedStatus: 200)
        let result = try JSONDecoder().decode(HomePreferences.self, from: data)
        guard result.isValid else { throw ClientError.invalidResponse }
        return result
    }
    public func saveHomePreferences(_ preferences: HomePreferences) async throws -> HomePreferences {
        guard preferences.isValid else { throw ClientError.invalidResponse }
        let data = try await requestData(["support", "home", "preferences"], method: "PUT",
            body: JSONEncoder().encode(preferences), extensionToken: true, expectedStatus: 200)
        let result = try JSONDecoder().decode(HomePreferences.self, from: data)
        guard result.isValid else { throw ClientError.invalidResponse }
        await responseCache?.invalidateMetadata()
        return result
    }
}
