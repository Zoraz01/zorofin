import Foundation

/// Weighted random order for the unpinned part of Home. A retained instance keeps
/// already-published rows still while pages, artwork and metadata refresh.
public struct HomeRowOrder: Sendable {
    public enum Kind: Sendable { case deliberate, generated }
    public struct Candidate: Sendable {
        public let id: String
        public let kind: Kind
        public init(id: String, kind: Kind) { self.id = id; self.kind = kind }
    }
    public static let pinnedIDs = ["shelf-0", "requests-ready", "sports-live-events"]
    public private(set) var ids: [String] = []
    private var seen: Set<String> = Set(pinnedIDs)
    private var random: HomeRandom
    public init(seed: UInt64 = .random(in: .min ... .max)) { random = HomeRandom(seed: seed) }

    /// Each deliberate candidate has three tickets; a generated one has one.
    /// Sample without replacement, so the boost never duplicates a row.
    public mutating func append(_ candidates: [Candidate]) {
        var pending = candidates.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        while !pending.isEmpty {
            let total = pending.reduce(0) { $0 + ($1.kind == .deliberate ? 3 : 1) }
            var ticket = Int.random(in: 0..<total, using: &random)
            var selected = 0
            for (index, candidate) in pending.enumerated() {
                ticket -= candidate.kind == .deliberate ? 3 : 1
                if ticket < 0 { selected = index; break }
            }
            ids.append(pending.remove(at: selected).id)
        }
    }
}

/// Small reproducible generator for per-visit layout decisions, never security.
struct HomeRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
