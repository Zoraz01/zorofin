import Foundation
import Observation
import AVFoundation
import ZorofinCore

struct GroupPlaybackRequest: Identifiable {
    let id = UUID()
    let item: MediaItem
    let options: PlaybackOptions
}

/// One device session on an ordinary Jellyfin server. The server owns the group,
/// queue, clock, and commands; this adapter connects that contract to AVPlayer.
@MainActor @Observable final class WatchTogetherModel {
    var groups: [SyncPlayGroup] = []
    var group: SyncPlayGroup?
    var currentItem: MediaItem?
    var playbackRequest: GroupPlaybackRequest?
    var browseRequested = false
    var busy = false
    var error: String?
    var access: String?
    var connected = false
    var canCreate: Bool { access == "CreateAndJoinGroups" }
    var canJoin: Bool { canCreate || access == "JoinGroups" }
    var isJoined: Bool { group != nil }

    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var socket: SyncPlaySocket?
    @ObservationIgnored private var receiver: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var scheduledCommand: Task<Void, Never>?
    @ObservationIgnored private var connection: Task<Void, any Error>?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var clockOffset: TimeInterval = 0
    @ObservationIgnored private var queue: SyncPlayQueue?
    @ObservationIgnored private var latestCommand: SyncPlayCommand?
    @ObservationIgnored private var queueRevision = ""
    @ObservationIgnored private var following = true
    @ObservationIgnored private weak var player: PlaybackController?

    func configure(_ client: JellyfinClient?) {
        let previous = self.client
        let wasJoined = isJoined
        epoch = UUID(); receiver?.cancel(); heartbeat?.cancel(); scheduledCommand?.cancel(); connection?.cancel()
        let oldSocket = socket
        socket = nil; receiver = nil; heartbeat = nil; scheduledCommand = nil; connection = nil
        self.client = client
        player?.leaveSyncPlay(); player = nil
        group = nil; groups = []; queue = nil; latestCommand = nil; queueRevision = ""
        currentItem = nil; playbackRequest = nil; browseRequested = false
        access = nil; connected = false; busy = false; error = nil; following = true
        Task {
            await oldSocket?.close()
            if wasJoined { try? await previous?.syncPlay("Leave") }
        }
    }

    func refresh() async {
        guard let client, !busy else { return }
        let expected = epoch
        do {
            let viewer = try await client.currentViewer()
            guard expected == epoch else { return }
            access = viewer.policy?.syncPlayAccess
            guard canJoin else { groups = []; clearGroup(); disconnect(); return }
            let available = try await client.syncPlayGroups()
            guard expected == epoch else { return }
            groups = available
            if let id = group?.id { group = available.first { $0.id == id } ?? group }
            error = nil
        } catch {
            guard expected == epoch, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
            if !isJoined { disconnect() }
        }
    }

    private func ensureConnected() async throws {
        if connected { return }
        if let connection { return try await connection.value }
        let expected = epoch
        let pending = Task { @MainActor [self] in
            guard let client = self.client else { throw ClientError.missingSession }
            let socket = SyncPlaySocket()
            try await socket.connect(client: client)
            guard expected == self.epoch, !Task.isCancelled else { await socket.close(); throw CancellationError() }
            self.socket = socket; self.connected = true
            self.receiver = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard let self, expected == self.epoch else { break }
                        await self.receive(message)
                    }
                } catch {
                    guard let self, expected == self.epoch, !Task.isCancelled else { return }
                    self.connected = false; self.scheduledCommand?.cancel()
                    self.player?.pauseForInterface()
                    self.error = "The group connection was interrupted. Open Watch together to reconnect."
                    self.player?.leaveSyncPlay(); self.player = nil
                    self.group = nil; self.queue = nil; self.playbackRequest = nil
                    self.heartbeat?.cancel(); self.socket = nil
                    await socket.close()
                    // Remove this device from the server's buffering barrier.
                    try? await client.syncPlay("Leave")
                }
            }
            if let clock = try? await client.syncPlayClock(), expected == self.epoch {
                self.clockOffset = clock.offset
            }
            self.heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(20)); try Task.checkCancellation() }
                    catch { return }
                    guard let self, expected == self.epoch else { return }
                    do {
                        try await socket.ping()
                        let clock = try await client.syncPlayClock()
                        guard expected == self.epoch else { return }
                        self.clockOffset = clock.offset
                        if self.isJoined {
                            try await client.syncPlay("Ping", body: ["Ping": .double(clock.roundTrip * 1000)])
                        }
                    } catch { /* The receive task owns disconnect cleanup. */ }
                }
            }
        }
        connection = pending
        defer { if expected == epoch { connection = nil } }
        try await pending.value
    }

    func create(name: String) async {
        guard canCreate, !busy, !isJoined, let client else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { error = "Enter a group name of up to 100 characters."; return }
        let expected = epoch
        busy = true; error = nil
        defer { if expected == epoch { busy = false } }
        do {
            try await ensureConnected()
            let created = try await client.createSyncPlayGroup(name: name)
            guard expected == epoch else { return }
            group = created; following = true
        } catch {
            guard expected == epoch else { return }
            self.error = error.localizedDescription
        }
    }

    func join(_ selected: SyncPlayGroup) async {
        guard canJoin, !busy, !isJoined, let client else { return }
        let expected = epoch
        busy = true; error = nil
        defer { if expected == epoch { busy = false } }
        do {
            try await ensureConnected()
            try await client.syncPlay("Join", body: ["GroupId": .string(selected.id)])
            // Join is acknowledged on the socket. An HTTP 204 alone does not
            // prove membership (e.g. the server can send LibraryAccessDenied).
            for _ in 0..<50 {
                guard expected == epoch else { return }
                if group?.id == selected.id { return }
                if let error = self.error { throw GroupError.message(error) }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw GroupError.message("The server did not confirm joining. Refresh the group list and try again.")
        } catch {
            guard expected == epoch else { return }
            self.error = error.localizedDescription
        }
    }

    func leave() async {
        guard !busy, let client else { return }
        let expected = epoch
        busy = true; error = nil
        defer { if expected == epoch { busy = false } }
        do {
            try await client.syncPlay("Leave")
            guard expected == epoch else { return }
            clearGroup()
            disconnect()
        } catch {
            guard expected == epoch else { return }
            self.error = error.localizedDescription
        }
    }

    private func clearGroup() {
        scheduledCommand?.cancel(); scheduledCommand = nil
        player?.leaveSyncPlay(); player = nil
        group = nil; queue = nil; currentItem = nil; latestCommand = nil
        queueRevision = ""; playbackRequest = nil; following = true
    }
    private func disconnect() {
        receiver?.cancel(); heartbeat?.cancel(); connection?.cancel()
        receiver = nil; heartbeat = nil; connection = nil; connected = false
        let old = socket; socket = nil
        Task { await old?.close() }
    }

    func selectForPlayback(_ item: MediaItem, options: PlaybackOptions) async {
        guard isJoined, client != nil, !item.isLive else { return }
        await send("SetNewQueue", body: ["PlayingQueue": .array([.string(item.id)]),
            "PlayingItemPosition": .int(0), "StartPositionTicks": .int(options.startTicks)])
    }

    func continueWatching() async {
        guard let client, isJoined, connected else { return }
        following = true
        if let queue { await open(queue, client: client) }
    }

    func nextItem() async {
        guard let id = queue?.current?.playlistItemId else { return }
        await send("NextItem", body: ["PlaylistItemId": .string(id)])
    }

    func requestPause(_ paused: Bool) async {
        if !paused {
            await send("SetIgnoreWait", body: ["IgnoreWait": .bool(false)])
            await reportReadiness(buffering: false)
        }
        await send(paused ? "Pause" : "Unpause")
    }
    func requestSeek(seconds: Double) async {
        guard seconds.isFinite else { return }
        await send("SetIgnoreWait", body: ["IgnoreWait": .bool(false)])
        await send("Seek", body: ["PositionTicks": .int(MediaTime.ticks(seconds: max(0, seconds)))])
    }
    private func send(_ action: String, body: [String: JSONValue]? = nil) async {
        guard isJoined, connected, let client else { return }
        let expected = epoch
        do { try await client.syncPlay(action, body: body) }
        catch { if expected == epoch { self.error = error.localizedDescription } }
    }

    func playerReady(_ controller: PlaybackController, itemID: String) async {
        guard isJoined, queue?.current?.itemId.replacingOccurrences(of: "-", with: "").lowercased()
                == itemID.replacingOccurrences(of: "-", with: "").lowercased() else { return }
        player = controller
        following = true
        await send("SetIgnoreWait", body: ["IgnoreWait": .bool(false)])
        await reportReadiness(buffering: false)
        if let latestCommand { schedule(latestCommand) }
    }
    func reportReadiness(buffering: Bool) async {
        guard let player, let id = queue?.current?.playlistItemId else { return }
        let now = Date().addingTimeInterval(clockOffset)
        await send(buffering ? "Buffering" : "Ready", body: [
            "When": .string(SyncPlayTime.string(now)),
            "PositionTicks": .int(player.syncPositionTicks),
            "IsPlaying": .bool(player.player.timeControlStatus == .playing), "PlaylistItemId": .string(id)])
    }
    func playerClosed(_ controller: PlaybackController) async {
        guard player == nil || player === controller else { return }
        if playbackRequest != nil { player = nil; return }
        following = false; player = nil; scheduledCommand?.cancel()
        await send("SetIgnoreWait", body: ["IgnoreWait": .bool(true)])
    }
    func pauseForInterface(_ controller: PlaybackController) async {
        guard player === controller else { return }
        await send("SetIgnoreWait", body: ["IgnoreWait": .bool(true)])
    }
    func correctDrift(_ controller: PlaybackController) async {
        guard player === controller, !controller.groupPlaybackSuspended,
              group?.state == "Playing", let command = latestCommand,
              command.command == "Unpause", command.positionTicks != nil,
              let when = SyncPlayTime.date(command.when), when <= Date().addingTimeInterval(clockOffset),
              command.playlistItemId == queue?.current?.playlistItemId else { return }
        let expected = estimatedPosition(command)
        if abs(MediaTime.seconds(ticks: expected) - MediaTime.seconds(ticks: controller.syncPositionTicks)) > 0.75 {
            await controller.applyGroupCommand("Unpause", ticks: expected)
        }
    }

    private func receive(_ message: SyncPlayMessage) async {
        if message.messageType == "ForceKeepAlive" { try? await socket?.keepAlive(); return }
        if message.messageType == "SyncPlayCommand", let command = try? message.payload(SyncPlayCommand.self) {
            guard command.groupId == group?.id,
                  (latestCommand.flatMap({ SyncPlayTime.date($0.emittedAt) }) ?? .distantPast)
                    <= (SyncPlayTime.date(command.emittedAt) ?? .distantPast) else { return }
            if let previous = latestCommand, previous.command == command.command,
               previous.when == command.when, previous.positionTicks == command.positionTicks,
               previous.playlistItemId == command.playlistItemId { return }
            latestCommand = command; schedule(command); return
        }
        guard message.messageType == "SyncPlayGroupUpdate", let update = try? message.payload(SyncPlayUpdate.self) else { return }
        if update.type != "GroupJoined", update.type != "NotInGroup", let group, update.groupId != group.id { return }
        switch update.type {
        case "GroupJoined", "GroupUpdate":
            if let joined = try? update.payload(SyncPlayGroup.self) {
                if group?.id != joined.id { clearGroup() }
                group = joined; following = true; error = nil
            }
        case "GroupLeft", "NotInGroup": clearGroup()
        case "UserJoined":
            if let name = update.data?.string { group?.participants.append(name) }
        case "UserLeft":
            if let name = update.data?.string, let index = group?.participants.firstIndex(of: name) { group?.participants.remove(at: index) }
        case "StateUpdate":
            if let state = update.data?.object?["State"]?.string { group?.state = state }
        case "PlayQueue":
            guard let client, let queue = try? update.payload(SyncPlayQueue.self),
                  queueRevision.isEmpty || (SyncPlayTime.date(queue.lastUpdate) ?? .distantPast) > (SyncPlayTime.date(queueRevision) ?? .distantPast) else { return }
            self.queue = queue; queueRevision = queue.lastUpdate
            if queue.reason == "NewPlaylist" { following = true }
            guard following else { return }
            if queue.current == nil { currentItem = nil; player?.applyGroupStop(); player = nil; return }
            await open(queue, client: client)
        case "LibraryAccessDenied": error = "Your account cannot play this group's media."
        case "GroupDoesNotExist": error = "This group is no longer available. Refresh and choose another."
        case "CreateGroupDenied", "JoinGroupDenied", "SyncPlayIsDisabled": error = "Your server does not allow this group action."
        default: break
        }
    }

    private func open(_ queue: SyncPlayQueue, client: JellyfinClient) async {
        guard let selected = queue.current else { return }
        let expected = epoch, revision = queueRevision
        do {
            let item = try await client.item(selected.itemId)
            guard expected == epoch, revision == queueRevision, isJoined, following else { return }
            guard !item.isLive else { error = "Watch together supports movies and episodes."; await send("SetIgnoreWait", body: ["IgnoreWait": .bool(true)]); return }
            currentItem = item
            if player?.syncItemID == item.id { await reportReadiness(buffering: false); return }
            var ticks = queue.startPositionTicks
            if let command = latestCommand, command.playlistItemId == selected.playlistItemId {
                ticks = estimatedPosition(command)
            } else if queue.isPlaying, let when = SyncPlayTime.date(queue.lastUpdate) {
                ticks += MediaTime.ticks(seconds: max(0, Date().addingTimeInterval(clockOffset).timeIntervalSince(when)))
            }
            playbackRequest = .init(item: item, options: .init(startTicks: max(0, ticks), subtitleIndex: -2))
        } catch {
            guard expected == epoch else { return }
            self.error = "This group's media could not be opened. Check your access and try again."
            await send("SetIgnoreWait", body: ["IgnoreWait": .bool(true)])
        }
    }

    private func estimatedPosition(_ command: SyncPlayCommand) -> Int64 {
        var ticks = command.positionTicks ?? player?.syncPositionTicks ?? queue?.startPositionTicks ?? 0
        if command.command == "Unpause", let date = SyncPlayTime.date(command.when) {
            ticks += MediaTime.ticks(seconds: max(0, Date().addingTimeInterval(clockOffset).timeIntervalSince(date)))
        }
        return max(0, ticks)
    }
    private func schedule(_ command: SyncPlayCommand) {
        guard let player, !player.groupPlaybackSuspended, following, command.command == "Stop" || command.playlistItemId == queue?.current?.playlistItemId,
              let when = SyncPlayTime.date(command.when) else { return }
        scheduledCommand?.cancel()
        let expected = epoch
        scheduledCommand = Task { [weak self, weak player] in
            guard let self, let player else { return }
            let delay = when.timeIntervalSince(Date().addingTimeInterval(self.clockOffset))
            guard delay < 60 else { return }
            if delay > 0 { do { try await Task.sleep(for: .seconds(delay)) } catch { return } }
            guard expected == self.epoch, self.isJoined, !player.groupPlaybackSuspended, !Task.isCancelled else { return }
            await player.applyGroupCommand(command.command, ticks: self.estimatedPosition(command))
        }
    }

    private enum GroupError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
    }
}
