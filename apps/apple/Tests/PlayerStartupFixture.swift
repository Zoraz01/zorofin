import Foundation
import Network
import XCTest
import ZorofinCore

struct PlayerReplayProfile: Codable, Sendable {
    let durationSeconds: Double
    let resumeSeconds: Double
    let width: Int
    let height: Int
    let frameRateNumerator: Int
    let frameRateDenominator: Int
    let audioSampleRate: Int
    let audioChannels: Int
    let audioStreamIndex: Int
    let subtitleStreamIndex: Int
    var resumeSegment: String {
        let duration = 96 * Double(frameRateDenominator) / Double(frameRateNumerator)
        return String(format: "/segment-%05d.ts", Int((resumeSeconds / duration + 0.000001).rounded(.down)))
    }
    static func load() throws -> (URL, PlayerReplayProfile) {
        guard let path = ProcessInfo.processInfo.environment["ZOROFIN_ROTATION_FIXTURE_ROOT"], !path.isEmpty else {
            throw XCTSkip("Generate the synthetic replay fixture and set ZOROFIN_ROTATION_FIXTURE_ROOT; see UITests/README.md")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        return (directory, try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("profile.json"))))
    }
}

/// Test-only, loopback-only HLS origin. Listener and connections belong to one
/// serial queue; stop() synchronously cancels them before the fixture leaves scope.
final class PlayerHLSOrigin: @unchecked Sendable {
    struct RequestEvent: Codable, Sendable {
        let path: String
        let requestedAt: Double
        let held: Bool
        var respondedAt: Double?
        var sendCompletedAt: Double?
        var sendFailed: Bool?
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "player-layout-hls")
    private let resources: [String: Data]
    private var connections: [NWConnection] = []
    private var paths: [String] = []
    private var events: [RequestEvent] = []
    private let heldPaths: Set<String>
    private var releasedPaths: Set<String> = []
    private var pending: [String: [(NWConnection, Data, Int)]] = [:]
    private var stopped = false

    init(bundle: Bundle, directory: URL? = nil, heldPaths: Set<String> = []) throws {
        let folder = try directory ?? XCTFixture.folder(in: bundle)
        self.heldPaths = heldPaths
        resources = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil).filter { ["m3u8", "ts"].contains($0.pathExtension) }
            .map { ("/" + $0.lastPathComponent, try Data(contentsOf: $0)) })
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
    }

    func address() async throws -> ServerAddress {
        for _ in 0..<100 {
            if case .ready = listener.state, let port = listener.port, port.rawValue > 0 {
                return try ServerAddress("http://127.0.0.1:\(port.rawValue)", allowsLocalHTTP: true)
            }
            if case .failed(let error) = listener.state { throw error }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw URLError(.timedOut)
    }

    var requestedPaths: [String] { queue.sync { paths } }
    var requestEvents: [RequestEvent] { queue.sync { events } }
    func isHolding(_ path: String) -> Bool { queue.sync { pending[path]?.isEmpty == false } }

    func release(_ path: String) {
        queue.sync {
            releasedPaths.insert(path)
            for (connection, response, index) in pending.removeValue(forKey: path) ?? [] {
                send(response, to: connection, event: index)
            }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            listener.cancel()
            pending.removeAll()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func send(_ response: Data, to connection: NWConnection, event index: Int) {
        guard !stopped else { connection.cancel(); return }
        events[index].respondedAt = ProcessInfo.processInfo.systemUptime
        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self] error in
                self?.events[index].sendCompletedAt = ProcessInfo.processInfo.systemUptime
                self?.events[index].sendFailed = error != nil
                connection.cancel()
                self?.connections.removeAll { $0 === connection }
            })
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            let request = accumulated + (data ?? Data())
            guard request.count <= 65_536, error == nil else { connection.cancel(); return }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() }
                else { self.receive(connection, accumulated: request) }
                return
            }
            let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
            let firstLine = lines[0]
            let target = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let path = target.components(separatedBy: "?")[0]
            self.paths.append(path) // Deliberately omit query values, including the dummy token.
            let held = self.heldPaths.contains(path) && !self.releasedPaths.contains(path)
            let eventIndex = self.events.count
            self.events.append(.init(path: path, requestedAt: ProcessInfo.processInfo.systemUptime, held: held))
            let resource = self.resources[path] ?? Data()
            var body = resource
            var status = self.resources[path] == nil ? "404 Not Found" : "200 OK"
            var rangeHeader = ""
            if let range = lines.first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
                let bounds = range.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
                if bounds.count == 2, let start = Int(bounds[0]), start >= 0, start < resource.count {
                    let end = min(Int(bounds[1]) ?? (resource.count - 1), resource.count - 1)
                    if end >= start {
                        body = resource.subdata(in: start..<(end + 1))
                        status = "206 Partial Content"
                        rangeHeader = "Content-Range: bytes \(start)-\(end)/\(resource.count)\r\n"
                    }
                }
            }
            let type = path.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : "video/mp2t"
            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\n\(rangeHeader)Connection: close\r\n\r\n"
            let response = Data(header.utf8) + (firstLine.hasPrefix("HEAD ") ? Data() : body)
            if held { self.pending[path, default: []].append((connection, response, eventIndex)) }
            else { self.send(response, to: connection, event: eventIndex) }
        }
    }
}

private enum XCTFixture {
    static func folder(in bundle: Bundle) throws -> URL {
        guard let folder = bundle.url(forResource: "rotation-hls", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return folder
    }
}

/// Only Jellyfin JSON is stubbed. NativePlayerView performs its metadata request,
/// PlaybackController negotiates the plan, and AVPlayer fetches/decodes real HLS.
actor PlayerStartupTransport: HTTPTransport {
    struct NegotiatedOptions: Sendable {
        let startTicks: Int64
        let audioIndex: Int?
        let subtitleIndex: Int?
    }
    private(set) var negotiationStarted = false
    private(set) var requests: [String] = []
    private(set) var negotiatedOptions: [NegotiatedOptions] = []
    private var released: Bool
    private let profile: PlayerReplayProfile?

    init(profile: PlayerReplayProfile? = nil, initiallyReleased: Bool = false) {
        self.profile = profile; released = initiallyReleased
    }

    func allowPlayback() { released = true }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        requests.append(url.path)
        let itemID = profile == nil ? "layout-movie" : "layout-episode"
        let duration = profile?.durationSeconds ?? 60
        // Replay the input DTO separately from the delivered stream: the
        // recorded source is 2160p HEVC/6-channel E-AC-3, while AVPlayer receives
        // the generated 1080p H.264/stereo AAC transcode. Subtitles stay Off.
        let streams: [[String: Any]] = profile.map { value in [
            ["Type": "Video", "Index": 1, "Codec": "hevc", "Profile": "Main 10", "PixelFormat": "yuv420p10le",
             "Width": value.width * 2, "Height": value.height * 2, "VideoRangeType": "DOVIWithHDR10"],
            ["Type": "Audio", "Index": 2, "Codec": "eac3", "Language": "jpn", "Channels": 6, "SampleRate": value.audioSampleRate],
            ["Type": "Audio", "Index": value.audioStreamIndex, "Codec": "eac3", "Language": "eng",
             "Channels": 6, "SampleRate": value.audioSampleRate],
            ["Type": "Subtitle", "Index": 7, "Codec": "subrip", "Language": "eng", "IsDefault": true]] } ?? []
        var source: [String: Any] = ["Id": "layout-source", "SupportsDirectPlay": false,
            "SupportsTranscoding": true, "TranscodingSubProtocol": "hls", "MediaStreams": streams,
            "TranscodingUrl": profile == nil ? "/stream.m3u8" : "/master.m3u8"]
        if profile != nil { source["Container"] = "mkv" }
        let json: [String: Any]
        if url.path.hasSuffix("/PlaybackInfo") {
            negotiationStarted = true
            if request.httpMethod == "POST", let data = request.httpBody,
               let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                negotiatedOptions.append(.init(startTicks: (body["StartTimeTicks"] as? NSNumber)?.int64Value ?? -1,
                    audioIndex: (body["AudioStreamIndex"] as? NSNumber)?.intValue,
                    subtitleIndex: (body["SubtitleStreamIndex"] as? NSNumber)?.intValue))
            }
            while !released { try await Task.sleep(for: .milliseconds(50)) }
            json = ["PlaySessionId": "layout-session", "MediaSources": [source]]
        } else if request.httpMethod == "GET", url.path == "/Items/" + itemID {
            var item: [String: Any] = ["Id": itemID, "Name": "Synthetic rotation fixture",
                "Type": profile == nil ? "Movie" : "Episode", "RunTimeTicks": Int64(duration * 10_000_000)]
            if profile != nil {
                item["SeriesId"] = "layout-series"; item["SeriesName"] = "Synthetic series"
                item["ParentIndexNumber"] = 1; item["IndexNumber"] = 1; item["MediaSources"] = [source]
            }
            json = item
        } else {
            json = [:]
        }
        return (try JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
