import Foundation
import CryptoKit

/// Only explicitly selected library reads enter this cache. Authentication,
/// permissions, playback URLs, support messages and writes always use the network.
public struct LibraryCachePolicy: Sendable {
    enum Storage: Sendable { case page, homeFeed, artwork, memory }
    let storage: Storage
    let lifetime: TimeInterval
    let snapshotLifetime: TimeInterval
    public static let library = Self(storage: .page, lifetime: 300, snapshotLifetime: 86_400)
    public static let activity = Self(storage: .page, lifetime: 60, snapshotLifetime: 3_600)
    public static let liveEvents = Self(storage: .memory, lifetime: 60, snapshotLifetime: 120)
    public static let liveArtworkIndex = Self(storage: .memory, lifetime: 300, snapshotLifetime: 900)
    public static let detail = Self(storage: .memory, lifetime: 120, snapshotLifetime: 120)
    public static let home = Self(storage: .homeFeed, lifetime: 300, snapshotLifetime: 3_600)
    /// Plugin Home rows: always fetched, but the last answer is kept on disk so
    /// a cold launch can show yesterday's rows while today's load.
    public static let homeSnapshot = Self(storage: .homeFeed, lifetime: 0, snapshotLifetime: 86_400)
    public static let homeCrest = Self(storage: .artwork, lifetime: 7 * 86_400, snapshotLifetime: 7 * 86_400)
    public static let artwork = Self(storage: .artwork, lifetime: 30 * 86_400, snapshotLifetime: 30 * 86_400)
}

public enum LibraryCacheMiss: Error { case missing }

/// One instance per signed-in server/viewer. All file IO and metadata decoding
/// happen on this actor, away from SwiftUI's main actor. OS caches are purgeable.
public actor LibraryResponseCache {
    public nonisolated let scope: String
    private let directory: URL?
    private let memoryLimit: Int
    private let diskLimit: Int
    private struct Entry { let data: Data; let date: Date; var touched: Date }
    private struct Flight { let id: UUID; let task: Task<Data, Error> }
    private var entries: [String: Entry] = [:]
    private var flights: [String: Flight] = [:]
    private var epoch = 0
    private var closed = false
    private var diskEntries: [String: (size: Int, date: Date)] = [:]
    private var diskIndexed = false

    public init(server: ServerAddress, viewerID: String,
                root: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("ZorofinLibrary-v1", isDirectory: true),
                memoryLimit: Int = 16 * 1024 * 1024, diskLimit: Int = 96 * 1024 * 1024) {
        scope = Self.scope(server: server, viewerID: viewerID)
        directory = root?.appendingPathComponent(scope, isDirectory: true)
        self.memoryLimit = max(0, memoryLimit); self.diskLimit = max(0, diskLimit)
    }
    public nonisolated func matches(server: ServerAddress, viewerID: String) -> Bool {
        scope == Self.scope(server: server, viewerID: viewerID)
    }
    private nonisolated static func scope(server: ServerAddress, viewerID: String) -> String {
        hash(server.storageKey + "\n" + viewerID)
    }
    private nonisolated static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func key(_ request: String, _ policy: LibraryCachePolicy) -> String {
        (policy.storage == .artwork ? "a-" : "m-") + Self.hash(request)
    }
    public func snapshot(_ request: String, policy: LibraryCachePolicy) -> Data? {
        guard !closed else { return nil }
        return read(key(request, policy), policy: policy, age: policy.snapshotLifetime)
    }
    public func value(_ request: String, policy: LibraryCachePolicy,
                      fetch: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let key = key(request, policy)
        if let data = read(key, policy: policy, age: policy.lifetime) { return data }
        let revision = epoch
        let flight: Flight
        if let pending = flights[key] { flight = pending }
        else {
            flight = Flight(id: UUID(), task: Task { try await fetch() })
            flights[key] = flight
        }
        do {
            let data = try await flight.task.value
            guard !closed, revision == epoch || policy.storage == .artwork else { throw CancellationError() }
            // Exactly one waiter stores the response; other waiters share it.
            if flights[key]?.id == flight.id {
                flights[key] = nil
                store(data, key: key, policy: policy)
            }
            try Task.checkCancellation()
            return data
        } catch {
            if flights[key]?.id == flight.id { flights[key] = nil }
            throw error
        }
    }
    public func remove(_ request: String, policy: LibraryCachePolicy) {
        let key = key(request, policy)
        entries[key] = nil
        flights.removeValue(forKey: key)?.task.cancel()
        if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent(key)) }
        diskEntries[key] = nil
    }
    public func invalidateMetadata() {
        epoch += 1
        entries = entries.filter { $0.key.hasPrefix("a-") }
        diskEntries = diskEntries.filter { $0.key.hasPrefix("a-") }
        // Pre-mutation library results cannot repopulate, while artwork continues.
        for (key, flight) in flights where key.hasPrefix("m-") {
            flight.task.cancel(); flights[key] = nil
        }
        if let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("m-") { try? FileManager.default.removeItem(at: file) }
        }
    }
    /// Retire on account switch; additionally remove this viewer's files on logout.
    public func close(purge: Bool) {
        closed = true; epoch += 1; entries = [:]; diskEntries = [:]
        for flight in flights.values { flight.task.cancel() }; flights = [:]
        if purge, let directory { try? FileManager.default.removeItem(at: directory) }
    }
    public func diskUsage() -> Int64 {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    /// Close this instance before clearing so in-flight artwork cannot refill the deleted cache.
    public func purge() throws {
        close(purge: false)
        if let directory, FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func read(_ key: String, policy: LibraryCachePolicy, age: TimeInterval) -> Data? {
        let now = Date()
        if var entry = entries[key], now.timeIntervalSince(entry.date) >= 0, now.timeIntervalSince(entry.date) < age {
            entry.touched = now; entries[key] = entry; return entry.data
        }
        guard policy.storage != .memory, let directory else { return nil }
        let file = directory.appendingPathComponent(key)
        guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = attrs.contentModificationDate, now.timeIntervalSince(date) >= 0, now.timeIntervalSince(date) < age,
              let size = attrs.fileSize, size <= 12 * 1024 * 1024,
              let data = try? Data(contentsOf: file) else { return nil }
        remember(data, key: key, date: date)
        return data
    }
    private func remember(_ data: Data, key: String, date: Date) {
        guard data.count <= memoryLimit else { return }
        entries[key] = Entry(data: data, date: date, touched: .now)
        var total = entries.values.reduce(0) { $0 + $1.data.count }
        for (key, value) in entries.sorted(by: { $0.value.touched < $1.value.touched }) where total > memoryLimit {
            entries[key] = nil; total -= value.data.count
        }
    }
    private func store(_ data: Data, key: String, policy: LibraryCachePolicy) {
        let now = Date()
        remember(data, key: key, date: now)
        guard policy.storage != .memory, let directory else { return }
        let diskData: Data
        if policy.storage == .page {
            // Persist a known model only, excluding playback sources/open tokens
            // and unknown fields a plugin or server might add to list responses.
            guard var page = try? Wire.decoder().decode(ItemPage.self, from: data) else { return }
            for index in page.items.indices { page.items[index].removePlaybackSources() }
            guard let encoded = try? Wire.encoder().encode(page) else { return }
            diskData = encoded
        } else if policy.storage == .homeFeed {
            guard let feed = try? Wire.decoder().decode(HomeFeed.self, from: data) else { return }
            let rows = feed.rows.map { row in
                HomeRow(id: row.id, title: row.title, description: row.description, state: row.state, message: row.message,
                    cards: row.cards.map { card in
                        var item = card.item; item.removePlaybackSources()
                        return HomeRowCard(id: card.id, item: item, subtitle: card.subtitle, badges: card.badges,
                                           startsAt: card.startsAt, endsAt: card.endsAt)
                    })
            }
            guard let encoded = try? Wire.encoder().encode(HomeFeed(schemaVersion: feed.schemaVersion,
                generatedAt: feed.generatedAt, preferences: feed.preferences, rows: rows)) else { return }
            diskData = encoded
        } else { diskData = data }
        guard diskData.count <= diskLimit else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var url = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            indexDisk()
            let file = directory.appendingPathComponent(key)
            #if os(iOS)
            try diskData.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try diskData.write(to: file, options: .atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: now], ofItemAtPath: file.path)
            diskEntries[key] = (diskData.count, now)
            trimDisk()
        } catch { /* Cache failures must never prevent browsing. */ }
    }
    private func indexDisk() {
        guard !diskIndexed, let directory else { return }
        diskIndexed = true
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        for file in files {
            if let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                diskEntries[file.lastPathComponent] = (attrs.fileSize ?? 0, attrs.contentModificationDate ?? .distantPast)
            }
        }
    }
    private func trimDisk() {
        guard let directory else { return }
        var total = diskEntries.values.reduce(0) { $0 + $1.size }
        // File metadata is indexed once, avoiding a directory scan per poster.
        for (key, entry) in diskEntries.sorted(by: { $0.value.date < $1.value.date }) where total > diskLimit {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(key))
            diskEntries[key] = nil; total -= entry.size
        }
    }
}
