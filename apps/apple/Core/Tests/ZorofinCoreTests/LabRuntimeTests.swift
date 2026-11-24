import Foundation
import Testing
#if os(macOS)
import AVFoundation
#endif
@testable import ZorofinCore

/// Explicit opt-in only. The marker, fixed loopback port, server ID and runtime
/// version must match the existing synthetic migration lab before sign-in.
@Suite("Native compatibility against the isolated runtime", .serialized)
struct LabRuntimeTests {
    struct Marker: Decodable { let kind: String; let admin: String; let password: String }
    struct Seed: Decodable {
        let adminId: String; let viewerId: String; let itemId: String; let baselineServerId: String
        let collectionId: String; let playlistId: String
    }
    struct Lab: Sendable {
        let root: URL; let instance: String; let version: String; let seed: Seed
        let client: JellyfinClient
        func report(_ name: String, facts: [String: JSONValue]) throws {
            var facts = facts
            facts["runtimeVersion"] = .string(version)
            facts["testedAt"] = .string(Date().ISO8601Format())
            facts["platform"] = .string("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
            facts["physicalIOSOrTV"] = .bool(false)
            facts["productionWrites"] = .int(0)
            let path = root.appendingPathComponent(instance + "/native-" + name + ".json")
            try JSONEncoder().encode(facts).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }
    enum ProbeFailure: Error { case invalidLab, mediaHTTP(Int), mediaUnavailable, playerFailed(Int), noDecodedFrames, resumeSeekFailed, restorationFailed }
    private func connected(_ device: String, viewer: Bool = false) async throws -> Lab {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ZOROFIN_LAB_ROOT"] else { throw ProbeFailure.invalidLab }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let instance = env["ZOROFIN_LAB_INSTANCE"] ?? "candidate"
        guard ["baseline", "candidate"].contains(instance) else { throw ProbeFailure.invalidLab }
        let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: root.appendingPathComponent(".jellyfin-lab.json")))
        guard marker.kind == "synthetic-jellyfin-lab-v1" else { throw ProbeFailure.invalidLab }
        let seed = try JSONDecoder().decode(Seed.self, from: Data(contentsOf: root.appendingPathComponent("seed.json")))
        let server = try ServerAddress("http://127.0.0.1:\(instance == "candidate" ? 18097 : 18096)", allowsLocalHTTP: true)
        let identity = ClientIdentity(deviceID: "native-compatibility-" + device, deviceName: "Synthetic compatibility")
        let anonymous = JellyfinClient(server: server, identity: identity)
        let info = try await anonymous.systemInfo()
        let expected = instance == "candidate" ? "12.2.0" : "10.11.11"
        guard info.id == seed.baselineServerId, info.version == expected else { throw ProbeFailure.invalidLab }
        let session = try await anonymous.login(username: viewer ? "LabViewer" : marker.admin, password: marker.password)
        guard session.viewer.id == (viewer ? seed.viewerId : seed.adminId),
              !viewer || session.viewer.policy?.isAdministrator == false else {
            try? await JellyfinClient(server: server, identity: identity, session: session).logout()
            throw ProbeFailure.invalidLab
        }
        return Lab(root: root, instance: instance, version: expected, seed: seed,
                   client: JellyfinClient(server: server, identity: identity, session: session))
    }
    private func media(_ url: URL, lab: Lab, range: Bool = false) async throws -> Data {
        guard lab.client.server.contains(url) else { throw ProbeFailure.invalidLab }
        var request = URLRequest(url: url)
        if range { request.setValue("bytes=0-65535", forHTTPHeaderField: "Range") }
        // No API header: these requests must work with only the supplied URL,
        // matching AVPlayer's separate loader and generated HLS descendants.
        let (data, response) = try await URLSessionTransport(server: lab.client.server).send(request)
        guard [200,206].contains(response.statusCode) else { throw ProbeFailure.mediaHTTP(response.statusCode) }
        guard !data.isEmpty else { throw ProbeFailure.mediaUnavailable }
        return data
    }
    private func firstChild(_ data: Data, parent: URL, lab: Lab) throws -> URL {
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard let line = lines.first(where: { !$0.hasPrefix("#") && !$0.isEmpty }),
              let url = URL(string: String(line), relativeTo: parent)?.absoluteURL,
              lab.client.server.contains(url) else { throw ProbeFailure.mediaUnavailable }
        return url
    }
    private func stopEncoding(_ plan: PlaybackPlan, lab: Lab) async {
        guard plan.method == "Transcode" else { return }
        _ = try? await lab.client.requestData(["Videos", "ActiveEncodings"], query: [
            .init(name: "deviceId", value: lab.client.identity.deviceID),
            .init(name: "playSessionId", value: plan.sessionID)], method: "DELETE")
    }
    private func restoreUserData(_ data: Data?, lab: Lab) async throws {
        guard let data else { return }
        _ = try await lab.client.requestData(["UserItems", lab.seed.itemId, "UserData"],
            query: [.init(name: "userId", value: lab.client.session?.viewer.id)], method: "POST", body: data)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZOROFIN_LAB_ROOT"] != nil))
    func actualHTTPPaths() async throws {
        let lab = try await connected("http"), client = lab.client
        var encoding: PlaybackPlan?
        var savedUserData: Data?
        do {
            let item = try await client.item(lab.seed.itemId, fresh: true)
            let capabilities = try await client.discoverFeatures()
            try #require(capabilities.features == ServerFeatures() && !capabilities.needsRetry)
            try #require(try await client.currentViewer().id == lab.seed.adminId)
            try #require(try await client.items(type: "Movie", search: "Rehearsal").items.contains { $0.id == lab.seed.itemId })
            _ = try await client.resume(); _ = try await client.nextUp()
            _ = try await client.items(favorites: true)
            try #require(try await client.items(type: "BoxSet").items.contains { $0.id == lab.seed.collectionId })
            try #require(try await client.items(type: "Movie", parentID: lab.seed.collectionId).items.contains { $0.id == lab.seed.itemId })
            try #require(try await client.items(type: "Playlist").items.contains { $0.id == lab.seed.playlistId })
            let playlist = try await client.request(ItemPage.self, path: ["Playlists",lab.seed.playlistId,"Items"],
                query: [.init(name: "userId", value: lab.seed.adminId)])
            try #require(playlist.items.contains { $0.id == lab.seed.itemId })
            _ = try await client.viewerSettings(); _ = try await client.settingsLanguages()
            let favorite = item.userData?.isFavorite ?? false
            _ = try await client.favorite(itemID: item.id, value: favorite)
            let channels = try await client.channels()
            if let channel = channels.items.first { _ = try await client.livePlayerGuide(channelID: channel.id) }
            var imageChecked = false
            if let tag = item.imageTags?["Primary"] {
                try #require(!(try await client.image(itemID: item.id, tag: tag, width: 320)).isEmpty)
                imageChecked = true
            }
            let directOptions = PlaybackOptions()
            let info = try await client.playbackInfo(itemID: item.id, options: directOptions)
            let direct = try PlaybackPlan.make(info: info, itemID: item.id, client: client, options: directOptions)
            encoding = direct
            try #require(direct.method == "DirectPlay")
            try #require(!(try await media(direct.url, lab: lab, range: true)).isEmpty)
            let source = try #require(info.mediaSources?.first)
            let sourceID = try #require(source.id)
            let subtitle = try #require(source.mediaStreams?.first { $0.type == "Subtitle" })
            let subtitleURL = try client.server.mediaURL("Videos/\(item.id)/\(sourceID)/Subtitles/\(subtitle.index)/Stream.vtt", token: try #require(client.session?.token))
            try #require(String(decoding: try await media(subtitleURL, lab: lab), as: UTF8.self).contains("Synthetic migration subtitle"))
            let hlsOptions = PlaybackOptions(subtitleIndex: subtitle.index)
            let hlsInfo = try await client.playbackInfo(itemID: item.id, options: hlsOptions)
            let hls = try PlaybackPlan.make(info: hlsInfo, itemID: item.id, client: client, options: hlsOptions)
            encoding = hls
            try #require(hls.method == "Transcode")
            let master = try await media(hls.url, lab: lab)
            let variant = try firstChild(master, parent: hls.url, lab: lab)
            let playlistData = try await media(variant, lab: lab)
            let segment = try firstChild(playlistData, parent: variant, lab: lab)
            try #require(!(try await media(segment, lab: lab, range: true)).isEmpty)
            let names = URLComponents(url: variant, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
            try #require(names.contains("ApiKey") && !names.contains("api_key"))
            // Only the disposable item is touched; restore its full original
            // user data even when a lifecycle assertion fails.
            savedUserData = try await client.requestData(["UserItems", item.id, "UserData"],
                query: [.init(name: "userId", value: lab.seed.adminId)])
            let reporter = PlaybackReporter(client: client, plan: direct)
            await reporter.start(positionTicks: 0, canSeek: true)
            await reporter.flush()
            await reporter.progress(positionTicks: 400_000_000, paused: true, canSeek: true)
            await reporter.flush()
            await reporter.stop(positionTicks: 400_000_000)
            try #require(await reporter.failureCount == 0)
            let updated = try await client.item(item.id, fresh: true)
            try #require(updated.userData?.playbackPositionTicks == 400_000_000)
            try await restoreUserData(savedUserData, lab: lab)
            savedUserData = nil
            let quickIdentity = ClientIdentity(deviceID: "native-compatibility-quick", deviceName: "Synthetic receiver")
            let quick = JellyfinClient(server: client.server, identity: quickIdentity)
            let state = try await quick.initiateQuickConnect()
            try #require(try await client.authorizeQuickConnect(code: state.code))
            let session = try await quick.completeQuickConnect(secret: state.secret)
            try #require(session.viewer.id == lab.seed.adminId)
            try await JellyfinClient(server: client.server, identity: quickIdentity, session: session).logout()
            try lab.report("http", facts: ["apiPaths": .bool(true), "artwork": .bool(imageChecked),
                "directRange": .bool(true), "externalSubtitle": .bool(true), "hlsMasterVariantSegment": .bool(true),
                "generatedVariantUsesApiKey": .bool(true), "quickConnect": .bool(true),
                "sessionStartProgressStop": .bool(true), "genericServerWithoutExtension": .bool(true)])
            if let encoding { await stopEncoding(encoding, lab: lab) }
            try await client.logout()
        } catch {
            if let encoding { await stopEncoding(encoding, lab: lab) }
            do { try await restoreUserData(savedUserData, lab: lab) }
            catch { Issue.record("Synthetic item user-data restoration failed; inspect the private lab before another run.") }
            try? await client.logout()
            throw error
        }
    }

    /// Real writes use only the pre-existing synthetic non-admin viewer.
    /// Restore configuration, image absence and complete item user data on failure too.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZOROFIN_LAB_ROOT"] != nil))
    func actualViewerSettingsAndWatchState() async throws {
        let lab = try await connected("viewer-settings", viewer: true), client = lab.client
        let viewerID = lab.seed.viewerId
        var configuration: [String: JSONValue]?
        var userData: Data?
        var imageTouched = false
        func restore() async throws {
            var failed = false
            if imageTouched {
                do { try await client.updateOwnProfileImage(jpeg: nil) } catch { failed = true }
            }
            if let configuration {
                do {
                    _ = try await client.requestData(["Users", "Configuration"],
                        query: [.init(name: "userId", value: viewerID)], method: "POST",
                        body: JSONEncoder().encode(configuration), expectedStatus: 204)
                    let restored = try await client.viewerSettings()
                    if restored.configuration != configuration { failed = true }
                } catch { failed = true }
            }
            do { try await restoreUserData(userData, lab: lab) } catch { failed = true }
            if failed { throw ProbeFailure.restorationFailed }
        }
        do {
            let baseline = try await client.viewerSettings()
            try #require(baseline.canEdit && !baseline.hasImage)
            configuration = baseline.configuration
            userData = try await client.requestData(["UserItems", lab.seed.itemId, "UserData"],
                query: [.init(name: "userId", value: viewerID)])
            let item = try await client.item(lab.seed.itemId, fresh: true)
            var changes: [String: JSONValue] = [
                "AudioLanguagePreference": .string(baseline.string("AudioLanguagePreference") == "eng" ? "spa" : "eng"),
                "SubtitleLanguagePreference": .string(baseline.string("SubtitleLanguagePreference") == "spa" ? "eng" : "spa"),
                "SubtitleMode": .string(baseline.string("SubtitleMode") == "None" ? "Always" : "None")]
            for key in ["PlayDefaultAudioTrack", "RememberAudioSelections", "RememberSubtitleSelections", "EnableNextEpisodeAutoPlay"] {
                changes[key] = .bool(!baseline.bool(key))
            }
            let saved = try await client.saveViewerConfiguration(changes: changes, baseline: baseline)
            try #require(changes.allSatisfy { saved.configuration[$0.key] == $0.value })
            let favorite = !(item.userData?.isFavorite ?? false)
            _ = try await client.favorite(itemID: item.id, value: favorite)
            let favoriteReadback = try await client.item(item.id, fresh: true)
            try #require(favoriteReadback.userData?.isFavorite == favorite)
            for played in [true, false] {
                _ = try await client.played(itemID: item.id, value: played)
                let readback = try await client.item(item.id, fresh: true)
                try #require(readback.userData?.played == played)
            }
            let jpeg = try await client.requestData(["Items", item.id, "Images", "Primary"],
                query: [.init(name: "format", value: "Jpg"), .init(name: "maxWidth", value: "80")], accept: "image/jpeg")
            try #require(jpeg.starts(with: [0xff, 0xd8]))
            imageTouched = true
            try await client.updateOwnProfileImage(jpeg: jpeg)
            try #require(try await client.viewerSettings().hasImage)
            try #require(!(try await client.ownProfileImage()).isEmpty)
            try await restore()
            imageTouched = false; configuration = nil; userData = nil
            try #require(!(try await client.viewerSettings()).hasImage)
            try await client.logout()
            // A restored/saved token must not keep working after server logout.
            await #expect(throws: ClientError.unauthorized) { try await client.currentViewer() }
            try lab.report("viewer-settings", facts: ["nonAdminViewer": .bool(true),
                "configurationWriteReadRestore": .bool(true), "favoriteWriteReadRestore": .bool(true),
                "watchedAndUnwatched": .bool(true), "avatarUploadReadDelete": .bool(true),
                "logoutRejectsSavedToken": .bool(true)])
        } catch {
            do { try await restore() }
            catch { Issue.record("Synthetic viewer restoration failed; inspect the private lab before another run.") }
            try? await client.logout()
            throw error
        }
    }

    #if os(macOS)
    @MainActor
    private func decode(_ plan: PlaybackPlan, with player: AVPlayer) async throws {
        let avItem = AVPlayerItem(url: plan.url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        avItem.add(output); player.replaceCurrentItem(with: avItem)
        let start = MediaTime.seconds(ticks: plan.options.startTicks)
        if start > 0 {
            guard await player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                                    toleranceBefore: .zero, toleranceAfter: .zero) else {
                throw ProbeFailure.resumeSeekFailed
            }
        }
        player.play()
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(35))
        while ContinuousClock.now < deadline {
            if avItem.status == .failed { throw ProbeFailure.playerFailed((avItem.error as NSError?)?.code ?? 0) }
            let time = player.currentTime()
            if time.seconds > start + 2, output.hasNewPixelBuffer(forItemTime: time),
               output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ProbeFailure.noDecodedFrames
    }
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZOROFIN_LAB_AVPLAYER"] == "1"))
    func actualMacAVPlayer() async throws {
        let lab = try await connected("avplayer")
        let client = lab.client
        var encoding: PlaybackPlan?
        let player = AVPlayer(); player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        do {
            let item = try await client.item(lab.seed.itemId, fresh: true)
            let subtitle = try #require(item.mediaSources?.first?.mediaStreams?.first { $0.type == "Subtitle" })
            let audio = try #require(item.mediaSources?.first?.mediaStreams?.first { $0.type == "Audio" })
            let cases: [(String, PlaybackOptions)] = [
                ("direct", .init()), ("direct-resume", .init(startTicks: 400_000_000)),
                ("subtitle", .init(subtitleIndex: subtitle.index)),
                ("subtitle-resume", .init(startTicks: 400_000_000, subtitleIndex: subtitle.index)),
                ("audio-selection", .init(startTicks: 400_000_000, audioIndex: audio.index)),
                ("lower-quality", .init(startTicks: 400_000_000, bitrate: 2_000_000, subtitleIndex: subtitle.index))]
            for (name, options) in cases {
                let info = try await client.playbackInfo(itemID: item.id, options: options)
                let plan = try PlaybackPlan.make(info: info, itemID: item.id, client: client, options: options)
                encoding = plan
                try #require(plan.method == (options.subtitleIndex == -1 && options.audioIndex == nil ? "DirectPlay" : "Transcode"))
                try await decode(plan, with: player)
                await stopEncoding(plan, lab: lab); encoding = nil
                try lab.report(name + "-avplayer", facts: ["decodedFramesAfterTwoSeconds": .bool(true),
                    "subtitleBurnInRequested": .bool(options.subtitleIndex >= 0), "avPlayerURLOnly": .bool(true),
                    "explicitAudioSelection": .bool(options.audioIndex != nil), "bitrateCap": .int(Int64(options.bitrate)),
                    "requestedStartTicks": .int(options.startTicks),
                    "decodedBeyondRequestedPosition": .bool(true)])
            }
            try await client.logout()
        } catch {
            player.pause(); player.replaceCurrentItem(with: nil)
            if let encoding { await stopEncoding(encoding, lab: lab) }
            try? await client.logout()
            throw error
        }
    }
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZOROFIN_LAB_AVPLAYER"] == "1"))
    func actualSyntheticLiveAVPlayer() async throws {
        let lab = try await connected("live"), client = lab.client
        let player = AVPlayer(); player.isMuted = true
        var ownedStream: String?
        var encoding: PlaybackPlan?
        do {
            let channels = try await client.channels()
            let channel = try #require(channels.items.first { $0.name == "Lab Sports" })
            let detail = try await client.item(channel.id, fresh: true)
            let options = PlaybackOptions(subtitleIndex: -2)
            let info = try await client.playbackInfo(for: detail, options: options)
            var source = try #require(info.mediaSources?.first)
            if source.requiresOpening == true {
                source = try await client.openLive(source: source, info: info, itemID: channel.id, options: options)
                if source.requiresClosing == true { ownedStream = source.liveStreamId }
            }
            let plan = try PlaybackPlan.make(info: info, source: source, itemID: channel.id, client: client, options: options)
            encoding = plan
            try await decode(plan, with: player)
            await stopEncoding(plan, lab: lab); encoding = nil
            if let ownedStream { try await client.closeLive(ownedStream) }
            ownedStream = nil
            try lab.report("live-avplayer", facts: ["decodedFramesAfterTwoSeconds": .bool(true),
                "syntheticLocalChannelOnly": .bool(true), "avPlayerURLOnly": .bool(true),
                "method": .string(plan.method), "ownedStreamClosed": .bool(true)])
            try await client.logout()
        } catch {
            player.pause(); player.replaceCurrentItem(with: nil)
            if let encoding { await stopEncoding(encoding, lab: lab) }
            if let ownedStream { try? await client.closeLive(ownedStream) }
            try? await client.logout()
            throw error
        }
    }
    #endif
}
