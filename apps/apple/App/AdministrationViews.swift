import SwiftUI
import ZorofinCore

/// Native Metadata Manager and Account approvals for iPhone and iPad.
/// Dashboard uses the server's web UI through DashboardWebView.
enum AdministrationPage: String, Identifiable, Hashable {
    case metadata, accountApprovals
    var id: String { rawValue }
    var title: String {
        switch self {
        case .metadata: "Metadata Manager"
        case .accountApprovals: "Account approvals"
        }
    }
    var icon: String {
        switch self {
        case .metadata: "pencil"
        case .accountApprovals: "person.crop.circle.badge.checkmark"
        }
    }
}

#if os(iOS)
private func adminMessage(_ error: Error) -> String {
    if error is CancellationError { return "" }
    if let error = error as? LocalizedError, let text = error.errorDescription { return text }
    return "Something went wrong. Check your connection and try again."
}

private struct AdminErrorRow: View {
    let message: String?
    var body: some View {
        if let message, !message.isEmpty {
            Section { Text(message).foregroundStyle(.orange).accessibilityIdentifier("administration-error") }
        }
    }
}

/// Re-checks administrator rights before showing anything and whenever the app returns.
struct AdministrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let page: AdministrationPage
    @State private var verified = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if verified {
                    switch page {
                    case .metadata: MetadataManagerView()
                    case .accountApprovals: AccountApprovalsView()
                    }
                } else if let failure {
                    StatusView(title: page.title, detail: failure, icon: page.icon, retry: { Task { await verify() } })
                        .frame(maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.background)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("administration-done") } }
        }
        .tint(Theme.jade).preferredColorScheme(.dark)
        .task { await verify() }
        .onChange(of: scenePhase) { _, phase in if phase == .active && verified { Task { await verify() } } }
    }

    @MainActor private func verify() async {
        #if DEBUG
        if model.isDemo && ProcessInfo.processInfo.arguments.contains("--profile-admin-preview") { verified = true; return }
        #endif
        guard let client = model.client else { failure = "Sign in to your server to manage it."; return }
        let generation = model.generation
        failure = nil
        do {
            let viewer = try await client.currentViewer()
            guard generation == model.generation else { return }
            guard viewer.id == model.session?.viewer.id, viewer.policy?.isAdministrator == true else {
                if verified { dismiss() } else { failure = "Your account doesn’t have administrator access." }
                return
            }
            verified = true
        } catch {
            guard generation == model.generation, !verified else { return }
            failure = adminMessage(error)
        }
    }
}

private struct AdminFormStyle: ViewModifier {
    let title: String
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden).background(Theme.background).foregroundStyle(Theme.text)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Metadata Manager

private let metadataContainers: Set<String> = ["Series", "Season", "BoxSet", "MusicAlbum", "MusicArtist", "Folder", "CollectionFolder", "Playlist", "PhotoAlbum"]

private struct MetadataItemRow: View {
    let item: MediaItem
    var body: some View {
        HStack(spacing: 14) {
            MediaArtwork(item: item, width: 120, showPreviewTitle: false)
                .frame(width: 40, height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.isEpisode ? item.episodeLabel : item.name).lineLimit(2)
                if item.isEpisode, let series = item.seriesName { Text(series).font(.footnote).foregroundStyle(Theme.muted).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if let year = item.productionYear, !item.isEpisode { Text(String(year)).foregroundStyle(Theme.muted) }
        }
    }
}

private struct MetadataDestination: View {
    let item: MediaItem
    var body: some View {
        if metadataContainers.contains(item.type ?? "") { MetadataFolderView(parentID: item.id, title: item.name, editable: item.type != "CollectionFolder") }
        else { MetadataEditorView(itemID: item.id, title: item.name) }
    }
}

private struct MetadataManagerView: View {
    @Environment(AppModel.self) private var model
    @State private var libraries: [AdminLibrary] = []
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var searching = false
    @State private var error: String?
    var body: some View {
        Form {
            AdminErrorRow(message: error)
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(libraries.filter { $0.itemId != nil }) { library in
                    NavigationLink { MetadataFolderView(parentID: library.itemId!, title: library.name, editable: false) } label: {
                        Label(library.name, systemImage: "folder")
                    }
                }
            } else {
                if searching && results.isEmpty { ProgressView() }
                ForEach(results) { item in NavigationLink { MetadataDestination(item: item) } label: { MetadataItemRow(item: item) } }
                if !searching && results.isEmpty { Text("No matches").foregroundStyle(Theme.muted) }
            }
        }
        .modifier(AdminFormStyle(title: "Metadata Manager"))
        .searchable(text: $query, prompt: "Search titles")
        .task(id: model.generation) {
            guard let client = model.client else { return }
            do { libraries = try await client.adminLibraries(); error = nil } catch { self.error = adminMessage(error) }
        }
        .task(id: query) {
            let term = query.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, let client = model.client else { results = []; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do { results = try await client.metadataItems(search: term).items; error = nil }
            catch { if !(error is CancellationError) { self.error = adminMessage(error) } }
            searching = false
        }
    }
}

private struct MetadataFolderView: View {
    @Environment(AppModel.self) private var model
    let parentID: String
    let title: String
    let editable: Bool
    @State private var items: [MediaItem] = []
    @State private var total: Int?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        Form {
            AdminErrorRow(message: error)
            if editable {
                Section { NavigationLink { MetadataEditorView(itemID: parentID, title: title) } label: { Label("Edit \(title)", systemImage: "pencil") } }
            }
            Section {
                ForEach(items) { item in
                    NavigationLink { MetadataDestination(item: item) } label: { MetadataItemRow(item: item) }
                        .onAppear { if item.id == items.last?.id { Task { await load(more: true) } } }
                }
                if loading { ProgressView() }
            }
        }
        .modifier(AdminFormStyle(title: title))
        .refreshable { await load(more: false) }
        .task(id: model.generation) { await load(more: false) }
    }
    @MainActor private func load(more: Bool) async {
        guard let client = model.client, !loading else { return }
        if more, let total, items.count >= total { return }
        loading = true
        do {
            let page = try await client.metadataItems(parentID: parentID, start: more ? items.count : 0)
            items = more ? items + page.items.filter { new in !items.contains { $0.id == new.id } } : page.items
            total = page.totalRecordCount
            error = nil
        } catch { if !(error is CancellationError) { self.error = adminMessage(error) } }
        loading = false
    }
}

private struct MetadataEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let itemID: String
    let title: String
    @State private var baseline: MetadataDraft?
    @State private var draft: MetadataDraft?
    @State private var busy = false
    @State private var status: String?
    @State private var error: String?
    @State private var refreshing: MetadataRefreshMode?
    @State private var confirmDiscard = false
    private var dirty: Bool { draft != nil && draft != baseline }

    var body: some View {
        Form {
            AdminErrorRow(message: error)
            if let status { Text(status).foregroundStyle(Theme.jade) }
            if let binding = Binding($draft) { fields(binding) }
            else if error == nil { ProgressView() }
        }
        .modifier(AdminFormStyle(title: draft?.name.isEmpty == false ? draft!.name : title))
        .navigationBarBackButtonHidden(dirty)
        .toolbar {
            if dirty {
                ToolbarItem(placement: .navigation) { Button("Cancel") { confirmDiscard = true }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(busy).accessibilityIdentifier("metadata-save") }
            }
        }
        .task(id: model.generation) { await load() }
        .onChange(of: draft) { _, _ in status = nil }
        .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { draft = baseline; dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .confirmationDialog(refreshing?.title ?? "", isPresented: Binding(get: { refreshing != nil }, set: { if !$0 { refreshing = nil } }),
                            titleVisibility: .visible, presenting: refreshing) { mode in
            Button("Refresh", role: mode == .scan || mode == .missing ? nil : .destructive) { refresh(mode) }
            Button("Cancel", role: .cancel) {}
        } message: { mode in
            if mode == .replaceMetadata || mode == .replaceAll { Text("Edits that aren’t locked are replaced with your metadata providers’ details.") }
        }
    }

    @ViewBuilder private func fields(_ draft: Binding<MetadataDraft>) -> some View {
        Section {
            TextField("Title", text: draft.name)
            TextField("Original title", text: draft.originalTitle)
            TextField("Sort title", text: draft.sortName)
        }
        Section("Overview") {
            TextField("Overview", text: draft.overview, axis: .vertical).lineLimit(4...14)
        }
        Section("Details") {
            TextField("Tagline", text: draft.tagline)
            if draft.wrappedValue.hasEpisodeNumbers {
                if draft.wrappedValue.type == "Episode" {
                    TextField("Season number", text: draft.parentIndexNumber).keyboardType(.numberPad)
                }
                TextField(draft.wrappedValue.type == "Season" ? "Season number" : "Episode number", text: draft.indexNumber).keyboardType(.numberPad)
            }
            TextField("Year", text: draft.year).keyboardType(.numberPad)
            Toggle("Release date", isOn: Binding(get: { draft.wrappedValue.premiereDate != nil },
                                                  set: { draft.wrappedValue.premiereDate = $0 ? (draft.wrappedValue.premiereDate ?? Date()) : nil }))
            if draft.wrappedValue.premiereDate != nil {
                DatePicker("Released", selection: Binding(get: { draft.wrappedValue.premiereDate ?? Date() }, set: { draft.wrappedValue.premiereDate = $0 }),
                           displayedComponents: .date)
                    .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .current)
            }
            TextField("Parental rating", text: draft.officialRating).textInputAutocapitalization(.characters)
            TextField("Community rating", text: draft.communityRating).keyboardType(.decimalPad)
        }
        Section("Genres") { TextField("Comma separated", text: draft.genres, axis: .vertical) }
        Section("Tags") { TextField("Comma separated", text: draft.tags, axis: .vertical) }
        Section("Studios") { TextField("Comma separated", text: draft.studios, axis: .vertical) }
        Section {
            Toggle("Lock metadata", isOn: draft.lockData)
        }
        if draft.wrappedValue.supportsIdentify {
            Section {
                NavigationLink { IdentifyView(draft: draft.wrappedValue, onApply: { Task { await load() } }) } label: {
                    Label("Identify", systemImage: "magnifyingglass")
                }.disabled(dirty || busy)
            }
        }
        Section("Refresh") {
            ForEach(MetadataRefreshMode.allCases) { mode in
                Button(mode.title) { refreshing = mode }.disabled(dirty || busy)
            }
        }
    }

    @MainActor private func load() async {
        guard let client = model.client else { return }
        do {
            let fresh = try await client.metadataDraft(itemID: itemID)
            baseline = fresh; draft = fresh; error = nil
        } catch { if !(error is CancellationError) { self.error = adminMessage(error) } }
    }
    private func save() {
        guard let client = model.client, let draft, let baseline, !busy else { return }
        busy = true; error = nil
        Task {
            do {
                let saved = try await client.saveMetadata(draft, baseline: baseline)
                self.baseline = saved; self.draft = saved
                status = "Saved."
            } catch { self.error = adminMessage(error) }
            busy = false
        }
    }
    private func refresh(_ mode: MetadataRefreshMode) {
        guard let client = model.client, !busy else { return }
        busy = true; error = nil
        Task {
            do { try await client.refreshMetadata(itemID: itemID, mode: mode); status = "Refresh started. Pull to reload in a moment." }
            catch { self.error = adminMessage(error) }
            busy = false
        }
    }
}

private struct IdentifyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: MetadataDraft
    let onApply: () -> Void
    @State private var name = ""
    @State private var year = ""
    @State private var results: [RemoteSearchResult] = []
    @State private var searched = false
    @State private var busy = false
    @State private var replaceImages = true
    @State private var error: String?
    @State private var choice: RemoteSearchResult?

    var body: some View {
        Form {
            AdminErrorRow(message: error)
            Section {
                TextField("Title", text: $name)
                TextField("Year", text: $year).keyboardType(.numberPad)
                Toggle("Replace existing images", isOn: $replaceImages)
                Button("Search") { search() }.disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if busy && results.isEmpty { ProgressView() }
            if !results.isEmpty {
                Section("Results") {
                    ForEach(results) { result in
                        Button { choice = result } label: { resultRow(result) }.disabled(busy)
                    }
                }
            } else if searched && !busy {
                Text("No matches").foregroundStyle(Theme.muted)
            }
        }
        .modifier(AdminFormStyle(title: "Identify"))
        .onAppear {
            if name.isEmpty { name = draft.name; year = draft.year }
        }
        .confirmationDialog("Use this match?", isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }),
                            titleVisibility: .visible, presenting: choice) { result in
            Button("Use \(result.name ?? "match")") { apply(result) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("The server downloads new details for this title and replaces fields that aren’t locked.") }
    }

    private func resultRow(_ result: RemoteSearchResult) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: result.imageUrl.flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil }) { image in
                image.resizable().scaledToFill()
            } placeholder: { Theme.panel }
                .frame(width: 40, height: 60).clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.name ?? "Untitled").foregroundStyle(Theme.text)
                Text([result.productionYear.map(String.init), result.searchProviderName].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
    }
    private func search() {
        guard let client = model.client, !busy else { return }
        busy = true; error = nil; results = []
        let (title, releaseYear, item) = (name, year, draft)
        Task {
            do { results = try await client.remoteSearch(item, name: title, year: releaseYear) } catch { self.error = adminMessage(error) }
            searched = true; busy = false
        }
    }
    private func apply(_ result: RemoteSearchResult) {
        guard let client = model.client, !busy else { return }
        busy = true; error = nil
        let (itemID, replace) = (draft.id, replaceImages)
        Task {
            do { try await client.applyRemoteResult(result, itemID: itemID, replaceImages: replace); onApply(); dismiss() }
            catch { self.error = adminMessage(error) }
            busy = false
        }
    }
}

#endif
