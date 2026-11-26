import SwiftUI
import UniformTypeIdentifiers

// The origin page and the sites listed on their own (docs/features/auth-autofill.md → Origins).

/// Sites with nothing listed under them (a named site with only notes or documents), after Auth's
/// groups. Clicking one opens its page.
struct OriginsSection: View {
    let model: PanelViewModel
    let origins: [AuthOrigin]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Image(systemName: "globe")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text("Sites").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
            ForEach(origins) { origin in
                let selected = model.originPage?.key == .origin(origin.id)
                HStack(spacing: 10) {
                    SourceIcon(source: origin.faviconDomain().map(AuthSource.domain), origin: origin, size: 22)
                        .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(origin.title)
                            .lineLimit(1)
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        Text(Self.summary(origin))
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { model.openOriginPage(.origin(origin.id)) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    static func summary(_ origin: AuthOrigin) -> String {
        var parts: [String] = []
        if let domain = origin.domains.first { parts.append(domain) }
        if !origin.notes.isEmpty { parts.append(origin.notes.count == 1 ? "1 note" : "\(origin.notes.count) notes") }
        if !origin.documents.isEmpty {
            parts.append(origin.documents.count == 1 ? "1 document" : "\(origin.documents.count) documents")
        }
        return parts.isEmpty ? "Nothing here yet" : parts.joined(separator: " · ")
    }
}

/// Everything for one site, in the right pane: its name, websites and icon; its logins, secrets
/// and authenticators (add, edit, move, delete); notes; documents; merging and deleting the site.
struct OriginPageView: View {
    @Bindable var page: OriginPageState
    let model: PanelViewModel
    @Environment(AppEnvironment.self) private var env
    @FocusState private var focus: Field?
    @State private var dropTargeted = false

    private enum Field: Hashable { case name, domain(Int), newNote, note }

    private var origin: AuthOrigin? { env.origins.origin(withID: page.key?.originID) }
    private var isNoWebsite: Bool { page.key == AuthGroupKey.none }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !isNoWebsite { siteSection }
                entriesSection
                if !isNoWebsite {
                    notesSection
                    documentsSection
                    manageSection
                }
                if let error = page.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !isNoWebsite else { return false }
            Task { model.addOriginDocuments(await PanelDrag.loadFileURLs(from: providers)) }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { if page.isNew { focus = .name } }
    }

    // MARK: Header

    private var header: some View {
        let heading = model.originPageHeading(page)
        return HStack(spacing: 12) {
            SourceIcon(source: heading.source, origin: heading.origin, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(page.isNew ? "New Site" : heading.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                model.closeOriginPage()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Back to the list (esc)")
            .accessibilityLabel("Close")
        }
    }

    private var subtitle: String {
        if page.isNew { return "Name it, or give it a website" }
        if isNoWebsite { return "Entries without a website" }
        if origin != nil { return "Edited by hand · synced" }
        return "Grouped automatically · editing makes it a site of its own"
    }

    // MARK: Site

    private var siteSection: some View {
        section("Site") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("Name", text: $page.name, prompt: Text("e.g. Google, PJ Logistik"))
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .name)
                        .onSubmit { model.saveOriginDetails() }
                }
                ForEach(Array(page.domains.enumerated()), id: \.offset) { index, _ in
                    GridRow {
                        Text(index == 0 ? "Websites" : "").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            TextField("Website", text: Binding(
                                get: { page.domains.indices.contains(index) ? page.domains[index] : "" },
                                set: { if page.domains.indices.contains(index) { page.domains[index] = $0 } }
                            ), prompt: Text(index == 0 ? "e.g. google.com" : "Another site, e.g. accounts.google.com"))
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .domain(index))
                            .onSubmit { model.saveOriginDetails() }
                            if page.domains.count > 1 {
                                Button { page.removeDomain(at: index) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .help("Remove this website")
                                    .accessibilityLabel("Remove website")
                            }
                            if index == page.domains.count - 1 {
                                Button {
                                    page.addDomainRow()
                                    focus = .domain(page.domains.count - 1)
                                } label: { Image(systemName: "plus.circle") }
                                    .buttonStyle(.borderless)
                                    .help("Add another website")
                                    .accessibilityLabel("Add website")
                            }
                        }
                    }
                }
                GridRow {
                    Text("Icon").foregroundStyle(.secondary)
                    iconPicker
                }
            }
            HStack {
                Text("Every website's domain files its logins and codes here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(page.isNew ? "Create Site" : "Save") { model.saveOriginDetails() }
                    .disabled(!page.canSaveDetails || (!page.isNew && !page.hasUnsavedDetails))
            }
        }
    }

    private var iconPicker: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Website Icon") { model.setOriginIcon(.favicon(nil)) }
                let hosts = page.cleanDomains.compactMap(AuthSource.host(ofSite:))
                if hosts.count > 1 {
                    Menu("Icon of") {
                        ForEach(hosts, id: \.self) { host in
                            Button(host) { model.setOriginIcon(.favicon(host)) }
                        }
                    }
                }
                Button("First Letter") { model.setOriginIcon(.letter) }
                Menu("Symbol") {
                    ForEach(OriginIcon.symbols, id: \.self) { name in
                        Button { model.setOriginIcon(.symbol(name)) } label: { Label(name, systemImage: name) }
                    }
                }
            } label: {
                Text(iconTitle)
            }
            .fixedSize()
            TextField("Emoji", text: $page.emojiDraft, prompt: Text("or an emoji"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .onChange(of: page.emojiDraft) { _, text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { model.setOriginIcon(.emoji(String(trimmed.prefix(4)))) }
                }
        }
    }

    private var iconTitle: String {
        switch page.icon {
        case .favicon(nil): "Website Icon"
        case .favicon(let host?): "Icon of \(host)"
        case .letter: "First Letter"
        case .symbol(let name): "Symbol: \(name)"
        case .emoji(let text): "Emoji: \(text)"
        }
    }

    // MARK: Entries

    private var entriesSection: some View {
        let members = model.originPageEntries(page.key)
        return section("Logins, secrets and authenticators") {
            if members.secrets.isEmpty && members.authenticators.isEmpty {
                Text(page.isNew ? "Save the site, then add logins and codes." : "Nothing filed here yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(members.secrets) { ref in
                entryRow(.secret(ref), symbol: ref.isPassword ? "person.badge.key" : "key",
                         title: ref.username ?? ref.name, detail: ref.username == nil ? ref.urls.first : ref.name)
            }
            ForEach(members.authenticators) { item in
                entryRow(.authenticator(item), symbol: "lock.shield", title: item.title,
                         detail: item.isOwned ? item.subtitle : "Shared with you", item: item)
            }
            if !page.isNew {
                HStack(spacing: 8) {
                    Button("New Login…") { model.beginNewEntry(.password, onPage: page) }
                    Button("New Secret…") { model.beginNewEntry(.secret, onPage: page) }
                    Button("New Authenticator…") { model.beginNewAuthenticator(onPage: page) }
                }
                .controlSize(.small)
                Text("Revealing or pasting a password still asks for Touch ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func entryRow(_ entry: PanelEntry, symbol: String, title: String, detail: String?,
                          item: AuthenticatorItem? = nil) -> some View {
        let changeable = model.canRefile(entry)
        let confirming = page.confirmingEntryID == entry.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let item {
                    LiveCode(item: item, clock: model.otpClock, isSelected: false)
                }
                if changeable, entry.secret != nil || item?.isOwned == true {
                    Button("Edit") { model.editEntry(entry, onPage: page) }
                        .controlSize(.small)
                }
                moveMenu(entry)
                if changeable {
                    Button(role: .destructive) { page.confirmingEntryID = entry.id } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete")
                        .accessibilityLabel("Delete \(title)")
                }
            }
            if confirming {
                HStack(spacing: 8) {
                    Text(item != nil ? "Delete “\(title)” for good? It's removed for everyone it's shared with."
                                     : "Delete “\(title)”? This can't be undone.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Cancel") { page.confirmingEntryID = nil }
                    Button("Delete", role: .destructive) { model.deleteEntry(entry) }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func moveMenu(_ entry: PanelEntry) -> some View {
        Menu {
            let targets = model.originTargets(excluding: page.key)
            ForEach(targets) { target in
                Button(target.title) { model.moveEntry(entry, to: target.key) }
            }
            if page.key?.originID != nil {
                Divider()
                Button("Group by Its Website Again") { model.moveEntry(entry, to: .none) }
            }
        } label: {
            Text("Move")
        }
        .controlSize(.small)
        .fixedSize()
        .help("Files it under another site")
    }

    // MARK: Notes

    private var notesSection: some View {
        section("Notes") {
            ForEach(origin?.notes ?? []) { note in
                if page.editingNoteID == note.id {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: $page.noteDraft)
                            .font(.body)
                            .frame(minHeight: 70, maxHeight: 160)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .focused($focus, equals: .note)
                        HStack {
                            Spacer()
                            Button("Cancel") { page.editingNoteID = nil }
                            Button("Save") { model.saveEditedNote() }
                                .keyboardShortcut(.return, modifiers: .command)
                        }
                        .controlSize(.small)
                    }
                    .onAppear { focus = .note }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(note.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Edit") { model.beginEditNote(note) }
                            .controlSize(.small)
                        Button(role: .destructive) { model.deleteOriginNote(note) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete note")
                            .accessibilityLabel("Delete note")
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $page.newNote)
                    .font(.body)
                    .frame(minHeight: 44, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .focused($focus, equals: .newNote)
                    .overlay(alignment: .topLeading) {
                        if page.newNote.isEmpty {
                            Text("A note: a customer number, who to call, how to sign in…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    Text("Notes sync with the site, end-to-end encrypted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Note") { model.addOriginNote() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(page.newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: Documents

    private var documentsSection: some View {
        section("Documents") {
            let documents = origin?.documents ?? []
            if documents.isEmpty {
                Text("Contracts, recovery codes, invoices… Drop files here or add them.")
                    .foregroundStyle(.secondary)
            }
            ForEach(documents) { document in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (document.name as NSString).pathExtension) ?? .data))
                            .resizable()
                            .frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(document.name).lineLimit(1).truncationMode(.middle)
                            Text(ByteCountFormatter.string(fromByteCount: document.size, countStyle: .file)
                                 + (env.origins.documents.contains(id: document.id) ? "" : " · not on this Mac yet"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button("Open") { model.openOriginDocument(document) }
                        Button("Quick Look") { model.quickLookOriginDocument(document) }
                        Button("Paste") { model.pasteOriginDocument(document) }
                            .help("Pastes the file into the app you were in")
                        Button(role: .destructive) { page.confirmingDocumentID = document.id } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove")
                            .accessibilityLabel("Remove \(document.name)")
                    }
                    .controlSize(.small)
                    if page.confirmingDocumentID == document.id {
                        HStack {
                            Text("Remove “\(document.name)” from this site and your other devices?")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Cancel") { page.confirmingDocumentID = nil }
                            Button("Remove", role: .destructive) { model.removeOriginDocument(document) }
                        }
                        .controlSize(.small)
                    }
                }
            }
            HStack {
                Text("Encrypted on this Mac and in sync. Up to \(OriginStore.maxDocuments), 95 MB each.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Files…") { model.chooseOriginDocuments() }
                    .controlSize(.small)
                    .disabled(page.isNew && !page.canSaveDetails)
            }
        }
    }

    // MARK: Merge and delete

    private var manageSection: some View {
        section("Manage") {
            HStack(spacing: 8) {
                Menu {
                    ForEach(model.originTargets(excluding: page.key)) { target in
                        Button(target.title) { page.mergeTarget = target.key }
                    }
                } label: {
                    Text("Merge Into")
                }
                .fixedSize()
                .disabled(page.isNew)
                .help("Moves everything here into another site, then removes this one")
                if origin != nil {
                    Button("Delete Site", role: .destructive) { page.confirmingDelete = true }
                }
                Spacer()
            }
            .controlSize(.small)
            if let target = page.mergeTarget {
                let name = model.originTargets(excluding: page.key).first { $0.key == target }?.title ?? "that site"
                HStack {
                    Text("Move all logins, codes, notes, documents and websites into “\(name)”? This site then goes.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Cancel") { page.mergeTarget = nil }
                    Button("Merge") { model.mergeOrigin(into: target) }
                }
                .controlSize(.small)
            }
            if page.confirmingDelete {
                HStack {
                    Text("Delete this site, its notes and documents? Its logins and codes stay, grouped by their websites again.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Cancel") { page.confirmingDelete = false }
                    Button("Delete", role: .destructive) { model.deleteOrigin() }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Layout

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
