#if os(iOS)
import SwiftUI
import AVFoundation
import Network
import ZorofinCore

/// Owns every offline download on iPhone and iPad.
///
/// Original files use a background URLSession; HLS transcodes use
/// AVAssetDownloadURLSession. Both keep running when the app is suspended, and
/// both sessions are recreated at launch so the system can hand back finished
/// work. Only the signed-in server and viewer can see or start their downloads.
@MainActor @Observable final class DownloadManager {
    static let shared = DownloadManager()
    nonisolated static let fileSessionID = "org.zorofin.app.downloads.files"
    nonisolated static let streamSessionID = "org.zorofin.app.downloads.streams"
    /// Transcodes load the server, so only one runs at a time.
    private static let maxActive = 2
    private static let maxActiveStreams = 1

    private(set) var catalog = DownloadCatalog()
    private(set) var isOnline = true
    private(set) var accountKey: String?
    private(set) var freeBytes: Int64?
    private(set) var downloadPermission: Bool?
    var canRequestDownload: Bool { isOnline && downloadPermission == true }

    @ObservationIgnored private var accountRevision = UUID()
    @ObservationIgnored private var permissionRequest = UUID()
    @ObservationIgnored private var permissionTask: Task<Bool, Error>?

    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private let bridge = DownloadSessionBridge()
    @ObservationIgnored private var fileSession: URLSession!
    @ObservationIgnored private var streamSession: AVAssetDownloadURLSession!
    @ObservationIgnored private var tasks: [String: URLSessionTask] = [:]
    @ObservationIgnored private var preparing: [String: UUID] = [:]
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored var backgroundCompletions: [String: () -> Void] = [:]

    private init() {
        catalog = Self.loadCatalog()
        let files = URLSessionConfiguration.background(withIdentifier: Self.fileSessionID)
        files.sessionSendsLaunchEvents = true
        files.isDiscretionary = false
        fileSession = URLSession(configuration: files, delegate: bridge, delegateQueue: nil)
        let streams = URLSessionConfiguration.background(withIdentifier: Self.streamSessionID)
        streams.sessionSendsLaunchEvents = true
        streams.isDiscretionary = false
        streamSession = AVAssetDownloadURLSession(configuration: streams, assetDownloadDelegate: bridge, delegateQueue: nil)
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in DownloadManager.shared.networkChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "org.zorofin.downloads.network"))
        refreshFreeSpace()
        Task { await restoreTasks() }
    }

    /// Creates the shared manager at launch so background sessions reconnect.
    static func activate() { _ = shared }

    // MARK: Account

    func configure(client: JellyfinClient?) {
        accountRevision = UUID()
        permissionRequest = UUID()
        permissionTask?.cancel(); permissionTask = nil
        downloadPermission = nil
        preparing.removeAll()
        self.client = client
        accountKey = client?.session.map { DownloadAccount.key(server: $0.server, viewerID: $0.viewer.id) }
        pump()
        Task { await refreshDownloadPermission(); await syncPendingProgress() }
    }

    /// Display state is only a hint. Every admission and queued start rechecks
    /// the current server; concurrent checks share an in-flight request only.
    func refreshDownloadPermission() async {
        _ = try? await checkDownloadPermission()
    }

    private func checkDownloadPermission() async throws -> Bool {
        guard isOnline, let client, accountKey != nil else {
            downloadPermission = nil
            throw ClientError.network
        }
        let revision = accountRevision
        let task: Task<Bool, Error>
        if let pending = permissionTask { task = pending }
        else {
            permissionRequest = UUID()
            downloadPermission = nil
            task = Task { try await client.contentDownloadPermission() }
            permissionTask = task
        }
        let request = permissionRequest
        defer { if permissionRequest == request { permissionTask = nil } }
        do {
            let allowed = try await task.value
            guard revision == accountRevision, request == permissionRequest else { throw CancellationError() }
            downloadPermission = allowed
            return allowed
        } catch {
            if revision == accountRevision, request == permissionRequest { downloadPermission = nil }
            throw error
        }
    }

    var records: [DownloadRecord] {
        guard let accountKey else { return [] }
        return catalog.records(accountKey: accountKey)
    }
    func record(itemID: String) -> DownloadRecord? {
        guard let accountKey else { return nil }
        return catalog.record(accountKey: accountKey, itemID: itemID)
    }
    func playableRecord(itemID: String) -> DownloadRecord? {
        guard let record = record(itemID: itemID), record.isPlayable, mediaURL(for: record) != nil else { return nil }
        return record
    }
    var usedBytes: Int64 { accountKey.map { catalog.usedBytes(accountKey: $0) } ?? 0 }

    // MARK: Starting and removing

    func download(_ item: MediaItem, quality: DownloadQuality, audioIndex: Int?, subtitleIndex: Int) async throws {
        guard item.isDownloadable, let accountKey else { throw ClientError.unsupportedPlayback }
        let revision = accountRevision
        guard try await checkDownloadPermission() else { throw ClientError.forbidden }
        guard revision == accountRevision, self.accountKey == accountKey else { throw CancellationError() }
        if let existing = catalog.record(accountKey: accountKey, itemID: item.id), existing.status != .failed { return }
        // "Automatic" subtitles mean the viewer's server default; a saved copy
        // cannot change tracks later, so keep it simple and burn in nothing.
        let record = DownloadRecord(accountKey: accountKey, item: item, quality: quality,
            audioIndex: audioIndex, subtitleIndex: subtitleIndex == -2 ? -1 : subtitleIndex)
        catalog.upsert(record)
        save()
        pump()
    }

    func retry(_ id: String) async throws {
        guard let record = catalog.record(id), record.accountKey == accountKey, record.status == .failed else { return }
        let revision = accountRevision
        guard try await checkDownloadPermission() else { throw ClientError.forbidden }
        guard revision == accountRevision, record.accountKey == accountKey,
              let current = catalog.record(id), current.createdAt == record.createdAt,
              current.status == .failed else { throw CancellationError() }
        catalog.update(id) { record in
            record.status = .queued; record.failure = nil; record.progress = 0; record.bytesWritten = 0
        }
        save()
        pump()
    }

    func remove(_ id: String) {
        guard let record = catalog.remove(id) else { return }
        preparing.removeValue(forKey: id)
        tasks.removeValue(forKey: id)?.cancel()
        deleteFiles(of: record)
        if record.method == .stream, record.status.isActive, let session = record.playSessionID, let client {
            Task { try? await client.stopEncoding(playSessionID: session) }
        }
        save()
        refreshFreeSpace()
        pump()
    }

    func removeAll() {
        records.map(\.id).forEach(remove)
    }

    /// Removing a saved account deletes its downloads from this device.
    func removeAll(server: ServerAddress, viewerID: String) {
        let key = DownloadAccount.key(server: server, viewerID: viewerID)
        for record in catalog.records(accountKey: key) {
            preparing.removeValue(forKey: record.id)
            tasks.removeValue(forKey: record.id)?.cancel()
            deleteFiles(of: record)
        }
        catalog.removeAll(accountKey: key)
        save()
        refreshFreeSpace()
    }

    // MARK: Offline playback

    func mediaURL(for record: DownloadRecord) -> URL? {
        guard let path = record.mediaPath else { return nil }
        let url = Self.home.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func artwork(for record: DownloadRecord) -> UIImage? {
        guard let path = record.artworkPath else { return nil }
        return UIImage(contentsOfFile: Self.home.appendingPathComponent(path).path)
    }

    func recordPlayback(_ id: String, positionSeconds: Double, durationSeconds: Double?) {
        catalog.update(id) { $0.recordPlayback(positionSeconds: positionSeconds, durationSeconds: durationSeconds) }
        save()
    }

    func syncPendingProgress() async {
        guard !syncing, isOnline, let client, let accountKey else { return }
        syncing = true
        defer { syncing = false }
        for record in catalog.pendingSync(accountKey: accountKey) {
            do {
                try await client.syncOfflineProgress(itemID: record.item.id,
                    positionTicks: record.offlinePositionTicks ?? 0, played: record.offlinePlayed ?? false)
                guard self.accountKey == accountKey else { return }
                catalog.update(record.id) { saved in
                    // Playback may have continued while this request was in flight.
                    if saved.offlinePositionTicks == record.offlinePositionTicks && saved.offlinePlayed == record.offlinePlayed {
                        saved.pendingSync = false
                    }
                    saved.item.userData = UserData(playbackPositionTicks: saved.offlinePositionTicks,
                        isFavorite: saved.item.userData?.isFavorite, played: saved.offlinePlayed)
                }
            } catch { break }
        }
        save()
    }

    // MARK: Queue

    private func pump() {
        guard restored, isOnline, let client, let accountKey else { return }
        let active = catalog.records.filter { $0.status == .downloading || preparing[$0.id] != nil }
        var slots = Self.maxActive - active.count
        var streamSlots = Self.maxActiveStreams - active.filter { $0.method == .stream }.count
        for record in catalog.records(accountKey: accountKey).reversed() where record.status == .queued && preparing[record.id] == nil {
            guard slots > 0 else { return }
            // An undecided method may become a transcode; keep one free slot for it.
            guard streamSlots > 0 || record.method == .file else { continue }
            slots -= 1; streamSlots -= 1
            let token = UUID(), revision = accountRevision
            preparing[record.id] = token
            Task { await start(record, token: token, revision: revision, client: client) }
        }
    }

    private func startIsCurrent(_ record: DownloadRecord, token: UUID, revision: UUID) -> Bool {
        revision == accountRevision && record.accountKey == accountKey && preparing[record.id] == token
            && catalog.record(record.id)?.createdAt == record.createdAt
            && catalog.record(record.id)?.status == .queued
    }

    private func start(_ record: DownloadRecord, token: UUID, revision: UUID, client: JellyfinClient) async {
        defer {
            if preparing[record.id] == token { preparing.removeValue(forKey: record.id) }
            pump()
        }
        do {
            guard startIsCurrent(record, token: token, revision: revision) else { return }
            guard try await checkDownloadPermission() else { throw ClientError.forbidden }
            guard startIsCurrent(record, token: token, revision: revision) else { return }
            var item = record.item
            if item.mediaSources?.first == nil { item = try await client.item(item.id, fresh: true) }
            guard startIsCurrent(record, token: token, revision: revision) else { return }
            let options = PlaybackOptions(bitrate: record.quality.bitrate, audioIndex: record.audioIndex,
                                          subtitleIndex: record.subtitleIndex)
            let info = try await client.playbackInfo(for: item, options: options)
            let plan = try DownloadPlan.make(info: info, itemID: item.id, client: client, options: options)
            let estimate = plan.expectedBytes ?? record.quality.estimatedBytes(runTimeTicks: item.runTimeTicks, source: info.mediaSources?.first)
            refreshFreeSpace()
            if let estimate, let freeBytes, estimate > freeBytes {
                throw DownloadFailure.storage
            }
            guard startIsCurrent(record, token: token, revision: revision) else {
                if plan.method == .stream { try? await client.stopEncoding(playSessionID: plan.playSessionID) }
                return
            }
            let artwork = await saveArtwork(for: item, record: record, token: token, revision: revision, client: client)
            guard startIsCurrent(record, token: token, revision: revision) else {
                if plan.method == .stream { try? await client.stopEncoding(playSessionID: plan.playSessionID) }
                return
            }
            catalog.update(record.id) { saved in
                saved.item = item
                saved.method = plan.method
                saved.playSessionID = plan.playSessionID
                saved.expectedBytes = estimate
                saved.status = .downloading
                saved.artworkPath = artwork ?? saved.artworkPath
            }
            let description = Self.taskDescription(id: record.id, ext: plan.fileExtension)
            let task: URLSessionTask
            switch plan.method {
            case .file:
                task = fileSession.downloadTask(with: plan.url)
            case .stream:
                let configuration = AVAssetDownloadConfiguration(asset: AVURLAsset(url: plan.url), title: item.displayTitle)
                if let artwork, let data = FileManager.default.contents(atPath: Self.home.appendingPathComponent(artwork).path) {
                    configuration.artworkData = data
                }
                task = streamSession.makeAssetDownloadTask(downloadConfiguration: configuration)
            }
            task.taskDescription = description
            tasks[record.id] = task
            task.resume()
            save()
            watchProgress()
        } catch {
            if startIsCurrent(record, token: token, revision: revision) { fail(record.id, error) }
        }
    }

    private func saveArtwork(for item: MediaItem, record: DownloadRecord, token: UUID, revision: UUID,
                             client: JellyfinClient) async -> String? {
        let tag = item.imageTags?["Primary"]
        guard tag != nil || item.isEpisode,
              let data = try? await client.image(itemID: item.id, kind: "Primary", tag: tag, width: 720) else { return nil }
        guard startIsCurrent(record, token: token, revision: revision) else { return nil }
        let relative = Self.folder(accountKey: record.accountKey) + "/" + Self.safeName(item.id) + ".jpg"
        let url = Self.home.appendingPathComponent(relative)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return relative
        } catch { return nil }
    }

    // MARK: Session callbacks

    func finishedFile(id: String, relativePath: String?, error: String?) {
        tasks.removeValue(forKey: id)
        guard catalog.record(id) != nil else {
            if let relativePath { try? FileManager.default.removeItem(at: Self.home.appendingPathComponent(relativePath)) }
            return
        }
        if let relativePath {
            let size = Self.size(of: Self.home.appendingPathComponent(relativePath))
            catalog.update(id) { record in
                record.mediaPath = relativePath; record.status = .completed; record.failure = nil
                record.progress = 1; record.bytesWritten = size; record.completedAt = Date()
            }
        } else {
            fail(id, DownloadFailure.message(error ?? "The download stopped. Try again."))
        }
        save(); refreshFreeSpace(); pump()
    }

    func streamLocation(id: String, relativePath: String) {
        catalog.update(id) { $0.mediaPath = relativePath }
        save()
    }

    func finishedStream(id: String, error: String?) {
        tasks.removeValue(forKey: id)
        guard let record = catalog.record(id) else { return }
        if let session = record.playSessionID, let client {
            Task { try? await client.stopEncoding(playSessionID: session) }
        }
        if error == nil, let url = mediaURL(for: record) {
            let size = Self.size(of: url)
            catalog.update(id) { record in
                record.status = .completed; record.failure = nil; record.progress = 1
                record.bytesWritten = size; record.completedAt = Date()
            }
        } else {
            if let url = record.mediaPath.map({ Self.home.appendingPathComponent($0) }) { try? FileManager.default.removeItem(at: url) }
            catalog.update(id) { $0.mediaPath = nil }
            fail(id, DownloadFailure.message(error ?? "The download stopped. Try again."))
        }
        save(); refreshFreeSpace(); pump()
    }

    func finishBackgroundEvents(_ identifier: String) {
        backgroundCompletions.removeValue(forKey: identifier)?()
    }

    // MARK: Internals

    private enum DownloadFailure: LocalizedError {
        case storage
        case message(String)
        var errorDescription: String? {
            switch self {
            case .storage: "There isn't enough free space on this device. Remove some downloads and try again."
            case .message(let text): text
            }
        }
    }

    private func fail(_ id: String, _ error: Error) {
        let text: String
        switch error {
        case let failure as DownloadFailure: text = failure.errorDescription ?? "The download stopped."
        case ClientError.unsupportedPlayback: text = "This title can't be downloaded from this server."
        case let error as ClientError: text = error.localizedDescription
        default: text = "The download couldn't start. Check your connection and try again."
        }
        catalog.update(id) { record in
            record.status = .failed; record.failure = text
        }
        save()
    }

    private func networkChanged(online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        if online {
            pump()
            Task { await refreshDownloadPermission(); await syncPendingProgress() }
        } else {
            permissionRequest = UUID()
            permissionTask?.cancel(); permissionTask = nil
            downloadPermission = nil
        }
    }

    private func restoreTasks() async {
        let files = await fileSession.allTasks
        let streams = await streamSession.allTasks
        for task in files + streams {
            guard let description = task.taskDescription, let id = Self.parse(description)?.id else { task.cancel(); continue }
            if catalog.record(id) == nil { task.cancel() } else { tasks[id] = task }
        }
        // Anything marked as downloading without a live task was interrupted.
        for record in catalog.records where record.status == .downloading && tasks[record.id] == nil {
            catalog.update(record.id) { $0.status = .queued; $0.progress = 0; $0.bytesWritten = 0 }
        }
        restored = true
        save()
        watchProgress()
        pump()
    }

    private func watchProgress() {
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let active = self.tasks.filter { $0.value.state == .running }
                if active.isEmpty && self.preparing.isEmpty { break }
                for (id, task) in active {
                    let fraction = task.progress.fractionCompleted
                    let received = task.countOfBytesReceived
                    self.catalog.update(id) { record in
                        if fraction.isFinite, fraction > 0 { record.progress = min(0.99, fraction) }
                        if received > 0 { record.bytesWritten = received }
                        if let expected = record.expectedBytes, expected > 0, !(fraction > 0) {
                            record.progress = min(0.99, Double(received) / Double(expected))
                        }
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
            self?.progressTask = nil
        }
    }

    private func deleteFiles(of record: DownloadRecord) {
        for path in [record.mediaPath, record.artworkPath].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: Self.home.appendingPathComponent(path))
        }
    }

    private func refreshFreeSpace() {
        let values = try? Self.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeBytes = values?.volumeAvailableCapacityForImportantUsage
    }

    private func save() {
        do {
            let url = Self.catalogURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(catalog).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var folder = url.deletingLastPathComponent()
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        } catch { /* The next change retries the save. */ }
    }

    private static func loadCatalog() -> DownloadCatalog {
        guard let data = try? Data(contentsOf: catalogURL),
              let catalog = try? JSONDecoder().decode(DownloadCatalog.self, from: data) else { return DownloadCatalog() }
        return catalog
    }

    nonisolated static var home: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
    nonisolated static let root = "Library/Application Support/Zorofin Downloads"
    nonisolated static var catalogURL: URL { home.appendingPathComponent(root + "/catalog.json") }
    nonisolated static func folder(accountKey: String) -> String { root + "/" + safeName(accountKey) }
    nonisolated static func safeName(_ value: String) -> String {
        String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.prefix(80))
    }
    nonisolated static func taskDescription(id: String, ext: String) -> String { id + "|" + ext }
    nonisolated static func parse(_ description: String) -> (id: String, ext: String)? {
        guard let split = description.lastIndex(of: "|") else { return nil }
        return (String(description[..<split]), String(description[description.index(after: split)...]))
    }
    /// The record ID is "accountKey:itemID".
    nonisolated static func destination(id: String, ext: String) -> String? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let safeExt = ["mp4", "m4v", "mov"].contains(ext) ? ext : "mp4"
        return folder(accountKey: parts[0]) + "/" + safeName(parts[1]) + "." + safeExt
    }
    nonisolated static func relativeToHome(_ url: URL) -> String {
        let home = Self.home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(home + "/") { return String(path.dropFirst(home.count + 1)) }
        return url.relativePath
    }
    nonisolated static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let file = enumerator?.nextObject() as? URL {
            let item = try? file.resourceValues(forKeys: Set(keys))
            total += Int64(item?.totalFileAllocatedSize ?? item?.fileAllocatedSize ?? 0)
        }
        return total
    }
}

/// URLSession delegates run off the main actor. File moves happen here,
/// synchronously, because the system deletes the temporary file on return.
final class DownloadSessionBridge: NSObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var moved: [Int: String] = [:]

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription,
              let parsed = DownloadManager.parse(description),
              let relative = DownloadManager.destination(id: parsed.id, ext: parsed.ext) else { return }
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) { return }
        let target = DownloadManager.home.appendingPathComponent(relative)
        do {
            let folder = target.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var root = DownloadManager.home.appendingPathComponent(DownloadManager.root)
            try? root.setResourceValues(values)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: location, to: target)
            lock.withLock { moved[downloadTask.taskIdentifier] = relative }
        } catch { }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        report(assetDownloadTask, location: location)
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        report(assetDownloadTask, location: location)
    }

    private func report(_ task: URLSessionTask, location: URL) {
        guard let description = task.taskDescription, let id = DownloadManager.parse(description)?.id else { return }
        let relative = DownloadManager.relativeToHome(location)
        Task { @MainActor in DownloadManager.shared.streamLocation(id: id, relativePath: relative) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let description = task.taskDescription, let id = DownloadManager.parse(description)?.id else { return }
        if (error as? URLError)?.code == .cancelled { return }
        let message = error.map { _ in "The download stopped. Check your connection and try again." }
        if session.configuration.identifier == DownloadManager.streamSessionID {
            Task { @MainActor in DownloadManager.shared.finishedStream(id: id, error: message) }
        } else {
            let relative = lock.withLock { moved.removeValue(forKey: task.taskIdentifier) }
            var text = message
            if relative == nil, text == nil {
                let status = (task.response as? HTTPURLResponse)?.statusCode
                text = status == 401 || status == 403 ? "The server declined this download. Sign in again and retry."
                    : "The server didn't send this title. Try again or choose another quality."
            }
            let failure = text
            Task { @MainActor in DownloadManager.shared.finishedFile(id: id, relativePath: relative, error: failure) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in DownloadManager.shared.finishBackgroundEvents(identifier) }
    }
}
#endif
