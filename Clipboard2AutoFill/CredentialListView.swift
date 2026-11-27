import SwiftUI
import Observation

/// The list the extension shows when the user asks Clipboard2 for a password or a code: the
/// site's items first, a search field, Fill and Cancel.
@Observable
final class CredentialListModel {
    enum Kind { case passwords, codes }

    private(set) var entries: [AutoFillEntry] = []
    private(set) var kind: Kind = .passwords
    private(set) var serviceIdentifiers: [String] = []
    var search = ""
    var selection: AutoFillEntry.ID?
    /// The title of what's being unlocked while Touch ID is up.
    var unlocking: String?

    @ObservationIgnored var onPick: (AutoFillEntry) -> Void = { _ in }
    @ObservationIgnored var onCancel: () -> Void = {}

    func show(entries: [AutoFillEntry], kind: Kind, serviceIdentifiers: [String]) {
        self.entries = entries
        self.kind = kind
        self.serviceIdentifiers = serviceIdentifiers
        selection = shown.first?.id
    }

    var shown: [AutoFillEntry] {
        AutoFillMatch.ranked(entries, serviceIdentifiers: serviceIdentifiers, search: search)
    }

    func isForSite(_ entry: AutoFillEntry) -> Bool {
        AutoFillMatch.matches(entry, hosts: serviceIdentifiers.compactMap(AutoFillMatch.host(of:)))
    }

    var selected: AutoFillEntry? { shown.first { $0.id == selection } }

    func pickSelected() {
        guard let entry = selected else { return }
        unlocking = entry.title
        onPick(entry)
    }
}

struct CredentialListView: View {
    @Bindable var model: CredentialListModel

    var body: some View {
        VStack(spacing: 0) {
            TextField(model.kind == .codes ? "Search codes" : "Search passwords", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .padding(12)
                .onChange(of: model.search) { model.selection = model.shown.first?.id }
            Divider()
            if model.shown.isEmpty {
                Spacer()
                Text(model.entries.isEmpty
                     ? (model.kind == .codes ? "No codes in Clipboard2 yet." : "No passwords in Clipboard2 yet.")
                     : "Nothing matches.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.shown, selection: $model.selection) { entry in
                    row(entry)
                        .tag(entry.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            model.selection = entry.id
                            model.pickSelected()
                        }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                if let unlocking = model.unlocking {
                    Text("Unlocking \(unlocking)…").foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Fill") { model.pickSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selected == nil || model.unlocking != nil)
            }
            .padding(12)
        }
        .frame(minWidth: 380, minHeight: 300)
    }

    private func row(_ entry: AutoFillEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isCode ? "number.circle.fill" : "key.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1)
                let detail = [entry.user, entry.domains.first ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if model.isForSite(entry) {
                Text("This site").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
