import Testing

@testable import ZorofinCore

@Suite("Automatic quality") struct AdaptiveQualityTests {
  @Test func bufferingStepsBelowSourceRateAndThenCoolsDown() {
    var policy = AdaptiveQuality(ceiling: 40_000_000)
    var change: Int?
    for t in 0..<20 {
      let next = policy.sample(
        now: Double(t), position: 10, bitrate: 40_000_000, enabled: true,
        ready: true, paused: false, seeking: false, buffering: true, sourceBitrate: 17_000_000)
      if let next { change = next }
    }
    #expect(change == 12_000_000)
    for t in 20..<40 {
      #expect(
        policy.sample(
          now: Double(t), position: 10, bitrate: 12_000_000, enabled: true,
          ready: true, paused: false, seeking: false, buffering: true) == nil)
    }
  }
  @Test func pausedAndManualPlaybackNeverAdapt() {
    for mode in 0..<5 {
      var policy = AdaptiveQuality(ceiling: 40_000_000)
      for t in 0..<100 {
        #expect(
          policy.sample(
            now: Double(t), position: 10, bitrate: 40_000_000,
            enabled: mode != 0 && mode != 4, ready: mode != 1, paused: mode == 2,
            seeking: mode == 3, buffering: true) == nil)
      }
    }
  }
  @Test func smoothPlaybackAndFullBufferNeverRaiseQuality() {
    var policy = AdaptiveQuality(ceiling: 40_000_000)
    for t in 0..<1800 {
      #expect(
        policy.sample(
          now: Double(t), position: Double(t), bitrate: 12_000_000,
          enabled: true, ready: true, paused: false, seeking: false, buffering: false,
          bufferedAhead: 120) == nil)
    }
    #expect(
      policy.sample(
        now: 1800, position: 1800, bitrate: 12_000_000, enabled: true,
        ready: true, paused: false, seeking: false, buffering: false, bufferedAhead: 30)
        == nil)
  }
  @Test func onlyDescendsAndHoldsItsFloorThroughSmoothPlayback() {
    var policy = AdaptiveQuality(ceiling: 40_000_000)
    var bitrate = 40_000_000
    for t in 0..<2000 {
      let next = policy.sample(
        now: Double(t), position: 10, bitrate: bitrate,
        enabled: true, ready: true, paused: false, seeking: false,
        buffering: t < 200, bufferedAhead: t < 200 ? 0 : 120, sourceBitrate: 17_000_000)
      if let next {
        #expect(next < bitrate)
        bitrate = next
      }
    }
    #expect(bitrate == 2_000_000)
    #expect(policy.reason == "Reduced after buffering")
  }

}
