import SwiftUI
import ZorofinCore
#if os(iOS)
import StoreKit
#endif

enum AppRating {
    // Both platform targets belong to this App Store Connect record.
    static var url: URL {
        #if os(iOS)
        URL(string: "https://apps.apple.com/app/id6826013941?action=write-review")!
        #else
        URL(string: "https://apps.apple.com/app/id6826013941")!
        #endif
    }
}

@MainActor final class ReviewPromptStore {
    private let defaults: UserDefaults
    private let key = "app-review-opportunities-v1"
    private var policy: ReviewPromptPolicy

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        policy = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ReviewPromptPolicy.self, from: $0) } ?? .init()
        save()
    }
    func recordPlayback(activeSeconds: TimeInterval, failed: Bool) {
        policy.recordPlayback(activeSeconds: activeSeconds, failed: failed)
        save()
    }
    func takeOpportunity() -> Bool {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard policy.takeOpportunity(version: version) else { return false }
        save()
        return true
    }
    private func save() {
        if let data = try? JSONEncoder().encode(policy) { defaults.set(data, forKey: key) }
    }
}

/// The review-request API is unavailable on tvOS; its Profile action opens the App Store.
struct AppRatingPrompt: ViewModifier {
    let opportunity: Int
    let isClear: Bool
    #if os(iOS)
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content.task(id: isClear && scenePhase == .active ? opportunity : 0) {
            guard opportunity > 0, isClear, scenePhase == .active else { return }
            let generation = model.generation
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, generation == model.generation, model.signedIn,
                  !model.isDemo, model.message == nil, !model.watchTogether.isJoined,
                  model.reviewPrompts.takeOpportunity() else { return }
            requestReview()
        }
        #else
        content
        #endif
    }
}
