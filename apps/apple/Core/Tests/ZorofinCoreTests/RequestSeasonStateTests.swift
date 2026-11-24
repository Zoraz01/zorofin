import Foundation
import Testing
@testable import ZorofinCore

struct RequestSeasonStateTests {
    private func title(_ media: String) throws -> RequestTitle {
        try JSONDecoder().decode(RequestTitle.self, from: Data(("{\"id\":20,\"mediaType\":\"tv\",\"name\":\"Example\",\"seasons\":[{\"seasonNumber\":1,\"episodeCount\":8},{\"seasonNumber\":2,\"episodeCount\":8}],\"mediaInfo\":" + media + "}").utf8))
    }
    @Test func separatesAvailabilityFromApprovalAndMissingEpisodes() throws {
        let value = try title(#"{"status":4,"seasons":[{"seasonNumber":1,"status":5},{"seasonNumber":2,"status":4}]}"#)
        #expect(value.requestSeasonState(1) == .available)
        #expect(value.requestSeasonState(2) == .partlyAvailable)
        #expect(value.eligibleSeasons(is4K: false).map(\.seasonNumber) == [2])
        let pending = try title(#"{"seasons":[{"seasonNumber":1,"status":2},{"seasonNumber":2,"status":3}]}"#)
        #expect(pending.requestSeasonState(1) == .pendingApproval)
        #expect(pending.requestSeasonState(2) == .requested)
        #expect(pending.eligibleSeasons(is4K: false).isEmpty)
    }
    @Test func receiptBlocksSelectionWithoutImplyingAvailability() throws {
        let value = try title(#"{"requests":[{"id":5,"status":1,"seasons":[{"seasonNumber":2}]}]}"#)
        #expect(value.requestSeasonState(1) == .missing)
        #expect(value.requestSeasonState(2) == .pendingApproval)
        #expect(!value.seasonBlocked(1, is4K: false))
        #expect(value.seasonBlocked(2, is4K: false))
    }
    @Test func existingHighQualityVersionDoesNotOfferAnotherRequest() throws {
        let value = try title(#"{"seasons":[{"seasonNumber":1,"status":1,"status4k":5},{"seasonNumber":2,"status":1,"status4k":2}]}"#)
        #expect(value.requestSeasonState(1) == .available)
        #expect(value.requestSeasonState(2) == .pendingApproval)
        #expect(value.seasonState(1) == .missing)
    }
    @Test func unknownStateDoesNotInventAvailableSeasons() throws {
        let value = try title(#"{"status":5}"#)
        #expect(value.requestSeasonState(1) == .unknown)
        #expect(value.seasonBlocked(1, is4K: false))
        let future = try title(#"{"seasons":[{"seasonNumber":1,"status":99}]}"#)
        #expect(future.requestSeasonState(1) == .unknown)
    }
    @Test func requestDefaultsToOneServerManagedType() throws {
        let intent = RequestIntent(kind: .tv, id: 20, seasons: [2])
        let data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(intent)) as? [String: Any]
        #expect(data?["is4k"] as? Bool == false)
        #expect(data?["seasons"] as? [Int] == [2])
    }
}
