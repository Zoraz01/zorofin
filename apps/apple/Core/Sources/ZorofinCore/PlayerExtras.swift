import Foundation

/// A chapter marker from Jellyfin (`Fields=Chapters`).
public struct PlayerChapter: Sendable, Equatable, Identifiable {
    public let start: Double
    public let name: String
    public let imageTag: String?
    /// The chapter's place in Jellyfin's list, which its image URL uses.
    public let imageIndex: Int
    public var id: Int { imageIndex }

    /// Chapters in time order; unnamed ones are numbered in that order. A
    /// single chapter is no navigation at all, so it gives none.
    public static func list(from json: [String: Any]) -> [PlayerChapter] {
        guard let entries = json["Chapters"] as? [Any] else { return [] }
        var found: [(start: Double, name: String?, tag: String?, index: Int)] = []
        for (index, entry) in entries.enumerated() {
            guard let entry = entry as? [String: Any], let ticks = (entry["StartPositionTicks"] as? NSNumber)?.int64Value,
                  ticks >= 0 else { continue }
            let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            found.append((MediaTime.seconds(ticks: ticks), name?.isEmpty == false ? name : nil, entry["ImageTag"] as? String, index))
        }
        guard found.count >= 2 else { return [] }
        found.sort { $0.start < $1.start }
        return found.enumerated().map { position, chapter in
            PlayerChapter(start: chapter.start, name: chapter.name ?? "Chapter \(position + 1)",
                          imageTag: chapter.tag, imageIndex: chapter.index)
        }
    }

    /// The chapter playing at `seconds`, or nil before the first one.
    public static func index(in chapters: [PlayerChapter], at seconds: Double) -> Int? {
        chapters.lastIndex { $0.start <= seconds }
    }
}

/// Jellyfin's scrub thumbnails (`Fields=Trickplay`): sheets of
/// `tileWidth` x `tileHeight` frames, one every `interval` seconds.
public struct Trickplay: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let tileWidth: Int
    public let tileHeight: Int
    public let count: Int
    public let interval: Double

    public var isValid: Bool { width > 0 && height > 0 && tileWidth > 0 && tileHeight > 0 && count > 0 && interval > 0 }

    /// The smallest resolution at least `preferredWidth` wide, or the largest there is.
    public static func best(from json: [String: Any], mediaSourceID: String?, preferredWidth: Int = 320) -> Trickplay? {
        guard let all = json["Trickplay"] as? [String: Any], !all.isEmpty else { return nil }
        let bySource = (mediaSourceID.flatMap { all[$0] } ?? (json["Id"] as? String).flatMap { all[$0] } ?? all.values.first) as? [String: Any]
        let options = (bySource?.values ?? [:].values).compactMap { value -> Trickplay? in
            guard let value = value as? [String: Any] else { return nil }
            func read(_ key: String) -> Int { (value[key] as? NSNumber)?.intValue ?? 0 }
            let info = Trickplay(width: read("Width"), height: read("Height"), tileWidth: read("TileWidth"),
                                 tileHeight: read("TileHeight"), count: read("ThumbnailCount"),
                                 interval: Double(read("Interval")) / 1000)
            return info.isValid ? info : nil
        }.sorted { $0.width < $1.width }
        return options.first { $0.width >= preferredWidth } ?? options.last
    }

    /// Which sheet holds the frame for `seconds`, and where in it.
    public func frame(at seconds: Double) -> (sheet: Int, column: Int, row: Int) {
        let raw = seconds.isFinite ? Int(max(0, seconds) / interval) : 0
        let frame = min(max(0, raw), count - 1)
        let perSheet = tileWidth * tileHeight
        let inSheet = frame % perSheet
        return (frame / perSheet, inSheet % tileWidth, inSheet / tileWidth)
    }

    /// `Videos/{id}/Trickplay/{width}/{sheet}.jpg`, fetched with the
    /// Authorization header; the URL carries no token.
    public func sheetURL(server: ServerAddress, itemID: String, sheet: Int, mediaSourceID: String?) throws -> URL {
        try server.endpoint(["Videos", itemID, "Trickplay", String(width), "\(sheet).jpg"],
                            query: mediaSourceID.map { [URLQueryItem(name: "mediaSourceId", value: $0)] } ?? [])
    }
}

/// Chapters and scrub thumbnails for one title.
public struct PlayerExtras: Sendable, Equatable {
    public var chapters: [PlayerChapter] = []
    public var trickplay: Trickplay?
    public init(chapters: [PlayerChapter] = [], trickplay: Trickplay? = nil) {
        self.chapters = chapters; self.trickplay = trickplay
    }
    public static let none = PlayerExtras()
}

public extension JellyfinClient {
    /// Optional: a server without chapters or trickplay just has none.
    func playerExtras(itemID: String, mediaSourceID: String?) async throws -> PlayerExtras {
        guard let session else { throw ClientError.missingSession }
        let data = try await requestData(["Items", itemID], query: [
            URLQueryItem(name: "userId", value: session.viewer.id), .init(name: "fields", value: "Chapters,Trickplay")])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .none }
        return PlayerExtras(chapters: PlayerChapter.list(from: json),
                            trickplay: Trickplay.best(from: json, mediaSourceID: mediaSourceID))
    }

    /// One trickplay sheet as JPEG data.
    func trickplaySheet(itemID: String, trickplay: Trickplay, sheet: Int, mediaSourceID: String?) async throws -> Data {
        try await requestData(["Videos", itemID, "Trickplay", String(trickplay.width), "\(sheet).jpg"],
                              query: mediaSourceID.map { [URLQueryItem(name: "mediaSourceId", value: $0)] } ?? [],
                              accept: "image/*")
    }

    /// A chapter's still as image data, or nil when it has none.
    func chapterImage(itemID: String, chapter: PlayerChapter) async throws -> Data? {
        guard let tag = chapter.imageTag else { return nil }
        return try await requestData(["Items", itemID, "Images", "Chapter", String(chapter.imageIndex)], query: [
            .init(name: "maxWidth", value: "400"), .init(name: "quality", value: "80"), .init(name: "tag", value: tag)],
            accept: "image/*")
    }

    /// A chapter's still; fetched with the Authorization header.
    func chapterImageURL(itemID: String, chapter: PlayerChapter) throws -> URL? {
        guard let tag = chapter.imageTag else { return nil }
        return try server.endpoint(["Items", itemID, "Images", "Chapter", String(chapter.imageIndex)], query: [
            .init(name: "maxWidth", value: "400"), .init(name: "quality", value: "80"), .init(name: "tag", value: tag)])
    }
}

/// What the viewer last picked for a show (or movie), so its other episodes
/// follow it on this device, plus the subtitle and audio timing they set.
public struct TrackMemory: Codable, Equatable, Sendable {
    public var audioLanguage: String?
    public var subtitleLanguage: String?
    public var subtitlesOff = false
    public var subtitleForced = false
    /// Positive: subtitles appear later. Seconds.
    public var subtitleOffset: Double = 0
    /// Positive: sound plays later. Only the on-device player applies it.
    public var audioOffset: Double = 0

    public static let maxOffset = 10.0
    public static let step = 0.1

    public init() {}

    /// The key a choice is kept under: the show, or the movie itself.
    public static func key(for item: MediaItem) -> String { item.seriesId ?? item.id }

    /// Records the tracks just chosen; unchanged parts are kept.
    public func choosing(audio: MediaStream? = nil, subtitle: MediaStream? = nil, off: Bool = false) -> TrackMemory {
        var next = self
        if let language = Self.language(audio) { next.audioLanguage = language }
        if off { next.subtitlesOff = true }
        else if let subtitle {
            next.subtitlesOff = false
            next.subtitleForced = subtitle.isForced == true
            if let language = Self.language(subtitle) { next.subtitleLanguage = language }
        }
        return next
    }

    public static func clamp(_ offset: Double) -> Double {
        guard offset.isFinite else { return 0 }
        return (min(maxOffset, max(-maxOffset, offset)) * 10).rounded() / 10
    }

    private static func language(_ stream: MediaStream?) -> String? {
        let value = stream?.language?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// Stream indexes matching this choice; nil where nothing is remembered
    /// or this file has no track in that language.
    public func pick(_ streams: [MediaStream]) -> (audio: Int?, subtitle: Int?) {
        let audio = audioLanguage.flatMap { language in
            streams.first { $0.type == "Audio" && ViewerSettings.sameLanguage($0.language, language) }?.index
        }
        var subtitle: Int?
        if subtitlesOff { subtitle = -1 }
        else if let language = subtitleLanguage {
            let matches = streams.filter { $0.type == "Subtitle" && ViewerSettings.sameLanguage($0.language, language) }
            subtitle = (matches.first { ($0.isForced == true) == subtitleForced } ?? matches.first)?.index
        }
        return (audio, subtitle)
    }

    /// `+0.3 s`, `−1.2 s`, `In sync`.
    public static func label(_ offset: Double) -> String {
        guard abs(offset) >= 0.05 else { return "In sync" }
        return (offset < 0 ? "−" : "+") + String(format: "%.1f s", abs(offset))
    }
}

/// Track memory for each account, in UserDefaults on this device.
public struct TrackMemoryStore: Sendable {
    public let scope: String
    public init(scope: String) { self.scope = scope }

    private func key(_ id: String) -> String { "zorofin.tracks.v1.\(scope).\(id)" }

    public func memory(for id: String) -> TrackMemory? {
        guard let data = UserDefaults.standard.data(forKey: key(id)) else { return nil }
        return try? JSONDecoder().decode(TrackMemory.self, from: data)
    }

    public func save(_ memory: TrackMemory, for id: String) {
        if memory == TrackMemory() { UserDefaults.standard.removeObject(forKey: key(id)); return }
        if let data = try? JSONEncoder().encode(memory) { UserDefaults.standard.set(data, forKey: key(id)) }
    }
}
