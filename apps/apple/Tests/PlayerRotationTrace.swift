import AVFoundation
import UIKit
import XCTest
@testable import Zorofin_iOS

/// Numeric test evidence only. Captures transition frames without declaring
/// animated intermediate bounds to be a persistent layout failure.
@MainActor final class PlayerRotationTrace {
    private let window: UIWindow
    private let cover: UIViewController
    private let surface: UIView
    private let layer: AVPlayerLayer
    private let controls: @MainActor () -> PlayerControlsSnapshot?
    private let started = ProcessInfo.processInfo.systemUptime
    private var sampler: Task<Void, Never>?
    private var observation: NSKeyValueObservation?
    private var samples: [[String: Any]] = []
    private var stage = "before-media-setup"
    private var finished = false
    private weak var previousItem: AVPlayerItem?
    private var itemGeneration = 0
    private(set) var firstFrameAt: Double?

    init(window: UIWindow, cover: UIViewController, surface: UIView,
         controls: @escaping @MainActor () -> PlayerControlsSnapshot?) {
        self.window = window; self.cover = cover; self.surface = surface
        layer = surface.layer as! AVPlayerLayer
        self.controls = controls
        observation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay, observedAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                guard let self, !self.finished else { return }
                if ready, self.firstFrameAt == nil { self.firstFrameAt = observedAt }
                self.capture("render-readiness-change")
            }
        }
        capture("start")
        sampler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.capture("sample")
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }

    func mark(_ value: String) { stage = value; capture("marker") }

    private func number(_ value: Double) -> Any {
        value.isFinite ? (value * 1000).rounded() / 1000 : NSNull()
    }
    private func rect(_ value: CGRect) -> [Any] {
        [value.minX, value.minY, value.width, value.height].map { number(Double($0)) }
    }
    private func insets(_ value: UIEdgeInsets) -> [Any] {
        [value.top, value.left, value.bottom, value.right].map { number(Double($0)) }
    }
    private func transform(_ value: CGAffineTransform) -> [Any] {
        [value.a, value.b, value.c, value.d, value.tx, value.ty].map { number(Double($0)) }
    }

    func capture(_ reason: String) {
        guard !finished, samples.count < 8000 else { return }
        let player = layer.player, item = player?.currentItem, state = controls()
        if let item, item !== previousItem { itemGeneration += 1; previousItem = item }
        let viewport = state?.viewport ?? .zero
        samples.append([
            "t": number(ProcessInfo.processInfo.systemUptime - started), "reason": reason, "stage": stage,
            "orientation": window.windowScene?.interfaceOrientation.rawValue ?? 0,
            "horizontalSizeClass": cover.traitCollection.horizontalSizeClass.rawValue,
            "verticalSizeClass": cover.traitCollection.verticalSizeClass.rawValue,
            "transitionActive": cover.transitionCoordinator != nil,
            "windowBounds": rect(window.bounds), "windowSafeRect": rect(window.safeAreaLayoutGuide.layoutFrame),
            "windowSafeInsets": insets(window.safeAreaInsets), "coverBounds": rect(cover.view.bounds),
            "coverFrame": rect(cover.view.frame), "coverSafeInsets": insets(cover.view.safeAreaInsets),
            "coverTransform": transform(cover.view.transform), "surfaceFrame": rect(surface.frame),
            "surfaceBounds": rect(surface.bounds), "surfaceInWindow": rect(surface.convert(surface.bounds, to: window)),
            "surfaceSafeInsets": insets(surface.safeAreaInsets), "surfaceTransform": transform(surface.transform),
            "layerFrame": rect(layer.frame), "layerBounds": rect(layer.bounds), "videoRect": rect(layer.videoRect),
            "presentationLayerFrame": rect(layer.presentation()?.frame ?? .zero),
            "readyForDisplay": layer.isReadyForDisplay, "itemGeneration": itemGeneration,
            "itemStatus": item?.status.rawValue ?? -1, "hasItem": item != nil,
            "timeControl": player?.timeControlStatus.rawValue ?? -1,
            "mediaTime": number(player?.currentTime().seconds ?? .nan),
            "presentationSize": [number(Double(item?.presentationSize.width ?? 0)), number(Double(item?.presentationSize.height ?? 0))],
            "phase": state?.phase.rawValue ?? "unknown", "controlsVisible": state?.visible as Any? ?? NSNull(),
            "controlsViewport": [number(Double(viewport.width)), number(Double(viewport.height))]
        ])
    }

    func finish(name: String, requests: [PlayerHLSOrigin.RequestEvent]) throws -> XCTAttachment {
        capture("finish")
        finished = true; sampler?.cancel(); sampler = nil; observation?.invalidate(); observation = nil
        let network: [[String: Any]] = requests.map { request in
            ["path": request.path, "requestedAt": number(request.requestedAt - started), "held": request.held,
             "respondedAt": request.respondedAt.map { number($0 - started) } ?? NSNull(),
             "sendCompletedAt": request.sendCompletedAt.map { number($0 - started) } ?? NSNull(),
             "sendFailed": request.sendFailed as Any? ?? NSNull()]
        }
        let payload: [String: Any] = [
            "schema": 1, "case": name, "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "os": UIDevice.current.systemVersion,
            "simulatorModel": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown",
            "firstFrameAt": firstFrameAt.map { number($0 - started) } ?? NSNull(),
            "samples": samples, "requests": network]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: payload), uniformTypeIdentifier: "public.json")
        attachment.name = "rotation-\(name)-geometry"; attachment.lifetime = .keepAlways
        print("Player delayed replay: case=\(name) samples=\(samples.count) itemGenerations=\(itemGeneration) firstFrame=\(firstFrameAt.map { $0 - started } ?? -1)")
        return attachment
    }
}
