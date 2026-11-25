import SwiftUI
import ZorofinCore

struct Shelf: Identifiable {
    let id: Int
    let title: String
    let items: [MediaItem]
    let landscape: Bool
}

@MainActor @Observable final class HomeLibraryState {
    var shelves: [Shelf] = []
    var banner = HomeBanner()
    var featuredItems: [MediaItem] = []
    var loading: Bool = true
    var failure: String? = nil
    var refresh: Int = 0
    var homeFeed: HomeFeed? = nil
    var homeTeams: [String] = []
    var homeError: String? = nil
    var loadingRows: Bool = false
    var discovery: DiscoveryFeed = DiscoveryFeed()
    var discoveryRows: [DiscoveryRow] = []
    var rowOrder = HomeRowOrder()
    var mixPrepared = false
    var discoveryLoading: Bool = false
    var discoveryLoadID = UUID()
    var discoveryError: String? = nil
    var discoveryAutomatic: Bool = true
    var loadedAt = Date.distantPast
    var loadedRevision = -1
    var loadedRefresh = -1
    var visibleID: String?
    var rowsContract: HomeRowsContract?
    var rowsLoadedAt = Date.distantPast
    var rowsRevision = -1
    var rowsRefresh = -1
    var shelfLoadID = UUID()
    var rowLoadID = UUID()
    var liveLoading = false
    var liveError: String?
    var liveSnapshot: LiveTVSnapshot?
    var liveEvents: [LiveEvent] = []
    var hasLiveScoresFeed = false
    var liveArtwork: LiveArtworkManifest?
    var liveRevision = -1
    var liveLoadID = UUID()
    /// Live now order, favorite teams, the game cap and scores from the companion.
    @ObservationIgnored let liveScores = LiveScoresCache()
}

@MainActor @Observable final class CatalogLibraryState {
    var options = LibraryBrowseOptions()
    var genres: [String] = []
    var genresRevision = -1
    var genresFailed = false
    var items: [MediaItem] = []
    var cursor: LibraryPageCursor = LibraryPageCursor()
    var loading: Bool = false
    var error: String? = nil
    var favorites: Bool = false
    var refresh: Int = 0
    var automatic: Bool = true
    var loadedAt = Date.distantPast
    var loadedRevision = -1
    var loadedRefresh = -1
    var visibleID: String?
    var loadID = UUID()
}

@MainActor @Observable final class SearchLibraryState {
    var kind = ""
    var loadedKind = ""
    var offset = 0
    var hasMore = false
    var query: String = ""
    var results: [MediaItem] = []
    var searching: Bool = false
    var error: String? = nil
    var loadedAt = Date.distantPast
    var loadedRevision = -1
    var loadedRefresh = -1
    var visibleID: String?
    var loadedQuery = ""
    var searchLoadID = UUID()
    var recommendations: [MediaItem] = []
    var recommendationsLoading = false
    var recommendationsError: String?
    var recommendationsLoadedAt = Date.distantPast
    var recommendationsRevision = -1
    var recommendationsLoadID = UUID()
}


private enum HomeBrowseRow: Identifiable {
    case personal(HomeRow), library(Shelf), generated(DiscoveryRow)
    var id: String {
        switch self {
        case .personal(let row): row.id
        case .library(let shelf): "shelf-\(shelf.id)"
        case .generated(let row): row.id
        }
    }
    var candidate: HomeRowOrder.Candidate {
        switch self {
        case .generated: .init(id: id, kind: .generated)
        default: .init(id: id, kind: .deliberate)
        }
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var model
    private var state: HomeLibraryState { model.homeLibrary }
    let wide: Bool
    let select: (Destination) -> Void
    let open: (MediaItem) -> Void
    let play: (MediaItem, PlaybackOptions) -> Void
    private var shelves: [Shelf] { get { state.shelves } nonmutating set { state.shelves = newValue } }
    private var loading: Bool { get { state.loading } nonmutating set { state.loading = newValue } }
    private var failure: String? { get { state.failure } nonmutating set { state.failure = newValue } }
    private var refresh: Int { get { state.refresh } nonmutating set { state.refresh = newValue } }
    @State private var homeUtility: HomeUtility?
    #if os(tvOS)
    @State private var previews = TrailerPreviewEngine()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif
    private var homeFeed: HomeFeed? { get { state.homeFeed } nonmutating set { state.homeFeed = newValue } }
    private var homeError: String? { get { state.homeError } nonmutating set { state.homeError = newValue } }
    private var loadingRows: Bool { get { state.loadingRows } nonmutating set { state.loadingRows = newValue } }
    private var discovery: DiscoveryFeed { get { state.discovery } nonmutating set { state.discovery = newValue } }
    private var discoveryRows: [DiscoveryRow] { get { state.discoveryRows } nonmutating set { state.discoveryRows = newValue } }
    private var discoveryLoading: Bool { get { state.discoveryLoading } nonmutating set { state.discoveryLoading = newValue } }
    private var discoveryError: String? { get { state.discoveryError } nonmutating set { state.discoveryError = newValue } }
    private var discoveryAutomatic: Bool { get { state.discoveryAutomatic } nonmutating set { state.discoveryAutomatic = newValue } }
    @Environment(\.scenePhase) private var scenePhase
    private var hero: MediaItem? { state.banner.item }
    private var browseRows: [HomeBrowseRow] {
        let personal = (homeFeed?.rows ?? []).filter { $0.id != "requests-ready" && !$0.cards.isEmpty }.map(HomeBrowseRow.personal)
        let library = shelves.filter { $0.id >= 2 && !$0.items.isEmpty }.map(HomeBrowseRow.library)
        return personal + library + discoveryRows.map(HomeBrowseRow.generated)
    }
    private var mixedRows: [HomeBrowseRow] {
        let available = Dictionary(browseRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return state.rowOrder.ids.compactMap { available[$0] }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.isTV ? 36 : 28) {
                if !Theme.isTV {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) {
                            Brand(symbolOnly: true)
                            categoryShortcuts.fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 12)
                            headerUtilities.fixedSize(horizontal: true, vertical: false)
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            HStack { Brand(symbolOnly: true); Spacer(minLength: 12); headerUtilities }
                            ScrollView(.horizontal) { categoryShortcuts }.scrollIndicators(.hidden)
                        }
                    }.padding(.horizontal, Theme.gutter).accessibilityIdentifier("home-header")
                }
                if loading { ProgressView("Loading your library…").frame(maxWidth: .infinity).padding(50) }
                if let hero { HeroView(item: hero, wide: wide, play: play)
                    .padding(.horizontal, Theme.gutter).accessibilityIdentifier("home-banner") }
                if let failure {
                    StatusView(title: shelves.allSatisfy({ $0.items.isEmpty }) ? "Library unavailable" : "Some shelves couldn't load",
                               detail: failure, icon: "wifi.exclamationmark", retry: { refresh += 1 })
                }
                ForEach(shelves.filter { $0.id == 0 && !$0.items.isEmpty }) { shelf in
                    // Continue Watching opens the episode page (Resume, the series and its
                    // episodes) instead of starting playback, as Apple TV's own apps do.
                    MediaShelf(title: shelf.title, items: shelf.items, landscape: shelf.landscape).id("shelf-\(shelf.id)")
                }
                if let ready = homeFeed?.rows.first(where: { $0.id == "requests-ready" }) {
                    CustomHomeShelf(row: ready, title: "My requests", retry: { refresh += 1 }).id("requests-ready")
                }
                if let snapshot = state.liveSnapshot {
                    LiveEventsShelf(snapshot: snapshot, events: state.liveEvents,
                        allChannels: { select(.live) }, open: open).id("sports-live-events")
                }
                CollectionsHomeShelf(refresh: refresh).id("collections-\(model.generation)")
                homeRowsStatus
                ForEach(mixedRows) { row in
                    Group {
                        switch row {
                        case .personal(let personal):
                            CustomHomeShelf(row: personal, retry: { refresh += 1 })
                        case .library(let shelf):
                            #if os(tvOS)
                            if !shelf.landscape && previewable(shelf.items) {
                                PreviewShelf(id: row.id, title: shelf.title, items: shelf.items)
                            } else { MediaShelf(title: shelf.title, items: shelf.items, landscape: shelf.landscape) }
                            #else
                            MediaShelf(title: shelf.title, items: shelf.items, landscape: shelf.landscape)
                            #endif
                        case .generated(let generated):
                            #if os(tvOS)
                            if previewable(generated.items) {
                                PreviewShelf(id: row.id, title: generated.title, items: generated.items)
                            } else { MediaShelf(title: generated.title, items: generated.items) }
                            #else
                            MediaShelf(title: generated.title, items: generated.items)
                            #endif
                        }
                    }.id(row.id).accessibilityIdentifier(row.id)
                }
                if state.mixPrepared && !loading && !model.isDemo && model.client != nil {
                    BrowseContinuation(hasMore: discovery.hasMore, loading: discoveryLoading,
                        error: discoveryError, automatic: discoveryAutomatic,
                        revision: "\(refresh)-\(discoveryRows.count)", load: loadDiscovery)
                }
                if !loading && failure == nil && shelves.allSatisfy({ $0.items.isEmpty }) {
                    StatusView(title: "Your library is ready for its first title", detail: "Media added to your Jellyfin server will appear here.")
                }
            }.scrollTargetLayout().padding(.top, wide ? 16 : 8).padding(.bottom, 24)
        }.background(Theme.background)
            .scrollPosition(id: Binding(get: { state.visibleID }, set: { state.visibleID = $0 }))
            .task(id: "\(refresh)-\(model.libraryRevision)") { await load(); await prepareMix() }
            .task(id: "\(refresh)-\(model.homeRevision)-\(model.features.homeRowsContract?.rawValue ?? 0)") {
                await loadRows(); await prepareMix()
                #if DEBUG
                // Simulator checks: --home-scroll-row N scrolls Home to the Nth mixed row.
                let arguments = ProcessInfo.processInfo.arguments
                if let flag = arguments.firstIndex(of: "--home-scroll-row"), flag + 1 < arguments.count,
                   let index = Int(arguments[flag + 1]), mixedRows.indices.contains(index) {
                    try? await Task.sleep(for: .seconds(2)); state.visibleID = mixedRows[index].id
                }
                #endif
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    if scenePhase == .active { await loadRows() }
                }
            }
            .task(id: "live-\(model.libraryRevision)-\(model.features.liveArtwork)-\(model.features.sportsEvents)-\(scenePhase == .active)") {
                guard scenePhase == .active else { return }
                state.liveRevision = -1
                while !Task.isCancelled {
                    await loadLiveEvents()
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await load(); await loadRows(); await prepareMix() }
                }
            }
            .sheet(item: $homeUtility) { utility in
                HomeUtilityView(utility: utility).id(model.generation)
            }
            #if os(tvOS)
            .environment(\.trailerPreview, previews)
            .task(id: "\(model.generation)-\(model.preferences.autoplayPreviews != false)-\(reduceMotion)-\(model.preferences.reduceMotion)") {
                // Reduce Motion (system or app) acts as autoplay off.
                previews.configure(client: model.client, autoplay: model.preferences.autoplayPreviews != false && !reduceMotion && !model.preferences.reduceMotion)
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { previews.stopAll(endVisit: true) } }
            .onChange(of: model.generation) { _, _ in previews.stopAll(endVisit: true) }
            .onDisappear { previews.stopAll(endVisit: true) }
            #endif
    }

    #if os(tvOS)
    /// Rows of movies and shows preview; mixed rows of episodes or channels keep today's behavior.
    private func previewable(_ items: [MediaItem]) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--no-trailer-previews") { return false }
        #endif
        return !items.isEmpty && items.allSatisfy { $0.type == "Movie" || $0.type == "Series" }
    }
    #endif

    private var categoryShortcuts: some View {
        HStack(spacing: 10) {
            ForEach([Destination.movies, .shows, .live]) { destination in
                Button(destination == .shows ? "Shows" : destination.rawValue) { select(destination) }
                    .buttonStyle(ZoroButtonStyle()).fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var headerUtilities: some View {
        HStack(spacing: 8) {
            if model.features.support {
                Button { homeUtility = .support } label: {
                    InterfaceIcon(name: "support", size: 24).frame(width: Theme.target, height: Theme.target)
                }.buttonStyle(ArtworkButtonStyle()).accessibilityLabel("Support").accessibilityIdentifier("home-support")
            }
            #if os(iOS)
            if model.hasNotifications { MobileNotificationButton(open: open) }
            #endif
            Button { select(.search) } label: {
                Image(systemName: "magnifyingglass").frame(width: Theme.target, height: Theme.target)
            }.buttonStyle(ArtworkButtonStyle()).accessibilityLabel("Search").accessibilityIdentifier("home-search")
        }.font(.system(size: 20))
    }
    private func loadLiveEvents() async { await state.refreshLiveEvents(model: model) }
    @ViewBuilder private var homeRowsStatus: some View {
        if loadingRows && homeFeed == nil { ProgressView().padding(.horizontal, Theme.gutter) }
        if homeError != nil {
            Button("Retry Home rows") { refresh += 1 }.buttonStyle(ZoroButtonStyle())
                .padding(.horizontal, Theme.gutter)
        }
    }
    private func updateBanner() {
        let recent = shelves.filter { $0.id >= 2 }.flatMap(\.items)
        let discovered = discoveryRows.flatMap(\.items)
        let continued = shelves.filter { $0.id == 0 }.flatMap(\.items)
        state.banner.update(recent + discovered + continued, featured: state.featuredItems)
    }
    private func appendRowOrder() {
        guard state.mixPrepared else { return }
        state.rowOrder.append(browseRows.map(\.candidate))
    }
    private func prepareMix() async {
        guard !state.mixPrepared,
              state.loadedRevision >= 0 || failure != nil || !shelves.isEmpty,
              model.isDemo || model.client == nil || state.rowsRevision >= 0 || homeError != nil || homeFeed != nil else { return }
        state.mixPrepared = true
        // Show the server and library rows as soon as they're here. One bounded
        // discovery batch is added below them when it arrives, instead of
        // holding every row back until discovery finishes.
        appendRowOrder()
        await loadDiscovery()
        appendRowOrder()
    }
    private func loadDiscovery() async {
        guard !discoveryLoading, discovery.hasMore, let client = model.client else { return }
        let generation = model.generation, revision = refresh, loadID = UUID()
        state.discoveryLoadID = loadID
        discoveryLoading = true; discoveryError = nil
        defer {
            if generation == model.generation && state.discoveryLoadID == loadID {
                discoveryLoading = false
                appendRowOrder()
            }
        }
        var next = discovery
        let fixedIDs = Set(shelves.flatMap { $0.items.map(\.id) } + (homeFeed?.rows.flatMap { $0.cards.map { $0.item.id } } ?? []))
        do {
            let rows = try await next.next(client: client, excluding: fixedIDs)
            guard !Task.isCancelled, generation == model.generation, revision == refresh,
                  state.discoveryLoadID == loadID else { return }
            discovery = next; discoveryRows += rows
            updateBanner()
            // Duplicate-only / sparse pages never trigger a background request loop.
            discoveryAutomatic = !rows.isEmpty
        } catch {
            guard !Task.isCancelled, generation == model.generation, revision == refresh else { return }
            discoveryError = error.localizedDescription
        }
    }
    private func loadRows() async {
        #if DEBUG
        if model.isDemo {
            homeFeed = HomeFeed(generatedAt: ISO8601DateFormatter().string(from: .now), preferences: .init(),
                rows: HomePreferences.rowOptions.map { option in
                    let items = option.id == "new-episodes" ? PreviewLibrary.episodes : PreviewLibrary.movies
                    return HomeRow(id: option.id, title: option.title, description: "Preview · Example titles only", cards:
                        option.id == "sports" ? [] : Array(items.prefix(4)).enumerated().map { index, item in
                            HomeRowCard(id: item.id, item: item, subtitle: option.id == "short-movies" ? "85 min · Example" : "Example selection",
                                badges: option.id == "showcase" ? ["4K", "HDR10"] : option.id == "popular" ? ["#\(index + 1)"] : [])
                        })
                })
            return
        }
        #endif
        guard !model.isDemo, let client = model.client else { homeFeed = nil; homeError = nil; return }
        let generation = model.generation, contract = model.features.homeRowsContract
        let changed = state.rowsContract != contract
        // A switch between two known contracts retires the old one's cache. The
        // first load after launch is not a switch and may show the stored rows.
        let switching = changed && state.rowsContract != nil
        if changed {
            state.rowsContract = contract; state.rowLoadID = UUID()
            homeFeed = nil; homeError = nil; state.rowsLoadedAt = .distantPast
        }
        let lifetime: TimeInterval = homeError != nil ? 30 : contract == .plugin ? 60 : 300
        guard changed || state.rowsRevision != model.homeRevision || state.rowsRefresh != refresh ||
              Date().timeIntervalSince(state.rowsLoadedAt) >= lifetime else { return }
        let loadID = UUID(), revision = model.homeRevision, requestedRefresh = refresh
        // The viewer changed their rows or teams, or pulled to refresh: ask the
        // server to rebuild instead of reusing its last-minute copy.
        let fresh = (state.rowsRevision >= 0 && state.rowsRevision != revision) ||
            (state.rowsRefresh >= 0 && state.rowsRefresh != requestedRefresh)
        state.rowLoadID = loadID
        func current() -> Bool {
            !Task.isCancelled && generation == model.generation && state.rowLoadID == loadID &&
                contract == model.features.homeRowsContract && revision == model.homeRevision && requestedRefresh == refresh
        }
        loadingRows = true; homeError = nil
        defer { if current() { loadingRows = false } }
        if switching {
            // Retire the prior contract's cached/in-flight legacy result before
            // allowing a switch back. Plugin responses are never persisted.
            if let url = try? client.server.endpoint(HomeRowsContract.legacy.path) {
                await client.responseCache?.remove(url.absoluteString, policy: .home)
            }
            guard current() else { return }
        }
        if homeFeed == nil && !switching {
            // Show the last rows straight away; the network answer replaces them.
            let reader = client.readingCache()
            if contract == .plugin {
                if let stored = try? await reader.homeFeed(contract: .plugin) {
                    guard current() else { return }
                    homeFeed = stored
                }
            } else {
                var server: HomeFeed?
                if contract == .legacy { server = try? await reader.homeFeed() }
                let rows = (try? await reader.clientHomeRows(teams: state.homeTeams)) ?? []
                guard current() else { return }
                if server != nil || rows.contains(where: { !$0.cards.isEmpty }) {
                    homeFeed = ClientHomeRows.feed(client: rows, server: server, teams: state.homeTeams)
                }
            }
        }
        do {
            let loaded = try await client.loadHomeRows(contract: contract, fallbackTeams: state.homeTeams, fresh: fresh)
            guard current() else { return }
            state.homeTeams = loaded.feed.preferences.teams
            homeFeed = loaded.feed; homeError = loaded.serverError
            appendRowOrder()
            state.rowsLoadedAt = .now; state.rowsRevision = revision; state.rowsRefresh = requestedRefresh
            let enriched = try await client.enrichHomeFeed(loaded.feed)
            guard current() else { return }
            homeFeed = enriched
        } catch {
            guard current() else { return }
            homeFeed = nil; homeError = error.localizedDescription
            state.rowsLoadedAt = .now
        }
    }
    private func load() async {
        guard state.loadedRevision != model.libraryRevision || state.loadedRefresh != refresh ||
              Date().timeIntervalSince(state.loadedAt) >= 60 else { return }
        let generation = model.generation, revision = model.libraryRevision, loadID = UUID()
        state.shelfLoadID = loadID
        loading = shelves.isEmpty; failure = nil
        defer { if generation == model.generation && state.shelfLoadID == loadID { loading = false } }
        if model.isDemo {
            shelves = [Shelf(id: 0, title: "Continue Watching", items: Array(PreviewLibrary.episodes.prefix(2)), landscape: true),
                       Shelf(id: 2, title: "Recently Added Movies", items: PreviewLibrary.movies, landscape: false),
                       Shelf(id: 3, title: "Recently Added Shows", items: PreviewLibrary.shows, landscape: false)]
            updateBanner()
            state.loadedAt = .now; state.loadedRevision = revision; state.loadedRefresh = refresh
            return
        }
        guard let client = model.client else { return }
        if shelves.isEmpty { await loadShelves(client.readingCache(), generation: generation, loadID: loadID, snapshot: true) }
        guard !Task.isCancelled, generation == model.generation else { return }
        await loadShelves(client, generation: generation, loadID: loadID, snapshot: false)
        guard !Task.isCancelled, generation == model.generation, revision == model.libraryRevision, state.shelfLoadID == loadID else { return }
        if failure == nil {
            state.loadedAt = .now; state.loadedRevision = revision; state.loadedRefresh = refresh
            model.refreshTopShelf()
        }
    }
    private func loadShelves(_ client: JellyfinClient, generation: UUID, loadID: UUID, snapshot: Bool) async {
        await withTaskGroup(of: (Int, [MediaItem]?, String?).self) { group in
            for index in [0, 1, 2, 3] {
                group.addTask {
                    do {
                        let page: ItemPage
                        switch index {
                        case 0:
                            let feed = try await client.continueWatching()
                            return (index, feed.items, !snapshot && feed.isPartial ? "Some Continue Watching titles couldn't load. Try again." : nil)
                        case 1: page = try await client.homeBannerItems()
                        case 2: page = try await client.items(type: "Movie")
                        default: page = try await client.items(type: "Series")
                        }
                        return (index, page.items, nil)
                    } catch is CancellationError { return (index, nil, nil) }
                    catch { return (index, nil, snapshot ? nil : error.localizedDescription) }
                }
            }
            let names = [0: "Continue Watching", 2: "Recently Added Movies", 3: "Recently Added Shows"]
            // Publish each shelf as soon as it arrives, without waiting for the slowest request.
            for await (index, items, error) in group {
                guard !Task.isCancelled, generation == model.generation, state.shelfLoadID == loadID else { continue }
                if index == 1 {
                    // Optional feature selection never blocks the core shelves.
                    if let items { state.featuredItems = items; updateBanner() }
                    continue
                }
                if let items {
                    shelves.removeAll { $0.id == index }
                    shelves.append(Shelf(id: index, title: names[index] ?? "", items: items, landscape: index == 0))
                    shelves.sort { $0.id < $1.id }; loading = false
                    updateBanner()
                    appendRowOrder()
                }
                if let error { failure = error }
            }
        }
    }

}

private struct HeroView: View {
    @Environment(\.adaptiveWindow) private var window
    @Environment(\.dynamicTypeSize) private var textSize
    let item: MediaItem
    let wide: Bool
    let play: (MediaItem, PlaybackOptions) -> Void
    var body: some View {
        Group {
            if textSize.isAccessibilitySize && !Theme.isTV {
                VStack(alignment: .leading, spacing: 0) {
                    MediaArtwork(item: item, landscape: true, width: 1600, showPreviewTitle: false)
                        .aspectRatio(16 / 9, contentMode: .fit)
                    information.padding(24)
                }.background(Theme.panel)
            } else {
                ZStack(alignment: .bottomLeading) {
                    MediaArtwork(item: item, landscape: wide, width: wide ? 1600 : 900, showPreviewTitle: false)
                    if wide && !Theme.isTV {
                        LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
                    information.frame(maxWidth: wide && !Theme.isTV ? 620 : .infinity, alignment: .leading)
                        .padding(Theme.isTV ? 40 : wide ? 32 : 24)
                }.frame(height: Theme.isTV ? 480 : wide ? window.heroHeight : 470)
            }
        }.clipShape(RoundedRectangle(cornerRadius: Theme.isTV ? 24 : wide ? 20 : 18))
    }
    private var information: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.name).font(Theme.font(wide ? 48 : 36, weight: .bold, relativeTo: .largeTitle))
                .lineLimit(textSize.isAccessibilitySize ? nil : 2)
            MetadataLine(item: item)
            if wide, let overview = item.overview { Text(overview).font(Theme.font(20)).foregroundStyle(Theme.muted).lineLimit(2).frame(maxWidth: 620, alignment: .leading) }
            let layout = textSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Button { play(item, .init(startTicks: item.resumeTicks)) } label: {
                    Label(item.resumeTicks > 0 ? "Resume" : "Play", systemImage: "play.fill")
                }.buttonStyle(ZoroButtonStyle(white: true))
                HStack(spacing: 12) {
                    NavigationLink(value: item) { Image(systemName: "info.circle").font(.system(size: 24)).frame(width: Theme.target, height: Theme.target) }
                        .buttonStyle(ArtworkButtonStyle()).background(.white.opacity(0.12), in: Circle()).accessibilityLabel("Details for \(item.name)")
                    FavoriteButton(item: item)
                }
            }
        }
    }
}

struct MetadataLine: View {
    let item: MediaItem
    var body: some View {
        HStack(spacing: 12) {
            if let year = item.productionYear { Text(String(year)) }
            if !item.durationLabel.isEmpty { Text(item.durationLabel) }
            if let rating = item.officialRating { Text(rating).padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4)) }
        }.font(Theme.font(Theme.isTV ? 22 : 14, weight: .medium)).foregroundStyle(Theme.muted)
    }
}

struct MediaShelf: View {
    let title: String
    let items: [MediaItem]
    var landscape = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: title).padding(.horizontal, Theme.gutter)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.isTV ? 28 : 14) {
                    ForEach(items) { item in
                        NavigationLink(value: item) { MediaCard(item: item, landscape: landscape) }
                            .buttonStyle(ArtworkButtonStyle())
                            .accessibilityIdentifier("item-\(item.id)")
                    }
                }.padding(.horizontal, Theme.gutter).padding(.vertical, Theme.isTV ? 18 : 3)
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }
}

struct MediaCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.adaptiveWindow) private var window
    let item: MediaItem
    var landscape = false
    var flexible = false
    var availableFormats: [String] = []
    /// Replaces the year/episode line, for a row's one context label ("85 min").
    var label: String? = nil
    private var qualityBadges: [String] {
        guard model.preferences.showQualityBadges != false else { return [] }
        let badges = item.quality().thumbnailBadges
        return badges.isEmpty ? availableFormats.map { $0 == "Dolby Vision" ? "DV" : $0 } : badges
    }
    private var width: CGFloat { (Theme.isTV ? (landscape ? 360 : 212) : (landscape ? window.landscapeCardWidth : window.posterWidth)) * model.posterScale }
    private var ratingText: String? {
        guard model.preferences.showRatings, let rating = item.communityRating else { return nil }
        return String(format: "%.1f", rating)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            MediaArtwork(item: item, landscape: landscape, width: landscape ? 720 : 420)
                .aspectRatio(landscape ? 16 / 9 : 2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topTrailing) {
                    if let ratingText {
                        Label(ratingText, systemImage: "star.fill")
                            .font(Theme.font(Theme.isTV ? 18 : 12, weight: .bold))
                            .foregroundStyle(.yellow).lineLimit(1)
                            .padding(.horizontal, Theme.isTV ? 10 : 8).padding(.vertical, 5)
                            .background(.black.opacity(0.82), in: Capsule())
                            .padding(Theme.isTV ? 12 : 8)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if !qualityBadges.isEmpty {
                        Text(qualityBadges.joined(separator: " · "))
                            .font(Theme.font(Theme.isTV ? 16 : 10, weight: .bold))
                            .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.85)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 5))
                            .padding(.horizontal, 8)
                            .padding(.bottom, model.preferences.showProgress && item.resumeTicks > 0 ? 16 : 8)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottom) {
                    if model.preferences.showProgress, item.resumeTicks > 0, let duration = item.runTimeTicks, duration > 0 {
                        GeometryReader { geometry in
                            Rectangle().fill(Theme.jade).frame(width: geometry.size.width * min(1, Double(item.resumeTicks) / Double(duration)))
                        }.frame(height: 4).padding(.horizontal, 8).padding(.bottom, 6)
                    }
                }
            if model.preferences.showTitles {
                Text(item.displayTitle).font(Theme.font(Theme.isTV ? 22 : 15, weight: .semibold)).lineLimit(1)
                Text(label ?? (item.isEpisode ? item.episodeLabel : item.productionYear.map(String.init) ?? (item.isLive ? "Live TV" : "")))
                    .font(Theme.font(Theme.isTV ? 17 : 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }.frame(width: flexible ? nil : width).foregroundStyle(Theme.text)
            .accessibilityElement(children: .ignore).accessibilityLabel(item.isEpisode ? "\(item.displayTitle), \(item.episodeLabel)" : item.name)
            .accessibilityValue(([ratingText.map { "Rated \($0) out of 10" }].compactMap { $0 }
                + (model.preferences.showQualityBadges == false ? [] : item.quality().badges.isEmpty ? availableFormats : item.quality().badges)).joined(separator: ", "))
    }
}

struct FavoriteButton: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    var compact = false
    var labeled = false
    @State private var favorite: Bool?
    @State private var busy = false
    private var value: Bool { favorite ?? item.userData?.isFavorite ?? false }
    var body: some View {
        Group {
            if labeled { action.buttonStyle(ZoroButtonStyle()) }
            else if compact { action.buttonStyle(DetailIconStyle()) }
            else { action.buttonStyle(ArtworkButtonStyle()).background(.white.opacity(0.08), in: Circle()) }
        }.disabled(busy).accessibilityLabel(value ? "Remove from favorites" : "Add to favorites")
            .accessibilityValue(value ? "Favorited" : "Not favorited")
            .help(value ? "Remove from favorites" : "Add to favorites")
            .accessibilityIdentifier("favorite-" + item.id)
    }
    private var action: some View {
        Button {
            guard !busy else { return }
            if model.isDemo { favorite = !value; return }
            guard let client = model.client else { return }
            let next = !value, generation = model.generation
            busy = true
            Task {
                defer { busy = false }
                do {
                    let result = try await client.favorite(itemID: item.id, value: next)
                    guard generation == model.generation else { return }
                    favorite = result.isFavorite ?? next
                    model.libraryRevision += 1
                    if item.isSeries { model.homeRevision += 1 }
                } catch { if generation == model.generation { model.message = error.localizedDescription } }
            }
        } label: {
            if labeled {
                Label(value ? "Favorited" : "Favorite", systemImage: value ? "heart.fill" : "heart").frame(maxWidth: .infinity)
            } else if compact {
                Image(systemName: value ? "heart.fill" : "heart").foregroundStyle(value ? Theme.jade : Theme.text)
            }
            else {
                Image(systemName: value ? "heart.fill" : "heart").font(.system(size: Theme.isTV ? 28 : 23))
                    .foregroundStyle(value ? Theme.jade : Theme.text).frame(width: Theme.target, height: Theme.target)
            }
        }
    }
}

/// Visibility-driven paging with a focusable / VoiceOver-friendly retry fallback.
private struct BrowseContinuation: View {
    let hasMore: Bool
    let loading: Bool
    let error: String?
    var automatic = true
    let revision: String
    let load: () async -> Void
    @State private var visible = false
    @State private var pending: Task<Void, Never>?
    private func begin(automaticOnly: Bool) {
        guard hasMore, !loading else { return }
        if automaticOnly && (!visible || !automatic || error != nil) { return }
        pending?.cancel()
        pending = Task { await load() }
    }
    var body: some View {
        Group {
            if hasMore {
                VStack(spacing: 12) {
                    if loading { ProgressView().accessibilityLabel("Loading more titles") }
                    if let error { Text(error).font(Theme.font(14)).foregroundStyle(Theme.muted) }
                    Button(error == nil ? "Explore more" : "Try again") { begin(automaticOnly: false) }
                        .buttonStyle(ZoroButtonStyle()).disabled(loading)
                }.frame(maxWidth: .infinity).padding(.vertical, 16)
                    .accessibilityIdentifier("browse-continuation")
                    .onScrollVisibilityChange(threshold: 0.1) {
                        visible = $0
                        if $0 { begin(automaticOnly: true) }
                    }
                    .onChange(of: revision) { _, _ in begin(automaticOnly: true) }
                    .onChange(of: loading) { _, busy in if !busy { begin(automaticOnly: true) } }
                    .onDisappear { visible = false; pending?.cancel() }
            }
        }
    }
}

struct CatalogView: View {
    @Environment(AppModel.self) private var model
    private var state: CatalogLibraryState { model.catalogLibrary(kind) }
    let title: String
    let kind: String
    let wide: Bool
    let back: () -> Void
    private var items: [MediaItem] { get { state.items } nonmutating set { state.items = newValue } }
    private var cursor: LibraryPageCursor { get { state.cursor } nonmutating set { state.cursor = newValue } }
    private var loading: Bool { get { state.loading } nonmutating set { state.loading = newValue } }
    private var error: String? { get { state.error } nonmutating set { state.error = newValue } }
    private var favorites: Bool { get { state.favorites } nonmutating set { state.favorites = newValue } }
    private var refresh: Int { get { state.refresh } nonmutating set { state.refresh = newValue } }
    private var automatic: Bool { get { state.automatic } nonmutating set { state.automatic = newValue } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HStack {
                    if !Theme.isTV {
                        Button(action: back) { Image(systemName: "chevron.left").frame(width: Theme.target, height: Theme.target) }
                            .buttonStyle(.plain).accessibilityLabel("Back to Home")
                        Text(title).font(Theme.font(30, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer()
                    if kind != "TvChannel" { controls }
                }
                #if os(tvOS)
                if kind == "TvChannel" { TVLiveTVAvailabilityNotice() }
                #endif
                if !items.isEmpty { MediaGrid(items: items, wide: wide, landscape: kind == "TvChannel") }
                if !model.isDemo {
                    BrowseContinuation(hasMore: cursor.hasMore, loading: loading, error: error,
                        automatic: automatic, revision: "\(refresh)-\(cursor.offset)") { await load(reset: false) }
                }
                if !loading && error == nil && items.isEmpty {
                    StatusView(title: state.options.hasFilters ? "No matching titles" : "No titles here yet",
                               detail: state.options.hasFilters ? "Try a different filter, or clear the filters." : favorites ? "Add favorites from a title's details." : "Titles available to your account will appear here.")
                }
            }.padding(.horizontal, Theme.gutter).padding(.top, 20).padding(.bottom, 24)
        }.scrollPosition(id: Binding(get: { state.visibleID }, set: { state.visibleID = $0 }))
            .task(id: "\(refresh)-\(model.libraryRevision)") { await load(reset: true) }
            .task(id: "genres-\(model.generation)-\(model.libraryRevision)-\(kind)") { await loadGenres() }
            #if os(iOS)
            .refreshable { await model.client?.responseCache?.invalidateMetadata(); refresh += 1 }
            #endif
    }
    /// Symbols, not words: sort, filter and favorites sit beside the title.
    private var controls: some View {
        HStack(spacing: Theme.isTV ? 16 : 8) {
            Menu {
                Picker("Sort by", selection: Binding(get: { state.options.sort }, set: { state.options.sort = $0; resetQuery() })) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }
                .buttonStyle(DetailIconStyle()).accessibilityLabel("Sort").accessibilityValue(state.options.sort.title)
                .accessibilityIdentifier("library-sort")
            Menu {
                Picker("Genre", selection: Binding(get: { state.options.genre }, set: { state.options.genre = $0; resetQuery() })) {
                    Text("All genres").tag("")
                    ForEach(Array(Set(state.genres + (state.options.genre.isEmpty ? [] : [state.options.genre]))).sorted(), id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
                Toggle("Unwatched only", isOn: Binding(get: { state.options.unwatched }, set: { state.options.unwatched = $0; resetQuery() }))
                if state.genresFailed { Button("Retry genres") { Task { await loadGenres(force: true) } } }
                if state.options.hasFilters {
                    Button("Clear filters", role: .destructive) { state.options.genre = ""; state.options.unwatched = false; resetQuery() }
                }
            } label: {
                Image(systemName: state.options.hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(state.options.hasFilters ? Theme.jade : Theme.text)
            }.buttonStyle(DetailIconStyle()).accessibilityLabel("Filter")
                .accessibilityValue([state.options.genre.isEmpty ? "All genres" : state.options.genre, state.options.unwatched ? "Unwatched only" : nil].compactMap { $0 }.joined(separator: ", "))
                .accessibilityIdentifier("library-filter")
            Button { favorites.toggle(); resetQuery() } label: {
                Image(systemName: favorites ? "heart.fill" : "heart").foregroundStyle(favorites ? Theme.jade : Theme.text)
            }.buttonStyle(DetailIconStyle()).accessibilityLabel("Favorites only")
                .accessibilityAddTraits(favorites ? .isSelected : []).accessibilityIdentifier("library-favorites")
        }
    }
    private func resetQuery() {
        state.loadID = UUID(); items = []; cursor = LibraryPageCursor(); state.visibleID = nil
        error = nil; refresh += 1
    }
    private func loadGenres(force: Bool = false) async {
        guard kind != "TvChannel", force || state.genresRevision != model.libraryRevision else { return }
        let generation = model.generation, revision = model.libraryRevision
        do {
            let genres: [String]
            if model.isDemo { genres = Array(Set((PreviewLibrary.movies + PreviewLibrary.shows).flatMap { $0.genres ?? [] })).sorted() }
            else if let client = model.client { genres = try await client.libraryGenres(type: kind) }
            else { return }
            guard !Task.isCancelled, generation == model.generation, revision == model.libraryRevision else { return }
            state.genres = genres; state.genresRevision = revision; state.genresFailed = false
        } catch {
            guard !Task.isCancelled, generation == model.generation else { return }
            state.genresFailed = true
        }
    }
    private func load(reset: Bool) async {
        if reset && state.loadedRefresh == refresh && state.loadedRevision == model.libraryRevision {
            if cursor.offset > 30 || Date().timeIntervalSince(state.loadedAt) < (kind == "TvChannel" ? 60 : 300) { return }
        }
        guard reset || (!loading && cursor.hasMore) else { return }
        let generation = model.generation, revision = refresh, libraryRevision = model.libraryRevision, options = state.options
        let loadID = UUID(); state.loadID = loadID
        loading = true; error = nil
        let offset = reset ? 0 : cursor.offset
        defer { if generation == model.generation && state.loadID == loadID { loading = false } }
        if model.isDemo {
            items = kind == "Series" ? PreviewLibrary.shows : kind == "TvChannel" ? [] : PreviewLibrary.movies
            if favorites { items = [] }
            if options.unwatched { items = items.filter { $0.userData?.played != true } }
            if !options.genre.isEmpty { items = items.filter { $0.genres?.contains(options.genre) == true } }
            if options.sort == .title { items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
            if options.sort == .year { items.sort { ($0.productionYear ?? 0) > ($1.productionYear ?? 0) } }
            return
        }
        guard let client = model.client else { return }
        if reset && items.isEmpty {
            let cached = kind == "TvChannel" ? try? await client.readingCache().channels() :
                try? await client.readingCache().items(type: kind, favorites: favorites, options: options)
            if let cached, !Task.isCancelled, generation == model.generation, revision == refresh, state.loadID == loadID { items = cached.items }
        }
        do {
            let page = kind == "TvChannel" ? try await client.channels(start: offset) :
                try await client.items(type: kind, start: offset, favorites: favorites, options: options)
            guard !Task.isCancelled, generation == model.generation, revision == refresh, libraryRevision == model.libraryRevision, state.loadID == loadID else { return }
            if reset { items = []; cursor = LibraryPageCursor(); automatic = true }
            cursor.accept(page, limit: 30)
            state.loadedAt = .now; state.loadedRevision = libraryRevision; state.loadedRefresh = refresh
            var existing = Set(items.map(\.id))
            let additions = page.items.filter { existing.insert($0.id).inserted }
            items += additions; automatic = !additions.isEmpty
        } catch {
            guard !Task.isCancelled, generation == model.generation, revision == refresh, state.loadID == loadID else { return }
            self.error = error.localizedDescription
        }
    }
}

struct MediaGrid: View {
    @Environment(AppModel.self) private var model
    let items: [MediaItem]
    let wide: Bool
    var landscape = false
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: (Theme.isTV ? 210 : wide ? 180 : 140) * model.posterScale), spacing: Theme.isTV ? 28 : 16)], alignment: .leading, spacing: 28) {
            ForEach(items) { item in
                NavigationLink(value: item) { MediaCard(item: item, landscape: landscape, flexible: true) }
                    .buttonStyle(ArtworkButtonStyle()).accessibilityIdentifier("item-\(item.id)")
            }
        }.scrollTargetLayout().padding(.vertical, Theme.isTV ? 16 : 0)
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var model
    private var state: SearchLibraryState { model.searchLibrary }
    let wide: Bool
    let openRequests: () -> Void
    @State private var recommendationRetry = 0
    @State private var searchRetry = 0
    private var query: String { state.query }
    private var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matchingResults: [MediaItem] { state.loadedQuery == text && state.loadedKind == state.kind ? state.results : [] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Search").font(Theme.font(Theme.isTV ? 44 : 30, weight: .bold))
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("Search your library", text: Binding(get: { query }, set: updateQuery))
                        .accessibilityIdentifier("library-search")
                    if !query.isEmpty {
                        Button { updateQuery("") } label: {
                            Image(systemName: "xmark.circle.fill").frame(width: Theme.target, height: Theme.target)
                        }.accessibilityLabel("Clear search").accessibilityIdentifier("clear-search")
                    }
                }.modifier(ServerFieldInput())
                // Immediate presentation switch, independent of network completion.
                if text.isEmpty { recommendations }
                else {
                    resultTypeControl
                    if state.searching { ProgressView("Searching…").frame(maxWidth: .infinity).padding(24) }
                    if !matchingResults.isEmpty {
                        resultRows
                    } else if !state.searching && state.loadedQuery == text && state.error == nil {
                        StatusView(title: "No matching titles", detail: "Try another title or spelling.", icon: "magnifyingglass")
                    }
                    if let error = state.error {
                        Text(error).foregroundStyle(.orange)
                        Button("Retry search") { Task { await search(more: !matchingResults.isEmpty && state.hasMore) } }.buttonStyle(ZoroButtonStyle())
                    }
                    if model.extensionEnabled {
                        Button("Can't find it? Open Requests", action: openRequests).buttonStyle(ZoroButtonStyle())
                    }
                }
            }.padding(Theme.gutter).padding(.bottom, 24)
        }
        .task(id: "search-\(model.libraryRevision)-\(searchRetry)-\(state.kind)-\(query)") { await search() }
        .task(id: "recommendations-\(text.isEmpty)-\(model.libraryRevision)-\(recommendationRetry)") {
            if text.isEmpty { await loadRecommendations() }
        }
    }
    @ViewBuilder private var recommendations: some View {
        if !state.recommendations.isEmpty {
            SectionTitle(title: "Recommended")
            MediaGrid(items: state.recommendations, wide: wide)
                .accessibilityIdentifier("search-recommendations")
        } else if state.recommendationsLoading || (state.recommendationsRevision < 0 && state.recommendationsError == nil) {
            ProgressView("Finding recommendations…").frame(maxWidth: .infinity).padding(24)
        } else if state.recommendationsError == nil {
            StatusView(title: "Explore your library", detail: "Recommended movies and shows will appear here as your library grows.", icon: "film")
        }
        if state.recommendationsError != nil {
            Button("Retry recommendations") {
                state.recommendationsLoadedAt = .distantPast
                recommendationRetry += 1
            }.buttonStyle(ZoroButtonStyle())
        }
    }
    private func updateQuery(_ value: String) {
        state.query = value
        state.searchLoadID = UUID()
        state.error = nil
        state.searching = !text.isEmpty && (state.loadedQuery != text || state.loadedKind != state.kind)
    }
    private func search(more: Bool = false) async {
        let requested = text, generation = model.generation, revision = model.libraryRevision, kind = state.kind
        guard !requested.isEmpty else { state.searching = false; return }
        if more {
            guard !state.searching, state.hasMore, state.loadedQuery == requested, state.loadedKind == kind else { return }
        } else if requested == state.loadedQuery && kind == state.loadedKind && state.loadedRevision == revision && Date().timeIntervalSince(state.loadedAt) < 300 {
            state.searching = false; return
        }
        let loadID = UUID(); state.searchLoadID = loadID
        let offset = more ? state.offset : 0
        state.error = nil; state.searching = true
        defer { if generation == model.generation && state.searchLoadID == loadID { state.searching = false } }
        do {
            if !more { try await Task.sleep(for: .milliseconds(300)) }
            let page: ItemPage
            if model.isDemo {
                let values = (PreviewLibrary.movies + PreviewLibrary.shows).filter {
                    $0.name.localizedCaseInsensitiveContains(requested) && (kind.isEmpty || $0.type == kind)
                }
                page = ItemPage(items: Array(values.dropFirst(offset).prefix(30)), totalRecordCount: values.count)
            } else if let client = model.client {
                page = try await client.items(type: kind.isEmpty ? nil : kind, search: requested, start: offset)
            } else { throw ClientError.missingSession }
            guard !Task.isCancelled, generation == model.generation, revision == model.libraryRevision,
                  state.searchLoadID == loadID, requested == text, kind == state.kind else { return }
            var seen = Set((more ? state.results : []).map(\.id))
            let additions = page.items.filter { seen.insert($0.id).inserted }
            state.results = (more ? state.results : []) + additions
            state.offset = offset + page.items.count
            state.hasMore = !additions.isEmpty && (page.totalRecordCount.map { state.offset < $0 } ?? (page.items.count == 30))
            state.loadedQuery = requested; state.loadedKind = kind; state.loadedAt = .now; state.loadedRevision = revision
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, generation == model.generation, revision == model.libraryRevision,
                  state.searchLoadID == loadID, requested == text, kind == state.kind else { return }
            if error as? ClientError == .unauthorized || error as? ClientError == .forbidden { state.results = []; state.hasMore = false }
            state.error = error.localizedDescription
        }
    }
    @ViewBuilder private var resultTypeControl: some View {
        #if os(iOS)
        resultTypePicker.pickerStyle(.segmented)
        #else
        Menu { resultTypePicker } label: {
            Label(state.kind == "Movie" ? "Movies" : state.kind == "Series" ? "Shows" : "All results", systemImage: "line.3.horizontal.decrease")
        }.buttonStyle(ZoroButtonStyle())
        #endif
    }
    private var resultTypePicker: some View {
        Picker("Result type", selection: Binding(get: { state.kind }, set: {
            state.kind = $0; state.searchLoadID = UUID(); state.error = nil
        })) {
            Text("All").tag(""); Text("Movies").tag("Movie"); Text("Shows").tag("Series")
        }.accessibilityIdentifier("search-result-type")
    }
    private var resultRows: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(matchingResults) { item in
                NavigationLink(value: item) {
                    HStack(spacing: 14) {
                        MediaArtwork(item: item, landscape: true, width: 360).aspectRatio(16 / 9, contentMode: .fit)
                            .frame(width: Theme.isTV ? 200 : 108).clipShape(RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.displayTitle).font(Theme.font(Theme.isTV ? 24 : 16, weight: .semibold)).multilineTextAlignment(.leading)
                            Text([item.productionYear.map(String.init), item.isSeries ? "Show" : "Movie"].compactMap { $0 }.joined(separator: " · "))
                                .font(Theme.font(Theme.isTV ? 20 : 13)).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, minHeight: Theme.target, alignment: .leading)
                }.buttonStyle(ArtworkButtonStyle()).accessibilityIdentifier("search-item-" + item.id)
            }
            if state.hasMore {
                Button(state.searching ? "Loading more results…" : "More results") { Task { await search(more: true) } }
                    .buttonStyle(ZoroButtonStyle()).disabled(state.searching).accessibilityIdentifier("search-more")
            }
        }.accessibilityIdentifier("search-results")
    }
    private func loadRecommendations() async {
        let generation = model.generation, revision = model.libraryRevision
        if state.recommendationsRevision == revision && Date().timeIntervalSince(state.recommendationsLoadedAt) < 300 { return }
        let loadID = UUID(); state.recommendationsLoadID = loadID
        state.recommendationsLoading = true; state.recommendationsError = nil
        defer {
            if generation == model.generation && state.recommendationsLoadID == loadID { state.recommendationsLoading = false }
        }
        func canPublish() -> Bool {
            !Task.isCancelled && generation == model.generation && revision == model.libraryRevision &&
                state.recommendationsLoadID == loadID && text.isEmpty
        }
        if model.isDemo {
            state.recommendations = SearchRecommendations.select(from: PreviewLibrary.movies + PreviewLibrary.shows)
            state.recommendationsLoadedAt = .now; state.recommendationsRevision = revision
            return
        }
        guard let client = model.client else { return }
        // Warm Home metadata can paint cards before the first cache/disk read.
        if state.recommendations.isEmpty {
            state.recommendations = SearchRecommendations.select(from: model.homeLibrary.shelves.filter { $0.id >= 2 }.flatMap(\.items))
            if state.recommendations.isEmpty,
               let cached = try? await client.readingCache().searchRecommendations(), canPublish() {
                state.recommendations = cached
            }
        }
        guard canPublish() else { return }
        do {
            let items = try await client.searchRecommendations()
            guard canPublish() else { return }
            state.recommendations = items
            state.recommendationsLoadedAt = .now; state.recommendationsRevision = revision
        } catch is CancellationError { }
        catch {
            guard canPublish() else { return }
            if error as? ClientError == .unauthorized || error as? ClientError == .forbidden { state.recommendations = [] }
            state.recommendationsError = error.localizedDescription
        }
    }
}

/// Server Home rows use the same two card shapes as every other row: wide cards
/// for live and episodes, posters for movies and shows (trailer previews on
/// Apple TV). Each card gets at most one context line.
struct CustomHomeShelf: View {
    let row: HomeRow
    var title: String? = nil
    let retry: () -> Void
    private var wide: Bool { row.id == "sports" || row.cards.contains { $0.item.isEpisode || $0.item.isLive } }

    static func label(_ card: HomeRowCard, rowID: String, at now: Date) -> String? {
        if let start = HomeRowCard.date(card.startsAt) {
            let when = start <= now ? "On now" : "Starts " + start.formatted(date: .omitted, time: .shortened)
            return card.subtitle.isEmpty ? when : card.subtitle + " · " + when
        }
        if rowID == "short-movies", !card.subtitle.isEmpty { return card.subtitle }
        return card.contextBadges.first
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let cards = row.cards.filter { !$0.isExpired(at: timeline.date) }
            if !cards.isEmpty {
                let labels = Dictionary(cards.compactMap { card in Self.label(card, rowID: row.id, at: timeline.date).map { (card.item.id, $0) } },
                                        uniquingKeysWith: { first, _ in first })
                #if os(tvOS)
                if !wide && cards.allSatisfy({ $0.item.type == "Movie" || $0.item.type == "Series" }) {
                    PreviewShelf(id: "home-row-" + row.id, title: title ?? row.title, items: cards.map(\.item), labels: labels)
                        .accessibilityIdentifier("home-row-\(row.id)")
                } else { shelf(cards, labels: labels) }
                #else
                shelf(cards, labels: labels)
                #endif
            }
        }
    }

    private func shelf(_ cards: [HomeRowCard], labels: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: title ?? row.title).padding(.horizontal, Theme.gutter)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.isTV ? 28 : 14) {
                    ForEach(cards) { card in
                        NavigationLink(value: card.item) {
                            if row.id == "sports", let game = card.game {
                                HomeGameCard(card: card, game: game, fallbackLabel: labels[card.item.id])
                            } else {
                                MediaCard(item: card.item, landscape: wide, availableFormats: card.qualityBadges, label: labels[card.item.id])
                            }
                        }.buttonStyle(ArtworkButtonStyle())
                            .accessibilityIdentifier("item-\(card.item.id)")
                    }
                }.padding(.horizontal, Theme.gutter).padding(.vertical, Theme.isTV ? 18 : 3)
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }.accessibilityIdentifier("home-row-\(row.id)")
    }
}

private struct HomeGameCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.adaptiveWindow) private var window
    let card: HomeRowCard
    let game: HomeRowCard.Game
    let fallbackLabel: String?
    private struct Key: Hashable { let generation: UUID; let game: HomeRowCard.Game }
    @State private var loaded: Key?
    @State private var images: [UIImage] = []
    private var key: Key { Key(generation: model.generation, game: game) }
    var body: some View {
        Group {
            if loaded == key, images.count == 2 {
                let start = HomeRowCard.date(card.startsAt)
                let soon = start.map { $0 > .now } ?? card.badges.contains("Starting soon")
                let status = soon ? "Starting soon" : "On now"
                VStack(alignment: .leading, spacing: 6) {
                    Color.clear.aspectRatio(16 / 9, contentMode: .fit).overlay {
                        GeometryReader { g in
                            ZStack {
                                RadialGradient(colors: [Color(hex: 0x2a3530), Color(hex: 0x151b18)],
                                    center: .center, startRadius: 0, endRadius: g.size.width / 2)
                                HStack(spacing: g.size.width * 0.035) {
                                    crest(images[0], size: g.size)
                                    Text("VS").font(Theme.font(Theme.isTV ? 18 : 12, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.7))
                                    crest(images[1], size: g.size)
                                }
                            }
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 12))
                    if model.preferences.showTitles {
                        Text(game.title).font(Theme.font(Theme.isTV ? 22 : 15, weight: .semibold)).lineLimit(2)
                        Text(card.item.name).font(Theme.font(Theme.isTV ? 17 : 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        Text(soon ? [status, start.map { "Starts " + $0.formatted(date: .omitted, time: .shortened) }].compactMap { $0 }.joined(separator: " · ") : status)
                            .font(Theme.font(Theme.isTV ? 17 : 12)).foregroundStyle(Theme.jade)
                    }
                }.frame(width: (Theme.isTV ? 360 : window.landscapeCardWidth) * model.posterScale)
                 .accessibilityElement(children: .ignore).accessibilityLabel([game.title, card.item.name, status].joined(separator: ", "))
            } else { MediaCard(item: card.item, landscape: true, availableFormats: card.qualityBadges, label: fallbackLabel) }
        }.task(id: key) {
            let loading = key
            guard let client = model.client else { return }
            let cache = model.imageCache
            async let first = cache.homeCrest(client: client, path: game.paths[0])
            async let second = cache.homeCrest(client: client, path: game.paths[1])
            if let pair = try? await (first, second), let a = pair.0, let b = pair.1, !Task.isCancelled {
                images = [a,b]; loaded = loading
            }
        }
    }
    private func crest(_ image: UIImage, size: CGSize) -> some View {
        Image(uiImage: image).resizable().scaledToFit().frame(width: size.width * 0.28, height: size.height * 0.56)
            .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
    }
}

struct YourTeamsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var teams = ""
    @State private var teamSearch = ""
    @State private var teamLeague = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @State private var retry = 0
    private var edited: HomePreferences {
        var value = HomePreferences()
        value.teams = teams.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return value
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("See your teams on Home").font(Theme.font(Theme.isTV ? 32 : 26, weight: .bold))
                    Text("Home shows your teams when a game is on now or starts within an hour. Leave your list blank to use the server’s favorite teams.")
                        .foregroundStyle(Theme.muted)
                    if !loaded && error == nil { ProgressView("Loading your teams…") }
                    if let error {
                        Text(error).foregroundStyle(Theme.muted)
                        if !loaded { Button("Try again") { retry += 1 }.buttonStyle(ZoroButtonStyle()) }
                    }
                    if loaded {
                        teamPicker
                        if !edited.isValid { Text("Use up to 12 team names, each between 3 and 64 characters.").foregroundStyle(Theme.muted) }
                        Button(saving ? "Saving…" : "Save teams") { Task { await save() } }
                            .buttonStyle(ZoroButtonStyle(primary: true)).disabled(saving || !edited.isValid)
                    }
                }.frame(maxWidth: 720).padding(Theme.gutter).frame(maxWidth: .infinity)
                    .disabled(saving)
            }.background(Theme.background).foregroundStyle(Theme.text).navigationTitle("Your teams")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(saving) } }
        }.tint(Theme.jade).preferredColorScheme(.dark).interactiveDismissDisabled(saving)
            .task(id: retry) { await load() }
    }
    private var teamPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !edited.teams.isEmpty {
                DetailWrapLayout(spacing: 10) {
                    ForEach(edited.teams, id: \.self) { name in
                        Button { teams = edited.teams.filter { $0 != name }.joined(separator: ", ") } label: {
                            Label(name, systemImage: "xmark").fixedSize(horizontal: false, vertical: true)
                        }.buttonStyle(ZoroButtonStyle()).accessibilityLabel("Remove " + name)
                    }
                }
            }
            TextField("Find or add a team", text: $teamSearch)
                .padding(14).frame(minHeight: Theme.target).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("team-search").onSubmit { addTeam(teamSearch) }
            Menu {
                Picker("Sport or league", selection: $teamLeague) {
                    Text("All sports").tag("")
                    ForEach(Array(Set(TeamSuggestion.all.map(\.league))).sorted(), id: \.self) { Text($0).tag($0) }
                }
            } label: { Label(teamLeague.isEmpty ? "All sports" : teamLeague, systemImage: "line.3.horizontal.decrease") }
                .buttonStyle(ZoroButtonStyle())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.isTV ? 260 : 148), spacing: 12)], spacing: 12) {
                ForEach(TeamSuggestion.all.filter {
                    (teamLeague.isEmpty || $0.league == teamLeague) && (teamSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(teamSearch))
                }) { suggestion in
                    let selected = edited.teams.contains { $0.caseInsensitiveCompare(suggestion.name) == .orderedSame }
                    Button {
                        if selected { teams = edited.teams.filter { $0.caseInsensitiveCompare(suggestion.name) != .orderedSame }.joined(separator: ", ") }
                        else { addTeam(suggestion.name, clearSearch: false) }
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(suggestion.name).multilineTextAlignment(.leading)
                                Text(suggestion.league).font(Theme.font(Theme.isTV ? 18 : 12)).foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle").foregroundStyle(Theme.jade)
                        }
                    }.buttonStyle(DetailControlStyle()).accessibilityAddTraits(selected ? .isSelected : [])
                        .disabled(!selected && edited.teams.count >= 12)
                }
            }
            if !teamSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Add “\(teamSearch.trimmingCharacters(in: .whitespacesAndNewlines))”") { addTeam(teamSearch) }
                    .buttonStyle(ZoroButtonStyle()).disabled(!canAddTeam(teamSearch))
            }
            Text("\(edited.teams.count) of 12 teams selected. Suggestions are quick choices; you can add teams from any sport using the names in your guide.")
                .font(Theme.font(Theme.isTV ? 19 : 13)).foregroundStyle(Theme.muted)
        }
    }
    private func canAddTeam(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (3...64).contains(name.count) && !name.contains(",") && edited.teams.count < 12 &&
            !edited.teams.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
    private func addTeam(_ raw: String, clearSearch: Bool = true) {
        guard canAddTeam(raw) else { return }
        teams = (edited.teams + [raw.trimmingCharacters(in: .whitespacesAndNewlines)]).joined(separator: ", ")
        if clearSearch { teamSearch = "" }
    }
    private func load() async {
        error = nil
        if model.isDemo { loaded = true; return }
        guard let client = model.client else { return }
        let generation = model.generation
        do {
            await model.checkFeatures()
            guard !Task.isCancelled, generation == model.generation else { return }
            let value = try await client.homeTeams(serverFallback: model.features.homeRowsContract == .legacy)
            guard !Task.isCancelled, generation == model.generation else { return }
            teams = value.joined(separator: ", "); loaded = true
        } catch {
            guard !Task.isCancelled, generation == model.generation else { return }
            self.error = error.localizedDescription
        }
    }
    private func save() async {
        if model.isDemo { dismiss(); return }
        guard let client = model.client, edited.isValid else { return }
        let generation = model.generation
        saving = true; error = nil
        defer { if generation == model.generation { saving = false } }
        do {
            await model.checkFeatures()
            guard !Task.isCancelled, generation == model.generation else { return }
            try await client.saveHomeTeams(edited.teams)
            guard !Task.isCancelled, generation == model.generation else { return }
            // Keep the older server feed and the web Home in step when present.
            if model.features.homeRowsContract == .legacy { _ = try? await client.saveHomePreferences(edited) }
            guard !Task.isCancelled, generation == model.generation else { return }
            model.homeLibrary.homeTeams = edited.teams
            model.homeRevision += 1; dismiss()
        } catch {
            guard !Task.isCancelled, generation == model.generation else { return }
            self.error = "Your teams couldn't be confirmed. Try Save again; saving replaces the same preferences."
        }
    }
}

/// Same Home role as the web live-events row, independent of personalized team picks.
private struct LiveEventsShelf: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: LiveTVSnapshot
    let events: [LiveEvent]
    var title = "Sports & live events"
    let allChannels: () -> Void
    let open: (MediaItem) -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            let events = snapshot.isFresh(at: timeline.date) ? events.filter { $0.isCurrent(at: timeline.date) } : []
            if !events.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    #if os(iOS)
                    HStack(spacing: 8) {
                        heading
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.75)
                        channelsLink.fixedSize(horizontal: true, vertical: false)
                    }.padding(.horizontal, Theme.gutter)
                    #else
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { heading.fixedSize(horizontal: true, vertical: false); Spacer(minLength: 0); channelsLink.fixedSize() }
                        VStack(alignment: .leading, spacing: 0) { heading; channelsLink }
                    }.padding(.horizontal, Theme.gutter)
                    #endif
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Theme.isTV ? 28 : 14) {
                            ForEach(events) { event in
                                Button {
                                    // Recheck at activation, even between timeline updates.
                                    guard snapshot.isFresh(at: .now), event.isCurrent(at: .now) else { return }
                                    open(event.channel)
                                } label: { LiveEventCard(event: event, now: timeline.date) }
                                .buttonStyle(ArtworkButtonStyle())
                                .accessibilityLabel("\(event.title)\(event.score.map { ", " + $0.text } ?? "")\(event.favoriteTeam ? ", favorite team" : ""), live on \(event.channel.name), \(event.start.formatted(date: .omitted, time: .shortened)) to \(event.end.formatted(date: .omitted, time: .shortened)). Open channel.")
                                .accessibilityIdentifier("live-event-\(event.id)")
                            }
                        }.padding(.horizontal, Theme.gutter).padding(.vertical, Theme.isTV ? 18 : 3)
                    }.scrollIndicators(.hidden).scrollClipDisabled()
                }.accessibilityIdentifier("home-live-events")
            }
        }
    }
    private var heading: some View {
        Button(action: allChannels) { SectionTitle(title: title) }
            .buttonStyle(ArtworkButtonStyle()).frame(minHeight: Theme.target)
    }
    private var channelsLink: some View {
        Button(action: allChannels) { Label("All channels", systemImage: "chevron.right").font(Theme.font(Theme.isTV ? 20 : 14, weight: .semibold)) }
            .buttonStyle(ArtworkButtonStyle()).foregroundStyle(Theme.jade)
            .frame(minWidth: Theme.target, minHeight: Theme.target).accessibilityIdentifier("home-all-channels")
    }
}

private struct LiveEventCard: View {
    let event: LiveEvent
    let now: Date
    private var width: CGFloat { Theme.isTV ? 360 : 270 }
    private var scale: CGFloat { Theme.isTV ? 1 : 0.67 }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            art
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .topTrailing) {
                    if event.favoriteTeam {
                        Image(systemName: "star.fill").font(.system(size: Theme.isTV ? 18 : 13))
                            .foregroundStyle(Color(hex: 0xffd60a))
                            .frame(minWidth: Theme.isTV ? 32 : 26, minHeight: Theme.isTV ? 30 : 24)
                            .background(.black.opacity(0.75), in: Capsule()).padding(10)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
            // Scored and unscored cards share one text layout so every card in the row is the same size.
            Text(event.scoreStatus ?? event.title).font(Theme.font(Theme.isTV ? 23 : 16, weight: .semibold)).lineLimit(1)
            Text(event.channel.name + (event.channel.channelNumber.map { " · Ch " + $0 } ?? ""))
                .font(Theme.font(Theme.isTV ? 18 : 13)).foregroundStyle(Theme.muted).lineLimit(1)
            HStack(spacing: 4) { Text(event.start, style: .time); Text("–"); Text(event.end, style: .time) }
                .font(Theme.font(Theme.isTV ? 17 : 12)).foregroundStyle(Theme.muted)
            GeometryReader { geometry in
                Capsule().fill(Theme.border)
                Capsule().fill(Theme.jade).frame(width: geometry.size.width * event.progress(at: now))
            }.frame(height: 3).accessibilityHidden(true)
        }.frame(width: width, alignment: .leading).foregroundStyle(Theme.text)
            .accessibilityElement(children: .ignore)
    }

    /// One LIVE badge for every card, scored or not.
    private var liveBadge: some View {
        // The web's pill: dark capsule with a red dot (PR #199).
        HStack(spacing: Theme.isTV ? 7 : 5) {
            Circle().fill(Color(hex: 0xff453a)).frame(width: Theme.isTV ? 9 : 7, height: Theme.isTV ? 9 : 7)
            Text("LIVE").font(Theme.font(Theme.isTV ? 15 : 11, weight: .bold)).tracking(0.6)
        }.foregroundStyle(.white)
            .padding(.horizontal, Theme.isTV ? 12 : 9).padding(.vertical, Theme.isTV ? 6 : 5)
            .background(.black.opacity(0.75), in: Capsule())
            .padding(10)
    }

    @ViewBuilder private var art: some View {
        if let score = event.score {
            // The matchup art stays underneath; the fade and scores sit over it.
            LiveEventArtworkView(event: event)
                .overlay { LiveScoreArt(score: score, scale: scale) }
                .overlay(alignment: .topLeading) { if !score.isFinal { liveBadge } }
        } else {
            LiveEventArtworkView(event: event)
                .overlay(alignment: .topLeading) { liveBadge }
        }
    }
}

/// Over a scored game's matchup art, like the Zorofin site's "Live now" row
/// (owner approved Nov 9): a team-tinted gradient with both teams and their
/// scores at the bottom. Same as the TV apps' `LiveScoreArt`.
private struct LiveScoreArt: View {
    let score: LiveScore
    let scale: CGFloat
    var body: some View {
        ZStack(alignment: .bottom) {
            // Bottom-to-top fade so the scores read over any art (same as web).
            LinearGradient(stops: [.init(color: .black.opacity(0.92), location: 0),
                                   .init(color: .black.opacity(0.65), location: 0.36),
                                   .init(color: .clear, location: 0.68)],
                           startPoint: .bottom, endPoint: .top)
            VStack(spacing: 2 * scale) {
                row(score.awayName.isEmpty ? score.away : score.awayName, score.awayScore,
                    trailing: score.isFinal && score.homeLeads)
                row(score.homeName.isEmpty ? score.home : score.homeName, score.homeScore,
                    trailing: score.isFinal && score.awayLeads)
            }.padding(.horizontal, 18 * scale).padding(.bottom, 14 * scale)
        }.accessibilityHidden(true)
    }
    /// `trailing`: the losing side of a final reads muted (same as web).
    private func row(_ name: String, _ points: String, trailing: Bool) -> some View {
        HStack(spacing: 10 * scale) {
            Text(name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(points).monospacedDigit()
        }.font(Theme.font(24 * scale, weight: .bold)).foregroundStyle(trailing ? Theme.muted : .white)
    }

    /// The team-tinted 135° card, only for games without matchup art.
    static func tinted(_ score: LiveScore) -> LinearGradient {
        LinearGradient(stops: [.init(color: Color(hex: UInt32(score.tint)), location: 0),
                               .init(color: Color(hex: 0x102421), location: 0.6),
                               .init(color: .black, location: 1)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct LiveEventArtworkView: View {
    @Environment(AppModel.self) private var model
    let event: LiveEvent
    @State private var photo: UIImage?
    @State private var crests: [UIImage] = []
    private struct LoadKey: Hashable {
        let generation: UUID
        let channelID: String
        let start: Date
        let sources: [LiveEventArtworkSource]
    }
    private var key: LoadKey {
        .init(generation: model.generation, channelID: event.id, start: event.start, sources: event.artworkSources)
    }
    @State private var loadedKey: LoadKey?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if loadedKey == key, let photo {
                    // Event posters can contain names/scores: preserve the complete art.
                    Image(uiImage: photo).resizable().scaledToFit()
                } else if loadedKey == key, crests.count == 2 {
                    // Scored cards: crests sit higher so the score lines don't cover them.
                    let crestHeight = geometry.size.height * (event.score == nil ? 0.72 : 0.46)
                    if let score = event.score {
                        LiveScoreArt.tinted(score)
                    } else {
                        LinearGradient(colors: [Color(hex: 0x213f36), Color(hex: 0x0e201a)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    HStack(alignment: event.score == nil ? .center : .top, spacing: 0) {
                        Image(uiImage: crests[0]).resizable().scaledToFit()
                            .frame(width: geometry.size.width * 0.34, height: crestHeight)
                        Text("VS").font(Theme.font(Theme.isTV ? 18 : 14, weight: .bold))
                            .foregroundStyle(Color(hex: 0xbce2c8)).frame(maxWidth: .infinity)
                            .frame(height: crestHeight)
                        Image(uiImage: crests[1]).resizable().scaledToFit()
                            .frame(width: geometry.size.width * 0.34, height: crestHeight)
                    }.padding(.horizontal, 14).padding(.top, event.score == nil ? 16 : 12)
                        .frame(maxHeight: .infinity, alignment: event.score == nil ? .center : .top)
                } else if let score = event.score {
                    // No generic sport drawing on scored cards: the team tint stands in.
                    LiveScoreArt.tinted(score)
                } else {
                    // Bundled exports of the web's illustrations: instant/offline,
                    // including ordinary Jellyfin servers with no artwork extension.
                    Image("LiveSport-\(event.sport.rawValue)").renderingMode(.original)
                        .resizable().scaledToFit()
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .background(Color(hex: 0x151c18)).clipped()
        }.accessibilityHidden(true)
            .task(id: key) {
                photo = nil; crests = []; loadedKey = nil
                guard let client = model.client else { return }
                let cache = model.imageCache, loadingKey = key
                for source in loadingKey.sources {
                    guard !Task.isCancelled else { return }
                    switch source {
                    case .catalogue(let path):
                        if let loaded = try? await cache.liveImage(client: client, path: path, width: 720) {
                            guard !Task.isCancelled else { return }
                            photo = loaded; loadedKey = loadingKey; return
                        }
                    case .program(let image):
                        let cacheKey = "live-program-\(image.itemID)-\(image.kind)-\(image.tag)-720"
                        if let loaded = try? await cache.image(key: cacheKey, client: client, itemID: image.itemID,
                            kind: image.kind, tag: image.tag, width: 720) {
                            guard !Task.isCancelled else { return }
                            // Guide images that aren't a 16:9 picture are usually a
                            // channel logo or a presenter headshot: use crests or the
                            // sport illustration instead, as the web does.
                            guard LiveEventArtwork.isWidePicture(width: loaded.size.width, height: loaded.size.height) else { continue }
                            photo = loaded; loadedKey = loadingKey; return
                        }
                    case .crests(let paths):
                        async let first = try? cache.liveImage(client: client, path: paths[0], width: 256)
                        async let second = try? cache.liveImage(client: client, path: paths[1], width: 256)
                        let images = await (first, second)
                        guard !Task.isCancelled else { return }
                        if let first = images.0, let second = images.1 {
                            crests = [first, second]; loadedKey = loadingKey; return
                        }
                    }
                }
            }
            .onDisappear { photo = nil; crests = []; loadedKey = nil }
    }
}

@MainActor extension HomeLibraryState {
    func refreshLiveEvents(model: AppModel) async {
        if model.isDemo {
            if self.liveSnapshot == nil {
                let formatter = ISO8601DateFormatter()
                let channels = ["Live: NFL Football", "Live: NBA Basketball", "Live: Premier League Soccer"].enumerated().map { index, title in
                    var channel = MediaItem(id: "preview-live-\(index)", name: "Preview Sports \(index + 1)", type: "TvChannel")
                    channel.channelNumber = String(index + 1)
                    channel.currentProgram = LiveProgram(name: title,
                        startDate: formatter.string(from: .now.addingTimeInterval(-900)),
                        endDate: formatter.string(from: .now.addingTimeInterval(3600)), isLive: true)
                    return channel
                }
                self.liveSnapshot = LiveTVSnapshot(channels: channels)
                var events = LiveEvent.select(channels, at: .now)
                // One scored card beside unscored ones, so the preview shows both formats.
                if events.count > 1 {
                    events[1].score = LiveScore(away: "AWY", awayScore: "54", home: "HME", homeScore: "61", detail: "3rd · 4:12",
                                                isFinal: false, awayName: "Away Club", homeName: "Home Club", awayColor: nil, homeColor: nil)
                }
                self.liveEvents = events
            }
            return
        }
        guard let client = model.client else { return }
        if !model.features.liveArtwork, self.liveArtwork != nil {
            self.liveArtwork = nil; self.liveRevision = -1
        }
        if let snapshot = self.liveSnapshot, self.liveRevision == model.libraryRevision,
           (!model.features.liveArtwork || self.liveArtwork != nil),
           Date().timeIntervalSince(snapshot.fetchedAt) < 60 { return }
        let generation = model.generation, revision = model.libraryRevision, loadID = UUID()
        liveLoading = true; liveError = nil
        defer { if generation == model.generation && liveLoadID == loadID { liveLoading = false } }
        self.liveLoadID = loadID
        if self.liveSnapshot == nil {
            let cached = await client.cachedLiveTVSnapshot()
            guard !Task.isCancelled, generation == model.generation, self.liveLoadID == loadID else { return }
            if let cached { await publishLive(cached, artwork: self.liveArtwork, client: client, generation: generation, loadID: loadID, model: model) }
        }
        do {
            let wantsArtwork = model.features.liveArtwork
            async let artwork: LiveArtworkManifest? = wantsArtwork ? (try? await client.liveArtworkManifest()) : nil
            let snapshot = try await client.liveTVSnapshot()
            guard !Task.isCancelled, generation == model.generation, self.liveLoadID == loadID else { return }
            await publishLive(snapshot, artwork: self.liveArtwork, client: client, generation: generation, loadID: loadID, model: model)
            guard !Task.isCancelled, generation == model.generation, self.liveLoadID == loadID else { return }
            self.liveRevision = revision
            // The guide-only row shows first; the companion's feed (when there is
            // one) then sets its order, favorite stars and scores.
            if model.features.sportsEvents {
                let before = await self.liveScores.feed(for: client)
                let feed = await self.liveScores.load(client)
                guard !Task.isCancelled, generation == model.generation, self.liveLoadID == loadID else { return }
                if feed != before {
                    await publishLive(snapshot, artwork: self.liveArtwork, client: client, generation: generation, loadID: loadID, model: model)
                    guard !Task.isCancelled, generation == model.generation, self.liveLoadID == loadID else { return }
                }
            }
            // Event cards can render before the optional artwork index arrives.
            let manifest = await artwork
            guard !Task.isCancelled, generation == model.generation, self.liveLoadID == loadID else { return }
            if let manifest {
                self.liveArtwork = manifest
                await publishLive(snapshot, artwork: manifest, client: client, generation: generation, loadID: loadID, model: model)
            }
        } catch {
            guard !Task.isCancelled, generation == model.generation, self.liveLoadID == loadID else { return }
            if error as? ClientError == .unauthorized || error as? ClientError == .forbidden { self.liveSnapshot = nil }
            liveError = "Live programs could not be refreshed."
            // A transient outage can retain still-current listings for at most two minutes.
        }
    }
    private func publishLive(_ snapshot: LiveTVSnapshot, artwork: LiveArtworkManifest?, client: JellyfinClient,
                             generation: UUID, loadID: UUID, model: AppModel) async {
        let feed = model.features.sportsEvents ? await self.liveScores.feed(for: client) : nil
        let events = await LiveScores.events(in: snapshot, feed: feed, artwork: artwork)
        guard !Task.isCancelled, generation == model.generation, self.liveLoadID == loadID else { return }
        self.liveSnapshot = snapshot; self.liveEvents = events; self.hasLiveScoresFeed = feed != nil
    }
}


/// Programs and Guide share an entry on touch and remote devices.
struct LiveTVBrowseView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let back: () -> Void
    let open: (MediaItem) -> Void
    let play: (MediaItem, PlaybackOptions) -> Void
    @State private var guide = false
    #if os(tvOS)
    @FocusState private var focusedGuide: Bool?
    #endif
    @State private var refresh = 0
    private var state: HomeLibraryState { model.homeLibrary }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                if !Theme.isTV {
                    Button(action: back) { Image(systemName: "chevron.left").frame(width: 44, height: 48) }
                        .buttonStyle(.plain).accessibilityLabel("Back to Home")
                }
                Text("Live TV").font(Theme.font(Theme.isTV ? 36 : 28, weight: .bold))
                Spacer()
            }.padding(.horizontal, Theme.gutter)
            #if os(tvOS)
            HStack(spacing: 16) {
                Button("Programs") { guide = false }.buttonStyle(ZoroButtonStyle(primary: !guide))
                    .focused($focusedGuide, equals: false)
                    .accessibilityAddTraits(guide ? [] : .isSelected)
                Button("Guide") { guide = true }.buttonStyle(ZoroButtonStyle(primary: guide))
                    .focused($focusedGuide, equals: true)
                    .accessibilityAddTraits(guide ? .isSelected : [])
                Spacer()
            }.padding(.horizontal, Theme.gutter).accessibilityIdentifier("live-tv-mode")
            #else
            Picker("Live TV", selection: $guide) {
                Text("Programs").tag(false)
                Text("Guide").tag(true)
            }.pickerStyle(.segmented).frame(minHeight: 44).padding(.horizontal, Theme.gutter)
                .accessibilityIdentifier("live-tv-mode")
            #endif
            if guide { LiveGuideView(back: { guide = false }, play: play, embedded: true) }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        LiveTVStreamsStrip { play($0, .init(subtitleIndex: -2)) }.padding(.horizontal, Theme.gutter)
                        if state.liveLoading { ProgressView(model.features.sportsEvents || model.features.liveArtwork ? "Loading sports and programs…" : "Loading live programs…").frame(maxWidth: .infinity) }
                        if let error = state.liveError {
                            StatusView(title: "Live programs unavailable", detail: error, retry: { refresh += 1 })
                        }
                        if let snapshot = state.liveSnapshot {
                            LiveEventsShelf(snapshot: snapshot, events: state.liveEvents,
                                allChannels: { guide = true }, open: open)
                            TimelineView(.periodic(from: .now, by: 5)) { timeline in
                                let channels = snapshot.isFresh(at: timeline.date) ? snapshot.channels : []
                                let current = channels.filter { LiveProgramListing.isCurrent($0, at: timeline.date) }
                                let sports = channels.filter { LiveProgramListing.isSports($0) }
                                if !state.liveEvents.contains(where: { $0.isCurrent(at: timeline.date) }) {
                                    if !state.hasLiveScoresFeed && !sports.isEmpty {
                                        LiveProgramShelf(title: "Sports & live events", channels: sports, now: timeline.date, guide: { guide = true }) { channel in
                                            guard snapshot.isFresh(at: .now) else { return }; open(channel)
                                        }
                                    } else if !state.liveLoading && state.liveError == nil {
                                        StatusView(title: "No sports listed right now", detail: "Open Guide to browse channels and upcoming programs.")
                                    }
                                }
                                // Owner rule (Nov 24): no "On now" row in any app; the Guide has every channel.

                            }
                        } else if !state.liveLoading && state.liveError == nil {
                            StatusView(title: "No live programs right now", detail: "Open Guide to browse all channels and upcoming programs.")
                        }
                        Button("All channels · Guide") { guide = true }.buttonStyle(ZoroButtonStyle()).padding(.horizontal, Theme.gutter)
                    }.padding(.vertical, 12).padding(.bottom, 100)
                }.refreshable { state.liveRevision = -1; refresh += 1 }
            }
        }.background(Theme.background).accessibilityIdentifier("live-tv-browse")
        #if os(tvOS)
        .onChange(of: guide) { _, selected in focusedGuide = selected }
        .onExitCommand(perform: guide ? { guide = false } : nil)
        #endif
        .task(id: "\(model.generation)-\(model.libraryRevision)-\(model.features.liveArtwork)-\(model.features.sportsEvents)-\(scenePhase == .active)-\(guide)-\(refresh)") {
            guard scenePhase == .active && !guide else { return }
            state.liveRevision = -1
            while !Task.isCancelled {
                await state.refreshLiveEvents(model: model)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}

/// Landscape programme rails: artwork and metadata have one clear hierarchy.
private struct LiveProgramShelf: View {
    @Environment(AppModel.self) private var model
    @Environment(\.adaptiveWindow) private var window
    let title: String
    let channels: [MediaItem]
    let now: Date
    let guide: () -> Void
    let open: (MediaItem) -> Void
    private var width: CGFloat { (Theme.isTV ? 360 : min(360, window.landscapeCardWidth)) * model.posterScale }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: guide) { HStack { SectionTitle(title: title); Image(systemName: "chevron.right").font(Theme.font(14)); Spacer() } }
                .buttonStyle(ArtworkButtonStyle()).frame(minHeight: 44).padding(.horizontal, Theme.gutter)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.isTV ? 28 : 14) {
                    ForEach(channels) { channel in
                        Button { open(channel) } label: { MobileProgramCard(channel: channel, now: now).frame(width: width) }
                            .buttonStyle(ArtworkButtonStyle())
                            .accessibilityLabel("\(channel.currentProgram?.name ?? channel.name), \(channel.name). Open channel.")
                    }
                }.padding(.horizontal, Theme.gutter).padding(.vertical, Theme.isTV ? 18 : 4)
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }
}
private struct MobileProgramCard: View {
    let channel: MediaItem
    let now: Date
    private var program: LiveProgram? { channel.currentProgram }
    private var title: String {
        let name = program?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? channel.name : name
    }
    private var channelLine: String {
        let same = title.caseInsensitiveCompare(channel.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        return (same ? "Channel" : channel.name) + (channel.channelNumber.map { " · Ch " + $0 } ?? "")
    }
    private var progress: Double {
        guard let p = program, let start = HomeRowCard.date(p.startDate), let end = HomeRowCard.date(p.endDate), end > start else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / end.timeIntervalSince(start)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MobileProgramArtwork(channel: channel).aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if LiveProgramListing.isLive(channel, at: now) {
                        HStack(spacing: 5) { Circle().fill(.red).frame(width: 6, height: 6); Text("LIVE").font(Theme.font(12, weight: .bold)) }
                            .padding(.horizontal, 9).padding(.vertical, 6).background(.black.opacity(0.8), in: Capsule()).padding(9)
                    }
                }
            Text(title).font(Theme.font(Theme.isTV ? 23 : 17, weight: .semibold)).lineLimit(2)
            Text(channelLine)
                .font(Theme.font(Theme.isTV ? 18 : 14)).foregroundStyle(Theme.muted).lineLimit(1)
            if let p = program, let start = HomeRowCard.date(p.startDate), let end = HomeRowCard.date(p.endDate) {
                Text(start.formatted(date: .abbreviated, time: .shortened) + " – " + end.formatted(date: Calendar.current.isDate(start, inSameDayAs: end) ? .omitted : .abbreviated, time: .shortened))
                    .font(Theme.font(13)).foregroundStyle(Theme.muted).lineLimit(2)
                GeometryReader { geometry in
                    Capsule().fill(Theme.border)
                    Capsule().fill(Theme.jade).frame(width: geometry.size.width * progress)
                }.frame(height: 3).accessibilityHidden(true)
            }
        }.foregroundStyle(Theme.text)
    }
}
private struct MobileProgramArtwork: View {
    @Environment(AppModel.self) private var model
    let channel: MediaItem
    @State private var image: UIImage?
    @State private var programmeArt = false
    @State private var loadedKey = ""
    private var sources: [LiveProgramArtSource] { LiveProgramListing.artwork(channel) }
    private var key: String { "\(model.generation)-\(channel.id)-" + sources.map { "\($0.itemID):\($0.kind):\($0.tag)" }.joined(separator: "|") }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Theme.panel, Theme.background], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image, loadedKey == key {
                    if programmeArt { Image(uiImage: image).resizable().scaledToFill() }
                    else { Image(uiImage: image).resizable().scaledToFit().padding(20) }
                } else { Image(systemName: "tv").font(.system(size: 40)).foregroundStyle(Theme.muted) }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.accessibilityHidden(true)
        .task(id: key) {
            let loadingKey = key, generation = model.generation, candidates = sources
            image = nil; loadedKey = ""
            guard let client = model.client else { return }
            for source in candidates {
                if let value = try? await model.imageCache.image(key: "\(generation)-program-card-\(source.itemID)-\(source.kind)-\(source.tag)", client: client, itemID: source.itemID, kind: source.kind, tag: source.tag, width: 720) {
                    guard !Task.isCancelled, model.generation == generation else { return }
                    // A programme picture that isn't a wide still is a presenter headshot or a
                    // station logo: use the channel's own art instead, as web, Roku and LG do.
                    if source.isProgram, value.size.height > 0, !(1.6...1.95).contains(value.size.width / value.size.height) { continue }
                    image = value; programmeArt = source.isProgram; loadedKey = loadingKey; return
                }
                if Task.isCancelled { return }
            }
        }
    }
}


/// A navigation value, never a synthetic server item or a new top-menu tab.
struct CollectionsDestination: Hashable {}

struct CollectionsHomeShelf: View {
    @Environment(AppModel.self) private var model
    let refresh: Int
    @State private var items: [MediaItem] = []
    @State private var failure: String?
    @State private var retry = 0
    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        SectionTitle(title: "Collections")
                        Spacer(minLength: 12)
                        NavigationLink("Browse all", value: CollectionsDestination())
                            .buttonStyle(ZoroButtonStyle())
                    }.padding(.horizontal, Theme.gutter)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Theme.isTV ? 28 : 14) {
                            ForEach(items) { item in
                                NavigationLink(value: item) { MediaCard(item: item) }
                                    .buttonStyle(ArtworkButtonStyle())
                                    .accessibilityIdentifier("collection-\(item.id)")
                            }
                        }.padding(.horizontal, Theme.gutter).padding(.vertical, Theme.isTV ? 18 : 3)
                    }.scrollIndicators(.hidden).scrollClipDisabled()
                }
            } else if let failure {
                StatusView(title: "Collections unavailable", detail: failure, retry: { retry += 1 })
            }
        }.task(id: "\(refresh)-\(model.libraryRevision)-\(retry)") {
            guard let client = model.client, !model.isDemo else { return }
            let generation = model.generation
            do {
                let page = try await client.collectionPage()
                guard !Task.isCancelled, generation == model.generation else { return }
                var seen = Set<String>()
                items = Array(page.items.filter { $0.type == "BoxSet" && seen.insert($0.id).inserted }.prefix(20))
                failure = nil
            } catch {
                guard !Task.isCancelled, generation == model.generation else { return }
                failure = error.localizedDescription
            }
        }
    }
}

struct CollectionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var collection: MediaItem? = nil
    let wide: Bool
    @State private var items: [MediaItem] = []
    @State private var cursor = LibraryPageCursor()
    @State private var loading = false
    @State private var failure: String?
    @State private var visibleID: String?
    @State private var loaded = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HStack {
                    if Theme.isTV { Button("Back") { dismiss() }.buttonStyle(ZoroButtonStyle()) }
                    Text(collection?.name ?? "Collections")
                        .font(Theme.font(Theme.isTV ? 40 : 28, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                }
                if !items.isEmpty { MediaGrid(items: items, wide: wide) }
                if loading { ProgressView("Loading collections…") }
                if let failure {
                    StatusView(title: "Couldn’t load collections", detail: failure, retry: { Task { await load() } })
                } else if !loading && loaded && items.isEmpty {
                    StatusView(title: collection == nil ? "No collections here yet" : "This collection is empty",
                               detail: "Titles shared with your account will appear here.")
                } else if !loading && cursor.hasMore && loaded {
                    Button("More titles") { Task { await load() } }.buttonStyle(ZoroButtonStyle())
                }
            }.scrollTargetLayout().padding(.horizontal, Theme.gutter).padding(.top, 20).padding(.bottom, 24)
        }.background(Theme.background)
            .scrollPosition(id: $visibleID)
            .task { if !loaded { await load() } }
    }
    private func load() async {
        guard !loading, cursor.hasMore, let client = model.client else { return }
        let generation = model.generation
        loading = true; failure = nil
        defer { if generation == model.generation { loading = false } }
        do {
            let page = try await client.collectionPage(parentID: collection?.id, start: cursor.offset)
            guard !Task.isCancelled, generation == model.generation else { return }
            var seen = Set(items.map(\.id))
            let additions = page.items.filter { seen.insert($0.id).inserted }
            cursor.accept(page, limit: 48)
            if additions.isEmpty { cursor.accept(.init(items: []), limit: 48) }
            items += additions; loaded = true
        } catch {
            guard !Task.isCancelled, generation == model.generation else { return }
            failure = error.localizedDescription
        }
    }
}
