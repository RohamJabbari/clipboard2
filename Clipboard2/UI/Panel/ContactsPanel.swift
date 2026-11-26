import SwiftUI

// Contacts → People and Send to Contact… (docs/features/notifications-contacts.md → Contact list).

/// One row of Contacts → People: pending requests first, then contacts.
nonisolated enum PeopleRow: Identifiable, Equatable, Sendable {
    case incoming(ContactRequest)
    case outgoing(ContactRequest)
    case contact(SyncContact)

    var id: String {
        switch self {
        case .incoming(let request): "in-" + request.spaceId
        case .outgoing(let request): "out-" + request.spaceId
        case .contact(let contact): "p-" + contact.id
        }
    }

    var name: String {
        switch self {
        case .incoming(let request), .outgoing(let request): request.name
        case .contact(let contact): contact.name
        }
    }

    var contact: SyncContact? { if case .contact(let contact) = self { contact } else { nil } }

    /// What the search matches: the name and the username.
    var searchText: String {
        switch self {
        case .incoming(let request), .outgoing(let request): request.name + " " + (request.username ?? "")
        case .contact(let contact): contact.name
        }
    }
}

nonisolated enum PeopleList {
    /// Contacts by when you last sent them something or got something from them, newest first,
    /// then by name.
    static func ranked(_ contacts: [SyncContact], lastExchange: [String: Date]) -> [SyncContact] {
        contacts.sorted { a, b in
            let da = lastExchange[a.id] ?? .distantPast, db = lastExchange[b.id] ?? .distantPast
            if da != db { return da > db }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Requests (incoming, then outgoing), then contacts; only those matching `query`.
    static func rows(contacts: [SyncContact], requests: ContactRequests, lastExchange: [String: Date],
                     query: String) -> [PeopleRow] {
        let rows = requests.incoming.map(PeopleRow.incoming) + requests.outgoing.map(PeopleRow.outgoing)
            + ranked(contacts, lastExchange: lastExchange).map(PeopleRow.contact)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return rows }
        return rows.filter { FuzzyMatcher.score(query: q, in: $0.searchText) != nil }
    }
}

/// Send to Contact…: the contacts (recent first), a search, the ones ticked, and what goes.
@Observable
final class ContactPickerState {
    let clips: [ClipItem]
    /// Secrets with their values, unlocked before the picker opened.
    let secrets: [(ref: SecretRef, value: String)]
    let contacts: [SyncContact]
    var query = "" { didSet { if query != oldValue { selection = 0 } } }
    var selection = 0
    var checked: Set<String> = []

    init(clips: [ClipItem], secrets: [(ref: SecretRef, value: String)], contacts: [SyncContact]) {
        self.clips = clips
        self.secrets = secrets
        self.contacts = contacts
    }

    var count: Int { clips.count + secrets.count }

    var shown: [SyncContact] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return contacts }
        return contacts.filter { FuzzyMatcher.score(query: q, in: $0.name) != nil }
    }

    var highlighted: SyncContact? {
        let shown = shown
        return shown.indices.contains(selection) ? shown[selection] : nil
    }

    func toggle(_ contact: SyncContact) {
        if checked.contains(contact.id) { checked.remove(contact.id) } else { checked.insert(contact.id) }
    }

    func toggleHighlighted() {
        if let highlighted { toggle(highlighted) }
    }

    /// Who Return sends to: the ticked contacts, or the highlighted one when none are ticked.
    /// `adding` (⌘↩) sends to the ticked ones and the highlighted one.
    func recipients(adding: Bool) -> [SyncContact] {
        var ids = checked
        if (adding || ids.isEmpty), let highlighted { ids.insert(highlighted.id) }
        return contacts.filter { ids.contains($0.id) }
    }
}

/// Add Contact in Contacts → People: a username (a request) or a contact code (added at once,
/// after "Add ‹name›?"), and Create Code. The same calls as Settings → Sync.
@Observable
final class AddContactState {
    var text = "" { didSet { if text != oldValue { preview = nil; error = nil } } }
    var busy = false
    var error: String?
    /// A contact code, opened: Return adds them.
    var preview: InvitePreview?
    /// A code just made (shown once).
    var code: String?
    var copied = false

    /// What was typed is a code, not a username.
    static func isCode(_ text: String) -> Bool { SyncCrypto.Invite.parse(text) != nil }
}

// MARK: - Views

/// The Contacts chip. Selected it grows into a pill with **Inbox · People**, like a group's.
struct ContactsChip: View {
    let selected: Bool
    @Binding var showsPeople: Bool
    let onSelect: () -> Void
    var pendingRequests = 0
    @Namespace private var segmentSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    private let tint = Color.blue

    var body: some View {
        HStack(spacing: 0) {
            nameButton
            if selected {
                segments
                    .transition(reduceMotion ? .identity
                                : .asymmetric(insertion: .opacity.animation(ChipMotion.labelsIn),
                                              removal: .opacity.animation(ChipMotion.labelsOut)))
            }
        }
        .font(.callout.weight(.medium))
        .lineLimit(1)
        .fixedSize()
        .background { shape.fill(tint.opacity(selected ? 0.16 : 0.13)) }
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Contacts")
    }

    private var nameButton: some View {
        Button {
            guard !selected else { return }
            onSelect()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle").imageScale(.small)
                Text("Contacts")
                if pendingRequests > 0 && !selected {
                    Text("\(pendingRequests)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.red))
                        .accessibilityLabel("\(pendingRequests) contact requests")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, selected ? 4 : 10)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Contacts filter")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var segments: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(tint.opacity(0.3))
                .frame(width: 1, height: 13)
                .padding(.trailing, 3)
                .accessibilityHidden(true)
            segment("Inbox", people: false)
            segment(pendingRequests > 0 ? "People · \(pendingRequests)" : "People", people: true)
        }
        .padding(.vertical, 2)
        .padding(.trailing, 2)
    }

    private func segment(_ label: String, people isPeople: Bool) -> some View {
        let active = showsPeople == isPeople
        return Button {
            showsPeople = isPeople
        } label: {
            Text(label)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tint)
                            .matchedGeometryEffect(id: "highlight", in: segmentSpace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPeople ? "People" : "Inbox")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// Contacts → People: Add Contact, requests, then contacts. The main search field filters it.
struct PeopleListView: View {
    let model: PanelViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.people.isEmpty && !model.query.isEmpty ? "No matches" : "People")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.beginAddContact()
                } label: {
                    Label("Add Contact", systemImage: "person.crop.circle.badge.plus")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .help("Add someone by username or with a contact code (⌘N)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            Hairline()
            if model.people.isEmpty && model.query.isEmpty {
                ContentUnavailableView {
                    Label("No Contacts Yet", systemImage: "person.crop.circle")
                } description: {
                    Text("Add someone by their username or a contact code to send them items.")
                }
                .pinnedEmptyState()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(model.people) { row in
                                PeopleRowView(row: row, isSelected: model.peopleSelectionID == row.id, model: model)
                                    .id(row.id)
                                    .onTapGesture { model.peopleSelectionID = row.id }
                                    .contextMenu { contextMenu(row) }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .onChange(of: model.peopleSelectionID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("People")
    }

    @ViewBuilder
    private func contextMenu(_ row: PeopleRow) -> some View {
        switch row {
        case .incoming(let request):
            Button("Accept") { model.accept(request) }
            Button("Decline") { model.dismiss(request) }
        case .outgoing(let request):
            Button("Cancel Request") { model.dismiss(request) }
        case .contact(let contact):
            Button("Send…") { model.beginSendItems(to: contact) }
            Divider()
            Button("Remove Contact…", role: .destructive) {
                model.peopleSelectionID = row.id
                model.askToRemove(contact)
            }
        }
    }
}

private struct PeopleRowView: View {
    let row: PeopleRow
    let isSelected: Bool
    let model: PanelViewModel

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.blue))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            Spacer(minLength: 4)
            buttons
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var symbol: String {
        switch row {
        case .incoming: "person.crop.circle.badge.plus"
        case .outgoing: "clock"
        case .contact: "person.crop.circle.fill"
        }
    }

    private var subtitle: String? {
        switch row {
        case .incoming: "Wants to add you"
        case .outgoing: "Waiting for them to accept"
        case .contact(let contact):
            model.lastExchange[contact.id].map { "Last item \($0.shortRelative)" }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch row {
        case .incoming(let request):
            Button("Decline") { model.dismiss(request) }
                .controlSize(.small)
            Button("Accept") { model.accept(request) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        case .outgoing(let request):
            Button("Cancel") { model.dismiss(request) }
                .controlSize(.small)
        case .contact(let contact):
            Button("Send…") { model.beginSendItems(to: contact) }
                .controlSize(.small)
                .help("Pick items to send to \(contact.name)")
            Button {
                model.askToRemove(contact)
            } label: {
                Image(systemName: "person.crop.circle.badge.minus")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .help("Remove \(contact.name)… (asks first)")
            .accessibilityLabel("Remove \(contact.name)")
        }
    }
}

/// The right pane for the selected person: what you can do with them, and Remove's inline confirm.
struct PersonPreview: View {
    let row: PeopleRow
    let model: PanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(row.name, systemImage: "person.crop.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            switch row {
            case .incoming(let request):
                Text("\(request.name) wants to add you as a contact. You'll be able to send each other items; what they send shows up in your Inbox.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Decline") { model.dismiss(request) }
                    Button("Accept") { model.accept(request) }
                        .buttonStyle(.borderedProminent)
                        .help("Return")
                }
            case .outgoing(let request):
                Text("Waiting for \(request.name) to accept your request.")
                    .foregroundStyle(.secondary)
                Button("Cancel Request") { model.dismiss(request) }
            case .contact(let contact):
                if let date = model.lastExchange[contact.id] {
                    Text("Last item \(date.shortRelative)").foregroundStyle(.secondary)
                } else {
                    Text("Nothing sent yet.").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Send…") { model.beginSendItems(to: contact) }
                        .buttonStyle(.borderedProminent)
                        .help("Return")
                    Button("Show Inbox") { model.showInbox() }
                }
                Spacer(minLength: 0)
                if model.pendingRemoveContactID == contact.id {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Remove \(contact.name)? Everything you've sent each other is deleted, for both of you.")
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Cancel") { model.cancelRemove() }
                                .keyboardShortcut(.cancelAction)
                            Button("Remove Contact", role: .destructive) { model.remove(contact) }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.08)))
                } else {
                    Button("Remove Contact…", role: .destructive) { model.askToRemove(contact) }
                        .help("⌫")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Send to Contact…: a search already focused, recent contacts first, ticks for several.
struct ContactPickerView: View {
    @Bindable var form: ContactPickerState
    let model: PanelViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        let shown = form.shown
        VStack(alignment: .leading, spacing: 10) {
            Label(form.count == 1 ? "Send to Contact" : "Send \(form.count) Items to Contact", systemImage: "paperplane")
                .font(.headline)
            TextField("Search contacts", text: $form.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            if shown.isEmpty {
                Text(form.contacts.isEmpty ? "No contacts yet." : "No matches.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, contact in
                                row(contact, selected: index == form.selection)
                                    .id(contact.id)
                                    .onTapGesture {
                                        form.selection = index
                                        model.submitContactPicker(adding: false)
                                    }
                            }
                        }
                    }
                    .onChange(of: form.selection) { _, index in
                        if shown.indices.contains(index) { proxy.scrollTo(shown[index].id) }
                    }
                }
            }
            HStack {
                Text("↑↓ choose · space ticks · ⌘↩ adds the highlighted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(form.checked.isEmpty ? "Send" : "Send to \(form.checked.count)") { model.submitContactPicker(adding: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.recipients(adding: false).isEmpty)
            }
        }
        .padding(16)
        .onAppear { searchFocused = true }
    }

    private func row(_ contact: SyncContact, selected: Bool) -> some View {
        let checked = form.checked.contains(contact.id)
        return HStack(spacing: 8) {
            Button {
                form.toggle(contact)
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checked ? "Untick \(contact.name)" : "Tick \(contact.name)")
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.blue))
            Text(contact.name)
                .lineLimit(1)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Spacer(minLength: 4)
            if let date = model.lastExchange[contact.id] {
                Text(date.shortRelative)
                    .font(.caption)
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(checked ? [.isButton, .isSelected] : .isButton)
    }
}

/// Add Contact: a username or a code; Create Code shows a new one once.
struct AddContactView: View {
    @Bindable var form: AddContactState
    let model: PanelViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add Contact", systemImage: "person.crop.circle.badge.plus")
                .font(.headline)
            if let preview = form.preview {
                Text("Add \(preview.name) as a contact? You'll be able to send each other items.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Their username sends them a request. A contact code they gave you adds them right away.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Username or code", text: $form.text, prompt: Text("Username or XXXX-XXXX-… code"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { model.submitAddContact() }
            }
            if let error = form.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if form.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { model.resetMode() }
                Button(form.preview != nil ? "Add Contact"
                       : AddContactState.isCode(form.text) ? "Continue" : "Send Request") { model.submitAddContact() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.busy || (form.preview == nil && form.text.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Or give them a code").font(.callout.weight(.medium))
                    Text("Whoever enters it becomes your contact. It works once, for 7 days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Create Code") { model.createContactCode() }
                    .disabled(form.busy)
            }
            if let code = form.code {
                HStack {
                    Text(code)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button(form.copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        form.copied = true
                    }
                }
                Text("Shown only once.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .onAppear { focused = true }
    }
}
