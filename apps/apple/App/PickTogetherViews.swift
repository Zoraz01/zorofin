import CoreImage.CIFilterBuiltins
import SwiftUI
import ZorofinCore

// Pick Together (handoff: docs/handoffs/PICK_TOGETHER_APPS_HANDOFF.md, mockups in
// docs/design/pick-together/mockups). Phones vote; Apple TV hosts and displays.
// Session swipes never write Catch Up taste, played state, favorites or the watchlist.

/// One account-scoped session on this device. Lives on AppModel so closing the
/// screen only pauses observation; Leave is the explicit way out.
@MainActor @Observable final class PickTogetherController {
    private(set) var tracker = PickTogetherTracker()
    var session: PickTogetherSession? { tracker.session }
    /// This seat's remaining deck, in server order.
    private(set) var cards: [PickTogetherCard] = []
    private(set) var busy = false
    /// The card whose swipe is waiting for the server.
    private(set) var pendingSwipe: String?
    var error: String?
    /// A new match to celebrate once.
    var moment: PickTogetherCard?
    var showResults = false
    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var epoch = 0

    func bind(_ client: JellyfinClient?, generation: UUID) {
        guard generation != self.generation else { self.client = client; return }
        reset(); self.client = client; self.generation = generation
    }

    func reset() {
        epoch += 1; clear(); busy = false; pendingSwipe = nil; error = nil
    }

    /// Forgets the session without cancelling the call in flight.
    private func clear() { tracker.reset(); cards = []; moment = nil; showResults = false }

    private func run(_ work: (JellyfinClient, Int) async throws -> Void) async {
        guard !busy, let client else { return }
        let started = epoch
        busy = true; error = nil
        defer { if started == epoch { busy = false } }
        do { try await work(client, started) }
        catch is CancellationError { }
        catch { if started == epoch { fail(error) } }
    }

    private func fail(_ error: Error) {
        let known = error as? PickTogetherError
        if known?.endsSession == true { reset() }
        self.error = (known ?? (error as? LocalizedError))?.errorDescription ?? "Couldn’t reach Pick Together. Try again."
    }

    private func take(_ view: PickTogetherSession, started: Int) {
        guard started == epoch else { return }
        let first = tracker.session == nil || tracker.session?.id != view.id
        tracker.apply(view)
        if first { tracker.absorbMatches() }
    }

    func create(kind: PickTogetherKind, display: Bool) async {
        await run { client, started in
            let view = try await client.createPickTogether(kind: kind, display: display)
            guard started == epoch else { return }
            clear(); take(view, started: started)
        }
    }

    func join(_ text: String, server: ServerAddress?) async {
        guard let code = PickTogetherLink.code(from: text, server: server) else {
            error = PickTogetherError.invalidCode.errorDescription; return
        }
        await run { client, started in
            let view = try await client.joinPickTogether(code: code)
            guard started == epoch else { return }
            clear(); take(view, started: started)
            try await refreshDeck(client, started: started)
        }
    }

    /// One poll: unchanged replies keep the full session; the deck follows status and round.
    func refresh() async {
        guard let client, let session else { return }
        let started = epoch
        do {
            if let view = try await client.pickTogetherState(session.id, seat: session.seat, since: session.version) {
                take(view, started: started)
            }
            try await refreshDeck(client, started: started)
        } catch is CancellationError {
        } catch let failure as PickTogetherError where failure.endsSession {
            if started == epoch { fail(failure) }
        } catch {
            // A missed poll is not an error worth showing; the next one retries.
        }
    }

    private func refreshDeck(_ client: JellyfinClient, started: Int) async throws {
        guard started == epoch, tracker.needsDeck, let session, pendingSwipe == nil else { return }
        let deck = try await client.pickTogetherDeck(session.id, seat: session.seat)
        guard started == epoch, deck.round == tracker.session?.round else { return }
        tracker.deckFetched(deck); cards = deck.cards
    }

    /// Polls about every 2 s while the caller's screen is visible and the app is active.
    func poll() async {
        while !Task.isCancelled, session != nil {
            await refresh()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    /// Keeps the card until the server answers; never replays an uncertain swipe.
    func swipe(_ card: PickTogetherCard, _ choice: PickTogetherChoice) async {
        guard pendingSwipe == nil, !busy, let client, let session, cards.first?.itemID == card.itemID else { return }
        let started = epoch, round = session.round
        pendingSwipe = card.itemID; error = nil
        defer { if started == epoch { pendingSwipe = nil } }
        do {
            let result = try await client.pickTogetherSwipe(session.id, seat: session.seat, itemID: card.itemID, choice: choice)
            guard started == epoch, tracker.session?.round == round else { return }
            cards.removeAll { $0.itemID == card.itemID }
            if let match = tracker.newMatch(result.match) { moment = match }
            await refresh()
        } catch is CancellationError {
        } catch {
            guard started == epoch else { return }
            fail(error)
            // Re-read the deck rather than guessing whether the swipe landed.
            if let failure = error as? PickTogetherError, failure == .notSwiping || failure == .server(409) { await refresh() }
        }
    }

    func host(_ action: PickTogetherHostAction) async {
        await run { client, started in
            guard let session else { return }
            let view = try await client.pickTogetherHost(session.id, seat: session.seat, action: action)
            take(view, started: started)
            if action == .nextRound { showResults = false; cards = [] }
            try await refreshDeck(client, started: started)
        }
    }

    func remove(_ member: PickTogetherMember) async {
        await run { client, started in
            guard let session else { return }
            take(try await client.pickTogetherRemove(session.id, seat: session.seat, target: member.seat), started: started)
        }
    }

    func leave() async {
        guard let client, let session else { reset(); return }
        busy = true
        _ = try? await client.pickTogetherLeave(session.id, seat: session.seat)
        reset()
    }
}

// MARK: - Shared pieces

enum PickPalette {
    static let colors: [UInt32] = [0x3b6ef5, 0xe08a2c, 0xa070e8, 0x4fd1a1, 0xe0607e, 0x2fb5c9, 0xd4b13c, 0x8a96a3]
    static func color(_ index: Int) -> Color { Color(hex: colors[abs(index) % colors.count]) }
}

struct PickAvatar: View {
    let member: PickTogetherMember
    let index: Int
    var size: CGFloat = 40
    var body: some View {
        Text(member.initials.prefix(1)).font(Theme.font(size * 0.42, weight: .bold))
            .foregroundStyle(Color(hex: 0x0f1211)).frame(width: size, height: size)
            .background(PickPalette.color(index), in: Circle())
            .overlay(Circle().stroke(Theme.background, lineWidth: 2)).accessibilityHidden(true)
    }
}

/// Core Image QR at level M with a quiet zone. The code stays visible beside it.
struct PickQRCode: View {
    let url: URL?
    var body: some View {
        if let image = Self.image(url) {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                .padding(10).background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("QR code for the join link")
        }
    }
    static func image(_ url: URL?) -> UIImage? {
        guard let data = url?.absoluteString.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data; filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

private struct PickPoster: View {
    let card: PickTogetherCard
    var width = 400
    var body: some View {
        MediaArtwork(item: card.mediaItem, width: width, showPreviewTitle: true)
            .aspectRatio(2 / 3, contentMode: .fit)
    }
}

/// Opens the matched title through the ordinary catalog and player.
@MainActor private func playMatch(_ card: PickTogetherCard, model: AppModel, together: Bool) async {
    guard let client = model.client else { return }
    do {
        let item = try await client.item(card.itemID)
        if together && !model.watchTogether.isJoined {
            await model.watchTogether.create(name: String("Pick Together: \(item.name)".prefix(100)))
            guard model.watchTogether.isJoined else {
                model.message = model.watchTogether.error ?? "Couldn’t start a group. Try again."; return
            }
        }
        model.pendingPlay = item
    } catch {
        model.message = "That title couldn’t be opened. Try again."
    }
}

// MARK: - Phone and tablet: vote

#if os(iOS)
/// The Together body of Catch Up (and the sheet from Watch together).
struct PickTogetherPhoneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    var startKind: PickTogetherKind?
    var close: (() -> Void)?
    @State private var kind = PickTogetherKind.movie
    @State private var joining = false
    @State private var code = ""
    @State private var autoStarted = false
    private var pick: PickTogetherController { model.pickTogether }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let session = pick.session {
                if session.status == .lobby || session.status == .preparing {
                    PickLobby(session: session)
                } else if session.status.isOver {
                    ended(session)
                } else if pick.showResults || pick.cards.isEmpty {
                    PickResults(session: session)
                } else {
                    PickDeck(session: session)
                }
            } else {
                start
            }
            if let error = pick.error {
                Text(error).font(Theme.font(15)).foregroundStyle(Theme.muted)
                    .accessibilityAddTraits(.updatesFrequently).accessibilityIdentifier("pick-error")
            }
        }
        .overlay { if let moment = pick.moment, let session = pick.session { PickMatchMoment(card: moment, session: session) } }
        .sensoryFeedback(.success, trigger: pick.moment?.itemID) { _, new in new != nil }
        .task { pick.bind(model.client, generation: model.generation)
            if let startKind, !autoStarted, pick.session == nil { autoStarted = true; await pick.create(kind: startKind, display: false) } }
        .task(id: "\(pick.session?.id ?? "")-\(scenePhase == .active)") {
            guard scenePhase == .active, pick.session != nil else { return }
            await pick.poll()
        }
    }

    private var start: some View {
        VStack(spacing: 18) {
            ZStack {
                ForEach(0..<3) { index in
                    RoundedRectangle(cornerRadius: 18).fill(PickPalette.color(index + 5).opacity(0.35))
                        .frame(width: 150, height: 210).rotationEffect(.degrees(Double(index - 1) * 9))
                        .offset(x: CGFloat(index - 1) * 56, y: index == 1 ? -8 : 6)
                }
                Image(systemName: "heart.fill").font(.system(size: 34)).foregroundStyle(Theme.jade)
            }.frame(height: 240).frame(maxWidth: .infinity).accessibilityHidden(true)
            Text("Swipe together, watch what everyone likes")
                .font(Theme.font(26, weight: .bold, relativeTo: .title)).multilineTextAlignment(.center)
            Text("Everyone swipes on their own phone. Picks are based on what each of you has watched and liked.")
                .font(Theme.font(16)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                ForEach(PickTogetherKind.allCases) { option in
                    Button(option.label) { kind = option }
                        .font(Theme.font(17, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(kind == option ? Theme.text : Theme.muted)
                        .background(kind == option ? Theme.jade.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(kind == option ? Theme.jade : Theme.border, lineWidth: 1))
                        .buttonStyle(.plain).accessibilityAddTraits(kind == option ? .isSelected : [])
                }
            }
            Button { Task { await pick.create(kind: kind, display: false) } } label: {
                Text("Start a group").frame(maxWidth: .infinity)
            }.buttonStyle(PickPrimaryStyle()).disabled(pick.busy || model.isDemo).accessibilityIdentifier("pick-start")
            if joining {
                HStack(spacing: 10) {
                    TextField("Code or link", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(Theme.font(18, weight: .semibold)).padding(.horizontal, 14).frame(minHeight: 48)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                        .onSubmit { Task { await pick.join(code, server: model.session?.server) } }
                        .accessibilityLabel("Six-character code or join link")
                    Button("Join") { Task { await pick.join(code, server: model.session?.server) } }
                        .buttonStyle(ZoroButtonStyle()).disabled(pick.busy || code.isEmpty)
                }
            } else {
                Button("Join with a code") { joining = true }.font(Theme.font(17, weight: .semibold))
                    .foregroundStyle(Theme.text).frame(minHeight: 44).buttonStyle(.plain)
            }
            if model.isDemo {
                Text("Connect to your own server to swipe with others.").font(Theme.font(15)).foregroundStyle(Theme.muted)
            }
        }.frame(maxWidth: 520).frame(maxWidth: .infinity)
    }

    private func ended(_ session: PickTogetherSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.status == .failed ? "Couldn’t find titles for this group" : "This session has ended")
                .font(Theme.font(24, weight: .bold))
            if !session.matches.isEmpty { PickResults(session: session) }
            Button("Start another") { pick.reset() }.buttonStyle(ZoroButtonStyle(primary: true))
        }
    }
}

private struct PickPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.font(18, weight: .bold)).foregroundStyle(Theme.background)
            .padding(.horizontal, 20).frame(minHeight: 54).background(Theme.jade, in: RoundedRectangle(cornerRadius: 16))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct PickLobby: View {
    @Environment(AppModel.self) private var model
    let session: PickTogetherSession
    private var pick: PickTogetherController { model.pickTogether }
    private var link: URL? { model.session.flatMap { PickTogetherLink.joinURL(server: $0.server, code: session.code) } }
    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 2) {
                Text("Pick Together").font(Theme.font(18, weight: .bold))
                Text("\(session.kind.label) · \(session.voters) joined").font(Theme.font(14)).foregroundStyle(Theme.muted)
            }
            VStack(spacing: 14) {
                PickQRCode(url: link).frame(width: 190, height: 190)
                Text(PickTogetherCode.spaced(session.code)).font(Theme.font(38, weight: .bold)).tracking(6)
                    .textSelection(.enabled).accessibilityLabel("Code \(session.code.map(String.init).joined(separator: " "))")
                Text("Scan with a phone camera, or enter the code in Catch Up").font(Theme.font(15))
                    .foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }.padding(22).frame(maxWidth: .infinity).background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
            if let link {
                ShareLink(item: link, subject: Text("Pick Together"), message: Text("Join with code \(session.code)")) {
                    HStack { Text("Share invite link").font(Theme.font(17, weight: .semibold)); Spacer()
                        Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.jade) }
                        .padding(.horizontal, 18).frame(minHeight: 54).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Array(session.voterMembers.enumerated()), id: \.element.id) { index, member in
                        VStack(spacing: 6) {
                            PickAvatar(member: member, index: index, size: 58)
                            Text(member.seat == session.seat ? "You" : member.name).font(Theme.font(14)).lineLimit(1)
                        }.frame(width: 72)
                            .contextMenu {
                                if session.host && member.seat != session.seat {
                                    Button("Remove \(member.name)", role: .destructive) { Task { await pick.remove(member) } }
                                }
                            }
                            .accessibilityElement(children: .combine)
                    }
                }.padding(.vertical, 4)
            }
            Text("About 20 picks each. Same titles for everyone, in your own order.")
                .font(Theme.font(14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            if session.status == .preparing {
                ProgressView("Finding titles for everyone…").frame(maxWidth: .infinity)
            } else if session.host {
                Button { Task { await pick.host(.start) } } label: { Text("Start swiping").frame(maxWidth: .infinity) }
                    .buttonStyle(PickPrimaryStyle()).disabled(pick.busy || !session.canStart(asDisplay: false))
                    .opacity(session.canStart(asDisplay: false) ? 1 : 0.45)
                    .accessibilityIdentifier("pick-start-swiping")
                if session.voters < 2 {
                    Text("Start unlocks when someone else joins.").font(Theme.font(14)).foregroundStyle(Theme.muted)
                }
            } else {
                Text("Waiting for the host to start").font(Theme.font(16, weight: .semibold)).foregroundStyle(Theme.jade)
            }
            Button("Leave", role: .destructive) { Task { await pick.leave() } }.font(Theme.font(16))
                .foregroundStyle(Color(hex: 0xf08a8a)).buttonStyle(.plain).frame(minHeight: 44)
        }
    }
}

private struct PickDeck: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let session: PickTogetherSession
    @State private var drag: CGFloat = 0
    @State private var cardWidth: CGFloat = 320
    private var pick: PickTogetherController { model.pickTogether }
    private var gestures: Bool { !reduceMotion && !typeSize.isAccessibilitySize }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                progress
                if !session.matches.isEmpty {
                    Button { pick.showResults = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "heart.fill").foregroundStyle(Theme.jade)
                            Text(session.matches.count == 1 ? "1 match" : "\(session.matches.count) matches")
                        }.font(Theme.font(15, weight: .semibold)).padding(.horizontal, 12).frame(minHeight: 36)
                            .background(Theme.panel, in: Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("pick-matches")
                }
            }
            if let card = pick.cards.first {
                ZStack {
                    if pick.cards.count > 1 {
                        artwork(pick.cards[1]).scaleEffect(0.97).offset(y: 10).opacity(0.6).accessibilityHidden(true)
                    }
                    cardView(card)
                }.background(GeometryReader { proxy in
                    Color.clear.onAppear { cardWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in cardWidth = width }
                })
                HStack(spacing: 28) {
                    decision(card, .skip)
                    decision(card, .like)
                }.disabled(pick.pendingSwipe != nil).frame(maxWidth: .infinity)
                Text(session.kind.label).font(Theme.font(13)).foregroundStyle(Theme.muted)
            }
        }.onChange(of: pick.cards.first?.itemID) { _, _ in drag = 0 }
    }

    private var progress: some View {
        let total = max(session.you?.total ?? 0, pick.cards.count)
        let done = max(0, total - pick.cards.count)
        return HStack(spacing: 3) {
            ForEach(0..<max(1, min(total, 30)), id: \.self) { index in
                Capsule().fill(index < done ? Theme.text : Theme.border).frame(height: 4)
            }
        }.frame(maxWidth: .infinity).accessibilityElement()
            .accessibilityLabel("\(done) of \(total) swiped")
    }

    private func artwork(_ card: PickTogetherCard) -> some View {
        MediaArtwork(item: card.mediaItem, width: 780, showPreviewTitle: true)
            .aspectRatio(2 / 3, contentMode: .fit).frame(maxHeight: 560)
            .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func cardView(_ card: PickTogetherCard) -> some View {
        artwork(card)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).font(Theme.font(26, weight: .bold, relativeTo: .title)).lineLimit(2)
                    Text([card.metadata, card.genres.first].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Theme.font(15)).foregroundStyle(Theme.muted)
                    if let reason = card.reason { Text(reason).font(Theme.font(14, weight: .medium)).foregroundStyle(Theme.jade) }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: .top, endPoint: .bottom))
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
            }
            .overlay(alignment: drag > 0 ? .topLeading : .topTrailing) {
                Text(drag > 0 ? "LIKE" : "SKIP").font(Theme.font(22, weight: .heavy))
                    .foregroundStyle(drag > 0 ? Theme.jade : Theme.text).padding(.horizontal, 12).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(drag > 0 ? Theme.jade : Theme.text, lineWidth: 3))
                    .rotationEffect(.degrees(drag > 0 ? -12 : 12)).padding(22)
                    .opacity(min(1, abs(drag) / 60)).accessibilityHidden(true)
            }
            .offset(x: drag).rotationEffect(.degrees(Double(drag / 28)))
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { value in
                    guard pick.pendingSwipe == nil else { return }
                    if abs(value.translation.width) > 5 { drag = value.translation.width }
                }
                .onEnded { value in
                    guard pick.pendingSwipe == nil else { return }
                    let x = value.translation.width, y = value.translation.height
                    let projected = value.predictedEndTranslation.width - x
                    let flick = abs(x) >= 32 && abs(projected) > 100 && projected * x > 0
                    if (abs(x) >= min(72, cardWidth * 0.2) || flick), abs(x) > abs(y) * 0.8 {
                        commit(card, x < 0 ? .skip : .like)
                    } else { withAnimation(.easeOut(duration: 0.16)) { drag = 0 } }
                }, including: gestures ? .all : .none)
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: Text("Skip")) { commit(card, .skip) }
            .accessibilityAction(named: Text("Like")) { commit(card, .like) }
    }

    private func commit(_ card: PickTogetherCard, _ choice: PickTogetherChoice) {
        guard pick.pendingSwipe == nil else { return }
        if gestures { withAnimation(.easeOut(duration: 0.19)) { drag = (choice == .skip ? -1 : 1) * max(cardWidth * 1.3, 400) } }
        Task {
            await pick.swipe(card, choice)
            // A failed swipe keeps the card: bring it back.
            if pick.cards.first?.itemID == card.itemID { withAnimation(gestures ? .easeOut(duration: 0.16) : nil) { drag = 0 } }
        }
    }

    private func decision(_ card: PickTogetherCard, _ choice: PickTogetherChoice) -> some View {
        let like = choice == .like
        return Button { commit(card, choice) } label: {
            Image(systemName: like ? "heart.fill" : "xmark").font(.system(size: like ? 28 : 24, weight: .semibold))
                .foregroundStyle(like ? Theme.background : Theme.text).frame(width: 66, height: 66)
                .background(like ? Theme.jade : Color.clear, in: Circle())
                .overlay(Circle().stroke(like ? Color.clear : Theme.border, lineWidth: 1.5))
        }.buttonStyle(.plain).accessibilityLabel(like ? "Like" : "Skip").accessibilityIdentifier("pick-\(choice.rawValue)")
    }
}

private struct PickMatchMoment: View {
    @Environment(AppModel.self) private var model
    let card: PickTogetherCard
    let session: PickTogetherSession
    private var pick: PickTogetherController { model.pickTogether }
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            PickPoster(card: card, width: 520).frame(maxWidth: 230).clipShape(RoundedRectangle(cornerRadius: 18))
                .rotationEffect(.degrees(-4)).shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            HStack(spacing: -10) {
                ForEach(Array(session.voterMembers.prefix(5).enumerated()), id: \.element.id) { index, member in
                    PickAvatar(member: member, index: index, size: 44)
                }
                Image(systemName: "heart.fill").font(.system(size: 18)).foregroundStyle(Theme.background)
                    .frame(width: 44, height: 44).background(Theme.jade, in: Circle())
            }
            Text("It’s a match").font(Theme.font(34, weight: .heavy, relativeTo: .largeTitle))
            Text(card.tally.map { "\($0) liked \(card.title)." } ?? "Everyone liked \(card.title).")
                .font(Theme.font(17)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Spacer()
            Button { pick.moment = nil; pick.showResults = true } label: { Text("See matches").frame(maxWidth: .infinity) }
                .buttonStyle(PickPrimaryStyle())
            Button("Keep swiping") { pick.moment = nil }.font(Theme.font(17, weight: .semibold))
                .foregroundStyle(Theme.text).buttonStyle(.plain).frame(minHeight: 44)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.opacity(0.97))
            .contentShape(Rectangle()).onTapGesture { pick.moment = nil }
            .accessibilityAddTraits(.isModal)
            .task(id: card.itemID) {
                do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
                if pick.moment?.itemID == card.itemID { pick.moment = nil }
            }
    }
}

private struct PickResults: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: PickTogetherSession
    private var pick: PickTogetherController { model.pickTogether }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pick Together · \(session.kind.label)").font(Theme.font(14)).foregroundStyle(Theme.muted)
                Text("Your matches").font(Theme.font(28, weight: .bold, relativeTo: .title))
            }
            if session.matches.isEmpty {
                Text(pick.cards.isEmpty && session.status == .swiping
                     ? "You’re done. Matches show up here as the others finish."
                     : "No matches yet. Keep swiping.")
                    .font(Theme.font(16)).foregroundStyle(Theme.muted)
            } else {
                Text("Everyone liked").font(Theme.font(19, weight: .semibold))
                ForEach(session.matches) { card in matchRow(card) }
            }
            if !session.almost.isEmpty {
                (Text("Almost").font(Theme.font(19, weight: .semibold)) + Text(" · all but one").font(Theme.font(15)).foregroundStyle(Theme.muted))
                ForEach(session.almost) { card in
                    HStack(spacing: 14) {
                        PickPoster(card: card, width: 200).frame(width: 52).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card.title).font(Theme.font(17, weight: .semibold))
                            Text([card.tally.map { "\($0) liked" }, card.metadata].compactMap { $0 }.joined(separator: " · "))
                                .font(Theme.font(14)).foregroundStyle(Theme.muted)
                        }
                    }.opacity(0.8).accessibilityElement(children: .combine)
                }
            }
            Text("Only counts are shown, never who skipped.").font(Theme.font(14)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity)
            if !pick.cards.isEmpty && session.status == .swiping {
                Button("Keep swiping") { pick.showResults = false }.buttonStyle(ZoroButtonStyle())
            }
            HStack(spacing: 12) {
                if session.host {
                    Button("Another round") { Task { await pick.host(.nextRound) } }.buttonStyle(ZoroButtonStyle())
                        .disabled(pick.busy || !(session.status == .swiping || session.status == .empty))
                    Button("End session") { Task { await pick.host(.end) } }.buttonStyle(ZoroButtonStyle()).disabled(pick.busy)
                } else {
                    Button("Leave") { Task { await pick.leave() } }.buttonStyle(ZoroButtonStyle())
                }
            }.frame(maxWidth: .infinity)
        }
    }

    private func matchRow(_ card: PickTogetherCard) -> some View {
        HStack(alignment: .top, spacing: 14) {
            PickPoster(card: card, width: 300).frame(width: 82).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(card.title).font(Theme.font(19, weight: .bold)).lineLimit(2)
                Text([card.metadata, card.communityRating.map { "★ " + String(format: "%.1f", $0) }].compactMap { $0 }
                        .filter { !$0.isEmpty }.joined(separator: " · ")).font(Theme.font(14)).foregroundStyle(Theme.muted)
                if let tally = card.tally { Text("\(tally) liked").font(Theme.font(14, weight: .medium)).foregroundStyle(Theme.jade) }
                HStack(spacing: 8) {
                    Button("Play") { Task { dismiss(); await playMatch(card, model: model, together: false) } }
                        .buttonStyle(ZoroButtonStyle(primary: true))
                    if model.watchTogether.isJoined || model.watchTogether.canCreate {
                        Button("Watch together") { Task { dismiss(); await playMatch(card, model: model, together: true) } }
                            .buttonStyle(ZoroButtonStyle())
                    }
                }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }.padding(14).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// `Just me | Together` beside the Catch Up title.
struct CatchUpModePicker: View {
    @Binding var together: Bool
    var body: some View {
        HStack(spacing: 2) {
            option("Just me", selected: !together) { together = false }
            option("Together", selected: together) { together = true }
        }.padding(3).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain).accessibilityLabel("Catch Up mode")
    }
    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.font(15, weight: .semibold)).foregroundStyle(selected ? Theme.text : Theme.muted)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(selected ? Theme.border : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif

// MARK: - Apple TV: host and display

#if os(tvOS)
/// Home's Pick Together entry on Apple TV (no new main-menu tab).
struct PickTogetherHomeAction: View {
    @Environment(AppModel.self) private var model
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 20) {
                Image(systemName: "rectangle.stack.fill").font(.system(size: 30)).foregroundStyle(Theme.jade)
                    .frame(width: 64, height: 64).background(Theme.jade.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.pickTogether.session?.display == true ? "Back to Pick Together" : "Pick together")
                        .font(Theme.font(28, weight: .semibold))
                    Text("Everyone swipes on their phone. Matches show up here.").font(Theme.font(20)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 24).frame(width: 760, height: 104, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(ArtworkButtonStyle()).accessibilityIdentifier("home-pick-together")
    }
}

struct PickTogetherTVView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    var startKind: PickTogetherKind?
    @State private var autoStarted = false
    @State private var selected: String?
    @FocusState private var focus: String?
    private var pick: PickTogetherController { model.pickTogether }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Group {
                if let session = pick.session, session.display {
                    if session.status == .lobby || session.status == .preparing { lobby(session) }
                    else { live(session) }
                } else { start }
            }.padding(.horizontal, 96).padding(.vertical, 64)
        }
        .foregroundStyle(Theme.text)
        .task {
            pick.bind(model.client, generation: model.generation)
            // A phone seat on this account is not this screen's session.
            if pick.session?.display == false { pick.reset() }
            if let startKind, !autoStarted, pick.session == nil { autoStarted = true; await pick.create(kind: startKind, display: true) }
        }
        .task(id: "\(pick.session?.id ?? "")-\(scenePhase == .active)") {
            guard scenePhase == .active, pick.session?.display == true else { return }
            await pick.poll()
        }
        .onExitCommand { dismiss() }
    }

    private var start: some View {
        VStack(spacing: 34) {
            Spacer()
            Text("Pick Together").font(Theme.font(26, weight: .semibold)).foregroundStyle(Theme.jade)
            Text("What are we watching?").font(Theme.font(68, weight: .bold))
            Text("Everyone swipes on their own phone. Matches show up here, and Play starts the pick on this TV.")
                .font(Theme.font(28)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 1100)
            HStack(spacing: 48) {
                ForEach(PickTogetherKind.allCases) { kind in
                    Button { Task { await pick.create(kind: kind, display: true) } } label: {
                        VStack(spacing: 18) {
                            Image(systemName: kind == .movie ? "film" : "tv").font(.system(size: 64, weight: .semibold))
                                .foregroundStyle(Theme.jade)
                            Text(kind.label).font(Theme.font(36, weight: .bold))
                        }.frame(width: 380, height: 260).background(Theme.panel, in: RoundedRectangle(cornerRadius: 24))
                    }.buttonStyle(ArtworkButtonStyle()).disabled(pick.busy || model.isDemo)
                        .accessibilityLabel("Pick \(kind.label.lowercased()) together")
                }
            }.focusSection().padding(.top, 10)
            if pick.busy { ProgressView() }
            if let error = pick.error { Text(error).font(Theme.font(24)).foregroundStyle(Theme.muted) }
            if model.isDemo { Text("Connect to your own server to start a group.").font(Theme.font(24)).foregroundStyle(Theme.muted) }
            Spacer()
            Text("Press Menu to go back").font(Theme.font(20)).foregroundStyle(Theme.muted)
        }.frame(maxWidth: .infinity)
    }

    private func link(_ session: PickTogetherSession) -> URL? {
        model.session.flatMap { PickTogetherLink.joinURL(server: $0.server, code: session.code) }
    }

    private func lobby(_ session: PickTogetherSession) -> some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 24) {
                Text("Pick Together · \(session.kind.label)").font(Theme.font(24)).foregroundStyle(Theme.muted)
                Text("Grab your phones.").font(Theme.font(64, weight: .bold))
                Text("Scan the code, or open Catch Up → Together and type the code. Everyone swipes on their own phone, and matches show up here.")
                    .font(Theme.font(28)).foregroundStyle(Theme.muted)
                HStack(alignment: .top, spacing: 40) {
                    PickQRCode(url: link(session)).frame(width: 240, height: 240)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Group code").font(Theme.font(24)).foregroundStyle(Theme.muted)
                        Text(PickTogetherCode.spaced(session.code)).font(Theme.font(88, weight: .heavy)).tracking(8)
                            .lineLimit(1).fixedSize()
                            .accessibilityLabel("Code \(session.code.map(String.init).joined(separator: " "))")
                    }
                }
                Spacer()
            }.frame(width: 860, alignment: .leading)
            VStack(alignment: .leading, spacing: 16) {
                Text("Joined · \(session.voters)").font(Theme.font(24)).foregroundStyle(Theme.muted)
                if session.voterMembers.isEmpty {
                    Text("Waiting for the first phone…").font(Theme.font(26)).foregroundStyle(Theme.muted).padding(.vertical, 12)
                }
                ForEach(Array(session.voterMembers.enumerated()), id: \.element.id) { index, member in
                    HStack(spacing: 18) {
                        PickAvatar(member: member, index: index, size: 56)
                        Text(member.name).font(Theme.font(30, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Text(member.host ? "Host" : "Ready").font(Theme.font(22)).foregroundStyle(member.host ? Theme.jade : Theme.muted)
                    }.padding(.horizontal, 20).frame(height: 84).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
                }
                Spacer()
                if session.status == .preparing { ProgressView("Finding titles for everyone…") }
                HStack(spacing: 20) {
                    Button("Start swiping") { Task { await pick.host(.start) } }
                        .buttonStyle(ZoroButtonStyle(primary: true))
                        .disabled(pick.busy || !session.canStart(asDisplay: true))
                        .opacity(session.canStart(asDisplay: true) ? 1 : 0.45)
                    Button("Cancel") { Task { await pick.host(.end); pick.reset(); dismiss() } }.buttonStyle(ZoroButtonStyle())
                }.focusSection()
                Text(session.voters < 2 ? "Start unlocks when two people have joined. The TV never swipes."
                                        : "The TV shows the group. It never swipes.")
                    .font(Theme.font(20)).foregroundStyle(Theme.muted)
                if let error = pick.error { Text(error).font(Theme.font(22)).foregroundStyle(Theme.muted) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func live(_ session: PickTogetherSession) -> some View {
        let chosen = session.matches.first { $0.itemID == selected } ?? session.matches.first
        return VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick Together · \(session.kind.label) · code \(PickTogetherCode.spaced(session.code))")
                        .font(Theme.font(22)).foregroundStyle(Theme.muted)
                    Text(title(session)).font(Theme.font(54, weight: .bold))
                }
                Spacer(minLength: 40)
                HStack(spacing: 28) {
                    ForEach(Array(session.voterMembers.enumerated()), id: \.element.id) { index, member in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(member.name) · \(member.swiped)/\(member.total)").font(Theme.font(20)).lineLimit(1)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.border)
                                Capsule().fill(PickPalette.color(index)).frame(width: 190 * member.progress)
                            }.frame(width: 190, height: 7)
                        }.accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(member.name), \(member.swiped) of \(member.total) swiped")
                    }
                }
            }
            Text(session.matches.isEmpty ? "Matches show up here when everyone likes the same title" : "Matches · everyone liked")
                .font(Theme.font(24, weight: .semibold)).foregroundStyle(Theme.jade)
            HStack(alignment: .top, spacing: 48) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 36) {
                        ForEach(session.matches) { card in
                            Button { selected = card.itemID } label: {
                                PickPoster(card: card, width: 500).frame(width: 260).clipShape(RoundedRectangle(cornerRadius: 14))
                            }.buttonStyle(ArtworkButtonStyle()).focused($focus, equals: card.itemID)
                                .accessibilityLabel("\(card.title), \(card.tally ?? "") liked")
                                .overlay(alignment: .bottomLeading) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(card.title).font(Theme.font(24, weight: .semibold)).lineLimit(1)
                                        Text([card.tally, card.metadata].compactMap { $0 }.joined(separator: " · "))
                                            .font(Theme.font(20)).foregroundStyle(Theme.muted)
                                    }.frame(width: 260, alignment: .leading).offset(y: 70)
                                }
                        }
                        ForEach(session.almost) { card in
                            VStack(spacing: 8) {
                                Text("Almost: \(card.title)").font(Theme.font(22)).multilineTextAlignment(.center)
                                Text(card.tally ?? "").font(Theme.font(20))
                            }.foregroundStyle(Theme.muted).padding(20).frame(width: 260, height: 390)
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                                .accessibilityElement(children: .combine)
                        }
                    }.padding(.vertical, 20).padding(.bottom, 70)
                }.scrollClipDisabled().focusSection()
                VStack(spacing: 18) {
                    Spacer()
                    if let chosen {
                        Button("Play \(chosen.title)") { Task { await playMatch(chosen, model: model, together: false); dismiss() } }
                            .buttonStyle(ZoroButtonStyle(primary: true)).lineLimit(1)
                    }
                    if session.host {
                        Button("Another round") { Task { await pick.host(.nextRound) } }.buttonStyle(ZoroButtonStyle())
                            .disabled(pick.busy || !(session.status == .swiping || session.status == .empty))
                        Button(session.status.isOver ? "Done" : "End") {
                            Task { if !session.status.isOver { await pick.host(.end) }; pick.reset(); dismiss() }
                        }.buttonStyle(ZoroButtonStyle())
                    } else {
                        Button("Close") { dismiss() }.buttonStyle(ZoroButtonStyle())
                    }
                    if let error = pick.error { Text(error).font(Theme.font(20)).foregroundStyle(Theme.muted) }
                }.frame(width: 420).focusSection()
            }
        }
        .onChange(of: session.matches.first?.itemID, initial: true) { _, first in
            // Focus the first match when it appears; later polls keep the viewer's place.
            if selected == nil, let first { selected = first; focus = first }
        }
        .onChange(of: focus) { _, id in if let id { selected = id } }
    }

    private func title(_ session: PickTogetherSession) -> String {
        switch session.status {
        case .swiping: session.voterMembers.allSatisfy(\.done) && !session.voterMembers.isEmpty ? "Everyone’s done" : "Swiping…"
        case .empty: "Out of titles"
        case .ended: "Session ended"
        case .failed: "Couldn’t find titles"
        default: "Getting ready…"
        }
    }
}
#endif
