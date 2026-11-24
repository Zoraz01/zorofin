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
    var rowsLoadedAt = Date.distantPast
    var rowsRevision = -1
    var rowsRefresh = -1
    var shelfLoadID = UUID()
    var rowLoadID = UUID()
    var liveSnapshot: LiveTVSnapshot?
    var liveEvents: [LiveEvent] = []
    var liveArtwork: LiveArtworkManifest?
    var liveRevision = -1
    var liveLoadID = UUID()
}

@MainActor @Observable final class CatalogLibraryState {
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
                    MediaShelf(title: shelf.title, items: shelf.items, landscape: shelf.landscape).id("shelf-\(shelf.id)")
                }
                if let ready = homeFeed?.rows.first(where: { $0.id == "requests-ready" }) {
                    CustomHomeShelf(row: ready, title: "My requests", retry: { refresh += 1 }).id("requests-ready")
                }
                if let snapshot = state.liveSnapshot {
                    LiveEventsShelf(snapshot: snapshot, events: state.liveEvents,
                        allChannels: { select(.live) }, open: open).id("sports-live-events")
                }
                homeRowsStatus
                ForEach(mixedRows) { row in
                    Group {
                        switch row {
                        case .personal(let personal):
                            CustomHomeShelf(row: personal, retry: { refresh += 1 })
                        case .library(let shelf):
                            MediaShelf(title: shelf.title, items: shelf.items, landscape: shelf.landscape)
                        case .generated(let generated):
                            MediaShelf(title: generated.title, items: generated.items)
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
            .task(id: "\(refresh)-\(model.homeRevision)-\(model.features.homeRows)") {
                await loadRows(); await prepareMix()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    if scenePhase == .active { await loadRows() }
                }
            }
            .task(id: "live-\(model.libraryRevision)-\(model.features.liveArtwork)-\(scenePhase == .active)") {
                guard scenePhase == .active else { return }
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
    }

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
    private func loadLiveEvents() async {
        if model.isDemo {
            if state.liveSnapshot == nil {
                let formatter = ISO8601DateFormatter()
                let channels = ["Live: NFL Football", "Live: NBA Basketball", "Live: Premier League Soccer"].enumerated().map { index, title in
                    var channel = MediaItem(id: "preview-live-\(index)", name: "Preview Sports \(index + 1)", type: "TvChannel")
                    channel.channelNumber = String(index + 1)
                    channel.currentProgram = LiveProgram(name: title,
                        startDate: formatter.string(from: .now.addingTimeInterval(-900)),
                        endDate: formatter.string(from: .now.addingTimeInterval(3600)), isLive: true)
                    return channel
                }
                state.liveSnapshot = LiveTVSnapshot(channels: channels)
                state.liveEvents = LiveEvent.select(channels, at: .now)
            }
            return
        }
        guard let client = model.client else { return }
        if !model.features.liveArtwork, state.liveArtwork != nil {
            state.liveArtwork = nil; state.liveRevision = -1
        }
        if let snapshot = state.liveSnapshot, state.liveRevision == model.libraryRevision,
           (!model.features.liveArtwork || state.liveArtwork != nil),
           Date().timeIntervalSince(snapshot.fetchedAt) < 60 { return }
        let generation = model.generation, revision = model.libraryRevision, loadID = UUID()
        state.liveLoadID = loadID
        if state.liveSnapshot == nil {
            let cached = await client.cachedLiveTVSnapshot()
            guard !Task.isCancelled, generation == model.generation, state.liveLoadID == loadID else { return }
            if let cached { await publishLive(cached, artwork: state.liveArtwork, generation: generation, loadID: loadID) }
        }
        do {
            let wantsArtwork = model.features.liveArtwork
            async let artwork: LiveArtworkManifest? = wantsArtwork ? (try? await client.liveArtworkManifest()) : nil
            let snapshot = try await client.liveTVSnapshot()
            guard !Task.isCancelled, generation == model.generation, state.liveLoadID == loadID else { return }
            await publishLive(snapshot, artwork: state.liveArtwork, generation: generation, loadID: loadID)
            guard !Task.isCancelled, generation == model.generation, state.liveLoadID == loadID else { return }
            state.liveRevision = revision
            // Event cards can render before the optional artwork index arrives.
            let manifest = await artwork
            guard !Task.isCancelled, generation == model.generation, state.liveLoadID == loadID else { return }
            if let manifest {
                state.liveArtwork = manifest
                await publishLive(snapshot, artwork: manifest, generation: generation, loadID: loadID)
            }
        } catch {
            guard !Task.isCancelled, generation == model.generation, state.liveLoadID == loadID else { return }
            if error as? ClientError == .unauthorized || error as? ClientError == .forbidden { state.liveSnapshot = nil }
            // A transient outage can retain still-current listings for at most two minutes.
        }
    }
    private func publishLive(_ snapshot: LiveTVSnapshot, artwork: LiveArtworkManifest?, generation: UUID, loadID: UUID) async {
        let events = await snapshot.featuredEvents(artwork: artwork)
        guard !Task.isCancelled, generation == model.generation, state.liveLoadID == loadID else { return }
        state.liveSnapshot = snapshot; state.liveEvents = events
    }
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
        guard state.mixPrepared, !discoveryLoading else { return }
        state.rowOrder.append(browseRows.map(\.candidate))
    }
    private func prepareMix() async {
        guard !state.mixPrepared,
              state.loadedRevision >= 0 || failure != nil,
              model.isDemo || model.client == nil || state.rowsRevision >= 0 || homeError != nil else { return }
        state.mixPrepared = true
        // Prime just one bounded discovery batch after the priority data finishes.
        // The pinned rows are already visible while the lower mix is prepared.
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
        let generation = model.generation, usesServer = model.features.homeRows
        guard state.rowsRevision != model.homeRevision || state.rowsRefresh != refresh ||
              Date().timeIntervalSince(state.rowsLoadedAt) >= 300 else { return }
        let loadID = UUID(), revision = model.homeRevision, requestedRefresh = refresh
        state.rowLoadID = loadID
        loadingRows = true; homeError = nil
        defer { if generation == model.generation && state.rowLoadID == loadID { loadingRows = false } }
        if homeFeed == nil {
            // Cache-only hydration: neither read below can start a network request.
            let reader = client.readingCache()
            var server: HomeFeed?
            if usesServer { server = try? await reader.homeFeed() }
            let rows = (try? await reader.clientHomeRows(teams: state.homeTeams)) ?? []
            guard !Task.isCancelled, generation == model.generation, state.rowLoadID == loadID else { return }
            if server != nil || rows.contains(where: { !$0.cards.isEmpty }) {
                let cached = ClientHomeRows.feed(client: rows, server: server, teams: state.homeTeams)
                homeFeed = cached
                let enriched = try? await reader.enrichHomeFeed(cached)
                guard !Task.isCancelled, generation == model.generation, state.rowLoadID == loadID else { return }
                homeFeed = enriched ?? cached
            }
        }
        do {
            // Requests and Popular still need the optional server feed; every other
            // row is computed here from the viewer's own Jellyfin reads.
            async let serverResult = Self.serverFeed(client, enabled: usesServer)
            let teams = (try? await client.homeTeams(serverFallback: usesServer)) ?? state.homeTeams
            let rows = try await client.clientHomeRows(teams: teams)
            let server = await serverResult
            guard !Task.isCancelled, generation == model.generation, state.rowLoadID == loadID else { return }
            if case .failure(let error)? = server {
                if error as? ClientError == .unauthorized { throw error }
                homeError = error.localizedDescription
            }
            let feed = ClientHomeRows.feed(client: rows, server: try? server?.get(), teams: teams)
            state.homeTeams = teams
            homeFeed = feed
            appendRowOrder()
            state.rowsLoadedAt = .now; state.rowsRevision = revision; state.rowsRefresh = requestedRefresh
            // Show the row immediately, then fill badges without changing its order.
            let enriched = try await client.enrichHomeFeed(feed)
            guard !Task.isCancelled, generation == model.generation, state.rowLoadID == loadID else { return }
            homeFeed = enriched
        } catch {
            guard !Task.isCancelled, generation == model.generation, state.rowLoadID == loadID else { return }
            homeError = error.localizedDescription
        }
    }
    nonisolated private static func serverFeed(_ client: JellyfinClient, enabled: Bool) async -> Result<HomeFeed, any Error>? {
        guard enabled else { return nil }
        do { return .success(try await client.automaticHomeFeed()) } catch { return .failure(error) }
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
    private var qualityBadges: [String] {
        guard model.preferences.showQualityBadges != false else { return [] }
        let badges = item.quality().thumbnailBadges
        return badges.isEmpty ? availableFormats.map { $0 == "Dolby Vision" ? "DV" : $0 } : badges
    }
    private var width: CGFloat { (Theme.isTV ? (landscape ? 360 : 212) : (landscape ? window.landscapeCardWidth : window.posterWidth)) * model.preferences.posterScale }
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
                Text(item.isEpisode ? item.episodeLabel : item.productionYear.map(String.init) ?? (item.isLive ? "Live TV" : ""))
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
    @State private var favorite: Bool?
    @State private var busy = false
    private var value: Bool { favorite ?? item.userData?.isFavorite ?? false }
    var body: some View {
        Group {
            if compact { action.buttonStyle(DetailIconStyle()) }
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
            if compact {
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
                    }
                    if !Theme.isTV { Text(title).font(Theme.font(30, weight: .bold)) }
                    Spacer()
                    if kind != "TvChannel" {
                        Button(favorites ? "All titles" : "Favorites") {
                            favorites.toggle(); items = []; cursor = LibraryPageCursor()
                            state.visibleID = nil; refresh += 1
                        }
                            .buttonStyle(ZoroButtonStyle())
                    }
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
                    StatusView(title: "No titles here yet", detail: favorites ? "Add favorites from a title's details." : "Titles available to your account will appear here.")
                }
            }.padding(.horizontal, Theme.gutter).padding(.top, 20).padding(.bottom, 24)
        }.scrollPosition(id: Binding(get: { state.visibleID }, set: { state.visibleID = $0 }))
            .task(id: "\(refresh)-\(model.libraryRevision)") { await load(reset: true) }
            #if os(iOS)
            .refreshable { await model.client?.responseCache?.invalidateMetadata(); refresh += 1 }
            #endif
    }
    private func load(reset: Bool) async {
        if reset && state.loadedRefresh == refresh && state.loadedRevision == model.libraryRevision {
            // Keep deep browsing intact; pull to refresh explicitly starts a new catalogue.
            if cursor.offset > 30 || Date().timeIntervalSince(state.loadedAt) < (kind == "TvChannel" ? 60 : 300) { return }
        }
        guard reset || (!loading && cursor.hasMore) else { return }
        let generation = model.generation, revision = refresh, libraryRevision = model.libraryRevision
        let loadID = UUID(); state.loadID = loadID
        loading = true; error = nil
        let offset = reset ? 0 : cursor.offset
        defer { if generation == model.generation && state.loadID == loadID { loading = false } }
        if model.isDemo {
            items = kind == "Series" ? PreviewLibrary.shows : kind == "TvChannel" ? [] : PreviewLibrary.movies
            if favorites { items = [] }; return
        }
        guard let client = model.client else { return }
        if reset && items.isEmpty {
            let cached = kind == "TvChannel" ? try? await client.readingCache().channels() :
                try? await client.readingCache().items(type: kind, favorites: favorites)
            if let cached, !Task.isCancelled, generation == model.generation, revision == refresh, state.loadID == loadID { items = cached.items }
        }
        do {
            let page = kind == "TvChannel" ? try await client.channels(start: offset) :
                try await client.items(type: kind, start: offset, favorites: favorites)
            guard !Task.isCancelled, generation == model.generation, revision == refresh, state.loadID == loadID else { return }
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: (Theme.isTV ? 210 : wide ? 180 : 140) * model.preferences.posterScale), spacing: Theme.isTV ? 28 : 16)], alignment: .leading, spacing: 28) {
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
    private var matchingResults: [MediaItem] { state.loadedQuery == text ? state.results : [] }
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
                    if state.searching { ProgressView("Searching…").frame(maxWidth: .infinity).padding(24) }
                    if !matchingResults.isEmpty {
                        MediaGrid(items: matchingResults, wide: wide).accessibilityIdentifier("search-results")
                    } else if !state.searching && state.loadedQuery == text && state.error == nil {
                        StatusView(title: "No matching titles", detail: "Try another title or spelling.", icon: "magnifyingglass")
                    }
                    if let error = state.error {
                        Text(error).foregroundStyle(.orange)
                        Button("Retry search") { searchRetry += 1 }.buttonStyle(ZoroButtonStyle())
                    }
                    if model.extensionEnabled {
                        Button("Can't find it? Open Requests", action: openRequests).buttonStyle(ZoroButtonStyle())
                        Text("Showing up to 30 library matches. Refine your search to narrow the results.")
                            .font(Theme.font(13)).foregroundStyle(Theme.muted)
                    }
                }
            }.padding(Theme.gutter).padding(.bottom, 24)
        }
        .task(id: "search-\(model.libraryRevision)-\(searchRetry)-\(query)") { await search() }
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
        state.searching = !text.isEmpty && state.loadedQuery != text
    }
    private func search() async {
        let requested = text, generation = model.generation, revision = model.libraryRevision
        let loadID = UUID(); state.searchLoadID = loadID
        state.error = nil
        guard !requested.isEmpty else { state.searching = false; return }
        if requested == state.loadedQuery && state.loadedRevision == revision && Date().timeIntervalSince(state.loadedAt) < 300 {
            state.searching = false; return
        }
        state.searching = true
        defer {
            if generation == model.generation && state.searchLoadID == loadID { state.searching = false }
        }
        do {
            try await Task.sleep(for: .milliseconds(300))
            let items: [MediaItem]
            if model.isDemo { items = (PreviewLibrary.movies + PreviewLibrary.shows).filter { $0.name.localizedCaseInsensitiveContains(requested) } }
            else if let client = model.client { items = try await client.items(search: requested).items }
            else { throw ClientError.missingSession }
            guard !Task.isCancelled, generation == model.generation, revision == model.libraryRevision,
                  state.searchLoadID == loadID, requested == text else { return }
            state.results = items
            state.loadedQuery = requested; state.loadedAt = .now; state.loadedRevision = revision
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, generation == model.generation, revision == model.libraryRevision,
                  state.searchLoadID == loadID, requested == text else { return }
            state.error = error.localizedDescription
        }
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

struct CustomHomeShelf: View {
    let row: HomeRow
    var title: String? = nil
    let retry: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let cards = row.cards.filter { !$0.isExpired(at: timeline.date) }
            if !cards.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(title: title ?? row.title).padding(.horizontal, Theme.gutter)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Theme.isTV ? 28 : 14) {
                            ForEach(cards) { card in
                                NavigationLink(value: card.item) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        MediaCard(item: card.item, landscape: row.id == "sports" || card.item.isEpisode, availableFormats: card.qualityBadges)
                                        if !card.contextBadges.isEmpty {
                                            Text(card.startsAt == nil ? card.contextBadges.joined(separator: " · ") : ((HomeRowCard.date(card.startsAt) ?? .distantFuture) <= timeline.date ? "On now" : "Starting soon")).font(Theme.font(Theme.isTV ? 19 : 13, weight: .semibold))
                                                .foregroundStyle(Theme.jade).fixedSize(horizontal: false, vertical: true)
                                        }
                                        if ["short-movies", "sports"].contains(row.id), !card.subtitle.isEmpty {
                                            Text(card.subtitle).font(Theme.font(Theme.isTV ? 19 : 13)).foregroundStyle(Theme.muted)
                                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                        }
                                        if let start = HomeRowCard.date(card.startsAt) {
                                            HStack(spacing: 4) {
                                                Text(start <= timeline.date ? "Started" : "Starts")
                                                Text(start, style: .time)
                                            }.font(Theme.font(Theme.isTV ? 19 : 13)).foregroundStyle(Theme.muted)
                                        }
                                    }.frame(width: Theme.isTV ? ((row.id == "sports" || card.item.isEpisode) ? 360 : 212) : ((row.id == "sports" || card.item.isEpisode) ? 270 : 148), alignment: .leading)
                                        .accessibilityElement(children: .combine)
                                }.buttonStyle(ArtworkButtonStyle())
                            }
                        }.padding(.horizontal, Theme.gutter).padding(.vertical, Theme.isTV ? 18 : 3)
                    }.scrollIndicators(.hidden).scrollClipDisabled()
                }.accessibilityIdentifier("home-row-\(row.id)")
            }
        }
    }
}

struct YourTeamsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var teams = ""
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
                    Text("Home shows a game when one of your teams is on now or about to start. Everything else on Home is selected automatically.")
                        .foregroundStyle(Theme.muted)
                    if !loaded && error == nil { ProgressView("Loading your teams…") }
                    if let error {
                        Text(error).foregroundStyle(Theme.muted)
                        if !loaded { Button("Try again") { retry += 1 }.buttonStyle(ZoroButtonStyle()) }
                    }
                    if loaded {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Your teams").font(.headline)
                            TextField("New York Knicks, New York Yankees", text: $teams)
                                .padding(14).frame(minHeight: Theme.target).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityLabel("Favorite team names, separated by commas")
                            Text("Use full team names as they appear in the guide, separated by commas. Up to 12 teams. Leave blank to use the server’s favorite teams, if it has any.").font(.callout).foregroundStyle(Theme.muted)
                        }
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
    private func load() async {
        error = nil
        if model.isDemo { loaded = true; return }
        guard let client = model.client else { return }
        let generation = model.generation
        do {
            let value = try await client.homeTeams(serverFallback: model.features.homeRows)
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
            try await client.saveHomeTeams(edited.teams)
            // Keep the older server feed and the web Home in step when present.
            if model.features.homeRows { _ = try? await client.saveHomePreferences(edited) }
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
                                .accessibilityLabel("\(event.title), live on \(event.channel.name), \(event.start.formatted(date: .omitted, time: .shortened)) to \(event.end.formatted(date: .omitted, time: .shortened)). Open channel.")
                                .accessibilityIdentifier("live-event-\(event.id)")
                            }
                        }.padding(.horizontal, Theme.gutter).padding(.vertical, Theme.isTV ? 18 : 3)
                    }.scrollIndicators(.hidden).scrollClipDisabled()
                }.accessibilityIdentifier("home-live-events")
            }
        }
    }
    private var heading: some View {
        Button(action: allChannels) { SectionTitle(title: "Sports & live events") }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LiveEventArtworkView(event: event)
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .topLeading) {
                    Label("LIVE", systemImage: "circle.fill")
                        .font(Theme.font(Theme.isTV ? 14 : 11, weight: .bold))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.black.opacity(0.75), in: Capsule()).padding(10)
                }.clipShape(RoundedRectangle(cornerRadius: 12))
            Text(event.title).font(Theme.font(Theme.isTV ? 23 : 16, weight: .semibold)).lineLimit(2)
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
                    LinearGradient(colors: [Color(hex: 0x213f36), Color(hex: 0x0e201a)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    HStack(spacing: 0) {
                        Image(uiImage: crests[0]).resizable().scaledToFit()
                            .frame(width: geometry.size.width * 0.34, height: geometry.size.height * 0.72)
                        Text("VS").font(Theme.font(Theme.isTV ? 18 : 14, weight: .bold))
                            .foregroundStyle(Color(hex: 0xbce2c8)).frame(maxWidth: .infinity)
                        Image(uiImage: crests[1]).resizable().scaledToFit()
                            .frame(width: geometry.size.width * 0.34, height: geometry.size.height * 0.72)
                    }.padding(.horizontal, 14).padding(.top, 16)
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
