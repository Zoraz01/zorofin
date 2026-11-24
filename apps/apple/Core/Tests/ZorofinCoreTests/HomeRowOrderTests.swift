import Testing
@testable import ZorofinCore

@Suite("Weighted Home row order") struct HomeRowOrderTests {
    private let candidates: [HomeRowOrder.Candidate] = [
        .init(id: "new-episodes", kind: .deliberate), .init(id: "showcase", kind: .deliberate),
        .init(id: "curated", kind: .deliberate), .init(id: "shelf-2", kind: .deliberate),
        .init(id: "discovery-1", kind: .generated), .init(id: "discovery-2", kind: .generated)
    ]
    @Test func priorityRowsNeverEnterShuffleAndCandidatesAppearOnce() {
        #expect(HomeRowOrder.pinnedIDs == ["shelf-0", "requests-ready", "sports-live-events"])
        var order = HomeRowOrder(seed: 42)
        let pinned = HomeRowOrder.pinnedIDs.map { HomeRowOrder.Candidate(id: $0, kind: .generated) }
        order.append(pinned + candidates + candidates + [.init(id: "", kind: .deliberate)])
        #expect(Set(order.ids) == Set(candidates.map(\.id)))
        #expect(order.ids.count == candidates.count)
    }
    @Test func metadataRefreshAndPaginationNeverReshuffleExistingRows() {
        var order = HomeRowOrder(seed: 2)
        order.append(candidates)
        let first = order.ids
        order.append(Array(candidates.reversed()))
        #expect(order.ids == first)
        order.append(candidates + [.init(id: "discovery-3", kind: .generated), .init(id: "sports", kind: .deliberate)])
        #expect(Array(order.ids.prefix(first.count)) == first)
        #expect(Set(order.ids.suffix(2)) == ["discovery-3", "sports"])
        // Missing / temporarily empty rows retain their slot when content returns.
        order.append([candidates[0]])
        #expect(order.ids.count == first.count + 2)
    }
    @Test func seededVisitsAreReproducibleAndNewVisitsVary() {
        var first = HomeRowOrder(seed: 21), same = HomeRowOrder(seed: 21), other = HomeRowOrder(seed: 55)
        first.append(candidates); same.append(candidates); other.append(candidates)
        #expect(first.ids == same.ids)
        #expect(first.ids != other.ids)
    }
    @Test func deliberateRowsWinRoughlyThreeOfFourPairwiseDraws() {
        var wins = 0
        for seed in UInt64(0)..<512 {
            var order = HomeRowOrder(seed: seed)
            order.append([.init(id: "deliberate", kind: .deliberate), .init(id: "generated", kind: .generated)])
            if order.ids.first == "deliberate" { wins += 1 }
        }
        // Fixed seeds make this deterministic; both outcomes must remain possible.
        #expect((340...425).contains(wins))
    }
    @Test func genericServersCanOrderGeneratedRowsWithoutDeliberateCandidates() {
        var order = HomeRowOrder(seed: 3)
        order.append(candidates.filter { $0.kind == .generated })
        #expect(Set(order.ids) == ["discovery-1", "discovery-2"])
    }
}
