import SwiftUI

/// Settings → Sync → Notifications: a master switch, one per kind, and muted groups. When the
/// system has them off for Clipboard2, says so with a way to System Settings (never a dialog).
struct NotificationsSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var prefs = env.prefs
        let hub = env.notifications
        Section {
            if hub.permission == .denied {
                HStack {
                    Label("Notifications are off in System Settings", systemImage: "bell.slash")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open System Settings…") { NotificationHub.openSystemSettings() }
                }
            }
            Toggle("Show notifications", isOn: $prefs.notificationsEnabled)
            ForEach(NotificationKind.allCases) { kind in
                Toggle(isOn: Binding(get: { prefs.notifies(kind) }, set: { prefs.setNotifies(kind, $0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.title)
                        Text(kind.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!prefs.notificationsEnabled)
                .padding(.leading, 12)
            }
            if !env.sync.groups.isEmpty {
                ForEach(env.sync.groups) { group in
                    Toggle(isOn: Binding(get: { prefs.isMuted(group: group.id) }, set: { prefs.setMuted($0, group: group.id) })) {
                        Label("Mute \(group.name)", systemImage: "person.2.fill")
                    }
                    .disabled(!prefs.notificationsEnabled)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Arrive within about a minute, respect Focus, and never show the content of secrets. Nothing you do yourself is announced, on any of your devices. With notifications off, what contacts send still shows briefly on screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await hub.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await hub.refreshPermission() }
        }
    }
}

/// "Mute Notifications" / "Unmute Notifications" for a group's right-click menu.
struct GroupMuteButton: View {
    let groupID: String
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let muted = env.prefs.isMuted(group: groupID)
        Button(muted ? "Unmute Notifications" : "Mute Notifications") {
            env.prefs.setMuted(!muted, group: groupID)
        }
    }
}
