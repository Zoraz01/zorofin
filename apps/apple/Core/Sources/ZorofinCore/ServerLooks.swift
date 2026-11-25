import Foundation
import CryptoKit

/// The server's look for every viewer (companion `looks.json`, through the
/// plugin at `/Zorofin/Web/ui/looks.json`): one accent colour and one card
/// size. The web look uses the same file. With `enforced` (the Dashboard's
/// "Same look for every viewer"), the apps hide their own poster size setting;
/// without it, the server's card size is only the starting point.
public struct ServerLooks: Codable, Equatable, Sendable {
    public static let cardSizes: [String: Double] = ["compact": 0.85, "standard": 1.0, "large": 1.2]
    /// The web look's own Zorofin green preset.
    public static let zorofinWeb: UInt32 = 0x42d779

    /// `0xRRGGBB`, already made readable; nil keeps the apps' own Zorofin green.
    public var accent: UInt32?
    /// `compact`, `standard` or `large`.
    public var cardSize: String
    public var enforced: Bool

    public init(accent: UInt32? = nil, cardSize: String = "standard", enforced: Bool = true) {
        self.accent = accent; self.cardSize = cardSize; self.enforced = enforced
    }

    /// The apps' poster size step for `cardSize`.
    public var posterScale: Double { Self.cardSizes[cardSize] ?? 1.0 }

    /// Nil when the answer isn't a version 1 looks file.
    public static func decode(_ data: Data) -> ServerLooks? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["version"] as? Int == 1 else { return nil }
        var accent: UInt32?
        if json["colors"] as? String != "zorofin", let hex = json["accent"] as? String,
           hex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
           let value = UInt32(hex.dropFirst(), radix: 16), value != zorofinWeb {
            // Zorofin green on the server is the apps' own green, as on the web.
            accent = readableAccent(value)
        }
        let size = json["cardSize"] as? String
        return ServerLooks(accent: accent,
            cardSize: size.flatMap { cardSizes[$0] == nil ? nil : $0 } ?? "standard",
            enforced: json["enforced"] as? Bool != false)
    }

    /// An accent stays readable: on the dark panels, and under the dark label
    /// of a primary button (4.5:1 against the background needs a luminance of
    /// about 0.22). One that is too dark is lightened, keeping its hue.
    public static func readableAccent(_ rgb: UInt32) -> UInt32 {
        var (hue, saturation, lightness) = hsl(rgb)
        var out = rgb
        while luminance(out) < 0.22 && lightness < 0.95 {
            lightness = min(lightness + 0.04, 0.95)
            out = fromHSL(hue, saturation, lightness)
        }
        return out
    }

    static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((rgb >> shift) & 0xff) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private static func hsl(_ rgb: UInt32) -> (Double, Double, Double) {
        let r = Double((rgb >> 16) & 0xff) / 255, g = Double((rgb >> 8) & 0xff) / 255, b = Double(rgb & 0xff) / 255
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        let lightness = (high + low) / 2
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch high {
        case r: hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        case g: hue = 60 * ((b - r) / delta + 2)
        default: hue = 60 * ((r - g) / delta + 4)
        }
        if hue < 0 { hue += 360 }
        return (hue, saturation, lightness)
    }

    private static func fromHSL(_ hue: Double, _ saturation: Double, _ lightness: Double) -> UInt32 {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let x = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - chroma / 2
        let (r, g, b): (Double, Double, Double) = switch hue {
        case ..<60: (chroma, x, 0)
        case ..<120: (x, chroma, 0)
        case ..<180: (0, chroma, x)
        case ..<240: (0, x, chroma)
        case ..<300: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        func byte(_ value: Double) -> UInt32 { UInt32(max(0, min(255, ((value + m) * 255).rounded()))) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}

/// The last looks each server sent, so the first frame after launch already
/// has them. Looks are server-wide, so one entry per server.
public struct ServerLooksCache: Sendable {
    private static let prefix = "ZorofinLooks-v1."
    private let suiteName: String?
    public static let standard = ServerLooksCache(suiteName: nil)
    public init(suiteName: String?) { self.suiteName = suiteName }
    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }
    private func key(_ server: ServerAddress) -> String {
        Self.prefix + SHA256.hash(data: Data(server.storageKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func load(_ server: ServerAddress) -> ServerLooks? {
        defaults.data(forKey: key(server)).flatMap { try? JSONDecoder().decode(ServerLooks.self, from: $0) }
    }
    public func save(_ looks: ServerLooks?, server: ServerAddress) {
        if let looks, let data = try? JSONEncoder().encode(looks) { defaults.set(data, forKey: key(server)) }
        else { defaults.removeObject(forKey: key(server)) }
    }
}

extension JellyfinClient {
    /// The server's looks, or nil for a server without them (older companion,
    /// no plugin, or the web look turned off).
    public func serverLooks() async throws -> ServerLooks? {
        do {
            return ServerLooks.decode(try await requestData(["Zorofin", "Web", "ui", "looks.json"], expectedStatus: 200))
        } catch let error as ClientError {
            switch error {
            case .unavailable(404), .unavailable(405), .forbidden: return nil
            default: throw error
            }
        }
    }
}
