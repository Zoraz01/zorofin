import Foundation

/// What a saved profile was last watching, shown behind "Who's watching?".
/// Built from that profile's own Continue Watching feed with its own session,
/// so no other account's token or history is used.
public struct ProfileSpotlight: Codable, Hashable, Sendable {
    public var itemID: String
    /// Show name for an episode, otherwise the title.
    public var title: String
    /// "S2 E4 · The Long Dark" for an episode, empty for a movie.
    public var detail: String
    /// 0...1 when the item has a resume position, otherwise nil.
    public var progress: Double?
    /// Wide art: the backdrop behind the picker.
    public var backdrop: ImageSource?
    /// 16:9 thumbnail on the "was watching" card (episode still when present).
    public var thumbnail: ImageSource?

    public struct ImageSource: Codable, Hashable, Sendable {
        public var itemID: String
        public var kind: String
        public var tag: String
        public init(itemID: String, kind: String, tag: String) { self.itemID = itemID; self.kind = kind; self.tag = tag }
        public var cacheKey: String { "\(itemID)-\(kind)-\(tag)" }
    }

    public init(itemID: String, title: String, detail: String, progress: Double?, backdrop: ImageSource?, thumbnail: ImageSource?) {
        self.itemID = itemID; self.title = title; self.detail = detail
        self.progress = progress; self.backdrop = backdrop; self.thumbnail = thumbnail
    }

    /// The first Continue Watching item that has wide art leads; when none has
    /// art, the first item still names what they were watching.
    public static func pick(from items: [MediaItem]) -> ProfileSpotlight? {
        let usable = items.filter { !$0.id.isEmpty && !$0.name.isEmpty }
        guard let item = usable.first(where: { backdrop(for: $0) != nil }) ?? usable.first else { return nil }
        return make(item)
    }

    static func make(_ item: MediaItem) -> ProfileSpotlight {
        var progress: Double?
        if let runtime = item.runTimeTicks, runtime > 0, item.resumeTicks > 0 {
            progress = min(1, max(0, Double(item.resumeTicks) / Double(runtime)))
        } else if let percent = item.userData?.playedPercentage, percent > 0 {
            progress = min(1, percent / 100)
        }
        return ProfileSpotlight(itemID: item.id, title: item.displayTitle, detail: item.episodeLabel,
            progress: progress, backdrop: backdrop(for: item), thumbnail: thumbnail(for: item))
    }

    /// Show/movie backdrop first; an episode's own still is only a fallback
    /// because stills are often dark or low resolution at full-screen size.
    static func backdrop(for item: MediaItem) -> ImageSource? {
        if let tag = nonEmpty(item.backdropImageTags?.first) { return .init(itemID: item.id, kind: "Backdrop", tag: tag) }
        if let id = nonEmpty(item.parentBackdropItemId), let tag = nonEmpty(item.parentBackdropImageTags?.first) {
            return .init(itemID: id, kind: "Backdrop", tag: tag)
        }
        if let tag = nonEmpty(item.imageTags?["Thumb"]) { return .init(itemID: item.id, kind: "Thumb", tag: tag) }
        if item.isEpisode, let tag = nonEmpty(item.imageTags?["Primary"]) { return .init(itemID: item.id, kind: "Primary", tag: tag) }
        return nil
    }

    static func thumbnail(for item: MediaItem) -> ImageSource? {
        if item.isEpisode, let tag = nonEmpty(item.imageTags?["Primary"]) { return .init(itemID: item.id, kind: "Primary", tag: tag) }
        if let tag = nonEmpty(item.imageTags?["Thumb"]) { return .init(itemID: item.id, kind: "Thumb", tag: tag) }
        return backdrop(for: item)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

extension JellyfinClient {
    /// Continue Watching for the signed-in viewer of this client, reduced to
    /// the one item the profile picker shows. Nil when there is nothing to resume.
    public func profileSpotlight() async throws -> ProfileSpotlight? {
        ProfileSpotlight.pick(from: try await continueWatching().items)
    }
}

/// Last known spotlight per saved account, kept on this device so the picker
/// draws instantly (and Roku-class devices never wait on the network).
/// Entries are keyed by the saved account id and removed with the account.
public struct ProfileSpotlightStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func file(_ account: UUID) -> URL { directory.appendingPathComponent("spotlight-\(account.uuidString).json") }

    public func load(_ account: UUID) -> ProfileSpotlight? {
        guard let data = try? Data(contentsOf: file(account)) else { return nil }
        return try? JSONDecoder().decode(ProfileSpotlight.self, from: data)
    }

    public func save(_ spotlight: ProfileSpotlight?, for account: UUID) {
        guard let spotlight else { remove(account); return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(spotlight) else { return }
        try? data.write(to: file(account), options: .atomic)
    }

    /// Compressed backdrop bytes, so the art is on screen before the network answers.
    public func loadImage(_ account: UUID, tag: String) -> Data? {
        guard load(account)?.backdrop?.cacheKey == tag else { return nil }
        return try? Data(contentsOf: imageFile(account))
    }
    public func saveImage(_ data: Data, for account: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: imageFile(account), options: .atomic)
    }
    private func imageFile(_ account: UUID) -> URL { directory.appendingPathComponent("spotlight-\(account.uuidString)-backdrop.img") }

    public func remove(_ account: UUID) {
        try? FileManager.default.removeItem(at: file(account))
        try? FileManager.default.removeItem(at: imageFile(account))
    }

    /// Drops entries for accounts no longer saved on this device.
    public func prune(keeping accounts: Set<UUID>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("spotlight-") {
            let raw = String(name.dropFirst("spotlight-".count).prefix(36))
            if let id = UUID(uuidString: raw), !accounts.contains(id) { remove(id) }
        }
    }
}

/// Built-in avatars for profiles without a photo: crops of Zorofin's own
/// fictional landscape art. The choice is stable per viewer id.
public enum SceneAvatar {
    public static let names = ["northbound", "orbital", "ember", "tide", "harbor", "saltflats", "lastlight"]
    public static func name(for viewerID: String) -> String {
        // Sum of UTF-8 bytes: stable across launches and simple enough to match
        // exactly on Flutter, LG and Roku, so a viewer gets the same scene everywhere.
        let sum = viewerID.lowercased().utf8.reduce(0) { $0 + Int($1) }
        return names[sum % names.count]
    }
}
