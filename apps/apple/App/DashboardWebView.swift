import SwiftUI
import ZorofinCore
#if os(iOS)
import WebKit
#endif

#if os(iOS)
/// Administration remains the server's full web UI, presented without Safari,
/// shared cookies, persistent web credentials or access to native app bridges.
struct DashboardWebView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var access: AdminWebSession?
    @State private var browser = AdministrationBrowserState()
    @State private var preparing = false
    @State private var preparationError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let access {
                    AdministrationBrowser(access: access, state: browser)
                        .overlay {
                            if let error = browser.error { failure(error, retry: { browser.reload() }) }
                            else if browser.loading { ProgressView().padding(18).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12)).accessibilityLabel("Loading dashboard") }
                        }
                        .safeAreaInset(edge: .top, spacing: 0) {
                            if access.requiresSignIn {
                                Text("Sign in as \(access.viewer.name) on your server to continue.")
                                    .font(.footnote).foregroundStyle(Theme.muted).padding(12).frame(maxWidth: .infinity).background(Theme.background)
                            }
                            if browser.blockedLink {
                                HStack {
                                    Text("That link leaves your server. It wasn’t opened.").font(.footnote)
                                    Spacer()
                                    Button("Dismiss") { browser.blockedLink = false }
                                }.padding(12).background(Theme.panel)
                            }
                        }
                } else if let preparationError { failure(preparationError, retry: { Task { await prepare() } }) }
                else { ProgressView("Opening dashboard…") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
            .navigationTitle("Dashboard").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if access != nil {
                        Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                            .disabled(!browser.canGoBack).accessibilityLabel("Back in dashboard")
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("administration-done") }
            }
        }.tint(Theme.jade).preferredColorScheme(.dark)
        .task { await prepare() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, access != nil else { return }
            let generation = model.generation
            Task {
                guard let client = model.client else { return }
                let viewer = try? await client.currentViewer()
                guard !Task.isCancelled, generation == model.generation, access != nil else { return }
                guard viewer?.id == model.session?.viewer.id, viewer?.policy?.isAdministrator == true else { dismiss(); return }
            }
        }
        .onDisappear {
            browser.stop()
            let lease = access; access = nil
            Task { await lease?.close() }
        }
        .alert("Server message", isPresented: Binding(get: { browser.dialog != nil }, set: { if !$0 { browser.resolveDialog(nil) } }), presenting: browser.dialog) { dialog in
            if dialog.kind == .prompt { TextField("Response", text: $browser.promptText) }
            if dialog.kind != .alert { Button("Cancel", role: .cancel) { browser.resolveDialog(nil) } }
            Button(dialog.kind == .alert ? "OK" : "Continue") { browser.resolveDialog(browser.promptText) }
        } message: { dialog in Text(dialog.message) }
    }

    private func failure(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 20) {
            Text(message).multilineTextAlignment(.center).foregroundStyle(Theme.muted)
            Button("Try again", action: retry).buttonStyle(ZoroButtonStyle(primary: true))
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
    }
    @MainActor private func prepare() async {
        guard !Task.isCancelled, !preparing, access == nil else { return }
        preparing = true; preparationError = nil
        guard let client = model.client else { preparing = false; preparationError = "Sign in to your server to open administration."; return }
        let generation = model.generation
        do {
            let lease = try await client.adminWebSession()
            guard !Task.isCancelled, generation == model.generation else { await Task { await lease.close() }.value; return }
            access = lease
        } catch {
            guard !Task.isCancelled, generation == model.generation else { return }
            preparationError = error as? ClientError == .forbidden ? "Your account no longer has administrator access." : "Couldn’t open administration. Check your connection and try again."
        }
        preparing = false
    }
}

@MainActor @Observable private final class AdministrationBrowserState {
    enum DialogKind { case alert, confirm, prompt }
    struct Dialog { let kind: DialogKind; let message: String }
    var loading = true
    var canGoBack = false
    var error: String?
    var blockedLink = false
    var dialog: Dialog?
    var promptText = ""
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var dialogReply: (@MainActor (String?) -> Void)?
    func resolveDialog(_ value: String?) { let reply = dialogReply; dialogReply = nil; dialog = nil; reply?(value) }
    func goBack() { if webView?.canGoBack == true { webView?.goBack() } }
    func reload() { error = nil; webView?.reload() }
    func stop() { resolveDialog(nil); webView?.stopLoading(); webView?.configuration.userContentController.removeAllUserScripts() }
}

private struct AdministrationBrowser: UIViewRepresentable {
    let access: AdminWebSession
    let state: AdministrationBrowserState
    func makeCoordinator() -> Coordinator { Coordinator(access: access, state: state) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        do {
            if let script = try access.bootstrapScript() {
                config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
            let view = WKWebView(frame: .zero, configuration: config)
            view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
            view.allowsBackForwardNavigationGestures = true
            view.isOpaque = false; view.backgroundColor = UIColor(Theme.background)
            state.webView = view
            context.coordinator.history = view.observe(\.canGoBack, options: [.new]) { [weak state] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in state?.canGoBack = value }
            }
            view.load(URLRequest(url: try access.server.dashboardWebURL()))
            return view
        } catch {
            state.error = "Couldn’t open this server’s dashboard."
            return WKWebView(frame: .zero, configuration: config)
        }
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.state.stop(); coordinator.history?.invalidate()
        view.navigationDelegate = nil; view.uiDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let access: AdminWebSession
        let state: AdministrationBrowserState
        var history: NSKeyValueObservation?
        init(access: AdminWebSession, state: AdministrationBrowserState) { self.access = access; self.state = state }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, access.permitsNavigation(to: url) else {
                if navigationAction.targetFrame?.isMainFrame != false { state.blockedLink = true }
                decisionHandler(.cancel); return
            }
            if navigationAction.targetFrame == nil {
                decisionHandler(.cancel); webView.load(navigationAction.request); return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { state.loading = true; state.error = nil }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { state.loading = false; state.canGoBack = webView.canGoBack }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
        private func failed(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            state.loading = false; state.error = "Couldn’t load the dashboard. Check your connection and try again."
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { state.loading = false; state.error = "The dashboard stopped responding. Try loading it again." }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
            guard frame.isMainFrame, frame.request.url.map(access.permitsNavigation) == true else { completionHandler(); return }
            state.resolveDialog(nil); state.dialogReply = { _ in completionHandler() }; state.dialog = .init(kind: .alert, message: message)
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
            guard frame.isMainFrame, frame.request.url.map(access.permitsNavigation) == true else { completionHandler(false); return }
            state.resolveDialog(nil); state.promptText = ""; state.dialogReply = { completionHandler($0 != nil) }; state.dialog = .init(kind: .confirm, message: message)
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
            guard frame.isMainFrame, frame.request.url.map(access.permitsNavigation) == true else { completionHandler(nil); return }
            state.resolveDialog(nil); state.promptText = defaultText ?? ""; state.dialogReply = completionHandler; state.dialog = .init(kind: .prompt, message: prompt)
        }
    }
}
#endif
