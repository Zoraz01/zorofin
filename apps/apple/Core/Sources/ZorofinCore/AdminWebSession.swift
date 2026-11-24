import Foundation

extension ServerAddress {
    /// A credential-free web UI address. Never copy an app token into a URL.
    /// An embedded admin view may establish a separate session; external browsers
    /// select their own signed-in account.
    public func dashboardWebURL() throws -> URL {
        let web = try endpoint(["web"])
        guard var parts = URLComponents(url: web, resolvingAgainstBaseURL: false) else { throw ClientError.unsafeURL }
        parts.path += "/"
        parts.fragment = "/dashboard"
        guard let result = parts.url, result.host == url.host else { throw ClientError.unsafeURL }
        return result
    }
}


/// An in-memory browser login scoped to the chosen server and account. The native
/// token is never exported to WebKit. Closing this lease revokes only its own token.
public struct AdminWebSession: Sendable {
    public let server: ServerAddress
    public let viewer: Viewer
    public let serverID: String
    public let browserClient: JellyfinClient?
    public var requiresSignIn: Bool { browserClient == nil }

    init(server: ServerAddress, viewer: Viewer, serverID: String, browserClient: JellyfinClient?) {
        self.server = server; self.viewer = viewer; self.serverID = serverID; self.browserClient = browserClient
    }
    public func close() async { try? await browserClient?.logout() }

    /// Hash routes are local navigation; strip them before applying the existing
    /// origin, port, base-path, traversal and user-info protections.
    public func permitsNavigation(to url: URL) -> Bool {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return false }
        let sensitive = Set(["apikey", "api_key", "x-emby-token", "token", "access_token"])
        guard !(parts.queryItems ?? []).contains(where: { sensitive.contains($0.name.lowercased()) }) else { return false }
        parts.fragment = nil
        return parts.url.map(server.contains) == true
    }

    /// Matches Jellyfin Web's credential-provider contract. This runs once, only
    /// in the selected server's main web frame and an ephemeral WebKit store.
    public func bootstrapScript() throws -> String? {
        guard let client = browserClient, let session = client.session else { return nil }
        guard client.server == server, session.server == server, session.viewer.id == viewer.id,
              !session.token.isEmpty, !serverID.isEmpty else { throw ClientError.unsafeURL }
        let web = try server.endpoint(["web"])
        guard var origin = URLComponents(url: server.url, resolvingAgainstBaseURL: false) else { throw ClientError.unsafeURL }
        origin.path = ""; origin.query = nil; origin.fragment = nil
        if (origin.scheme == "https" && origin.port == 443) || (origin.scheme == "http" && origin.port == 80) { origin.port = nil }
        guard let originURL = origin.url else { throw ClientError.unsafeURL }
        // Jellyfin Web appends /System/... directly; its saved address must not end in /.
        let address = server.url.absoluteString.hasSuffix("/") ? String(server.url.absoluteString.dropLast()) : server.url.absoluteString
        let payload: [String: Any] = [
            "origin": originURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            "webPath": (URLComponents(url: web, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? web.path) + "/", "deviceID": client.identity.deviceID,
            "credentials": ["Servers": [["Id": serverID, "Name": "Jellyfin",
                "ManualAddress": address, "manualAddressOnly": true,
                "LastConnectionMode": 2, "UserId": viewer.id, "AccessToken": session.token,
                "DateLastAccessed": Date().timeIntervalSince1970 * 1000]]]
        ]
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .fragmentsAllowed])
        // Base64 avoids script delimiters, quotes and Unicode line separators in
        // server names/URLs/IDs. No credentials enter a URL or message handler.
        let encoded = json.base64EncodedString()
        return """
        (() => {
          const p = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'), c => c.charCodeAt(0))));
          if (window.top !== window || location.origin !== p.origin || !location.pathname.startsWith(p.webPath)) return;
          if (sessionStorage.getItem('zorofin-admin-initialized') === '1') return;
          localStorage.setItem('jellyfin_credentials', JSON.stringify(p.credentials));
          localStorage.setItem('_deviceId2', p.deviceID);
          sessionStorage.setItem('zorofin-admin-initialized', '1');
        })();
        """
    }
}
