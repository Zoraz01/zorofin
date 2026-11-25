import Foundation

/// Same downward-only single-stream policy as the shared TV core. The app reconnects
/// at the same position when a decision changes bitrate.
public struct AdaptiveQuality: Sendable {
  public let ceiling: Int
  public private(set) var reason: String?
  public static let ladder = [2, 4, 8, 12, 20, 40, 60, 80, 120].map { $0 * 1_000_000 }
  private var last: Double?, position: Double?
  private var grace = 10.0, stall = 0.0, cooldown = 0.0
  private var counted = false
  private var stalls: [Double] = []
  public init(ceiling: Int) { self.ceiling = ceiling }
  public mutating func sample(
    now: Double, position: Double, bitrate: Int,
    enabled: Bool, ready: Bool, paused: Bool, seeking: Bool, buffering: Bool,
    bufferedAhead: Double = 0, sourceBitrate: Int? = nil
  ) -> Int? {
    guard now.isFinite, position.isFinite else { return nil }
    let elapsed = last.map { min(3, max(0, now - $0)) } ?? 0
    let jumped = self.position.map { abs(position - $0) > elapsed * 3 + 3 } ?? false
    last = now
    self.position = position
    guard enabled, ready, !paused, !seeking, !jumped else {
      stall = 0
      counted = false
      stalls = []
      grace = 10
      return nil
    }
    if grace > 0 {
      grace -= elapsed
      return nil
    }
    stalls.removeAll { now - $0 > 60 }
    if buffering {
      stall += elapsed
      if stall >= 2 && !counted {
        stalls.append(now)
        counted = true
      }
      if now >= cooldown && (stall >= 6 || stalls.count >= 2) {
        let source = sourceBitrate.flatMap { $0 > 0 ? $0 : nil } ?? bitrate
        let target = Double(min(source, bitrate)) * 0.8
        if let next = Self.ladder.last(where: {
          $0 < bitrate && Double($0) <= target && $0 <= ceiling
        }) {
          changed(now)
          reason = "Reduced after buffering"
          return next
        }
      }
    } else {
      stall = 0
      counted = false

    }
    return nil
  }
  private mutating func changed(_ now: Double) {
    stall = 0
    counted = false
    stalls = []
    cooldown = now + 45
    grace = 10
  }
}
