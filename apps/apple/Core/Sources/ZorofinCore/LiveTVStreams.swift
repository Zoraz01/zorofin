import Foundation

/// Which channels are using the server's Live TV streams, from the companion's
/// `liveTvStreams` module (capability version 1). Viewers get channel names and
/// counts only, never who is watching. Text matches the web client
/// (branding/zorofin-live-tv-streams.js) so every app says the same thing.
public struct LiveTVStreams: Decodable, Sendable, Equatable {
    public struct Programme: Decodable, Sendable, Equatable {
        public let title: String
        public let endsAt: String?
        public init(title: String, endsAt: String? = nil) { self.title = title; self.endsAt = endsAt }
    }
    public struct Stream: Decodable, Sendable, Equatable, Identifiable {
        public let channelId: String
        public let channelName: String
        public let channelNumber: String?
        public let programme: Programme?
        public let viewers: Int
        public let paused: Bool
        public let yours: Bool
        public var id: String { channelId }
        public init(channelId: String, channelName: String, channelNumber: String? = nil, programme: Programme? = nil,
                    viewers: Int = 1, paused: Bool = false, yours: Bool = false) {
            self.channelId = channelId; self.channelName = channelName; self.channelNumber = channelNumber
            self.programme = programme; self.viewers = viewers; self.paused = paused; self.yours = yours
        }
        /// A playable channel item for Join.
        public var channel: MediaItem { MediaItem(id: channelId, name: channelName, type: "TvChannel") }
        /// "2 watching · 18 min left"
        public func detail(now: Date = .now) -> String {
            var parts = ["\(max(1, viewers)) watching"]
            if let left = LiveTVStreams.timeLeft(programme?.endsAt, now: now) { parts.append(left) }
            return parts.joined(separator: " · ")
        }
    }
    public struct Request: Decodable, Sendable, Equatable {
        public let channelId: String
        public let playing: Bool
        public let canStart: Bool
        public let reason: String
    }

    public let version: Int
    public let state: String
    public let limit: Int
    public let inUse: Int
    public let free: Int
    public let otherUse: Int
    public let streams: [Stream]
    public let request: Request?

    public init(limit: Int, inUse: Int, free: Int, otherUse: Int = 0, streams: [Stream], request: Request? = nil) {
        self.version = 1; self.state = free > 0 ? "available" : "full"; self.limit = limit; self.inUse = inUse
        self.free = free; self.otherUse = otherUse; self.streams = streams; self.request = request
    }

    public var isFull: Bool { free <= 0 }

    /// "1 of 1 Live TV stream in use. Anyone can join a channel that’s already playing."
    public var summary: String {
        let head = "\(inUse) of \(Self.plural(limit, "Live TV stream")) in use."
        return isFull ? head + " Anyone can join a channel that’s already playing."
            : head + " \(Self.plural(free, "stream")) free for another channel."
    }

    public func stream(for channelID: String) -> Stream? {
        let id = Self.clean(channelID)
        return streams.first { Self.clean($0.channelId) == id }
    }

    /// The line under a channel's Play button, or nil when there is nothing to say.
    public func channelLine(for channelID: String) -> String? {
        if let playing = stream(for: channelID) {
            if playing.yours { return "You’re watching this channel." }
            return "Already playing" + (playing.viewers > 1 ? " for \(playing.viewers) people" : "") + ". Joining doesn’t use another stream."
        }
        guard isFull, let list = othersList(excluding: channelID) else { return nil }
        return limit == 1 ? "\(list) is using the only Live TV stream." : "\(list) are using all \(limit) Live TV streams."
    }

    public struct Blocked: Sendable, Equatable {
        public let title: String
        public let text: String
        public let hint: String
        /// The one channel the viewer could watch instead.
        public let join: Stream?
    }

    /// Set when starting this channel would need a stream and none is free.
    public func blocked(channelID: String) -> Blocked? {
        if let request, Self.clean(request.channelId) == Self.clean(channelID) {
            guard !request.canStart else { return nil }
        } else if stream(for: channelID) != nil || !isFull {
            return nil
        }
        let others = streams.filter { Self.clean($0.channelId) != Self.clean(channelID) }
        let list = othersList(excluding: channelID)
        let text = list.map { limit == 1 ? "\($0) is using the only Live TV stream right now." : "\($0) are using all \(limit) Live TV streams right now." }
            ?? "Every Live TV stream is in use right now."
        let hint = others.isEmpty ? "Try again when a stream is free."
            : "You can watch \(others.count == 1 ? others[0].channelName : "one of those channels") instead, or try again when a stream is free."
        return Blocked(title: "Live TV is in use", text: text, hint: hint, join: others.count == 1 ? others[0] : nil)
    }

    private func othersList(excluding channelID: String) -> String? {
        var names = streams.filter { Self.clean($0.channelId) != Self.clean(channelID) }.map(\.channelName).filter { !$0.isEmpty }
        if otherUse > 0 { names.append(otherUse == 1 ? "another app" : "\(otherUse) other apps") }
        guard let last = names.last else { return nil }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
    }

    static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }
    static func clean(_ id: String) -> String { id.replacingOccurrences(of: "-", with: "").lowercased() }
    static func timeLeft(_ endsAt: String?, now: Date) -> String? {
        // Jellyfin writes seven fractional digits, which ISO8601DateFormatter rejects; drop them.
        guard let endsAt, let end = ISO8601DateFormatter().date(from: endsAt.replacingOccurrences(
            of: "\\.\\d+", with: "", options: .regularExpression)) else { return nil }
        let minutes = Int((end.timeIntervalSince(now) / 60).rounded())
        guard minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes) min left" }
        return "\(minutes / 60) hr " + (minutes % 60 > 0 ? "\(minutes % 60) min " : "") + "left"
    }
}

/// Starting this channel would need a stream and every one is in use.
public struct LiveTVStreamsConflict: LocalizedError, Sendable {
    public let blocked: LiveTVStreams.Blocked
    public var errorDescription: String? { blocked.text + " " + blocked.hint }
}

public extension JellyfinClient {
    /// Through the Zorofin plugin's companion route. Fails when the module is missing.
    func liveTVStreams(channelID: String? = nil) async throws -> LiveTVStreams {
        var query = [URLQueryItem(name: "deviceId", value: identity.deviceID)]
        if let channelID { query.append(.init(name: "channelId", value: channelID)) }
        let data = try await requestData(["Zorofin", "Companion", "liveTvStreams", "status"], query: query,
                                         extensionToken: true, expectedStatus: 200)
        guard let status = try? JSONDecoder().decode(LiveTVStreams.self, from: data),
              status.version == 1, status.limit > 0, status.limit <= 1000, status.inUse >= 0, status.free >= 0 else {
            throw ClientError.invalidResponse
        }
        return status
    }

    /// Checks before opening a tuner. Prefers the companion's stream status, which
    /// names the channel in use; falls back to the older availability check.
    /// Missing or failing optional services leave native playback alone.
    func checkLiveTVCapacity(channelID: String, features: ServerFeatures) async throws {
        guard features.liveTvStreams else {
            try await checkLiveTVCapacity(channelID: channelID, enabled: features.liveTVAvailability)
            return
        }
        do {
            let status = try await liveTVStreams(channelID: channelID)
            try Task.checkCancellation()
            if let blocked = status.blocked(channelID: channelID) { throw LiveTVStreamsConflict(blocked: blocked) }
        } catch is CancellationError { throw CancellationError() }
        catch let conflict as LiveTVStreamsConflict { throw conflict }
        catch { try Task.checkCancellation() }
    }
}
