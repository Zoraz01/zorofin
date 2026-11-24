import SwiftUI
import ZorofinCore

#if os(iOS)
struct AccountApprovalsView: View {
    @Environment(AppModel.self) private var model
    @State private var requests: [AccountRequest] = []
    @State private var loaded = false
    @State private var reviewed = false
    @State private var busy = false
    @State private var error: String?
    @State private var status: String?
    @State private var denying: AccountRequest?

    var body: some View {
        AccountApprovalsContent(requests: requests, loaded: loaded, reviewed: $reviewed,
            busy: busy, error: error, status: status,
            approve: { decide($0, approve: true) }, deny: { denying = $0 })
            .refreshable { await load() }
            .task(id: model.generation) { await load() }
            .confirmationDialog("Deny this account request?", isPresented: Binding(
                get: { denying != nil }, set: { if !$0 { denying = nil } }),
                titleVisibility: .visible, presenting: denying) { request in
                Button("Deny request", role: .destructive) { decide(request, approve: false) }
                Button("Cancel", role: .cancel) {}
            }
    }

    @MainActor private func load() async {
        guard let client = model.client else { return }
        let generation = model.generation
        do {
            let result = try await client.accountRequests()
            guard !Task.isCancelled, generation == model.generation else { return }
            requests = result; error = nil
        } catch {
            guard !Task.isCancelled, generation == model.generation else { return }
            self.error = message(error)
        }
        loaded = true
    }

    private func decide(_ request: AccountRequest, approve: Bool) {
        guard let client = model.client, !busy else { return }
        busy = true; error = nil; status = nil
        let generation = model.generation
        Task {
            defer { busy = false }
            do {
                try await client.decideAccountRequest(request.id, approve: approve)
                guard !Task.isCancelled, generation == model.generation else { return }
                status = approve ? "\(request.username) approved." : "Request denied."
                await load()
            } catch {
                guard !Task.isCancelled, generation == model.generation else { return }
                // A successful list reload must not erase a failed decision message.
                self.error = message(error)
            }
        }
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Check your connection and try again."
    }
}

/// The same presentation is used for live data and isolated layout previews.
private struct AccountApprovalsContent: View {
    let requests: [AccountRequest]
    let loaded: Bool
    @Binding var reviewed: Bool
    let busy: Bool
    let error: String?
    let status: String?
    let approve: (AccountRequest) -> Void
    let deny: (AccountRequest) -> Void
    private var shown: [AccountRequest] { requests.filter { $0.isPending != reviewed } }

    var body: some View {
        List {
            Section {
                Picker("Show requests", selection: $reviewed) {
                    Text("Waiting").tag(false)
                    Text("Reviewed").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("approvals-filter")
            }.listRowBackground(Color.clear)

            if let error, !error.isEmpty {
                Section {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("administration-error")
                }.listRowBackground(Theme.panel)
            }
            if let status {
                Section {
                    Text(status).foregroundStyle(Theme.jade).fixedSize(horizontal: false, vertical: true)
                }.listRowBackground(Theme.panel)
            }
            if !loaded && error == nil {
                Section { ProgressView("Loading requests…").padding(.vertical, 12) }
                    .listRowBackground(Theme.panel)
            } else if loaded && shown.isEmpty && error == nil {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reviewed ? "No reviewed requests" : "All caught up")
                            .font(.headline).foregroundStyle(Theme.text)
                        Text(reviewed ? "Approved and denied requests will appear here." : "New account requests will appear here for review.")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                    }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
                }.listRowBackground(Theme.panel)
            }
            Section {
                ForEach(shown) { request in
                    AccountApprovalRow(request: request, busy: busy,
                        approve: { approve(request) }, deny: { deny(request) })
                        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                        .listRowBackground(Theme.panel)
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden)
        .background(Theme.background).foregroundStyle(Theme.text)
        .navigationTitle("Account approvals").navigationBarTitleDisplayMode(.inline)
    }
}

private struct AccountApprovalRow: View {
    let request: AccountRequest
    let busy: Bool
    let approve: () -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(request.username).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("approval-username")
                if let date = request.createdAt {
                    Text("Requested \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if request.status == "pending" {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { decisionButtons(expand: false) }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 10) { decisionButtons(expand: true) }
                }
                .disabled(busy)
            } else {
                Text(request.statusTitle).font(.subheadline.weight(.medium))
                    .foregroundStyle(request.status == "denied" || request.status == "failed" ? Color.orange : Theme.jade)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func decisionButtons(expand: Bool) -> some View {
        Button(action: deny) {
            Text("Deny").fixedSize().frame(maxWidth: expand ? .infinity : nil)
        }
        .buttonStyle(ZoroButtonStyle()).accessibilityLabel("Deny \(request.username)")
        Button(action: approve) {
            Text("Approve").fixedSize().frame(maxWidth: expand ? .infinity : nil)
        }
        .buttonStyle(ZoroButtonStyle(primary: true)).accessibilityLabel("Approve \(request.username)")
    }
}

#if DEBUG
/// Fictional data only; no AppModel, server reads or decision calls are used.
struct AccountApprovalsLayoutPreview: View {
    @State private var reviewed = ProcessInfo.processInfo.arguments.contains("--approvals-reviewed")
    private var mode: String {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--approvals-error") { return "error" }
        if arguments.contains("--approvals-loading") { return "loading" }
        if arguments.contains("--approvals-empty") { return "empty" }
        return "requests"
    }
    private var requests: [AccountRequest] {
        let fixture = #"[{"id":"sample1","username":"avery_with_a_very_long_account_name","status":"pending","created_at":1762196400000},{"id":"sample2","username":"morgan","status":"provisioning","created_at":1762189200000},{"id":"sample3","username":"riley_with_another_long_account_name","status":"approved","created_at":1762102800000},{"id":"sample4","username":"sam","status":"failed","created_at":1762102800000}]"#
        return (try? JSONDecoder().decode([AccountRequest].self, from: Data(fixture.utf8))) ?? []
    }
    var body: some View {
        NavigationStack {
            AccountApprovalsContent(requests: mode == "requests" ? requests : [],
                loaded: mode != "loading", reviewed: $reviewed, busy: false,
                error: mode == "error" ? "Requests couldn’t load. Check your connection and pull to refresh." : nil,
                status: nil, approve: { _ in }, deny: { _ in })
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") {} } }
        }
        .tint(Theme.jade).preferredColorScheme(.dark)
        .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--approvals-large-text") ? .accessibility3 : .large)
    }
}
#endif
#endif
