import Foundation

/// Two hours of broadcast time. This is a schedule, not a DVR/seek range.
public struct LiveGuideWindow: Equatable, Hashable, Sendable {
    public let start: Date
    public var end: Date { start.addingTimeInterval(Self.duration) }
    public static let duration: TimeInterval = 7_200
    public init(start: Date) { self.start = start }
    public static func current(at date: Date = .now, calendar: Calendar = .current) -> Self {
        let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        return Self(start: hour.addingTimeInterval(floor(date.timeIntervalSince(hour) / 1_800) * 1_800))
    }
    public func shifted(_ pages: Int) -> Self { Self(start: start.addingTimeInterval(Double(pages) * Self.duration)) }
    public func contains(_ date: Date) -> Bool { start <= date && date < end }
    public func fraction(_ date: Date) -> Double { min(1, max(0, date.timeIntervalSince(start) / Self.duration)) }
}

public struct LiveGuideSlot: Identifiable, Sendable {
    public let id: String
    public let program: LiveProgram?
    public let start: Date
    public let end: Date
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct LiveGuideRow: Identifiable, Sendable {
    public var id: String { channel.id }
    public let channel: MediaItem
    public let slots: [LiveGuideSlot]

    /// Clip broadcasts to the viewport, preserve gaps, and prevent overlapping
    /// or duplicate server entries from placing controls on top of each other.
    public init(channel: MediaItem, programs: [LiveProgram], window: LiveGuideWindow) {
        self.channel = channel
        let ordered = programs.compactMap { program -> (LiveProgram, Date, Date)? in
            guard program.channelId == channel.id, let schedule = program.schedule,
                  schedule.start < window.end, schedule.end > window.start else { return nil }
            return (program, schedule.start, schedule.end)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            return ($0.0.id ?? $0.0.name) < ($1.0.id ?? $1.0.name)
        }
        var result: [LiveGuideSlot] = [], cursor = window.start
        func slot(_ program: LiveProgram?, _ start: Date, _ end: Date) -> LiveGuideSlot {
            .init(id: "\(channel.id)|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)",
                  program: program, start: start, end: end)
        }
        for (program, start, end) in ordered {
            let left = max(cursor, start), right = min(window.end, end)
            guard right > left else { continue }
            if left > cursor { result.append(slot(nil, cursor, left)) }
            result.append(slot(program, left, right)); cursor = right
        }
        if cursor < window.end { result.append(slot(nil, cursor, window.end)) }
        slots = result
    }

    public static func matching(_ channels: [MediaItem], query: String, favorites: Bool) -> [MediaItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        return channels.filter {
            !$0.id.isEmpty && seen.insert($0.id).inserted && (!favorites || $0.userData?.isFavorite == true) &&
                (query.isEmpty || $0.name.localizedStandardContains(query) || ($0.channelNumber ?? "").localizedStandardContains(query))
        }
    }
}

private struct LiveGuidePage: Decodable, Sendable {
    let items: [LiveProgram]
    let totalRecordCount: Int?
}

public extension JellyfinClient {
    /// Index reads are independent of program reads. A guide failure must not
    /// hide channels that the viewer can still select and play.
    func guideChannels(start: Int = 0) async throws -> ItemPage {
        guard let session, session.server == server else { throw ClientError.missingSession }
        return try await request(ItemPage.self, path: ["LiveTv", "Channels"], query: [
            .init(name: "userId", value: session.viewer.id), .init(name: "startIndex", value: String(max(0, start))),
            .init(name: "limit", value: "200"), .init(name: "sortBy", value: "ChannelNumber,SortName"),
            .init(name: "sortOrder", value: "Ascending"), .init(name: "enableFavoriteSorting", value: "false"),
            .init(name: "enableUserData", value: "true"), .init(name: "addCurrentProgram", value: "false"),
            .init(name: "enableImages", value: "true"), .init(name: "imageTypeLimit", value: "1")])
    }

    /// Viewer-scoped, bounded and paged. Does not open streams, report playback,
    /// create recordings, or call optional server extensions.
    func guidePrograms(channelIDs: [String], window: LiveGuideWindow) async throws -> [LiveProgram] {
        guard let session, session.server == server else { throw ClientError.missingSession }
        let ids = Array(Set(channelIDs)).sorted()
        guard !ids.isEmpty, ids.count <= 40, ids.allSatisfy({ !$0.isEmpty && !$0.contains(",") }),
              window.start.timeIntervalSince1970.isFinite else { throw ClientError.invalidResponse }
        var programs: [LiveProgram] = [], seen: Set<LiveProgram> = [], offset = 0
        // A pathological or non-paging server must not create an endless loop.
        for _ in 0..<20 {
            try Task.checkCancellation()
            let page = try await request(LiveGuidePage.self, path: ["LiveTv", "Programs"], query: [
                .init(name: "userId", value: session.viewer.id), .init(name: "channelIds", value: ids.joined(separator: ",")),
                .init(name: "minEndDate", value: window.start.ISO8601Format()),
                .init(name: "maxStartDate", value: window.end.ISO8601Format()),
                .init(name: "startIndex", value: String(offset)), .init(name: "limit", value: "200"),
                .init(name: "sortBy", value: "StartDate,SortName"), .init(name: "sortOrder", value: "Ascending"),
                .init(name: "enableTotalRecordCount", value: "true"), .init(name: "enableImages", value: "false"),
                .init(name: "fields", value: "Overview,Genres")])
            guard page.items.count <= 200 else { throw ClientError.invalidResponse }
            let additions = page.items.filter { seen.insert($0).inserted }
            programs += additions.filter { program in
                guard let channel = program.channelId, ids.contains(channel), let schedule = program.schedule else { return false }
                return schedule.start < window.end && schedule.end > window.start
            }
            offset += page.items.count
            if page.items.isEmpty || (page.totalRecordCount.map { offset >= $0 } ?? (page.items.count < 200)) { return programs }
            guard !additions.isEmpty else { throw ClientError.invalidResponse }
        }
        // Report incomplete pagination instead of presenting missing listings as fact.
        throw ClientError.invalidResponse
    }
}
