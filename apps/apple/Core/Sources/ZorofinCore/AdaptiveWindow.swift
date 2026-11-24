import Foundation

/// Layout follows the live scene, never a device model, orientation, or screen.
public struct AdaptiveWindow: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public init(width: Double, height: Double) {
        self.width = width.isFinite ? max(0, width) : 0
        self.height = height.isFinite ? max(0, height) : 0
    }
    public var usesTabletLayout: Bool { width >= 700 && height >= 560 }
    public var contentWidth: Double { width }
    public var usesWideContent: Bool { contentWidth >= 700 && height >= 440 }
    public var posterWidth: Double { usesWideContent ? 180 : 148 }
    public var landscapeCardWidth: Double { usesWideContent ? 320 : 270 }
    public var heroHeight: Double { usesWideContent ? min(520, max(380, width * 0.5)) : 470 }
}
