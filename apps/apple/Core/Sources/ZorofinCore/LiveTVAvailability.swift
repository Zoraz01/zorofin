import Foundation

/// Viewer-safe status only. No other viewer, channel title or upstream address.
public struct LiveTVAvailability: Decodable, Sendable, Equatable {
    public enum State: String, Decodable, Sendable { case available, busy, unknown }
    public let limit: Int
    public let state: State
    public let sameChannel: Bool
    public let differentChannel: Bool
    public let ownStream: Bool

    public var blocksPlayback: Bool {
        state == .busy && differentChannel && !sameChannel && !ownStream
    }
    public var policy: String {
        limit == 1 ? "Live TV supports one channel at a time. Multiple people can watch the same channel. A different channel must wait."
            : "Live TV has a shared limit of \(limit) channels at a time."
    }
    public var message: String {
        if sameChannel { return "This channel is already playing. You can join it." }
        if ownStream { return "You can switch channels on this device." }
        if state == .busy { return "Live TV is in use. A different channel must wait until the current connection is free." }
        if state == .available { return "Live TV is available." }
        return "Live TV availability could not be checked."
    }
}

public struct LiveTVCapacityError: LocalizedError, Sendable {
    public let status: LiveTVAvailability
    public var errorDescription: String? { status.message + " " + status.policy }
}

public extension JellyfinClient {
    func liveTVAvailability(channelID: String? = nil) async throws -> LiveTVAvailability {
        var query = [URLQueryItem(name: "deviceId", value: identity.deviceID)]
        if let channelID { query.append(.init(name: "channelId", value: channelID)) }
        let data = try await requestData(["support", "live-tv", "status"], query: query,
                                         extensionToken: true, expectedStatus: 200)
        guard let status = try? JSONDecoder().decode(LiveTVAvailability.self, from: data),
              status.limit > 0, status.limit <= 1000,
              !(status.sameChannel && status.differentChannel),
              !(status.state != .busy && (status.sameChannel || status.differentChannel || status.ownStream)) else {
            throw ClientError.invalidResponse
        }
        return status
    }

    /// A fresh conflict blocks before opening a tuner. Missing/unavailable optional
    /// services retain native playback; cancellation must never start playback.
    func checkLiveTVCapacity(channelID: String, enabled: Bool) async throws {
        guard enabled else { return }
        do {
            let status = try await liveTVAvailability(channelID: channelID)
            try Task.checkCancellation()
            if status.blocksPlayback { throw LiveTVCapacityError(status: status) }
        } catch is CancellationError { throw CancellationError() }
        catch let conflict as LiveTVCapacityError { throw conflict }
        catch { try Task.checkCancellation() }
    }
}
