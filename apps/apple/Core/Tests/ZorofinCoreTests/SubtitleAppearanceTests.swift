import Testing
import AVFoundation
import CoreMedia
@testable import ZorofinCore

@Suite("Native subtitle appearance") struct SubtitleAppearanceTests {
    @Test @MainActor func stylingReachesEveryReplacementPlayerItem() throws {
        var appearance = SubtitleAppearance()
        appearance.size = 125; appearance.color = .yellow; appearance.bold = true
        let player = AVPlayer()
        let url = try #require(Bundle.module.url(forResource: "player-preparation", withExtension: "mp4", subdirectory: "Fixtures"))
        let driver = AVPlayerPreparationDriver(player: player, url: url, allowsLiveResourcesWhilePaused: false,
                                              subtitleAppearance: appearance, isActive: { true })
        driver.load()
        let first = try #require(player.currentItem)
        driver.load()
        let replacement = try #require(player.currentItem)
        #expect(first !== replacement)
        for item in [first, replacement] {
            let attributes = try #require(item.textStyleRules?.first?.textMarkupAttributes)
            #expect(attributes[kCMTextMarkupAttribute_RelativeFontSize as String] as? Int == 125)
            #expect(attributes[kCMTextMarkupAttribute_ForegroundColorARGB as String] as? [Double] == [1, 1, 1, 0])
            #expect(attributes[kCMTextMarkupAttribute_BoldStyle as String] as? Bool == true)
        }
        player.replaceCurrentItem(with: nil)
        let systemDriver = AVPlayerPreparationDriver(player: player, url: url, allowsLiveResourcesWhilePaused: false, isActive: { true })
        systemDriver.load()
        #expect(player.currentItem?.textStyleRules?.isEmpty != false)
        player.replaceCurrentItem(with: nil)
    }
}
