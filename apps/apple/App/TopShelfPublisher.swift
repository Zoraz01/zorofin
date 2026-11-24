import ZorofinCore
#if os(tvOS)
import Foundation
import ImageIO
import TVServices
import UniformTypeIdentifiers

/// The foreground app fetches artwork through its authenticated Jellyfin transport.
/// The extension reads only these bounded, re-encoded local images and public title metadata.
@MainActor final class TopShelfPublisher {
    private var task: Task<Void, Never>?
    private var revision = UUID()
    private var store: TopShelfStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: TopShelfSnapshot.appGroup)
            .map { TopShelfStore(root: $0.appendingPathComponent("Library/Caches/TopShelf-v1", isDirectory: true)) }
    }
    func clear() {
        task?.cancel(); task = nil; revision = UUID()
        store?.clear()
        TVTopShelfContentProvider.topShelfContentDidChange()
    }
    func publish(accountID: UUID, client: JellyfinClient, resume: [MediaItem], movies: [MediaItem]) {
        task?.cancel(); revision = UUID()
        let expected = revision
        guard let store else { return }
        task = Task {
            var entries: [TopShelfEntry] = [], images: [String: Data] = [:]
            for candidate in TopShelfSelection.candidates(resume: resume, movies: movies) {
                guard !Task.isCancelled, expected == revision else { return }
                if entries.count == 8 { break }
                let item = candidate.item
                var sources: [(String, String, String?)] = []
                if let tag = item.backdropImageTags?.first { sources.append((item.id, "Backdrop", tag)) }
                if let parent = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
                    sources.append((parent, "Backdrop", tag))
                }
                if item.isEpisode, let series = item.seriesId, !sources.contains(where: { $0.0 == series }) {
                    sources.append((series, "Backdrop", nil))
                }
                if sources.isEmpty { sources.append((item.id, "Backdrop", nil)) }
                if let tag = item.imageTags?["Thumb"] { sources.append((item.id, "Thumb", tag)) }
                // Portrait posters are deliberately not stretched into full-screen artwork.
                if item.isEpisode, let tag = item.imageTags?["Primary"] { sources.append((item.id, "Primary", tag)) }
                for (id, kind, tag) in sources {
                    guard !Task.isCancelled, expected == revision else { return }
                    do {
                        let bytes = try await client.image(itemID: id, kind: kind, tag: tag, width: 1920)
                        guard !Task.isCancelled, expected == revision else { return }
                        guard let jpeg = Self.landscapeJPEG(bytes) else { continue }
                        let name = UUID().uuidString + ".jpg"
                        let entry = TopShelfEntry(item: item, continuing: candidate.continuing, imageName: name)
                        guard entry.isValid else { break }
                        images[name] = jpeg; entries.append(entry)
                        break
                    } catch ClientError.unauthorized {
                        if !Task.isCancelled, expected == revision { clear() }
                        return
                    }
                    catch ClientError.forbidden { continue }
                    catch { if Task.isCancelled { return } }
                }
            }
            guard !Task.isCancelled, expected == revision else { return }
            guard !entries.isEmpty else { clear(); return }
            do {
                try store.save(TopShelfSnapshot(accountID: accountID, entries: entries), images: images)
                TVTopShelfContentProvider.topShelfContentDidChange()
            } catch {
                // Preserve a still-valid snapshot on an out-of-space/write failure. Never log URLs.
            }
        }
    }
    private static func landscapeJPEG(_ data: Data) -> Data? {
        guard data.count <= 12 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1920
              ] as CFDictionary), image.width >= 640, Double(image.width) / Double(image.height) >= 1.4 else { return nil }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // A fresh CGImage export omits original EXIF/location metadata.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination), result.length <= 3 * 1024 * 1024 else { return nil }
        return result as Data
    }
}
#endif

extension AppModel {
    func refreshTopShelf() {
        #if os(tvOS)
        let expected = generation
        Task {
            await waitForSettings()
            guard !Task.isCancelled, generation == expected else { return }
            guard !isDemo, preferences.homeScreenPreviews != false,
                  let account = connections.activeAccount, isCurrent(account),
                  account.session?.token == session?.token, let client else { topShelf.clear(); return }
            topShelf.publish(accountID: account.id, client: client,
                resume: homeLibrary.shelves.first(where: { $0.id == 0 })?.items ?? [],
                movies: homeLibrary.shelves.first(where: { $0.id == 2 })?.items ?? [])
        }
        #endif
    }
    func clearTopShelf() {
        #if os(tvOS)
        topShelf.clear()
        #endif
    }
}
