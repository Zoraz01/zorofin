import Foundation

/// What a player tells the server went wrong (plugin capability
/// "playbackReports" version 1). The raw values are the server's contract.
public enum PlaybackProblem: String, Sendable, Encodable {
    case startFailed = "start_failed", stopped, fallback, stalled
    case qualityLowered = "quality_lowered", recovered, slowStart = "slow_start", appError = "app_error"
}

/// One report. The server adds the viewer and the time; nothing here names an account.
public struct PlaybackProblemReport: Encodable, Sendable, Equatable {
    public var kind: PlaybackProblem
    public var itemId: String
    public var title: String
    public var platform: String
    public var appVersion: String
    public var device: String
    public var method: String
    public var reason: String
    public var startMs: Int?
    public var positionSeconds: Int?

    public init(kind: PlaybackProblem, item: MediaItem, platform: String, identity: ClientIdentity,
                method: String = "", reason: String = "", startMs: Int? = nil, positionSeconds: Int? = nil) {
        self.kind = kind; itemId = item.id
        title = item.isEpisode ? [item.seriesName, item.name].compactMap { $0 }.joined(separator: ": ") : item.name
        self.platform = platform; appVersion = identity.version; device = identity.deviceName
        self.method = method; self.reason = String(reason.prefix(300))
        self.startMs = startMs.map { max(0, $0) }; self.positionSeconds = positionSeconds.map { max(0, $0) }
    }

    /// Jellyfin's play method as the report's short word.
    public static func method(_ playMethod: String?, isLive: Bool, onDevice: Bool = false) -> String {
        if isLive { return "live" }
        if onDevice { return "on-device" }
        switch playMethod {
        case "DirectPlay": return "direct"
        case "DirectStream": return "remux"
        case "Transcode": return "transcode"
        default: return ""
        }
    }

    public static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

/// Sends playback problems to the viewer's own server, and only there.
///
/// Callers check the server's capability and the viewer's own switch first.
/// Sending never throws, never blocks playback, and stops for the rest of
/// this run of the app once the server says it is not collecting.
public actor PlaybackProblemLog {
    public static let shared = PlaybackProblemLog()
    /// A player in a failure loop must not flood the server.
    public static let maxPerSession = 30
    private var sent = 0
    private var refused = false

    public init() {}

    public func send(_ report: PlaybackProblemReport, client: JellyfinClient) async {
        guard !refused, sent < Self.maxPerSession, client.session != nil,
              let body = try? JSONEncoder().encode(report) else { return }
        sent += 1
        do {
            _ = try await client.requestData(["Zorofin", "PlaybackReports"], method: "POST", body: body,
                                             extensionToken: true, requestTimeout: 10)
        } catch ClientError.unavailable(let status) where status == 404 || status == 429 {
            // 404: the owner switched collection off since sign-in. 429: enough.
            refused = true
        } catch {
            // A report is never worth interrupting the viewer for.
        }
    }
}
