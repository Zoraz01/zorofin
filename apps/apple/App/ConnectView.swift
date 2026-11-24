import SwiftUI
import ZorofinCore

struct ConnectView: View {
    private struct Connection {
        let server: ServerAddress
        let name: String
    }

    let isAdding: Bool
    let expectedViewerID: String?
    let reauthenticationServer: ServerAddress?
    @Environment(\.dismiss) private var dismiss
    @State private var remember = true
    @State private var deviceID = UUID().uuidString

    init(server: ServerAddress? = nil, serverName: String? = nil, username: String = "", expectedViewerID: String? = nil, isAdding: Bool = false) {
        self.isAdding = isAdding; self.expectedViewerID = expectedViewerID
        self.reauthenticationServer = server
        _serverText = State(initialValue: server?.url.absoluteString ?? "")
        _allowsHTTP = State(initialValue: server?.allowsLocalHTTP ?? false)
        _serverScheme = State(initialValue: server?.url.scheme == "http" ? .http : .https)
        _username = State(initialValue: username)
        _connection = State(initialValue: server.map { Connection(server: $0, name: serverName ?? "Jellyfin server") })
        _showSignIn = State(initialValue: server != nil)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var serverText = ""
    @State private var serverScheme: ServerAddress.InputScheme = .https
    @State private var username = ""
    @State private var password = ""
    @State private var allowsHTTP = false
    @State private var connection: Connection?
    @State private var showSignIn = false
    @State private var busy = false
    @State private var error: String?
    @State private var information: PublicDocument?
    @State private var quickCode: String?
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    #if os(tvOS)
    private enum Focus: Hashable { case server, https, http, quickConnect, username, password }
    @FocusState private var focusedControl: Focus?
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isAdding || showSignIn {
                    HStack {
                        if showSignIn && reauthenticationServer == nil {
                            Button { showSignIn = false } label: {
                                Label("Server", systemImage: "chevron.left").frame(minHeight: Theme.target)
                            }.buttonStyle(.plain).accessibilityIdentifier("change-server")
                        }
                        Spacer()
                        if isAdding {
                            Button("Cancel") { cancel(); dismiss() }
                                .buttonStyle(ZoroButtonStyle()).accessibilityIdentifier("cancel-add-server")
                        }
                    }.padding(.horizontal, Theme.isTV ? 64 : 28).padding(.vertical, 16)
                        .background(Theme.background)
                        #if os(tvOS)
                        // The header and centered form do not overlap horizontally.
                        // Give directional navigation a full-width target in both directions.
                        .focusSection()
                        .onMoveCommand { direction in
                            if direction == .down { focusedControl = showSignIn ? .quickConnect : .server }
                        }
                        #endif
                }
                if showSignIn { signInPage } else { serverPage }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { informationButton(.privacy); informationButton(.support) }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(spacing: 0) { informationButton(.privacy); informationButton(.support) }
                }.font(Theme.font(Theme.isTV ? 20 : 14))
                    .buttonStyle(.plain).padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    #if os(tvOS)
                    .focusSection()
                    #endif
            }.modifier(HideNavigationBar())
        }.foregroundStyle(Theme.text).background(Theme.background)
        #if os(tvOS)
        .onAppear { focusedControl = showSignIn ? .quickConnect : .server }
        #endif
        .sheet(item: $information) { PublicInformationView(page: $0) }
        .onDisappear { cancel(); password = "" }
        .onChange(of: model.generation) { _, _ in cancel(); password = "" }
        .onChange(of: serverText) { _, text in
            #if os(tvOS)
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.hasPrefix("https://") { serverScheme = .https }
            else if value.hasPrefix("http://") { serverScheme = .http }
            #endif
            resetConnection()
        }
        .onChange(of: serverScheme) { _, _ in resetConnection() }
        .onChange(of: allowsHTTP) { _, _ in resetConnection() }
        .onChange(of: showSignIn) { _, presented in
            if !presented { resetConnection() }
            #if os(tvOS)
            focusedControl = presented ? .quickConnect : .server
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancel(); password = "" }
        }
    }

    private func informationButton(_ page: PublicDocument) -> some View {
        Button { information = page } label: {
            Text(page.title).frame(minHeight: Theme.target).contentShape(Rectangle())
        }
    }

    private var serverPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Brand().padding(.bottom, 18)
                Text("Connect to\nyour server.")
                    .font(Theme.font(Theme.isTV ? 48 : 36, weight: .bold, relativeTo: .largeTitle))
                Text("Enter your Jellyfin server address. You’ll sign in next.")
                    .font(Theme.font(Theme.isTV ? 24 : 17)).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Server address").font(Theme.font(16, weight: .semibold))
                    #if os(tvOS)
                    serverSchemeSelector
                    #endif
                    TextField(Theme.isTV ? "Address, IP, port or path" : "Server address or IP", text: $serverText)
                        .modifier(ServerFieldInput()).accessibilityIdentifier("server-address")
                        #if os(tvOS)
                        .focused($focusedControl, equals: .server)
                        .foregroundStyle(focusedControl == .server ? Theme.background : Theme.text)
                        #endif
                }
                #if os(tvOS)
                Text(serverScheme == .http
                     ? "HTTP is unencrypted and only works for local servers. Add a port or path if needed."
                     : "No need to type https://. A local IP like 192.168.1.20:8096 works too. Add a port or path if needed.")
                    .font(Theme.font(18)).foregroundStyle(Theme.muted)
                #else
                if serverText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://") || allowsHTTP {
                    Toggle("Allow HTTP on my local network", isOn: $allowsHTTP)
                        .font(Theme.font(Theme.isTV ? 20 : 14))
                    if allowsHTTP {
                        Text("Local HTTP is unencrypted. Use it only on a network you trust. Public servers still require HTTPS.")
                            .font(Theme.font(14)).foregroundStyle(Theme.muted)
                    }
                }
                #endif
                Button { connect() } label: {
                    HStack {
                        if busy { ProgressView() }
                        Text(busy ? "Connecting…" : "Next")
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(ZoroButtonStyle(primary: true))
                    .disabled(busy || serverText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("connect-server")
                if busy {
                    Button("Cancel") { cancel() }.buttonStyle(ZoroButtonStyle())
                }
                connectionError
                if !isAdding {
                Button("Explore the app preview") { cancel(); model.showDemo() }
                    .buttonStyle(ZoroButtonStyle()).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("open-preview")
                Text("Preview uses fictional titles.")
                    .font(Theme.font(13)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                }
            }
            .padding(Theme.isTV ? 64 : 28).frame(maxWidth: Theme.isTV ? 850 : 580)
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        }.background(Theme.background)
        #if os(tvOS)
        .focusSection()
        #endif
    }

    #if os(tvOS)
    private var serverSchemeSelector: some View {
        HStack(spacing: 16) {
            ForEach(ServerAddress.InputScheme.allCases, id: \.self) { scheme in
                Button { selectServerScheme(scheme) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: serverScheme == scheme ? "checkmark.circle.fill" : "circle")
                        Text(scheme.rawValue.uppercased())
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(ZoroButtonStyle(primary: serverScheme == scheme))
                    .focused($focusedControl, equals: scheme == .https ? .https : .http)
                    .accessibilityLabel(scheme == .https ? "HTTPS, secure connection" : "HTTP, local network only")
                    .accessibilityAddTraits(serverScheme == scheme ? [.isSelected] : [])
                    .accessibilityIdentifier("server-scheme-" + scheme.rawValue)
            }
        }.frame(maxWidth: .infinity).focusSection()
    }

    private func selectServerScheme(_ scheme: ServerAddress.InputScheme) {
        // Keep pasted URLs consistent with the visible selection; never double-prefix.
        let text = serverText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix = text.range(of: "^(?i:https|http)://", options: .regularExpression) {
            serverText = scheme.rawValue + "://" + text[prefix.upperBound...]
        }
        serverScheme = scheme
    }
    #endif

    private var signInPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Brand().padding(.bottom, 8)
                if let connection {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(connection.name, systemImage: "server.rack")
                            .font(Theme.font(Theme.isTV ? 28 : 20, weight: .semibold))
                        Text(connection.server.url.absoluteString)
                            .font(Theme.font(Theme.isTV ? 20 : 14)).foregroundStyle(Theme.muted)

                    }
                    Text("Sign in")
                        .font(Theme.font(Theme.isTV ? 40 : 30, weight: .bold, relativeTo: .title))
                    Text("Use an account on this server.")
                        .font(Theme.font(Theme.isTV ? 24 : 17)).foregroundStyle(Theme.muted)
                    if let quickCode {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Approve this device").font(Theme.font(24, weight: .bold))
                            Text(quickCode).font(.system(size: Theme.isTV ? 56 : 40, weight: .semibold, design: .monospaced))
                                .tracking(7).accessibilityLabel("Quick Connect code \(quickCode.map(String.init).joined(separator: " "))")
                            Text("In an already signed-in Jellyfin app, open Quick Connect and enter this code.")
                                .foregroundStyle(Theme.muted)
                            HStack { ProgressView(); Text("Waiting for approval…") }
                            Button("Cancel") { cancel() }.buttonStyle(ZoroButtonStyle())
                        }.padding(24).background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
                    } else {
                        Button { beginQuickConnect() } label: {
                            Label("Use Quick Connect", systemImage: "link").frame(maxWidth: .infinity)
                        }.buttonStyle(ZoroButtonStyle(primary: true)).disabled(busy)
                        .accessibilityIdentifier("quick-connect")
                        #if os(tvOS)
                        .focused($focusedControl, equals: .quickConnect)
                        #endif
                        HStack { Rectangle().frame(height: 1); Text("or sign in").fixedSize(); Rectangle().frame(height: 1) }
                            .foregroundStyle(Theme.border).font(Theme.font(14))
                        TextField("Username", text: $username).modifier(ServerFieldInput())
                            .disabled(busy).accessibilityIdentifier("username")
                            #if os(tvOS)
                            .focused($focusedControl, equals: .username)
                            .foregroundStyle(focusedControl == .username ? Theme.background : Theme.text)
                            #endif
                        SecureField("Password", text: $password).modifier(ServerFieldInput())
                            .disabled(busy).accessibilityIdentifier("password")
                            #if os(tvOS)
                            .focused($focusedControl, equals: .password)
                            .foregroundStyle(focusedControl == .password ? Theme.background : Theme.text)
                            #endif
                        Button { signIn() } label: {
                            HStack { if busy { ProgressView() }; Text("Sign in") }.frame(maxWidth: .infinity)
                        }.buttonStyle(ZoroButtonStyle()).disabled(busy || username.isEmpty)
                            .accessibilityIdentifier("sign-in")
                    }
                    Toggle("Keep this account on this device", isOn: $remember)
                        .font(Theme.font(Theme.isTV ? 20 : 15)).disabled(busy)
                    connectionError
                    Text("Your password is never saved.")
                        .font(Theme.font(13)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                }
            }
            .padding(Theme.isTV ? 64 : 28).frame(maxWidth: Theme.isTV ? 850 : 580)
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        }.background(Theme.background)
        #if os(tvOS)
        .focusSection()
        #endif
    }

    @ViewBuilder private var connectionError: some View {
        if let error {
            Text(error).foregroundStyle(.orange).font(Theme.font(16))
                .accessibilityIdentifier("connection-error")
        }
    }

    private func cancel() {
        operationID = UUID()
        operation?.cancel(); operation = nil; busy = false; quickCode = nil
    }

    private func resetConnection() {
        cancel(); connection = nil; username = ""; password = ""; error = nil
    }

    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        operation = nil; busy = false; quickCode = nil
    }

    private func connect() {
        cancel(); error = nil; busy = true
        #if os(tvOS)
        let scheme = serverScheme, allowHTTP = serverScheme == .http
        #else
        let scheme = ServerAddress.InputScheme.https, allowHTTP = allowsHTTP
        #endif
        let id = operationID, address = serverText
        operation = Task { @MainActor in
            defer { finish(id) }
            do {
                // A bare local address such as 192.168.1.20:8096 tries HTTPS first, then
                // plain HTTP, since Jellyfin's default port does not serve TLS.
                let candidates = try ServerAddress.connectionCandidates(address, defaultScheme: scheme, allowsLocalHTTP: allowHTTP)
                var reached: (server: ServerAddress, info: PublicSystemInfo)?
                for (index, candidate) in candidates.enumerated() {
                    do {
                        let info = try await model.unauthenticatedClient(server: candidate, deviceID: deviceID).systemInfo()
                        reached = (candidate, info)
                        break
                    } catch ClientError.network where index < candidates.count - 1 {
                        try Task.checkCancellation()
                    }
                }
                guard let reached else { throw ClientError.network }
                let server = reached.server, info = reached.info
                try Task.checkCancellation()
                guard operationID == id else { return }
                let name = info.serverName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                connection = Connection(server: server, name: name.isEmpty ? "Jellyfin server" : name)
                showSignIn = true
            } catch is CancellationError { }
            catch { if operationID == id { self.error = error.localizedDescription } }
        }
    }

    private func signIn() {
        guard let server = connection?.server else { return }
        cancel(); error = nil; busy = true
        let id = operationID, name = username, secret = password, generation = model.generation
        operation = Task { @MainActor in
            defer { if operationID == id { password = ""; finish(id) } }
            do {
                let session = try await model.unauthenticatedClient(server: server, deviceID: deviceID).login(username: name, password: secret)
                try Task.checkCancellation()
                guard operationID == id else { return }
                try await accept(session, generation: generation)
            } catch is CancellationError { }
            catch ClientError.unauthorized {
                if operationID == id { self.error = "That username or password was not accepted by this server. Try again." }
            }
            catch { if operationID == id { self.error = error.localizedDescription } }
        }
    }

    private func beginQuickConnect() {
        guard let server = connection?.server else { return }
        cancel(); error = nil; password = ""; busy = true
        let id = operationID, generation = model.generation
        operation = Task { @MainActor in
            defer { finish(id) }
            do {
                let client = model.unauthenticatedClient(server: server, deviceID: deviceID)
                let initial = try await client.initiateQuickConnect()
                try Task.checkCancellation()
                guard operationID == id else { return }
                quickCode = initial.code
                for _ in 0..<60 {
                    try await Task.sleep(for: .seconds(2))
                    let state = try await client.quickConnectState(secret: initial.secret)
                    if state.authenticated {
                        let session = try await client.completeQuickConnect(secret: initial.secret)
                        try Task.checkCancellation()
                        guard operationID == id else { return }
                        try await accept(session, generation: generation); return
                    }
                }
                if operationID == id { error = "This code expired. Start Quick Connect again." }
            } catch is CancellationError { }
            catch { if operationID == id { self.error = error.localizedDescription } }
        }
    }

    private func accept(_ session: Session, generation: UUID) async throws {
        try Task.checkCancellation()
        guard model.generation == generation else { throw CancellationError() }
        if session.server.storageKey == reauthenticationServer?.storageKey,
           let expectedViewerID, expectedViewerID != session.viewer.id {
            let issued = JellyfinClient(server: session.server,
                identity: .init(deviceID: session.deviceID, deviceName: model.deviceName), session: session)
            try? await issued.logout()
            throw SignInError.differentAccount
        }
        try model.accept(session, serverName: connection?.name ?? "Jellyfin server", remember: remember)
        password = ""
        if isAdding { dismiss() }
    }

    private enum SignInError: LocalizedError {
        case differentAccount
        var errorDescription: String? {
            "That sign-in belongs to a different account. Sign in as the selected account, or use Add account to keep another viewer."
        }
    }

}

struct ServerFieldInput: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.textInputAutocapitalization(.never).autocorrectionDisabled()
            .font(Theme.font(17)).padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
        #else
        content.font(Theme.font(24)).padding(12)
        #endif
    }
}

/// One chooser shared by Home, Profile and the signed-out entry screen.
struct SavedServersView: View {
    private struct SignIn: Identifiable {
        let id = UUID()
        var server: ServerAddress?
        var serverName: String?
        var username = ""
        var viewerID: String?
    }
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var signIn: SignIn?
    @State private var choosingServer = false
    @State private var isManaging = false
    @State private var managing: SavedAccount?
    @State private var removing: SavedAccount?
    @State private var error: String?
    @State private var busyID: UUID?
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    @FocusState private var focusedAccount: UUID?
    @Namespace private var accountFocus

    private var preferredAccountID: UUID? {
        model.connections.accounts.first(where: { model.isCurrent($0) })?.id
            ?? model.connections.accounts.first?.id
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.signedIn {
                    HStack {
                        Spacer()
                        Button("Done") { cancel(); dismiss() }.buttonStyle(AccountUtilityButtonStyle())
                    }.padding(.horizontal, Theme.isTV ? Theme.gutter : 24).padding(.vertical, 16)
                    #if os(tvOS)
                    // Extend the header's focus region across its empty space so
                    // Up from the left-hand account list can reach Done at right.
                    .focusSection()
                    #endif
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.isTV ? 22 : 18) {
                        Text(isManaging ? "Manage accounts" : "Who’s watching?")
                            .font(Theme.font(Theme.isTV ? 42 : 30, weight: .bold, relativeTo: .largeTitle))
                            .accessibilityAddTraits(.isHeader)
                            .padding(.bottom, Theme.isTV ? 18 : 10)
                        if let error {
                            Text(error).foregroundStyle(.orange).accessibilityIdentifier("server-switch-error")
                        }
                        ForEach(model.connections.accounts) { account in accountRow(account) }
                        if model.connections.accounts.isEmpty {
                            Text("Add an account to get started.").foregroundStyle(Theme.muted)
                        }
                        if !model.connections.servers.isEmpty && !isManaging {
                            Button(action: addAccount) {
                                HStack(spacing: Theme.isTV ? 28 : 20) {
                                    Image(systemName: "plus")
                                        .font(.system(size: Theme.isTV ? 32 : 24, weight: .medium))
                                        .frame(width: Theme.isTV ? 96 : 72, height: Theme.isTV ? 72 : 56)
                                    Text("Add account").font(Theme.font(Theme.isTV ? 26 : 18, weight: .medium))
                                }
                            }.buttonStyle(AccountUtilityButtonStyle()).disabled(busyID != nil)
                                .accessibilityIdentifier("add-account")
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Theme.isTV ? 36 : 24) { accountActions }
                            VStack(alignment: .leading, spacing: 12) { accountActions }
                        }.padding(.top, Theme.isTV ? 22 : 10)
                        if busyID != nil { Button("Cancel") { cancel() }.buttonStyle(AccountUtilityButtonStyle()) }
                    }.frame(maxWidth: Theme.isTV ? 820 : 640, alignment: .leading)
                        .padding(Theme.isTV ? Theme.gutter : 24)
                        .frame(maxWidth: .infinity, alignment: Theme.isTV ? .leading : .center)
                }
            }
            #if os(tvOS)
            .focusScope(accountFocus)
            #endif
            .background(Theme.background).foregroundStyle(Theme.text).modifier(HideNavigationBar())
        }
        #if os(tvOS)
        .fullScreenCover(item: $signIn) { signInView($0) }
        #else
        .sheet(item: $signIn) { signInView($0) }
        #endif
        .confirmationDialog("Add account to a server", isPresented: $choosingServer, titleVisibility: .visible) {
            ForEach(model.connections.servers) { server in
                Button(server.name + " · " + server.address.url.absoluteString) {
                    signIn = SignIn(server: server.address, serverName: server.name)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(managing.map { "\($0.viewer.name) on \($0.serverName)" } ?? "Account",
            isPresented: Binding(get: { managing != nil }, set: { if !$0 { managing = nil } }),
            titleVisibility: .visible, presenting: managing) { account in
                Button("Sign in again") { reauthenticate(account) }
                Button("Remove from device", role: .destructive) { removing = account }
                Button("Cancel", role: .cancel) {}
        }
        .alert("Remove saved account?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing) { account in
                Button("Remove", role: .destructive) { remove(account) }
                Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("Remove \(account.viewer.name) from \(account.serverName) on this device? Their server account, library and other saved sign-ins stay unchanged.")
        }
        .onDisappear { cancel() }
        .onChange(of: model.connections.accounts.isEmpty) { _, empty in
            if empty { isManaging = false }
        }
    }

    @ViewBuilder private var accountActions: some View {
        Button { signIn = SignIn() } label: {
            Text("Add server")
        }.buttonStyle(AccountUtilityButtonStyle()).disabled(busyID != nil)
            .accessibilityIdentifier("add-server")
            #if os(tvOS)
            .prefersDefaultFocus(model.connections.accounts.isEmpty, in: accountFocus)
            #endif
        if !model.connections.accounts.isEmpty {
            Button(isManaging ? "Finish editing" : "Manage accounts") {
                isManaging.toggle(); error = nil
            }.buttonStyle(AccountUtilityButtonStyle()).disabled(busyID != nil)
                .accessibilityIdentifier("manage-accounts")
        }
    }
    private func addAccount() {
        if let server = model.connections.servers.first, model.connections.servers.count == 1 {
            signIn = SignIn(server: server.address, serverName: server.name)
        } else { choosingServer = true }
    }
    private func signInView(_ target: SignIn) -> some View {
        ConnectView(server: target.server, serverName: target.serverName, username: target.username,
                    expectedViewerID: target.viewerID, isAdding: true)
    }
    private func accountRow(_ account: SavedAccount) -> some View {
        Button {
            if isManaging { managing = account } else { choose(account) }
        } label: {
            AccountChoiceLabel(account: account, current: model.isCurrent(account),
                busy: busyID == account.id, editing: isManaging, focused: focusedAccount == account.id)
        }.buttonStyle(AccountSelectionButtonStyle()).disabled(busyID != nil)
            .focused($focusedAccount, equals: account.id)
            #if os(tvOS)
            .prefersDefaultFocus(account.id == preferredAccountID, in: accountFocus)
            #endif
            .accessibilityIdentifier("saved-account-\(account.id)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(isManaging ? "Manage " : "")\(account.viewer.name), \(account.server.url.absoluteString)")
            .accessibilityValue(busyID == account.id ? "Connecting" : model.isCurrent(account) ? "Current account" : account.session == nil ? "Sign in again" : "")
            .accessibilityHint(isManaging ? "Opens account options." : "Opens this account’s library.")
    }

    private func reauthenticate(_ account: SavedAccount) {
        error = nil
        signIn = SignIn(server: account.server, serverName: account.serverName, username: account.viewer.name, viewerID: account.viewer.id)
    }
    private func choose(_ account: SavedAccount) {
        if model.isCurrent(account) { dismiss(); return }
        if account.session == nil { reauthenticate(account); return }
        cancel(); error = nil; busyID = account.id
        let id = operationID
        operation = Task { @MainActor in
            defer { if operationID == id { busyID = nil; operation = nil } }
            do {
                try await model.switchAccount(account.id)
                dismiss()
            } catch is CancellationError { }
            catch ClientError.unauthorized {
                error = "\(account.viewer.name) needs to sign in again on \(account.serverName)."
                reauthenticate(account)
            } catch {
                if !Task.isCancelled { self.error = "\(account.serverName): \(error.localizedDescription)" }
            }
        }
    }
    private func remove(_ account: SavedAccount) {
        cancel(); error = nil; busyID = account.id
        let id = operationID
        operation = Task { @MainActor in
            defer { if operationID == id { busyID = nil; operation = nil } }
            do { try await model.removeAccount(account.id) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func cancel() { operationID = UUID(); operation?.cancel(); operation = nil; busyID = nil }
}

/// A profile is one focus target. Only its avatar receives a focus ring; the
/// name and server stay on the page without a surrounding card or row menu.
private struct AccountChoiceLabel: View {
    let account: SavedAccount
    let current: Bool
    let busy: Bool
    let editing: Bool
    let focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeReduceMotion) private var appReduceMotion
    private var avatarSize: CGFloat { Theme.isTV ? 96 : 72 }

    var body: some View {
        HStack(spacing: Theme.isTV ? 28 : 20) {
            SavedAccountAvatar(account: account, size: avatarSize)
                .overlay {
                    RoundedRectangle(cornerRadius: avatarSize * 0.22 + 5)
                        .stroke(focused ? Theme.text : .clear, lineWidth: 3).padding(-5)
                }
                .overlay {
                    if busy {
                        RoundedRectangle(cornerRadius: avatarSize * 0.22).fill(Theme.background.opacity(0.7))
                        ProgressView().tint(Theme.text)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !busy && (editing || current) {
                        Image(systemName: editing ? "pencil" : "checkmark")
                            .font(.system(size: Theme.isTV ? 17 : 12, weight: .bold))
                            .foregroundStyle(Theme.background)
                            .frame(width: Theme.isTV ? 32 : 24, height: Theme.isTV ? 32 : 24)
                            .background(Theme.jade, in: Circle()).offset(x: 4, y: 4)
                    }
                }
                .scaleEffect(!reduceMotion && !appReduceMotion && focused ? 1.04 : 1)
                .animation(reduceMotion || appReduceMotion ? nil : NavigationMotion.focus, value: focused)
            VStack(alignment: .leading, spacing: Theme.isTV ? 8 : 6) {
                Text(account.viewer.name)
                    .font(Theme.font(Theme.isTV ? 30 : 22, weight: .semibold))
                    .foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                Text(account.server.url.absoluteString)
                    .font(Theme.font(Theme.isTV ? 19 : 13)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if account.session == nil {
                    Text("Sign in again").font(Theme.font(Theme.isTV ? 18 : 13)).foregroundStyle(Theme.jade)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 10).padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: Theme.target, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct AccountSelectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// Secondary actions remain quiet until focused, with full-size hit targets.
private struct AccountUtilityButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(Theme.isTV ? 22 : 16, weight: .medium))
            .foregroundStyle(focused ? Theme.text : Theme.muted)
            .padding(.horizontal, 4).frame(minWidth: Theme.target, minHeight: Theme.target)
            .overlay(alignment: .bottom) {
                Rectangle().fill(focused ? Theme.jade : .clear).frame(height: 3)
            }
            .contentShape(Rectangle()).opacity(configuration.isPressed ? 0.65 : 1)
    }
}
