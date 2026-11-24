import SwiftUI
import ZorofinCore

enum Theme {
    static let background = Color(hex: 0x111513)
    static let panel = Color(hex: 0x1b211e)
    static let border = Color(hex: 0x39423c)
    static let text = Color(hex: 0xf5f7f5)
    static let muted = Color(hex: 0xbbc5bd)
    static let jade = Color(hex: 0x72e79b)
    static let play = Color(hex: 0x1cb956)
    static let avatar = Color(hex: 0x24543e)
    static var isTV: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }
    static var gutter: CGFloat { isTV ? 48 : 16 }
    static var target: CGFloat { isTV ? 60 : 48 }
    static func font(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("InterVariable", size: size, relativeTo: style).weight(weight)
    }
}

private struct NavigationDockClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}
extension EnvironmentValues {
    @Entry var adaptiveWindow = AdaptiveWindow(width: 0, height: 0)
    var navigationDockClearance: CGFloat {
        get { self[NavigationDockClearanceKey.self] }
        set { self[NavigationDockClearanceKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}

struct Brand: View {
    var symbolOnly = false
    private static let wordmark = UIImage(contentsOfFile: Bundle.main.path(forResource: "wordmark", ofType: "png") ?? "") ?? UIImage()
    var body: some View {
        Group {
            if symbolOnly {
                Image("HeaderLogo").renderingMode(.original).resizable().scaledToFit()
                    .frame(width: 48, height: 48)
            } else {
                Image(uiImage: Self.wordmark).renderingMode(.original).resizable().scaledToFit()
                    .frame(width: Theme.isTV ? 196 : 160, height: Theme.isTV ? 48 : 38)
            }
        }.accessibilityLabel("Zorofin")
    }
}

struct Avatar: View {
    var initial: String
    var size: CGFloat = 40
    var body: some View {
        Text(initial).font(Theme.font(size * 0.52, weight: .medium))
            .foregroundStyle(Color(hex: 0xe6ffef))
            .frame(width: size, height: size).background(Theme.avatar, in: Circle())
            .overlay(Circle().stroke(Theme.jade.opacity(0.35), lineWidth: 1))
    }
}

/// Each saved viewer loads their own photo with their own server-bound session.
/// No active-account token is reused for another account or origin.
struct SavedAccountAvatar: View {
    @Environment(AppModel.self) private var model
    let account: SavedAccount
    let size: CGFloat
    @State private var photo: UIImage?
    var body: some View {
        Group {
            if let image = model.isCurrent(account) ? model.profileImage ?? photo : photo {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String(account.viewer.name.prefix(1)).uppercased())
                    .font(Theme.font(size * 0.48, weight: .bold)).foregroundStyle(Theme.text)
            }
        }.frame(width: size, height: size).background(Theme.avatar)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22)).accessibilityHidden(true)
            .task(id: account.id) {
                guard let session = account.session, !model.isDemo else { return }
                if model.isCurrent(account), model.profileImage != nil { return }
                let client = JellyfinClient(server: account.server,
                    identity: .init(deviceID: session.deviceID, deviceName: model.deviceName), session: session)
                guard let data = try? await client.ownProfileImage(), !Task.isCancelled else { return }
                photo = UIImage(data: data)
            }
    }
}

struct ZoroButtonStyle: ButtonStyle {
    var primary = false
    var white = false
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeReduceMotion) private var appReduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(Theme.isTV ? 22 : 16, weight: .semibold))
            .foregroundStyle(primary || white ? Theme.background : Theme.text)
            .padding(.horizontal, Theme.isTV ? 28 : 20)
            .frame(minHeight: Theme.target)
            .background(white ? Theme.text : primary ? Theme.play : Theme.panel, in: Capsule())
            .overlay(Capsule().stroke(focused ? Color.white : Theme.border, lineWidth: focused ? 3 : 1))
            .scaleEffect(configuration.isPressed ? 0.97 : focused ? 1.04 : 1)
            .animation(reduceMotion || appReduceMotion ? nil : .easeOut(duration: 0.14), value: focused)
    }
}

struct ArtworkButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeReduceMotion) private var appReduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(focused ? Color.white : .clear, lineWidth: 4))
            .scaleEffect(configuration.isPressed ? 0.98 : focused ? 1.045 : 1)
            .animation(reduceMotion || appReduceMotion ? nil : .easeOut(duration: 0.14), value: focused)
    }
}

/// Shared navigation timing; screen movement stays quieter than the controls.
enum NavigationMotion {
    static let selection = Animation.spring(duration: 0.38, bounce: 0.24)
    static let icon = Animation.spring(duration: 0.32, bounce: 0.30)
    static let focus = Animation.spring(duration: 0.30, bounce: 0.20)
    static let press = Animation.easeOut(duration: 0.09)
    static let release = Animation.spring(duration: 0.34, bounce: 0.28)
    static let screen = Animation.spring(duration: 0.28, bounce: 0.08)
}

/// Scoped to shell navigation so artwork and playback controls keep their behavior.
struct NavigationButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeReduceMotion) private var appReduceMotion
    private var reduced: Bool { reduceMotion || appReduceMotion }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Capsule())
            .background(Theme.text.opacity(Theme.isTV && focused ? 0.08 : 0), in: Capsule())
            .overlay {
                // A dark gap keeps the focus ring distinct even on the white selected pill.
                Capsule().strokeBorder(Theme.isTV && focused ? Theme.jade : .clear, lineWidth: 3)
                    .padding(-6)
            }
            // Reduce Motion removes spatial feedback, but keeps press/focus visible.
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(reduced ? 1 : configuration.isPressed ? (Theme.isTV ? 0.97 : 0.92) : focused && Theme.isTV ? 1.06 : 1)
            .offset(y: !reduced && Theme.isTV && focused && !configuration.isPressed ? -2 : 0)
            .animation(reduced ? nil : NavigationMotion.focus, value: focused)
            .animation(reduced ? nil : configuration.isPressed ? NavigationMotion.press : NavigationMotion.release,
                       value: configuration.isPressed)
    }
}

struct SectionTitle: View {
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.jade).frame(width: 4, height: Theme.isTV ? 30 : 21)
            Text(title).font(Theme.font(Theme.isTV ? 30 : 22, weight: .bold, relativeTo: .title2))
            Spacer()
        }.foregroundStyle(Theme.text)
    }
}

/// Support uses the same microphone-headset vector as the web toolbar.
/// Other interface glyphs retain their existing SF Symbol size and styling.
struct InterfaceIcon: View {
    let name: String
    let size: CGFloat
    var body: some View {
        Group {
            if name == "support" {
                Image("Support").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: name).font(.system(size: size))
            }
        }
    }
}

struct StatusView: View {
    let title: String
    let detail: String
    var icon = "film"
    var retry: (() -> Void)?
    var body: some View {
        VStack(spacing: 16) {
            InterfaceIcon(name: icon, size: Theme.isTV ? 48 : 32).foregroundStyle(Theme.jade)
            Text(title).font(Theme.font(Theme.isTV ? 32 : 22, weight: .semibold)).multilineTextAlignment(.center)
            Text(detail).font(Theme.font(Theme.isTV ? 22 : 16)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            if let retry { Button("Try again", action: retry).buttonStyle(ZoroButtonStyle()) }
        }.padding(32).frame(maxWidth: 720).frame(maxWidth: .infinity)
    }
}

struct MediaArtwork: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    var landscape = false
    var width = 640
    var showPreviewTitle = true
    @State private var image: UIImage?
    private var source: (String, String, String?) {
        // An episode's Primary is its own still; inherited show backdrops are fallback art.
        if item.isEpisode {
            for kind in ["Primary", "Thumb"] {
                if let tag = item.imageTags?[kind], !tag.isEmpty { return (item.id, kind, tag) }
            }
        }
        if landscape, let tag = item.backdropImageTags?.first { return (item.id, "Backdrop", tag) }
        if landscape, let id = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first { return (id, "Backdrop", tag) }
        return (item.id, "Primary", item.imageTags?["Primary"])
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { PreviewArtwork(title: item.displayTitle, seed: item.id, showTitle: model.isDemo && showPreviewTitle) }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .accessibilityHidden(true)
        .task(id: "\(model.generation)-\(source.0)-\(source.1)-\(source.2 ?? "")-\(width)") {
            image = nil
            guard let client = model.client, source.2 != nil else { return }
            let cache = model.imageCache
            let key = "\(source.0)-\(source.1)-\(source.2 ?? "")-\(width)"
            do {
                let thumbnail = try await cache.image(key: key, client: client,
                    itemID: source.0, kind: source.1, tag: source.2, width: width)
                try Task.checkCancellation()
                image = thumbnail
            } catch { /* Artwork failure never prevents browsing. */ }
        }
        .onDisappear { image = nil }
    }
}

/// Fictional preview art is rendered locally; no real library/account data or
/// third-party poster downloads are needed to inspect the interface.
struct PreviewArtwork: View {
    let title: String
    let seed: String
    var showTitle = true
    private var hue: Double { Double(seed.utf8.reduce(0) { $0 + Int($1) } % 90) / 100 + 0.1 }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.45), Color(hex: 0x102421), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(Color(hue: hue + 0.08, saturation: 0.25, brightness: 0.9).opacity(0.7))
                    .frame(width: geometry.size.width * 0.46).offset(x: geometry.size.width * 0.2, y: -geometry.size.height * 0.16)
                Path { path in
                    let w = geometry.size.width, h = geometry.size.height
                    path.move(to: CGPoint(x: 0, y: h * 0.78)); path.addLine(to: CGPoint(x: w * 0.4, y: h * 0.35))
                    path.addLine(to: CGPoint(x: w, y: h * 0.88)); path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h)); path.closeSubpath()
                }.fill(Color.black.opacity(0.4))
                if showTitle {
                    VStack { Spacer(); Text(title.uppercased()).font(Theme.font(min(geometry.size.width * 0.11, 34), weight: .bold))
                        .tracking(2).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.9)); Spacer().frame(height: geometry.size.height * 0.18) }
                        .padding(16)
                }
            }.clipped()
        }
    }
}

private struct NativeReduceMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var nativeReduceMotion: Bool {
        get { self[NativeReduceMotionKey.self] }
        set { self[NativeReduceMotionKey.self] = newValue }
    }
}
struct NativeMotionPreference: ViewModifier {
    let reduce: Bool
    func body(content: Content) -> some View { content.environment(\.nativeReduceMotion, reduce) }
}

/// Small visual controls, with a full 48-point touch / 60-point TV focus target.
struct DetailIconStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeReduceMotion) private var appReduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Theme.isTV ? 26 : 21, weight: .medium))
            .frame(width: Theme.target, height: Theme.target)
            .background(Theme.panel, in: Circle())
            .overlay(Circle().stroke(focused ? Color.white : Theme.border, lineWidth: focused ? 3 : 1))
            .contentShape(Circle()).opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.94 : focused ? 1.08 : 1)
            .animation(reduceMotion || appReduceMotion ? nil : .easeOut(duration: 0.14), value: focused)
    }
}

/// Wrap metadata and compact actions without shrinking text or touch targets.
struct DetailWrapLayout: Layout {
    var spacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (CGSize, [CGPoint], [CGSize]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var origins: [CGPoint] = [], sizes: [CGSize] = []
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y)); sizes.append(size)
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        if alignment == .center {
            // Center each line, including an incomplete final line. Centering
            // only the outer frame leaves wrapped controls pinned to the left.
            var first = 0
            while first < origins.count {
                var end = first + 1
                while end < origins.count && origins[end].y == origins[first].y { end += 1 }
                let rowWidth = origins[end - 1].x + sizes[end - 1].width
                let offset = max(0, (usedWidth - rowWidth) / 2)
                for index in first..<end { origins[index].x += offset }
                first = end
            }
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), origins, sizes)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: max(1, proposal.width ?? 760)).0
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (_, origins, sizes) = arrange(subviews, width: max(1, bounds.width))
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + origins[index].x, y: bounds.minY + origins[index].y),
                anchor: .topLeading, proposal: ProposedViewSize(sizes[index]))
        }
    }
}

struct DetailControlStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeReduceMotion) private var appReduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.text)
            .padding(Theme.isTV ? 18 : 12)
            .frame(maxWidth: .infinity, minHeight: Theme.target)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(focused ? Color.white : Theme.border, lineWidth: focused ? 3 : 1))
            .opacity(enabled ? 1 : 0.6)
            .scaleEffect(configuration.isPressed ? 0.98 : focused ? 1.02 : 1)
            .animation(reduceMotion || appReduceMotion ? nil : .easeOut(duration: 0.14), value: focused)
    }
}

/// Flat options keep selection and tvOS focus visually separate.
struct FlatOptionStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(Theme.isTV ? 23 : 16))
            .frame(minHeight: Theme.target)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(Theme.text.opacity(focused ? 0.09 : configuration.isPressed ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Theme.jade : .clear, lineWidth: 2))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
