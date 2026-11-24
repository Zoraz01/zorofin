import XCTest

/// Physical-iPad layout/input checks. Preview captures are never store artwork
/// or evidence of real-server authentication, playback or network compatibility.
final class IPadAcceptanceTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func required(_ element: XCUIElement, _ description: String, timeout: TimeInterval = 15) throws {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("Missing UI: " + description)
            throw NSError(domain: "ZorofinIPadUI", code: 1)
        }
    }

    @MainActor private func tap(_ element: XCUIElement, _ description: String) throws {
        try required(element, description)
        if !element.isHittable {
            let app = XCUIApplication(bundleIdentifier: "org.zorofin.app")
            for _ in 0..<5 where !element.isHittable { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable, description + " is not reachable")
        element.tap()
    }

    // iPadOS 18 propagates the dock container identifier to its buttons. Match
    // the declared label within either representation without using coordinates.
    @MainActor private func navigation(_ title: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format:
            "label == %@ AND (identifier == %@ OR identifier == %@)",
            title, "dock-" + title, "tablet-navigation")).firstMatch
    }

    @MainActor private func title(_ name: String, identifier: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, name)).firstMatch
    }

    /// Opt-in real sample-server capture. The host approves the visible Quick
    /// Connect challenge; no password or token is passed through XCTest.
    @MainActor func testDemoLibraryPortraitCapture() throws {
        guard let address = ProcessInfo.processInfo.environment["ZOROFIN_CAPTURE_SERVER"],
              let url = URL(string: address), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil else {
            throw XCTSkip("An explicitly selected HTTPS sample server is required")
        }
        let app = XCUIApplication(bundleIdentifier: "org.zorofin.app")
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        if app.textFields["server-address"].waitForExistence(timeout: 5) {
            let field = app.textFields["server-address"]
            try tap(field, "empty server field")
            field.typeText(address)
            try tap(app.buttons["connect-server"], "connect to selected sample server")
            try tap(app.buttons["quick-connect"], "Quick Connect sign-in")
            // Host-side approval uses only the existing restricted viewer.
            try required(navigation("Home", app: app), "approved demo Home", timeout: 180)
        } else {
            // Never capture a previously signed-in private library by accident.
            throw XCTSkip("Start from empty setup; existing accounts are preserved")
        }
        try required(app.staticTexts["More movies to explore"].firstMatch, "loaded sample Home", timeout: 30)
        capture("ipad-demo-home-portrait", app: app)
        try tap(app.buttons.matching(NSPredicate(format: "label == %@", "Movies")).firstMatch, "Movies library")
        try required(title("Sintel", identifier: "unused-demo-identifier", app: app), "sample library artwork", timeout: 30)
        capture("ipad-demo-library-portrait", app: app)
        try tap(title("Sintel", identifier: "unused-demo-identifier", app: app), "Sintel details")
        try required(app.buttons["detail-back"], "sample movie details")
        try required(app.staticTexts["Sintel"].firstMatch, "sample movie title")
        capture("ipad-demo-detail-portrait", app: app)
        try tap(navigation("Search", app: app), "Search")
        try required(app.textFields["library-search"], "sample library search")
        try required(app.descendants(matching: .any)["search-recommendations"].firstMatch,
                     "loaded sample recommendations", timeout: 30)
        capture("ipad-demo-search-portrait", app: app)
        try tap(navigation("Home", app: app), "return to sample Home")
    }

    /// Optional cleanup of this capture device only, preserving other devices'
    /// sessions and leaving a reviewer sign-in slot available.
    @MainActor func testFinishDemoCapture() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ZOROFIN_CAPTURE_CLEANUP"] == "1",
              let serverName = env["ZOROFIN_CAPTURE_SERVER_NAME"],
              let viewer = env["ZOROFIN_CAPTURE_VIEWER"] else {
            throw XCTSkip("Explicit capture cleanup identity required")
        }
        let app = XCUIApplication(bundleIdentifier: "org.zorofin.app")
        app.launch()
        if app.textFields["server-address"].waitForExistence(timeout: 3)
            || app.buttons["add-server"].exists { return }
        try tap(navigation("Profile", app: app), "capture account Profile")
        try required(app.staticTexts[serverName].firstMatch, "expected sample server")
        try required(app.staticTexts[viewer].firstMatch, "expected sample viewer")
        try tap(app.buttons["profile-sign-out"], "sign out this capture device")
        // Signing out preserves the saved account entry for the next sign-in.
        try required(app.buttons["add-server"], "saved servers after capture sign-out")
        capture("ipad-release-after-capture-signout", app: app)
    }

    @MainActor func testPhysicalIPadPreviewJourney() throws {
        let app = XCUIApplication(bundleIdentifier: "org.zorofin.app")
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        try required(app.textFields["server-address"], "empty server setup")
        // Never reset/sign out an existing account to force a fixture.
        capture("ipad-release-connect-portrait", app: app)
        try tap(app.buttons["Privacy Policy"], "pre-login Privacy Policy")
        try required(app.descendants(matching: .any)["public-information-privacy"].firstMatch, "Privacy Policy document")
        capture("ipad-release-privacy", app: app)
        try tap(app.buttons["Done"], "close privacy document")
        try tap(app.buttons["App Support"], "pre-login App Support")
        try required(app.descendants(matching: .any)["public-information-support"].firstMatch, "App Support document")
        capture("ipad-release-support", app: app)
        try tap(app.buttons["Done"], "close support document")

        try tap(app.buttons["open-preview"], "fictional preview entry")
        try required(navigation("Home", app: app), "Home navigation")
        capture("ipad-fictional-home-portrait", app: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        try required(navigation("Search", app: app), "landscape Search navigation")
        capture("ipad-fictional-home-landscape", app: app)

        try tap(navigation("Search", app: app), "Search navigation")
        let search = app.textFields["library-search"]
        try tap(search, "library search field")
        search.typeText("Light")
        let movie = title("The Last Light", identifier: "item-00000000000000000000000000000001", app: app)
        try tap(movie, "fictional movie search result")
        try required(app.buttons["detail-back"], "movie detail navigation")
        try required(app.staticTexts["The Last Light"].firstMatch, "movie title")
        capture("ipad-fictional-movie-detail-landscape", app: app)
        // The fictional library has no media streams or file metadata. Only
        // exercise File details if the fixture actually provides that action.
        let fileDetails = app.buttons.matching(NSPredicate(format:
            "identifier == %@ OR label == %@", "detail-file-info", "File details")).firstMatch
        if fileDetails.exists {
            try tap(fileDetails, "File details action")
            capture("ipad-fictional-file-details", app: app)
            try tap(app.buttons["Done"], "close File details")
        }
        try tap(app.buttons["detail-back"], "return from movie")

        try tap(navigation("Search", app: app), "return to Search root")
        let searchAgain = app.textFields["library-search"]
        try tap(searchAgain, "search field for series")
        if app.buttons["clear-search"].exists { app.buttons["clear-search"].tap() }
        searchAgain.typeText("Orbital")
        try tap(title("Orbital", identifier: "item-00000000000000000000000000000020", app: app), "fictional series search result")
        let episodes = app.descendants(matching: .any)["episode-browser-list"].firstMatch
        for _ in 0..<6 where !episodes.isHittable { app.swipeUp() }
        try required(episodes, "vertical episode list")
        capture("ipad-fictional-episodes-landscape", app: app)
        XCUIDevice.shared.orientation = .portrait
        capture("ipad-fictional-episodes-portrait", app: app)
        try tap(app.buttons["detail-back"], "return from series")
        try tap(navigation("Profile", app: app), "Profile navigation")
        capture("ipad-fictional-profile", app: app)
        try tap(app.buttons["profile-sign-out"], "Leave preview")
        try required(app.textFields["server-address"], "restored empty connection setup")
        capture("ipad-release-connect-restored", app: app)
    }
}
