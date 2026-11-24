import Foundation

/// Keep one pending progress sample during an outage and serialize all events.
/// Actor reentrancy must not let a progress request overtake the final stop.
public actor PlaybackReporter {
    private struct Event: Sendable {
        let kind: String
        let payload: [String: JSONValue]
    }
    private let client: JellyfinClient
    private let plan: PlaybackPlan
    private var pending: [Event] = []
    private var worker: Task<Void, Never>?
    private var started = false
    private var stopped = false
    public private(set) var failureCount = 0
    public private(set) var liveStreamCloseFailed = false
    private var closeRetry: Task<Bool, Never>?

    public init(client: JellyfinClient, plan: PlaybackPlan) { self.client = client; self.plan = plan }
    public func start(positionTicks: Int64, canSeek: Bool) {
        guard !started, !stopped else { return }
        started = true
        enqueue("start", payload: plan.report(positionTicks: positionTicks, paused: false, canSeek: canSeek))
    }
    public func progress(positionTicks: Int64, paused: Bool, canSeek: Bool) {
        guard started, !stopped else { return }
        pending.removeAll { $0.kind == "progress" }
        enqueue("progress", payload: plan.report(positionTicks: positionTicks, paused: paused, canSeek: canSeek))
    }
    public func stop(positionTicks: Int64, failed: Bool = false) async {
        guard !stopped else { await worker?.value; return }
        stopped = true
        if started {
            var payload = plan.report(positionTicks: positionTicks, paused: true, canSeek: false)
            payload["Failed"] = .bool(failed)
            enqueue("stop", payload: payload)
        }
        if plan.requiresClosing, plan.liveStreamID != nil { enqueue("close", payload: [:]) }
        // A failed or abandoned start never reports Stopped, so the server keeps
        // transcoding until its own kill timer (about a minute). Retries then
        // compete with those orphaned jobs. End this play session's encode now.
        if plan.method == "Transcode", plan.liveStreamID == nil { enqueue("endEncoding", payload: [:]) }
        await worker?.value
    }
    /// Only an explicit channel/reconnect action retries cleanup; never open a
    /// replacement tuner until this returns true. Concurrent callers share one try.
    public func retryLiveCleanup() async -> Bool {
        guard stopped else { return false }
        await worker?.value
        if let closeRetry { return await closeRetry.value }
        guard liveStreamCloseFailed else { return true }
        let retry = Task { () -> Bool in
            enqueue("close", payload: [:])
            await worker?.value
            return !liveStreamCloseFailed
        }
        closeRetry = retry
        let success = await retry.value
        closeRetry = nil
        return success
    }
    public func flush() async { await worker?.value }
    private func enqueue(_ kind: String, payload: [String: JSONValue]) {
        pending.append(Event(kind: kind, payload: payload))
        if worker == nil { worker = Task { await drain() } }
    }
    private func drain() async {
        while !pending.isEmpty {
            let event = pending.removeFirst()
            do {
                if event.kind == "close", let stream = plan.liveStreamID {
                    try await client.closeLive(stream)
                    liveStreamCloseFailed = false
                }
                else if event.kind == "endEncoding" { try await client.stopEncoding(playSessionID: plan.sessionID) }
                else { try await client.reportPlayback(event.kind, payload: event.payload) }
            } catch { failureCount += 1; if event.kind == "close" { liveStreamCloseFailed = true } }
        }
        worker = nil
    }
}
