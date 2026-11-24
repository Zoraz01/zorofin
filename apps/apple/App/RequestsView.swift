import SwiftUI
import ZorofinCore

@MainActor @Observable final class RequestsLibraryState {
    var category = "discover"
    var query = ""
    var mine = true
    var filter = "all"
    var page = 1
    var totalPages = 1
    var titles: [RequestTitle] = []
    var discovery: [RequestDiscoveryRow] = []
    var activity: [RequestActivityItem] = []
    var queue: RequestQueue?
    var personalActivity: [RequestActivityItem] = []
    var personalQueue: RequestQueue?
    var pending: [RequestJournal.Entry] = []
    var error: String?
    var loading = false
    var service: RequestSubmissionService?
    var revision = 0
    var loadedKey: String?
    var loadedAt = Date.distantPast

    func prepare(client: JellyfinClient) throws -> RequestSubmissionService {
        if let service { return service }
        guard let session = client.session,
              let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw RequestFailure.storage }
        let journal = RequestJournal(server: client.server, viewerID: session.viewer.id,
            root: root.appendingPathComponent("RequestReceipts-v1", isDirectory: true))
        let service = RequestSubmissionService(client: client, journal: journal)
        self.service = service
        return service
    }
}

private struct RequestSelection: Identifiable {
    let kind: RequestKind
    let titleID: Int
    var id: String { "\(kind.rawValue)-\(titleID)" }
}

struct RequestsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.navigationDockClearance) private var dockClearance
    let wide: Bool
    var open: (MediaItem) -> Void = { _ in }
    @State private var selected: RequestSelection?
    @State private var focusAfterPaging = false
    @FocusState private var requestFocus: String?
    private var state: RequestsLibraryState { model.requestsLibrary }
    private var activityMode: Bool { state.category == "activity" && state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var discoveryMode: Bool { state.category == "discover" && state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var key: String { "\(model.generation)-\(state.category)-\(state.query)-\(state.page)-\(state.mine)-\(state.filter)-\(state.revision)-\(model.extensionEnabled)" }
    private let tabs = [("discover", "Discover"), ("trending", "Trending"), ("movies", "Movies"), ("tv", "TV shows"), ("upcoming", "Coming soon"), ("activity", "Activity")]
    var body: some View {
        @Bindable var state = state
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.isTV ? 28 : 20) {
                if !Theme.isTV { Text("Requests").font(Theme.font(30, weight: .bold)) }
                if !model.extensionEnabled && !model.isDemo {
                    StatusView(title: "Requests unavailable", detail: "This server does not provide Requests. Your library remains available.", icon: "plus.rectangle.on.rectangle")
                } else {
                    TextField("Search movies and TV shows", text: $state.query)
                        .padding(14).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("requests-search")
                        .focused($requestFocus, equals: "search")
                        .onChange(of: state.query) { _, _ in state.page = 1 }
                    HStack(spacing: Theme.isTV ? 30 : 24) {
                        ForEach([("discover", "Discover"), ("activity", "My requests")], id: \.0) { tab in
                            Button { state.query = ""; state.category = tab.0; state.page = 1 } label: {
                                VStack(spacing: 9) {
                                    Text(tab.1).font(Theme.font(Theme.isTV ? 25 : 17, weight: state.category == tab.0 ? .semibold : .regular))
                                    Rectangle().fill(state.category == tab.0 ? Theme.jade : .clear).frame(height: 2)
                                }.fixedSize(horizontal: true, vertical: false)
                            }.buttonStyle(FlatOptionStyle()).accessibilityAddTraits(state.category == tab.0 ? .isSelected : [])
                        }
                        Spacer(minLength: 0)
                        Menu {
                            ForEach(tabs.filter { !["discover", "activity"].contains($0.0) }, id: \.0) { tab in
                                Button(tab.1) { state.query = ""; state.category = tab.0; state.page = 1 }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease").frame(width: Theme.target, height: Theme.target)
                        }.buttonStyle(FlatOptionStyle()).accessibilityLabel("Browse request categories")
                    }.requestFocusSection()
                    if activityMode { activityFilters }
                    if let error = state.error {
                        StatusView(title: "Requests couldn’t load", detail: error, icon: "exclamationmark.circle", retry: { state.revision += 1 })
                    }
                    if state.loading { ProgressView("Loading Requests…").frame(maxWidth: .infinity) }
                    if activityMode { activityList }
                    else if discoveryMode { personalRequestPreview; discoveryRows }
                    else { titleGrid }
                    if !state.loading && state.error == nil {
                        if !discoveryMode && (activityMode ? state.activity.isEmpty : visibleTitles(state.titles).isEmpty) {
                            StatusView(title: activityMode ? "No requests here yet" : "No titles found",
                                detail: activityMode ? "Request a title to follow its progress here." : model.preferences.hideAvailableRequests == true ? "Try the next page, or turn off Hide available titles in Display settings." : "Try another title or browse a different section.", icon: "magnifyingglass")
                        }
                        if discoveryMode && !state.discovery.contains(where: { !visibleTitles($0.titles).isEmpty || $0.failed }) {
                            StatusView(title: "No discovery titles yet", detail: "Search for a title or browse Movies and TV shows.", icon: "sparkles")
                        }
                        if !discoveryMode && state.totalPages > 1 {
                            VStack(spacing: 8) {
                                Text("Page \(state.page) of \(state.totalPages)").font(Theme.font(14)).foregroundStyle(Theme.muted)
                                HStack(spacing: 16) {
                                    Button("Previous") { focusAfterPaging = true; state.page -= 1 }.disabled(state.page <= 1)
                                        .accessibilityIdentifier("requests-previous")
                                    Button("Next") { focusAfterPaging = true; state.page += 1 }.disabled(state.page >= state.totalPages)
                                        .accessibilityIdentifier("requests-next")
                                }
                            }.buttonStyle(ZoroButtonStyle()).frame(maxWidth: .infinity).requestFocusSection()
                        }
                    }
                    if model.isDemo { Text("Preview only · Requests are never sent").foregroundStyle(Theme.muted) }
                }
            }.padding(Theme.gutter).padding(.vertical, 16)
                // Keep the final controls above the floating dock even when the
                // NavigationStack's scroll content extends into its safe area.
                .padding(.bottom, dockClearance).id("requests-top")
        }
        .onChange(of: state.loadedKey) { _, _ in
            guard focusAfterPaging else { return }
            focusAfterPaging = false
            scroll.scrollTo("requests-top", anchor: .top)
            requestFocus = activityMode
                ? state.activity.first.map { "activity-\($0.id)" } ?? "search"
                : visibleTitles(state.titles).first.map { "title-\($0.identity)" } ?? "search"
        }
        .onChange(of: state.query) { _, _ in focusAfterPaging = false }
        .onChange(of: state.category) { _, _ in focusAfterPaging = false }
        }
        .task(id: key) { await load() }
        .task(id: "\(key)-\(scenePhase == .active)") {
            guard scenePhase == .active, activityMode || discoveryMode, !model.isDemo else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await load(force: true)
            }
        }
        #if os(tvOS)
        .fullScreenCover(item: $selected, onDismiss: { state.revision += 1 }) { selection in
            RequestDetailsView(selection: selection, wide: wide) { item in selected = nil; open(item) }
                .id(model.generation)
        }
        #else
        .sheet(item: $selected, onDismiss: { state.revision += 1 }) { selection in
            RequestDetailsView(selection: selection, wide: wide) { item in selected = nil; open(item) }
                .id(model.generation)
        }
        #endif
    }
    @ViewBuilder private var personalRequestPreview: some View {
        if !state.personalActivity.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Your requests").font(Theme.font(Theme.isTV ? 28 : 20, weight: .semibold))
                    Spacer()
                    Button("See all") { state.query = ""; state.category = "activity"; state.mine = true; state.page = 1 }
                        .buttonStyle(FlatOptionStyle()).foregroundStyle(Theme.jade)
                }
                ForEach(Array(state.personalActivity.prefix(3))) { item in
                    Button {
                        if let kind = item.kind, let id = item.tmdbId { selected = .init(kind: kind, titleID: id) }
                    } label: {
                        HStack(spacing: 14) {
                            RequestPoster(url: RequestArtwork.url(absolute: item.posterUrl), title: item.title ?? "Title")
                                .frame(width: Theme.isTV ? 64 : 44, height: Theme.isTV ? 96 : 66)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title ?? "Untitled").font(Theme.font(Theme.isTV ? 23 : 16, weight: .semibold)).lineLimit(1)
                                Text(state.personalQueue?.label(for: item) ?? item.statusLabel)
                                    .font(Theme.font(Theme.isTV ? 19 : 13)).foregroundStyle(Theme.jade)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: item.statusLabel == "Available" ? "play.fill" : "chevron.right").foregroundStyle(Theme.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(FlatOptionStyle()).disabled(item.kind == nil || item.tmdbId == nil)
                }
            }.requestFocusSection().accessibilityIdentifier("requests-personal-preview")
        }
    }
    private var activityFilters: some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Button("My requests") { state.mine = true; state.page = 1 }.buttonStyle(ZoroButtonStyle(primary: state.mine))
                Button("All activity") { state.mine = false; state.page = 1 }.buttonStyle(ZoroButtonStyle(primary: !state.mine))
                Spacer(minLength: 0)
                Button { state.revision += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(ZoroButtonStyle()).accessibilityLabel("Refresh request activity")
            }.requestFocusSection()
            Picker("Status", selection: $state.filter) {
                Text("All statuses").tag("all"); Text("Pending approval").tag("pending")
                Text("Requested").tag("approved"); Text("Processing").tag("processing"); Text("Available").tag("available")
            }.onChange(of: state.filter) { _, _ in state.page = 1 }
            if !state.mine { Text("Activity your server allows this account to see.").font(Theme.font(14)).foregroundStyle(Theme.muted) }
        }
    }
    private func visibleTitles(_ titles: [RequestTitle]) -> [RequestTitle] {
        model.preferences.hideAvailableRequests == true ? titles.filter { $0.mediaInfo?.status != 5 } : titles
    }
    private var discoveryRows: some View {
        LazyVStack(alignment: .leading, spacing: Theme.isTV ? 36 : 24) {
            ForEach(state.discovery) { row in
                let titles = visibleTitles(row.titles)
                if !titles.isEmpty || row.failed {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(row.section.title).font(Theme.font(Theme.isTV ? 28 : 22, weight: .bold))
                                .accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 8)
                            if row.section != .recommended {
                                Button { state.category = row.section.rawValue; state.page = 1 } label: {
                                    Image(systemName: "chevron.right").frame(minWidth: Theme.target, minHeight: Theme.target)
                                }.buttonStyle(NavigationButtonStyle()).foregroundStyle(Theme.jade)
                                    .accessibilityLabel("See all \(row.section.title.lowercased())")
                            }
                        }
                        if row.failed {
                            Button("Couldn’t load this row. Retry") { state.revision += 1 }
                                .buttonStyle(ZoroButtonStyle())
                        } else {
                            ScrollView(.horizontal) {
                                LazyHStack(alignment: .top, spacing: Theme.isTV ? 24 : 14) {
                                    ForEach(titles, id: \.identity) { title in
                                        requestCard(title, focusID: "\(row.id)-\(title.identity)")
                                            .frame(width: (Theme.isTV ? 210 : 144) * model.preferences.posterScale)
                                    }
                                }.padding(8)
                            }.scrollIndicators(.hidden)
                        }
                    }.requestFocusSection().accessibilityIdentifier("requests-row-\(row.id)")
                }
            }
        }
    }
    private var titleGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.isTV ? 210 : 140), spacing: 20, alignment: .top)], alignment: .leading, spacing: 28) {
            ForEach(visibleTitles(state.titles).filter { $0.kind != nil }, id: \.identity) { title in
                requestCard(title, focusID: "title-\(title.identity)")
            }
        }.requestFocusSection()
    }
    private func requestCard(_ title: RequestTitle, focusID: String) -> some View {
        Button { if let kind = title.kind { selected = .init(kind: kind, titleID: title.id) } } label: {
            VStack(alignment: .leading, spacing: 8) {
                RequestPoster(url: RequestArtwork.url(path: title.posterPath), title: title.displayTitle)
                    .aspectRatio(2 / 3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                Text(title.displayTitle).font(Theme.font(Theme.isTV ? 20 : 15, weight: .semibold)).lineLimit(2)
                Text([title.year, title.kind == .tv ? "TV show" : "Movie"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.font(Theme.isTV ? 16 : 12)).foregroundStyle(Theme.muted)
                if title.mediaInfo != nil { Text(title.status()).font(Theme.font(Theme.isTV ? 16 : 12)).foregroundStyle(Theme.jade) }
            }.padding(4).frame(maxWidth: .infinity, alignment: .topLeading).foregroundStyle(Theme.text)
        }.buttonStyle(ArtworkButtonStyle()).accessibilityLabel("\(title.displayTitle), \(title.status())")
            .focused($requestFocus, equals: focusID)
    }
    private var activityList: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(state.pending.filter { $0.receiptID == nil }) { entry in
                Button {
                    selected = .init(kind: entry.intent.mediaType, titleID: entry.intent.mediaId)
                } label: { Label("Review unconfirmed \(entry.intent.mediaType == .tv ? "show" : "movie") request", systemImage: "exclamationmark.circle") }
                    .buttonStyle(ZoroButtonStyle())
            }
            ForEach(state.activity) { item in
                Button {
                    if let kind = item.kind, let id = item.tmdbId { selected = .init(kind: kind, titleID: id) }
                } label: {
                    HStack(spacing: 20) {
                        RequestPoster(url: RequestArtwork.url(absolute: item.posterUrl), title: item.title ?? "Title")
                            .frame(width: Theme.isTV ? 88 : 64, height: Theme.isTV ? 132 : 96).clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title ?? "Untitled").font(Theme.font(Theme.isTV ? 24 : 17, weight: .semibold))
                            Text(item.statusLabel).foregroundStyle(Theme.jade)
                            if let download = state.queue?.label(for: item) { Text(download).foregroundStyle(Theme.muted) }
                            if !state.mine, let name = item.requestedBy { Text(name).font(Theme.font(14)).foregroundStyle(Theme.muted) }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(Theme.text)
                }.buttonStyle(ArtworkButtonStyle()).disabled(item.kind == nil || item.tmdbId == nil)
                    .focused($requestFocus, equals: "activity-\(item.id)")
            }
        }.requestFocusSection()
    }
    private func load(force: Bool = false) async {
        let state = state, expected = model.generation, expectedKey = key
        guard model.extensionEnabled || model.isDemo else { return }
        if model.isDemo {
            state.titles = RequestPreview.titles
            state.discovery = RequestDiscoverySection.allCases.map { .init(section: $0, titles: RequestPreview.titles) }
            state.loading = false; return
        }
        guard let client = model.client else { return }
        guard force || state.loadedKey != expectedKey || Date().timeIntervalSince(state.loadedAt) > 60 else { return }
        let isActivity = activityMode, isDiscovery = discoveryMode
        let category = ["activity", "discover"].contains(state.category) ? "trending" : state.category
        let query = state.query, page = state.page, mine = state.mine, filter = state.filter
        state.loading = true; state.error = nil
        if !force { state.titles = []; state.activity = []; state.queue = nil; state.discovery = [] }
        defer { if model.generation == expected && key == expectedKey { state.loading = false } }
        do {
            if !query.isEmpty { try await Task.sleep(for: .milliseconds(350)) }
            guard try await client.requestAccess().available else { throw RequestFailure.unavailable }
            let service = try state.prepare(client: client)
            let pending = try await service.journal.entries()
            if isDiscovery {
                async let personalResult = try? client.requestActivity(mine: true)
                let rows = try await client.requestDiscovery(includeRecommendations: model.features.support) { row in
                    guard !Task.isCancelled, model.generation == expected, key == expectedKey else { return }
                    state.discovery.removeAll { $0.id == row.id }
                    state.discovery.append(row)
                    state.discovery.sort {
                        (RequestDiscoverySection.allCases.firstIndex(of: $0.section) ?? 0) <
                        (RequestDiscoverySection.allCases.firstIndex(of: $1.section) ?? 0)
                    }
                }
                guard !Task.isCancelled, model.generation == expected, key == expectedKey else { return }
                let personal = await personalResult
                let queue = personal?.requests.isEmpty == false ? try? await client.requestQueue() : nil
                guard !Task.isCancelled, model.generation == expected, key == expectedKey else { return }
                state.discovery = rows; state.totalPages = 1
                state.personalActivity = (personal?.requests ?? []).filter { $0.kind != nil && $0.tmdbId != nil }
                state.personalQueue = queue
            } else if isActivity {
                let result = try await client.requestActivity(mine: mine, page: page, filter: filter)
                let queue = try? await client.requestQueue()
                guard !Task.isCancelled, model.generation == expected, key == expectedKey else { return }
                state.activity = result.requests; state.queue = queue; state.totalPages = max(1, min(500, result.totalPages ?? 1))
            } else {
                let result = try await client.requestTitles(category: category, query: query, page: page)
                guard !Task.isCancelled, model.generation == expected, key == expectedKey else { return }
                var seen = Set<String>()
                state.titles = result.results.filter { $0.id > 0 && $0.kind != nil && seen.insert($0.identity).inserted }
                state.totalPages = max(1, min(500, result.totalPages ?? 1))
            }
            state.pending = pending; state.loadedKey = expectedKey; state.loadedAt = Date()
        } catch is CancellationError { }
        catch { if !Task.isCancelled, model.generation == expected, key == expectedKey { state.error = error.localizedDescription } }
    }
}

private struct RequestPoster: View {
    @Environment(AppModel.self) private var model
    let url: URL?
    let title: String
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { PreviewArtwork(title: title, seed: title, showTitle: true) }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.accessibilityHidden(true)
            .task(id: "\(model.generation)-\(url?.absoluteString ?? "")") {
                image = nil
                guard let url, !model.isDemo else { return }
                let result = try? await model.imageCache.requestImage(url: url)
                if !Task.isCancelled { image = result }
            }
    }
}

private struct RequestDetailsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let selection: RequestSelection
    let wide: Bool
    let open: (MediaItem) -> Void
    @State private var title: RequestTitle?
    @State private var settings: RequestSeasonSettings?
    @State private var quota: RequestQuota?
    @State private var seasons: Set<Int> = []
    @State private var entries: [RequestJournal.Entry] = []
    @State private var activity: RequestActivityItem?
    @State private var download: String?
    @State private var loading = true
    @State private var updating = false
    @State private var sending = false
    @State private var error: String?
    @State private var outcome: String?
    @State private var receiptStatus: Int?
    @State private var blocked = false
    @State private var refresh = 0
    @State private var loadID = UUID()
    @State private var confirmation = false
    @State private var retryConfirmation = false
    @State private var unconfirmed = false
    @State private var initializedChoices = false
    private var intent: RequestIntent {
        .init(kind: selection.kind, id: selection.titleID, seasons: Array(seasons), tvdbID: title?.externalIds?.tvdbId)
    }
    private var canSend: Bool {
        guard !loading, !sending, !blocked, !model.isDemo, let title, model.extensionEnabled else { return false }
        if selection.kind == .movie,
           title.mediaInfo?.status4k == 5 || title.mediaInfo?.requests?.contains(where: { [1, 2].contains($0.status ?? 0) }) == true { return false }
        return (try? intent.validate(title: title, settings: settings, quota: quota)) != nil
    }
    private var movieCanBeRequested: Bool {
        guard let title, selection.kind == .movie, entries.isEmpty, receiptStatus == nil,
              title.mediaInfo?.status4k != 5 else { return false }
        return (try? RequestIntent(kind: .movie, id: selection.titleID).validate(title: title, settings: nil, quota: nil)) != nil
    }
    private var visibleSeasons: [RequestSeason] {
        (title?.seasons ?? []).filter { $0.seasonNumber >= (settings?.enableSpecialEpisodes == true ? 0 : 1) && ($0.episodeCount ?? 0) > 0 }
            .sorted { $0.seasonNumber < $1.seasonNumber }
    }
    private func state(_ season: RequestSeason) -> RequestSeasonState {
        guard let title else { return .unknown }
        let serverState = title.requestSeasonState(season.seasonNumber)
        if serverState.requestable, entries.contains(where: { ($0.intent.seasons ?? []).contains(season.seasonNumber) }) {
            return receiptStatus == 1 ? .pendingApproval : .requested
        }
        return serverState
    }
    private var missing: [RequestSeason] { visibleSeasons.filter { state($0).requestable } }
    private var statusLabel: String {
        if unconfirmed { return "Confirmation pending" }
        if activity?.statusLabel == "Available" { return "Ready to watch" }
        if let download { return download }
        if let activity { return activity.statusLabel }
        if receiptStatus == 1 { return "Awaiting approval" }
        if let title, title.mediaInfo?.status == 5 || title.mediaInfo?.status4k == 5 { return "Ready to watch" }
        if let outcome { return outcome }
        return title?.status() ?? "Status unavailable"
    }
    private var showsStatus: Bool { unconfirmed || outcome != nil || activity != nil || title?.status() != "Not requested" && title != nil || title?.mediaInfo?.status4k == 5 }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.isTV ? 30 : 24) {
                    #if os(tvOS)
                    HStack {
                        Text("Requests").font(Theme.font(28, weight: .semibold))
                        Spacer()
                        Button("Done") { dismiss() }.buttonStyle(ZoroButtonStyle())
                    }.requestFocusSection()
                    #endif
                    if loading { ProgressView("Loading title…") }
                    if let title {
                        HStack(alignment: .center, spacing: Theme.isTV ? 32 : 18) {
                            RequestPoster(url: RequestArtwork.url(path: title.posterPath), title: title.displayTitle)
                                .aspectRatio(2 / 3, contentMode: .fit).frame(width: Theme.isTV ? 200 : 88)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 10) {
                                Text(title.displayTitle).font(Theme.font(Theme.isTV ? 40 : 28, weight: .bold, relativeTo: .title))
                                Text([title.year, selection.kind == .movie ? "Movie" : "TV show"].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .foregroundStyle(Theme.muted)
                                if movieCanBeRequested { requestButton }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if showsStatus { requestStatus }
                        if let error {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(error).font(Theme.font(Theme.isTV ? 20 : 14)).foregroundStyle(Theme.muted)
                                if !unconfirmed { Button("Try again") { refresh += 1 }.buttonStyle(FlatOptionStyle()) }
                            }
                        }
                        if selection.kind == .tv { seasonGroups }
                        if selection.kind == .tv, !missing.isEmpty { requestButton }
                        if unconfirmed {
                            Button("Review another attempt") { retryConfirmation = true }
                                .buttonStyle(FlatOptionStyle()).disabled(sending || updating)
                        }
                        if let limit = quota?.limit(selection.kind), let remaining = limit.remaining {
                            Text("\(remaining) \(selection.kind == .tv ? "seasons" : "movies") remaining in your \(limit.days ?? 7)-day request limit.")
                                .font(Theme.font(Theme.isTV ? 18 : 12)).foregroundStyle(Theme.muted)
                        }
                        if let itemID = title.mediaInfo?.jellyfinMediaId ?? title.mediaInfo?.jellyfinMediaId4k,
                           selection.kind == .movie || !visibleSeasons.contains(where: { state($0) == .available }) {
                            Button { Task { await openLibrary(itemID) } } label: { Label("Open in library", systemImage: "play.fill") }
                                .buttonStyle(ZoroButtonStyle())
                        }
                        if let overview = title.overview, !overview.isEmpty {
                            Text(overview).font(Theme.font(Theme.isTV ? 23 : 16)).fixedSize(horizontal: false, vertical: true)
                        }
                    } else if let error {
                        StatusView(title: "Title unavailable", detail: error, icon: "exclamationmark.circle", retry: { refresh += 1 })
                    }
                }.padding(Theme.gutter).padding(.vertical, 16)
                    .frame(maxWidth: Theme.isTV ? 1300 : 850, alignment: .leading).frame(maxWidth: .infinity)
            }.background(Theme.background).foregroundStyle(Theme.text)
                #if os(iOS)
                .navigationTitle("Requests").navigationBarTitleDisplayMode(.inline)
                .refreshable { await load(quiet: true) }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                #endif
                .task(id: refresh) { await load(quiet: title != nil) }
                .task(id: scenePhase) {
                    guard scenePhase == .active, !model.isDemo else { return }
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(30)) } catch { return }
                        guard !Task.isCancelled, !sending else { continue }
                        await load(quiet: true)
                    }
                }
                .onChange(of: scenePhase) { _, phase in if phase == .active, title != nil { refresh += 1 } }
                .alert("Request \(title?.displayTitle ?? "this title")?", isPresented: $confirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Send request") { Task { await send() } }
                } message: {
                    Text(selection.kind == .tv ? seasons.sorted().map { $0 == 0 ? "Specials" : "Season \($0)" }.joined(separator: ", ") : "Your server manages quality and approval.")
                }
                .confirmationDialog("Check Activity before trying again", isPresented: $retryConfirmation, titleVisibility: .visible) {
                    Button("I checked · Allow another attempt") { Task { await allowRetry() } }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("The first request may have reached the server. Continue only after checking Activity or confirming with your server owner. Nothing is resent automatically.")
                }
        }.tint(Theme.jade).preferredColorScheme(.dark)
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
    }
    private var requestButton: some View {
        Button { confirmation = true } label: {
            Label(sending ? "Sending…" : selection.kind == .tv ? "Request \(seasons.count) \(seasons.count == 1 ? "season" : "seasons")" : "Request movie", systemImage: "plus")
                .frame(maxWidth: Theme.isTV ? nil : .infinity)
        }.buttonStyle(ZoroButtonStyle(primary: true)).disabled(!canSend)
            .accessibilityIdentifier("request-submit").requestFocusSection()
    }
    private var requestStatus: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: unconfirmed ? "exclamationmark.circle" : statusLabel == "Ready to watch" ? "checkmark.circle" : "clock")
                    .foregroundStyle(unconfirmed ? .yellow : Theme.jade)
                VStack(alignment: .leading, spacing: 6) {
                    Text(statusLabel).font(Theme.font(Theme.isTV ? 26 : 18, weight: .semibold))
                    if unconfirmed {
                        Text("The server may have received your request. We’ll keep checking; nothing is resent automatically.")
                            .font(Theme.font(Theme.isTV ? 20 : 14)).foregroundStyle(Theme.muted)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("request-current-status")
            Button {
                model.requestsLibrary.category = "activity"; model.requestsLibrary.mine = true
                model.requestsLibrary.query = ""; model.requestsLibrary.page = 1; dismiss()
            } label: { Label("View request activity", systemImage: "arrow.right") }
                .buttonStyle(FlatOptionStyle()).foregroundStyle(Theme.jade)
        }.requestFocusSection()
    }
    private var seasonGroups: some View {
        VStack(alignment: .leading, spacing: Theme.isTV ? 28 : 24) {
            let available = visibleSeasons.filter { state($0) == .available }
            let progress = visibleSeasons.filter { [.pendingApproval, .requested].contains(state($0)) }
            let unknown = visibleSeasons.filter { state($0) == .unknown }
            if !available.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    groupHeading("Available to watch", count: available.count)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(available) { season in
                            if let id = libraryID(for: season) {
                                Button { Task { await openLibrary(id, season: season.seasonNumber) } } label: {
                                    Label(season.displayName, systemImage: "play.fill").frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(FlatOptionStyle()).accessibilityLabel("Watch \(season.displayName)")
                            } else { Label(season.displayName, systemImage: "checkmark").frame(minHeight: Theme.target) }
                        }
                    }.requestFocusSection()
                }
            }
            if !progress.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    groupHeading("Already requested", count: progress.count)
                    ForEach(progress) { season in
                        HStack {
                            Text(season.displayName)
                            Spacer(minLength: 12)
                            Text(unconfirmed ? "Confirmation pending" : state(season).label).foregroundStyle(Theme.muted)
                        }.font(Theme.font(Theme.isTV ? 22 : 14)).accessibilityElement(children: .combine)
                    }
                }
            }
            if !missing.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    groupHeading("Missing seasons", count: missing.count)
                    if settings?.partialRequestsEnabled != true {
                        Text("Your server requests all missing seasons together.").font(Theme.font(Theme.isTV ? 20 : 13)).foregroundStyle(Theme.muted)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(missing) { season in
                            Button {
                                if seasons.contains(season.seasonNumber) { seasons.remove(season.seasonNumber) }
                                else { seasons.insert(season.seasonNumber) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: seasons.contains(season.seasonNumber) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(Theme.jade)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(season.displayName)
                                        if state(season) == .partlyAvailable { Text("Missing episodes").font(Theme.font(Theme.isTV ? 18 : 12)).foregroundStyle(Theme.muted) }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(14).frame(maxWidth: .infinity, minHeight: Theme.target + 12, alignment: .leading)
                                    .background(seasons.contains(season.seasonNumber) ? Theme.avatar.opacity(0.6) : Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(seasons.contains(season.seasonNumber) ? Theme.jade : Theme.border, lineWidth: 1))
                            }.buttonStyle(FlatOptionStyle()).disabled(sending || loading || settings?.partialRequestsEnabled != true)
                                .accessibilityAddTraits(seasons.contains(season.seasonNumber) ? .isSelected : [])
                                .accessibilityLabel("\(season.displayName), \(state(season).label)")
                        }
                    }.requestFocusSection()
                }
            }
            if !unknown.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Availability not confirmed").font(Theme.font(Theme.isTV ? 23 : 17, weight: .semibold))
                    Text(unknown.map(\.displayName).joined(separator: ", ")).foregroundStyle(Theme.muted)
                }
            }
        }
    }
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: Theme.isTV ? 300 : 140), spacing: 12, alignment: .leading)] }
    private func groupHeading(_ text: String, count: Int) -> some View {
        HStack { Text(text).font(Theme.font(Theme.isTV ? 26 : 18, weight: .semibold)); Spacer(); Text("\(count)").font(Theme.font(Theme.isTV ? 20 : 13)).foregroundStyle(Theme.muted) }
            .accessibilityAddTraits(.isHeader)
    }
    private func libraryID(for season: RequestSeason) -> String? {
        guard let title else { return nil }
        return title.seasonState(season.seasonNumber) == .available ? title.mediaInfo?.jellyfinMediaId : title.mediaInfo?.jellyfinMediaId4k
    }
    private func updateSelection() {
        let eligible = Set(missing.map(\.seasonNumber))
        if !initializedChoices || settings?.partialRequestsEnabled != true { seasons = eligible }
        else { seasons.formIntersection(eligible) }
        initializedChoices = true
    }
    private func load(quiet: Bool = false) async {
        guard !updating, !sending else { return }
        if model.isDemo { title = RequestPreview.titles.first { $0.id == selection.titleID }; loading = false; return }
        guard let client = model.client, model.extensionEnabled else { loading = false; error = RequestFailure.unavailable.localizedDescription; return }
        let expected = model.generation, currentLoad = UUID()
        loadID = currentLoad; updating = true; loading = !quiet && title == nil
        defer { if expected == model.generation, loadID == currentLoad { updating = false; loading = false } }
        do {
            async let titleResult = client.requestTitle(kind: selection.kind, id: selection.titleID)
            async let quotaResult = client.requestQuota()
            let fresh = try await titleResult, freshQuota = try await quotaResult
            let seasonSettings = selection.kind == .tv ? try await client.requestSeasonSettings() : nil
            let service = try model.requestsLibrary.prepare(client: client)
            try await service.journal.reconcile(fresh)
            let saved = try await service.journal.entries().filter { $0.intent.mediaId == selection.titleID && $0.intent.mediaType == selection.kind }
            let activityPage = try? await client.requestActivity(mine: true)
            let personal = activityPage?.requests.first { $0.tmdbId == selection.titleID && $0.kind == selection.kind }
            var queueLabel: String?
            if let personal { queueLabel = try? await client.requestQueue().label(for: personal) }
            guard !Task.isCancelled, expected == model.generation, loadID == currentLoad else { return }
            title = fresh; quota = freshQuota; settings = seasonSettings; entries = saved
            activity = personal; download = queueLabel; error = nil
            blocked = saved.contains { $0.receiptID == nil }; unconfirmed = blocked
            if blocked { outcome = nil }
            else if !saved.isEmpty { outcome = "Request received" }
            else { outcome = nil; receiptStatus = nil }
            updateSelection()
        } catch is CancellationError { }
        catch { if !Task.isCancelled, expected == model.generation, loadID == currentLoad { self.error = error.localizedDescription; blocked = true } }
    }
    private func send() async {
        guard canSend, let client = model.client else { return }
        loadID = UUID(); updating = false
        sending = true; error = nil
        let expected = model.generation, intent = intent
        defer { if expected == model.generation { sending = false } }
        do {
            let service = try model.requestsLibrary.prepare(client: client)
            let receipt = try await service.submit(intent)
            guard expected == model.generation else { return }
            blocked = true; receiptStatus = receipt.status; outcome = "Request received"
            model.requestsLibrary.revision += 1
            await client.responseCache?.invalidateMetadata()
            guard expected == model.generation else { return }
            model.homeRevision += 1; sending = false
            await load(quiet: true)
        } catch {
            guard expected == model.generation else { return }
            let failure = error.localizedDescription
            blocked = true
            unconfirmed = (error as? RequestFailure) == .unconfirmed
            sending = false
            await load(quiet: true)
            if expected == model.generation, !unconfirmed { self.error = failure }
        }
    }
    private func allowRetry() async {
        guard let client = model.client, !sending else { return }
        let expected = model.generation; sending = true
        defer { if expected == model.generation { sending = false } }
        do {
            let service = try model.requestsLibrary.prepare(client: client)
            try await service.allowAnotherAttempt(kind: selection.kind, id: selection.titleID, is4K: false)
            guard expected == model.generation else { return }
            unconfirmed = false; blocked = false; outcome = nil; refresh += 1
        } catch { if expected == model.generation { self.error = error.localizedDescription } }
    }
    private func openLibrary(_ id: String, season: Int? = nil) async {
        guard let client = model.client else { return }
        let expected = model.generation
        do {
            var item = try await client.item(id, fresh: true)
            if let season, item.isSeries, let selected = try await client.seasons(seriesID: id).items.first(where: { $0.indexNumber == season }) { item = selected }
            if !Task.isCancelled, expected == model.generation { open(item) }
        } catch { if expected == model.generation { self.error = error.localizedDescription } }
    }
}

private extension View {
    @ViewBuilder func requestFocusSection() -> some View {
        #if os(tvOS)
        self.frame(maxWidth: .infinity, alignment: .leading).focusSection()
        #else
        self
        #endif
    }
}

private enum RequestPreview {
    static let titles: [RequestTitle] = (1...12).compactMap { index in
        let names = ["The Last Light", "Northbound", "Open Water", "City Stories", "Tideline", "Wild Blue"]
        let value: [String: Any] = ["id": index, "mediaType": index % 3 == 0 ? "tv" : "movie", "title": names[(index - 1) % names.count],
            "overview": PreviewLibrary.synopsis, "releaseDate": "2026-01-01"]
        return (try? JSONSerialization.data(withJSONObject: value)).flatMap { try? JSONDecoder().decode(RequestTitle.self, from: $0) }
    }
}

enum HomeUtility: String, Identifiable {
    case support = "Support", notifications = "Notifications"
    var id: String { rawValue }
}

struct HomeUtilityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let utility: HomeUtility
    @Environment(\.adaptiveWindow) private var window
    @State private var libraryItem: MediaItem?
    @State private var notificationPlayer: PlaybackPresentation?
    @State private var allowsSupportProcessing = false
    #if os(tvOS)
    @State private var choosingSupportIssue = false
    #endif
    private let issues = ["Playback / buffering problem", "Live TV issue", "Download not appearing / slow",
                          "Request a 4K movie upgrade", "Subtitle or captions problem", "Corrupted video or audio",
                          "Feature request", "Other"]
    var body: some View {
        NavigationStack {
            Group {
                if utility == .notifications {
                    NotificationInboxView(close: { dismiss() }, open: { libraryItem = $0 })
                        .modifier(HideNavigationBar())
                } else {
                    #if os(tvOS)
                    // A fixed header keeps focused form rows from scrolling behind
                    // the title and supplies a full-width path back to Done.
                    VStack(spacing: 0) {
                        HStack(spacing: 20) {
                            Text(utility.rawValue).font(Theme.font(32, weight: .bold))
                                .accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 12)
                            Button("Done") { dismiss() }.buttonStyle(ZoroButtonStyle())
                        }.padding(Theme.gutter).frame(maxWidth: .infinity).focusSection()
                        Divider().overlay(Theme.muted.opacity(0.2))
                        supportScroll.clipped().focusSection()
                    }.modifier(HideNavigationBar()).onExitCommand { dismiss() }
                    #else
                    supportScroll.navigationTitle(utility.rawValue)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                    #endif
                }
            }.foregroundStyle(Theme.text).background(Theme.background)
                .navigationDestination(item: $libraryItem) { item in
                    DetailView(item: item, wide: Theme.isTV || window.usesWideContent) { item, options in
                        var selected = options; selected.bitrate = model.bitrate
                        notificationPlayer = .init(item: item, options: selected)
                    }
                }
        }.tint(Theme.jade).preferredColorScheme(.dark)
            .fullScreenCover(item: $notificationPlayer) { presentation in
                NativePlayerView(presentation: presentation, onClose: { notificationPlayer = nil })
            }
    }

    private var supportScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.isDemo {
                    Text("Preview only · No report will be sent").font(Theme.font(14)).foregroundStyle(Theme.jade)
                }
                supportContent
            }.padding(Theme.gutter).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private var supportContent: some View {
        @Bindable var model = model
        if !model.features.support {
            StatusView(title: "Support unavailable", detail: "This server does not currently offer support for your account.", icon: "support")
        } else {
            Text("How can we help?").font(Theme.font(Theme.isTV ? 32 : 24, weight: .bold))
            Text("Send an issue to your server’s support agent. Replies appear under the notification bell.")
                .foregroundStyle(Theme.muted)
            if model.supportSubmission.canEdit {
                #if os(tvOS)
                // tvOS turns the default Picker into eight tiny segments in
                // this sheet. A labeled choice opens a readable remote list.
                Button { choosingSupportIssue = true } label: {
                    HStack(spacing: 16) {
                        Text(model.supportIssue).multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down")
                    }.padding(14).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                }.buttonStyle(ArtworkButtonStyle()).accessibilityLabel("Issue: " + model.supportIssue)
                    .confirmationDialog("Issue", isPresented: $choosingSupportIssue, titleVisibility: .visible) {
                        ForEach(issues, id: \.self) { issue in
                            Button(issue) { model.supportIssue = issue }
                        }
                        Button("Cancel", role: .cancel) { }
                    }
                #else
                Picker("Issue", selection: $model.supportIssue) {
                    ForEach(issues, id: \.self) { Text($0).tag($0) }
                }
                #endif
                VStack(alignment: .leading, spacing: 8) {
                    Text("Movie, show or channel (optional)").font(Theme.font(14, weight: .semibold))
                    TextField("Title or channel name", text: $model.supportMedia)
                        .padding(12).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Affected movie, show or channel")
                    Text("\(model.supportMedia.utf16.count)/200").font(Theme.font(12)).foregroundStyle(Theme.muted)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("What happened?").font(Theme.font(14, weight: .semibold))
                    #if os(iOS)
                    TextEditor(text: $model.supportDescription).frame(minHeight: 140)
                        .scrollContentBackground(.hidden).padding(8)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Describe the issue")
                    #else
                    TextField("Describe the issue", text: $model.supportDescription)
                    #endif
                    Text("\(model.supportDescription.utf16.count)/1,500").font(Theme.font(12)).foregroundStyle(Theme.muted)
                }
                Text("Sending as \(model.viewerName)").font(Theme.font(16, weight: .semibold))
                Text("Your report, affected title and account context go to this server’s administrators and support service. The service may send them to its configured AI support provider and consult relevant server diagnostics. Ask your server owner about that provider before sending sensitive information. Leave out passwords and payment details.")
                    .font(Theme.font(14)).foregroundStyle(Theme.muted)
                Toggle("I agree to share this report for server support and possible AI processing", isOn: $allowsSupportProcessing)
                    .accessibilityIdentifier("support-processing-consent")
                Button("Send report") { allowsSupportProcessing = false; model.sendSupport() }.buttonStyle(ZoroButtonStyle(primary: true))
                    .disabled(model.isDemo || !model.supportReport.isValid || !allowsSupportProcessing)
                    .accessibilityIdentifier("support-send")
            }
            switch model.supportSubmission {
            case .idle: EmptyView()
            case .sending: ProgressView("Sending your report…")
            case .accepted(let ticketID):
                Label("Report received", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.jade)
                Text("Reference: \(ticketID)").font(Theme.font(14))
                Text("Your server’s support agent will review it. Watch Notifications for a reply.").foregroundStyle(Theme.muted)
                Button("Start another report") { model.supportSubmission = .idle }.buttonStyle(ZoroButtonStyle())
            case .rejected:
                Text(SupportError.rejected.localizedDescription).foregroundStyle(Theme.muted)
            case .uncertain:
                Label("Delivery unconfirmed", systemImage: "exclamationmark.circle")
                Text(SupportError.outcomeUnknown.localizedDescription).foregroundStyle(Theme.muted)
            }
        }
    }

}

/// The header is outside the clipped scroll viewport. Seen items stay in their
/// current position for this presentation, then move to Hidden on the next open.
struct NotificationInboxView: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    let open: (MediaItem) -> Void
    @State private var showHidden = false
    @State private var sessionRequestIDs: Set<Int> = []
    @State private var sessionReplyKeys: Set<String> = []
    @State private var openingID: Int?
    @State private var openError: String?
    @State private var openTask: Task<Void, Never>?
    @FocusState private var closeFocused: Bool
    private var newRequests: [RequestAvailabilityNotice] {
        model.requestNotices.filter { !model.requestReadIDs.contains($0.id) || sessionRequestIDs.contains($0.id) }
    }
    private var oldRequests: [RequestAvailabilityNotice] {
        model.requestNotices.filter { model.requestReadIDs.contains($0.id) && !sessionRequestIDs.contains($0.id) }
    }
    private var newReplies: [SupportReply] {
        model.replies.filter { !model.seenReplyKeys.contains($0.notificationKey) || sessionReplyKeys.contains($0.notificationKey) }
    }
    private var oldReplies: [SupportReply] {
        model.hiddenReplies.filter { !sessionReplyKeys.contains($0.notificationKey) }
    }
    private var historyCount: Int { oldRequests.count + oldReplies.count }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Notifications").font(Theme.font(Theme.isTV ? 28 : 21, weight: .bold))
                    .layoutPriority(1).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: Theme.isTV ? 20 : 17, weight: .semibold))
                        .frame(width: Theme.isTV ? 48 : 44, height: Theme.isTV ? 48 : 44)
                        .background(Theme.text.opacity(0.06), in: Circle())
                }.buttonStyle(ArtworkButtonStyle()).focused($closeFocused)
                    .accessibilityLabel("Close notifications").accessibilityIdentifier("notifications-close")
            }.padding(.horizontal, Theme.isTV ? 24 : 16).padding(.vertical, 12)
                .background(Theme.panel)
            Divider().overlay(Theme.border)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let openError { Text(openError).foregroundStyle(Theme.muted) }
                    if model.replyError != nil || model.requestNoticeError != nil {
                        Button { Task { await model.refreshNotifications(force: true) } } label: {
                            Label("Couldn't refresh · Retry", systemImage: "arrow.clockwise")
                                .font(Theme.font(Theme.isTV ? 20 : 14)).padding(12)
                        }.buttonStyle(ArtworkButtonStyle()).disabled(model.loadingNotifications)
                    }
                    if newRequests.isEmpty && newReplies.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("You're all caught up").font(Theme.font(Theme.isTV ? 23 : 17, weight: .semibold))
                            Text("New updates will appear here.").font(Theme.font(Theme.isTV ? 19 : 14)).foregroundStyle(Theme.muted)
                        }.padding(.vertical, 20).padding(.horizontal, 8)
                    }
                    ForEach(newRequests) { notice in
                        requestRow(notice).modifier(NotificationSeenModifier {
                            sessionRequestIDs.insert(notice.id)
                            await model.markRequestRead(notice)
                        })
                    }
                    ForEach(newReplies, id: \.notificationKey) { reply in
                        replyRow(reply).modifier(NotificationSeenModifier {
                            sessionReplyKeys.insert(reply.notificationKey)
                            await model.markRead(reply)
                        })
                    }
                    if historyCount > 0 {
                        Button { showHidden.toggle() } label: {
                            HStack {
                                Text("Hidden (\(historyCount))")
                                Spacer()
                                Image(systemName: showHidden ? "chevron.up" : "chevron.down")
                            }.font(Theme.font(Theme.isTV ? 21 : 15, weight: .semibold))
                                .foregroundStyle(Theme.muted).padding(14).frame(minHeight: 48)
                        }.buttonStyle(ArtworkButtonStyle()).accessibilityIdentifier("notifications-hidden")
                            .accessibilityValue(showHidden ? "Expanded" : "Collapsed")
                        if showHidden {
                            ForEach(oldRequests) { requestRow($0) }
                            ForEach(oldReplies, id: \.notificationKey) { replyRow($0) }
                            if model.hasOlderRequestNotices {
                                Text("More requests are in Requests → Activity.")
                                    .font(Theme.font(Theme.isTV ? 18 : 13)).foregroundStyle(Theme.muted).padding(8)
                            }
                        }
                    }
                }.padding(Theme.isTV ? 18 : 12)
            }.clipped()
        }.foregroundStyle(Theme.text).background(Theme.panel).tint(Theme.jade)
            .accessibilityIdentifier("notification-inbox")
            .task { await model.refreshNotifications() }
            .onAppear { closeFocused = Theme.isTV }
            .onDisappear { openTask?.cancel() }
            #if os(tvOS)
            .onExitCommand(perform: close)
            #endif
    }
    private func requestRow(_ notice: RequestAvailabilityNotice) -> some View {
        Button { openRequest(notice) } label: {
            HStack(alignment: .center, spacing: 14) {
                RequestPoster(url: RequestArtwork.url(absolute: notice.posterURL), title: notice.title)
                    .frame(width: Theme.isTV ? 54 : 42, height: Theme.isTV ? 81 : 63)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 5) {
                    Text(notice.title).font(Theme.font(Theme.isTV ? 22 : 16, weight: .semibold))
                        .multilineTextAlignment(.leading).lineLimit(2)
                    Text(openingID == notice.id ? "Opening…" : notice.is4K ? "Ready to watch · 4K" : "Ready to watch")
                        .font(Theme.font(Theme.isTV ? 18 : 13)).foregroundStyle(Theme.jade)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: Theme.isTV ? 18 : 13)).foregroundStyle(Theme.muted)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(ArtworkButtonStyle()).disabled(openingID != nil)
            .accessibilityLabel("\(notice.title), \(notice.is4K ? "4K " : "")ready to watch. Open title")
            .accessibilityIdentifier("notification-request-\(notice.id)")
    }
    private func replyRow(_ reply: SupportReply) -> some View {
        NotificationReplyRow(reply: reply)
    }
    private func openRequest(_ notice: RequestAvailabilityNotice) {
        guard openingID == nil else { return }
        guard !model.isDemo, let client = model.client else {
            openError = "Connect your server to open requested titles."; return
        }
        let expected = model.generation
        openingID = notice.id; openError = nil
        openTask = Task {
            defer { openingID = nil }
            do {
                let item = try await client.requestNotificationItem(notice)
                guard !Task.isCancelled, model.generation == expected else { return }
                await model.markRequestRead(notice)
                guard !Task.isCancelled, model.generation == expected else { return }
                open(item)
            } catch {
                guard !Task.isCancelled, model.generation == expected else { return }
                openError = "This title couldn't be opened. Check its availability in Requests."
            }
        }
    }
}

private struct NotificationReplyRow: View {
    let reply: SupportReply
    @State private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label { Text("Support reply") } icon: { InterfaceIcon(name: "support", size: Theme.isTV ? 22 : 18) }
                    .foregroundStyle(Theme.jade)
                Text(reply.affectedMedia?.isEmpty == false ? reply.affectedMedia! : reply.issueType)
                    .fontWeight(.semibold).lineLimit(2)
                Text(reply.message).foregroundStyle(Theme.muted).lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                if expanded { Text("Reference: \(reply.id)").foregroundStyle(Theme.muted) }
            }.font(Theme.font(Theme.isTV ? 20 : 14)).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Theme.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(ArtworkButtonStyle()).accessibilityHint("Show or hide the full reply")
    }
}

/// Lazy layout alone is not evidence that a notification was seen. Require a
/// mostly visible row for a short dwell, and cancel when it scrolls out or closes.
private struct NotificationSeenModifier: ViewModifier {
    let seen: () async -> Void
    @State private var visible = false
    @State private var acknowledged = false
    func body(content: Content) -> some View {
        content.onScrollVisibilityChange(threshold: 0.6) { visible = $0 }
            .task(id: visible) {
                guard visible, !acknowledged else { return }
                do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
                guard !Task.isCancelled else { return }
                await seen(); acknowledged = true
            }
    }
}

struct NotificationBellAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

#if os(tvOS)
struct TVNotificationPopover: View {
    let anchor: Anchor<CGRect>
    let close: () -> Void
    let open: (MediaItem) -> Void
    var body: some View {
        GeometryReader { geometry in
            let bell = geometry[anchor]
            let width: CGFloat = min(560, geometry.size.width - 48)
            let left = min(max(24, bell.maxX - width + 16), geometry.size.width - width - 24)
            let top = bell.maxY + 14
            let height = min(650, geometry.size.height - top - 24)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.18).contentShape(Rectangle()).onTapGesture(perform: close)
                NotificationPointer().fill(Theme.panel).frame(width: 24, height: 12)
                    .position(x: bell.midX, y: top - 5)
                NotificationInboxView(close: close, open: open)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
                    .offset(x: left, y: top)
            }
        }.onExitCommand(perform: close)
    }
}
private struct NotificationPointer: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.closeSubpath()
        }
    }
}
#else
struct MobileNotificationButton: View {
    @Environment(AppModel.self) private var model
    let open: (MediaItem) -> Void
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: {
            Image(systemName: "bell").frame(width: Theme.target, height: Theme.target)
                .overlay(alignment: .topTrailing) {
                    if model.preferences.showUnreadBadge && model.unreadNotificationCount > 0 {
                        Text(model.unreadNotificationCount > 99 ? "99+" : String(model.unreadNotificationCount))
                            .font(Theme.font(11, weight: .bold)).foregroundStyle(Theme.background)
                            .padding(4).background(Theme.jade, in: Capsule()).accessibilityHidden(true)
                    }
                }
        }.buttonStyle(ArtworkButtonStyle())
            .accessibilityLabel("Notifications, \(model.unreadNotificationCount) unread updates")
            .accessibilityIdentifier("home-notifications")
            .popover(isPresented: $presented, arrowEdge: .top) {
                NotificationInboxView(close: { presented = false }, open: { item in
                    presented = false; open(item)
                }).id(model.generation).frame(idealWidth: 360, idealHeight: 500)
                    .presentationCompactAdaptation(.popover).preferredColorScheme(.dark)
            }
    }
}
#endif
