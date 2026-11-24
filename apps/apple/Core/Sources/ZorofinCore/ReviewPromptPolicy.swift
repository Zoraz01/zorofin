import Foundation

/// Device-local pacing only. No account, server, title, or rating is recorded.
public struct ReviewPromptPolicy: Codable, Equatable, Sendable {
    public let firstUse: Date
    public private(set) var successfulSessions = 0
    public private(set) var lastRequestedVersion: String?
    public private(set) var lastRequestedAt: Date?

    public init(firstUse: Date = .now) { self.firstUse = firstUse }

    public mutating func recordPlayback(activeSeconds: TimeInterval, failed: Bool) {
        guard !failed, activeSeconds.isFinite, activeSeconds >= 300 else { return }
        successfulSessions = min(3, successfulSessions + 1)
    }

    /// A request is not evidence that Apple displayed a prompt or a user rated.
    public mutating func takeOpportunity(version: String, now: Date = .now) -> Bool {
        guard !version.isEmpty, successfulSessions >= 3,
              now.timeIntervalSince(firstUse) >= 7 * 86_400,
              lastRequestedVersion != version,
              lastRequestedAt.map({ now.timeIntervalSince($0) >= 120 * 86_400 }) ?? true else { return false }
        lastRequestedVersion = version
        lastRequestedAt = now
        successfulSessions = 0
        return true
    }
}
