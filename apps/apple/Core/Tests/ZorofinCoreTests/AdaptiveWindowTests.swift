import Testing
@testable import ZorofinCore

struct AdaptiveWindowTests {
    @Test func resizingBetweenPhoneTabletAndShallowWindows() {
        let narrow = AdaptiveWindow(width: 390, height: 844)
        #expect(!narrow.usesTabletLayout && !narrow.usesWideContent)
        let tablet = AdaptiveWindow(width: 1024, height: 768)
        #expect(tablet.usesTabletLayout && tablet.usesWideContent)
        #expect(tablet.contentWidth == 1024)
        let shallow = AdaptiveWindow(width: 844, height: 390)
        #expect(!shallow.usesTabletLayout && !shallow.usesWideContent)
        let split = AdaptiveWindow(width: 500, height: 1024)
        #expect(!split.usesTabletLayout && !split.usesWideContent)
    }
    @Test func tabletUsesTheWholeWidthForCinematicContent() {
        let window = AdaptiveWindow(width: 760, height: 600)
        #expect(window.usesTabletLayout)
        #expect(window.contentWidth == 760)
        #expect(window.usesWideContent)
        #expect(AdaptiveWindow(width: 800, height: 600).usesWideContent)
        #expect(window.posterWidth == 180 && window.landscapeCardWidth == 320)
        #expect(window.heroHeight == 380)
        #expect(AdaptiveWindow(width: 1366, height: 1024).heroHeight == 520)
    }
    @Test func invalidGeometryIsSafe() {
        let window = AdaptiveWindow(width: .infinity, height: -.infinity)
        #expect(window.width == 0 && window.height == 0)
        #expect(AdaptiveWindow(width: -4, height: .nan).contentWidth == 0)
    }
}
