import SwiftUI
import KeyboardShortcuts

/// First launch: the welcome, then the permissions, in one window.
struct FirstRunView: View {
    let startWithWelcome: Bool
    let dismiss: () -> Void
    @State private var showsPermissions = false

    var body: some View {
        Group {
            if startWithWelcome && !showsPermissions {
                WelcomeView { withAnimation(.snappy) { showsPermissions = true } }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                PermissionsView(dismiss: dismiss)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
}

/// Three shortcuts are all anyone needs to start; everything else can be found later.
struct WelcomeView: View {
    let onContinue: () -> Void
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var prefs = env.prefs
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(spacing: 5) {
                Text("Welcome to Clipboard2")
                    .font(.title.weight(.bold))
                Text("Everything you copy, one key away. These three are all you need.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(alignment: .top, spacing: 10) {
                card(keys: keys(for: .toggleQuickPanel), title: "Open your clipboard",
                     detail: "Search, preview and paste anything you copied.")
                card(keys: keys(for: .selectionActions), title: "Fix or translate text",
                     detail: "Select text in any app first, then press it.")
                card(keys: prefs.contextMenuEnabled ? [prefs.contextMenuModifier.symbol, "right-click"] : [],
                     title: "Everything in one menu", detail: "Recent items, snippets and secrets, in every app.")
            }

            HStack {
                Text("Next: what Clipboard2 needs from macOS to paste for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    /// The shortcut as separate key caps (⇧ ⌘ V), or none when it isn't set.
    private func keys(for name: KeyboardShortcuts.Name) -> [String] {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return [] }
        let text = "\(shortcut)"
        let modifiers = text.prefix { "⌃⌥⇧⌘".contains($0) }
        return modifiers.map(String.init) + [String(text.dropFirst(modifiers.count))]
    }

    private func card(keys: [String], title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                if keys.isEmpty {
                    Text("Not set").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 26, minHeight: 26)
                        .padding(.horizontal, key.count > 1 ? 6 : 0)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.quaternary))
                        .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(keys.isEmpty ? "No shortcut set" : keys.joined(separator: " "))
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
