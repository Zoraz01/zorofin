import Foundation

/// Programme schedules are wall-clock facts, never a seekable/DVR timeline.
public struct LivePlayerGuide: Sendable {
    public let channelID: String
    public let programs: [LiveProgram]
    public let fetchedAt: Date
    public init(channelID: String, programs: [LiveProgram], fetchedAt: Date = .now) {
        self.channelID = channelID; self.fetchedAt = fetchedAt
        self.programs = programs.filter { $0.channelId == channelID && $0.schedule != nil }
            .sorted { $0.schedule!.start < $1.schedule!.start }
    }
    public func current(at now: Date) -> LiveProgram? {
        guard (0..<120).contains(now.timeIntervalSince(fetchedAt)) else { return nil }
        return programs.first { $0.isAiring(at: now) }
    }
    public func next(at now: Date) -> LiveProgram? {
        guard (0..<120).contains(now.timeIntervalSince(fetchedAt)) else { return nil }
        let after = current(at: now)?.schedule?.end ?? now
        return programs.first { $0.schedule!.start >= after }
    }
}
public extension LiveProgram {
    var schedule: (start: Date, end: Date)? {
        guard let start = HomeRowCard.date(startDate), let end = HomeRowCard.date(endDate), end > start else { return nil }
        return (start, end)
    }
    func isAiring(at now: Date) -> Bool {
        guard let schedule else { return false }
        return schedule.start <= now && now < schedule.end
    }
}
private struct LivePlayerGuidePage: Decodable { let items: [LiveProgram] }
public extension JellyfinClient {
    /// Small, viewer-authenticated guide read; does not open a tuner or write history.
    func livePlayerGuide(channelID: String, at now: Date = .now) async throws -> LivePlayerGuide {
        guard let session, session.server == server else { throw ClientError.missingSession }
        guard !channelID.isEmpty else { throw ClientError.invalidResponse }
        let page = try await request(LivePlayerGuidePage.self, path: ["LiveTv", "Programs"], query: [
            .init(name: "userId", value: session.viewer.id), .init(name: "channelIds", value: channelID),
            .init(name: "minEndDate", value: now.ISO8601Format()),
            .init(name: "maxStartDate", value: now.addingTimeInterval(12 * 3600).ISO8601Format()),
            .init(name: "sortBy", value: "StartDate"), .init(name: "sortOrder", value: "Ascending"),
            .init(name: "limit", value: "8"), .init(name: "enableTotalRecordCount", value: "false"),
            .init(name: "enableImages", value: "false"), .init(name: "fields", value: "Overview")])
        guard page.items.count <= 8 else { throw ClientError.invalidResponse }
        return LivePlayerGuide(channelID: channelID, programs: page.items, fetchedAt: now)
    }
}
