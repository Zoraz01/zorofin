import Foundation
import Testing
@testable import ZorofinCore

@Suite struct ReviewPromptTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func noPromptOnFirstUseShortPlaybackOrFailure() {
        var policy = ReviewPromptPolicy(firstUse: start)
        for _ in 0..<10 {
            policy.recordPlayback(activeSeconds: 299, failed: false)
            policy.recordPlayback(activeSeconds: 600, failed: true)
            policy.recordPlayback(activeSeconds: .infinity, failed: false)
        }
        let opportunity1 = policy.takeOpportunity(version: "1.2", now: start.addingTimeInterval(8 * 86_400))
        #expect(!opportunity1)
        for _ in 0..<3 { policy.recordPlayback(activeSeconds: 300, failed: false) }
        let opportunity2 = policy.takeOpportunity(version: "1.2", now: start.addingTimeInterval(6 * 86_400))
        #expect(!opportunity2)
        let opportunity3 = policy.takeOpportunity(version: "1.2", now: start.addingTimeInterval(7 * 86_400))
        #expect(opportunity3)
        let opportunity4 = policy.takeOpportunity(version: "1.2", now: start.addingTimeInterval(7 * 86_400))
        #expect(!opportunity4)
    }

    @Test func persistenceVersionAndCooldownPreventRepeatedPrompts() throws {
        var policy = ReviewPromptPolicy(firstUse: start)
        for _ in 0..<3 { policy.recordPlayback(activeSeconds: 300, failed: false) }
        let firstRequest = start.addingTimeInterval(7 * 86_400)
        let opportunity5 = policy.takeOpportunity(version: "1.2", now: firstRequest)
        #expect(opportunity5)
        policy = try JSONDecoder().decode(ReviewPromptPolicy.self, from: JSONEncoder().encode(policy))
        for _ in 0..<3 { policy.recordPlayback(activeSeconds: 300, failed: false) }
        let opportunity6 = policy.takeOpportunity(version: "1.3", now: firstRequest.addingTimeInterval(119 * 86_400))
        #expect(!opportunity6)
        let opportunity7 = policy.takeOpportunity(version: "1.2", now: firstRequest.addingTimeInterval(120 * 86_400))
        #expect(!opportunity7)
        let opportunity8 = policy.takeOpportunity(version: "1.3", now: firstRequest.addingTimeInterval(120 * 86_400))
        #expect(opportunity8)
        let opportunity9 = policy.takeOpportunity(version: "1.4", now: firstRequest.addingTimeInterval(240 * 86_400))
        #expect(!opportunity9)
    }
}
