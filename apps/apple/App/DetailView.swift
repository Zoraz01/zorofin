import SwiftUI
import ZorofinCore

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var textSize
    let item: MediaItem
    let wide: Bool
    let play: (MediaItem, PlaybackOptions) -> Void
    @State private var loaded: MediaItem?
    @State private var related: [MediaItem] = []
    @State private var nextEpisode: MediaItem?
    @State private var audioIndex = -999
    @State private var subtitleIndex = -2
    @State private var failure: String?
    @State private var playedOverride: Bool?
    @State private var changingPlayed = false
    @State private var loading = false
    @State private var refresh = 0
    @State private var showingMediaInfo = false
    @State private var availableWidth: CGFloat = 0
    private var usesColumns: Bool { availableWidth >= 720 && !textSize.isAccessibilitySize }
    private var media: MediaItem { loaded ?? item }
    private var qualityItem: MediaItem { playable ?? media }
    private var quality: MediaQuality { qualityItem.quality(audioIndex: audioIndex == -999 ? nil : audioIndex) }
    private var streams: [MediaStream] { qualityItem.mediaSources?.first?.mediaStreams ?? qualityItem.mediaStreams ?? [] }
    private var isPlayed: Bool { playedOverride ?? media.userData?.played ?? false }
    private var audioStreams: [MediaStream] { streams.filter { $0.type == "Audio" } }
    private var subtitleStreams: [MediaStream] { streams.filter { $0.type == "Subtitle" } }
    private var playable: MediaItem? { (media.isSeries || media.type == "Season") ? nextEpisode : media }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: wide ? 28 : 18) {
                if Theme.isTV || usesColumns {
                    HStack(alignment: .top, spacing: Theme.isTV ? 48 : 28) {
                        MediaArtwork(item: media, landscape: media.isEpisode || media.isLive, width: 900)
                            .aspectRatio(media.isEpisode || media.isLive ? 16 / 9 : 2 / 3, contentMode: .fit)
                            .frame(width: Theme.isTV ? (media.isEpisode || media.isLive ? 460 : 300)
                                   : (media.isEpisode || media.isLive ? min(360, availableWidth * 0.38) : 220))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 24) {
                            heading
                            qualityBadges
                            playbackActions { proxy.scrollTo("season-episode-browser", anchor: .top) }
                            if media.isLive { LiveTVStreamsLine(channelID: media.id) { play($0, .init(subtitleIndex: -2)) } }
                            #if os(tvOS)
                            if media.isLive && !model.features.liveTvStreams { TVLiveTVAvailabilityNotice(channelID: media.id) }
                            #endif
                            synopsis
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityIdentifier(Theme.isTV ? "tv-detail-overview" : "wide-detail-overview")
                } else {
                    if media.isEpisode || media.isLive {
                        MediaArtwork(item: media, landscape: true, width: 900).aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        heading
                    } else {
                        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20)) : AnyLayout(HStackLayout(alignment: .top, spacing: 18))
                        layout {
                            MediaArtwork(item: media, landscape: media.isEpisode || media.isLive, width: 900)
                                .aspectRatio(media.isEpisode || media.isLive ? 16 / 9 : 2 / 3, contentMode: .fit)
                                .frame(width: min(150, max(100, availableWidth * 0.36)))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            heading.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    qualityBadges
                    playbackActions { proxy.scrollTo("season-episode-browser", anchor: .top) }
                    if media.isLive { LiveTVStreamsLine(channelID: media.id) { play($0, .init(subtitleIndex: -2)) } }
                    synopsis
                }
                if let genres = media.genres, !genres.isEmpty {
                    HStack(alignment: .top, spacing: 20) {
                        Text("Genres").foregroundStyle(Theme.muted)
                        Text(genres.joined(separator: ", ")).foregroundStyle(Theme.jade)
                    }.font(Theme.font(Theme.isTV ? 22 : 16)).padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
                }
                if media.episodeSeriesID != nil {
                    SeasonEpisodeBrowser(context: media, preferredEpisode: playable,
                        scrollToEpisode: { id in proxy.scrollTo(id, anchor: .center) }).id(model.generation).id("season-episode-browser")
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let failure { StatusView(title: "Some details couldn't load", detail: failure, retry: { refresh += 1 }) }
            }.padding(.horizontal, Theme.gutter).padding(.top, Theme.isTV ? 20 : 12)
            if let people = media.people, !people.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(title: "Cast & Crew").padding(.horizontal, Theme.gutter)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(Array(people.prefix(24))) { person in
                                VStack(alignment: .leading, spacing: 8) {
                                    MediaArtwork(item: personItem(person), width: 360).aspectRatio(2 / 3, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                    Text(person.name).font(Theme.font(Theme.isTV ? 20 : 14, weight: .semibold)).lineLimit(2)
                                    Text(person.role ?? person.type ?? "").font(Theme.font(Theme.isTV ? 17 : 12)).foregroundStyle(Theme.muted).lineLimit(2)
                                }.frame(width: Theme.isTV ? 180 : 138)
                            }
                        }.padding(.horizontal, Theme.gutter)
                    }.scrollIndicators(.hidden)
                }.padding(.top, 32)
            }
            if !related.isEmpty { MediaShelf(title: "More Like This", items: related, landscape: true).padding(.top, 32) }
            Color.clear.frame(height: 24)
        }.foregroundStyle(Theme.text).background(Theme.background).task(id: refresh) { await load() }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { availableWidth = $0 }
            .sheet(isPresented: $showingMediaInfo) { MediaFileInfoView(item: qualityItem, audioIndex: audioIndex == -999 ? nil : audioIndex) }
        }
    }
    @ViewBuilder private var qualityBadges: some View {
        if !quality.badges.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if media.isSeries || media.type == "Season" {
                    Text("Next episode · " + qualityItem.episodeLabel)
                        .font(Theme.font(Theme.isTV ? 18 : 12)).foregroundStyle(Theme.muted)
                }
                DetailWrapLayout(spacing: 7) {
                    ForEach(Array(quality.badges.enumerated()), id: \.offset) { _, badge in
                        Text(badge).font(Theme.font(Theme.isTV ? 18 : 12, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
                    }
                }
            }.accessibilityElement(children: .combine).accessibilityIdentifier("detail-quality")
        }
    }
    @ViewBuilder private var synopsis: some View {
        if let tagline = media.taglines?.first { Text(tagline).font(Theme.font(Theme.isTV ? 26 : 17, weight: .semibold)) }
        if let overview = media.overview {
            Text(overview.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .font(Theme.font(Theme.isTV ? 24 : 16)).foregroundStyle(Theme.muted).lineSpacing(5)
                .frame(maxWidth: 1100, alignment: .leading)
        }
    }
    private func playbackActions(browseEpisodes: @escaping () -> Void) -> some View {
        let layout = Theme.isTV
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 24))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        return layout {
            Button {
                if let playable { play(playable, .init(startTicks: playable.resumeTicks, bitrate: model.bitrate,
                    audioIndex: audioIndex == -999 ? nil : audioIndex, subtitleIndex: subtitleIndex)) }
            } label: {
                Label(playable?.resumeTicks ?? 0 > 0 ? "Resume" : media.isSeries ? "Play next episode" : "Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(ZoroButtonStyle(primary: true)).disabled(playable == nil)
                .frame(width: Theme.isTV ? 260 : nil)
                .accessibilityIdentifier("detail-play")
            DetailWrapLayout(spacing: Theme.isTV ? 16 : 10, alignment: Theme.isTV ? .leading : .center) {
                FavoriteButton(item: media, compact: true)
                Button { togglePlayed() } label: {
                    Image(systemName: isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(isPlayed ? Theme.jade : Theme.text)
                }.buttonStyle(DetailIconStyle()).disabled(changingPlayed)
                    .accessibilityLabel(isPlayed ? "Mark unwatched" : "Mark watched")
                    .accessibilityValue(isPlayed ? "Watched" : "Not watched")
                    .help(isPlayed ? "Mark unwatched" : "Mark watched")
                    .accessibilityIdentifier("detail-watched")
                // iPhone/iPad episodes keep the row short: no Start over, View series or Seasons & episodes.
                if let playable, playable.resumeTicks > 0, Theme.isTV || !playable.isEpisode {
                    Button { play(playable, .init(bitrate: model.bitrate, audioIndex: audioIndex == -999 ? nil : audioIndex, subtitleIndex: subtitleIndex)) } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }.buttonStyle(DetailIconStyle()).accessibilityLabel("Start over").help("Start over")
                        .accessibilityIdentifier("detail-start-over")
                }
                if !streams.isEmpty { trackControls }
                #if os(iOS)
                if media.isDownloadable && !media.isLive {
                    DownloadButton(item: media, audioIndex: audioIndex == -999 ? nil : audioIndex, subtitleIndex: subtitleIndex)
                }
                #endif
                if Theme.isTV, media.isEpisode, let seriesID = media.seriesId {
                    // Continue Watching lands here, so the show is one step away.
                    NavigationLink(value: MediaItem(id: seriesID, name: media.seriesName ?? "Series", type: "Series")) {
                        Image(systemName: "tv")
                    }.buttonStyle(DetailIconStyle()).accessibilityLabel("View series").help("View series")
                        .accessibilityIdentifier("detail-view-series")
                }
                if Theme.isTV, media.episodeSeriesID != nil {
                    Button(action: browseEpisodes) { Image(systemName: "rectangle.stack") }
                        .buttonStyle(DetailIconStyle()).accessibilityLabel("Seasons and episodes").help("Seasons and episodes")
                        .accessibilityIdentifier("detail-browse-episodes")
                }
                if qualityItem.fileQualities.contains(where: { !$0.facts.isEmpty }) {
                    Button { showingMediaInfo = true } label: { Image(systemName: "info.circle") }
                        .buttonStyle(DetailIconStyle()).accessibilityLabel("File details").help("File details")
                        .accessibilityIdentifier("detail-file-info")
                }
            }.foregroundStyle(Theme.text)
                .frame(maxWidth: Theme.isTV ? nil : .infinity, alignment: .center)
        }.frame(maxWidth: Theme.isTV ? 1120 : 760, alignment: .leading)
    }
    private var trackControls: some View {
        Group {
            selectionRow("Audio", icon: "waveform", value: audioStreams.isEmpty ? "No audio tracks" : trackTitle(audioStreams, index: audioIndex)) {
                Picker("Audio", selection: $audioIndex) {
                    Text("Automatic").tag(-999)
                    ForEach(audioStreams, id: \.index) { stream in Text(streamTitle(stream)).tag(stream.index) }
                }
            }.disabled(audioStreams.isEmpty)
            selectionRow("Subtitles", icon: "captions.bubble", value: subtitleStreams.isEmpty ? "No subtitles available" : subtitleIndex == -1 ? "Off" : trackTitle(subtitleStreams, index: subtitleIndex)) {
                Picker("Subtitles", selection: $subtitleIndex) {
                    Text("Automatic").tag(-2)
                    Text("Off").tag(-1)
                    ForEach(subtitleStreams, id: \.index) { stream in Text(streamTitle(stream)).tag(stream.index) }
                }
            }.disabled(subtitleStreams.isEmpty)
        }
    }
    private func selectionRow<Content: View>(_ title: String, icon: String, value: String, @ViewBuilder choices: () -> Content) -> some View {
        Menu { choices() } label: {
            Image(systemName: icon).foregroundStyle(Theme.jade)
        }.buttonStyle(DetailIconStyle()).accessibilityLabel(title).accessibilityValue(value).help(title + ": " + value)
            .accessibilityIdentifier("detail-" + title.lowercased())
    }
    private func streamTitle(_ stream: MediaStream) -> String {
        stream.displayTitle ?? stream.language ?? "Track \(stream.index)"
    }
    private func trackTitle(_ values: [MediaStream], index: Int) -> String {
        values.first(where: { $0.index == index }).map(streamTitle) ?? "Automatic"
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: wide ? 18 : 12) {
            Label(media.type?.uppercased() ?? "TITLE", systemImage: "circle.fill")
                .font(Theme.font(Theme.isTV ? 16 : 11, weight: .semibold)).foregroundStyle(Theme.jade)
            Text(media.displayTitle).font(Theme.font(wide ? 46 : 27, weight: .bold, relativeTo: .title))
                .fixedSize(horizontal: false, vertical: true)
            if media.isEpisode { Text(media.episodeLabel).font(Theme.font(Theme.isTV ? 26 : 17)).foregroundStyle(Theme.muted) }
            MetadataLine(item: media)
            if let rating = media.communityRating {
                Label(String(format: "%.1f", rating), systemImage: "star.fill").font(Theme.font(Theme.isTV ? 22 : 16)).foregroundStyle(.yellow)
            }
        }
    }
    private func personItem(_ person: Person) -> MediaItem {
        var result = MediaItem(id: person.id, name: person.name, type: "Person")
        if let tag = person.primaryImageTag { result.imageTags = ["Primary": tag] }
        return result
    }
    private func load() async {
        loading = true; failure = nil
        defer { loading = false }
        if model.isDemo {
            loaded = item; related = PreviewLibrary.movies.filter { $0.id != item.id }
            if item.isSeries || item.type == "Season" { nextEpisode = PreviewLibrary.episodes.first }
            return
        }
        guard let client = model.client else { return }
        do {
            async let relatedPage = client.similar(itemID: item.id)
            loaded = try await client.item(item.id)
            try Task.checkCancellation()
            if media.isSeries {
                // Include the in-progress episode, as Continue Watching does; otherwise Next Up skips it.
                nextEpisode = try? await client.nextUp(seriesID: media.id, includeResumable: true).items.first
                if nextEpisode == nil, let seasons = try? await client.seasons(seriesID: media.id).items,
                   let season = seasons.first(where: { ($0.indexNumber ?? 0) > 0 }) ?? seasons.first {
                    nextEpisode = try? await client.episodes(seriesID: media.id, seasonID: season.id).items.first
                }
            } else if media.type == "Season", let seriesID = media.seriesId {
                nextEpisode = try? await client.episodes(seriesID: seriesID, seasonID: media.id).items.first
            }
            // One detail read for the actual next episode; no per-poster requests.
            if let next = nextEpisode { nextEpisode = (try? await client.item(next.id)) ?? next }
            related = (try? await relatedPage.items) ?? []
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }
    private func togglePlayed() {
        guard !changingPlayed else { return }
        let next = !isPlayed
        if model.isDemo { playedOverride = next; return }
        guard let client = model.client else { return }
        changingPlayed = true
        let generation = model.generation
        Task {
            defer { changingPlayed = false }
            do {
                let result = try await client.played(itemID: media.id, value: next)
                guard generation == model.generation else { return }
                playedOverride = result.played ?? next; model.libraryRevision += 1; model.homeRevision += 1
            }
            catch { if generation == model.generation { model.message = error.localizedDescription } }
        }
    }
}


/// Native menus keep season choices above content without expanding the page.
private struct SeasonSelector: View {
    let seasons: [MediaItem]
    let selectedID: String
    let choose: (String) -> Void
    private var selectedTitle: String { seasons.first { $0.id == selectedID }?.seasonTitle ?? "Choose season" }
    var body: some View {
        #if os(iOS)
        Menu {
            Picker("Season", selection: Binding(get: { selectedID }, set: { id in choose(id) })) {
                ForEach(seasons) { season in
                    Text(season.seasonTitle).tag(season.id)
                }
            }
        } label: {
            HStack(spacing: 14) {
                Text(selectedTitle).font(Theme.font(16, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
            }.fixedSize(horizontal: true, vertical: false).padding(.horizontal, 18).frame(minHeight: Theme.target)
                .background(.ultraThinMaterial, in: Capsule())
                .contentShape(Capsule())
        }.menuOrder(.fixed).buttonStyle(.plain)
            .accessibilityLabel("Choose season").accessibilityValue(selectedTitle)
            .accessibilityHint("Show season choices over the episode list")
            .accessibilityIdentifier("episode-browser-season")
        #else
        Menu {
            Picker("Season", selection: Binding(get: { selectedID }, set: { choose($0) })) {
                ForEach(seasons) { season in
                    Text(season.seasonTitle).tag(season.id)
                }
            }
        } label: {
            HStack(spacing: 14) {
                Text(selectedTitle).font(Theme.font(24, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 18, weight: .semibold))
            }.padding(.horizontal, 20).frame(minHeight: 56)
                .background(Theme.panel, in: Capsule())
                .contentShape(Capsule())
        }.menuOrder(.fixed).buttonStyle(FlatOptionStyle())
            .playerOptionsDefaultFocus()
            .accessibilityLabel("Choose season").accessibilityValue(selectedTitle)
            .accessibilityHint("Show season choices over the episode list")
            .accessibilityIdentifier("episode-browser-season")
        #endif
    }
}

/// Retains the browser's context and useful controls while metadata is unavailable.
private struct EpisodeBrowserStatusView<Actions: View>: View {
    let title: String
    let detail: String
    var loading = false
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if loading { ProgressView().accessibilityHidden(true) }
                Text(title).font(Theme.font(Theme.isTV ? 28 : 22, weight: .semibold, relativeTo: .title2))
            }.accessibilityElement(children: .combine)
            Text(detail).font(Theme.font(Theme.isTV ? 22 : 15)).foregroundStyle(Theme.muted)
            if loading {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 9).fill(Theme.panel)
                            .frame(width: Theme.isTV ? 180 : 108, height: Theme.isTV ? 101 : 61)
                        VStack(alignment: .leading, spacing: 10) {
                            RoundedRectangle(cornerRadius: 4).fill(Theme.panel).frame(maxWidth: 230).frame(height: 10)
                            RoundedRectangle(cornerRadius: 4).fill(Theme.panel).frame(maxWidth: 140).frame(height: 8)
                        }
                    }.accessibilityHidden(true)
                }
            }
            actions()
        }.padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared navigator for series/season/episode pages and the in-player picker.
struct SeasonEpisodeBrowser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var textSize
    let context: MediaItem
    var preferredEpisode: MediaItem? = nil
    var scrollToEpisode: ((String) -> Void)? = nil
    var playSelection: ((MediaItem) -> Void)?
    @State private var browser: EpisodeBrowserState?
    @State private var selectionTask: Task<Void, Never>?
    @State private var centeredCurrent = false
    @State private var currentJump = 0
    @FocusState private var focusedEpisodeID: String?
    @State private var loadedRevision: Int?
    private var cardWidth: CGFloat { Theme.isTV ? (playSelection == nil ? 380 : 300) : textSize.isAccessibilitySize ? 300 : 250 }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let headingLayout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
            if playSelection == nil {
                headingLayout {
                Text(Theme.isTV ? "Seasons & episodes" : "Episodes").font(Theme.font(Theme.isTV ? 28 : 21, weight: .bold, relativeTo: .title2))
                Spacer(minLength: 8)
                if context.isEpisode, let seriesID = context.seriesId, playSelection == nil {
                    NavigationLink(value: MediaItem(id: seriesID, name: context.seriesName ?? "Series", type: "Series")) {
                        Text("View series").font(Theme.font(Theme.isTV ? 20 : 14, weight: .semibold))
                            .frame(minHeight: Theme.target)
                    }.buttonStyle(.plain).foregroundStyle(Theme.jade)
                }
            }
            }
            if let browser {
                if !browser.seasons.isEmpty {
                    HStack(spacing: 12) {
                        SeasonSelector(seasons: browser.seasons, selectedID: browser.selectedSeasonID) { id in
                            selectionTask?.cancel(); centeredCurrent = true
                            browser.cancelTargeting()
                            selectionTask = Task { await browser.selectSeason(id) }
                        }
                        #if os(iOS)
                        Spacer(minLength: 0)
                        if let total = browser.total {
                            // Drops out rather than truncating when the season and current-episode controls need the room.
                            ViewThatFits(in: .horizontal) {
                                Text(total == 1 ? "1 episode" : "\(total) episodes").lineLimit(1)
                                Color.clear.frame(width: 0, height: 0)
                            }.font(Theme.font(13)).foregroundStyle(Theme.muted)
                        }
                        #endif
                    }
                    #if os(tvOS)
                    // Keep Up from every episode card connected to the season
                    // picker, even when the carousel is scrolled far to the right.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
                    #endif
                }
                if browser.loadingSeasons || browser.loadingEpisodes && browser.episodes.isEmpty {
                    EpisodeBrowserStatusView(title: browser.loadingSeasons ? "Loading seasons" : "Loading \(browser.selectedSeason?.seasonTitle ?? "episodes")",
                        detail: "Finding episodes. Your place is saved.", loading: true) { EmptyView() }
                }
                if !browser.episodes.isEmpty {
                    #if os(iOS)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(browser.episodes) { episode in
                            Group {
                                if let playSelection {
                                    Button { playSelection(episode) } label: {
                                        EpisodeBrowseRow(item: episode, current: episode.id == browser.currentEpisodeID, inPlayer: true)
                                    }.accessibilityLabel(episode.id == browser.currentEpisodeID ? "Return to current episode" : "\(episode.resumeTicks > 0 ? "Resume" : "Play") \(episode.episodeNumberLabel), \(episode.name)")
                                } else {
                                    // The whole row opens the episode, synopsis included; Play starts it.
                                    // Both are plain buttons, so a drag that begins on them still scrolls.
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(alignment: .center, spacing: 12) {
                                            NavigationLink(value: episode) {
                                                EpisodeBrowseRow(item: episode, current: episode.id == browser.currentEpisodeID, showsOverview: false)
                                            }.accessibilityLabel("\(episode.episodeNumberLabel), \(episode.name)\(episode.id == browser.currentEpisodeID ? ", current episode" : "")")
                                            Button { model.pendingPlay = episode } label: {
                                                Image(systemName: "play.fill").font(.system(size: 15, weight: .semibold))
                                                    .foregroundStyle(Theme.text).frame(width: 40, height: 40)
                                                    .background(Theme.panel, in: Circle())
                                                    .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                                            }.frame(width: 56, height: 56).contentShape(Rectangle())
                                                .accessibilityLabel("\(episode.resumeTicks > 0 ? "Resume" : "Play") \(episode.episodeNumberLabel)")
                                                .accessibilityIdentifier("episode-play-" + episode.id)
                                        }
                                        if let overview = episode.overview, !overview.isEmpty {
                                            NavigationLink(value: episode) {
                                                Text(overview.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                                                    .font(Theme.font(13)).foregroundStyle(Theme.muted).lineLimit(textSize.isAccessibilitySize ? nil : 2)
                                                    .multilineTextAlignment(.leading)
                                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                            }.accessibilityHidden(true)
                                        }
                                    }.padding(.vertical, 14)
                                }
                            }.buttonStyle(.plain).id(episode.id)
                                .accessibilityIdentifier("browse-episode-" + episode.id)
                            Divider().overlay(Theme.border.opacity(0.4))
                        }
                        if browser.hasMore && !browser.loadingEpisodes && browser.error == nil {
                            Button("More episodes") {
                                selectionTask = Task { await browser.loadMore() }
                            }.buttonStyle(FlatOptionStyle()).frame(maxWidth: .infinity)
                                .accessibilityIdentifier("episode-browser-more")
                                .onAppear {
                                    selectionTask = Task { await browser.loadMore() }
                                }
                        }
                    }.accessibilityIdentifier("episode-browser-list")
                        // Only the in-player list centers itself; a details page opens at the top
                        // with Play visible, and Current episode scrolls on request.
                        .onChange(of: browser.episodes.count) { _, _ in if playSelection != nil { centerMobileCurrent(browser) } }
                        .onAppear { if playSelection != nil { centerMobileCurrent(browser) } }
                    #else
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(browser.episodes) { episode in
                                    Group {
                                        if let playSelection {
                                            Button { playSelection(episode) } label: {
                                                EpisodeBrowseCard(item: episode, current: episode.id == browser.currentEpisodeID, inPlayer: true)
                                            }.accessibilityLabel(episode.id == browser.currentEpisodeID ? "Return to current episode" : "\(episode.resumeTicks > 0 ? "Resume" : "Play") \(episode.episodeNumberLabel), \(episode.name)")
                                        } else {
                                            NavigationLink(value: episode) { EpisodeBrowseCard(item: episode, current: episode.id == browser.currentEpisodeID) }
                                                .accessibilityLabel("\(episode.episodeNumberLabel), \(episode.name)\(episode.id == browser.currentEpisodeID ? ", current episode" : "")")
                                        }
                                    }.buttonStyle(ArtworkButtonStyle()).focused($focusedEpisodeID, equals: episode.id).frame(width: cardWidth).id(episode.id)
                                        .accessibilityIdentifier("browse-episode-" + episode.id)
                                }
                                if browser.hasMore {
                                    Button { selectionTask = Task { await browser.loadMore() } } label: {
                                        VStack(spacing: 12) { Image(systemName: "chevron.right"); Text("More episodes") }
                                            .frame(width: 140, height: 160)
                                    }.buttonStyle(DetailControlStyle()).disabled(browser.loadingEpisodes)
                                }
                            }.padding(4)
                        }.scrollIndicators(.hidden).scrollClipDisabled()
                            .onChange(of: currentJump) { _, _ in
                                centeredCurrent = false; centerCurrent(browser, proxy: proxy)
                                focusedEpisodeID = browser.currentEpisodeID
                            }
                            .onChange(of: browser.episodes.count) { _, _ in centerCurrent(browser, proxy: proxy) }
                            .onAppear { centerCurrent(browser, proxy: proxy) }
                    }
                    #endif
                }
                if browser.loadingEpisodes && !browser.episodes.isEmpty { ProgressView("Loading more episodes…") }
                if let error = browser.error {
                    EpisodeBrowserStatusView(title: browser.seasons.isEmpty ? "Seasons couldn’t load" : "Episodes couldn’t load",
                        detail: "Your place is saved. " + error) {
                        Button("Try again") {
                            selectionTask?.cancel()
                            selectionTask = Task {
                                if browser.seasons.isEmpty { await browser.load(context, preferredEpisode: preferredEpisode, force: true) }
                                else { await browser.loadMore() }
                            }
                        }.buttonStyle(ZoroButtonStyle(primary: true))
                            .playerOptionsDefaultFocus(playSelection != nil && browser.seasons.isEmpty)
                        alternateSeasonMenu(browser)
                    }
                } else if !browser.loadingEpisodes && !browser.loadingSeasons && browser.episodes.isEmpty {
                    EpisodeBrowserStatusView(title: browser.seasons.isEmpty ? "No seasons available" : "No episodes available",
                        detail: browser.seasons.isEmpty ? "There aren’t any seasons to show for this series." : "There aren’t any episodes to show in this season. Choose another season without losing your place.") {
                        alternateSeasonMenu(browser)
                    }
                }
            } else {
                EpisodeBrowserStatusView(title: "Loading seasons", detail: "Finding available seasons.", loading: true) { EmptyView() }
            }
        }.foregroundStyle(Theme.text)
            #if os(iOS)
            // Only the in-player list centers itself, so only it has to notice a drag. On a
            // show or season page this gesture competed with the page's own scrolling.
            .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { _ in
                // Written once per drag: every write redraws the list.
                if !centeredCurrent { centeredCurrent = true }
                if browser?.targetingCancelled == false { browser?.cancelTargeting() }
            }, including: playSelection != nil ? .all : .subviews)
            #endif
            #if os(tvOS)
            .onMoveCommand { _ in centeredCurrent = true; browser?.cancelTargeting() }
            #endif
            .task(id: "\(context.id):\(context.seasonId ?? ""):\(context.parentIndexNumber ?? -1):\(preferredEpisode?.id ?? ""):\(model.libraryRevision)") {
                if browser == nil {
                    if model.isDemo { browser = EpisodeBrowserState(library: PreviewEpisodeLibrary(context: context)) }
                    else if let client = model.client { browser = EpisodeBrowserState(library: client) }
                }
                let revision = model.libraryRevision
                let refresh = loadedRevision != nil && loadedRevision != revision
                if refresh && browser?.targetingCancelled != true { centeredCurrent = false }
                await browser?.load(context, preferredEpisode: preferredEpisode, force: refresh)
                if !Task.isCancelled { loadedRevision = revision }
            }
            .onDisappear { selectionTask?.cancel(); browser?.cancel() }
    }
    @ViewBuilder private func alternateSeasonMenu(_ browser: EpisodeBrowserState) -> some View {
        if browser.seasons.count > 1 {
            Menu {
                ForEach(browser.seasons) { season in
                    Button(season.seasonTitle) {
                        selectionTask?.cancel(); centeredCurrent = true; browser.cancelTargeting()
                        selectionTask = Task { await browser.selectSeason(season.id) }
                    }
                }
            } label: { Label("Choose another season", systemImage: "chevron.down") }
                .buttonStyle(ZoroButtonStyle()).accessibilityIdentifier("episode-browser-other-season")
        }
    }
    private func centerMobileCurrent(_ browser: EpisodeBrowserState) {
        guard !centeredCurrent, !browser.targetingCancelled, let scrollToEpisode,
              let current = browser.currentEpisodeID, browser.episodes.contains(where: { $0.id == current }) else { return }
        scrollToEpisode(current); centeredCurrent = true
    }
    private func centerCurrent(_ browser: EpisodeBrowserState, proxy: ScrollViewProxy) {
        guard !centeredCurrent, !browser.targetingCancelled, let current = browser.currentEpisodeID, browser.episodes.contains(where: { $0.id == current }) else { return }
        proxy.scrollTo(current, anchor: .center); centeredCurrent = true
    }
}

#if os(iOS)
/// Borderless rows share the page's vertical scroll and reuse cached episode artwork.
private struct EpisodeBrowseRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.adaptiveWindow) private var window
    let item: MediaItem
    let current: Bool
    var inPlayer = false
    /// Off when the synopsis sits outside the row's tap area.
    var showsOverview = true
    private var artworkWidth: CGFloat { textSize.isAccessibilitySize ? 176 : window.usesTabletLayout ? 180 : 128 }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let layout = textSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
            layout {
                MediaArtwork(item: item, landscape: true, width: 640)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(width: artworkWidth)
                    .overlay {
                        if inPlayer {
                            Image(systemName: current ? "arrow.uturn.backward" : "play.fill")
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 36, height: 36).background(.black.opacity(0.6), in: Circle())
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if model.preferences.showProgress, item.watchProgress > 0 {
                            GeometryReader { geometry in
                                Rectangle().fill(Theme.jade).frame(width: geometry.size.width * item.watchProgress)
                            }.frame(height: 3).background(.white.opacity(0.18))
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(item.indexNumber.map { String($0) + ". " } ?? "")\(item.name)")
                        .font(Theme.font(16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(item.durationLabel).font(Theme.font(12)).foregroundStyle(Theme.muted)
                    if current {
                        Text(inPlayer ? "Currently playing" : "Current episode")
                            .font(Theme.font(12)).foregroundStyle(Theme.jade)
                    } else if item.userData?.played == true {
                        Label("Watched", systemImage: "checkmark").font(Theme.font(12)).foregroundStyle(Theme.muted)
                    } else if item.resumeTicks > 0 {
                        Text("In progress").font(Theme.font(12)).foregroundStyle(Theme.jade)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsOverview, let overview = item.overview, !overview.isEmpty {
                Text(overview.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                    .font(Theme.font(13)).foregroundStyle(Theme.muted)
                    .lineLimit(textSize.isAccessibilitySize ? nil : 2)
            }
        }.padding(.vertical, showsOverview ? 16 : 0).foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, minHeight: Theme.target, alignment: .leading)
            .contentShape(Rectangle())
    }
}
#endif

private struct EpisodeBrowseCard: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    let current: Bool
    var inPlayer = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            MediaArtwork(item: item, landscape: true, width: 640).aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if inPlayer {
                        Image(systemName: current ? "arrow.uturn.backward" : "play.fill")
                            .font(.system(size: Theme.isTV ? 26 : 18, weight: .semibold))
                            .foregroundStyle(.white).frame(width: Theme.isTV ? 60 : 40, height: Theme.isTV ? 60 : 40)
                            .background(.black.opacity(0.6), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 1))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if model.preferences.showProgress, item.watchProgress > 0 {
                        GeometryReader { geometry in
                            Rectangle().fill(Theme.jade).frame(width: geometry.size.width * item.watchProgress)
                        }.frame(height: Theme.isTV ? 5 : 3).background(.white.opacity(0.18))
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 10))
            Text("\(item.indexNumber.map { String($0) + ". " } ?? "")\(item.name)")
                .font(Theme.font(Theme.isTV ? 23 : 16, weight: .semibold)).lineLimit(2)
            HStack(spacing: 8) {
                Text(item.durationLabel).foregroundStyle(Theme.muted)
                if current { Text(inPlayer ? "Currently playing" : "Current episode").foregroundStyle(Theme.jade) }
                else if item.userData?.played == true { Label("Watched", systemImage: "checkmark").foregroundStyle(Theme.muted) }
            }.font(Theme.font(Theme.isTV ? 18 : 12))
            if let overview = item.overview, !overview.isEmpty, !(Theme.isTV && inPlayer) {
                Text(overview.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                    .font(Theme.font(Theme.isTV ? 19 : 13)).foregroundStyle(Theme.muted).lineLimit(3)
            }
        }.padding(4).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct PreviewEpisodeLibrary: EpisodeLibrary {
    let context: MediaItem
    private var seriesID: String { context.episodeSeriesID ?? PreviewLibrary.shows[0].id }
    func seasons(seriesID: String) async throws -> ItemPage {
        ItemPage(items: (0...2).map { index in
            var season = MediaItem(id: "\(seriesID)-season-\(index)", name: index == 0 ? "Specials" : "Season \(index)", type: "Season")
            season.indexNumber = index; season.seriesId = seriesID; return season
        })
    }
    func episodes(seriesID: String, seasonID: String, start: Int) async throws -> ItemPage {
        let season = Int(seasonID.split(separator: "-").last ?? "1") ?? 1
        let values = PreviewLibrary.episodes.enumerated().map { index, source in
            var item = source; item.seriesId = seriesID; item.seasonId = seasonID
            item.seriesName = context.isSeries ? context.name : context.seriesName
            item.parentIndexNumber = season
            if seriesID != PreviewLibrary.shows[0].id || season != 1 { item.id = "\(seasonID)-episode-\(index + 1)" }
            if index == 0 { item.userData?.played = true }
            return item
        }
        return ItemPage(items: Array(values.dropFirst(start).prefix(30)), totalRecordCount: values.count)
    }
    func recentlyPlayedEpisode(seriesID: String) async throws -> MediaItem? { nil }
}

/// Lists versions independently and excludes paths, stream URLs and credentials.
private struct MediaFileInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let audioIndex: Int?
    private var versions: [MediaQuality] {
        var values = item.fileQualities
        if !values.isEmpty { values[0] = item.quality(audioIndex: audioIndex) }
        return values
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(item.displayTitle).font(Theme.font(Theme.isTV ? 32 : 23, weight: .bold, relativeTo: .title2))
                    if item.isEpisode { Text(item.episodeLabel).foregroundStyle(Theme.muted) }
                    ForEach(Array(versions.enumerated()), id: \.offset) { index, quality in
                        VStack(alignment: .leading, spacing: 12) {
                            if versions.count > 1 {
                                Text("Version \(index + 1)")
                                    .font(Theme.font(Theme.isTV ? 24 : 17, weight: .semibold))
                            }
                            if quality.facts.isEmpty { Text("File information is unavailable.").foregroundStyle(Theme.muted) }
                            ForEach(quality.facts) { fact in
                                ViewThatFits(in: .horizontal) {
                                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                                        Text(fact.title).foregroundStyle(Theme.muted).fixedSize()
                                        Spacer(minLength: 12)
                                        Text(fact.value).fixedSize()
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(fact.title).foregroundStyle(Theme.muted)
                                        Text(fact.value)
                                    }
                                }.accessibilityElement(children: .combine)
                            }
                        }.padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Text("Source file information. Playback quality can change with your connection, device and streaming settings.")
                        .font(Theme.font(Theme.isTV ? 20 : 13)).foregroundStyle(Theme.muted)
                }.font(Theme.font(Theme.isTV ? 22 : 15)).padding(Theme.gutter)
            }.background(Theme.background).foregroundStyle(Theme.text).navigationTitle("File details")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}

#if os(tvOS)
/// Foreground-only polling scoped to this server/account and visible screen.
struct TVLiveTVAvailabilityNotice: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    var channelID: String? = nil
    @State private var status: LiveTVAvailability?
    @State private var knownPolicy: String?
    var body: some View {
        Group {
            if model.features.liveTVAvailability, let knownPolicy {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Live TV channel limit", systemImage: "info.circle")
                        .font(Theme.font(24, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(knownPolicy).font(Theme.font(22)).foregroundStyle(Theme.muted)
                    Text(status?.message ?? "Live TV availability could not be checked.")
                        .font(Theme.font(22, weight: .medium)).foregroundStyle(Theme.text)
                }.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityElement(children: .combine).accessibilityIdentifier("tv-live-capacity-notice")
            }
        }
        .task(id: "\(model.generation)-\(model.features.liveTVAvailability)-\(scenePhase == .active)-\(channelID ?? "")") {
            status = nil; knownPolicy = nil
            guard model.features.liveTVAvailability, !model.isDemo, scenePhase == .active, let client = model.client else { return }
            let generation = model.generation
            while !Task.isCancelled {
                let fresh = try? await client.liveTVAvailability(channelID: channelID)
                guard !Task.isCancelled, generation == model.generation, scenePhase == .active else { return }
                status = fresh
                if let fresh { knownPolicy = fresh.policy }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
}
#endif
