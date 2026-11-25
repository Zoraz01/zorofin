import Foundation

public struct JellyfinClient: Sendable {
    public let server: ServerAddress
    public let identity: ClientIdentity
    public let session: Session?
    public let responseCache: LibraryResponseCache?
    private var cacheOnly = false
    private let transport: any HTTPTransport

    public init(server: ServerAddress, identity: ClientIdentity, session: Session? = nil,
                transport: (any HTTPTransport)? = nil, responseCache: LibraryResponseCache? = nil) {
        self.responseCache = session.map { responseCache?.matches(server: server, viewerID: $0.viewer.id) == true ? responseCache : nil } ?? nil
        self.server = server; self.identity = identity; self.session = session
        self.transport = transport ?? URLSessionTransport(server: server)
    }

    /// A snapshot read never initiates a network request.
    public func readingCache() -> Self { var copy = self; copy.cacheOnly = true; return copy }

    public func requestData(_ path: [String], query: [URLQueryItem] = [], method: String = "GET",
                            body: Data? = nil, authenticated: Bool = true, accept: String = "application/json",
                            extensionToken: Bool = false, expectedStatus: Int? = nil, cachePolicy: LibraryCachePolicy? = nil, contentType: String = "application/json",
                            sameOrigin: Bool = false, requestTimeout: TimeInterval? = nil) async throws -> Data {
        if authenticated && session == nil { throw ClientError.missingSession }
        if authenticated && session?.server != server { throw ClientError.unsafeURL }
        var request = URLRequest(url: try server.endpoint(path, query: query))
        if let requestTimeout { request.timeoutInterval = requestTimeout }
        request.httpMethod = method
        request.httpBody = body
        request.setValue(identity.authorization(token: authenticated ? session?.token : nil), forHTTPHeaderField: "Authorization")
        if extensionToken {
            guard authenticated, let token = session?.token,
                  !token.isEmpty, token.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 }) else {
                throw ClientError.missingSession
            }
            request.setValue(token, forHTTPHeaderField: "X-Jellyfin-Token")
        }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if sameOrigin {
            // Same-origin gateways reject writes without the site's own Origin.
            guard let origin = server.origin else { throw ClientError.unsafeURL }
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let transport = self.transport
        let prepared = request
        let fetch: @Sendable () async throws -> Data = {
            let (data, response) = try await transport.send(prepared)
            try Task.checkCancellation()
            switch response.statusCode {
            case 200..<300:
                if let expectedStatus, response.statusCode != expectedStatus { throw ClientError.invalidResponse }
                return data
            case 401: throw ClientError.unauthorized
            case 403: throw ClientError.forbidden
            default: throw ClientError.unavailable(response.statusCode)
            }
        }
        let key = request.url!.absoluteString
        if cacheOnly {
            guard method == "GET", authenticated, let cachePolicy, let responseCache,
                  let data = await responseCache.snapshot(key, policy: cachePolicy) else { throw LibraryCacheMiss.missing }
            return data
        }
        do {
            if method == "GET", authenticated, let cachePolicy, let responseCache {
                return try await responseCache.value(key, policy: cachePolicy, fetch: fetch)
            }
            return try await fetch()
        } catch {
            if error as? ClientError == .unauthorized && !extensionToken {
                await responseCache?.invalidateMetadata()
            } else if error as? ClientError == .unauthorized {
                // Refusal by an optional module must not cancel core library reads.
                await responseCache?.remove(key, policy: cachePolicy ?? .detail)
            } else if error as? ClientError == .forbidden {
                // A viewer may browse movies while lacking access to Live TV or
                // an optional extension. Denying that resource must not cancel
                // concurrent, authorized Home reads. Still evict its stale data,
                // including when the permission check deliberately bypassed cache.
                await responseCache?.remove(key, policy: cachePolicy ?? .detail)
            }
            throw error
        }
    }

    /// An authenticated extension call whose JSON error body matters
    /// (`{ "error": "code" }`). Only 401 throws; other statuses are returned.
    func extensionCall(_ path: [String], query: [URLQueryItem] = [], method: String = "GET",
                       body: Data? = nil) async throws -> (status: Int, data: Data) {
        guard let session, session.server == server else { throw ClientError.missingSession }
        let token = session.token
        guard !token.isEmpty, token.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 }) else {
            throw ClientError.missingSession
        }
        var request = URLRequest(url: try server.endpoint(path, query: query))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue(identity.authorization(token: token), forHTTPHeaderField: "Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Jellyfin-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        if response.statusCode == 401 { throw ClientError.unauthorized }
        return (response.statusCode, data)
    }

    public func request<T: Decodable & Sendable>(_ type: T.Type, path: [String],
               query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil,
               authenticated: Bool = true, cachePolicy: LibraryCachePolicy? = nil) async throws -> T {
        let data = try await requestData(path, query: query, method: method, body: body, authenticated: authenticated, cachePolicy: cachePolicy)
        do { return try Wire.decoder().decode(type, from: data) }
        catch {
            if let cachePolicy, let url = try? server.endpoint(path, query: query) {
                await responseCache?.remove(url.absoluteString, policy: cachePolicy)
            }
            throw ClientError.invalidResponse
        }
    }

    public func systemInfo() async throws -> PublicSystemInfo {
        let info = try await request(PublicSystemInfo.self, path: ["System", "Info", "Public"], authenticated: false)
        guard let id = info.id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.invalidResponse
        }
        return info
    }

    public func login(username: String, password: String) async throws -> Session {
        struct Credentials: Encodable { var username: String; var pw: String }
        let result = try await request(LoginResponse.self, path: ["Users", "AuthenticateByName"], method: "POST",
            body: Wire.encoder().encode(Credentials(username: username, pw: password)), authenticated: false)
        return Session(server: server, viewer: result.user, token: result.accessToken, deviceID: identity.deviceID)
    }

    public func initiateQuickConnect() async throws -> QuickConnectState {
        try await request(QuickConnectState.self, path: ["QuickConnect", "Initiate"], method: "POST", authenticated: false)
    }
    public func quickConnectState(secret: String) async throws -> QuickConnectState {
        try await request(QuickConnectState.self, path: ["QuickConnect", "Connect"],
            query: [URLQueryItem(name: "secret", value: secret)], authenticated: false)
    }
    public func completeQuickConnect(secret: String) async throws -> Session {
        struct Secret: Encodable { var secret: String }
        let result = try await request(LoginResponse.self, path: ["Users", "AuthenticateWithQuickConnect"],
            method: "POST", body: Wire.encoder().encode(Secret(secret: secret)), authenticated: false)
        return Session(server: server, viewer: result.user, token: result.accessToken, deviceID: identity.deviceID)
    }
    public func currentViewer() async throws -> Viewer {
        try await request(Viewer.self, path: ["Users", "Me"])
    }
    public func authorizeQuickConnect(code: String) async throws -> Bool {
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw ClientError.invalidQuickConnectCode
        }
        // No userId override: authorize only the account owning this session.
        return try await request(Bool.self, path: ["QuickConnect", "Authorize"],
                                  query: [.init(name: "code", value: code)], method: "POST")
    }
    public func logout() async throws { _ = try await requestData(["Sessions", "Logout"], method: "POST") }

    /// The web dashboard gets a separate short-lived token via Quick Connect.
    /// Servers without Quick Connect still open an isolated, in-app sign-in page.
    public func adminWebSession() async throws -> AdminWebSession {
        guard let session, session.server == server else { throw ClientError.missingSession }
        let viewer = try await currentViewer()
        guard viewer.id == session.viewer.id, viewer.policy?.isAdministrator == true else { throw ClientError.forbidden }
        let info = try await systemInfo()
        guard let serverID = info.id else { throw ClientError.invalidResponse }
        let identity = ClientIdentity(deviceID: "zorofin-admin-" + UUID().uuidString,
                                      deviceName: "Zorofin in-app dashboard", version: self.identity.version)
        let browser = JellyfinClient(server: server, identity: identity, transport: transport)
        let manual = AdminWebSession(server: server, viewer: viewer, serverID: serverID, browserClient: nil)
        var issued: JellyfinClient?
        do {
            let challenge = try await browser.initiateQuickConnect()
            guard try await authorizeQuickConnect(code: challenge.code) else { return manual }
            let login = try await browser.completeQuickConnect(secret: challenge.secret)
            let authenticated = JellyfinClient(server: server, identity: identity, session: login, transport: transport)
            issued = authenticated
            let webViewer = try await authenticated.currentViewer()
            guard webViewer.id == viewer.id, webViewer.policy?.isAdministrator == true else { throw ClientError.forbidden }
            try Task.checkCancellation()
            return AdminWebSession(server: server, viewer: viewer, serverID: serverID, browserClient: authenticated)
        } catch {
            // Cancellation must still revoke an issued browser token; use a
            // separate cleanup task so the cancelled transport cannot skip it.
            if let issued { await Task { await AdminWebSession(server: server, viewer: viewer, serverID: serverID, browserClient: issued).close() }.value }
            try Task.checkCancellation()
            if error as? ClientError == .forbidden { throw ClientError.forbidden }
            return manual
        }
    }


    private func userQuery() throws -> [URLQueryItem] {
        guard let session else { throw ClientError.missingSession }
        return [URLQueryItem(name: "userId", value: session.viewer.id)]
    }
    public func items(type: String? = nil, search: String? = nil, start: Int = 0,
                      favorites: Bool = false, parentID: String? = nil,
                      options: LibraryBrowseOptions? = nil) async throws -> ItemPage {
        var query = try userQuery() + [
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "startIndex", value: String(max(0, start))),
            URLQueryItem(name: "fields", value: "Overview,Genres,MediaStreams"),
            URLQueryItem(name: "enableImageTypes", value: "Primary,Backdrop,Logo"),
            URLQueryItem(name: "imageTypeLimit", value: "1"),
            URLQueryItem(name: "includeItemTypes", value: type ?? "Movie,Series"),
            URLQueryItem(name: "sortBy", value: options?.sort.field ?? (search == nil ? "DateCreated,SortName" : "SortName")),
            URLQueryItem(name: "sortOrder", value: options?.sort.order ?? (search == nil ? "Descending" : "Ascending"))
        ]
        if let search { query.append(URLQueryItem(name: "searchTerm", value: String(search.prefix(256)))) }
        let filters = (favorites ? ["IsFavorite"] : []) + (options?.unwatched == true ? ["IsUnplayed"] : [])
        if !filters.isEmpty { query.append(.init(name: "filters", value: filters.joined(separator: ","))) }
        if let genre = options?.genre, !genre.isEmpty { query.append(.init(name: "genres", value: genre)) }
        if let parentID { query.append(URLQueryItem(name: "parentId", value: parentID)) }
        return try await request(ItemPage.self, path: ["Items"], query: query, cachePolicy: .library)
    }
    /// Viewer-scoped collection cards or direct members; no companion required.
    public func collectionPage(parentID: String? = nil, start: Int = 0) async throws -> ItemPage {
        if let parentID {
            guard try await item(parentID).type == "BoxSet" else { throw ClientError.invalidResponse }
        }
        var query = try userQuery() + [
            URLQueryItem(name: "includeItemTypes", value: parentID == nil ? "BoxSet" : "Movie,Series,BoxSet"),
            URLQueryItem(name: "recursive", value: parentID == nil ? "true" : "false"),
            URLQueryItem(name: "startIndex", value: String(max(0, min(start, 1_000_000)))),
            URLQueryItem(name: "limit", value: "48"),
            URLQueryItem(name: "sortBy", value: "SortName"),
            URLQueryItem(name: "sortOrder", value: "Ascending"),
            URLQueryItem(name: "enableTotalRecordCount", value: "true"),
            URLQueryItem(name: "fields", value: "Overview,Genres,MediaStreams"),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "excludeLocationTypes", value: "Virtual"),
            URLQueryItem(name: "isPlaceHolder", value: "false")
        ]
        if let parentID { query.append(URLQueryItem(name: "parentId", value: parentID)) }
        return try await request(ItemPage.self, path: ["Items"], query: query, cachePolicy: .library)
    }

    public func libraryGenres(type: String) async throws -> [String] {
        let page = try await request(ItemPage.self, path: ["Genres"], query: userQuery() + [
            .init(name: "includeItemTypes", value: type), .init(name: "recursive", value: "true")], cachePolicy: .library)
        return Array(Set(page.items.map(\.name))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    public func resume() async throws -> ItemPage {
        try await request(ItemPage.self, path: ["UserItems", "Resume"], query: userQuery() + [
            .init(name: "limit", value: "20"), .init(name: "mediaTypes", value: "Video"),
            .init(name: "fields", value: "Overview,MediaStreams"), .init(name: "imageTypeLimit", value: "1")], cachePolicy: .activity)
    }
    public func nextUp(seriesID: String? = nil, includeResumable: Bool = false) async throws -> ItemPage {
        var query = try userQuery() + [URLQueryItem(name: "limit", value: "20"), .init(name: "fields", value: "Overview,MediaStreams")]
        if let seriesID { query.append(.init(name: "seriesId", value: seriesID)) }
        if includeResumable { query.append(.init(name: "enableResumable", value: "true")) }
        return try await request(ItemPage.self, path: ["Shows", "NextUp"], query: query, cachePolicy: .activity)
    }
    public func item(_ id: String, fresh: Bool = false) async throws -> MediaItem {
        try await request(MediaItem.self, path: ["Items", id], query: userQuery(), cachePolicy: fresh ? nil : .detail)
    }
    public func seasons(seriesID: String) async throws -> ItemPage {
        try await request(ItemPage.self, path: ["Shows", seriesID, "Seasons"], query: userQuery() + [.init(name: "isMissing", value: "false")], cachePolicy: .library)
    }
    public func episodes(seriesID: String, seasonID: String, start: Int = 0) async throws -> ItemPage {
        try await request(ItemPage.self, path: ["Shows", seriesID, "Episodes"], query: userQuery() + [
            .init(name: "seasonId", value: seasonID), .init(name: "limit", value: "30"),
            .init(name: "startIndex", value: String(max(0, start))), .init(name: "fields", value: "Overview,MediaStreams"),
            .init(name: "isMissing", value: "false"), .init(name: "sortBy", value: "ParentIndexNumber,IndexNumber,SortName")], cachePolicy: .library)
    }
    public func similar(itemID: String) async throws -> ItemPage {
        try await request(ItemPage.self, path: ["Items", itemID, "Similar"], query: userQuery() + [.init(name: "limit", value: "12"), .init(name: "fields", value: "MediaStreams")], cachePolicy: .library)
    }
    public func channels(start: Int = 0) async throws -> ItemPage {
        try await request(ItemPage.self, path: ["LiveTv", "Channels"], query: userQuery() + [
            .init(name: "limit", value: "30"), .init(name: "startIndex", value: String(start)),
            .init(name: "addCurrentProgram", value: "true")], cachePolicy: .activity)
    }
    public func favorite(itemID: String, value: Bool) async throws -> UserData {
        let result = try await request(UserData.self, path: ["UserFavoriteItems", itemID], query: userQuery(), method: value ? "POST" : "DELETE")
        await responseCache?.invalidateMetadata()
        return result
    }
    public func played(itemID: String, value: Bool) async throws -> UserData {
        let result = try await request(UserData.self, path: ["UserPlayedItems", itemID], query: userQuery(), method: value ? "POST" : "DELETE")
        await responseCache?.invalidateMetadata()
        return result
    }
    /// Optional same-server assets. No session header or cookie is sent to static resources.
    /// Keep API path-component validation strict; static filenames have their own allowlist.
    func liveResourceData(_ filename: String) async throws -> Data {
        guard let session else { throw ClientError.missingSession }
        guard session.server == server,
              filename == "events.json" || LiveEventArtwork.isSafePath("/live-tv-logos/art/" + filename) else { throw ClientError.unsafeURL }
        let url = server.url.appendingPathComponent("live-tv-logos/art").appendingPathComponent(filename)
        guard server.contains(url) else { throw ClientError.unsafeURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = filename == "events.json" ? 4 : 8
        request.setValue(filename == "events.json" ? "application/json" : "image/jpeg,image/png,image/webp", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw ClientError.unavailable(response.statusCode) }
        return data
    }
    public func homeCrestData(path: String) async throws -> Data {
        guard HomeRowCard.validCrest(path), session?.server == server else { throw ClientError.unsafeURL }
        let url = try server.endpoint(path.split(separator: "/").map(String.init))
        let fetch: @Sendable () async throws -> Data = {
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            request.timeoutInterval = 8
            let (data, response) = try await self.transport.send(request)
            guard response.statusCode == 200 else { throw ClientError.unavailable(response.statusCode) }
            return data
        }
        if let responseCache { return try await responseCache.value(url.absoluteString, policy: .homeCrest, fetch: fetch) }
        return try await fetch()
    }
    public func image(itemID: String, kind: String = "Primary", tag: String? = nil, width: Int) async throws -> Data {
        var query = [URLQueryItem(name: "maxWidth", value: String(min(1920, max(80, width)))),
                     .init(name: "quality", value: "85")]
        if let tag { query.append(.init(name: "tag", value: tag)) }
        return try await requestData(["Items", itemID, "Images", kind], query: query, accept: "image/jpeg,image/png,image/webp", cachePolicy: tag == nil ? nil : .artwork)
    }
}
