import SwiftUI

// Auth's sources and passwords (docs/features/auth-autofill.md, phase 1).

/// A source above its items: the site's favicon (or its first letter) and its name.
struct AuthSourceHeader: View {
    let heading: AuthSourceHeading
    var isFirst = false

    var body: some View {
        HStack(spacing: 7) {
            SourceIcon(source: heading.source, size: 16)
            Text(heading.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(heading.source == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, isFirst ? 4 : 12)
        .padding(.bottom, 3)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The cached favicon of a source, else a badge with its first letter. Never waits for the network.
struct SourceIcon: View {
    let source: AuthSource?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let domain = source?.domain, let image = FaviconCache.shared.image(for: domain) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if let source {
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(Self.color(for: source.key).gradient)
                    .overlay {
                        Text(source.name.first.map { String($0).uppercased() } ?? "?")
                            .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// A stable colour per source.
    static func color(for key: String) -> Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .teal, .green, .mint, .cyan, .brown]
        let hash = key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

/// A password: its username, masked password, sites and notes, each with its own Copy.
/// Showing or copying the password (and showing notes) asks for Touch ID, like secrets.
struct PasswordPreview: View {
    let ref: SecretRef
    var onEdit: (() -> Void)?
    /// Copying a field counts as using its source.
    var onUse: () -> Void = {}
    /// Fill (phase 2); true: and remember the page's site for this password.
    var onFill: ((Bool) -> Void)?
    /// The page's site, when this password isn't for it yet ("Remember for ‹site›").
    var rememberSite: String?
    @Environment(AppEnvironment.self) private var env
    @State private var revealed: String?
    @State private var notes: String?
    @State private var copied: String?

    private var source: AuthSource? { AuthSource.of(ref) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SourceIcon(source: source, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ref.name).font(.title3.weight(.semibold)).lineLimit(2)
                    if let source { Text(source.name).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                if let username = ref.username {
                    field("Username", username) { copyPlain(username) }
                }
                GridRow {
                    Text("Password").foregroundStyle(.secondary)
                    Text(revealed ?? "••••••••••")
                        .font(.body.monospaced())
                        .foregroundStyle(revealed == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .accessibilityLabel(revealed == nil ? "Hidden password" : "Password")
                    HStack(spacing: 6) {
                        Button(revealed == nil ? "Show" : "Hide") { toggleReveal() }
                        copyButton(field: "\u{0}password") { copyPassword() }
                    }
                }
                ForEach(Array(ref.urls.enumerated()), id: \.offset) { index, site in
                    field(index == 0 ? (ref.urls.count == 1 ? "Website" : "Websites") : "", site) {
                        copyPlain(site)
                    }
                }
                if ref.notesStamp != nil {
                    GridRow {
                        Text("Notes").foregroundStyle(.secondary)
                        Text(notes ?? "Hidden")
                            .foregroundStyle(notes == nil ? .secondary : .primary)
                            .textSelection(.enabled)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                        Color.clear.frame(width: 1, height: 1)
                    }
                }
            }
            HStack {
                if let onFill {
                    Button("Fill") { onFill(false) }
                        .help("Types it into the app you were in")
                    if let rememberSite {
                        Button("Fill and Remember for \(rememberSite)") { onFill(true) }
                            .help("Adds \(rememberSite) to this password, then fills it")
                    }
                }
                if let onEdit { Button("Edit…", action: onEdit) }
                Spacer()
                SecretUnlockControl(secrets: env.secrets)
                    .controlSize(.small)
            }
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: ref.id) { hide() }
        .onDisappear { hide() }
    }

    private func field(_ label: String, _ value: String, copy: @escaping () -> Void) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            copyButton(field: value, action: copy)
        }
    }

    private func copyButton(field: String, action: @escaping () -> Void) -> some View {
        Button(copied == field ? "Copied" : "Copy", action: action)
            .help("Not kept in history")
    }

    private var hint: String {
        let clear = env.prefs.secretClearSeconds > 0
            ? " The clipboard clears after \(env.prefs.secretClearSeconds) seconds."
            : ""
        let what = ref.username == nil ? "the password" : "the username and password"
        if env.secrets.isUnlocked { return "Unlocked. Return fills \(what)." + clear }
        return "Return fills \(what) after Touch ID or your password." + clear
    }

    private func toggleReveal() {
        if revealed != nil {
            hide()
            return
        }
        Task {
            guard let value = await env.secrets.reveal(ref, reason: "show the password for “\(ref.name)”") else { return }
            revealed = value
            notes = env.secrets.notes(of: ref)
        }
    }

    private func hide() {
        revealed = nil
        notes = nil
        copied = nil
    }

    /// Usernames and sites aren't secret, but they stay out of history like everything in Auth.
    private func copyPlain(_ text: String) {
        onUse()
        env.paste.writeSecret(text, clearAfter: 0)
        flash(text)
    }

    /// Touch ID, then transient and concealed (never in history), cleared like a pasted secret.
    private func copyPassword() {
        Task {
            guard let value = await env.secrets.reveal(ref, reason: "copy the password for “\(ref.name)”") else { return }
            onUse()
            env.paste.writeSecret(value, clearAfter: env.prefs.secretClearSeconds)
            flash("\u{0}password")
        }
    }

    private func flash(_ field: String) {
        copied = field
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == field { copied = nil }
        }
    }
}
