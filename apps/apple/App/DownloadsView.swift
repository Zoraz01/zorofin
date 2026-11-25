#if os(iOS)
import SwiftUI
import AVKit
import ZorofinCore

/// The Downloads tab: saved titles, active downloads and storage use.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    private var downloads: DownloadManager { DownloadManager.shared }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmRemoveAll = false
    @State private var editing = false
    @State private var selectedIDs = Set<String>()
    @State private var confirmRemoveSelected = false

    var body: some View {
        let records = downloads.records
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button { dismiss() } label: {
                    Label("Profile", systemImage: "chevron.left")
                        .font(Theme.font(15)).frame(minHeight: Theme.target)
                }.buttonStyle(ZoroButtonStyle()).foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("downloads-back")
                HStack {
                    Text("Downloads").font(Theme.font(30, weight: .bold, relativeTo: .title)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if !records.isEmpty {
                        Button(editing ? "Done" : "Edit") { editing.toggle(); selectedIDs.removeAll() }
                            .buttonStyle(ZoroButtonStyle()).accessibilityIdentifier("downloads-edit")
                    }
                }
                if !downloads.isOnline {
                    Label("You're offline. Your downloads still play.", systemImage: "wifi.slash")
                        .font(Theme.font(15, weight: .medium)).foregroundStyle(Theme.jade)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                }
                storage
                if model.isDemo {
                    StatusView(title: "Downloads need your server",
                               detail: "Connect your server to save movies and episodes for offline viewing.",
                               icon: "arrow.down.circle")
                } else if records.isEmpty {
                    StatusView(title: "No downloads yet",
                               detail: "Tap the download button on a movie or episode to watch it without a connection.",
                               icon: "arrow.down.circle")
                    Button("Browse titles to download") { dismiss(); model.pendingBrowseDownloads = true }
                        .buttonStyle(ZoroButtonStyle(primary: true)).accessibilityIdentifier("downloads-browse")
                } else {
                    ForEach(DownloadGroup.groups(records)) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            if group.isSeries { SectionTitle(title: group.title) }
                            ForEach(group.records) { record in
                                DownloadRow(record: record, selected: selectedIDs.contains(record.id), onSelect: editing ? {
                                    if selectedIDs.contains(record.id) { selectedIDs.remove(record.id) }
                                    else { selectedIDs.insert(record.id) }
                                } : nil)
                            }
                        }
                    }
                    if editing {
                        Button("Remove selected (\(selectedIDs.count))", role: .destructive) { confirmRemoveSelected = true }
                            .buttonStyle(ZoroButtonStyle()).disabled(selectedIDs.isEmpty)
                            .accessibilityIdentifier("downloads-remove-selected")
                    }
                    Button(role: .destructive) { confirmRemoveAll = true } label: {
                        Label("Remove all downloads", systemImage: "trash").frame(maxWidth: .infinity)
                    }.buttonStyle(ZoroButtonStyle()).padding(.top, 8)
                        .accessibilityIdentifier("downloads-remove-all")
                }
            }.frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, Theme.gutter).padding(.top, 20).padding(.bottom, 32)
                .frame(maxWidth: .infinity)
        }.background(Theme.background)
            .confirmationDialog("Remove all downloads?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
                Button("Remove all", role: .destructive) { downloads.removeAll() }
            } message: { Text("Downloaded titles are deleted from this device. Your library on the server is not affected.") }
            .confirmationDialog("Remove selected downloads?", isPresented: $confirmRemoveSelected, titleVisibility: .visible) {
                Button("Remove selected", role: .destructive) {
                    let visible = Set(downloads.records.map(\.id))
                    for id in selectedIDs.intersection(visible) { downloads.remove(id) }
                    selectedIDs.removeAll()
                }
            } message: { Text("Selected copies are removed from this device and active downloads are cancelled. Your server library is unchanged.") }
            .onChange(of: model.generation) { _, _ in selectedIDs.removeAll(); editing = false; confirmRemoveSelected = false }
            .accessibilityIdentifier("downloads-screen")
            .modifier(HideNavigationBar())
            .task(id: "\(model.generation)-\(scenePhase == .active)") {
                if scenePhase == .active { await downloads.refreshDownloadPermission() }
            }
    }

    private var storage: some View {
        let used = downloads.usedBytes
        let free = downloads.freeBytes ?? 0
        let total = Double(used + free)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Storage").font(Theme.font(16, weight: .semibold))
                Spacer()
                Text("\(DownloadFormat.bytes(used)) used · \(DownloadFormat.bytes(free)) free")
                    .font(Theme.font(14)).foregroundStyle(Theme.muted)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border.opacity(0.6))
                    Capsule().fill(Theme.jade)
                        .frame(width: total > 0 ? max(used > 0 ? 6 : 0, geometry.size.width * Double(used) / total) : 0)
                }
            }.frame(height: 6)
        }.padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
    }
}

private struct DownloadRow: View {
    @Environment(AppModel.self) private var model
    let record: DownloadRecord
    var selected = false
    var onSelect: (() -> Void)? = nil
    @State private var confirmRemove = false
    private var downloads: DownloadManager { DownloadManager.shared }
    private var landscape: Bool { record.item.isEpisode }

    var body: some View {
        HStack(spacing: 12) {
            if let onSelect {
                Button(action: onSelect) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Theme.jade : Theme.muted).frame(width: Theme.target, height: Theme.target)
                }.buttonStyle(.plain).accessibilityLabel((selected ? "Deselect " : "Select ") + record.item.displayTitle)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Button { if let onSelect { onSelect() } else { play() } } label: {
                HStack(spacing: 14) {
                    artwork
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.item.isEpisode ? record.item.episodeLabel : record.item.name)
                            .font(Theme.font(16, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                        status
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(onSelect == nil && !record.isPlayable)
                .accessibilityHint(onSelect != nil ? "Changes selection" : record.isPlayable ? "Plays the downloaded copy" : "")
            if onSelect == nil {
                Menu {
                    if record.status == .failed {
                        Button { retryDownload(record.id, model: model) } label: { Label("Try again", systemImage: "arrow.clockwise") }
                            .disabled(!downloads.canRequestDownload)
                    }
                    if record.isPlayable { Button { play() } label: { Label("Play", systemImage: "play.fill") } }
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Label(record.status.isActive ? "Cancel download" : "Remove download", systemImage: record.status.isActive ? "xmark" : "trash")
                    }
                } label: { Image(systemName: "ellipsis").frame(width: Theme.target, height: Theme.target) }
                    .accessibilityLabel("Options for \(record.item.displayTitle)")
            }
        }.foregroundStyle(Theme.text)
            .confirmationDialog(record.status.isActive ? "Cancel this download?" : "Remove this download?",
                                isPresented: $confirmRemove, titleVisibility: .visible) {
                Button(record.status.isActive ? "Cancel download" : "Remove", role: .destructive) { downloads.remove(record.id) }
            }
    }
    private var artwork: some View {
        ZStack {
            if let image = downloads.artwork(for: record) { Image(uiImage: image).resizable().scaledToFill() }
            else { PreviewArtwork(title: record.item.displayTitle, seed: record.item.id, showTitle: false) }
            if record.isPlayable {
                Image(systemName: "play.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(.black.opacity(0.55), in: Circle())
            }
        }.frame(width: landscape ? (onSelect == nil ? 128 : 96) : 72, height: landscape ? (onSelect == nil ? 72 : 54) : 108)
            .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
    }

    @ViewBuilder private var status: some View {
        switch record.status {
        case .completed:
            Text([record.item.isEpisode ? nil : record.item.productionYear.map(String.init),
                  record.item.durationLabel.isEmpty ? nil : record.item.durationLabel,
                  DownloadFormat.bytes(record.bytesWritten), record.quality.title]
                .compactMap { $0 }.joined(separator: " · "))
                .font(Theme.font(13)).foregroundStyle(Theme.muted)
            if record.resumeTicks > 0, let total = record.item.runTimeTicks, total > 0 {
                ProgressView(value: min(1, Double(record.resumeTicks) / Double(total))).tint(Theme.jade)
            }
        case .queued, .downloading:
            ProgressView(value: record.progress).tint(Theme.jade)
            Text(progressText).font(Theme.font(13)).foregroundStyle(Theme.muted)
        case .failed:
            Text(record.failure ?? "The download stopped.").font(Theme.font(13)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progressText: String {
        if record.status == .queued { return downloads.isOnline ? "Waiting to download" : "Waiting for a connection" }
        let percent = Int((record.progress * 100).rounded())
        if let expected = record.expectedBytes, expected > 0 {
            return "\(percent)% · \(DownloadFormat.bytes(record.bytesWritten)) of about \(DownloadFormat.bytes(expected))"
        }
        return "\(percent)% downloaded"
    }

    private func play() {
        guard record.isPlayable else { return }
        OfflinePlayback.present(record, startTicks: record.resumeTicks, watchTogether: model.watchTogether.isJoined) { message in
            model.message = message
        }
    }
}

/// The download control on a movie or episode page.
struct DownloadButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let item: MediaItem
    let audioIndex: Int?
    let subtitleIndex: Int
    @State private var confirmRemove = false
    private var downloads: DownloadManager { DownloadManager.shared }

    var body: some View {
        let record = downloads.record(itemID: item.id)
        Menu {
            switch record?.status {
            case .none:
                Section("Download quality") {
                    ForEach(DownloadQuality.allCases) { quality in
                        Button { start(quality) } label: {
                            Text(quality.title)
                            Text(sizeLabel(quality))
                        }
                    }
                }
            case .queued?, .downloading?:
                Text(record?.status == .queued ? "Waiting to download" : "Downloading · \(Int(((record?.progress ?? 0) * 100).rounded()))%")
                Button(role: .destructive) { confirmRemove = true } label: { Label("Cancel download", systemImage: "xmark") }
            case .completed?:
                Text("Downloaded · \(DownloadFormat.bytes(record?.bytesWritten ?? 0))")
                Button(role: .destructive) { confirmRemove = true } label: { Label("Remove download", systemImage: "trash") }
            case .failed?:
                Text(record?.failure ?? "The download stopped.")
                Button { if let record { retryDownload(record.id, model: model) } } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .disabled(!downloads.canRequestDownload)
                Button(role: .destructive) { confirmRemove = true } label: { Label("Remove", systemImage: "trash") }
            }
        } label: {
            icon(record)
        }.buttonStyle(DetailIconStyle()).disabled(record == nil && (model.isDemo || !downloads.canRequestDownload))
            .accessibilityLabel(accessibilityLabel(record))
            .help(accessibilityLabel(record))
            .accessibilityIdentifier("detail-download")
            .task(id: "\(model.generation)-\(scenePhase == .active)") {
                if scenePhase == .active { await downloads.refreshDownloadPermission() }
            }
            .confirmationDialog(record?.status.isActive == true ? "Cancel this download?" : "Remove this download?",
                                isPresented: $confirmRemove, titleVisibility: .visible) {
                Button(record?.status.isActive == true ? "Cancel download" : "Remove", role: .destructive) {
                    if let record { downloads.remove(record.id) }
                }
            }
    }

    @ViewBuilder private func icon(_ record: DownloadRecord?) -> some View {
        switch record?.status {
        case .queued?, .downloading?:
            ZStack {
                Circle().stroke(Theme.border, lineWidth: 2.5)
                Circle().trim(from: 0, to: max(0.03, record?.progress ?? 0))
                    .stroke(Theme.jade, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "stop.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.jade)
            }.frame(width: 22, height: 22)
        case .completed?:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.jade)
        case .failed?:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        case .none:
            Image(systemName: "arrow.down.circle")
        }
    }

    private func accessibilityLabel(_ record: DownloadRecord?) -> String {
        switch record?.status {
        case .none: downloads.canRequestDownload ? "Download" : "Downloads unavailable"
        case .queued?: "Download waiting"
        case .downloading?: "Downloading, \(Int(((record?.progress ?? 0) * 100).rounded())) percent"
        case .completed?: "Downloaded"
        case .failed?: "Download failed"
        }
    }

    private func sizeLabel(_ quality: DownloadQuality) -> String {
        guard let bytes = quality.estimatedBytes(runTimeTicks: item.runTimeTicks, source: item.mediaSources?.first) else {
            return quality.detail
        }
        return "About \(DownloadFormat.bytes(bytes))"
    }

    private func start(_ quality: DownloadQuality) {
        guard !model.isDemo else {
            model.message = "This preview contains fictional titles. Connect your server to download your library."
            return
        }
        let generation = model.generation
        Task {
            do { try await downloads.download(item, quality: quality, audioIndex: audioIndex, subtitleIndex: subtitleIndex) }
            catch is CancellationError { }
            catch { if generation == model.generation { model.message = error.localizedDescription } }
        }
    }
}

@MainActor private func retryDownload(_ id: String, model: AppModel) {
    let generation = model.generation
    Task {
        do { try await DownloadManager.shared.retry(id) }
        catch is CancellationError { }
        catch { if generation == model.generation { model.message = error.localizedDescription } }
    }
}

enum DownloadFormat {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }
}

/// Plays a downloaded file with the system player, which works without a
/// connection and keeps Picture in Picture, AirPlay and scrubbing.
@MainActor enum OfflinePlayback {
    static func present(_ record: DownloadRecord, startTicks: Int64, watchTogether: Bool, failure: @escaping (String) -> Void) {
        if watchTogether {
            failure("Downloaded copies play on this device only. Leave your group from Profile to watch it.")
            return
        }
        guard let url = DownloadManager.shared.mediaURL(for: record) else {
            failure("This download is missing from the device. Remove it and download it again.")
            return
        }
        guard let presenter = topController() else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let player = AVPlayer(url: url)
        let controller = AVPlayerViewController()
        controller.player = player
        controller.modalPresentationStyle = .fullScreen
        // Closing the player ends offline playback; Picture in Picture would outlive it.
        controller.allowsPictureInPicturePlayback = false
        controller.loadViewIfNeeded()
        let tracker = OfflinePlaybackTracker(id: record.id, player: player,
            duration: record.item.runTimeTicks.map(MediaTime.seconds))
        // The overlay keeps landscape available and saves the position when closed.
        controller.contentOverlayView?.addSubview(tracker)
        controller.contentOverlayView?.addSubview(PhonePlaybackOrientation.RotationLeaseView())
        let start = MediaTime.seconds(ticks: startTicks)
        presenter.present(controller, animated: true) {
            if start > 0 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) { _ in player.play() } }
            else { player.play() }
        }
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// Saves offline progress every ten seconds, at the end, and when the player closes.
private final class OfflinePlaybackTracker: UIView {
    private let id: String
    private weak var player: AVPlayer?
    private let duration: Double?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var attached = false

    init(id: String, player: AVPlayer, duration: Double?) {
        self.id = id; self.player = player; self.duration = duration
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isHidden = true
    }
    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !attached {
            attached = true
            observer = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 600), queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                object: player?.currentItem, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.save(finished: true) }
            }
        } else if window == nil, attached {
            attached = false
            save()
            if let observer { player?.removeTimeObserver(observer) }
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            observer = nil; endObserver = nil
            player?.pause()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            Task { await DownloadManager.shared.syncPendingProgress() }
        }
    }

    private func save(finished: Bool = false) {
        guard let player else { return }
        let itemDuration = player.currentItem?.duration.seconds
        let total = duration ?? (itemDuration?.isFinite == true ? itemDuration : nil)
        let position = finished ? (total ?? player.currentTime().seconds) : player.currentTime().seconds
        guard position.isFinite, position > 0 || finished else { return }
        DownloadManager.shared.recordPlayback(id, positionSeconds: position, durationSeconds: total)
    }
}
#endif
