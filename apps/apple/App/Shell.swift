import SwiftUI
import ZorofinCore
#if os(iOS)
import PhotosUI
import ImageIO
#endif

enum Destination: String, CaseIterable, Identifiable {
    case home = "Home", movies = "Movies", shows = "TV Shows", live = "Live TV"
    case search = "Search", requests = "Requests", profile = "Profile"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "house.fill"
        case .movies: "film"
        case .shows: "tv"
        case .live: "dot.radiowaves.left.and.right"
        case .search: "magnifyingglass"
        case .requests: "plus.rectangle.on.rectangle"
        case .profile: "person.crop.circle"
        }
    }
}

struct ZorofinShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.adaptiveWindow) private var window
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeReduceMotion) private var appReduceMotion
    @Namespace private var navigationSelection
    @State private var destination = Destination.home
    @State private var dockHeight: CGFloat = 66
    @State private var path: [MediaItem] = []
    @State private var player: PlaybackPresentation?
    @State private var pendingPlayback: PlaybackPresentation?
    @State private var reviewOpportunity = 0
    @State private var pendingLivePlayback: PlaybackPresentation?
    @State private var liveTVConflict: LiveTVConflictAlert?
    #if os(tvOS)
    @State private var profileDestination: ProfileDestination?
    @State private var settingsReturnDestination: Destination?
    @FocusState private var profileButtonFocused: Bool
    #endif
    @State private var showServers = false
    #if os(iOS)
    @State private var showOfflineDownloads = false
    #endif
    @State private var showProfileMenu = false
    @State private var profileMenuAction: AccountMenuAction?
    @State private var utility: HomeUtility?
    @State private var showNotifications = false
    @FocusState private var notificationBellFocused: Bool
    private var wide: Bool { Theme.isTV || window.usesWideContent }
    private var tablet: Bool { !Theme.isTV && window.usesTabletLayout }
    private var reducedMotion: Bool { reduceMotion || appReduceMotion }
    private var phoneDestination: Destination {
        switch destination {
        case .movies, .shows, .live: .home
        default: destination
        }
    }
    private var screenTransition: AnyTransition {
        reducedMotion ? .identity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: Theme.isTV ? 12 : 8)),
            removal: .opacity)
    }
    private var shellContent: some View {
        VStack(spacing: 0) {
            if Theme.isTV { wideHeader }
            if !Theme.isTV && !path.isEmpty { detailHeader }
            NavigationStack(path: $path) {
                ZStack {
                    root
                        .environment(\.navigationDockClearance, Theme.isTV ? 0 : dockHeight)
                        .id(destination)
                        .transition(screenTransition)
                }
                    #if os(tvOS)
                    .ignoresSafeArea(.container, edges: .horizontal)
                    #endif
                    .animation(reducedMotion ? nil : NavigationMotion.screen, value: destination)
                    .navigationDestination(for: MediaItem.self) { item in
                        DetailView(item: item, wide: wide, play: play)
                            #if os(tvOS)
                            .ignoresSafeArea(.container, edges: .horizontal)
                            #endif
                            .modifier(HideNavigationBar())
                    }
                    .modifier(HideNavigationBar())
            }
        }
        .foregroundStyle(Theme.text).background(Theme.background)
        #if os(tvOS)
        .disabled(showNotifications || showProfileMenu).accessibilityHidden(showNotifications || showProfileMenu)
        .overlayPreferenceValue(NotificationBellAnchorKey.self) { anchor in
            if showNotifications, let anchor {
                TVNotificationPopover(anchor: anchor, close: closeNotifications, open: { item in
                    closeNotifications(); path.append(item)
                }).id(model.generation)
            }
        }
        .overlayPreferenceValue(ProfileButtonAnchorKey.self) { anchor in
            if showProfileMenu, let anchor {
                TVProfilePopover(anchor: anchor, close: closeProfileMenu,
                    open: { selected in closeProfileMenu(); profileDestination = selected },
                    settings: {
                        closeProfileMenu()
                        if destination != .profile { settingsReturnDestination = destination }
                        select(.profile)
                    })
                    .id(model.generation)
            }
        }
        #endif
        #if os(tvOS)
        // Use one deliberate edge inset instead of stacking it with TV overscan.
        .ignoresSafeArea(.container, edges: .horizontal)
        // The persistent TV header sits outside NavigationStack. Handle Back there
        // as well, so focusing a tab does not exit while a title is still open.
        .onExitCommand(perform: tvNavigationBack)
        #endif
        .onAppear {
            #if DEBUG
            if model.isDemo && ProcessInfo.processInfo.arguments.contains("--profile-preview") { select(.profile) }
            if model.isDemo && ProcessInfo.processInfo.arguments.contains("--requests-preview") { select(.requests) }
            #endif
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !Theme.isTV {
                VStack(spacing: 6) {
                    #if os(iOS)
                    if !DownloadManager.shared.isOnline && !model.isDemo && !showOfflineDownloads { offlineBanner }
                    #endif
                    phoneDock
                }.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { dockHeight = $0 }
            }
        }
        #if os(tvOS)
        .fullScreenCover(isPresented: $showServers) { SavedServersView() }
        .fullScreenCover(item: $profileDestination) { selected in
            ProfileDestinationContent(selected: selected).id(model.generation)
        }
        #else
        .sheet(isPresented: $showServers) { SavedServersView() }
        #endif
        .sheet(item: $utility) { HomeUtilityView(utility: $0).id(model.generation) }
        #if os(iOS)
        .sheet(isPresented: $showProfileMenu, onDismiss: {
            let action = profileMenuAction; profileMenuAction = nil
            switch action {
            case .accounts: showServers = true
            case .settings: select(.profile)
            case nil: break
            }
        }) {
            AccountMenuView(name: model.viewerName) { action in
                profileMenuAction = action; showProfileMenu = false
            }
        }
        #endif
        #if os(iOS)
        .sheet(isPresented: $showOfflineDownloads) { DownloadsView().id(model.generation) }
        #endif
        .fullScreenCover(item: $player, onDismiss: { reviewOpportunity += 1 }) { presentation in
            NativePlayerView(presentation: presentation, onClose: { player = nil })
        }
        .modifier(AppRatingPrompt(opportunity: reviewOpportunity,
            isClear: player == nil && pendingPlayback == nil && !showServers && !showProfileMenu && utility == nil && !showNotifications))
    }

    private var playbackContent: some View {
        shellContent
        .overlay(alignment: .bottom) {
            if let request = pendingPlayback, request.item.isSeries || request.item.type == "Season" {
                ProgressView("Finding an episode…")
                    .padding(24).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
                    .padding(Theme.gutter).accessibilityIdentifier("playback-selection-loading")
            }
        }
        .task(id: pendingPlayback?.id) {
            guard let request = pendingPlayback, let client = model.client, scenePhase == .active else { return }
            let generation = model.generation
            defer { if pendingPlayback?.id == request.id { pendingPlayback = nil } }
            do {
                let selected = try await client.playbackSelection(for: request.item, options: request.options)
                guard !Task.isCancelled, generation == model.generation, scenePhase == .active,
                      pendingPlayback?.id == request.id else { return }
                if model.watchTogether.isJoined {
                    if selected.item.isLive { model.message = "Leave your group from Profile to watch Live TV."; return }
                    await model.watchTogether.selectForPlayback(selected.item, options: selected.options)
                } else { presentPlayback(PlaybackPresentation(item: selected.item, options: selected.options)) }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, generation == model.generation, pendingPlayback?.id == request.id else { return }
                model.message = error.localizedDescription
            }
        }
        .onChange(of: model.generation) { _, _ in pendingPlayback = nil; player = nil }
        .onChange(of: scenePhase) { _, phase in if phase != .active { pendingPlayback = nil } }
        .onChange(of: path) { _, _ in pendingPlayback = nil }
        .onChange(of: destination) { _, _ in pendingPlayback = nil }
    }

    private var platformContent: some View {
        playbackContent
        .overlay(alignment: .bottom) {
            if pendingLivePlayback != nil {
                ProgressView("Checking Live TV availability…")
                    .font(Theme.font(Theme.isTV ? 22 : 16)).padding(24).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
                    .padding(Theme.gutter).accessibilityIdentifier("tv-live-capacity-checking")
            }
        }
        .alert(liveTVConflict?.title ?? "Live TV is in use",
               isPresented: Binding(get: { liveTVConflict != nil }, set: { if !$0 { liveTVConflict = nil } }),
               presenting: liveTVConflict) { conflict in
            if let join = conflict.join {
                Button("Watch \(join.name)") {
                    liveTVConflict = nil
                    presentPlayback(PlaybackPresentation(item: join, options: .init(subtitleIndex: -2)))
                }
                Button("Not now", role: .cancel) { liveTVConflict = nil }
            } else {
                Button("OK", role: .cancel) { liveTVConflict = nil }
            }
        } message: { conflict in Text(conflict.message) }
        .task(id: pendingLivePlayback?.id) {
            guard let request = pendingLivePlayback, let client = model.client, scenePhase == .active else { return }
            let generation = model.generation
            if !model.featuresChecked { await model.checkFeatures() }
            do {
                try await client.checkLiveTVCapacity(channelID: request.item.id, features: model.features)
                guard !Task.isCancelled, generation == model.generation, scenePhase == .active,
                      pendingLivePlayback?.id == request.id else { return }
                player = request; pendingLivePlayback = nil
            } catch let conflict as LiveTVStreamsConflict {
                guard !Task.isCancelled, generation == model.generation, pendingLivePlayback?.id == request.id else { return }
                liveTVConflict = LiveTVConflictAlert(conflict.blocked); pendingLivePlayback = nil
            } catch let conflict as LiveTVCapacityError {
                guard !Task.isCancelled, generation == model.generation, pendingLivePlayback?.id == request.id else { return }
                liveTVConflict = LiveTVConflictAlert(message: conflict.localizedDescription); pendingLivePlayback = nil
            } catch { if pendingLivePlayback?.id == request.id { pendingLivePlayback = nil } }
        }
        .onChange(of: model.generation) { _, _ in pendingLivePlayback = nil; liveTVConflict = nil }
        .onChange(of: scenePhase) { _, phase in if phase != .active { pendingLivePlayback = nil; liveTVConflict = nil } }
        .onChange(of: path) { _, _ in pendingLivePlayback = nil }
        .onChange(of: destination) { _, _ in pendingLivePlayback = nil }
    }

    var body: some View {
        platformContent
        .task(id: "\(model.generation)-\(scenePhase == .active)") {
            if scenePhase == .active { await model.runExtensionUpdates() }
        }
        #if os(tvOS)
        .task(id: "shelf-\(model.pendingTopShelfLink?.url.absoluteString ?? "")-\(player != nil)") {
            await openPendingTopShelfLink()
        }
        #endif
        .onChange(of: model.hasNotifications) { _, available in if !available { showNotifications = false } }
        .onChange(of: model.generation) { _, _ in
            showNotifications = false; showProfileMenu = false
            #if os(tvOS)
            profileDestination = nil
            settingsReturnDestination = nil
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { showNotifications = false; showProfileMenu = false }
        }
        .onChange(of: model.watchTogether.browseRequested) { _, browse in
            if browse { model.watchTogether.browseRequested = false; select(.home) }
        }
        .onChange(of: model.watchTogether.playbackRequest?.id) { _, _ in
            guard player == nil, let request = model.watchTogether.playbackRequest else { return }
            player = PlaybackPresentation(item: request.item, options: request.options)
            model.watchTogether.playbackRequest = nil
        }
        .onChange(of: model.extensionEnabled) { _, enabled in
            if !enabled && destination == .requests { select(.home) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isDemo {
                Text("APP PREVIEW · FICTIONAL LIBRARY")
                    .font(Theme.font(Theme.isTV ? 14 : 10, weight: .semibold)).tracking(1.3)
                    .foregroundStyle(Theme.jade).frame(maxWidth: .infinity).padding(.vertical, 5).background(Theme.panel)
            }
        }
    }
    @ViewBuilder private var root: some View {
        switch destination {
        case .home: HomeView(wide: wide, select: select, open: { path.append($0) }, play: play)
        case .movies: CatalogView(title: "Movies", kind: "Movie", wide: wide, back: { select(.home) })
        case .shows: CatalogView(title: "TV Shows", kind: "Series", wide: wide, back: { select(.home) })
        case .live: LiveGuideView(back: { select(.home) }, play: play)
        case .search: SearchView(wide: wide, openRequests: { select(.requests) })
        case .requests: RequestsView(wide: wide, open: { path.append($0) })
        case .profile: ProfileView()
        }
    }
    private func select(_ value: Destination) {
        path = []
        #if os(tvOS)
        if value != .profile { settingsReturnDestination = nil }
        #endif
        // Retapping a tab still returns to its root, without replacing the root view.
        guard destination != value else { return }
        destination = value
    }
    private func play(_ item: MediaItem, _ options: PlaybackOptions = .init(subtitleIndex: -2)) {
        if model.isDemo {
            model.message = "This preview contains fictional titles. Connect your server to watch your library."
        } else {
            var configured = options
            configured.bitrate = model.bitrate
            if item.isSeries || item.type == "Season" {
                pendingPlayback = PlaybackPresentation(item: item, options: configured)
            } else {
                // Keep direct media synchronous, including Top Shelf navigation + Play.
                pendingPlayback = nil
                guard item.isPlayableVideo else { model.message = PlaybackSelectionError.unsupportedItem.localizedDescription; return }
                if model.watchTogether.isJoined {
                    if item.isLive { model.message = "Leave your group from Profile to watch Live TV."; return }
                    Task { await model.watchTogether.selectForPlayback(item, options: configured) }
                } else { presentPlayback(PlaybackPresentation(item: item, options: configured)) }
            }
        }
    }
    #if os(tvOS)
    // Keep Top Shelf's async routing outside the large SwiftUI body expression.
    private func openPendingTopShelfLink() async {
        guard let link = model.pendingTopShelfLink else { return }
        if player != nil { player = nil; return }
        let expected = model.generation
        guard let account = model.connections.activeAccount, account.id == link.accountID,
              model.isCurrent(account), account.session?.token == model.session?.token,
              let client = model.client else {
            model.pendingTopShelfLink = nil
            model.message = "This preview belongs to another account. Choose that account to open its library."
            return
        }
        do {
            let item = try await client.item(link.itemID, fresh: true)
            guard !Task.isCancelled, expected == model.generation, model.pendingTopShelfLink == link else { return }
            showProfileMenu = false; showServers = false; utility = nil; showNotifications = false
            select(.home); path = [item]
            if link.action == .play && (item.type == "Movie" || item.isEpisode) {
                play(item, .init(startTicks: item.resumeTicks, subtitleIndex: -2))
            }
            model.pendingTopShelfLink = nil
        } catch {
            guard !Task.isCancelled, expected == model.generation else { return }
            model.pendingTopShelfLink = nil
            model.message = "This title could not be opened. Check your connection or choose another title."
        }
    }
    #endif
    private func presentPlayback(_ presentation: PlaybackPresentation) {
        #if os(iOS)
        // A downloaded copy always plays from the device, online or not. Use the
        // server's resume point unless offline progress has not reached it yet.
        if let record = DownloadManager.shared.playableRecord(itemID: presentation.item.id) {
            let current = DownloadManager.shared.isOnline && !record.pendingSync
            OfflinePlayback.present(record, startTicks: current ? presentation.options.startTicks : record.resumeTicks,
                                    watchTogether: false) { model.message = $0 }
            return
        }
        #endif
        // Apple TV always checks Live TV capacity first; iPhone and iPad check when
        // the server's companion reports which channels are in use.
        if presentation.item.isLive && (Theme.isTV || model.features.liveTvStreams) { pendingLivePlayback = presentation }
        else { player = presentation }
    }
    private var detailHeader: some View {
        HStack {
            Button { if !path.isEmpty { path.removeLast() } } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(Theme.font(17, weight: .semibold))
                    .frame(minWidth: Theme.target, minHeight: Theme.target)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("detail-back")
            Spacer()
        }.padding(.horizontal, Theme.gutter).background(Theme.background)
    }
    private func closeNotifications() {
        showNotifications = false
        notificationBellFocused = true
    }
    #if os(tvOS)
    private var tvNavigationBack: (() -> Void)? {
        if showProfileMenu { return closeProfileMenu }
        if showNotifications { return closeNotifications }
        if !path.isEmpty { return { path.removeLast() } }
        if destination == .profile, let previous = settingsReturnDestination {
            return { select(previous); settingsReturnDestination = nil; profileButtonFocused = true }
        }
        return nil
    }
    private func closeProfileMenu() {
        showProfileMenu = false
        profileButtonFocused = true
    }
    #endif
    private var wideHeader: some View {
        HStack(spacing: 18) {
            Brand(symbolOnly: true).padding(.trailing, 12)
            ForEach([Destination.home, .movies, .shows, .live] + (model.extensionEnabled ? [.requests] : [])) { value in
                Button { select(value) } label: {
                    Text(value.rawValue).font(Theme.font(22, weight: .semibold))
                        .foregroundStyle(destination == value ? Theme.background : Theme.muted)
                        .padding(.horizontal, 20).frame(minHeight: 60)
                        .background {
                            selectionPill(selected: destination == value, id: "tv-tab", color: Theme.text)
                        }
                }.buttonStyle(NavigationButtonStyle())
                    .accessibilityAddTraits(destination == value ? .isSelected : [])
                    .accessibilityIdentifier("nav-\(value.id)")
            }
            Spacer(minLength: 12)
            Button { showProfileMenu = true } label: {
                ProfileAvatar(size: 48).frame(width: 64, height: 64)
            }.buttonStyle(NavigationButtonStyle()).accessibilityLabel("Account menu")
                .accessibilityIdentifier("tv-account-menu")
                #if os(tvOS)
                .focused($profileButtonFocused)
                .anchorPreference(key: ProfileButtonAnchorKey.self, value: .bounds) { $0 }
                #endif
            if model.features.support {
                Button { utility = .support } label: {
                    InterfaceIcon(name: "support", size: 26).frame(width: 60, height: 60)
                }.buttonStyle(NavigationButtonStyle()).accessibilityLabel("Support")
                    .accessibilityIdentifier("tv-support")
            }
            if model.hasNotifications {
                Button { showNotifications = true } label: {
                    Image(systemName: "bell").frame(width: 60, height: 60)
                        .overlay(alignment: .topTrailing) {
                            if model.preferences.showUnreadBadge && model.unreadNotificationCount > 0 {
                                Text(model.unreadNotificationCount > 99 ? "99+" : String(model.unreadNotificationCount))
                                    .font(Theme.font(14, weight: .bold)).foregroundStyle(Theme.background)
                                    .padding(5).background(Theme.jade, in: Capsule()).accessibilityHidden(true)
                            }
                        }
                }.buttonStyle(NavigationButtonStyle())
                    .accessibilityLabel("Notifications, \(model.unreadNotificationCount) unread updates")
                    .accessibilityIdentifier("tv-notifications")
                    .focused($notificationBellFocused)
                    .anchorPreference(key: NotificationBellAnchorKey.self, value: .bounds) { $0 }
            }
            Button { select(.search) } label: {
                Image(systemName: "magnifyingglass").frame(width: 60, height: 60)
            }.buttonStyle(NavigationButtonStyle()).accessibilityLabel("Search")
                .accessibilityAddTraits(destination == .search ? .isSelected : [])
                .accessibilityIdentifier("tv-search")
        }.font(.system(size: 24)).padding(.horizontal, Theme.gutter).padding(.vertical, 16)
            .background(Theme.background)
            .animation(reducedMotion ? nil : NavigationMotion.selection, value: destination)
    }
    private var phoneDock: some View {
        Group {
            if tablet {
                dockItems.padding(.horizontal, max(24, window.width * 0.16)).padding(.vertical, 8)
                    .background(Theme.background.opacity(0.97))
                    .overlay(alignment: .top) { Rectangle().fill(Theme.border.opacity(0.4)).frame(height: 1) }
            } else {
                dockItems.padding(5).frame(maxWidth: 340).background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Theme.muted.opacity(0.2), lineWidth: 1))
                    .padding(.horizontal, 28).padding(.bottom, 8)
            }
        }.animation(reducedMotion ? nil : NavigationMotion.selection, value: phoneDestination)
    }
    #if os(iOS)
    private var offlineBanner: some View {
        Button { showOfflineDownloads = true } label: {
            Label("You're offline. Watch your downloads", systemImage: "wifi.slash")
                .font(Theme.font(14, weight: .semibold)).foregroundStyle(Theme.text)
                .padding(.horizontal, 16).frame(minHeight: 40)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Theme.jade.opacity(0.5), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityIdentifier("offline-downloads-banner")
    }
    #endif
    private var dockItems: some View {
        HStack(spacing: 0) {
            ForEach([Destination.home, .search] + (model.extensionEnabled ? [.requests] : []) + [.profile]) { value in
                Button { select(value) } label: {
                    let layout = tablet && !textSize.isAccessibilitySize ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 4))
                    layout {
                        Group {
                            if value == .profile { Avatar(initial: model.initial, size: 24) }
                            else { Image(systemName: value.icon).font(.system(size: 19)).frame(height: 24) }
                        }
                        .scaleEffect(!reducedMotion && phoneDestination == value ? 1.10 : 1)
                        .offset(y: !reducedMotion && phoneDestination == value ? -1 : 0)
                        .animation(reducedMotion ? nil : NavigationMotion.icon, value: phoneDestination)
                        Text(value.rawValue).font(Theme.font(tablet ? 14 : 10, weight: .medium))
                    }
                    .foregroundStyle(phoneDestination == value ? Theme.text : Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: tablet ? 56 : 48)
                    .background {
                        selectionPill(selected: phoneDestination == value, id: "phone-tab", color: .white.opacity(0.11))
                    }
                }.buttonStyle(NavigationButtonStyle()).accessibilityLabel(value.rawValue)
                    .accessibilityAddTraits(phoneDestination == value ? .isSelected : [])
                    .accessibilityIdentifier("dock-\(value.id)")
            }
        }.accessibilityIdentifier(tablet ? "tablet-navigation" : "phone-navigation")
    }
    @ViewBuilder private func selectionPill(selected: Bool, id: String, color: Color) -> some View {
        if selected {
            if reducedMotion {
                Capsule().fill(color)
            } else {
                Capsule().fill(color)
                    .matchedGeometryEffect(id: id, in: navigationSelection)
                    .transition(.identity)
            }
        }
    }
}

#if os(tvOS)
private struct ProfileButtonAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

private struct TVProfilePopover: View {
    @Environment(AppModel.self) private var model
    let anchor: Anchor<CGRect>
    let close: () -> Void
    let open: (ProfileDestination) -> Void
    let settings: () -> Void
    @State private var switchingAccount: UUID?
    @State private var switchTask: Task<Void, Never>?
    @State private var error: String?
    @FocusState private var focusedAccount: UUID?

    var body: some View {
        GeometryReader { geometry in
            let button = geometry[anchor]
            let width = min(460.0, geometry.size.width - 48)
            let left = min(max(24, button.maxX - width + 16), geometry.size.width - width - 24)
            let top = button.maxY + 14
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.18).contentShape(Rectangle()).onTapGesture(perform: close)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        ProfileAvatar(size: 40)
                        Text(model.serverName.isEmpty ? "Accounts" : model.serverName)
                            .font(Theme.font(25, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        Button(action: close) {
                            Image(systemName: "xmark").frame(width: 48, height: 48)
                        }.buttonStyle(FlatOptionStyle()).accessibilityLabel("Close account menu")
                    }.padding(.horizontal, 20).padding(.vertical, 12).focusSection()
                    Divider().overlay(Theme.border)
                    ScrollView {
                        VStack(spacing: 4) {
                            if let error { Text(error).font(Theme.font(19)).foregroundStyle(.orange).padding(12) }
                            ForEach(model.connections.accounts) { account in accountRow(account) }
                            if model.connections.accounts.isEmpty {
                                Text("No saved accounts").font(Theme.font(20)).foregroundStyle(Theme.muted).padding(12)
                            }
                            Divider().overlay(Theme.border).padding(.vertical, 8)
                            row("Change server", "server.rack", .servers)
                            row("Quick Connect", "iphone.gen3.radiowaves.left.and.right", .quickConnect)
                            if model.isDemo || model.watchTogether.canJoin {
                                row("Watch together", "person.2.wave.2", .watchTogether)
                            }
                        }.padding(16)
                    }.frame(maxHeight: min(520, max(120, geometry.size.height - top - 190))).focusSection()
                    Divider().overlay(Theme.border)
                    Button(action: settings) { menuLabel("Settings", "gearshape") }
                        .buttonStyle(FlatOptionStyle()).padding(16).disabled(switchingAccount != nil)
                        .accessibilityIdentifier("account-menu-settings")
                }.frame(width: width).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.16), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
                    .offset(x: left, y: top)
            }
        }.foregroundStyle(Theme.text).preferredColorScheme(.dark)
            .accessibilityIdentifier("tv-profile-popover")
            .onExitCommand(perform: close)
            .onDisappear { switchTask?.cancel() }
            .task(id: model.generation) {
                await Task.yield()
                focusedAccount = model.connections.accounts.first(where: { model.isCurrent($0) })?.id
                    ?? model.connections.accounts.first?.id
                guard let client = model.client else { return }
                let generation = model.generation
                guard let viewer = try? await client.currentViewer(), !Task.isCancelled,
                      generation == model.generation, viewer.id == model.session?.viewer.id else { return }
                model.watchTogether.access = viewer.policy?.syncPlayAccess
            }
    }
    private func accountRow(_ account: SavedAccount) -> some View {
        let current = model.isCurrent(account)
        return Button { choose(account) } label: {
            HStack(spacing: 14) {
                SavedAccountAvatar(account: account, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.viewer.name).font(Theme.font(22, weight: current ? .semibold : .regular))
                    Text(account.session == nil ? "Sign in again" : account.serverName)
                        .font(Theme.font(17)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if switchingAccount == account.id { ProgressView() }
                else if current { Image(systemName: "checkmark").foregroundStyle(Theme.jade) }
            }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        }.buttonStyle(FlatOptionStyle()).disabled(switchingAccount != nil)
            .focused($focusedAccount, equals: account.id)
            .accessibilityIdentifier("account-menu-saved-" + account.id.uuidString)
            .accessibilityLabel(account.viewer.name + ", " + account.serverName)
            .accessibilityValue(current ? "Current account" : account.session == nil ? "Sign in again" : "")
            .accessibilityAddTraits(current ? .isSelected : [])
    }
    private func choose(_ account: SavedAccount) {
        guard switchingAccount == nil else { return }
        if model.isCurrent(account) { close(); return }
        guard account.session != nil else { open(.servers); return }
        error = nil; switchingAccount = account.id
        switchTask = Task { @MainActor in
            defer { switchingAccount = nil }
            do {
                try await model.switchAccount(account.id)
                if !Task.isCancelled { close() }
            } catch is CancellationError { }
            catch ClientError.unauthorized { if !Task.isCancelled { open(.servers) } }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func menuLabel(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon).font(Theme.font(22))
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(.horizontal, 12)
    }
    private func row(_ title: String, _ icon: String, _ destination: ProfileDestination) -> some View {
        Button { open(destination) } label: { menuLabel(title, icon) }
            .buttonStyle(FlatOptionStyle()).disabled(switchingAccount != nil)
            .accessibilityIdentifier("account-menu-" + destination.id)
    }
}
#endif

private enum AccountMenuAction { case accounts, settings }

private struct AccountMenuView: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let choose: (AccountMenuAction) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(name).font(Theme.font(30, weight: .semibold))
            Button { choose(.accounts) } label: {
                Label("Change account", systemImage: "person.2").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(ZoroButtonStyle()).accessibilityIdentifier("account-menu-switch")
            Button { choose(.settings) } label: {
                Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(ZoroButtonStyle()).accessibilityIdentifier("account-menu-settings")
            Button("Cancel") { dismiss() }.buttonStyle(ZoroButtonStyle())
        }.padding(Theme.isTV ? 44 : 24).frame(maxWidth: 560).background(Theme.background).foregroundStyle(Theme.text)
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
    }
}

struct HideNavigationBar: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar(.hidden, for: .navigationBar)
        #else
        content
        #endif
    }
}

private enum ProfileDestination: Identifiable {
    case dashboard, admin(AdministrationPage), settings(NativeSettingsPage), legal(PublicDocument), quickConnect, watchTogether, support, notifications, teams, servers
    var id: String {
        switch self {
        case .dashboard: "dashboard"
        case .admin(let page): "admin-" + page.rawValue
        case .servers: "servers"
        case .teams: "teams"
        case .quickConnect: "quick-connect"
        case .watchTogether: "watch-together"
        case .settings(let page): "settings-" + page.id
        case .legal(let page): "legal-" + page.id
        case .support: "support"
        case .notifications: "notifications"
        }
    }
}

private struct ProfileDestinationContent: View {
    @Environment(AppModel.self) private var model
    let selected: ProfileDestination
    var body: some View {
        Group {
            switch selected {
            case .servers: SavedServersView()
            case .dashboard: DashboardDestination()
            case .admin(let page): AdministrationDestination(page: page)
            case .teams: YourTeamsView()
            case .quickConnect: ProfileQuickConnectView()
            case .watchTogether: WatchTogetherView()
            case .settings(let page): NativeSettingsView(page: page)
            case .legal(let page): PublicInformationView(page: page)
            case .support: HomeUtilityView(utility: .support)
            case .notifications: HomeUtilityView(utility: .notifications)
            }
        }.id(model.generation)
    }
}

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.adaptiveWindow) private var window
    @State private var signingOut = false
    @State private var destination: ProfileDestination?
    @State private var administrator = false
    @State private var showWatchTogether = false
    #if os(iOS)
    @State private var showDownloads = false
    #endif
    #if os(iOS)
    @State private var showDashboard = false
    #endif
    private var wide: Bool { Theme.isTV || window.usesWideContent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) {
                    ProfileAvatar(size: 64)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.viewerName).font(Theme.font(Theme.isTV ? 36 : 28, weight: .bold, relativeTo: .title))
                            .accessibilityAddTraits(.isHeader)
                        if !model.serverName.isEmpty {
                            Text(model.serverName).font(Theme.font(Theme.isTV ? 22 : 16)).foregroundStyle(Theme.muted)
                        }
                    }
                }.padding(.horizontal, 6)

                VStack(spacing: wide ? 8 : 0) {
                    row("Change account", icon: "person.2", destination: .servers)
                    row("Account", icon: "person.fill", destination: .settings(.account))
                    row("Quick Connect", icon: "iphone.gen3.radiowaves.left.and.right", destination: .quickConnect)
                    if model.isDemo || model.watchTogether.canJoin {
                        row("Watch together", icon: "person.2", destination: .watchTogether,
                            subtitle: model.watchTogether.group?.groupName,
                            action: {
                                #if os(tvOS)
                                destination = .watchTogether
                                #else
                                showWatchTogether = true
                                #endif
                            })
                            .accessibilityIdentifier("profile-watch-together")
                    }
                    row("Display", icon: "display", destination: .settings(.display))
                    row("Your teams", icon: "sportscourt", destination: .teams)
                    row("Playback", icon: "play.circle.fill", destination: .settings(.playback))
                    row("Subtitles", icon: "captions.bubble.fill", destination: .settings(.subtitles))
                    row("Controls", icon: "gamecontroller", destination: .settings(.controls))
                    #if os(iOS)
                    row("Downloads", icon: "arrow.down.circle", destination: .settings(.storage),
                        subtitle: downloadsSummary, action: { showDownloads = true })
                        .accessibilityIdentifier("profile-downloads")
                    #endif
                    row("Storage & app", icon: "internaldrive", destination: .settings(.storage))
                }

                if administrator {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Administration").font(Theme.font(Theme.isTV ? 28 : 20, weight: .bold, relativeTo: .headline))
                            .padding(.horizontal, 6).accessibilityAddTraits(.isHeader)
                        VStack(spacing: wide ? 8 : 0) { dashboardRow; adminRow(.metadata) }
                    }
                }

                VStack(spacing: wide ? 8 : 0) {
                    if administrator && model.features.accountApprovals { adminRow(.accountApprovals, utility: true) }
                    if model.features.support { row("Support", icon: "support", destination: .support, utility: true) }
                    if model.features.notificationSettings || model.hasNotifications || model.isDemo {
                        row("Notification settings", icon: "slider.horizontal.3", destination: .settings(.notifications), utility: true)
                    }
                    if model.hasNotifications { row("Notifications", icon: "bell.fill", destination: .notifications, utility: true) }
                    row("Privacy Policy", icon: "hand.raised", destination: .legal(.privacy), utility: true)
                    row("App Support", icon: "questionmark.circle", destination: .legal(.support), utility: true)
                    row("Rate Zorofin", icon: "star", destination: .legal(.support), utility: true, action: {
                        openURL(AppRating.url) { opened in
                            if !opened { model.message = "The App Store could not open. Please try again later." }
                        }
                    }).accessibilityIdentifier("profile-rate-app")
                }

                Button {
                    signingOut = true
                    Task { await model.signOut(); signingOut = false }
                } label: {
                    Label(model.isDemo ? "Leave preview" : "Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(ZoroButtonStyle()).disabled(signingOut).accessibilityIdentifier("profile-sign-out")
            }.frame(maxWidth: Theme.isTV ? 920 : 720, alignment: .leading)
                .padding(.horizontal, Theme.isTV ? Theme.gutter : 28)
                .frame(maxWidth: .infinity, alignment: Theme.isTV ? .leading : .center)
                .padding(.top, Theme.isTV ? 24 : 20).padding(.bottom, 40)
                #if os(tvOS)
                // The full-width section bridges the right-side profile icon to
                // the left-aligned settings rows when the remote moves down.
                .focusSection()
                #endif
        }.background(Theme.background)
        .navigationDestination(isPresented: $showWatchTogether) { WatchTogetherView().id(model.generation) }
        #if os(iOS)
        .navigationDestination(isPresented: $showDownloads) { DownloadsView().id(model.generation) }
        #endif
        #if os(tvOS)
        .fullScreenCover(item: $destination) { destinationView($0) }
        #else
        .sheet(item: $destination) { destinationView($0) }
        .fullScreenCover(isPresented: $showDashboard) { DashboardWebView().id(model.generation) }
        .onChange(of: model.generation) { _, _ in showDashboard = false; destination = nil }
        #endif
        .task(id: model.generation) {
            administrator = false
            #if DEBUG
            if model.isDemo, let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--settings-preview"),
               ProcessInfo.processInfo.arguments.indices.contains(index + 1),
               let page = NativeSettingsPage(rawValue: ProcessInfo.processInfo.arguments[index + 1]) {
                destination = .settings(page)
            }
            #endif
            #if DEBUG
            if model.isDemo && ProcessInfo.processInfo.arguments.contains("--profile-admin-preview") {
                administrator = true; return
            }
            #endif
            guard let client = model.client else { return }
            let generation = model.generation
            do {
                let viewer = try await client.currentViewer()
                guard !Task.isCancelled, generation == model.generation,
                      viewer.id == model.session?.viewer.id else { return }
                administrator = viewer.policy?.isAdministrator == true
                model.watchTogether.access = viewer.policy?.syncPlayAccess
            } catch { /* Keep administrative actions hidden without current permission evidence. */ }
        }
    }

    private func destinationView(_ selected: ProfileDestination) -> some View {
        ProfileDestinationContent(selected: selected)
    }

    @ViewBuilder private var dashboardRow: some View {
        #if os(iOS)
        row("Dashboard", icon: "square.grid.2x2.fill", destination: .dashboard,
            action: { showDashboard = true })
        #else
        row("Dashboard", icon: "square.grid.2x2.fill", destination: .dashboard)
        #endif
    }
    private func adminRow(_ page: AdministrationPage, utility: Bool = false) -> some View {
        row(page.title, icon: page.icon, destination: .admin(page), utility: utility)
    }
    #if os(iOS)
    private var downloadsSummary: String? {
        let records = DownloadManager.shared.records
        guard !records.isEmpty else { return nil }
        let active = records.filter { $0.status.isActive }.count
        if active > 0 { return active == 1 ? "1 downloading" : "\(active) downloading" }
        return (records.count == 1 ? "1 title" : "\(records.count) titles") + " · " + DownloadFormat.bytes(DownloadManager.shared.usedBytes)
    }
    #endif
    private func row(_ title: String, icon: String, destination: ProfileDestination, utility: Bool = false, subtitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        Button { if let action { action() } else { self.destination = destination } } label: {
            HStack(spacing: 26) {
                InterfaceIcon(name: icon, size: Theme.isTV ? 26 : 18)
                    .foregroundStyle(utility ? Theme.text : Color(hex: 0x9bd3ad)).frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.font(Theme.isTV ? 24 : 15)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle { Text(subtitle).font(Theme.font(Theme.isTV ? 20 : 13)).foregroundStyle(Theme.muted) }
                }
                Spacer(minLength: 8)
                if utility { Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.muted).accessibilityHidden(true) }
            }.padding(.horizontal, wide ? 20 : 4).padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: Theme.isTV ? 66 : wide ? 58 : 53, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(ProfileRowStyle(wide: wide)).accessibilityIdentifier("profile-\(destination.id)")
    }
}

private struct ProfileRowStyle: ButtonStyle {
    let wide: Bool
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(wide ? Theme.panel : configuration.isPressed ? Color.white.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: wide ? 14 : 0))
            .overlay {
                if wide || focused {
                    RoundedRectangle(cornerRadius: wide ? 14 : 4)
                        .stroke(focused ? Theme.jade : Theme.border, lineWidth: focused ? 3 : 1)
                }
            }
            .overlay(alignment: .bottom) { if !wide { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) } }
    }
}

/// Dashboard keeps the server's complete administration UI on iPhone and iPad.
private struct DashboardDestination: View {
    var body: some View {
        #if os(iOS)
        DashboardWebView()
        #else
        AdministrationOnPhoneView(title: "Dashboard")
        #endif
    }
}

/// Metadata and approvals are native; Apple TV directs administrators to the phone.
private struct AdministrationDestination: View {
    let page: AdministrationPage
    var body: some View {
        #if os(iOS)
        AdministrationView(page: page)
        #else
        AdministrationOnPhoneView(title: page.title)
        #endif
    }
}

#if os(tvOS)
private struct AdministrationOnPhoneView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title).font(Theme.font(32, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text("Open Profile, then \(title), in Zorofin on your iPhone or iPad.")
                .font(Theme.font(24)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Button("Done") { dismiss() }.buttonStyle(ZoroButtonStyle(primary: true))
        }.padding(Theme.gutter).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.background).foregroundStyle(Theme.text)
    }
}
#endif

private struct ProfileQuickConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var code = ""
    @State private var busy = false
    @State private var status: String?
    @State private var operation: Task<Void, Never>?
    private var valid: Bool { code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Sign in another device").font(Theme.font(24, weight: .bold))
                    Text("Enter the Quick Connect code shown on your other device. Authorizing it signs that device into \(model.viewerName)’s account.")
                        .foregroundStyle(Theme.muted)
                    TextField("Six-digit code", text: $code).modifier(ServerFieldInput())
                        .accessibilityLabel("Quick Connect code").disabled(busy)
                    Button {
                        guard valid, !busy, let client = model.client else { return }
                        let generation = model.generation, submittedCode = code
                        busy = true; status = nil
                        operation = Task {
                            defer { busy = false }
                            do {
                                let accepted = try await client.authorizeQuickConnect(code: submittedCode)
                                guard !Task.isCancelled, generation == model.generation else { return }
                                status = accepted ? "Device authorized. You can continue on your other device." : "That code could not be authorized. Check the code on your other device."
                                if accepted { code = "" }
                            } catch {
                                guard !Task.isCancelled, generation == model.generation else { return }
                                status = "Authorization could not be confirmed. Check your other device before trying again."
                            }
                        }
                    } label: {
                        HStack { if busy { ProgressView() }; Text("Authorize") }.frame(maxWidth: .infinity)
                    }.buttonStyle(ZoroButtonStyle(primary: true)).disabled(!valid || busy || model.isDemo)
                    if let status { Text(status).foregroundStyle(Theme.muted) }
                    if model.isDemo { Text("Connect your server to authorize another device.").foregroundStyle(Theme.muted) }
                }.padding(28).frame(maxWidth: 720).frame(maxWidth: .infinity)
            }.foregroundStyle(Theme.text).background(Theme.background).navigationTitle("Quick Connect")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(Theme.jade).preferredColorScheme(.dark)
            .onDisappear { operation?.cancel(); code = "" }
            .onChange(of: scenePhase) { _, phase in if phase != .active { operation?.cancel(); code = "" } }
    }
}

private enum NativeSettingsPage: String, Identifiable {
    case account = "Account", display = "Display", playback = "Playback", subtitles = "Subtitles"
    case controls = "Controls", notifications = "Notification settings", storage = "Storage & app"
    var id: String { rawValue }
    var usesAccount: Bool { [.account,.playback,.subtitles].contains(self) }
}

private struct ProfileAvatar: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat = 64
    var body: some View {
        Group {
            if let image = model.profileImage { Image(uiImage: image).resizable().scaledToFill() }
            else { Text(model.initial).font(Theme.font(size / 2, weight: .bold)).foregroundStyle(Theme.text) }
        }.frame(width: size, height: size).background(Theme.avatar)
            .clipShape(RoundedRectangle(cornerRadius: size / 4)).accessibilityHidden(true)
    }
}

private struct NativeSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let page: NativeSettingsPage
    @State private var draft = NativePreferences()
    @State private var baseline: ViewerSettings?
    @State private var configuration: [String: JSONValue] = [:]
    @State private var languages: [SettingsLanguage] = []
    @State private var ready = false
    @State private var loadingAccount = false
    @State private var busy = false
    @State private var status: String?
    @State private var error: String?
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmationPassword = ""
    @State private var email = ""
    @State private var alertSettings: RequestAlertSettings?
    @State private var cacheBytes: Int64 = 0
    @State private var confirmation: SettingsConfirmation?
    @State private var operation: Task<Void, Never>?
    @State private var pendingPhoto: Data?
    #if DEBUG
    @State private var showPlayerPreview = false
    @State private var showLivePlayerPreview = false
    @AppStorage("custom-player-preview-enabled") private var customPlayerPreviewEnabled = true
    #endif
    #if os(iOS)
    @State private var selectedPhoto: PhotosPickerItem?
    #endif

    private enum SettingsConfirmation: String, Identifiable {
        case discard = "Discard unsaved changes?", clearCache = "Clear this account’s cache?"
        case reset = "Reset app preferences?", removePhoto = "Remove profile photo?"
        case removeEmail = "Turn off email alerts?", removePush = "Turn off push alerts?", resetPush = "Replace push password?"
        var id: String { rawValue }
    }
    private var changes: [String: JSONValue] {
        guard let baseline else { return [:] }
        return configuration.filter { baseline.configuration[$0.key] != $0.value }
    }
    private var dirty: Bool {
        ready && (draft != model.preferences || !changes.isEmpty || pendingPhoto != nil ||
            !currentPassword.isEmpty || !newPassword.isEmpty || !confirmationPassword.isEmpty || !email.isEmpty)
    }
    private var canSave: Bool { ready && (draft != model.preferences || !changes.isEmpty) && !busy }
    private var canEditAccount: Bool { baseline?.canEdit == true && !busy && !loadingAccount }

    var body: some View {
        NavigationStack {
            Form {
                if !ready { ProgressView("Loading settings…") }
                else {
                    if model.isDemo { Text("Preview changes stay in this preview.").foregroundStyle(Theme.muted) }
                    if let error {
                        Section {
                            Text(error).foregroundStyle(.orange)
                            if page.usesAccount || page == .notifications {
                                Button("Reload from server") { run { await reloadServer(force: true) } }.disabled(busy)
                            }
                        }
                    }
                    if let status { Text(status).foregroundStyle(Theme.jade).accessibilityIdentifier("settings-status") }
                    switch page {
                    case .account: accountFields
                    case .display: displayFields
                    case .playback: playbackFields
                    case .subtitles: subtitleFields
                    case .controls: controlFields
                    case .notifications: notificationFields
                    case .storage: storageFields
                    }
                    if busy { ProgressView("Saving…") }
                }
            }
            .modifier(SettingsFormBackground()).background(Theme.background)
            #if os(tvOS)
            // Keep the title left aligned and actions reachable above the form.
            .safeAreaInset(edge: .top, spacing: 16) {
                HStack(spacing: 20) {
                    Text(page.rawValue).font(Theme.font(32, weight: .bold))
                        .foregroundStyle(Theme.text).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if canSave || busy {
                        Button("Save") { run { await save() } }.disabled(!canSave)
                            .buttonStyle(ZoroButtonStyle(primary: true))
                            .accessibilityIdentifier("settings-save")
                    }
                    Button("Done") { if dirty { confirmation = .discard } else { dismiss() } }
                        .buttonStyle(ZoroButtonStyle()).disabled(busy)
                }.padding(.horizontal, Theme.gutter).padding(.top, 24)
                    .background(Theme.background)
            }
            .toolbar(.hidden, for: .navigationBar)
            #else
            .navigationTitle(page.rawValue).modifier(SettingsNavigationStyle())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { if dirty { confirmation = .discard } else { dismiss() } }.disabled(busy)
                }
                if canSave || busy {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { run { await save() } }.disabled(!canSave)
                            .accessibilityIdentifier("settings-save")
                    }
                }
            }
            #endif
        }.tint(Theme.jade).preferredColorScheme(.dark)
            .interactiveDismissDisabled(dirty || busy)
            #if DEBUG
            .fullScreenCover(isPresented: $showPlayerPreview) { PlayerDesignPreview(canDismiss: true) }
            .fullScreenCover(isPresented: $showLivePlayerPreview) { PlayerDesignPreview(canDismiss: true, isLive: true) }
            #endif
            .task { await load() }
            .onDisappear { operation?.cancel(); clearSecrets() }
            .onChange(of: draft) { _, _ in status = nil }
            .onChange(of: scenePhase) { _, phase in if phase != .active { clearSecrets() } }
            .confirmationDialog(confirmation?.rawValue ?? "Confirm", isPresented: Binding(
                get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
                switch confirmation {
                case .discard: Button("Discard changes", role: .destructive) { clearSecrets(); dismiss() }
                case .clearCache: Button("Clear cache", role: .destructive) { run { await clearCache() } }
                case .reset: Button("Reset app preferences", role: .destructive) { draft = .init(); run { await save() } }
                case .removePhoto: Button("Remove photo", role: .destructive) { run { await savePhoto(nil) } }
                case .removeEmail: Button("Turn off email alerts", role: .destructive) { run { await alertAction(.removeEmail) } }
                case .removePush: Button("Turn off push alerts", role: .destructive) { run { await alertAction(.removePush) } }
                case .resetPush: Button("Replace password", role: .destructive) { run { await alertAction(.resetPush) } }
                case nil: EmptyView()
                }
                Button("Cancel", role: .cancel) { confirmation = nil }
            } message: {
                switch confirmation {
                case .clearCache: Text("Downloaded artwork and library data for this account will be removed. Your sign-in and server media are kept.")
                case .reset: Text("Only app preferences for this account on this device will reset. Server preferences and saved sign-ins are kept.")
                case .resetPush: Text("The previous push password will stop working. Save the new password when it appears.")
                default: EmptyView()
                }
            }
            #if os(iOS)
            .onChange(of: selectedPhoto) { _, selected in
                guard let selected else { return }
                operation?.cancel()
                let generation = model.generation
                operation = Task {
                    do {
                        guard let data = try await selected.loadTransferable(type: Data.self),
                              let source = CGImageSourceCreateWithData(data as CFData, nil),
                              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary),
                              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { throw SettingsError.invalidInput }
                        guard !Task.isCancelled, generation == model.generation else { return }
                        pendingPhoto = jpeg; status = nil; error = nil
                    } catch {
                        guard !Task.isCancelled, generation == model.generation else { return }
                        self.error = "That photo could not be opened. Choose another photo and try again."
                    }
                }
            }
            #endif
    }

    @ViewBuilder private var accountFields: some View {
        Section {
            HStack(spacing: 18) {
                if let pendingPhoto, let image = UIImage(data: pendingPhoto) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 18))
                } else { ProfileAvatar(size: 72) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(baseline?.name ?? model.viewerName).font(.title2.bold())
                    if !model.serverName.isEmpty { Text(model.serverName).foregroundStyle(Theme.muted) }
                }
            }.padding(.vertical, 8)
            if let server = model.session?.server { Text(server.url.absoluteString).font(.footnote).foregroundStyle(Theme.muted).modifier(SettingsSelectableText()) }
            #if os(iOS)
            PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("Choose profile photo", systemImage: "photo") }
                .disabled(!canEditAccount || model.isDemo)
            if let pendingPhoto { Button("Save photo") { run { await savePhoto(pendingPhoto) } }.disabled(!canEditAccount) }
            #endif
            if baseline?.hasImage == true { Button("Remove photo", role: .destructive) { confirmation = .removePhoto }.disabled(!canEditAccount) }
        }
        Section("Change password") {
            SecureField("Current password", text: $currentPassword).textContentType(.password).privacySensitive()
            SecureField("New password", text: $newPassword).textContentType(.newPassword).privacySensitive()
            SecureField("Confirm new password", text: $confirmationPassword).textContentType(.newPassword).privacySensitive()
            Button("Update password") { run { await changePassword() } }
                .disabled(!canEditAccount || model.isDemo || newPassword.isEmpty || newPassword != confirmationPassword || (baseline?.hasPassword == true && currentPassword.isEmpty))
            Text("Other devices may need to sign in again after you change your password.").font(.footnote).foregroundStyle(Theme.muted)
        }.disabled(!canEditAccount)
        accountStatus
    }
    private var displayFields: some View {
        Section("On this device") {
            SettingsPicker("Poster size", selection: $draft.posterScale) {
                Text("Compact").tag(0.85); Text("Comfortable").tag(1.0); Text("Large").tag(1.2)
            }
            Toggle("Show titles under posters", isOn: $draft.showTitles)
            Toggle("Show watching progress", isOn: $draft.showProgress)
            Toggle("Show ratings", isOn: $draft.showRatings)
            Toggle("Show quality badges", isOn: Binding(get: { draft.showQualityBadges != false }, set: { draft.showQualityBadges = $0 }))
            if model.extensionEnabled || model.isDemo {
                Toggle("Hide available titles in Requests", isOn: Binding(get: { draft.hideAvailableRequests == true }, set: { draft.hideAvailableRequests = $0 }))
                Text("Keep discovery and search focused on titles you can request. Partly available shows remain visible.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            #if os(tvOS)
            Toggle("Home Screen previews", isOn: Binding(get: { draft.homeScreenPreviews != false }, set: { draft.homeScreenPreviews = $0 }))
            Text("Show artwork and Continue Watching from this account on the Apple TV Home Screen.")
                .font(.footnote).foregroundStyle(Theme.muted)
            #endif
            Toggle("Reduce motion", isOn: $draft.reduceMotion)
            Text("Your device’s accessibility preferences are always respected.").font(.footnote).foregroundStyle(Theme.muted)
        }.disabled(busy)
    }
    @ViewBuilder private var playbackFields: some View {
        Section("On this device") {
            SettingsPicker("Streaming quality", selection: $draft.bitrate) {
                ForEach([2,4,8,12,20,40], id: \.self) { Text("\($0) Mbps").tag($0 * 1_000_000) }
            }
            SettingsPicker("Default speed", selection: $draft.playbackSpeed) {
                ForEach([0.5,0.75,1,1.25,1.5,2], id: \.self) { Text("\($0.formatted())×").tag($0) }
            }
            Text("Streaming quality is a maximum bitrate. Your server and connection determine the available quality.").font(.footnote).foregroundStyle(Theme.muted)
        }.disabled(busy)
        Section("Account defaults") {
            languagePicker("Preferred audio", key: "AudioLanguagePreference")
            Toggle("Prefer the original default audio track", isOn: bool("PlayDefaultAudioTrack", fallback: true))
            Toggle("Remember audio selections", isOn: bool("RememberAudioSelections", fallback: true))
            Toggle("Play the next episode automatically", isOn: bool("EnableNextEpisodeAutoPlay"))
        }.disabled(!canEditAccount)
        accountStatus
    }
    @ViewBuilder private var subtitleFields: some View {
        Section("Appearance on this device") {
            Toggle("Use system subtitle appearance", isOn: Binding(
                get: { draft.subtitleAppearance == nil },
                set: { draft.subtitleAppearance = $0 ? nil : .init() }))
            if let appearance = draft.subtitleAppearance {
                SettingsPicker("Text size", selection: subtitleStyle(\.size)) {
                    Text("Small").tag(80); Text("Medium").tag(100)
                    Text("Large").tag(125); Text("Extra large").tag(150)
                }
                SettingsPicker("Text color", selection: subtitleStyle(\.color)) {
                    Text("White").tag(SubtitleAppearance.TextColor.white)
                    Text("Yellow").tag(SubtitleAppearance.TextColor.yellow)
                }
                SettingsPicker("Background", selection: subtitleStyle(\.backgroundOpacity)) {
                    Text("None").tag(0.0); Text("Translucent").tag(0.65); Text("Black").tag(1.0)
                }
                Toggle("Bold text", isOn: subtitleStyle(\.bold))
                Text("Your next great watch.")
                    .font(.system(size: CGFloat(appearance.size) * (Theme.isTV ? 0.3 : 0.2), weight: appearance.bold ? .bold : .regular))
                    .foregroundStyle(appearance.color == .yellow ? Color.yellow : .white)
                    .padding(8).background(.black.opacity(appearance.backgroundOpacity), in: RoundedRectangle(cornerRadius: 4))
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .accessibilityLabel("Subtitle appearance preview")
            }
            Text("Applies to supported text subtitles. Image-based or burned-in subtitles keep their original appearance. System accessibility settings and embedded styling may take priority.")
                .font(.footnote).foregroundStyle(Theme.muted)
        }.disabled(busy)
        Section("Account defaults") {
            languagePicker("Preferred language", key: "SubtitleLanguagePreference")
            SettingsPicker("Subtitle mode", selection: string("SubtitleMode", fallback: "Default")) {
                Text("Default").tag("Default"); Text("Always").tag("Always"); Text("Smart").tag("Smart")
                Text("Forced only").tag("OnlyForced"); Text("Off").tag("None")
            }
            Toggle("Remember subtitle selections", isOn: bool("RememberSubtitleSelections", fallback: true))
            Text("Smart uses subtitles when the audio differs from your preferred subtitle language. Forced only shows required translations. A track chosen on a title overrides these defaults.")
                .font(.footnote).foregroundStyle(Theme.muted)
        }.disabled(!canEditAccount)
        accountStatus
    }
    private var controlFields: some View {
        Section("On this device") {
            SettingsPicker("Skip backward", selection: $draft.skipBack) {
                ForEach([5,10,15,30,60], id: \.self) { Text("\($0) seconds").tag($0) }
            }
            SettingsPicker("Skip forward", selection: $draft.skipForward) {
                ForEach([5,10,15,30,60], id: \.self) { Text("\($0) seconds").tag($0) }
            }
            Text("These intervals apply to the backward and forward buttons in the player.").font(.footnote).foregroundStyle(Theme.muted)
            #if os(iOS)
            Toggle("Picture in Picture", isOn: $draft.pictureInPicture)
            #endif
            Toggle("Pause when leaving the app", isOn: $draft.pauseInBackground)
            Text("Active Picture in Picture playback continues when you leave the app.").font(.footnote).foregroundStyle(Theme.muted)
        }.disabled(busy)
    }
    @ViewBuilder private var notificationFields: some View {
        Section("In the app") { Toggle("Show unread badge", isOn: $draft.showUnreadBadge).disabled(busy) }
        if let alerts = alertSettings {
            Section("Email alerts") {
                if alerts.email.enabled { LabeledContent("Current address", value: alerts.email.maskedAddress) }
                TextField("Email address", text: $email).modifier(SettingsEmailInput()).privacySensitive().disabled(busy)
                Button(alerts.email.enabled ? "Update email" : "Enable email alerts") { run { await alertAction(.saveEmail) } }
                    .disabled(busy || !email.contains("@") || model.isDemo)
                if alerts.email.enabled {
                    Button("Send test email") { run { await alertAction(.testEmail) } }.disabled(busy || model.isDemo)
                    Button("Turn off email alerts", role: .destructive) { confirmation = .removeEmail }.disabled(busy || model.isDemo)
                }
            }
            Section("Push through your server") {
                Text("These alerts use your server’s ntfy service. They are separate from the app’s inbox.").font(.footnote).foregroundStyle(Theme.muted)
                if alerts.push.enabled {
                    LabeledContent("Status", value: "Enabled")
                    if let topic = alerts.push.topic { LabeledContent("Topic", value: topic).modifier(SettingsSelectableText()).privacySensitive() }
                    Text(alerts.push.server).font(.footnote).modifier(SettingsSelectableText())
                    Button("Send test notification") { run { await alertAction(.testPush) } }.disabled(busy || model.isDemo)
                    Button("Replace push password") { confirmation = .resetPush }.disabled(busy || model.isDemo)
                    Button("Turn off push alerts", role: .destructive) { confirmation = .removePush }.disabled(busy || model.isDemo)
                } else { Button("Set up push alerts") { run { await alertAction(.createPush) } }.disabled(busy || model.isDemo) }
                if let credentials = alerts.credentials {
                    Text("Save these details in your ntfy app. The password is shown only now.").font(.footnote)
                    LabeledContent("Server", value: credentials.server)
                    LabeledContent("Topic", value: credentials.topic)
                    LabeledContent("Username", value: credentials.username)
                    LabeledContent("Password", value: credentials.password).modifier(SettingsSelectableText()).privacySensitive()
                }
            }
        } else if loadingAccount { ProgressView("Loading notification settings…") }
        else if !model.features.notificationSettings || model.isDemo {
            Text("This server does not provide email or push alert settings. The unread badge applies to the app’s inbox.")
                .foregroundStyle(Theme.muted)
        }
    }
    @ViewBuilder private var storageFields: some View {
        Section("This account on this device") {
            LabeledContent("Cached library & artwork", value: ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
            Button("Clear cache", role: .destructive) { confirmation = .clearCache }.disabled(busy || model.isDemo)
            Button("Reset app preferences", role: .destructive) { confirmation = .reset }.disabled(busy)
        }
        #if DEBUG
        Section("Design preview") {
            Button("Preview player design") { showPlayerPreview = true }
            Button("Preview Live TV player") { showLivePlayerPreview = true }
            #if os(iOS)
            Toggle("Use the custom player", isOn: $customPlayerPreviewEnabled)
            Text("Development option for movies, shows and Live TV. Turn off to use the standard player.").foregroundStyle(Theme.muted)
            #else
            Text("Apple TV playback uses Apple's native controls. These previews show the earlier custom design.").foregroundStyle(Theme.muted)
            #endif
            Text("Explore the proposed controls with fictional media. Your library and viewing history stay unchanged.").foregroundStyle(Theme.muted)
        }
        #endif
        Section("Zorofin") {
            LabeledContent("App", value: "Jellyfin client")
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            Text("Connect to a server you already use. Your server manages your library and account.").foregroundStyle(Theme.muted)
        }
    }
    @ViewBuilder private var accountStatus: some View {
        if loadingAccount { ProgressView("Loading account preferences…") }
        if baseline?.canEdit == false { Text("Your server owner has disabled account preference changes.").foregroundStyle(Theme.muted) }
    }
    private func languagePicker(_ title: String, key: String) -> some View {
        SettingsPicker(title, selection: string(key)) {
            Text("No preference").tag("")
            let current = configuration[key]?.string ?? ""
            if !current.isEmpty && !languages.contains(where: { $0.id == current }) { Text(current).tag(current) }
            ForEach(languages) { Text($0.name).tag($0.id) }
        }
    }
    private func subtitleStyle<Value>(_ key: WritableKeyPath<SubtitleAppearance, Value>) -> Binding<Value> {
        Binding(get: { (draft.subtitleAppearance ?? .init())[keyPath: key] }, set: { value in
            var appearance = draft.subtitleAppearance ?? .init()
            appearance[keyPath: key] = value
            draft.subtitleAppearance = appearance
        })
    }
    private func bool(_ key: String, fallback: Bool = false) -> Binding<Bool> {
        Binding(get: { configuration[key]?.bool ?? fallback }, set: { configuration[key] = .bool($0); status = nil })
    }
    private func string(_ key: String, fallback: String = "") -> Binding<String> {
        Binding(get: { configuration[key]?.string ?? fallback }, set: { configuration[key] = .string($0); status = nil })
    }
    private func clearSecrets() {
        currentPassword = ""; newPassword = ""; confirmationPassword = ""
        alertSettings?.credentials = nil
    }
    private func run(_ work: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        busy = true
        operation = Task { defer { busy = false }; await work() }
    }
    private func load() async {
        if !model.preferencesReady { await model.waitForSettings() }
        guard !Task.isCancelled else { return }
        draft = model.preferences; ready = true; error = model.settingsError
        languages = [.init(id: "eng", name: "English"),.init(id: "spa", name: "Spanish"),.init(id: "fra", name: "French"),
            .init(id: "ara", name: "Arabic"),.init(id: "urd", name: "Urdu"),.init(id: "hin", name: "Hindi")]
        await reloadServer()
        if page == .storage { cacheBytes = await model.client?.responseCache?.diskUsage() ?? 0 }
    }
    private func reloadServer(force: Bool = false) async {
        guard page.usesAccount || page == .notifications else { return }
        loadingAccount = true; error = nil
        defer { loadingAccount = false }
        let generation = model.generation
        do {
            if page == .notifications {
                if model.features.notificationSettings, let client = model.client {
                    let result = try await client.requestAlertSettings()
                    guard !Task.isCancelled, generation == model.generation else { return }
                    alertSettings = result
                }
            } else {
                if force || model.viewerSettings == nil { try await model.refreshViewerSettings() }
                guard !Task.isCancelled, generation == model.generation else { return }
                baseline = model.viewerSettings; configuration = baseline?.configuration ?? [:]
                if let client = model.client, let values = try? await client.settingsLanguages(), !values.isEmpty {
                    guard !Task.isCancelled, generation == model.generation else { return }
                    languages = values
                }
            }
        } catch {
            guard !Task.isCancelled, generation == model.generation else { return }
            self.error = error.localizedDescription
        }
    }
    private func save() async {
        busy = true; error = nil; status = nil
        defer { busy = false }
        let generation = model.generation
        do {
            if !changes.isEmpty, let baseline {
                if model.isDemo {
                    var next = baseline; next.configuration = configuration; model.viewerSettings = next; self.baseline = next
                } else if let client = model.client {
                    let confirmed = try await client.saveViewerConfiguration(changes: changes, baseline: baseline)
                    guard !Task.isCancelled, generation == model.generation else { return }
                    model.viewerSettings = confirmed; self.baseline = confirmed; configuration = confirmed.configuration
                    await client.responseCache?.invalidateMetadata()
                    guard !Task.isCancelled, generation == model.generation else { return }
                }
            }
            try await model.savePreferences(draft)
            guard !Task.isCancelled, generation == model.generation else { return }
            status = "Settings saved."
        } catch {
            guard !Task.isCancelled, generation == model.generation else { return }
            self.error = error.localizedDescription
        }
    }
    private func changePassword() async {
        guard let client = model.client, newPassword == confirmationPassword else { return }
        busy = true; error = nil; status = nil
        let generation = model.generation, old = currentPassword, new = newPassword
        clearSecrets()
        defer { busy = false }
        do {
            try await client.changeOwnPassword(current: old, new: new)
            guard !Task.isCancelled, generation == model.generation else { return }
            status = "Password updated."; baseline?.hasPassword = true
        } catch {
            guard !Task.isCancelled, generation == model.generation else { return }
            self.error = error.localizedDescription
        }
    }
    private func savePhoto(_ data: Data?) async {
        guard let client = model.client else { return }
        busy = true; error = nil; status = nil
        let generation = model.generation
        defer { busy = false }
        do {
            try await client.updateOwnProfileImage(jpeg: data)
            guard !Task.isCancelled, generation == model.generation else { return }
            model.profileImage = data.flatMap(UIImage.init(data:)); pendingPhoto = nil; baseline?.hasImage = data != nil
            model.viewerSettings?.hasImage = data != nil
            status = data == nil ? "Profile photo removed." : "Profile photo saved."
        } catch {
            guard !Task.isCancelled, generation == model.generation else { return }
            self.error = error.localizedDescription
        }
    }
    private func alertAction(_ action: RequestAlertAction) async {
        guard let client = model.client else { return }
        busy = true; error = nil; status = nil
        let generation = model.generation, submittedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { busy = false }
        do {
            var result = try await client.updateRequestAlerts(action, email: submittedEmail)
            guard !Task.isCancelled, generation == model.generation else { return }
            let credentialsHidden = scenePhase != .active && result.credentials != nil
            if credentialsHidden { result.credentials = nil }
            alertSettings = result
            status = credentialsHidden
                ? "Push alerts were updated while the app was in the background. Replace the push password to view fresh connection details."
                : result.message ?? "Notification settings updated."
            if action == .saveEmail { email = "" }
        } catch {
            guard !Task.isCancelled, generation == model.generation else { return }
            alertSettings?.credentials = nil; self.error = error.localizedDescription
        }
    }
    private func clearCache() async {
        busy = true; error = nil; status = nil
        let generation = model.generation
        defer { busy = false }
        do {
            try await model.clearLibraryCache()
            guard !Task.isCancelled, generation == model.generation else { return }
            cacheBytes = await model.client?.responseCache?.diskUsage() ?? 0; status = "Cache cleared."
        } catch {
            guard !Task.isCancelled, generation == model.generation else { return }
            self.error = "Some cached files could not be cleared. Try again."
        }
    }
}

private struct SettingsNavigationStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }
}
private struct SettingsEmailInput: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        content
        #endif
    }
}

private struct SettingsPicker<Selection: Hashable, Choices: View>: View {
    let title: String
    @Binding var selection: Selection
    let choices: Choices

    init(_ title: String, selection: Binding<Selection>, @ViewBuilder content: () -> Choices) {
        self.title = title
        _selection = selection
        choices = content()
    }

    var body: some View {
        #if os(tvOS)
        // tvOS menu pickers omit their label; keep a persistent row title.
        HStack(spacing: 24) {
            Text(title)
            Spacer()
            Picker(title, selection: $selection) { choices }
                .pickerStyle(.menu).labelsHidden().accessibilityLabel(title)
        }
        #else
        Picker(title, selection: $selection) { choices }
        #endif
    }
}

private struct SettingsFormBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.scrollContentBackground(.hidden).foregroundStyle(Theme.text)
        #else
        // Reset the shell’s fixed foreground so native focused rows can adapt.
        content.foregroundStyle(Color.primary)
        #endif
    }
}
private struct SettingsSelectableText: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.textSelection(.enabled)
        #else
        content
        #endif
    }
}



/// Bundled policy stays readable before sign-in and when a server is offline.
struct PublicInformationView: View {
    @Environment(\.dismiss) private var dismiss
    let page: PublicDocument
    @State private var relatedDocument: PublicDocument?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(page.title).font(Theme.font(Theme.isTV ? 40 : 30, weight: .bold, relativeTo: .largeTitle))
                        .accessibilityAddTraits(.isHeader)
                    Text("Updated \(PublicDocument.updated)").font(.footnote).foregroundStyle(Theme.muted)
                    Text(page.intro)
                    ForEach(page.sections) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(section.title).font(.headline).accessibilityAddTraits(.isHeader)
                            ForEach(section.paragraphs, id: \.self) { paragraph in
                                Text(paragraph).fixedSize(horizontal: false, vertical: true)
                                    #if os(tvOS)
                                    .focusable()
                                    #else
                                    .textSelection(.enabled)
                                    #endif
                            }
                        }
                    }
                    if page == .support {
                        Button("Sample media credits") { relatedDocument = .credits }
                            .frame(minHeight: Theme.target)
                    }
                    #if os(iOS)
                    Link("Email app support", destination: URL(string: "mailto:" + PublicDocument.contact)!)
                        .frame(minHeight: 48)
                    #else
                    Text(PublicDocument.contact).foregroundStyle(Theme.jade)
                    #endif
                }.font(Theme.font(Theme.isTV ? 24 : 17)).lineSpacing(5)
                    .padding(Theme.isTV ? 48 : 24).frame(maxWidth: 920, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
            }.background(Theme.background).foregroundStyle(Theme.text)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .accessibilityIdentifier("public-information-\(page.id)")
        }.tint(Theme.jade).preferredColorScheme(.dark)
            .sheet(item: $relatedDocument) { PublicInformationView(page: $0) }
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
    }
}
