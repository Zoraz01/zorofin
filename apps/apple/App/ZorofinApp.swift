import SwiftUI
import ZorofinCore

#if os(iOS)
import UIKit

/// The plist declares every orientation playback can use. Narrow that set at
/// runtime for iPhone browsing; iPad keeps its normal rotation/multitasking.
@MainActor final class ZorofinAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Background download sessions must exist before the system delivers results.
        DownloadManager.activate()
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.backgroundCompletions[identifier] = completionHandler
        DownloadManager.activate()
    }
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        let idiom = window?.traitCollection.userInterfaceIdiom ?? UIDevice.current.userInterfaceIdiom
        guard idiom == .phone else { return .all }
        guard let window else { return .portrait }
        return (PhonePlaybackOrientation.owners.object(forKey: window)?.count ?? 0) > 0 ? .allButUpsideDown : .portrait
    }
}

/// A lease on the player's actual window avoids changing other scenes and
/// remains active while audio, subtitles or episode options cover the player.
struct PhonePlaybackOrientation: UIViewRepresentable {
    static let owners = NSMapTable<UIWindow, NSMutableSet>.weakToStrongObjects()

    func makeUIView(context: Context) -> RotationLeaseView { RotationLeaseView() }
    func updateUIView(_ uiView: RotationLeaseView, context: Context) {}
    static func dismantleUIView(_ uiView: RotationLeaseView, coordinator: ()) { uiView.releaseWindow() }

    final class RotationLeaseView: UIView {
        private let owner = UUID()
        private weak var playbackWindow: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window !== playbackWindow else { return }
            releaseWindow()
            guard let window, window.traitCollection.userInterfaceIdiom == .phone else { return }
            playbackWindow = window
            let leases = owners.object(forKey: window) ?? NSMutableSet()
            leases.add(owner)
            owners.setObject(leases, forKey: window)
            updateRotation(in: window)
        }

        func releaseWindow() {
            guard let window = playbackWindow else { return }
            playbackWindow = nil
            let leases = owners.object(forKey: window)
            leases?.remove(owner)
            guard (leases?.count ?? 0) == 0 else { return }
            owners.removeObject(forKey: window)
            updateRotation(in: window)
        }

        private func updateRotation(in window: UIWindow) {
            // A lease can move during full-screen presentation or dismissal.
            // Finish that transition before requesting another geometry change,
            // then derive the policy from the window's current leases.
            Task { @MainActor [weak window] in
                guard let window else { return }
                var top = window.rootViewController
                while let presented = top?.presentedViewController { top = presented }
                if let transition = top?.transitionCoordinator,
                   transition.animate(alongsideTransition: nil, completion: { [weak window] _ in
                       Task { @MainActor in
                           if let window { Self.applyRotation(in: window) }
                       }
                   }) { return }
                Self.applyRotation(in: window)
            }
        }

        private static func applyRotation(in window: UIWindow) {
            let orientations: UIInterfaceOrientationMask =
                (owners.object(forKey: window)?.count ?? 0) > 0 ? .allButUpsideDown : .portrait
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
            // UIKit handles geometry changes; never force UIDevice orientation
            // through private KVC. A background scene may decline the request.
            window.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
        }
    }
}
#endif

@main struct ZorofinApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(ZorofinAppDelegate.self) private var appDelegate
    #endif
    @State private var model = AppModel()
    private var approvalsPreview: Bool {
        #if DEBUG && os(iOS)
        ProcessInfo.processInfo.arguments.contains("--approvals-preview")
        #else
        false
        #endif
    }
    private var playerPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--player-preview") || ProcessInfo.processInfo.arguments.contains("--live-player-preview")
        #else
        false
        #endif
    }
    var body: some Scene {
        WindowGroup {
            GeometryReader { geometry in
                Group {
                    if approvalsPreview {
                        #if DEBUG && os(iOS)
                        AccountApprovalsLayoutPreview()
                        #endif
                    }
                    else if playerPreview {
                        #if DEBUG
                        PlayerDesignPreview(isLive: ProcessInfo.processInfo.arguments.contains("--live-player-preview"))
                        #endif
                    }
                    else if model.restoring { ProgressView().tint(Theme.jade) }
                    else if model.signedIn { ZorofinShell().id(model.generation) }
                    else if !model.storageReady {
                        VStack(spacing: 20) {
                            Text("Unlock your device to open saved sign-ins.")
                            Button("Retry") { model.restoring = true; Task { await model.restore() } }
                                .buttonStyle(ZoroButtonStyle(primary: true))
                        }.padding(24)
                    }
                    else if !model.connections.accounts.isEmpty { SavedServersView().id(model.generation) }
                    else { ConnectView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .environment(model)
                .environment(\.adaptiveWindow, AdaptiveWindow(width: geometry.size.width, height: geometry.size.height))
                .modifier(NativeMotionPreference(reduce: model.preferences.reduceMotion))
                #if os(tvOS)
                .onOpenURL { url in
                    if let link = TopShelfLink(url: url) { model.pendingTopShelfLink = link }
                }
                #endif
                .preferredColorScheme(.dark)
                .tint(Theme.jade)
                .task {
                    if approvalsPreview { return }
                    if playerPreview { model.showDemo() } else { await model.restore() }
                }
                .alert("Zorofin", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                    Button("OK") { model.message = nil }
                } message: { Text(model.message ?? "") }
            }
        }
    }
}
