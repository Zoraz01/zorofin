import Foundation

/// Where Requests lives on a server. `requests` version 1 in the capability manifest means the
/// older Jellyfin Enhanced proxy; version 2 means the Zorofin plugin's own routes. Both return the
/// same shapes, so only the paths differ.
public enum RequestRoutes: Sendable, Equatable {
    case enhanced
    case zorofin

    public enum Route: Sendable, Equatable {
        case userStatus, configuration, quota, seasonSettings, submit, activity, queue, search
        case discover([String])
        case title(RequestKind, Int)
    }

    public init?(manifestVersion: Int) {
        switch manifestVersion {
        case 1: self = .enhanced
        case 2: self = .zorofin
        default: return nil
        }
    }

    public func path(_ route: Route) -> [String] {
        switch self {
        case .enhanced:
            let seerr = ["JellyfinEnhanced", "jellyseerr"]
            switch route {
            case .userStatus: return seerr + ["user-status"]
            case .configuration: return ["JellyfinEnhanced", "public-config"]
            case .quota: return seerr + ["quota"]
            case .seasonSettings: return seerr + ["settings", "partial-requests"]
            case .submit: return seerr + ["request"]
            case .activity: return ["JellyfinEnhanced", "arr", "requests"]
            case .queue: return ["JellyfinEnhanced", "arr", "queue"]
            case .search: return seerr + ["search"]
            case .discover(let rest): return seerr + ["discover"] + rest
            case .title(let kind, let id): return seerr + [kind.rawValue, String(id)]
            }
        case .zorofin:
            let base = ["Zorofin", "Requests"]
            switch route {
            case .userStatus: return base + ["user-status"]
            case .configuration: return base + ["config"]
            case .quota: return base + ["quota"]
            case .seasonSettings: return base + ["settings", "partial-requests"]
            case .submit: return base + ["request"]
            case .activity: return base + ["activity"]
            case .queue: return base + ["queue"]
            case .search: return base + ["search"]
            case .discover(let rest): return base + ["discover"] + rest
            case .title(let kind, let id): return base + [kind.rawValue, String(id)]
            }
        }
    }

    /// Routes found by the last feature discovery for each server and viewer. Before discovery, or on a
    /// server without the plugin, Requests keeps using the Jellyfin Enhanced paths.
    static func current(server: ServerAddress, viewer: String?) -> RequestRoutes {
        registry.withLock { $0[key(server, viewer)] } ?? .enhanced
    }

    static func remember(_ routes: RequestRoutes?, server: ServerAddress, viewer: String?) {
        registry.withLock { $0[key(server, viewer)] = routes }
    }

    private static func key(_ server: ServerAddress, _ viewer: String?) -> String {
        server.url.absoluteString + "\n" + (viewer ?? "")
    }

    private static let registry = Locked<[String: RequestRoutes]>([:])
}

/// A small lock around a value, for state shared across tasks.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

extension JellyfinClient {
    /// The Requests routes for this client's server and signed-in viewer.
    public var requestRoutes: RequestRoutes { RequestRoutes.current(server: server, viewer: session?.viewer.id) }
}
