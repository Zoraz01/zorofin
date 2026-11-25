import Foundation

/// Features are scoped to the connected server and authenticated viewer.
public struct ServerFeatures: Sendable, Equatable {
    /// Fictional preview only. Real connections always discover their own capabilities.
    public static let preview = ServerFeatures(support: true, notifications: true, requests: true, homeRows: true,
        liveArtwork: true, enhancedSettings: true, accountApprovals: true, notificationSettings: true)
    public var support: Bool
    public var notifications: Bool
    public var requests: Bool
    public var homeRowsContract: HomeRowsContract?
    public var homeRows: Bool { homeRowsContract != nil }
    public var liveArtwork: Bool
    public var enhancedSettings: Bool
    public var accountApprovals: Bool
    public var notificationSettings: Bool
    public var liveTVAvailability: Bool
    /// The companion's liveTvStreams module: which channels are using the Live TV streams.
    public var notificationReads: Bool
    public var sportsEvents: Bool
    public var liveTvStreams: Bool
    /// The companion's pickTogether module (schemaVersion 1): group swiping.
    public var pickTogether: Bool
    /// The plugin collects playback problem reports (version 1). Absent when
    /// the owner switched collection off; the app then sends nothing.
    public var playbackReports: Bool
    public init(support: Bool = false, notifications: Bool = false, requests: Bool = false, homeRows: Bool = false,
                homeRowsContract: HomeRowsContract? = nil, liveArtwork: Bool = false, enhancedSettings: Bool = false, accountApprovals: Bool = false,
                notificationSettings: Bool = false, liveTVAvailability: Bool = false, liveTvStreams: Bool = false, sportsEvents: Bool = false, notificationReads: Bool = false, pickTogether: Bool = false, playbackReports: Bool = false) {
        self.support = support; self.notifications = notifications; self.requests = requests; self.homeRowsContract = homeRowsContract ?? (homeRows ? .legacy : nil)
        self.liveArtwork = liveArtwork; self.enhancedSettings = enhancedSettings
        self.accountApprovals = accountApprovals; self.notificationSettings = notificationSettings
        self.liveTVAvailability = liveTVAvailability
        self.liveTvStreams = liveTvStreams; self.sportsEvents = sportsEvents; self.notificationReads = notificationReads
        self.pickTogether = pickTogether; self.playbackReports = playbackReports
    }
}

public struct FeatureDiscovery: Sendable {
    public let features: ServerFeatures
    public let needsRetry: Bool
}

public struct SupportReply: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let status: String
    public let issueType: String
    public let affectedMedia: String?
    public let message: String
    public let updatedAt: String
    public init(id: String, status: String, issueType: String, affectedMedia: String? = nil,
                message: String, updatedAt: String) {
        self.id = id; self.status = status; self.issueType = issueType
        self.affectedMedia = affectedMedia; self.message = message; self.updatedAt = updatedAt
    }
}

public struct SupportReport: Encodable, Sendable {
    public let issueType: String
    public let description: String
    public let affectedMedia: String
    public init(issueType: String, description: String, affectedMedia: String = "") {
        self.issueType = issueType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        self.affectedMedia = affectedMedia.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var isValid: Bool {
        !issueType.isEmpty && issueType.utf16.count <= 64 && !description.isEmpty &&
        description.utf16.count <= 1500 && affectedMedia.utf16.count <= 200
    }
}

public enum SupportError: LocalizedError, Sendable, Equatable {
    case invalidReport, rejected, outcomeUnknown
    public var errorDescription: String? {
        switch self {
        case .invalidReport: "Choose an issue and add a description of up to 1,500 characters. The title field allows 200 characters."
        case .rejected: "The server did not accept this report. Check your connection and account access before trying again."
        case .outcomeUnknown: "Delivery could not be confirmed. Your report may have arrived. Check Notifications or contact your server owner before sending it again."
        }
    }
}

private struct CapabilityManifest: Decodable {
    struct Feature: Decodable { let version: Int; let enabled: Bool }
    let schemaVersion: Int
    let features: [String: Feature]
    func supports(_ name: String) -> Bool { features[name]?.version == 1 && features[name]?.enabled == true }
    var homeRowsContract: HomeRowsContract? {
        guard let feature = features["homeRows"], feature.enabled else { return nil }
        return HomeRowsContract(rawValue: feature.version)
    }
    /// Requests v1 is the legacy proxy; v2 is the Zorofin plugin.
    var requestRoutes: RequestRoutes? {
        guard let feature = features["requests"], feature.enabled else { return nil }
        return RequestRoutes(manifestVersion: feature.version)
    }
}
private struct ReplyEnvelope: Decodable { let notifications: [SupportReply] }
private struct TicketReceipt: Decodable { let ticketId: String }

private func validTicketID(_ id: String) -> Bool {
    id.range(of: "^T[a-z0-9]{6,20}$", options: .regularExpression) == id.startIndex..<id.endIndex
}

extension JellyfinClient {
    /// Discover only from the server the viewer chose, after sign-in. No bundled server directory.
    public func discoverFeatures() async throws -> FeatureDiscovery {
        guard let session else { throw ClientError.missingSession }
        guard session.server == server else { throw ClientError.unsafeURL }
        // The support adapter implements the same manifest for existing installations.
        // Only a missing route tries the adapter; denied or malformed manifests fail closed.
        for path in [["Zorofin", "Capabilities"], ["support", "capabilities"]] {
            do {
                let data = try await requestData(path, extensionToken: true, expectedStatus: 200)
                guard let manifest = try? JSONDecoder().decode(CapabilityManifest.self, from: data),
                      manifest.schemaVersion == 1 else { throw ClientError.invalidResponse }
                let routes = manifest.requestRoutes
                RequestRoutes.remember(routes, server: server, viewer: session.viewer.id)
                return FeatureDiscovery(features: .init(support: manifest.supports("support"),
                    notifications: manifest.supports("notifications"), requests: routes != nil,
                    homeRowsContract: manifest.homeRowsContract, liveArtwork: manifest.supports("liveArtwork"),
                    enhancedSettings: manifest.supports("enhancedSettings"), accountApprovals: manifest.supports("accountApprovals"),
                    notificationSettings: manifest.supports("notificationSettings"),
                    liveTVAvailability: manifest.supports("liveTVAvailability"),
                    liveTvStreams: manifest.supports("liveTvStreams"), sportsEvents: manifest.supports("sportsEvents"), notificationReads: manifest.supports("notificationReads"),
                    pickTogether: manifest.supports("pickTogether"), playbackReports: manifest.supports("playbackReports")), needsRetry: false)
            } catch ClientError.unavailable(404) { continue }
        }
        RequestRoutes.remember(nil, server: server, viewer: session.viewer.id)
        return FeatureDiscovery(features: .init(), needsRetry: false)
    }

    public func supportReplies() async throws -> [SupportReply] {
        let data = try await requestData(["support", "notifications"], extensionToken: true, expectedStatus: 200)
        guard let envelope = try? JSONDecoder().decode(ReplyEnvelope.self, from: data),
              envelope.notifications.allSatisfy({ validTicketID($0.id) }),
              Set(envelope.notifications.map(\.id)).count == envelope.notifications.count else {
            throw ClientError.invalidResponse
        }
        return envelope.notifications
    }

    public func markSupportReplyRead(_ id: String) async throws {
        guard validTicketID(id) else { throw ClientError.unsafeURL }
        _ = try await requestData(["support", "notifications", id, "read"], method: "POST",
                                  extensionToken: true, expectedStatus: 204)
    }

    /// One POST only: a lost receipt must never silently create a duplicate ticket.
    public func submitSupport(_ report: SupportReport) async throws -> String {
        guard report.isValid else { throw SupportError.invalidReport }
        do {
            let data = try await requestData(["support", "ticket"], method: "POST",
                body: JSONEncoder().encode(report), extensionToken: true, expectedStatus: 202)
            guard let receipt = try? JSONDecoder().decode(TicketReceipt.self, from: data),
                  validTicketID(receipt.ticketId) else { throw SupportError.outcomeUnknown }
            return receipt.ticketId
        } catch ClientError.unauthorized { throw SupportError.rejected }
        catch ClientError.forbidden { throw SupportError.rejected }
        catch ClientError.unavailable(let status) where [400, 404, 413, 429].contains(status) {
            throw SupportError.rejected
        } catch { throw SupportError.outcomeUnknown }
    }
}
