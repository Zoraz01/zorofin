import SwiftUI
import ZorofinCore

/// A normal Profile destination. No group controls are added over browsing/video.
struct WatchTogetherView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var creating = false
    @State private var groupName = "Movie night"
    @State private var confirmingLeave = false

    private var groupState: WatchTogetherModel { model.watchTogether }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Button(action: goBack) {
                    Label(creating ? "Watch together" : "Profile", systemImage: "chevron.left")
                        .font(Theme.font(Theme.isTV ? 22 : 15)).frame(minHeight: Theme.target)
                }.buttonStyle(ZoroButtonStyle()).foregroundStyle(Theme.muted)
                Text(creating ? "Start a group" : "Watch together")
                    .font(Theme.font(Theme.isTV ? 42 : 28, weight: .bold, relativeTo: .title)).accessibilityAddTraits(.isHeader)

                if model.isDemo {
                    Text("Connect to your Jellyfin server to create or join a group.")
                        .font(Theme.font(Theme.isTV ? 24 : 16)).foregroundStyle(Theme.muted)
                } else if let group = groupState.group {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your group").font(Theme.font(Theme.isTV ? 20 : 13)).foregroundStyle(Theme.muted)
                        Text(group.groupName).font(Theme.font(Theme.isTV ? 30 : 20, weight: .semibold))
                        if let item = groupState.currentItem {
                            Text(item.displayTitle).font(Theme.font(Theme.isTV ? 22 : 15)).foregroundStyle(Theme.muted)
                        } else {
                            Text("Choose something to watch").font(Theme.font(Theme.isTV ? 22 : 15)).foregroundStyle(Theme.muted)
                        }
                        if group.state == "Waiting" { Text("Waiting for others…").font(Theme.font(Theme.isTV ? 22 : 14)).foregroundStyle(Theme.jade) }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
                    Text("Participants").font(Theme.font(Theme.isTV ? 26 : 17, weight: .semibold))
                    LazyVStack(spacing: 0) {
                        ForEach(Array(group.participants.enumerated()), id: \.offset) { _, name in
                            HStack(spacing: 12) {
                                Avatar(initial: String(name.prefix(1)).uppercased(), size: Theme.isTV ? 48 : 32)
                                Text(name).font(Theme.font(Theme.isTV ? 24 : 16))
                                Spacer()
                            }.frame(minHeight: Theme.isTV ? 72 : 53).padding(.vertical, 4)
                            Divider().overlay(Theme.border)
                        }
                    }
                    if confirmingLeave {
                        Text("Leave this group?").font(Theme.font(Theme.isTV ? 26 : 17, weight: .semibold))
                        Button("Leave group") { Task { await groupState.leave(); confirmingLeave = false; await groupState.refresh() } }
                            .buttonStyle(ZoroButtonStyle()).disabled(groupState.busy)
                        Button("Stay in group") { confirmingLeave = false }.buttonStyle(ZoroButtonStyle())
                    } else {
                        if groupState.currentItem != nil {
                            Button("Continue watching", systemImage: "play.fill") { Task { await groupState.continueWatching() } }
                                .buttonStyle(ZoroButtonStyle(primary: true)).disabled(groupState.busy)
                        } else {
                            Button("Browse library", systemImage: "rectangle.stack") { groupState.browseRequested = true }
                                .buttonStyle(ZoroButtonStyle(primary: true))
                        }
                        Button("Leave group") { confirmingLeave = true }.buttonStyle(ZoroButtonStyle()).disabled(groupState.busy)
                    }
                } else if creating {
                    Text("Create a group, then choose something from your library.")
                        .font(Theme.font(Theme.isTV ? 24 : 16)).foregroundStyle(Theme.muted)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Group name").font(Theme.font(Theme.isTV ? 22 : 14)).foregroundStyle(Theme.muted)
                        TextField("Movie night", text: $groupName).textFieldStyle(.plain)
                            .font(Theme.font(Theme.isTV ? 26 : 17)).padding(14).frame(minHeight: Theme.target)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Group name").disabled(groupState.busy)
                            .onSubmit { create() }
                    }
                    Button("Create group", action: create).buttonStyle(ZoroButtonStyle(primary: true))
                        .disabled(groupState.busy || groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if groupState.canJoin {
                    Text("Join a group or start your own.").font(Theme.font(Theme.isTV ? 24 : 16)).foregroundStyle(Theme.muted)
                    Text("Available groups").font(Theme.font(Theme.isTV ? 26 : 17, weight: .semibold))
                    if groupState.groups.isEmpty {
                        Text("No groups right now").font(Theme.font(Theme.isTV ? 24 : 16)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, minHeight: 100)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(groupState.groups) { group in
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(group.groupName).font(Theme.font(Theme.isTV ? 28 : 18, weight: .semibold))
                                    Text("\(group.participants.count) \(group.participants.count == 1 ? "person" : "people")")
                                        .font(Theme.font(Theme.isTV ? 22 : 14)).foregroundStyle(Theme.muted)
                                    Button("Join") { Task { await groupState.join(group) } }
                                        .buttonStyle(ZoroButtonStyle()).disabled(groupState.busy)
                                        .accessibilityLabel("Join \(group.groupName)")
                                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                    }
                    if groupState.canCreate {
                        Button("Start a group", systemImage: "plus") { creating = true }
                            .buttonStyle(ZoroButtonStyle(primary: true)).disabled(groupState.busy)
                    }
                } else {
                    Text("Your server has not enabled group watching for this account.")
                        .font(Theme.font(Theme.isTV ? 24 : 16)).foregroundStyle(Theme.muted)
                }
                if groupState.busy { ProgressView().frame(maxWidth: .infinity).accessibilityLabel("Updating group") }
                if let error = groupState.error {
                    Text(error).font(Theme.font(Theme.isTV ? 22 : 15)).foregroundStyle(Theme.muted).accessibilityAddTraits(.updatesFrequently)
                    Button("Refresh groups") { Task { await groupState.refresh() } }
                        .buttonStyle(ZoroButtonStyle()).disabled(groupState.busy)
                }
            }
                #if os(tvOS)
                .focusSection()
                #endif
                .frame(maxWidth: Theme.isTV ? 1000 : 720, alignment: .leading).frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.isTV ? 64 : 28).padding(.top, Theme.isTV ? 36 : 12).padding(.bottom, 32)
        }.foregroundStyle(Theme.text).background(Theme.background)
            .modifier(HideNavigationBar())
            #if os(tvOS)
            .onExitCommand(perform: goBack)
            .onChange(of: groupState.browseRequested) { _, requested in if requested { dismiss() } }
            .onChange(of: groupState.playbackRequest?.id) { _, request in if request != nil { dismiss() } }
            #endif
            .task(id: "\(model.generation)-\(scenePhase == .active)") {
                guard !model.isDemo, scenePhase == .active else { return }
                while !Task.isCancelled {
                    await groupState.refresh()
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                }
            }
            .onChange(of: groupState.group?.id) { _, _ in creating = false; confirmingLeave = false }
    }
    private func goBack() {
        if confirmingLeave { confirmingLeave = false }
        else if creating { creating = false }
        else { dismiss() }
    }
    private func create() { Task { await groupState.create(name: groupName) } }
}
