import SwiftUI
import Security
import ImageIO
import ZorofinCore

enum SessionVault {
    private static let service = "org.zorofin.viewer-session"
    static func save(_ connections: SavedConnections) throws {
        let data = try JSONEncoder().encode(connections)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "active"]
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query.merging(attributes) { _, new in new }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw VaultError.unavailable }
        } else if status != errSecSuccess { throw VaultError.unavailable }
    }
    static func load() throws -> SavedConnections? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "active",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VaultError.unavailable }
        return try JSONDecoder().decode(SavedConnections.self, from: data)
    }
    enum VaultError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Secure storage is unavailable. Unlock your device and try again." }
    }
}

@MainActor @Observable final class AppModel {
    @ObservationIgnored let reviewPrompts = ReviewPromptStore()
    var watchTogether = WatchTogetherModel()
    var client: JellyfinClient?
    var session: Session?
    private(set) var connections = SavedConnections()
    private(set) var storageReady = false
    private(set) var serverName = ""
    var isDemo = false
    var restoring = true
    var message: String?
    var generation = UUID()
    var pendingTopShelfLink: TopShelfLink?
    #if os(tvOS)
    @ObservationIgnored let topShelf = TopShelfPublisher()
    #endif
    var imageCache = ArtworkCache()
    var homeLibrary = HomeLibraryState()
    var liveGuide = LiveGuideState()
    var searchLibrary = SearchLibraryState()
    var requestsLibrary = RequestsLibraryState()
    private var movieLibrary = CatalogLibraryState()
    private var showLibrary = CatalogLibraryState()
    private var liveLibrary = CatalogLibraryState()
    var libraryRevision = 0
    func catalogLibrary(_ kind: String) -> CatalogLibraryState {
        switch kind { case "Series": showLibrary; case "TvChannel": liveLibrary; default: movieLibrary }
    }
    private func resetLibrary() {
        let oldCache = client?.responseCache
        Task { await oldCache?.close(purge: false) }
        homeLibrary = HomeLibraryState(); searchLibrary = SearchLibraryState(); liveGuide = LiveGuideState()
        requestsLibrary = RequestsLibraryState()
        movieLibrary = CatalogLibraryState(); showLibrary = CatalogLibraryState(); liveLibrary = CatalogLibraryState(); libraryRevision = 0
    }
    var extensionEnabled: Bool { features.requests }
    var features = ServerFeatures()
    /// The plugin's Calendar and Catch Up, when the operator turned them on.
    var pluginExtras = PluginExtras.none
    /// A title a Profile page (Calendar, Catch Up) asked the shell to open.
    var pendingOpen: MediaItem?
    /// A title to play through the ordinary player (Pick Together matches).
    var pendingPlay: MediaItem?
    let pickTogether = PickTogetherController()
    var pendingBrowseDownloads = false
    var featuresChecked = false
    var featureError: String?
    var replies: [SupportReply] = []
    var requestNotices: [RequestAvailabilityNotice] = []
    var accountNotificationReads: NotificationReadState?
    var requestReadIDs: Set<Int> = []
    var requestNoticeError: String?
    var loadingRequestNotices = false
    var readingRequestIDs: Set<Int> = []
    var hasOlderRequestNotices = false
    private let requestReadStore = RequestNotificationReadStore() // Migration only.
    private let notificationHistory = NotificationHistoryStore()
    var hiddenReplies: [SupportReply] = []
    var seenReplyKeys: Set<String> = []
    private var lastReplyCheck = Date.distantPast
    private var requestNoticeRevision = 0
    private var lastRequestNoticeCheck = Date.distantPast
    var hasNotifications: Bool { features.notifications || features.requests }
    func isRequestRead(_ id: Int) -> Bool { requestReadIDs.contains(id) || (features.notificationReads && accountNotificationReads?.requests.contains(id) == true) }
    func isReplyRead(_ reply: SupportReply) -> Bool { seenReplyKeys.contains(reply.notificationKey) || (features.notificationReads && !reply.isAnnouncement && accountNotificationReads?.replies.contains(reply.accountReadKey) == true) }
    var unreadRequestNotices: [RequestAvailabilityNotice] { requestNotices.filter { !isRequestRead($0.id) } }
    var unreadReplies: [SupportReply] { replies.filter { !isReplyRead($0) } }
    var readReplies: [SupportReply] {
        var seen: Set<String> = []
        return (replies.filter { isReplyRead($0) } + hiddenReplies).filter { seen.insert($0.notificationKey).inserted }
    }
    var unreadNotificationCount: Int { unreadReplies.count + unreadRequestNotices.count }
    var loadingNotifications: Bool { loadingReplies || loadingRequestNotices }
    var replyError: String?
    var loadingReplies = false
    var readingReplyIDs: Set<String> = []
    var supportIssue = "Playback / buffering problem"
    var supportDescription = ""
    var supportMedia = ""
    var supportSubmission = SupportSubmission.idle
    private var supportTask: Task<Void, Never>?
    private var checkingFeatures = false
    private var retryFeatures = false
    private var replyRevision = 0
    var homeRevision = 0
    var bitrate: Int { preferences.bitrate }
    var preferences = NativePreferences()
    var viewerSettings: ViewerSettings?
    var settingsError: String?
    var preferencesReady = false
    /// The server's looks (accent and card size for every viewer), if any.
    var serverLooks: ServerLooks?
    /// Whether this viewer saved their own settings on this device.
    private var preferencesSaved = false
    /// Poster size: the server's card size when it is the same for every
    /// viewer, or until the viewer picks their own; otherwise theirs.
    var posterScale: Double {
        if let serverLooks, serverLooks.enforced || !preferencesSaved { return serverLooks.posterScale }
        return preferences.posterScale
    }
    /// The server sets the poster size, so Settings doesn't offer it.
    var cardSizeFromServer: Bool { serverLooks?.enforced == true }
    var profileImage: UIImage?
    private let preferenceStore = NativePreferenceStore()
    private var settingsTask: Task<Void, Never>?
    private var accountSettingsTask: Task<Void, Never>?
    private var settingsRequestID = UUID()

    private func resetSettings() {
        settingsTask?.cancel(); settingsTask = nil
        accountSettingsTask?.cancel(); accountSettingsTask = nil; settingsRequestID = UUID()
        preferences = .init(); viewerSettings = nil; profileImage = nil
        preferencesReady = false; settingsError = nil; preferencesSaved = false
        useLooks(session.flatMap { ServerLooksCache.standard.load($0.server) })
    }
    private func useLooks(_ looks: ServerLooks?) {
        serverLooks = looks
        ServerAccent.shared.set(looks?.accent)
    }
    /// Fetches the server's looks and keeps them for the next launch. A
    /// server without them (or a failed check) keeps what was cached.
    private func refreshLooks(_ client: JellyfinClient, expected: UUID) async {
        guard let session else { return }
        do {
            let looks = try await client.serverLooks()
            guard !Task.isCancelled, generation == expected else { return }
            ServerLooksCache.standard.save(looks, server: session.server)
            useLooks(looks)
        } catch {}
    }
    private func beginSettings() {
        resetSettings()
        guard let session else { return }
        let expected = generation
        settingsTask = Task {
            do {
                let saved = try await preferenceStore.load(server: session.server, viewerID: session.viewer.id)
                let hasSaved = await preferenceStore.hasSaved(server: session.server, viewerID: session.viewer.id)
                guard !Task.isCancelled, generation == expected else { return }
                preferences = saved; preferencesSaved = hasSaved
            } catch {
                guard !Task.isCancelled, generation == expected else { return }
                settingsError = "Saved app settings could not be loaded. Defaults are in use until you save again."
            }
            guard !Task.isCancelled, generation == expected else { return }
            preferencesReady = true
            accountSettingsTask = Task {
                do { try await refreshViewerSettings() }
                catch {
                    guard !Task.isCancelled, generation == expected else { return }
                    settingsError = "Account settings could not be refreshed. Your library is still available."
                }
            }
        }
    }
    func waitForSettings() async { await settingsTask?.value }
    func refreshViewerSettings() async throws {
        guard !isDemo, let client else { return }
        let expected = generation, requestID = UUID()
        settingsRequestID = requestID
        let result = try await client.viewerSettings()
        guard !Task.isCancelled, generation == expected, settingsRequestID == requestID else { throw CancellationError() }
        viewerSettings = result; settingsError = nil
        if result.hasImage, let data = try? await client.ownProfileImage() {
            guard !Task.isCancelled, generation == expected, settingsRequestID == requestID else { throw CancellationError() }
            profileImage = UIImage(data: data)
        } else if !result.hasImage { profileImage = nil }
    }
    func savePreferences(_ value: NativePreferences) async throws {
        guard value.isValid else { throw SettingsError.invalidInput }
        if isDemo { preferences = value; return }
        guard let session else { throw ClientError.missingSession }
        let expected = generation
        try await preferenceStore.save(value, server: session.server, viewerID: session.viewer.id)
        guard !Task.isCancelled, generation == expected else { throw CancellationError() }
        preferences = value; preferencesReady = true; preferencesSaved = true
        if value.homeScreenPreviews == false { clearTopShelf() } else { refreshTopShelf() }
    }
    func clearLibraryCache() async throws {
        guard let session, let previous = client else { return }
        let expected = generation
        var failure: Error?
        do { try await previous.responseCache?.purge() } catch { failure = error }
        guard generation == expected else { throw CancellationError() }
        clearTopShelf()
        resetLibrary(); imageCache = ArtworkCache()
        client = JellyfinClient(server: session.server, identity: previous.identity, session: session,
            responseCache: LibraryResponseCache(server: session.server, viewerID: session.viewer.id))
        libraryRevision += 1; homeRevision += 1
        if let failure { throw failure }
    }

    var signedIn: Bool { session != nil || isDemo }
    var viewerName: String { session?.viewer.name ?? "Preview" }
    var initial: String { String(viewerName.prefix(1)).uppercased() }
    var deviceName: String {
        #if os(tvOS)
        "Apple TV"
        #else
        "iPhone / iPad"
        #endif
    }
    func unauthenticatedClient(server: ServerAddress, deviceID: String = UUID().uuidString) -> JellyfinClient {
        JellyfinClient(server: server, identity: .init(deviceID: deviceID, deviceName: deviceName))
    }
    func restore() async {
        guard restoring else { return }
        defer { restoring = false; if !signedIn { clearTopShelf() } }
        do {
            connections = try SessionVault.load() ?? SavedConnections()
            storageReady = true
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--demo") { showDemo(); return }
            #endif
            // Apple TV is shared, so it asks who's watching when the last server has
            // several viewers. iPhone and iPad reopen the last account.
            if let session = connections.launchSession(sharedDevice: Theme.isTV),
               let active = connections.activeAccount {
                setSession(session, name: active.serverName)
            }
        } catch { message = "Saved sign-ins could not be opened. Unlock your device and retry. Nothing has been replaced." }
    }
    private func persist(_ next: SavedConnections) throws {
        guard storageReady else { throw SessionVault.VaultError.unavailable }
        try SessionVault.save(next)
        connections = next
    }
    func accept(_ session: Session, serverName: String, remember: Bool = true) throws {
        var next = connections
        if remember { next.remember(session, serverName: serverName) }
        else { next.clearSelection() }
        try persist(next)
        setSession(session, name: serverName)
    }
    func switchAccount(_ id: UUID) async throws {
        guard let account = connections.accounts.first(where: { $0.id == id }),
              let saved = account.session else { throw ClientError.missingSession }
        let expectedGeneration = generation
        let selectedClient = JellyfinClient(server: saved.server,
            identity: .init(deviceID: saved.deviceID, deviceName: deviceName), session: saved)
        do {
            let viewer = try await selectedClient.currentViewer()
            try Task.checkCancellation()
            guard generation == expectedGeneration else { throw CancellationError() }
            guard viewer.id == saved.viewer.id else { throw ClientError.unauthorized }
            var refreshed = saved; refreshed.viewer = viewer
            var next = connections
            next.remember(refreshed, serverName: account.serverName)
            try persist(next)
            setSession(refreshed, name: account.serverName)
        } catch ClientError.unauthorized {
            guard !Task.isCancelled, generation == expectedGeneration else { throw CancellationError() }
            var next = connections; next.signOut(id)
            try persist(next)
            if isCurrent(account) { clearSession() }
            throw ClientError.unauthorized
        }
    }
    func isCurrent(_ account: SavedAccount) -> Bool {
        guard let session else { return false }
        return session.server.storageKey == account.server.storageKey && session.viewer.id == account.viewer.id
    }
    func removeAccount(_ id: UUID) async throws {
        guard let account = connections.accounts.first(where: { $0.id == id }) else { return }
        let previous = account.session.map { saved in
            JellyfinClient(server: saved.server,
                identity: .init(deviceID: saved.deviceID, deviceName: deviceName), session: saved)
        }
        let current = isCurrent(account)
        // A visit-only login can be a different token for the same saved viewer.
        let removingActiveToken = current && session?.token == account.session?.token
        var next = connections; next.remove(id)
        try persist(next)
        #if os(iOS)
        // Downloads belong to the saved account; removing it removes them too.
        DownloadManager.shared.removeAll(server: account.server, viewerID: account.viewer.id)
        #endif
        if current { clearTopShelf() }
        let oldCache = current ? client?.responseCache : nil
        if removingActiveToken { clearSession() }
        if removingActiveToken { await oldCache?.close(purge: true) }
        else if !current { await LibraryResponseCache(server: account.server, viewerID: account.viewer.id).close(purge: true) }
        let expectedGeneration = generation
        if let previous {
            do { try await Task { try await previous.logout() }.value }
            catch {
                if generation == expectedGeneration {
                    message = "Removed from this device. The server could not confirm sign-out; you can revoke that device session in the server's settings."
                }
            }
        }
    }
    private func setSession(_ session: Session, name: String) {
        clearTopShelf()
        resetLibrary()
        generation = UUID(); imageCache = ArtworkCache(); isDemo = false
        self.session = session; serverName = name
        client = JellyfinClient(server: session.server,
            identity: .init(deviceID: session.deviceID, deviceName: deviceName), session: session,
            responseCache: LibraryResponseCache(server: session.server, viewerID: session.viewer.id))
        watchTogether.configure(client)
        #if os(iOS)
        DownloadManager.shared.configure(client: client)
        #endif
        resetExtensions(); homeRevision = 0; beginSettings()
        // Start Home on the row source this server had last time, so a cold
        // launch doesn't build basic rows and then replace them.
        features.homeRowsContract = rememberedHomeContract
    }
    private var homeContractKey: String? {
        session.map { "zorofin.homeRowsContract.\($0.server.storageKey).\($0.viewer.id)" }
    }
    private var rememberedHomeContract: HomeRowsContract? {
        get { homeContractKey.flatMap { UserDefaults.standard.object(forKey: $0) as? Int }.flatMap(HomeRowsContract.init(rawValue:)) }
        set {
            guard let key = homeContractKey else { return }
            if let newValue { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
    private func clearSession() {
        watchTogether.configure(nil)
        #if os(iOS)
        DownloadManager.shared.configure(client: nil)
        #endif
        clearTopShelf(); pendingTopShelfLink = nil
        resetLibrary()
        generation = UUID(); client = nil; session = nil; isDemo = false; serverName = ""
        imageCache = ArtworkCache(); resetExtensions(); homeRevision = 0; resetSettings()
    }
    func showDemo() {
        clearSession(); isDemo = true; preferencesReady = true
        viewerSettings = .init(name: "Preview", configuration: ["SubtitleMode": .string("Default"), "EnableNextEpisodeAutoPlay": .bool(false)])
        features = .preview; featuresChecked = true
        requestNotices = [.init(id: 1, kind: .movie, titleID: 1, title: "The Last Lighthouse")]
        replies = [.init(id: "Tpreview1", status: "resolved", issueType: "Playback / buffering problem",
                         message: "This is a sample support reply. Real replies from your server appear here.", updatedAt: "2026-10-16T12:00:00Z")]
    }
    func signOut() async {
        let previous = client
        if !isDemo {
            var next = connections
            if let active = next.activeAccount, active.session?.token == session?.token { next.signOut(active.id) }
            else { next.clearSelection() }
            do { try persist(next) } catch { message = error.localizedDescription; return }
        }
        clearSession()
        await previous?.responseCache?.close(purge: true)
        let expectedGeneration = generation
        if let previous {
            do { try await Task { try await previous.logout() }.value }
            catch {
                if generation == expectedGeneration {
                    message = "Signed out on this device. The server could not confirm revocation; remove this device from your server if needed."
                }
            }
        }
    }

    private func resetExtensions() {
        accountNotificationReads = nil
        supportTask?.cancel(); supportTask = nil
        features = .init(); pluginExtras = .none; pendingOpen = nil; pendingPlay = nil; pickTogether.reset(); pendingBrowseDownloads = false; featuresChecked = false; featureError = nil
        checkingFeatures = false; retryFeatures = false
        replies = []; hiddenReplies = []; seenReplyKeys = []; lastReplyCheck = .distantPast; replyError = nil; loadingReplies = false; readingReplyIDs = []; replyRevision = 0
        requestNotices = []; requestReadIDs = []; requestNoticeError = nil; loadingRequestNotices = false
        readingRequestIDs = []; requestNoticeRevision = 0; hasOlderRequestNotices = false; lastRequestNoticeCheck = .distantPast
        supportIssue = "Playback / buffering problem"; supportDescription = ""; supportMedia = ""
        supportSubmission = .idle
    }

    /// Owned by SwiftUI's active-scene task; no background polling or global timers.
    func runExtensionUpdates() async {
        guard !isDemo else { return }
        let expectedGeneration = generation
        while !Task.isCancelled && generation == expectedGeneration {
            await checkFeatures()
            guard !Task.isCancelled, generation == expectedGeneration else { return }
            if hasNotifications { await refreshNotifications() }
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }

    func checkFeatures() async {
        guard !checkingFeatures, !isDemo, let client else { return }
        let expectedGeneration = generation
        checkingFeatures = true
        let previousContract = features.homeRowsContract
        defer {
            if generation == expectedGeneration {
                checkingFeatures = false
                if previousContract != features.homeRowsContract {
                    homeLibrary.rowLoadID = UUID(); homeLibrary.homeFeed = nil
                    homeLibrary.homeError = nil; homeLibrary.rowsLoadedAt = .distantPast
                    homeLibrary.rowsRevision = -1
                }
            }
        }
        do {
            let result = try await client.discoverFeatures()
            guard !Task.isCancelled, generation == expectedGeneration else { return }
            await refreshLooks(client, expected: expectedGeneration)
            guard !Task.isCancelled, generation == expectedGeneration else { return }
            features = result.features
            if !result.needsRetry || features.homeRowsContract != nil { rememberedHomeContract = features.homeRowsContract }
            if !features.notifications { replies = []; hiddenReplies = []; seenReplyKeys = []; replyError = nil }
            if !features.requests { requestNotices = []; requestReadIDs = []; requestNoticeError = nil; hasOlderRequestNotices = false }
            let extras = (try? await client.pluginExtras()) ?? .none
            guard !Task.isCancelled, generation == expectedGeneration else { return }
            pluginExtras = extras
            featuresChecked = true; retryFeatures = result.needsRetry
            featureError = result.needsRetry ? "Some server extras could not be checked. Your library is still available." : nil
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, generation == expectedGeneration else { return }
            if let failure = error as? ClientError {
                switch failure {
                case .unauthorized, .forbidden, .invalidResponse:
                    features = .init(); pluginExtras = .none; replies = []; hiddenReplies = []; seenReplyKeys = []; replyError = nil
                    rememberedHomeContract = nil
                    requestNotices = []; requestReadIDs = []; requestNoticeError = nil
                default: break
                }
            }
            featuresChecked = true; retryFeatures = true
            featureError = "Server extras could not be checked. Your library is still available."
        }
    }

    func refreshNotifications(force: Bool = false) async {
        let expected = generation
        if features.notificationReads, !isDemo, let client {
            let remote = try? await client.notificationReads()
            guard !Task.isCancelled, generation == expected else { return }
            accountNotificationReads = remote
        } else { accountNotificationReads = nil }
        async let support: Void = refreshReplies(force: force)
        async let requests: Void = refreshRequestNotices(force: force)
        _ = await (support, requests)
    }

    private func refreshRequestNotices(force: Bool) async {
        guard features.requests, !loadingRequestNotices, !isDemo, let client, let session,
              force || Date().timeIntervalSince(lastRequestNoticeCheck) >= 120 else { return }
        let expected = generation, revision = requestNoticeRevision
        let account = features.notificationReads ? accountNotificationReads : nil
        loadingRequestNotices = true
        // Also throttle failures during the foreground loop; explicit Retry bypasses it.
        lastRequestNoticeCheck = Date()
        defer { if generation == expected { loadingRequestNotices = false } }
        do {
            let readIDs = try await requestReadStore.readIDs(server: session.server, viewerID: session.viewer.id)
            let saved = try await notificationHistory.load(server: session.server, viewerID: session.viewer.id)
            guard !Task.isCancelled, generation == expected, features.requests else { return }
            requestReadIDs.formUnion(saved.readRequestIDs)
            if requestNotices.isEmpty { requestNotices = saved.requests }
            // Cached available items already have a history entry. Pending requests
            // are still rechecked; only a real availability transition adds an item.
            let result = try await client.requestAvailabilityNotifications(readIDs: account == nil ? Set(saved.requests.map(\.id)).union(saved.requestsInitialized ? saved.readRequestIDs : []) : [])
            guard !Task.isCancelled, generation == expected, features.requests,
                  revision == requestNoticeRevision, readingRequestIDs.isEmpty else { return }
            let updated = try await notificationHistory.receiveRequests(result.notices, legacyReadIDs: readIDs, initializeSnapshot: account?.initialized != true,
                server: session.server, viewerID: session.viewer.id)
            guard !Task.isCancelled, generation == expected, features.requests else { return }
            requestReadIDs.formUnion(updated.readRequestIDs); requestNotices = updated.requests
            hasOlderRequestNotices = result.hasOlder; requestNoticeError = nil
            if let account, features.notificationReads {
                let ready = Set(result.notices.map(\.id))
                let migration = account.initialized ? updated.readRequestIDs.intersection(ready).subtracting(account.requests) : ready
                if !account.initialized || !migration.isEmpty {
                    if let synced = try? await client.markNotificationReads(requests: Array(migration), initialize: !account.initialized) {
                        guard !Task.isCancelled, generation == expected, features.notificationReads else { return }
                        accountNotificationReads = (accountNotificationReads ?? .init()).merging(synced)
                    }
                }
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, generation == expected else { return }
            if let failure = error as? ClientError, [.unauthorized, .forbidden].contains(failure) { requestNotices = [] }
            requestNoticeError = "Request updates could not be refreshed. Try again shortly."
        }
    }

    func markRequestRead(_ notice: RequestAvailabilityNotice) async {
        guard !readingRequestIDs.contains(notice.id) else { return }
        if isDemo { requestReadIDs.insert(notice.id); return }
        guard features.requests, let session else { return }
        let expected = generation
        requestNoticeRevision += 1; readingRequestIDs.insert(notice.id)
        defer { if generation == expected { readingRequestIDs.remove(notice.id); requestNoticeRevision += 1 } }
        do {
            let ids = try await notificationHistory.seeRequest(notice.id, server: session.server, viewerID: session.viewer.id)
            guard !Task.isCancelled, generation == expected else { return }
            // Merge rather than replace, so overlapping acknowledgement responses
            // cannot make a successfully read notice unread again.
            requestReadIDs.formUnion(ids); requestNoticeError = nil
            if features.notificationReads, accountNotificationReads?.requests.contains(notice.id) != true, let client {
                if let synced = try? await client.markNotificationReads(requests: [notice.id]) {
                    guard !Task.isCancelled, generation == expected, features.notificationReads else { return }
                    accountNotificationReads = (accountNotificationReads ?? .init()).merging(synced)
                }
            }
        } catch {
            guard !Task.isCancelled, generation == expected else { return }
            requestNoticeError = "This update could not be marked as read. Please try again."
        }
    }

    func refreshReplies(force: Bool = false) async {
        guard features.notifications, !loadingReplies, !isDemo, let client, let session,
              force || Date().timeIntervalSince(lastReplyCheck) >= 120 else { return }
        let expectedGeneration = generation
        let expectedRevision = replyRevision
        loadingReplies = true; lastReplyCheck = Date()
        defer { if generation == expectedGeneration { loadingReplies = false } }
        do {
            let saved = try await notificationHistory.load(server: session.server, viewerID: session.viewer.id)
            guard !Task.isCancelled, generation == expectedGeneration, features.notifications else { return }
            hiddenReplies = saved.hiddenReplies; seenReplyKeys.formUnion(saved.seenReplyKeys)
            let result = try await client.inboxMessages()
            guard !Task.isCancelled, generation == expectedGeneration, features.notifications else { return }
            // Discard a GET overlapping an acknowledgement; remove only after success.
            guard replyRevision == expectedRevision, readingReplyIDs.isEmpty else { return }
            replies = result.keeping(replies)
            replyError = result.partial ? "Some messages could not be refreshed." : nil
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, generation == expectedGeneration else { return }
            if let failure = error as? ClientError, [.unauthorized, .forbidden].contains(failure) { replies = []; hiddenReplies = [] }
            replyError = "Messages could not be refreshed."
        }
    }

    func markRead(_ reply: SupportReply) async {
        guard !readingReplyIDs.contains(reply.id) else { return }
        if isDemo {
            seenReplyKeys.insert(reply.notificationKey)
            if !hiddenReplies.contains(where: { $0.notificationKey == reply.notificationKey }) { hiddenReplies.insert(reply, at: 0) }
            return
        }
        guard features.notifications, let session else { return }
        let expectedGeneration = generation
        replyRevision += 1
        readingReplyIDs.insert(reply.id)
        defer { if generation == expectedGeneration { readingReplyIDs.remove(reply.id); replyRevision += 1 } }
        do {
            // Keep the local write even when account syncing is unavailable.
            // The account ACK includes this exact reply version, never only a ticket ID.
            let saved = try await notificationHistory.seeReply(reply, server: session.server, viewerID: session.viewer.id)
            guard !Task.isCancelled, generation == expectedGeneration else { return }
            seenReplyKeys.formUnion(saved.seenReplyKeys); hiddenReplies = saved.hiddenReplies; replyError = nil
            if features.notificationReads, !reply.isAnnouncement, accountNotificationReads?.replies.contains(reply.accountReadKey) != true, let client {
                if let synced = try? await client.markNotificationReads(replies: [reply]) {
                    guard !Task.isCancelled, generation == expectedGeneration, features.notificationReads else { return }
                    accountNotificationReads = (accountNotificationReads ?? .init()).merging(synced)
                }
            }
        } catch {
            guard !Task.isCancelled, generation == expectedGeneration else { return }
            replyError = "This message could not be marked as read. Please try again."
        }
    }

    var supportReport: SupportReport {
        .init(issueType: supportIssue, description: supportDescription, affectedMedia: supportMedia)
    }
    func sendSupport() {
        guard features.support, !isDemo, let client, supportReport.isValid else { return }
        switch supportSubmission {
        case .idle, .rejected: break
        default: return
        }
        let expectedGeneration = generation
        let report = supportReport
        supportSubmission = .sending
        // Keep the one submission alive if its sheet is closed. Reset on account changes.
        supportTask = Task {
            do {
                let id = try await client.submitSupport(report)
                guard generation == expectedGeneration else { return }
                supportSubmission = .accepted(id)
                supportDescription = ""; supportMedia = ""
            } catch SupportError.rejected {
                guard generation == expectedGeneration else { return }
                supportSubmission = .rejected
            } catch {
                guard generation == expectedGeneration else { return }
                supportSubmission = .uncertain
            }
            supportTask = nil
        }
    }
}

enum SupportSubmission {
    case idle, sending, accepted(String), rejected, uncertain
    var canEdit: Bool {
        switch self { case .idle, .rejected: true; default: false }
    }
}

/// Decoded thumbnails are cost-bounded and evict automatically under memory pressure.
/// Compressed artwork is cached separately on disk by the account-scoped core cache.
actor ArtworkCache {
    private let images = NSCache<NSString, UIImage>()
    init() { images.totalCostLimit = 40 * 1024 * 1024 }
    func image(key: String, client: JellyfinClient, itemID: String, kind: String, tag: String?, width: Int) async throws -> UIImage? {
        if let image = images.object(forKey: key as NSString) { return image }
        let data = try await client.image(itemID: itemID, kind: kind, tag: tag, width: width)
        try Task.checkCancellation()
        if let image = images.object(forKey: key as NSString) { return image }
        return decode(data, key: key, width: width)
    }
    func liveImage(client: JellyfinClient, path: String, width: Int) async throws -> UIImage? {
        let key = "live-\(path)-\(width)"
        if let image = images.object(forKey: key as NSString) { return image }
        let data = try await client.liveArtworkImage(path: path)
        try Task.checkCancellation()
        if let image = images.object(forKey: key as NSString) { return image }
        return decode(data, key: key, width: width)
    }
    func homeCrest(client: JellyfinClient, path: String) async throws -> UIImage? {
        let key = client.server.url.absoluteString + "/" + path
        if let image = images.object(forKey: key as NSString) { return image }
        let data = try await client.homeCrestData(path: path)
        try Task.checkCancellation()
        return decode(data, key: key, width: 240)
    }
    func requestImage(url: URL) async throws -> UIImage? {
        let key = "request-" + url.absoluteString
        if let image = images.object(forKey: key as NSString) { return image }
        let data = try await RequestArtwork.data(url: url)
        try Task.checkCancellation()
        return decode(data, key: key, width: 342)
    }
    private func decode(_ data: Data, key: String, width: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(2880, max(120, width * 3 / 2))
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumbnail)
        images.setObject(image, forKey: key as NSString, cost: thumbnail.bytesPerRow * thumbnail.height)
        return image
    }
}

enum PreviewLibrary {
    static let synopsis = "A journey through unfamiliar places, unexpected encounters, and the moments that stay with us. This fictional title is part of the app preview."
    static let movies: [MediaItem] = ["The Last Light", "Tideline", "Northbound", "After Hours", "Wild Blue", "The Quiet City"].enumerated().map { index, name in
        var item = MediaItem(id: String(format: "000000000000000000000000000000%02d", index + 1), name: name,
            overview: synopsis, productionYear: 2026)
        item.runTimeTicks = Int64(92 + index * 7) * 600_000_000
        item.officialRating = "PG-13"; item.communityRating = 7.8 + Double(index) / 10
        item.genres = ["Drama", "Adventure"]
        item.taglines = ["Every ending is a new beginning."]
        return item
    }
    static let shows: [MediaItem] = ["Orbital", "Open Water", "City Stories"].enumerated().map { index, name in
        MediaItem(id: String(format: "000000000000000000000000000000%02d", index + 20), name: name,
            type: "Series", overview: synopsis, productionYear: 2026)
    }
    static let episodes: [MediaItem] = (1...6).map { index in
        var item = MediaItem(id: String(format: "000000000000000000000000000000%02d", index + 40),
            name: ["Arrival", "The Signal", "A New Orbit", "Into the Dark", "Homeward", "First Light"][index - 1],
            type: "Episode", overview: synopsis, userData: .init(playbackPositionTicks: index == 1 ? 9_000_000_000 : 0))
        item.seriesId = shows[0].id; item.seriesName = "Orbital"; item.parentIndexNumber = 1; item.indexNumber = index
        item.runTimeTicks = 27_000_000_000
        return item
    }
}
