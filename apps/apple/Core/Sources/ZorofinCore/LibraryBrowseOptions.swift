import Foundation

public enum LibrarySort: String, CaseIterable, Identifiable, Codable, Sendable {
    case recentlyAdded, title, year
    public var id: String { rawValue }
    public var title: String {
        switch self { case .recentlyAdded: "Recently added"; case .title: "Title"; case .year: "Year" }
    }
    public var field: String {
        switch self { case .recentlyAdded: "DateCreated,SortName"; case .title: "SortName"; case .year: "ProductionYear,SortName" }
    }
    public var order: String { self == .title ? "Ascending" : "Descending" }
}

/// Part of each server query/cache identity, never applied to a partial page.
public struct LibraryBrowseOptions: Equatable, Codable, Sendable {
    public var sort: LibrarySort
    public var genre: String
    public var unwatched: Bool
    public init(sort: LibrarySort = .recentlyAdded, genre: String = "", unwatched: Bool = false) {
        self.sort = sort; self.genre = genre; self.unwatched = unwatched
    }
    public var hasFilters: Bool { !genre.isEmpty || unwatched }
}
