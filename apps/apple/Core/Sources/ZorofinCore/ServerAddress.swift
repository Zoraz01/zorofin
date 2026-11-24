import Foundation

public enum ClientError: Error, LocalizedError, Equatable, Sendable {
    case invalidServer, insecureServer, unsafeURL, invalidResponse, unauthorized, forbidden
    case unavailable(Int), network, unsupportedPlayback, missingSession, responseTooLarge, invalidQuickConnectCode

    public var errorDescription: String? {
        switch self {
        case .invalidServer: "Enter the server address, such as media.example.com or 192.168.1.20:8096, plus any base path."
        case .insecureServer: "Use HTTPS, or explicitly allow HTTP for a local server."
        case .unsafeURL: "The server returned a resource outside its configured address."
        case .invalidResponse: "The server returned an unexpected response."
        case .unauthorized: "Your session expired. Please sign in again."
        case .forbidden: "Your account does not have permission for this action."
        case .unavailable(let status): "The server is unavailable (HTTP \(status)). Try again."
        case .network: "Could not reach the server. Check your connection and try again."
        case .unsupportedPlayback: "This title needs a compatible stream. Check the server's transcoding settings."
        case .missingSession: "Sign in to your server to continue."
        case .responseTooLarge: "The server response was too large. Try a smaller selection."
        case .invalidQuickConnectCode: "Enter the six-digit Quick Connect code shown on your other device."
        }
    }
}

public struct ServerAddress: Hashable, Codable, Sendable {
    public let url: URL
    public let allowsLocalHTTP: Bool

    public enum InputScheme: String, CaseIterable, Sendable {
        case https, http
    }

    /// A full URL takes precedence over the scheme selected for a bare address.
    public static func fromUserInput(_ input: String, defaultScheme: InputScheme = .https,
                                     allowsLocalHTTP: Bool = false) throws -> ServerAddress {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClientError.invalidServer }
        return try ServerAddress(text.contains("://") ? text : defaultScheme.rawValue + "://" + text, allowsLocalHTTP: allowsLocalHTTP)
    }

    /// Addresses to try, in order, for what the user typed.
    ///
    /// A bare local-network address with HTTPS selected (for example `192.168.1.20:8096`)
    /// also yields an HTTP fallback, because Jellyfin's default port serves plain HTTP.
    /// Callers try the fallback only after the HTTPS attempt fails to connect. Public
    /// hosts, typed schemes and an explicitly selected HTTP scheme never gain a fallback.
    public static func connectionCandidates(_ input: String, defaultScheme: InputScheme = .https,
                                            allowsLocalHTTP: Bool = false) throws -> [ServerAddress] {
        let primary = try fromUserInput(input, defaultScheme: defaultScheme, allowsLocalHTTP: allowsLocalHTTP)
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("://"), defaultScheme == .https,
              let host = primary.url.host, isLocalHost(host),
              let fallback = try? ServerAddress("http://" + text, allowsLocalHTTP: true)
        else { return [primary] }
        return [primary, fallback]
    }

    public init(_ input: String, allowsLocalHTTP: Bool = false) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text),
              let host = parts.host, !host.isEmpty,
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              Self.isSafePath(parts.percentEncodedPath),
              parts.port.map({ (1...65535).contains($0) }) ?? true
        else { throw ClientError.invalidServer }
        guard scheme == "https" || (allowsLocalHTTP && Self.isLocalHost(host)) else {
            throw ClientError.insecureServer
        }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = parts.path.isEmpty ? "/" : "/" + parts.path + "/"
        guard let url = parts.url else { throw ClientError.invalidServer }
        self.url = url
        self.allowsLocalHTTP = allowsLocalHTTP
    }

    /// scheme://host[:port], as browsers send it in an Origin header.
    public var origin: String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme, let host = parts.host else { return nil }
        let defaultPort = (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80)
        return scheme + "://" + host + (parts.port.map { defaultPort ? "" : ":\($0)" } ?? "")
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(values.decode(URL.self, forKey: .url).absoluteString,
                      allowsLocalHTTP: values.decode(Bool.self, forKey: .allowsLocalHTTP))
    }

    public func endpoint(_ path: [String], query: [URLQueryItem] = []) throws -> URL {
        var target = url
        for component in path {
            guard !component.isEmpty, component != ".", component != "..",
                  component.rangeOfCharacter(from: CharacterSet.alphanumerics
                    .union(CharacterSet(charactersIn: "-_" )).inverted) == nil
            else { throw ClientError.unsafeURL }
            target.appendPathComponent(component)
        }
        guard var parts = URLComponents(url: target, resolvingAgainstBaseURL: true) else {
            throw ClientError.unsafeURL
        }
        parts.queryItems = query.isEmpty ? nil : query
        guard let result = parts.url else { throw ClientError.unsafeURL }
        return result
    }

    /// Scope all credential-bearing API, image and initial media requests to this server.
    public func contains(_ candidate: URL) -> Bool {
        guard let a = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let b = URLComponents(url: candidate, resolvingAgainstBaseURL: true),
              a.scheme?.lowercased() == b.scheme?.lowercased(),
              a.host?.lowercased() == b.host?.lowercased(),
              (a.port ?? (a.scheme == "https" ? 443 : 80)) ==
                (b.port ?? (b.scheme == "https" ? 443 : 80)),
              b.user == nil, b.password == nil, b.fragment == nil,
              Self.isSafePath(b.percentEncodedPath) else { return false }
        return b.path.hasPrefix(a.path)
    }

    public func mediaURL(_ reference: String, token: String) throws -> URL {
        guard !reference.contains("\\"), let target = URL(string: reference, relativeTo: url)?.absoluteURL,
              contains(target), var parts = URLComponents(url: target, resolvingAgainstBaseURL: true)
        else { throw ClientError.unsafeURL }
        let forbidden = Set(["apikey", "api_key", "x-emby-token", "token", "access_token"])
        parts.queryItems = (parts.queryItems ?? []).filter { !forbidden.contains($0.name.lowercased()) }
        parts.queryItems?.append(URLQueryItem(name: "ApiKey", value: token))
        guard let result = parts.url else { throw ClientError.unsafeURL }
        return result
    }

    private static func isSafePath(_ path: String) -> Bool {
        var decoded = path
        for _ in 0..<3 {
            guard !decoded.contains("\\"), !decoded.unicodeScalars.contains(where: { $0.value < 32 }),
                  !decoded.split(separator: "/", omittingEmptySubsequences: false)
                    .contains(where: { $0 == "." || $0 == ".." }) else { return false }
            let next = decoded.removingPercentEncoding ?? decoded
            if next == decoded { return true }
            decoded = next
        }
        return !decoded.contains("%")
    }

    /// Loopback, mDNS and private-network hosts: RFC 1918, carrier-grade NAT (used by
    /// Tailscale), IPv4/IPv6 link-local and IPv6 unique local addresses.
    static func isLocalHost(_ value: String) -> Bool {
        var host = value.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        if host.contains(":") { return isLocalIPv6(host) }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = components.compactMap { Int($0) }
        guard components.count == 4, octets.count == 4,
              components.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 10 || octets[0] == 127 ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 169 && octets[1] == 254) ||
            (octets[0] == 100 && (64...127).contains(octets[1]))
    }

    private static func isLocalIPv6(_ host: String) -> Bool {
        let address = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        let hex = CharacterSet(charactersIn: "0123456789abcdef:.")
        guard !address.isEmpty, address.unicodeScalars.allSatisfy({ hex.contains($0) }),
              address.filter({ $0 == ":" }).count >= 2,
              let first = address.split(separator: ":", omittingEmptySubsequences: false).first,
              first.count <= 4, let value = Int(first.isEmpty ? "0" : first, radix: 16)
        else { return false }
        // fc00::/7 unique local, fe80::/10 link-local.
        return (value & 0xfe00) == 0xfc00 || (value & 0xffc0) == 0xfe80
    }
}
