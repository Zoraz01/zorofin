import SwiftUI
import ZorofinCore

@MainActor @Observable final class LiveGuideState {
    var channels: [MediaItem] = []
    var programs: [String: [LiveProgram]] = [:]
    var loadedChannels: Set<String> = []
    var query = ""
    var favorites = false
    var window = LiveGuideWindow.current()
    var followsNow = true
    var visibleCount = 40
    var refresh = 0
    var loadingChannels = false
    var loadingPrograms = false
    var channelError: String?
    var programError: String?
    var channelsAt = Date.distantPast
    var channelRevision = -1
    var channelRefresh = -1
    var loadedWindow: LiveGuideWindow?
    var programRefresh = -1
    var channelRequest = UUID()
    var programRequest = UUID()
    var visibleID: String?
}

private struct GuideSelection: Identifiable {
    let channel: MediaItem
    let program: LiveProgram?
    var id: String { channel.id + "|" + (program?.startDate ?? "channel") }
}

struct LiveGuideView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var textSize
    let back: () -> Void
    let play: (MediaItem, PlaybackOptions) -> Void
    private var state: LiveGuideState { model.liveGuide }
    @State private var selection: GuideSelection?
    @State private var pendingChannel: MediaItem?
    @FocusState private var focusedSlot: String?
    private var matches: [MediaItem] { LiveGuideRow.matching(state.channels, query: state.query, favorites: state.favorites) }
    private var visible: [MediaItem] { Array(matches.prefix(state.visibleCount)) }
    private var rows: [LiveGuideRow] {
        visible.map { LiveGuideRow(channel: $0, programs: state.loadedWindow == state.window ? state.programs[$0.id] ?? [] : [], window: state.window) }
    }
    private var programKey: String {
        "\(model.generation)|\(state.window.start.timeIntervalSince1970)|\(state.refresh)|\(scenePhase == .active)|" + visible.map(\.id).joined(separator: ",")
    }

    var body: some View {
        GeometryReader { geometry in
            let grid = (Theme.isTV || geometry.size.width >= 800) && !textSize.isAccessibilitySize
            VStack(spacing: Theme.isTV ? 14 : 8) {
                controls
                LiveTVStreamsStrip { play($0, .init(subtitleIndex: -2)) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                if Theme.isTV { preview.frame(height: 112, alignment: .topLeading) }
                status
                if grid { timeline(width: max(1, geometry.size.width - Theme.gutter * 2)) }
                else { agenda }
            }.padding(.horizontal, Theme.gutter).padding(.top, Theme.isTV ? 10 : 4)
        }
        .background(Theme.background).accessibilityIdentifier("live-guide")
        .task(id: "\(model.generation)-\(state.refresh)-\(model.libraryRevision)-\(scenePhase == .active)") {
            guard scenePhase == .active else { return }; await loadChannels()
        }
        .task(id: programKey) {
            guard scenePhase == .active else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            await loadPrograms()
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            if state.followsNow { state.window = .current() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                if state.followsNow { state.window = .current() }
                state.refresh += 1
            }
        }
        .onChange(of: state.query) { _, _ in state.visibleCount = 40; state.visibleID = nil }
        .onChange(of: state.favorites) { _, _ in state.visibleCount = 40; state.visibleID = nil }
        .sheet(item: $selection, onDismiss: {
            if let channel = pendingChannel { pendingChannel = nil; play(channel, .init(subtitleIndex: -2)) }
        }) { value in
            GuideProgramDetails(selection: value, watch: { pendingChannel = value.channel; selection = nil },
                                join: { channel in pendingChannel = channel; selection = nil })
                .environment(model)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if !Theme.isTV {
                    Button(action: back) { Image(systemName: "chevron.left").frame(width: 44, height: 48) }
                        .buttonStyle(.plain).accessibilityLabel("Back to Home")
                    Text("Live TV").font(Theme.font(28, weight: .bold))
                    Spacer(minLength: 0)
                }
                if Theme.isTV { searchField }
                Menu {
                    Picker("Channels", selection: Binding(get: { state.favorites }, set: { state.favorites = $0 })) {
                        Text("All channels").tag(false); Text("Favorites").tag(true)
                    }
                } label: {
                    Label(state.favorites ? "Favorites" : "All channels", systemImage: state.favorites ? "heart.fill" : "line.3.horizontal.decrease")
                        .font(Theme.font(Theme.isTV ? 23 : 15, weight: .semibold)).padding(.horizontal, 12).frame(minHeight: 48)
                }.buttonStyle(FlatOptionStyle()).accessibilityIdentifier("guide-filter")
                Button { state.refresh += 1 } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 48, height: 48)
                }.buttonStyle(FlatOptionStyle()).accessibilityLabel("Refresh guide")
            }
            if !Theme.isTV { searchField }
            HStack(spacing: Theme.isTV ? 16 : 8) {
                dateMenu
                Spacer(minLength: 0)
                Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 48, height: 48) }
                    .buttonStyle(FlatOptionStyle()).accessibilityLabel("Previous two hours")
                    .disabled(state.window.start <= Calendar.current.startOfDay(for: .now))
                Button("Now") { state.followsNow = true; state.window = .current(); state.refresh += 1 }
                    .buttonStyle(ZoroButtonStyle(primary: state.followsNow)).accessibilityIdentifier("guide-now")
                Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 48, height: 48) }
                    .buttonStyle(FlatOptionStyle()).accessibilityLabel("Next two hours")
                    .disabled(state.window.end >= lastDay)
            }
        }
    }
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField("Find a channel", text: Binding(get: { state.query }, set: { state.query = $0 }))
                .modifier(ServerFieldInput()).font(Theme.font(Theme.isTV ? 24 : 17))
                .accessibilityLabel("Find a channel by name or number").accessibilityIdentifier("guide-search")
            if !state.query.isEmpty {
                Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 48) }
                    .buttonStyle(.plain).accessibilityLabel("Clear channel search")
            }
        }.padding(.horizontal, 14).frame(minHeight: Theme.isTV ? 60 : 48)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }
    private var lastDay: Date { Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: .now))! }
    private var dateMenu: some View {
        Menu {
            ForEach(0..<7, id: \.self) { offset in
                let day = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: .now))!
                Menu(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) {
                    ForEach(Array(stride(from: 0, to: 24, by: 2)), id: \.self) { hour in
                        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
                        Button(date.formatted(date: .omitted, time: .shortened)) { state.followsNow = false; state.window = .init(start: date) }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Calendar.current.isDateInToday(state.window.start) ? "Today" : state.window.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(Theme.font(Theme.isTV ? 24 : 16, weight: .semibold))
                    if !Theme.isTV { Text(timeRange).font(Theme.font(13)).foregroundStyle(Theme.muted) }
                }
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
            }.padding(.horizontal, 8).frame(minHeight: 48)
        }.buttonStyle(FlatOptionStyle()).accessibilityLabel("Choose guide date and time")
            .accessibilityValue(state.window.start.formatted(date: .abbreviated, time: .shortened))
            .accessibilityIdentifier("guide-date")
    }
    private var timeRange: String { state.window.start.formatted(date: .omitted, time: .shortened) + " – " + state.window.end.formatted(date: .omitted, time: .shortened) }
    private func move(_ direction: Int) {
        state.followsNow = false
        let next = state.window.shifted(direction)
        state.window = .init(start: min(lastDay.addingTimeInterval(-LiveGuideWindow.duration), max(Calendar.current.startOfDay(for: .now), next.start)))
    }

    @ViewBuilder private var status: some View {
        if let error = state.channelError ?? state.programError {
            HStack(spacing: 12) {
                Text(error).font(Theme.font(Theme.isTV ? 20 : 14)).foregroundStyle(Theme.muted)
                Button("Retry") { state.refresh += 1 }.buttonStyle(ZoroButtonStyle())
            }.accessibilityIdentifier("guide-error")
        }
        if state.loadingChannels && state.channels.isEmpty { ProgressView("Loading channels…").padding(20) }
        if !state.loadingChannels && state.channelError == nil && matches.isEmpty {
            StatusView(title: state.channels.isEmpty ? "No channels" : "No matching channels",
                       detail: state.favorites ? "Favorite channels from their details to find them here." : "Channels available on your server will appear here.", icon: "tv")
        }
    }

    private var preview: some View {
        let row = rows.first { $0.id == focusedSlot || $0.slots.contains { $0.id == focusedSlot } } ?? rows.first
        let program = row?.slots.first { $0.id == focusedSlot }?.program ?? row?.slots.first { $0.program != nil }?.program
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                Text(program?.name ?? row?.channel.name ?? "TV Guide").font(Theme.font(30, weight: .bold)).lineLimit(1)
                if let program, let schedule = program.schedule {
                    Text(schedule.start.formatted(date: .omitted, time: .shortened) + " – " + schedule.end.formatted(date: .omitted, time: .shortened))
                        .font(Theme.font(21)).foregroundStyle(Theme.muted)
                }
            }
            Text(program == nil ? "" : program?.episodeTitle ?? row?.channel.name ?? "").font(Theme.font(22, weight: .medium)).foregroundStyle(Theme.jade).lineLimit(1)
            Text(program?.overview ?? "").font(Theme.font(21)).foregroundStyle(Theme.muted).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeline(width: CGFloat) -> some View {
        let channelWidth: CGFloat = Theme.isTV ? 236 : 168
        let scheduleWidth = max(1, width - channelWidth - 12)
        return TimelineView(.periodic(from: .now, by: 30)) { clock in
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Text("Channel").font(Theme.font(Theme.isTV ? 21 : 15, weight: .semibold))
                        .frame(width: channelWidth, alignment: .leading)
                    HStack(spacing: 0) {
                        ForEach(0..<4) { index in
                            Text(state.window.start.addingTimeInterval(Double(index) * 1_800), format: .dateTime.hour().minute())
                                .font(Theme.font(Theme.isTV ? 21 : 15, weight: .semibold)).monospacedDigit()
                                .frame(width: scheduleWidth / 4, alignment: .leading)
                        }
                    }
                }.foregroundStyle(Theme.muted).frame(height: Theme.isTV ? 38 : 30)
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(rows) { row in
                            HStack(spacing: 12) {
                                channelButton(row.channel).frame(width: channelWidth)
                                ZStack(alignment: .leading) {
                                    ForEach(row.slots) { slot in
                                        let cellWidth = scheduleWidth * slot.duration / LiveGuideWindow.duration
                                        slotButton(slot, channel: row.channel, now: clock.date, compact: cellWidth < 110)
                                            .frame(width: max(1, cellWidth - 4), height: Theme.isTV ? 108 : 84)
                                            .offset(x: scheduleWidth * state.window.fraction(slot.start))
                                    }
                                    if state.window.contains(clock.date) {
                                        Rectangle().fill(Theme.jade.opacity(0.65)).frame(width: 2)
                                            .offset(x: scheduleWidth * state.window.fraction(clock.date))
                                            .allowsHitTesting(false).accessibilityHidden(true)
                                    }
                                }.frame(width: scheduleWidth, height: Theme.isTV ? 108 : 84, alignment: .leading)
                            }.id(row.id)
                        }
                        moreChannels
                    }.scrollTargetLayout().padding(.vertical, 6).padding(.bottom, 20)
                }.scrollPosition(id: Binding(get: { state.visibleID }, set: { state.visibleID = $0 }))
            }
        }
    }
    private func channelButton(_ channel: MediaItem) -> some View {
        Button { selection = .init(channel: channel, program: nil) } label: {
            HStack(spacing: 12) {
                GuideChannelLogo(channel: channel).frame(width: Theme.isTV ? 64 : 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    if let number = channel.channelNumber {
                        Text(number).font(Theme.font(Theme.isTV ? 20 : 13, weight: .semibold)).foregroundStyle(Theme.jade)
                    }
                    Text(channel.name).font(Theme.font(Theme.isTV ? 22 : 15, weight: .semibold)).lineLimit(2)
                }
                if channel.userData?.isFavorite == true { Image(systemName: "heart.fill").font(.system(size: 12)).foregroundStyle(Theme.jade) }
                Spacer(minLength: 0)
            }.padding(10).frame(maxWidth: .infinity, minHeight: Theme.isTV ? 108 : 72, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(GuideCellStyle()).focused($focusedSlot, equals: channel.id)
            .accessibilityLabel([channel.channelNumber, channel.name].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Channel details and watch live")
    }
    private func slotButton(_ slot: LiveGuideSlot, channel: MediaItem, now: Date, compact: Bool = false) -> some View {
        let airing = slot.program?.isAiring(at: now) == true
        let empty = (state.loadedWindow == state.window && state.loadedChannels.contains(channel.id)) ? "No listings" : state.programError != nil ? "Guide unavailable" : "Loading…"
        return Button { selection = .init(channel: channel, program: slot.program) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(compact ? "…" : slot.program?.name ?? empty)
                    .font(Theme.font(Theme.isTV ? 23 : 17, weight: .semibold)).lineLimit(2)
                if !compact, let program = slot.program, let schedule = program.schedule {
                    Text(schedule.start.formatted(date: .omitted, time: .shortened) + " – " + schedule.end.formatted(date: .omitted, time: .shortened))
                        .font(Theme.font(Theme.isTV ? 18 : 13)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }.padding(.horizontal, compact ? 2 : 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(airing ? Theme.jade.opacity(0.13) : Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomLeading) {
                    if airing, let schedule = slot.program?.schedule {
                        GeometryReader { geometry in
                            Capsule().fill(Theme.jade).frame(width: geometry.size.width * min(1, max(0, now.timeIntervalSince(schedule.start) / schedule.end.timeIntervalSince(schedule.start))), height: 3)
                        }.frame(height: 3).padding(.horizontal, 10).padding(.bottom, 6)
                    }
                }
        }.buttonStyle(GuideCellStyle()).focused($focusedSlot, equals: slot.id)
            .accessibilityLabel(channel.name + ", " + (slot.program?.name ?? empty))
            .accessibilityValue(slot.program?.schedule.map { $0.start.formatted(date: .abbreviated, time: .shortened) + " to " + $0.end.formatted(date: .omitted, time: .shortened) } ?? "")
            .accessibilityHint("Program details")
    }
    private var agenda: some View {
        TimelineView(.periodic(from: .now, by: 30)) { clock in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(rows) { row in
                        VStack(spacing: 6) {
                            channelButton(row.channel)
                            ForEach(row.slots) { slot in
                                slotButton(slot, channel: row.channel, now: clock.date)
                                    .frame(minHeight: 76)
                            }
                        }.id(row.id)
                    }
                    moreChannels
                }.scrollTargetLayout().padding(.vertical, 6).padding(.bottom, 20)
            }.scrollPosition(id: Binding(get: { state.visibleID }, set: { state.visibleID = $0 }))
        }
    }
    @ViewBuilder private var moreChannels: some View {
        if matches.count > state.visibleCount {
            Button("More channels") { state.visibleCount += 40 }.buttonStyle(ZoroButtonStyle())
                .frame(maxWidth: .infinity).padding(12)
                .onScrollVisibilityChange(threshold: 0.5) { if $0 { state.visibleCount += 40 } }
        }
    }

    private func loadChannels() async {
        let state = state, generation = model.generation, revision = model.libraryRevision, refresh = state.refresh
        if state.channelRevision == revision && state.channelRefresh == refresh && Date.now.timeIntervalSince(state.channelsAt) < 120 { return }
        let request = UUID(); state.channelRequest = request
        state.loadingChannels = true; state.channelError = nil
        defer { if state.channelRequest == request { state.loadingChannels = false } }
        if model.isDemo { state.channels = GuidePreview.channels; state.channelsAt = .now; return }
        guard let client = model.client else { return }
        var channels: [MediaItem] = [], seen: Set<String> = [], cursor = LibraryPageCursor()
        do {
            for _ in 0..<20 {
                let page = try await client.guideChannels(start: cursor.offset)
                guard !Task.isCancelled, generation == model.generation, state.channelRequest == request else { return }
                channels += page.items.filter { seen.insert($0.id).inserted }
                cursor.accept(page, limit: 200)
                if !cursor.hasMore { break }
            }
            state.channels = channels; state.channelsAt = .now; state.channelRevision = revision; state.channelRefresh = refresh
            if cursor.hasMore { state.channelError = "Showing the first \(channels.count) channels." }
        } catch {
            guard !Task.isCancelled, generation == model.generation, state.channelRequest == request else { return }
            if error as? ClientError == .forbidden || error as? ClientError == .unauthorized { state.channels = []; state.programs = [:]; state.loadedChannels = [] }
            state.channelError = error.localizedDescription
        }
    }
    private func loadPrograms() async {
        let state = state, generation = model.generation, window = state.window, refresh = state.refresh
        let request = UUID(); state.programRequest = request
        if state.loadedWindow != window { state.programs = [:]; state.loadedChannels = []; state.loadedWindow = window }
        if state.programRefresh != refresh { state.loadedChannels = []; state.programRefresh = refresh }
        let missing = visible.map(\.id).filter { !state.loadedChannels.contains($0) }
        guard !missing.isEmpty else { return }
        state.loadingPrograms = true; state.programError = nil
        defer { if state.programRequest == request { state.loadingPrograms = false } }
        do {
            for start in stride(from: 0, to: missing.count, by: 40) {
                let ids = Array(missing[start..<min(start + 40, missing.count)])
                let programs: [LiveProgram]
                if model.isDemo { programs = GuidePreview.programs(channelIDs: ids, window: window) }
                else if let client = model.client { programs = try await client.guidePrograms(channelIDs: ids, window: window) }
                else { return }
                guard !Task.isCancelled, generation == model.generation, state.programRequest == request else { return }
                let grouped = Dictionary(grouping: programs, by: { $0.channelId ?? "" })
                for id in ids { state.programs[id] = grouped[id] ?? []; state.loadedChannels.insert(id) }
            }
        } catch {
            guard !Task.isCancelled, generation == model.generation, state.programRequest == request else { return }
            if error as? ClientError == .forbidden || error as? ClientError == .unauthorized { state.programs = [:]; state.loadedChannels = [] }
            state.programError = "The schedule couldn't refresh. Channels are still available."
        }
    }
}

private struct GuideChannelLogo: View {
    @Environment(AppModel.self) private var model
    let channel: MediaItem
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "tv").font(.system(size: Theme.isTV ? 28 : 22)).foregroundStyle(Theme.muted) }
        }.accessibilityHidden(true)
            .task(id: "\(model.generation)-\(channel.id)") {
                image = nil
                guard let client = model.client, let tag = channel.imageTags?["Primary"] else { return }
                let cache = model.imageCache
                image = try? await cache.image(key: "guide-\(channel.id)-\(tag)", client: client,
                    itemID: channel.id, kind: "Primary", tag: tag, width: 160)
                if Task.isCancelled { image = nil }
            }.onDisappear { image = nil }
    }
}

private struct GuideCellStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Theme.jade : Theme.border.opacity(0.5), lineWidth: focused ? 3 : 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct GuideProgramDetails: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let selection: GuideSelection
    let watch: () -> Void
    var join: (MediaItem) -> Void = { _ in }
    @FocusState private var watchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(selection.channel.name).font(Theme.font(Theme.isTV ? 24 : 17)).foregroundStyle(Theme.jade)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 48, height: 48) }
                    .buttonStyle(FlatOptionStyle()).accessibilityLabel("Close program details")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(selection.program?.name ?? selection.channel.name).font(Theme.font(Theme.isTV ? 38 : 27, weight: .bold))
                    if let program = selection.program {
                        if let schedule = program.schedule {
                            Text(schedule.start.formatted(date: .abbreviated, time: .shortened) + " – " + schedule.end.formatted(date: .omitted, time: .shortened))
                                .font(Theme.font(Theme.isTV ? 24 : 16)).foregroundStyle(Theme.muted)
                        }
                        if let episode = program.episodeTitle, !episode.isEmpty { Text(episode).font(Theme.font(Theme.isTV ? 27 : 20, weight: .semibold)) }
                        if let overview = program.overview, !overview.isEmpty { Text(overview).font(Theme.font(Theme.isTV ? 24 : 17)) }
                    } else { Text("No program information available.").foregroundStyle(Theme.muted) }
                    LiveTVStreamsLine(channelID: selection.channel.id, play: join)
                    #if os(tvOS)
                    if !model.features.liveTvStreams { TVLiveTVAvailabilityNotice(channelID: selection.channel.id) }
                    #endif
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let program = selection.program, !program.isAiring(at: .now) {
                Text("Watch live plays this channel's current broadcast.")
                    .font(Theme.font(Theme.isTV ? 21 : 15)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 16) {
                Button(action: watch) { Label("Watch live", systemImage: "play.fill") }
                    .buttonStyle(ZoroButtonStyle(primary: true)).focused($watchFocused)
                    .accessibilityHint("Plays what is on this channel now")
                FavoriteButton(item: selection.channel)
            }
        }.padding(Theme.isTV ? 48 : 24).frame(maxWidth: Theme.isTV ? 1000 : 760, maxHeight: Theme.isTV ? 720 : .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
            .foregroundStyle(Theme.text)
            #if os(tvOS)
            .onExitCommand { dismiss() }
            .task { await Task.yield(); watchFocused = true }
            #endif
    }
}

/// Synthetic previews only; never mixed into a signed-in server's guide.
private enum GuidePreview {
    static var channels: [MediaItem] {
        ["World News", "Cinema", "Nature", "Sports", "Family", "Culture", "Music", "Travel"].enumerated().map { index, name in
            var channel = MediaItem(id: "guide-preview-\(index)", name: name, type: "TvChannel", userData: .init(isFavorite: index < 2))
            channel.channelNumber = String(index + 1); return channel
        }
    }
    static func programs(channelIDs: [String], window: LiveGuideWindow) -> [LiveProgram] {
        channelIDs.enumerated().flatMap { index, id in
            (0..<4).map { slot in
                let titles = ["Evening edition", "Behind the scenes", "The natural world", "Match of the day", "Family stories", "Arts tonight"]
                var value = LiveProgram(name: titles[(index + slot) % titles.count], startDate: window.start.addingTimeInterval(Double(slot) * 1800).ISO8601Format(), endDate: window.start.addingTimeInterval(Double(slot + 1) * 1800).ISO8601Format())
                value.id = "\(id)-\(slot)"; value.channelId = id
                value.overview = "Explore today's stories and discover what's coming next. This is a sample program for the app preview."
                return value
            }
        }
    }
}
