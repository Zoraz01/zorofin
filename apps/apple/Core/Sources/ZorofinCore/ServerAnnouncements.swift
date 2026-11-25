import Foundation
import CryptoKit

/// Announcements adapt to the existing inbox/history row format, with a distinct
/// ID namespace. They are never acknowledged through the support-ticket API.
extension SupportReply {
    public var isAnnouncement: Bool { id.hasPrefix("announcement:") }
    public var sourceLabel: String { isAnnouncement ? "Server announcement" : "Support reply" }
}

public struct ServerInbox: Sendable {
    public let replies: [SupportReply]?
    public let announcements: [SupportReply]?
    public var partial: Bool { replies == nil || announcements == nil }
    public func keeping(_ previous: [SupportReply]) -> [SupportReply] {
        (announcements ?? previous.filter(\.isAnnouncement)) +
        (replies ?? previous.filter { !$0.isAnnouncement })
    }
}

public struct ServerAnnouncement: Decodable, Sendable {
    public let enabled: Bool
    public let id: String?
    public let title: String?
    public let message: String?
    public let startAt: String?
    public let endAt: String?

    public func inboxMessage(now: Date = Date()) throws -> SupportReply? {
        guard enabled else { return nil }
        guard let id, id.range(of: "^[A-Za-z0-9._-]{1,80}$", options: .regularExpression) != nil,
              let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 80,
              let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.utf16.count <= 320
        else { throw ClientError.invalidResponse }
        func date(_ value: String?) throws -> Date? {
            guard let value, !value.isEmpty else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: value) { return parsed }
            formatter.formatOptions = [.withInternetDateTime]
            guard let parsed = formatter.date(from: value) else { throw ClientError.invalidResponse }
            return parsed
        }
        let start = try date(startAt), end = try date(endAt)
        if let start, now < start { return nil }
        if let end, now >= end { return nil }
        // Title is part of the stable identity so an edited headline becomes unread.
        return SupportReply(id: "announcement:\(id)-\(SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined())", status: "Server announcement",
                            issueType: title, message: message, updatedAt: startAt ?? "")
    }
}

extension JellyfinClient {
    public func serverAnnouncements() async throws -> [SupportReply] {
        do {
            let data = try await requestData(["support", "announcement", "me"], extensionToken: true, expectedStatus: 200)
            guard let payload = try? JSONDecoder().decode(ServerAnnouncement.self, from: data) else { throw ClientError.invalidResponse }
            return try payload.inboxMessage().map { [$0] } ?? []
        } catch ClientError.unavailable(404) { return [] }
    }

    public func inboxMessages() async throws -> ServerInbox {
        func source(_ fetch: () async throws -> [SupportReply]) async throws -> [SupportReply]? {
            do { return try await fetch() }
            catch is CancellationError { throw CancellationError() }
            catch ClientError.unauthorized { throw ClientError.unauthorized }
            catch ClientError.forbidden { throw ClientError.forbidden }
            catch { return nil }
        }
        async let replies = source { try await self.supportReplies() }
        async let announcements = source { try await self.serverAnnouncements() }
        return try await ServerInbox(replies: replies, announcements: announcements)
    }
}
