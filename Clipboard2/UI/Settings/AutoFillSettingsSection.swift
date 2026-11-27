import SwiftUI
import AppKit

/// Settings → Auth: whether Clipboard2 is turned on as a system AutoFill provider
/// (docs/features/auth-autofill.md → Phase 3). One line, no dialogs.
struct AutoFillSettingsSection: View {
    #if AUTOFILL
    @State private var enabled: Bool?

    var body: some View {
        Section {
            HStack {
                Text(enabled == true ? "Clipboard2 AutoFill is on" : "Clipboard2 AutoFill is off")
                    .foregroundStyle(enabled == nil ? .secondary : .primary)
                Spacer()
                if enabled == false {
                    Button("Open AutoFill Settings") { AutoFillIdentities.openSettings() }
                }
            }
        } header: {
            Text("System AutoFill")
        } footer: {
            Text("Offers your passwords and codes in Safari, Chrome and apps. Filling asks for Touch ID unless Auth is unlocked.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        enabled = await AutoFillIdentities.isEnabled()
        AutoFillIdentities.checkEnabled()
    }
    #else
    var body: some View {
        Section {
            Text("System AutoFill needs the next update.")
                .foregroundStyle(.secondary)
        }
    }
    #endif
}
