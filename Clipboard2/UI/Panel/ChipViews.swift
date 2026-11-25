import SwiftUI

/// In Copies' search field: the target app's icon, filtering to "Only from ‹App›" while on.
struct OnlyFromAppToggle: View {
    let app: AppRef
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(nsImage: AppIconCache.icon(for: app.bundleID))
                .resizable()
                .frame(width: 16, height: 16)
                .saturation(isOn ? 1 : 0)
                .opacity(isOn ? 1 : 0.6)
                .padding(4)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? Color.accentColor.opacity(0.18) : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Showing only copies from \(app.name)" : "Only from \(app.name)")
        .accessibilityLabel("Only from \(app.name)")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// Groups without a group: join or create one.
struct NoGroupsView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Groups Yet", systemImage: "person.2")
        } description: {
            Text("Create a group or join one with an invite code in Settings → Sync.")
        } actions: {
            Button("Open Settings") { SettingsOpener.open() }
        }
    }
}
