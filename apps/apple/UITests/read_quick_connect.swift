// Recognize only a visible six-digit Quick Connect challenge from a private
// device screenshot. The code is written to a mode-600 file, never stdout.
import Foundation
import ImageIO
import Vision

guard CommandLine.arguments.count == 3 else { exit(2) }
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { exit(3) }
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: image).perform([request])
let codes = Set((request.results ?? []).compactMap { result -> String? in
    guard let text = result.topCandidates(1).first?.string else { return nil }
    let compact = text.filter { !$0.isWhitespace }
    return compact.count == 6 && compact.allSatisfy(\.isNumber) ? compact : nil
})
guard codes.count == 1, let code = codes.first else {
    fputs("Expected one visible Quick Connect challenge\n", stderr); exit(4)
}
let data = try JSONSerialization.data(withJSONObject: ["code": code])
guard FileManager.default.createFile(atPath: output.path, contents: data,
                                    attributes: [.posixPermissions: 0o600]) else { exit(5) }
print("Recognized one challenge; value kept private")
