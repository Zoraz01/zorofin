import SwiftUI
import ZorofinCore

/// Calendar (the plugin's extra, web `zorofin-extras-pages.js`, TV
/// `calendar_screen.dart`): the next four weeks of new episodes and movie
/// releases from Sonarr and Radarr, by day. Titles already on the server open
/// their page.
struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter = CalendarFilter.all
    @State private var events: [CalendarEvent]?
    @State private var error: String?
    @State private var opening = false
    @State private var retry = 0

    var body: some View {
        let now = Date()
        let days = events.map { CalendarAgenda.group($0, filter: filter, now: now) } ?? []
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ExtrasFilterRow(options: CalendarFilter.allCases, selected: $filter, label: \.label)
                    if let error {
                        ExtrasMessage(title: "Couldn’t load the calendar", detail: error) { retry += 1 }
                    } else if events == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    } else if days.isEmpty {
                        ExtrasMessage(title: "Nothing coming up", detail: filter == .all
                            ? "New episodes and movie releases from the next four weeks show here."
                            : "Try Everything to see the rest.")
                    } else {
                        ForEach(days) { day in
                            Text(CalendarAgenda.label(day.day, now: now))
                                .font(Theme.font(Theme.isTV ? 28 : 19, weight: .bold, relativeTo: .headline))
                                .padding(.top, 20).padding(.bottom, 8).accessibilityAddTraits(.isHeader)
                            ForEach(day.events) { event in
                                CalendarEventRow(event: event) { id in Task { await open(id) } }
                            }
                        }
                    }
                }.frame(maxWidth: Theme.isTV ? 1100 : 720, alignment: .leading)
                    .padding(Theme.gutter).frame(maxWidth: .infinity)
            }.background(Theme.background).foregroundStyle(Theme.text).navigationTitle("Calendar")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task(id: "\(model.generation)-\(retry)") { await load() }
    }

    private func load() async {
        events = nil; error = nil
        guard let client = model.client else { events = []; return }
        do {
            let loaded = try await client.calendar(start: Date())
            guard !Task.isCancelled else { return }
            events = loaded
        } catch is CancellationError {
        } catch {
            self.error = error as? ClientError == .unavailable(404)
                ? "The Calendar is turned off on this server."
                : "Sonarr or Radarr didn’t answer. Try again in a moment."
        }
    }

    private func open(_ id: String) async {
        guard !opening, let client = model.client else { return }
        opening = true; defer { opening = false }
        do {
            let item = try await client.item(id)
            dismiss(); model.pendingOpen = item
        } catch {
            model.message = "That title couldn’t be opened. Try again."
        }
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEvent
    let open: (String) -> Void
    private var meta: [String] {
        var parts: [String] = []
        if !event.allDay { parts.append(event.at.formatted(date: .omitted, time: .shortened)) }
        if !event.badge.isEmpty { parts.append(event.badge) }
        if event.hasFile { parts.append("On the server") }
        if let network = event.network, !network.isEmpty { parts.append(network) }
        return parts
    }
    var body: some View {
        let poster: CGFloat = Theme.isTV ? 80 : 54
        // Rows without a library title stay focusable so a remote can scroll.
        Button { if let id = event.itemID { open(id) } } label: {
            HStack(spacing: Theme.isTV ? 18 : 12) {
                ExtrasPoster(url: event.posterURL, episode: event.isEpisode)
                    .frame(width: poster, height: poster * 1.5).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title).font(Theme.font(Theme.isTV ? 24 : 16, weight: .semibold)).lineLimit(1)
                    if let subtitle = event.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(Theme.font(Theme.isTV ? 20 : 14)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    if !meta.isEmpty {
                        Text(meta.joined(separator: " · ")).font(Theme.font(Theme.isTV ? 18 : 13))
                            .foregroundStyle(event.premiere ? Theme.jade : Theme.muted).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if event.itemID != nil {
                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted).accessibilityHidden(true)
                }
            }.padding(Theme.isTV ? 12 : 8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14)).contentShape(Rectangle())
        }.buttonStyle(ExtrasRowStyle()).padding(.bottom, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(([event.title] + [event.subtitle].compactMap { $0 } + meta
                                 + (event.itemID == nil ? [] : ["Open title"])).joined(separator: ", "))
    }
}

/// Sonarr/Radarr's own public poster hosts; no server credentials sent.
private struct ExtrasPoster: View {
    let url: URL?
    let episode: Bool
    var body: some View {
        let fallback = ZStack {
            Color(hex: 0x151c18)
            Image(systemName: episode ? "tv" : "film").foregroundStyle(Theme.border)
        }
        if let url {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { fallback }
            }
        } else { fallback }
    }
}

/// Catch Up matches the web: Skip is neutral and Like trains recommendations.
/// Neither decision changes watched/progress, favorites or the watchlist.
struct CatchUpView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.adaptiveWindow) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var kind = CatchUpKind.all
    @State private var queue: CatchUpQueue?
    @State private var failed = false
    @State private var busy = false
    @State private var reload = 0
    @State private var request = UUID()
    @State private var drag: CGFloat = 0
    @State private var cardWidth: CGFloat = 320
    @State private var actionError: String?
    @State private var lastSkip: (id: String, index: Int)?
    @State private var together = false
    @FocusState private var skipFocused: Bool
    /// Pick Together only when the server advertises it (iPhone and iPad vote; Apple TV hosts from Home).
    private var offersTogether: Bool { !Theme.isTV && model.features.pickTogether }
    private var wide: Bool { Theme.isTV || window.usesWideContent }
    private var skips: CatchUpSkips? {
        guard let session = model.session else { return nil }
        return .standard(server: session.server.url.absoluteString, viewerID: session.viewer.id)
    }
    private var nextItem: MediaItem? {
        guard let queue, queue.index + 1 < queue.items.count else { return nil }
        return queue.items[queue.index + 1]
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    #if os(iOS)
                    if offersTogether {
                        ViewThatFits(in: .horizontal) {
                            HStack { Text("Catch Up").font(Theme.font(32, weight: .bold, relativeTo: .largeTitle)); Spacer(minLength: 12); CatchUpModePicker(together: $together) }
                            VStack(alignment: .leading, spacing: 10) { Text("Catch Up").font(Theme.font(32, weight: .bold, relativeTo: .largeTitle)); CatchUpModePicker(together: $together) }
                        }
                    }
                    if offersTogether && together {
                        PickTogetherPhoneView()
                    } else {
                        soloContent
                    }
                    #else
                    soloContent
                    #endif
                }.frame(maxWidth: Theme.isTV ? 1400 : (wide ? 900 : 460), alignment: .leading)
                    .padding(Theme.gutter).frame(maxWidth: .infinity)
            }.background(Theme.background).foregroundStyle(Theme.text).navigationTitle(offersTogether ? "" : "Catch Up")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task(id: "\(model.generation)-\(kind.rawValue)-\(reload)") { await load() }
        .onDisappear { request = UUID() }
        .onAppear { if model.pickTogether.session != nil && offersTogether { together = true } }
    }
    @ViewBuilder private var soloContent: some View {
                    ExtrasFilterRow(options: CatchUpKind.allCases, selected: $kind, label: \.label).disabled(busy)
                    if failed {
                        ExtrasMessage(title: "Couldn’t load titles", detail: "Try again in a moment.") { reload += 1 }
                    } else if let queue {
                        if let item = queue.current {
                            decisionCard(item)
                            Text(queue.position).font(Theme.font(Theme.isTV ? 18 : 13)).foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity, alignment: Theme.isTV ? .leading : .center)
                        } else {
                            ExtrasMessage(title: "You’re all caught up", detail: "Try another filter or restore skipped titles.", action: "Show skipped again") {
                                skips?.clear(); lastSkip = nil; reload += 1
                            }
                        }
                    } else { ProgressView().frame(maxWidth: .infinity).padding(40) }
                    if Theme.isTV && busy { ProgressView().frame(maxWidth: .infinity) }
                    if let actionError {
                        Text(actionError).font(Theme.font(Theme.isTV ? 20 : 15)).foregroundStyle(Theme.muted)
                            .accessibilityIdentifier("catch-up-error")
                    }
                    if lastSkip != nil {
                        Button("Undo skip") {
                            guard !busy, let previous = lastSkip else { return }
                            skips?.remove(previous.id); queue?.restore(previous.index); lastSkip = nil
                            actionError = nil; drag = 0; skipFocused = Theme.isTV
                        }.buttonStyle(ZoroButtonStyle()).disabled(busy)
                    }
    }
    private func load() async {
        let token = UUID(), generation = model.generation
        request = token; queue = nil; failed = false; busy = false; drag = 0; actionError = nil; lastSkip = nil
        guard let client = model.client, let skips else { queue = CatchUpQueue([], skips: .standard(server: "", viewerID: "")); return }
        do {
            let titles = try await client.catchUpTitles(kind)
            guard !Task.isCancelled, request == token, generation == model.generation else { return }
            queue = CatchUpQueue(titles, skips: skips); skipFocused = Theme.isTV
        } catch is CancellationError { }
        catch { if request == token, generation == model.generation { failed = true } }
    }
    private func act(_ action: CatchUpAction, id: String) async {
        guard action == .skip || action == .like, let item = queue?.current, item.id == id,
              !busy, let client = model.client else { return }
        let token = request, generation = model.generation, savedSkips = skips
        busy = true; actionError = nil
        defer { if request == token, generation == model.generation { busy = false } }
        let motionClock = ContinuousClock()
        var motionEnd = motionClock.now
        #if os(iOS)
        if !reduceMotion {
            motionEnd = motionEnd.advanced(by: .milliseconds(190))
            withAnimation(.easeOut(duration: 0.19)) { drag = (action == .skip ? -1 : 1) * max(cardWidth * 1.3, 400) }
        }
        #endif
        do {
            if action == .like { try await client.likeForRecommendations(id) }
            else { savedSkips?.add(id) }
            try? await motionClock.sleep(until: motionEnd)
            guard request == token, generation == model.generation, queue?.current?.id == id else { return }
            lastSkip = action == .skip ? (id, queue!.index) : nil
            queue?.next(); drag = 0; skipFocused = Theme.isTV
            if action == .skip { Task { await client.logCatchUp(id, action: .skip) } }
        } catch {
            try? await motionClock.sleep(until: motionEnd)
            guard request == token, generation == model.generation else { return }
            actionError = "Couldn’t save your like. Try again."
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { drag = 0 }
        }
    }
    private func metadata(_ item: MediaItem) -> String {
        [item.productionYear.map(String.init), item.officialRating.flatMap { $0.isEmpty ? nil : $0 },
         item.communityRating.flatMap { $0.isFinite && $0 > 0 ? "★ " + String(format: "%.1f", $0) : nil }]
            .compactMap { $0 }.joined(separator: " · ")
    }
    @ViewBuilder private func decisionCard(_ item: MediaItem) -> some View {
        #if os(iOS)
        VStack(spacing: 18) {
            ZStack {
                if let nextItem {
                    mobileArtwork(nextItem).scaleEffect(0.98).offset(y: 8)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                mobileCard(item)
                    .overlay(alignment: drag > 0 ? .topTrailing : .topLeading) {
                        Text(drag > 0 ? "LIKE" : "SKIP").font(Theme.font(24, weight: .bold))
                            .padding(12).foregroundStyle(drag > 0 ? Theme.jade : Theme.text)
                            .background(Theme.background.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(drag > 0 ? Theme.jade : Theme.text, lineWidth: 3))
                            .padding(20).opacity(min(1, abs(drag) / 60)).accessibilityHidden(true)
                    }
                    .offset(x: drag).rotationEffect(.degrees(reduceMotion ? 0 : Double(drag / 28)))
                    .contentShape(Rectangle())
                    .highPriorityGesture(DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            guard !busy, queue?.current?.id == item.id else { return }
                            if abs(value.translation.width) > 5 { drag = value.translation.width }
                        }
                        .onEnded { value in
                            guard !busy, queue?.current?.id == item.id else { return }
                            let x = value.translation.width, y = value.translation.height
                            let projected = value.predictedEndTranslation.width - x
                            let flick = abs(x) >= 32 && abs(projected) > 100 && projected * x > 0
                            if (abs(x) >= min(72, cardWidth * 0.2) || flick), abs(x) > abs(y) * 0.8 {
                                Task { await act(x < 0 ? .skip : .like, id: item.id) }
                            } else { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { drag = 0 } }
                        }, including: typeSize.isAccessibilitySize ? .none : .all)
                    .accessibilityAction(named: Text("Skip")) { Task { await act(.skip, id: item.id) } }
                    .accessibilityAction(named: Text("Like")) { Task { await act(.like, id: item.id) } }
            }.background(GeometryReader { proxy in
                Color.clear.onAppear { cardWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in cardWidth = width }
            })
            HStack(spacing: 32) {
                phoneDecision("Skip", "xmark", .skip, item)
                phoneDecision("Like", "heart.fill", .like, item)
            }.frame(maxWidth: .infinity).disabled(busy).opacity(busy ? 0.5 : 1)
            Text(busy ? "Saving…" : "Swipe left to skip · Swipe right to like")
                .font(Theme.font(15)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        #else
        HStack(alignment: .top, spacing: 32) {
            MediaArtwork(item: item, landscape: true, width: 1280, showPreviewTitle: false)
                .aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 10) {
                Text(item.name).font(Theme.font(36, weight: .bold))
                Text(metadata(item)).font(Theme.font(20)).foregroundStyle(Theme.muted)
                Text(item.overview ?? "").font(Theme.font(22)).lineLimit(4)
                HStack(spacing: 14) {
                    Button { Task { await act(.skip, id: item.id) } } label: { Label("Skip", systemImage: "xmark") }
                        .buttonStyle(ZoroButtonStyle()).focused($skipFocused).accessibilityIdentifier("catch-up-skip")
                    Button { Task { await act(.like, id: item.id) } } label: { Label("Like", systemImage: "heart.fill") }
                        .buttonStyle(ZoroButtonStyle(primary: true)).accessibilityIdentifier("catch-up-like")
                }.disabled(busy)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        #endif
    }
    #if os(iOS)
    private func mobileArtwork(_ item: MediaItem) -> some View {
        MediaArtwork(item: item, landscape: wide, width: wide ? 1280 : 780, showPreviewTitle: false)
            .aspectRatio(wide ? 16 / 9 : 4 / 5, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 20))
    }
    private func cardInfo(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.name).font(Theme.font(wide ? 34 : 28, weight: .bold, relativeTo: .title)).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            Text(metadata(item)).font(Theme.font(15)).foregroundStyle(Theme.muted)
            if let plot = item.overview?.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression), !plot.isEmpty { Text(plot).font(Theme.font(16)).lineLimit(typeSize.isAccessibilitySize ? nil : 2) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func mobileCard(_ item: MediaItem) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 14) { mobileArtwork(item); cardInfo(item).padding(18) }
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
        } else {
            mobileArtwork(item).overlay(alignment: .bottomLeading) {
                cardInfo(item).padding(18)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.95)], startPoint: .top, endPoint: .bottom))
            }.clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }
    private func phoneDecision(_ title: String, _ icon: String, _ action: CatchUpAction, _ item: MediaItem) -> some View {
        Button { Task { await act(action, id: item.id) } } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(action == .like ? Theme.jade : Theme.text)
                    .frame(width: 64, height: 64)
                    .background(action == .like ? Theme.jade.opacity(0.12) : Theme.panel, in: Circle())
                    .overlay(Circle().stroke(action == .like ? Theme.jade.opacity(0.4) : Theme.border, lineWidth: 1))
                    .accessibilityHidden(true)
                Text(title).font(Theme.font(15, weight: .semibold)).foregroundStyle(Theme.text)
            }.frame(minWidth: 80, minHeight: 96).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("catch-up-\(action.rawValue)")
    }
    #endif
}


private struct ExtrasFilterRow<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selected: Option
    let label: KeyPath<Option, String>
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(options) { option in
                    Button(option[keyPath: label]) { selected = option }
                        .buttonStyle(ZoroButtonStyle(primary: option == selected))
                        .accessibilityAddTraits(option == selected ? .isSelected : [])
                }
            }.padding(.vertical, 4)
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }
}

private struct ExtrasMessage: View {
    let title: String
    let detail: String
    var action = "Try again"
    var retry: (() -> Void)?
    init(title: String, detail: String, action: String = "Try again", retry: (() -> Void)? = nil) {
        self.title = title; self.detail = detail; self.action = action; self.retry = retry
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.font(Theme.isTV ? 28 : 21, weight: .bold))
            Text(detail).font(Theme.font(Theme.isTV ? 22 : 16)).foregroundStyle(Theme.muted)
            if let retry { Button(action, action: retry).buttonStyle(ZoroButtonStyle()).padding(.top, 8) }
        }.padding(.vertical, 24)
    }
}

private struct ExtrasRowStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(focused ? Color.white : .clear, lineWidth: 3))
            .opacity(configuration.isPressed ? 0.8 : 1)
            #if os(tvOS)
            .scaleEffect(focused ? 1.01 : 1)
            #endif
    }
}
