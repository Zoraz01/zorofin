import Foundation
import Testing
@testable import ZorofinCore

/// Opt-in negotiation against an explicitly selected server/account. Never opens
/// a stream, sends watch-state events, or includes private IDs/URLs in output.
@Suite("Playback selection server check") struct PlaybackSelectionRuntimeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZOROFIN_PLAYBACK_SELECTION_CHECK"] != nil))
    func resolvesContainersAndNegotiatesActualPlayableItems() async throws {
        struct Input: Decodable {
            let server: String
            let serverID: String
            let userID: String
            let token: String
            let itemIDs: [String]
        }
        let file = try #require(ProcessInfo.processInfo.environment["ZOROFIN_PLAYBACK_SELECTION_CHECK"])
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        let server = try ServerAddress(input.server, allowsLocalHTTP: true)
        let identity = ClientIdentity(deviceID: "playback-selection-check-" + UUID().uuidString, deviceName: "Playback selection check")
        let client = JellyfinClient(server: server, identity: identity,
            session: Session(server: server, viewer: .init(id: input.userID, name: "Validation"), token: input.token, deviceID: identity.deviceID))
        let info = try await client.systemInfo()
        guard info.id == input.serverID else { throw ClientError.unsafeURL }
        guard !input.itemIDs.isEmpty else { throw ClientError.invalidResponse }
        for id in input.itemIDs {
            let item = try await client.item(id, fresh: true)
            let selection = try await client.playbackSelection(for: item, options: .init())
            #expect(selection.item.isPlayableVideo)
            if item.isSeries || item.type == "Season" {
                #expect(selection.item.isEpisode && selection.item.id != item.id)
            } else { #expect(selection.item.id == item.id) }
            var options = selection.options
            // NativePlayer resolves the automatic subtitle sentinel before negotiation.
            if options.subtitleIndex == -2 { options.subtitleIndex = -1 }
            let playback = try await client.playbackInfo(for: selection.item, options: options)
            #expect(playback.errorCode == nil && playback.mediaSources?.isEmpty == false)
        }
        print("Playback selection: \(input.itemIDs.count) real-server items negotiated; no stream opened.")
    }
}
