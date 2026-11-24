#!/usr/bin/env swift
// Export the approved artwork without redrawing it. Run with the macOS SDK.
import Foundation
import CoreGraphics
import CoreText
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default
let metadata: [String: Any] = ["author": "org.zorofin.app", "version": 1]

func image(_ name: String) throws -> CGImage {
    let url = root.appendingPathComponent("Branding/" + name)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "IconExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot read \(url.path)"])
    }
    return image
}

func json(_ directory: URL, _ content: [String: Any]) throws {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    var data = try JSONSerialization.data(withJSONObject: content, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(10)
    try data.write(to: directory.appendingPathComponent("Contents.json"))
}

func export(_ artwork: CGImage?, width: Int, height: Int, fill: CGFloat = 1,
            transparent: Bool = false, to url: URL) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let alpha: CGImageAlphaInfo = transparent ? .premultipliedLast : .noneSkipLast
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: colorSpace, bitmapInfo: alpha.rawValue) else {
        throw NSError(domain: "IconExport", code: 2)
    }
    if !transparent {
        context.setFillColor(CGColor(srgbRed: 12/255, green: 16/255, blue: 15/255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    if let artwork {
        let scale = min(CGFloat(width) / CGFloat(artwork.width), CGFloat(height) / CGFloat(artwork.height)) * fill
        let w = CGFloat(artwork.width) * scale, h = CGFloat(artwork.height) * scale
        context.interpolationQuality = .high
        context.draw(artwork, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
    }
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let output = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "IconExport", code: 3)
    }
    CGImageDestinationAddImage(destination, output, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "IconExport", code: 4) }
}

let approved = try image("R5/master.png")
let foreground = approved
let ios = root.appendingPathComponent("Resources/iOS/Assets.xcassets")
try json(ios, ["info": metadata])
let appIcon = ios.appendingPathComponent("AppIcon.appiconset")
try json(appIcon, ["info": metadata, "images": [["filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]]])
try export(approved, width: 1024, height: 1024, fill: 0.86, to: appIcon.appendingPathComponent("AppIcon.png"))

let tv = root.appendingPathComponent("Resources/tvOS/Assets.xcassets")
try json(tv, ["info": metadata])
let brand = tv.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
try json(brand, ["info": metadata, "assets": [
    ["idiom": "tv", "size": "400x240", "filename": "App Icon.imagestack", "role": "primary-app-icon"],
    ["idiom": "tv", "size": "1280x768", "filename": "App Icon - App Store.imagestack", "role": "primary-app-icon"],
    ["idiom": "tv", "size": "1920x720", "filename": "Top Shelf Image.imageset", "role": "top-shelf-image"],
    ["idiom": "tv", "size": "2320x720", "filename": "Top Shelf Image Wide.imageset", "role": "top-shelf-image-wide"]
]])

for (name, width, height, scales) in [("App Icon", 400, 240, [1, 2]), ("App Icon - App Store", 1280, 768, [1])] {
    let stack = brand.appendingPathComponent(name + ".imagestack")
    try json(stack, ["info": metadata, "layers": [["filename": "Foreground.imagestacklayer"], ["filename": "Background.imagestacklayer"]]])
    for layerName in ["Foreground", "Background"] {
        let layer = stack.appendingPathComponent(layerName + ".imagestacklayer")
        try json(layer, ["info": metadata])
        let set = layer.appendingPathComponent("Content.imageset")
        try json(set, ["info": metadata, "images": scales.map { ["idiom": "tv", "scale": "\($0)x", "filename": "\(layerName)-\($0)x.png"] }])
        for scale in scales {
            let isForeground = layerName == "Foreground"
            try export(isForeground ? foreground : nil, width: width * scale, height: height * scale,
                       fill: 0.84, transparent: isForeground,
                       to: set.appendingPathComponent("\(layerName)-\(scale)x.png"))
        }
    }
}

for (name, width) in [("Top Shelf Image", 1920), ("Top Shelf Image Wide", 2320)] {
    let set = brand.appendingPathComponent(name + ".imageset")
    try json(set, ["info": metadata, "images": [1, 2].map { ["idiom": "tv", "scale": "\($0)x", "filename": "TopShelf-\($0)x.png"] }])
    for scale in [1, 2] {
        try export(approved, width: width * scale, height: 720 * scale, fill: 0.82,
                   to: set.appendingPathComponent("TopShelf-\(scale)x.png"))
    }
}

// Non-bundled previews include the actual tvOS foreground over its black back layer.
let previews = root.appendingPathComponent("Branding/Previews")
try export(approved, width: 120, height: 120, fill: 0.86, to: previews.appendingPathComponent("iOS-120.png"))
try export(foreground, width: 800, height: 480, fill: 0.84, to: previews.appendingPathComponent("tvOS-800.png"))
print("Exported iOS icon, tvOS layered icons, Top Shelf images and previews")

// The same R5 master also supplies in-app, browser and public-site branding.
let repository = root.deletingLastPathComponent().deletingLastPathComponent()
let source = repository.appendingPathComponent("branding/src")
let dist = repository.appendingPathComponent("branding/dist")
try fm.createDirectory(at: source, withIntermediateDirectories: true)
try fm.createDirectory(at: dist, withIntermediateDirectories: true)
let green = CGColor(srgbRed: 33/255, green: 187/255, blue: 98/255, alpha: 1)
let white = CGColor(srgbRed: 242/255, green: 245/255, blue: 241/255, alpha: 1)
let backdrop = CGColor(srgbRed: 12/255, green: 16/255, blue: 15/255, alpha: 1)

func raster(width: Int, height: Int, transparent: Bool = true, to url: URL,
            draw: (CGContext) -> Void) throws {
    let alpha: CGImageAlphaInfo = transparent ? .premultipliedLast : .noneSkipLast
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)!
    if !transparent { context.setFillColor(backdrop); context.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
    context.interpolationQuality = .high
    draw(context)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "BrandExport", code: 1) }
}

func wordmarkLine(size: CGFloat) -> CTLine {
    let text = NSMutableAttributedString(string: "ZOROFIN", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("AvenirNext-Heavy" as CFString, size, nil),
        NSAttributedString.Key(kCTKernAttributeName as String): size * 0.025,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): white])
    text.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: green, range: NSRange(location: 0, length: 4))
    return CTLineCreateWithAttributedString(text)
}
func drawWordmark(_ context: CGContext, size: CGFloat, x: CGFloat, y: CGFloat, centered: Bool = false) {
    let line = wordmarkLine(size: size)
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    context.textPosition = CGPoint(x: centered ? x - width / 2 : x, y: y)
    CTLineDraw(line, context)
}

for platform in ["iOS", "tvOS"] {
    try export(foreground, width: 1280, height: 1280, transparent: true,
        to: root.appendingPathComponent("Resources/\(platform)/Assets.xcassets/HeaderLogo.imageset/HeaderLogo.png"))
}
let wordmarkURL = dist.appendingPathComponent("wordmark.png")
try raster(width: 1240, height: 300, to: wordmarkURL) { c in
    c.draw(foreground, in: CGRect(x: 0, y: 0, width: 300, height: 300))
    drawWordmark(c, size: 170, x: 330, y: 85)
}
try Data(contentsOf: wordmarkURL).write(to: root.appendingPathComponent("Resources/wordmark.png"))
try export(foreground, width: 1280, height: 1280, transparent: true, to: source.appendingPathComponent("zoro-mark.png"))
try export(foreground, width: 512, height: 512, transparent: true, to: dist.appendingPathComponent("mark-512.png"))
try export(approved, width: 1024, height: 1024, fill: 0.86, to: root.appendingPathComponent("Branding/pirate-icon-approved.png"))
try export(foreground, width: 1280, height: 1280, transparent: true, to: root.appendingPathComponent("Branding/pirate-icon-foreground.png"))
for size in [32, 72, 114, 144, 180, 512] {
    try export(approved, width: size, height: size, fill: 0.86, to: dist.appendingPathComponent("tile-\(size).png"))
}
try raster(width: 800, height: 900, to: dist.appendingPathComponent("splash.png")) { c in
    c.draw(foreground, in: CGRect(x: 70, y: 235, width: 660, height: 660))
    drawWordmark(c, size: 132, x: 400, y: 95, centered: true)
}
try raster(width: 1200, height: 630, transparent: false, to: dist.appendingPathComponent("og-image.png")) { c in
    c.draw(foreground, in: CGRect(x: 455, y: 280, width: 290, height: 290))
    drawWordmark(c, size: 128, x: 600, y: 165, centered: true)
    let caption = NSAttributedString(string: "YOUR LIBRARY. YOUR SERVER.", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("AvenirNext-Medium" as CFString, 28, nil),
        NSAttributedString.Key(kCTKernAttributeName as String): 3,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): white])
    let line = CTLineCreateWithAttributedString(caption)
    c.textPosition = CGPoint(x: 600 - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) / 2, y: 92)
    CTLineDraw(line, c)
}
let png = try Data(contentsOf: dist.appendingPathComponent("tile-32.png"))
var ico = Data()
func appendLE<T: FixedWidthInteger>(_ number: T) { var n = number.littleEndian; withUnsafeBytes(of: &n) { ico.append(contentsOf: $0) } }
appendLE(UInt16(0)); appendLE(UInt16(1)); appendLE(UInt16(1))
ico.append(contentsOf: [32, 32, 0, 0]); appendLE(UInt16(1)); appendLE(UInt16(32)); appendLE(UInt32(png.count)); appendLE(UInt32(22)); ico.append(png)
try ico.write(to: dist.appendingPathComponent("favicon.ico"))

// Standalone SVG lockups retain the same raster master; no browser renderer is required.
let uri = "data:image/png;base64," + (try Data(contentsOf: source.appendingPathComponent("zoro-mark.png"))).base64EncodedString()
let svgText = "<text font-family=\"Avenir Next,Helvetica Neue,Arial,sans-serif\" font-weight=\"800\" letter-spacing=\"4\""
let label = "<tspan fill=\"#21bb62\">ZORO</tspan><tspan fill=\"#f2f5f1\">FIN</tspan></text>"
let svgs: [String: String] = [
    "zorofin-mark.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1280 1280\"><image href=\"\(uri)\" width=\"1280\" height=\"1280\"/></svg>",
    "zorofin-wordmark.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1240 300\"><image href=\"\(uri)\" width=\"300\" height=\"300\"/>\(svgText) x=\"330\" y=\"215\" font-size=\"170\">\(label)</svg>",
    "zorofin-tile.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 512 512\"><rect width=\"512\" height=\"512\" rx=\"100\" fill=\"#0c100f\"/><image href=\"\(uri)\" x=\"36\" y=\"36\" width=\"440\" height=\"440\"/></svg>",
    "zorofin-splash.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 800 900\"><image href=\"\(uri)\" x=\"70\" width=\"660\" height=\"660\"/>\(svgText) x=\"400\" y=\"805\" text-anchor=\"middle\" font-size=\"132\">\(label)</svg>",
    "zorofin-og.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1200 630\"><rect width=\"1200\" height=\"630\" fill=\"#0c100f\"/><image href=\"\(uri)\" x=\"455\" y=\"60\" width=\"290\" height=\"290\"/>\(svgText) x=\"600\" y=\"465\" text-anchor=\"middle\" font-size=\"128\">\(label)</svg>"
]
for (name, svg) in svgs { try (svg + "\n").write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8) }
print("Exported matching R5 in-app headers, wordmark, web icons, splash, social card and SVG lockups")

// The account portal consumes static artwork only; its runtime logic is untouched.
let portalImages = repository.appendingPathComponent("billing-gateway/public/img")
let portalAccess = repository.appendingPathComponent("billing-gateway/public/access")
for name in ["og-image.png", "mark-512.png", "wordmark.png", "tile-180.png", "favicon.ico"] {
    if fm.fileExists(atPath: portalImages.path) { try Data(contentsOf: dist.appendingPathComponent(name)).write(to: portalImages.appendingPathComponent(name)) }
}
if fm.fileExists(atPath: portalAccess.path) {
    try Data(contentsOf: wordmarkURL).write(to: portalAccess.appendingPathComponent("brand.png"))
    try Data(contentsOf: dist.appendingPathComponent("tile-180.png")).write(to: portalAccess.appendingPathComponent("share-icon.png"))
}

// Keep existing share URLs working while the next metadata load adopts a new hash.
let socialPNG = CGImageSourceCreateWithURL(dist.appendingPathComponent("og-image.png") as CFURL, nil)!
let socialImage = CGImageSourceCreateImageAtIndex(socialPNG, 0, nil)!
let socialJPEG = dist.appendingPathComponent("og-image.jpg")
let jpegOutput = CGImageDestinationCreateWithURL(socialJPEG as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(jpegOutput, socialImage, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
guard CGImageDestinationFinalize(jpegOutput) else { throw NSError(domain: "BrandExport", code: 2) }
let jpegData = try Data(contentsOf: socialJPEG)
let socialHash = SHA256.hash(data: jpegData).map { String(format: "%02x", $0) }.joined().prefix(12)
let socialName = "share-card-\(socialHash).jpg"
let shareManifestURL = portalAccess.appendingPathComponent("share-manifest.json")
if let old = try? JSONSerialization.jsonObject(with: Data(contentsOf: shareManifestURL)) as? [String: Any],
   let oldName = old["image"] as? String, oldName.range(of: #"^share-card-[a-f0-9]{12}\.jpg$"#, options: .regularExpression) != nil {
    try jpegData.write(to: portalAccess.appendingPathComponent(oldName))
}
try jpegData.write(to: portalAccess.appendingPathComponent(socialName))
var shareData = try JSONSerialization.data(withJSONObject: ["image": socialName, "width": 1200, "height": 630, "bytes": jpegData.count], options: [.prettyPrinted, .sortedKeys])
shareData.append(10)
try shareData.write(to: shareManifestURL)
