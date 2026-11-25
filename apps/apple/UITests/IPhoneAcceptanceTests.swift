import XCTest
import UIKit

/// Opt-in through the dedicated physical-iPhone scheme. Uses the account already
/// on the device; screenshots/results contain private library data, not artwork.
final class IPhoneAcceptanceTests: XCTestCase {
    private enum JourneyFailure: Error { case missingUI }

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func wait(_ description: String, timeout: TimeInterval = 15,
                                 until condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out: " + description)
                throw JourneyFailure.missingUI
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    @MainActor private func tap(_ element: XCUIElement, _ description: String) async throws {
        try await wait(description) { element.exists && element.isHittable && element.isEnabled }
        element.tap()
    }

    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "iphone-existing-account-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func navigation(_ title: String, app: XCUIApplication) -> XCUIElement {
        // SwiftUI may propagate the container's identifier to its children.
        app.buttons.matching(NSPredicate(format:
            "label == %@ AND (identifier == %@ OR identifier == %@)",
            title, "dock-" + title, "phone-navigation")).firstMatch
    }

    private struct PlayerControlSnapshot {
        let label: String
        let enabled: Bool
        let frame: CGRect
        let window: CGRect?
    }

    @MainActor private func playerControlSnapshots(app: XCUIApplication) -> [String: [PlayerControlSnapshot]]? {
        // Read one immutable tree. Each live element property lookup takes a new
        // AX snapshot and can fail after auto-hide removes a previously found button.
        guard let root = try? app.snapshot() else { return nil }
        let identifiers: Set<String> = ["player-play-pause", "player-back", "player-options-close"]
        var controls: [String: [PlayerControlSnapshot]] = [:]
        @MainActor func visit(_ node: any XCUIElementSnapshot, window: CGRect?) {
            let enclosingWindow = node.elementType == .window ? node.frame : window
            if node.elementType == .button {
                let key: String?
                if identifiers.contains(node.identifier) { key = node.identifier }
                else if node.label == "Show playback controls" { key = node.label }
                else { key = nil }
                if let key {
                    controls[key, default: []].append(.init(label: node.label, enabled: node.isEnabled,
                                                           frame: node.frame, window: enclosingWindow))
                }
            }
            for child in node.children { visit(child, window: enclosingWindow) }
        }
        visit(root, window: nil)
        return controls
    }

    private func uniqueControl(_ identifier: String, in controls: [String: [PlayerControlSnapshot]]) -> PlayerControlSnapshot? {
        guard let matches = controls[identifier], matches.count == 1 else { return nil }
        return matches[0]
    }

    @MainActor @discardableResult private func revealControls(app: XCUIApplication,
        snapshot: [String: [PlayerControlSnapshot]]? = nil) -> Bool {
        guard let controls = snapshot ?? playerControlSnapshots(app: app),
              controls["player-play-pause"] == nil, controls["player-back"] == nil,
              let reveal = uniqueControl("Show playback controls", in: controls),
              reveal.enabled, let window = reveal.window, visibleFrame(reveal.frame, in: window) else { return false }
        // Only the final action/hit check uses a live query. No exists→label or
        // exists→frame chain can race with the control disappearing.
        let target = app.buttons["Show playback controls"]
        guard target.isHittable else { return false }
        target.tap()
        return true
    }

    @MainActor private func transportDiagnostic(_ controls: [String: [PlayerControlSnapshot]]?, expected: String,
                                     reveals: Int, name: String) {
        var lines = ["Expected transport: " + expected, "Reveal taps: \(reveals)"]
        let safeLabels: Set<String> = ["Play", "Pause", "Watch again", "Reconnect", "Close player",
                                       "Show playback controls", "Unlock", "Return to playback"]
        if let controls {
            for identifier in ["player-play-pause", "player-back", "Show playback controls", "player-options-close"] {
                let matches = controls[identifier] ?? []
                lines.append(identifier + ": matches=\(matches.count)")
                for value in matches {
                    lines.append("enabled=\(value.enabled), frame=\(value.frame), window=\(String(describing: value.window)), "
                        + "label=" + (safeLabels.contains(value.label) ? value.label : "<unlisted>"))
                }
            }
        } else { lines.append("App snapshot unavailable; no control-state conclusion") }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func waitForTransport(app: XCUIApplication, label: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        var nextReveal = 0.0
        var reveals = 0
        var recordedReadySnapshot = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let controls = playerControlSnapshots(app: app) {
                if let transport = uniqueControl("player-play-pause", in: controls),
                   transport.label == label, transport.enabled,
                   let window = transport.window, visibleFrame(transport.frame, in: window) {
                    if !recordedReadySnapshot {
                        transportDiagnostic(controls, expected: label, reveals: reveals,
                                            name: "iphone-transport-first-ready-snapshot")
                        recordedReadySnapshot = true
                    }
                    // Hittability remains a live acceptance gate; a frame alone
                    // is insufficient. A false result keeps waiting; framework
                    // query errors remain failures, never suppressed acceptance.
                    if app.buttons["player-play-pause"].isHittable { return }
                } else if controls["player-play-pause"] == nil,
                          ProcessInfo.processInfo.systemUptime >= nextReveal {
                    if revealControls(app: app, snapshot: controls) { reveals += 1 }
                    nextReveal = ProcessInfo.processInfo.systemUptime + 2
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        // Capture before cleanup; diagnostics read only the immutable allowlist,
        // never a raw AX tree, private title/account, or arbitrary element value.
        capture("transport-timeout", app: app)
        transportDiagnostic(playerControlSnapshots(app: app), expected: label, reveals: reveals,
                            name: "iphone-transport-timeout-controls")
        XCTFail("Timed out: player transport " + label)
        throw JourneyFailure.missingUI
    }

    @MainActor private func closeIfPresented(app: XCUIApplication) {
        guard app.state == .runningForeground else { return }
        revealControls(app: app)
        guard let controls = playerControlSnapshots(app: app),
              let close = uniqueControl("player-back", in: controls), close.enabled,
              let window = close.window, visibleFrame(close.frame, in: window) else { return }
        let target = app.buttons["player-back"]
        if target.isHittable { target.tap() }
    }

    private func visibleFrame(_ frame: CGRect, in window: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.minX.isFinite && frame.minY.isFinite
            && frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
            && window.intersects(frame) && window.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    @MainActor private func playFromHome(app: XCUIApplication) async throws {
        let heading = app.staticTexts["Continue Watching"].firstMatch
        // Never query hittability on the entire lazy library. Snapshot geometry
        // first, then re-resolve one unique identifier in the intended shelf.
        for _ in 0..<5 {
            let window = app.windows.firstMatch.frame
            if heading.exists && visibleFrame(heading.frame, in: window) && heading.isHittable {
                let headerFrame = heading.frame
                let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "item-"))
                    .allElementsBoundByIndex.compactMap { element -> (String, CGRect)? in
                        let frame = element.frame
                        guard self.visibleFrame(frame, in: window), frame.minY >= headerFrame.maxY,
                              frame.minY < headerFrame.maxY + 100 else { return nil }
                        return (element.identifier, frame)
                    }.sorted { $0.1.minX < $1.1.minX }
                if let first = cards.first {
                    let exact = app.buttons.matching(identifier: first.0)
                    if exact.count == 1 {
                        let card = exact.firstMatch
                        if visibleFrame(card.frame, in: window) && card.isHittable {
                            try await tap(card, "first Continue Watching card")
                            // The card opens the episode page; Resume/Play is explicit there.
                            try await tap(app.buttons["detail-play"].firstMatch, "episode page Resume or Play")
                            return
                        }
                    }
                }
            }
            app.swipeUp()
        }
        // An absent/ambiguous shelf falls back only to the hero's declared
        // Play/Resume action, never to another shelf or a title detail button.
        for _ in 0..<6 {
            let window = app.windows.firstMatch.frame
            let inherited = app.buttons.matching(NSPredicate(format:
                "identifier == %@ AND (label == %@ OR label == %@)",
                "home-banner", "Play", "Resume")).firstMatch
            let nested = app.descendants(matching: .any).matching(identifier: "home-banner")
                .buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Play", "Resume")).firstMatch
            if inherited.exists && visibleFrame(inherited.frame, in: window) && inherited.isHittable {
                try await tap(inherited, "hero playback")
                return
            }
            if nested.exists && visibleFrame(nested.frame, in: window) && nested.isHittable {
                try await tap(nested, "hero playback")
                return
            }
            app.swipeDown()
        }
        XCTFail("No unambiguous Continue Watching card or hero playback action was reachable")
        throw JourneyFailure.missingUI
    }

    @MainActor private func rotate(_ orientation: UIDeviceOrientation, name: String,
                                   app: XCUIApplication) async throws {
        XCUIDevice.shared.orientation = orientation
        let landscape = orientation == .landscapeLeft || orientation == .landscapeRight
        try await wait("window orientation " + name) {
            let frame = app.windows.firstMatch.frame
            return frame.width > 0 && frame.height > 0
                && (landscape ? frame.width > frame.height : frame.height > frame.width)
        }
        // Let the system transition settle before checking reachability/capturing.
        try await Task.sleep(for: .milliseconds(600))
        try await waitForTransport(app: app, label: "Pause")
        let controls = try XCTUnwrap(playerControlSnapshots(app: app))
        for identifier in ["player-back", "player-play-pause"] {
            let control = try XCTUnwrap(uniqueControl(identifier, in: controls), "Unique control: " + identifier)
            let window = try XCTUnwrap(control.window).insetBy(dx: -1, dy: -1)
            XCTAssertTrue(control.enabled && app.buttons[identifier].isHittable, "Reachable control: " + identifier)
            XCTAssertTrue(window.contains(control.frame), "Control within its window: " + identifier)
        }
        capture("player-" + name, app: app)
    }

    @MainActor func testExistingAccountNavigationAndPlaybackRotation() async throws {
        let app = XCUIApplication(bundleIdentifier: "org.zorofin.app")
        // No preview/reset arguments, credentials, server override or preference writes.
        app.launch()
        guard navigation("Home", app: app).waitForExistence(timeout: 30) else {
            throw XCTSkip("Requires an already signed-in account; setup and saved accounts are preserved")
        }
        var playbackRequested = false
        defer {
            if playbackRequested { closeIfPresented(app: app) }
            XCUIDevice.shared.orientation = .portrait
        }
        XCUIDevice.shared.orientation = .portrait
        try await tap(navigation("Home", app: app), "Home")
        try await wait("loaded Home", timeout: 45) {
            app.descendants(matching: .any)["home-banner"].exists
                || app.staticTexts["Continue Watching"].exists
        }
        capture("home", app: app)
        try await tap(navigation("Profile", app: app), "Profile")
        // Merely inspect the sign-out action; never activate it. Preview is not
        // evidence of a real authenticated-library journey.
        try await wait("Profile actions") { app.buttons["profile-downloads"].exists }
        if app.buttons["profile-sign-out"].exists
            && app.buttons["profile-sign-out"].label == "Leave preview" {
            throw XCTSkip("Fictional preview is not a signed-in account")
        }
        capture("profile", app: app)
        try await tap(app.buttons["profile-downloads"], "Downloads")
        try await wait("Downloads screen") {
            app.descendants(matching: .any)["downloads-screen"].exists
                && app.buttons["downloads-back"].isHittable
        }
        capture("downloads", app: app)
        try await tap(app.buttons["downloads-back"], "return from Downloads")
        try await tap(navigation("Search", app: app), "Search")
        try await wait("Search field") { app.textFields["library-search"].isHittable }
        capture("search", app: app)
        try await tap(navigation("Home", app: app), "return Home")
        playbackRequested = true
        try await playFromHome(app: app)
        try await waitForTransport(app: app, label: "Pause")
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"),
                                    (.landscapeLeft, "landscape-left"),
                                    (.portrait, "portrait-between"),
                                    (.landscapeRight, "landscape-right"),
                                    (.portrait, "portrait-final")] {
            try await rotate(orientation, name: name, app: app)
        }
        try await tap(app.buttons["player-play-pause"], "pause")
        try await waitForTransport(app: app, label: "Play")
        capture("player-paused", app: app)
        try await tap(app.buttons["player-play-pause"], "resume")
        try await waitForTransport(app: app, label: "Pause")
        try await tap(app.buttons["player-back"], "close player")
        try await wait("Home after closing playback") { self.navigation("Home", app: app).isHittable }
        playbackRequested = false
        XCUIDevice.shared.press(.home)
        app.activate()
        try await wait("Home after foreground return") { self.navigation("Home", app: app).isHittable }
        capture("home-returned", app: app)
    }

    // This extra journey is opt-in even when the whole phone scheme runs. Only
    // the privately selected item may be created/removed; no launch reset flags.
    private struct DownloadSelection {
        let itemID: String
        let query: String
        let server: String
        let viewer: String
        let quality: String
        let maximumBytes: Double
        let keepForOffline: Bool

        init(environment: [String: String]) throws {
            guard environment["ZOROFIN_UI_DOWNLOAD_TEST"] == "1" else {
                throw XCTSkip("Download mutation journey requires explicit opt-in")
            }
            func required(_ name: String) throws -> String {
                guard let value = environment[name], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw XCTSkip("Missing private download selector: " + name)
                }
                return value
            }
            itemID = try required("ZOROFIN_UI_DOWNLOAD_ITEM_ID")
            query = try required("ZOROFIN_UI_DOWNLOAD_SEARCH")
            server = try required("ZOROFIN_UI_DOWNLOAD_SERVER_NAME")
            viewer = try required("ZOROFIN_UI_DOWNLOAD_VIEWER")
            quality = environment["ZOROFIN_UI_DOWNLOAD_QUALITY"] ?? "Original"
            guard ["Original", "High", "Standard", "Data saver"].contains(quality) else {
                throw XCTSkip("Unsupported download quality selector")
            }
            maximumBytes = Double(environment["ZOROFIN_UI_DOWNLOAD_MAX_BYTES"] ?? "67108864") ?? 0
            guard maximumBytes >= 1, maximumBytes <= 268_435_456 else {
                throw XCTSkip("Download size bound must be between 1 and 256 MiB; default is 64 MiB")
            }
            keepForOffline = environment["ZOROFIN_UI_DOWNLOAD_KEEP"] == "1"
        }
    }

    @MainActor private func downloadWait(_ description: String, timeout: TimeInterval = 20,
                                          until condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                // Throw before recording failure so the caller can attempt
                // narrowly scoped cleanup even when continueAfterFailure is false.
                throw NSError(domain: "DownloadAcceptance", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Timed out: " + description])
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    @MainActor private func downloadTap(_ element: XCUIElement, _ description: String) async throws {
        try await downloadWait(description) { element.exists && element.isHittable && element.isEnabled }
        element.tap()
    }

    @MainActor private func selectDownload(_ selection: DownloadSelection, app: XCUIApplication) async throws {
        try await downloadTap(navigation("Profile", app: app), "expected account Profile")
        try await downloadWait("expected server and viewer") {
            app.staticTexts[selection.server].exists && app.staticTexts[selection.viewer].exists
        }
        guard app.buttons["profile-sign-out"].label != "Leave preview" else {
            throw XCTSkip("Preview cannot download; saved sign-in is preserved")
        }
        try await downloadTap(navigation("Search", app: app), "Search")
        let field = app.textFields["library-search"]
        try await downloadTap(field, "library search field")
        if app.buttons["clear-search"].exists {
            try await downloadTap(app.buttons["clear-search"], "clear previous search")
            try await downloadTap(field, "empty library search field")
        }
        field.typeText(selection.query)
        let item = app.buttons.matching(identifier: "item-" + selection.itemID)
        try await downloadWait("exact selected library item", timeout: 45) { item.count == 1 }
        // A return key dismisses the keyboard without selecting another result.
        field.typeText("\n")
        for _ in 0..<6 where !item.firstMatch.isHittable { app.swipeUp() }
        try await downloadTap(item.firstMatch, "exact selected item")
        let download = app.buttons["detail-download"]
        try await downloadWait("selected item details") { app.buttons["detail-back"].exists && download.exists }
        for _ in 0..<6 where !download.isHittable { app.swipeUp() }
        try await downloadWait("selected download control") { download.isHittable }
    }

    private func estimatedDownloadBytes(_ label: String) -> Double? {
        // Fail closed for unavailable/localized/ambiguous estimates. This runner
        // uses English controls and cannot impose a production download byte cap.
        let pattern = #"About ([0-9]+(?:\.[0-9]+)?) (bytes|KB|MB|GB|TB)\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
              let valueRange = Range(match.range(at: 1), in: label),
              let unitRange = Range(match.range(at: 2), in: label),
              let value = Double(label[valueRange]),
              let multiplier = ["bytes": 1.0, "KB": 1_000.0, "MB": 1_000_000.0,
                                "GB": 1_000_000_000.0, "TB": 1_000_000_000_000.0][String(label[unitRange])] else { return nil }
        return value * multiplier
    }

    @MainActor private func closeDownloadedPlayer(app: XCUIApplication) async throws {
        for _ in 0..<5 {
            if app.buttons["detail-download"].isHittable { return }
            let close = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Done", "Close"))
                .allElementsBoundByIndex.filter { $0.isHittable }
            if close.count == 1 {
                close[0].tap()
                try await downloadWait("return from downloaded player") { app.buttons["detail-download"].isHittable }
                return
            }
            app.tap() // Reveal native AVKit controls; no system settings are opened.
            try await Task.sleep(for: .milliseconds(300))
        }
        throw NSError(domain: "DownloadAcceptance", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Native player could not be closed; cleanup remains pending"])
    }

    @MainActor private func removeCreatedDownload(_ selection: DownloadSelection, app: XCUIApplication) async throws {
        app.activate()
        try await closeDownloadedPlayer(app: app)
        // Recheck account and exact item before a destructive per-record action.
        try await selectDownload(selection, app: app)
        let download = app.buttons["detail-download"]
        if download.label == "Download" || (download.label == "Downloads unavailable" && !download.isEnabled) { return }
        let active = download.label == "Download waiting" || download.label.hasPrefix("Downloading,")
        let failed = download.label == "Download failed"
        guard active || failed || download.label == "Downloaded" else {
            throw NSError(domain: "DownloadAcceptance", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown selected download state; cleanup remains pending"])
        }
        try await downloadTap(download, "selected download menu")
        let action = active ? "Cancel download" : failed ? "Remove" : "Remove download"
        try await downloadTap(app.buttons[action].firstMatch, "per-item removal action")
        // There must be a new confirmation before any removal. Never use Remove all.
        try await downloadWait("per-item removal confirmation") {
            app.staticTexts[active ? "Cancel this download?" : "Remove this download?"].exists
        }
        try await downloadTap(app.buttons[active ? "Cancel download" : "Remove"].firstMatch, "confirm per-item removal")
        try await downloadWait("selected record removed") {
            download.label == "Download" || (download.label == "Downloads unavailable" && !download.isEnabled)
        }
    }

    @MainActor func testSelectedDownloadLifecycleAndCleanup() async throws {
        let selection = try DownloadSelection(environment: ProcessInfo.processInfo.environment)
        let app = XCUIApplication(bundleIdentifier: "org.zorofin.app")
        app.launch()
        guard navigation("Home", app: app).waitForExistence(timeout: 30) else {
            throw XCTSkip("Requires the selected already signed-in account; no reset or sign-out")
        }
        let previousOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = previousOrientation }
        try await selectDownload(selection, app: app)
        let download = app.buttons["detail-download"]
        let permissionDeadline = Date().addingTimeInterval(20)
        while !download.isEnabled && Date() < permissionDeadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        guard download.isEnabled else {
            throw XCTSkip("Download permission is denied/unverified; no account policy is changed")
        }
        guard download.label == "Download" else {
            throw XCTSkip("Selected item already has a download record; it is preserved")
        }
        try await downloadTap(download, "new download quality menu")
        let choices = app.buttons.matching(NSPredicate(format:
            "label == %@ OR label BEGINSWITH %@", selection.quality, selection.quality + ","))
        try await downloadWait("unambiguous quality choice") { choices.count == 1 && choices.firstMatch.isHittable }
        guard let estimate = estimatedDownloadBytes(choices.firstMatch.label), estimate > 0,
              estimate <= selection.maximumBytes else {
            // Dismiss without starting. Unknown size is not permission to fetch a long title.
            app.tap()
            throw XCTSkip("Choose a small sample with a displayed size estimate within the configured bound")
        }
        capture("download-size-approved", app: app)
        var created = false
        var completed = false
        do {
            choices.firstMatch.tap()
            created = true // No previous record existed; this test owns only this selected item.
            try await downloadWait("download queued or started") {
                download.label == "Download waiting" || download.label.hasPrefix("Downloading,")
                    || download.label == "Downloaded" || download.label == "Download failed"
            }
            guard download.label != "Download failed" else { throw JourneyFailure.missingUI }
            let stateBeforeBackground = download.label
            capture("download-before-background", app: app)
            XCUIDevice.shared.press(.home)
            try await Task.sleep(for: .seconds(5))
            app.activate()
            try await downloadWait("download completed", timeout: 180) {
                download.label == "Downloaded" || download.label == "Download failed"
            }
            guard download.label == "Downloaded" else { throw JourneyFailure.missingUI }
            completed = true
            capture("download-completed", app: app)
            let observation = XCTAttachment(string: "Before background: " + stateBeforeBackground
                + "\nAfter foreground: Downloaded\nBackground duration: 5 seconds\n"
                + "Completion before background does not prove background transfer. Network settings unchanged.")
            observation.name = "download-lifecycle-observation"
            observation.lifetime = .keepAlways
            add(observation)
            try await downloadTap(app.buttons["detail-play"], "play selected saved copy")
            try await downloadWait("native saved-copy player", timeout: 30) {
                let close = app.buttons.matching(NSPredicate(format:
                    "label == %@ OR label == %@", "Done", "Close"))
                    .allElementsBoundByIndex.filter { $0.isHittable }
                let transport = app.buttons["Pause"].isHittable || app.buttons["Play"].isHittable
                if !download.isHittable && !app.buttons["player-play-pause"].exists
                    && close.count == 1 && transport { return true }
                app.tap()
                return false
            }
            capture("download-player-first", app: app)
            try await Task.sleep(for: .seconds(5))
            capture("download-player-later", app: app)
            try await closeDownloadedPlayer(app: app)
            if !selection.keepForOffline {
                try await removeCreatedDownload(selection, app: app)
                created = false
                capture("download-removed", app: app)
            } else {
                let receipt = XCTAttachment(string: "Explicit KEEP=1: retained only test-created item " + selection.itemID
                    + "\nUse this private receipt for manual offline picture/audio and removal. Not offline acceptance.")
                receipt.name = "download-owned-record-retained"
                receipt.lifetime = .keepAlways
                add(receipt)
            }
        } catch {
            capture("download-failure-before-cleanup", app: app)
            if created && !(selection.keepForOffline && completed) {
                do { try await removeCreatedDownload(selection, app: app) }
                catch {
                    let receipt = XCTAttachment(string: "Cleanup pending for test-created item " + selection.itemID
                        + ": " + String(describing: error) + "\nPreserve all other downloads.")
                    receipt.name = "download-cleanup-pending"
                    receipt.lifetime = .keepAlways
                    add(receipt)
                }
            }
            throw error
        }
        // A native transport label and screenshots require separate decoded
        // picture/audio review; this online test does not claim offline playback.
    }

    // MARK: - 1.4 exploratory pass (read-only)

    /// Walks the 1.4 screens with the account already on the phone and saves a
    /// screenshot at each stop. Never signs in, plays, requests, swipes, downloads or
    /// changes settings. Missing screens are recorded, not failed.
    @MainActor func testExplore14Screens() async throws {
        continueAfterFailure = true
        let app = XCUIApplication(bundleIdentifier: "org.zorofin.app")
        app.launch()
        guard navigation("Home", app: app).waitForExistence(timeout: 30) else {
            throw XCTSkip("Requires an already signed-in account")
        }
        XCUIDevice.shared.orientation = .portrait
        func shot(_ name: String) { capture("explore-" + name, app: app) }
        func pause(_ seconds: Double = 2.5) async { try? await Task.sleep(for: .seconds(seconds)) }
        func softTap(_ element: XCUIElement, _ name: String, timeout: TimeInterval = 8) async -> Bool {
            guard element.waitForExistence(timeout: timeout), element.isHittable else {
                let note = XCTAttachment(string: "missing: " + name); note.name = "explore-missing-" + name
                note.lifetime = .keepAlways; add(note); return false
            }
            element.tap(); await pause(); return true
        }
        func back() async {
            let button = app.navigationBars.buttons.element(boundBy: 0)
            if button.exists && button.isHittable { button.tap() } else {
                app.swipeRight()
            }
            await pause(1.5)
        }

        await pause(5); shot("01-home")
        app.swipeUp(); await pause(); shot("02-home-scrolled")
        app.swipeUp(); await pause(); shot("03-home-scrolled-more")

        if await softTap(navigation("Search", app: app), "search-tab") {
            shot("04-search-empty")
            let field = app.textFields["library-search"].exists ? app.textFields["library-search"] : app.searchFields.firstMatch
            if await softTap(field, "search-field") { field.typeText("the"); await pause(3); shot("05-search-typed") }
        }

        _ = await softTap(navigation("Home", app: app), "home-tab")
        app.swipeDown(); app.swipeDown(); await pause()
        if await softTap(app.buttons["Shows"].firstMatch, "shows-shortcut") {
            await pause(3); shot("06-shows-library")
            let sort = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sort' OR identifier CONTAINS[c] 'sort'")).firstMatch
            if await softTap(sort, "library-sort", timeout: 3) { shot("07-library-sort"); app.tap(); await pause(1) }
            let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item-'")).firstMatch
            if await softTap(first, "first-series") {
                await pause(3); shot("08-series-detail")
                app.swipeUp(); await pause(); shot("09-series-episodes")
                let season = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Season' OR label CONTAINS 'season'")).firstMatch
                if await softTap(season, "season-picker", timeout: 3) { shot("10-season-menu"); app.tap(); await pause(1) }
                app.swipeUp(); await pause(); shot("11-series-more")
                await back()
            }
            await back()
        }

        if await softTap(navigation("Profile", app: app), "profile-tab") {
            shot("12-profile")
            let catchUp = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Catch Up'")).firstMatch
            if !catchUp.exists { app.swipeUp(); await pause(1) }
            if await softTap(catchUp, "catch-up-row") {
                await pause(3); shot("13-catch-up")
                if await softTap(app.buttons["Together"].firstMatch, "together-toggle", timeout: 4) {
                    shot("14-pick-together-start")
                    if await softTap(app.buttons["Join with a code"].firstMatch, "join-with-code", timeout: 3) { shot("15-pick-join") }
                }
                if app.buttons["Close"].exists { app.buttons["Close"].tap(); await pause(1.5) }
            }
            let watch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Watch together'")).firstMatch
            if !watch.exists { app.swipeUp(); await pause(1) }
            if await softTap(watch, "watch-together-row") { shot("16-watch-together"); await back() }
        }

        if await softTap(navigation("Requests", app: app), "requests-tab") { await pause(3); shot("17-requests") }
        _ = await softTap(navigation("Home", app: app), "home-tab-final")
        app.swipeDown(); await pause()
        if await softTap(app.buttons["Live TV"].firstMatch, "live-tv-shortcut") { await pause(4); shot("18-live-tv") }
        if await softTap(app.buttons["Movies"].firstMatch, "movies-shortcut", timeout: 3) { await pause(3); shot("19-movies") }
        _ = await softTap(navigation("Home", app: app), "home-tab-end")
    }

    /// Read-only: season menu, switching seasons, Current episode, opening an episode.
    @MainActor func testExploreSeasonsAndEpisodes() async throws {
        continueAfterFailure = true
        let app = XCUIApplication(bundleIdentifier: "org.zorofin.app")
        app.launch()
        guard navigation("Home", app: app).waitForExistence(timeout: 30) else { throw XCTSkip("Requires an already signed-in account") }
        XCUIDevice.shared.orientation = .portrait
        func shot(_ name: String) { capture("season-" + name, app: app) }
        func note(_ name: String, _ text: String) { let a = XCTAttachment(string: text); a.name = "season-note-" + name; a.lifetime = .keepAlways; add(a) }
        func pause(_ seconds: Double = 2) async { try? await Task.sleep(for: .seconds(seconds)) }
        func open(_ element: XCUIElement, _ name: String, timeout: TimeInterval = 8) async -> Bool {
            guard element.waitForExistence(timeout: timeout), element.isHittable else { note("missing-" + name, app.debugDescription.prefix(4000).description); return false }
            element.tap(); await pause(); return true
        }
        func seasonMenu() -> XCUIElement { app.buttons["episode-browser-season"].firstMatch }
        func scrollToSeason() async {
            for _ in 0..<6 where !(seasonMenu().exists && seasonMenu().isHittable) { app.swipeUp(); await pause(0.8) }
        }
        _ = await open(navigation("Search", app: app), "search")
        let field = app.textFields["library-search"].exists ? app.textFields["library-search"] : app.searchFields.firstMatch
        guard await open(field, "search-field") else { return }
        field.typeText("The Office"); await pause(3)
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'The Office'")).firstMatch
        guard await open(result, "office-result") else { shot("00-search"); return }
        await pause(3); shot("01-series-top")
        await scrollToSeason(); shot("02-episodes")
        note("season-label", seasonMenu().exists ? (seasonMenu().value as? String ?? seasonMenu().label) : "no season control")
        if await open(seasonMenu(), "season-menu") {
            shot("03-menu-open")
            let choices = app.buttons.allElementsBoundByIndex.map(\.label).filter { $0.contains("Season") || $0.contains("Special") }
            note("menu-choices", choices.joined(separator: " | "))
            let target = app.buttons.matching(NSPredicate(format: "label == 'Season 3'")).firstMatch
            if await open(target, "season-choice") { await pause(3); shot("04-after-season-change")
                note("after-change", seasonMenu().exists ? (seasonMenu().value as? String ?? "") : "season control gone") }
        }
        let current = app.buttons["episode-browser-current"].firstMatch
        if await open(current, "current-episode", timeout: 4) { await pause(3); shot("05-after-current") }
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '3.' OR label CONTAINS 'Office Olympics'")).firstMatch
        if await open(row, "episode-row", timeout: 4) { await pause(3); shot("06-episode-detail")
            app.swipeUp(); await pause(); shot("07-episode-detail-list")
            await scrollToSeason(); shot("08-episode-page-browser")
            if await open(seasonMenu(), "episode-page-season-menu", timeout: 4) { shot("09-episode-page-menu"); app.tap(); await pause(1) }
        }
        // A show with Specials and many seasons.
        _ = await open(navigation("Search", app: app), "search-2")
        if field.waitForExistence(timeout: 5) {
            field.tap(); if let text = field.value as? String, !text.isEmpty { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count)) }
            field.typeText("South Park"); await pause(3)
            let sp = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'South Park'")).firstMatch
            if await open(sp, "south-park") { await pause(3); await scrollToSeason(); shot("10-sp-episodes")
                if await open(seasonMenu(), "sp-menu") { shot("11-sp-menu"); app.swipeUp(); await pause(1); shot("12-sp-menu-scrolled"); app.tap(); await pause(1) }
            }
        }
    }

    /// Read-only: open the first Continue Watching title and watch the details page settle.
    @MainActor func testExploreContinueWatchingDetail() async throws {
        let app = XCUIApplication(bundleIdentifier: "org.zorofin.app")
        app.launch()
        guard navigation("Home", app: app).waitForExistence(timeout: 30) else { throw XCTSkip("Requires an already signed-in account") }
        navigation("Home", app: app).tap()
        try? await Task.sleep(for: .seconds(4))
        let heading = app.staticTexts["Continue Watching"]
        for _ in 0..<4 where !(heading.exists && heading.isHittable) { app.swipeUp(); try? await Task.sleep(for: .seconds(1)) }
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item-'")).allElementsBoundByIndex
            .first { $0.isHittable && $0.frame.minY > heading.frame.maxY }
        guard let card else { capture("cw-missing", app: app); return }
        card.tap()
        for second in [1, 3, 6, 9] {
            try? await Task.sleep(for: .seconds(second == 1 ? 1 : 3)); capture("cw-detail-\(second)s", app: app)
        }
        app.swipeUp(); try? await Task.sleep(for: .seconds(1.5)); capture("cw-detail-scrolled", app: app)
        app.swipeUp(); try? await Task.sleep(for: .seconds(1.5)); capture("cw-detail-scrolled-2", app: app)
    }

    /// Simulator only: start a Quick Connect sign-in to ZOROFIN_UI_SERVER and wait for approval.
    /// Prints the code; never types a password.
    @MainActor func testSimulatorQuickConnectSignIn() async throws {
        guard let server = ProcessInfo.processInfo.environment["ZOROFIN_UI_SERVER"] else { return }
        let app = XCUIApplication(bundleIdentifier: "org.zorofin.app")
        app.launch()
        if navigation("Home", app: app).waitForExistence(timeout: 8) { print("ZOROFIN-QC already signed in"); return }
        let field = app.textFields["server-address"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap(); field.typeText(server)
        app.buttons["connect-server"].tap()
        let quick = app.buttons["quick-connect"]
        XCTAssertTrue(quick.waitForExistence(timeout: 30))
        quick.tap()
        let code = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Quick Connect code'")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 20))
        print("ZOROFIN-QC CODE " + code.label.replacingOccurrences(of: "Quick Connect code ", with: "").replacingOccurrences(of: " ", with: ""))
        capture("sim-quick-connect", app: app)
        XCTAssertTrue(navigation("Home", app: app).waitForExistence(timeout: 290), "Quick Connect was not approved in time")
        print("ZOROFIN-QC SIGNED IN")
        capture("sim-signed-in", app: app)
    }

    /// Simulator, Claude Test account: put Breaking Bad S4E5 in progress, then reopen the
    /// series from Continue Watching and record which episode is current.
    @MainActor func testSimulatorSeriesCurrentEpisode() async throws {
        let app = XCUIApplication(bundleIdentifier: "org.zorofin.app")
        app.launchArguments = ["--ui-test-muted"]
        app.launch()
        XCTAssertTrue(navigation("Home", app: app).waitForExistence(timeout: 30))
        func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        func note(_ name: String, _ text: String) { let a = XCTAttachment(string: text); a.name = "cur-" + name; a.lifetime = .keepAlways; add(a) }
        func currentRows() -> String {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Current episode' OR label CONTAINS 'In progress'"))
                .allElementsBoundByIndex.prefix(8).map(\.label).joined(separator: " || ")
        }
        try await tap(navigation("Search", app: app), "Search")
        let field = app.textFields["library-search"].exists ? app.textFields["library-search"] : app.searchFields.firstMatch
        try await tap(field, "search field"); field.typeText("Breaking Bad"); await pause(3)
        try await tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Breaking Bad'")).firstMatch, "series result")
        await pause(3)
        let season = app.buttons["episode-browser-season"].firstMatch
        for _ in 0..<6 where !(season.exists && season.isHittable) { app.swipeUp(); await pause(0.8) }
        try await tap(season, "season menu")
        capture("cur-season-menu", app: app)
        try await tap(app.buttons["Season 4"].firstMatch, "Season 4"); await pause(3)
        capture("cur-season-4", app: app)
        note("season-4-labels", app.buttons.allElementsBoundByIndex.prefix(40).map(\.label).joined(separator: " || "))
        let shotgun = app.buttons["S4 E5, Shotgun"].firstMatch
        let window = app.windows.firstMatch.frame
        for _ in 0..<6 where !(shotgun.exists && shotgun.frame.midY < window.midY && shotgun.frame.minY > 80) {
            if shotgun.exists && shotgun.frame.minY <= 80 { app.swipeDown() } else { app.swipeUp() }
            await pause(0.8)
        }
        capture("cur-before-shotgun", app: app)
        shotgun.tap(); await pause(3)
        capture("cur-episode-page", app: app)
        let play = app.buttons["detail-play"].firstMatch
        for _ in 0..<4 where !(play.exists && play.isHittable) { app.swipeDown(); await pause(0.8) }
        try await tap(play, "Play Shotgun")
        await pause(50)
        capture("cur-playing", app: app)
        closeIfPresented(app: app); await pause(3)
        if app.buttons["player-back"].exists { app.buttons["player-back"].tap(); await pause(3) }
        try await tap(navigation("Home", app: app), "Home"); await pause(2)
        app.swipeDown(); await pause(5)
        let heading = app.staticTexts["Continue Watching"]
        for _ in 0..<4 where !(heading.exists && heading.isHittable) { app.swipeUp(); await pause(1) }
        capture("cur-home", app: app)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item-' AND label CONTAINS 'Breaking Bad'")).firstMatch
        try await tap(card, "Continue Watching Breaking Bad")
        for second in [2, 6, 10] {
            await pause(second == 2 ? 2 : 4)
            capture("cur-detail-\(second)s", app: app)
            note("rows-\(second)s", currentRows() + " | play: " + app.buttons["detail-play"].firstMatch.label)
        }
        app.swipeUp(); await pause(1.5); capture("cur-detail-scrolled", app: app)
        note("rows-scrolled", currentRows())
    }

    /// Simulator, read-only: open a series page and record the current episode and Play label.
    @MainActor func testSimulatorSeriesPageCurrent() async throws {
        let app = XCUIApplication(bundleIdentifier: "org.zorofin.app")
        app.launchArguments = ["--ui-test-muted"]
        app.launch()
        XCTAssertTrue(navigation("Home", app: app).waitForExistence(timeout: 30))
        try await tap(navigation("Search", app: app), "Search")
        let field = app.textFields["library-search"].exists ? app.textFields["library-search"] : app.searchFields.firstMatch
        try await tap(field, "search field"); field.typeText("Breaking Bad"); try? await Task.sleep(for: .seconds(3))
        try await tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Breaking Bad'")).firstMatch, "series result")
        try? await Task.sleep(for: .seconds(7))
        capture("series-top", app: app)
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Current episode' OR label CONTAINS 'In progress' OR label BEGINSWITH 'Next episode'"))
            .allElementsBoundByIndex.prefix(6).map(\.label).joined(separator: " || ")
        let a = XCTAttachment(string: rows + " | play: " + app.buttons["detail-play"].firstMatch.label + " | value: " + (app.buttons["detail-play"].firstMatch.value as? String ?? ""))
        a.name = "series-rows"; a.lifetime = .keepAlways; add(a)
        app.swipeUp(); try? await Task.sleep(for: .seconds(1.5)); app.swipeUp(); try? await Task.sleep(for: .seconds(1.5))
        capture("series-episodes", app: app)
    }

    /// Simulator, read-only: capture the Sports & live events row on Home.
    @MainActor func testSimulatorSportsRow() async throws {
        let app = XCUIApplication(bundleIdentifier: "org.zorofin.app")
        app.launchArguments = ["--ui-test-muted"] + (ProcessInfo.processInfo.environment["ZOROFIN_UI_DEMO"] == "1" ? ["--demo"] : [])
        app.launch()
        XCTAssertTrue(navigation("Home", app: app).waitForExistence(timeout: 30))
        try? await Task.sleep(for: .seconds(8))
        for step in 0..<6 {
            capture("sports-row-\(step)", app: app)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Simulator, read-only: Home on a warm relaunch (stored rows) and every row style.
    @MainActor func testSimulatorHomeRows() async throws {
        let app = XCUIApplication(bundleIdentifier: "org.zorofin.app")
        app.launchArguments = ["--ui-test-muted"]
        app.launch()
        XCTAssertTrue(navigation("Home", app: app).waitForExistence(timeout: 30))
        try? await Task.sleep(for: .seconds(8))
        app.terminate()
        let start = Date()
        app.launch()
        XCTAssertTrue(navigation("Home", app: app).waitForExistence(timeout: 30))
        let firstRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'home-row-'")).firstMatch
        let shown = firstRow.waitForExistence(timeout: 20)
        let timing = XCTAttachment(string: "relaunch to first server row: \(shown ? String(format: "%.1f s", Date().timeIntervalSince(start)) : "not shown")")
        timing.name = "home-row-timing"; timing.lifetime = .keepAlways; add(timing)
        for step in 0..<9 {
            capture("home-rows-\(step)", app: app)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
            try? await Task.sleep(for: .seconds(1.2))
        }
    }

    /// Simulator, read-only: series page, episode rows, an episode page, the Shows library and Search.
    @MainActor func testSimulatorUIPass() async throws {
        let app = XCUIApplication(bundleIdentifier: "org.zorofin.app")
        app.launchArguments = ["--ui-test-muted"]
        app.launch()
        XCTAssertTrue(navigation("Home", app: app).waitForExistence(timeout: 30))
        func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        try await tap(navigation("Search", app: app), "Search")
        await pause(2); capture("ui-search-empty", app: app)
        let field = app.textFields["library-search"].exists ? app.textFields["library-search"] : app.searchFields.firstMatch
        try await tap(field, "search field"); field.typeText("Breaking Bad"); await pause(3)
        capture("ui-search-typed", app: app)
        try await tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Breaking Bad'")).firstMatch, "series result")
        await pause(5); capture("ui-series-top", app: app)
        app.swipeUp(); await pause(1.5); capture("ui-series-mid", app: app)
        app.swipeUp(); await pause(1.5); capture("ui-series-episodes", app: app)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Pilot'")).firstMatch
        if row.exists && row.isHittable { row.tap(); await pause(4); capture("ui-episode-top", app: app)
            app.swipeUp(); await pause(1.5); capture("ui-episode-mid", app: app) }
        try await tap(navigation("Home", app: app), "Home"); await pause(2)
        app.swipeDown(); await pause(1)
        if app.buttons["Shows"].firstMatch.waitForExistence(timeout: 5) { app.buttons["Shows"].firstMatch.tap(); await pause(4); capture("ui-shows-library", app: app)
            let filter = app.buttons["library-filter"].firstMatch
            if filter.exists { filter.tap(); await pause(1.5); capture("ui-shows-filter-menu", app: app); app.tap(); await pause(1) } }
    }
}
