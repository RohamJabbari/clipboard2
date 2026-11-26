import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Auth → Saving passwords: the offer to save pasted logins, and the "Never" sites.
struct SavingPasswordsSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var prefs = env.prefs
        Section {
            Toggle("Offer to save passwords", isOn: $prefs.offerToSavePasswords)
                .onChange(of: prefs.offerToSavePasswords) { env.updateTextFieldIcons() }
            ForEach(prefs.neverSavePasswordSites) { site in
                HStack {
                    Label(site.title, systemImage: site.key.hasPrefix("app:") ? "app" : "globe")
                    Spacer()
                    Text("Never")
                        .foregroundStyle(.secondary)
                    Button {
                        prefs.neverSavePasswordSites.removeAll { $0.key == site.key }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Offer to save passwords for \(site.title) again")
                    .accessibilityLabel("Remove \(site.title)")
                }
            }
        } header: {
            Text("Saving passwords")
        } footer: {
            Text("When you paste a password into a password field and sign in, Clipboard2 offers to save it. The pasted value is kept only until you answer (20 seconds at most). Needs Accessibility.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Settings → Auth → Import: export steps per password manager, Open, watching Downloads and the
/// Desktop, then the review list. No dialogs besides the file chooser.
struct PasswordImportSection: View {
    let center: PasswordImportCenter
    @State private var isTargeted = false

    var body: some View {
        Section {
            if let review = center.review {
                PasswordImportReviewView(review: review, center: center)
            } else {
                sources
                if let source = center.source { steps(for: source) }
                status
            }
        } header: {
            Text("Import")
        } footer: {
            Text("The export is read once and not kept. Afterwards it's moved to the Trash: it isn't encrypted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard center.review == nil, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in center.load(url) }
            }
            return true
        }
    }

    private var sources: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            ForEach(PasswordExportSource.allCases) { source in
                Button {
                    center.choose(source)
                } label: {
                    Text(source.title)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(center.source == source ? .accentColor : nil)
                .accessibilityAddTraits(center.source == source ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func steps(for source: PasswordExportSource) -> some View {
        Text(source.steps)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            ForEach(ExportOpener.openers(for: source).filter(\.isAvailable)) { opener in
                Button("Open \(opener.name)") { opener.open() }
            }
            Spacer()
            Button("Choose File…") { chooseFile() }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let until = center.watchingUntil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Watching Downloads and the Desktop for the export until \(until.formatted(date: .omitted, time: .shortened)). Or drop it here.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { center.stopWatching() }
                    .buttonStyle(.borderless)
            }
            .font(.callout)
        } else if center.source != nil {
            HStack {
                Text(isTargeted ? "Drop to review it" : "Drop the export here, or choose it.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Watch Again") { center.startWatching() }
                    .buttonStyle(.borderless)
            }
            .font(.callout)
        }
        if let result = center.result {
            Text(result)
                .font(.callout)
        }
        if let line = center.trashLine {
            HStack {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Undo") { center.undoTrash() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "Review"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        center.load(url)
    }
}

/// The review list: search, Select all / none, a filter, every entry with its status and a
/// checkbox, then Import N and Cancel. Passwords stay masked.
private struct PasswordImportReviewView: View {
    @Bindable var review: PasswordImportReview
    let center: PasswordImportCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Search", text: $review.search, prompt: Text("Search sites and usernames"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Button("Select All") { review.selectAll() }
                Button("None") { review.selectNone() }
                Spacer()
                Picker("Show", selection: $review.filter) {
                    ForEach(PasswordImportReview.Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(review.visible) { entry in
                        row(entry)
                        Divider()
                    }
                    if review.visible.isEmpty {
                        Text("Nothing matches.")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
            }
            .frame(height: 260)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            HStack {
                Spacer()
                Button("Cancel") { center.cancel() }
                Button("Import \(review.checkedCount)") { center.importChecked() }
                    .buttonStyle(.borderedProminent)
                    .disabled(review.checkedCount == 0)
            }
        }
    }

    private var summary: String {
        var parts = ["\(review.entries.count) in “\(review.fileName)”"]
        for status in PasswordImportEntry.Status.allCases where review.count(status) > 0 {
            parts.append("\(review.count(status)) \(status.title.lowercased())")
        }
        if review.unreadable > 0 { parts.append("\(review.unreadable) empty") }
        return parts.joined(separator: " · ")
    }

    private func row(_ entry: PasswordImportEntry) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { entry.isChecked }, set: { review.setChecked(entry.id, $0) })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!entry.isSelectable)
            .accessibilityLabel("Import \(entry.site) \(entry.username)")
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.site)
                    .lineLimit(1)
                Text(entry.username.isEmpty ? "No username" : entry.username)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if case .password = entry.payload {
                Text("••••••••")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Password hidden")
            }
            Text(entry.status.title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(tagColor(entry.status).opacity(0.15), in: Capsule())
                .foregroundStyle(tagColor(entry.status))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .opacity(entry.isSelectable ? 1 : 0.45)
    }

    private func tagColor(_ status: PasswordImportEntry.Status) -> Color {
        switch status {
        case .new: .green
        case .changed: .orange
        case .duplicate: .secondary
        case .authenticator: .blue
        }
    }
}
