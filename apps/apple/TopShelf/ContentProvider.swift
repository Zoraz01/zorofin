import Foundation
import TVServices
import ZorofinCore

final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        completionHandler(Self.content())
    }
    private static func content() -> (any TVTopShelfContent)? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: TopShelfSnapshot.appGroup) else { return nil }
        let store = TopShelfStore(root: container.appendingPathComponent("Library/Caches/TopShelf-v1", isDirectory: true))
        guard let snapshot = store.load() else { return nil }
        let items = snapshot.entries.compactMap { entry -> TVTopShelfCarouselItem? in
            guard let play = TopShelfLink(accountID: snapshot.accountID, itemID: entry.itemID, action: .play),
                  let details = TopShelfLink(accountID: snapshot.accountID, itemID: entry.itemID, action: .details) else { return nil }
            let item = TVTopShelfCarouselItem(identifier: "\(snapshot.accountID)-\(entry.itemID)")
            item.title = entry.title; item.contextTitle = entry.context
            // Some tvOS releases omit the separate title header. Keep the title
            // identifiable in the detail panel as well as in accessibility metadata.
            item.summary = entry.title + (entry.summary.isEmpty ? "" : " · " + entry.summary)
            item.genre = entry.genre; item.duration = entry.duration
            item.expirationDate = snapshot.createdAt.addingTimeInterval(TopShelfSnapshot.lifetime)
            let image = store.imageURL(entry)
            item.setImageURL(image, for: .screenScale1x)
            item.setImageURL(image, for: .screenScale2x)
            item.playAction = TVTopShelfAction(url: play.url)
            item.displayAction = TVTopShelfAction(url: details.url)
            return item
        }
        // A sign-out or account switch racing this read must not return the previous account.
        guard !items.isEmpty, store.load()?.revision == snapshot.revision else { return nil }
        return TVTopShelfCarouselContent(style: .details, items: items)
    }
}
