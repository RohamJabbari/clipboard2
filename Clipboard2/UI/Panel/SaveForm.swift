import SwiftUI

/// Where Save… puts items: your own Saved (in a folder, or nil: none) or a group (its root or one
/// of its folders).
nonisolated enum SaveDestination: Hashable, Sendable {
    case mine(UUID?)
    case group(String, UUID?)

    var groupID: String? {
        if case .group(let id, _) = self { return id }
        return nil
    }

    var folderID: UUID? {
        switch self {
        case .mine(let id), .group(_, let id): id
        }
    }
}

/// Save… / Edit Saved…: a label, then exactly one destination picked from your folders or the
/// folders of a group you can send to. Inline in the right pane, never a dialog.
@Observable
final class SaveFormState {
    struct Row: Identifiable, Equatable {
        var id: String
        var title: String
        var level: Int
        var destination: SaveDestination
        /// A group's root ("‹Group›") rather than a folder.
        var isGroupRoot = false
    }

    enum Side { case mine, groups }

    let clips: [ClipItem]
    /// Edit Saved…: the item was saved already, and the form starts where it is.
    let isEditing: Bool
    var label: String
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            // The pick stays visible: the first row that's left when it's filtered away.
            if !allRows.contains(where: { $0.destination == destination }), let first = allRows.first {
                destination = first.destination
            }
        }
    }
    /// The group pill above Group folders: one group, or nil for all of them.
    var groupPill: String?
    var destination: SaveDestination
    /// Your folders, and each listed group's (refreshed when New Folder adds one).
    var personalFolders: [ClipFolder]
    /// Groups this account can send to; nobody else's are offered.
    let groups: [SyncGroup]
    var groupFolders: [String: [ClipFolder]]
    /// New Folder is being named in this list.
    var newFolderSide: Side?
    var newFolderName = ""

    init(clips: [ClipItem], isEditing: Bool = false, label: String? = nil, destination: SaveDestination = .mine(nil),
         personalFolders: [ClipFolder], groups: [SyncGroup], groupFolders: [String: [ClipFolder]]) {
        self.clips = clips
        self.isEditing = isEditing
        self.label = label ?? (clips.count == 1 ? Self.suggestedLabel(for: clips[0]) : "")
        self.personalFolders = personalFolders
        self.groups = groups
        self.groupFolders = groupFolders
        // A group that's not offered (no Send) can't be the destination.
        if let group = destination.groupID, !groups.contains(where: { $0.id == group }) {
            self.destination = .mine(nil)
        } else {
            self.destination = destination
        }
    }

    /// One item: the label field shows. Several: they all just move.
    var showsLabel: Bool { clips.count == 1 }

    /// The existing label, else the first line of text (at most 60 characters); a file's name or
    /// "Image" for images and files. Never the text of a password-like or concealed item.
    static func suggestedLabel(for item: ClipItem) -> String {
        if let label = item.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { return label }
        switch item.kind {
        case .image, .file:
            return item.fileURLs.first.map { $0.lastPathComponent } ?? (item.kind == .image ? "Image" : "File")
        case .text, .richText:
            guard !item.isConcealed, SensitiveText.detect(item.text) == nil else { return "" }
            let line = item.text.split(whereSeparator: \.isNewline).lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            return line.count > 60 ? String(line.prefix(60)).trimmingCharacters(in: .whitespaces) : line
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func matches(_ text: String) -> Bool {
        let q = trimmedQuery
        return q.isEmpty || text.localizedStandardContains(q)
    }

    /// A space's folders in tree order with their depth.
    private static func tree(_ folders: [ClipFolder]) -> [(folder: ClipFolder, level: Int)] {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return FolderTree(folders).flattened().compactMap { node, level in byID[node.id].map { ($0, level) } }
    }

    /// "My folders": Saved (no folder) first, then your tree.
    var myRows: [Row] {
        var rows: [Row] = []
        if matches("Saved (no folder)") {
            rows.append(Row(id: "m-root", title: "Saved (no folder)", level: 0, destination: .mine(nil)))
        }
        for (folder, level) in Self.tree(personalFolders) where matches(folder.name) {
            rows.append(Row(id: "m-" + folder.id.uuidString, title: folder.name, level: trimmedQuery.isEmpty ? level : 0,
                            destination: .mine(folder.id)))
        }
        return rows
    }

    /// "Group folders": each group (or the pill's one) as its root, then its tree. A group whose
    /// name matches the search keeps all its folders.
    var groupRows: [Row] {
        var rows: [Row] = []
        for group in groups where groupPill == nil || groupPill == group.id {
            let groupHit = matches(group.name)
            let folders = Self.tree(groupFolders[group.id] ?? []).filter { groupHit || matches($0.folder.name) }
            guard groupHit || !folders.isEmpty else { continue }
            rows.append(Row(id: "g-" + group.id, title: group.name, level: 0, destination: .group(group.id, nil), isGroupRoot: true))
            for (folder, level) in folders {
                rows.append(Row(id: "g-" + folder.id.uuidString, title: folder.name,
                                level: trimmedQuery.isEmpty || groupHit ? level + 1 : 1,
                                destination: .group(group.id, folder.id)))
            }
        }
        return rows
    }

    var allRows: [Row] { myRows + groupRows }

    /// ↑↓ walk My folders, then Group folders.
    func moveDestination(by delta: Int) {
        let rows = allRows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.destination == destination } ?? (delta > 0 ? -1 : rows.count)
        destination = rows[min(max(current + delta, 0), rows.count - 1)].destination
    }

    /// Where New Folder in that list creates one: in the picked folder (or at the top), in the
    /// picked group, the pill's group or the only one. Nil when no group is picked.
    func newFolderPlace(_ side: Side) -> (spaceID: String?, parentID: UUID?)? {
        switch (side, destination) {
        case (.mine, .mine(let folder)): return (nil, folder)
        case (.mine, .group): return (nil, nil)
        case (.groups, .group(let group, let folder)): return (group, folder)
        case (.groups, .mine):
            if let groupPill { return (groupPill, nil) }
            return groups.count == 1 ? (groups[0].id, nil) : nil
        }
    }
}

// MARK: - View

/// The Save… form in the right pane: label, one search, My folders | Group folders.
struct SaveFormView: View {
    @Bindable var form: SaveFormState
    let model: PanelViewModel
    @FocusState private var focus: Field?

    private enum Field { case label, search, newFolder }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(form.isEditing ? "Edit Saved" : "Save", systemImage: "bookmark")
                .font(.headline)
            if form.showsLabel {
                TextField("Label", text: $form.label, prompt: Text("Label (optional)"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .label)
            } else {
                Text("\(form.clips.count) items")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            TextField("Search", text: $form.query, prompt: Text("Search folders and groups"))
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .search)
            HStack(alignment: .top, spacing: 10) {
                column(title: "My folders", side: .mine, rows: form.myRows)
                if !form.groups.isEmpty {
                    column(title: "Group folders", side: .groups, rows: form.groupRows)
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Spacer()
                Button("Cancel") { model.resetMode() }
                Button("Save") { model.submitSave() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .onAppear { focus = form.showsLabel ? .label : .search }
        .onChange(of: form.newFolderSide) { _, side in focus = side == nil ? (form.showsLabel ? .label : .search) : .newFolder }
    }

    private func column(title: String, side: SaveFormState.Side, rows: [SaveFormState.Row]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if side == .groups && form.groups.count > 1 { groupPills }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(rows) { row in
                            rowView(row).id(row.id)
                        }
                        if rows.isEmpty {
                            Text("No matches")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .onChange(of: form.destination) {
                    if let row = rows.first(where: { $0.destination == form.destination }) { proxy.scrollTo(row.id) }
                }
            }
            newFolder(side)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var groupPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                pill("All groups", selected: form.groupPill == nil) { form.groupPill = nil }
                ForEach(form.groups) { group in
                    pill(group.name, selected: form.groupPill == group.id) { form.groupPill = group.id }
                }
            }
        }
    }

    private func pill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(ChipMotion.tint))
                .background(Capsule().fill(selected ? ChipMotion.tint : ChipMotion.tint.opacity(0.13)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func rowView(_ row: SaveFormState.Row) -> some View {
        let selected = row.destination == form.destination
        let symbol = row.isGroupRoot ? "person.2.fill" : row.id == "m-root" ? "bookmark" : "folder"
        return HStack(spacing: 6) {
            Image(systemName: symbol)
                .frame(width: 16)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : row.isGroupRoot ? AnyShapeStyle(ChipMotion.tint) : AnyShapeStyle(.tint))
            Text(row.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(row.isGroupRoot ? .medium : .regular)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Spacer(minLength: 0)
        }
        .padding(.leading, 6 + CGFloat(row.level) * 14)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // A second click on the picked row saves.
            if selected && (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                model.submitSave()
            } else {
                form.destination = row.destination
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func newFolder(_ side: SaveFormState.Side) -> some View {
        if form.newFolderSide == side {
            TextField("Folder name", text: $form.newFolderName, prompt: Text("Folder name"))
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .newFolder)
                .onSubmit { model.createSaveFormFolder() }
        } else {
            Button {
                model.beginSaveFormFolder(side)
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .disabled(form.newFolderPlace(side) == nil)
            .help(side == .groups && form.newFolderPlace(side) == nil ? "Pick a group first" : "New Folder in the picked level")
        }
    }
}
