import Foundation

/// nil in NativePreferences leaves rendering to the media and system caption
/// preferences. These choices apply only to text subtitles, never burned-in video.
public struct SubtitleAppearance: Codable, Sendable, Equatable {
    public enum TextColor: String, Codable, Sendable, CaseIterable { case white, yellow }
    public var size = 100
    public var color = TextColor.white
    public var backgroundOpacity = 0.65
    public var bold = false
    public init() {}
    public var isValid: Bool {
        [80, 100, 125, 150].contains(size) && [0.0, 0.65, 1.0].contains(backgroundOpacity)
    }
}

#if canImport(AVFoundation)
import AVFoundation
import CoreMedia

public extension SubtitleAppearance {
    /// Apple applies these defaults to supported text tracks. Embedded style and
    /// accessibility choices may take precedence; image subtitles cannot be styled.
    func textStyleRules() -> [AVTextStyleRule]? {
        guard isValid else { return nil }
        let foreground: [Double] = color == .yellow ? [1, 1, 1, 0] : [1, 1, 1, 1]
        guard let rule = AVTextStyleRule(textMarkupAttributes: [
            kCMTextMarkupAttribute_RelativeFontSize as String: size,
            kCMTextMarkupAttribute_ForegroundColorARGB as String: foreground,
            kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String: [backgroundOpacity, 0.0, 0.0, 0.0],
            kCMTextMarkupAttribute_BoldStyle as String: bold
        ]) else { return nil }
        return [rule]
    }
}
#endif
