
import Foundation
import Testing
@testable import ZorofinCore
#if os(macOS)
import AppKit
import WebKit
#endif

/// Opt-in HTTP check using a separately configured lab, never a bundled server.
@Suite("Embedded admin runtime") struct AdminWebRuntimeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZOROFIN_ADMIN_LAB_SERVER"] != nil))
    func temporaryWebTokenDoesNotRevokeNativeLogin() async throws {
        let env = ProcessInfo.processInfo.environment
        let address = try #require(env["ZOROFIN_ADMIN_LAB_SERVER"])
        let file = try #require(env["ZOROFIN_ADMIN_LAB_CREDENTIALS"])
        struct Account: Decodable { let username: String; let password: String }
        struct Accounts: Decodable { let admin: Account; let server_id: String }
        let accounts = try JSONDecoder().decode(Accounts.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        let credentials = accounts.admin
        let server = try ServerAddress(address)
        let identity = ClientIdentity(deviceID: "admin-lab-" + UUID().uuidString, deviceName: "Zorofin admin lab")
        let anonymous = JellyfinClient(server: server, identity: identity)
        let info = try await anonymous.systemInfo()
        guard info.id == accounts.server_id else { throw ClientError.unsafeURL }
        print("Embedded admin HTTP runtime: Jellyfin \(info.version ?? "unknown")")
        let session = try await anonymous.login(username: credentials.username, password: credentials.password)
        let native = JellyfinClient(server: server, identity: identity, session: session)
        var lease: AdminWebSession?
        do {
            let access = try await native.adminWebSession(); lease = access
            #expect(!access.requiresSignIn)
            let web = try #require(access.browserClient)
            let separateToken = web.session?.token != session.token
            #expect(separateToken)
            let webViewer = try await web.currentViewer()
            #expect(webViewer.id == session.viewer.id)
            #expect(webViewer.policy?.isAdministrator == true)
            #if os(macOS)
            if env["ZOROFIN_ADMIN_LAB_WEBKIT"] == "1" {
                let rendered = try await AdminWebProbe.opensDashboard(access)
                #expect(rendered)
            }
            #endif
            await access.close(); lease = nil
            await #expect(throws: ClientError.unauthorized) { try await web.currentViewer() }
            let stillSignedIn = try await native.currentViewer()
            #expect(stillSignedIn.id == session.viewer.id)
            try await native.logout()
        } catch {
            await lease?.close(); try? await native.logout(); throw error
        }
    }
}


#if os(macOS)
@MainActor private enum AdminWebProbe {
    /// Host WebKit smoke check, not iPhone/simulator acceptance. No server actions
    /// are clicked: only the dashboard's rendered admin navigation is inspected.
    static func opensDashboard(_ access: AdminWebSession) async throws -> Bool {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        if let script = try access.bootstrapScript() {
            config.userContentController.addUserScript(.init(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let networkProbe = """
        window.__adminLabNetwork = [];
        const record = (url, status) => { try { window.__adminLabNetwork.push({path:new URL(url,location.href).pathname,status:status}); } catch {} };
        const originalFetch = window.fetch.bind(window);
        window.fetch = (...args) => originalFetch(...args).then(r => {record(typeof args[0] === 'string' ? args[0] : args[0].url, r.status);return r;}).catch(e=>{record(typeof args[0] === 'string' ? args[0] : args[0].url, 'network-error');throw e;});
        const originalOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method,url,...args) {this.addEventListener('loadend',()=>record(url,this.status));return originalOpen.call(this,method,url,...args);};
        """
        config.userContentController.addUserScript(.init(source: networkProbe, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 430, height: 900), configuration: config)
        defer { view.stopLoading(); config.userContentController.removeAllUserScripts() }
        view.load(URLRequest(url: try access.server.dashboardWebURL()))
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(300))
            let ready: Bool = await withCheckedContinuation { continuation in
                view.evaluateJavaScript("document.title === 'Dashboard' && document.body && document.body.innerText.includes('Server version') && document.body.innerText.includes('Devices') && !document.querySelector('input[type=password]')") { value, _ in
                    continuation.resume(returning: value as? Bool == true)
                }
            }
            if ready { print("Host WebKit: authenticated dashboard navigation rendered"); return true }
        }
        let diagnostic: String = await withCheckedContinuation { continuation in
            view.evaluateJavaScript("JSON.stringify({title:document.title,path:location.pathname,route:location.hash,initialized:sessionStorage.getItem('zorofin-admin-initialized'),unavailable:(document.body?.innerText||'').includes('Server Unavailable'),passwordFields:document.querySelectorAll('input[type=password]').length,network:window.__adminLabNetwork.map(r=>({path:r.path.replace(/[a-f0-9]{32}/gi,'[id]'),status:r.status}))})") { value, _ in
                continuation.resume(returning: value as? String ?? "no DOM")
            }
        }
        print("Host WebKit diagnostic: " + diagnostic)
        print("Host WebKit: dashboard navigation did not become ready before the deadline")
        return false
    }
}
#endif
