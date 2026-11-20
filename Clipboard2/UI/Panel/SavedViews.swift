import SwiftUI

/// The full path above the Saved list ("Saved › Work › Clients") and the New menu. Every
/// segment opens that level and takes dropped items and folders.
struct SavedHeader: View {
    let model: PanelViewModel

    var body: some View {
        HStack(spacing: 4) {
            let path = model.openFolderPath
            BreadcrumbSegment(title: "Saved", symbol: path.isEmpty ? "bookmark.fill" : "chevron.left",
                              isCurrent: path.isEmpty, target: .savedRoot, model: model) { model.showLevel(nil) }
            ForEach(Array(path.enumerated()), id: \.element.id) { index, folder in
                Text("›").foregroundStyle(.tertiary)
                BreadcrumbSegment(title: folder.name, symbol: index == path.count - 1 ? "folder.fill" : nil,
                                  isCurrent: index == path.count - 1, target: .folder(folder.id), model: model) {
                    model.showLevel(folder.id)
                }
            }
            Spacer(minLength: 4)
            newMenu
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var newMenu: some View {
        let inFolder = model.openFolder != nil
        Button {
            model.beginAddItems()
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("Add from clipboard history")
        .accessibilityLabel("Add Items")
        if model.savedSpaceID == nil && !inFolder {
            // Your own Saved: New Folder, or an authenticator typed by hand.
            Menu {
                Button("New Folder", systemImage: "folder.badge.plus") { model.beginNewFolder() }
                Button("New Authenticator…", systemImage: "lock.shield") { model.beginAddAuthenticator() }
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New Folder or Authenticator")
            .accessibilityLabel("New")
        } else {
            Button {
                model.beginNewFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help(inFolder ? "New Folder Inside" : "New Folder")
            .accessibilityLabel(inFolder ? "New Folder Inside" : "New Folder")
        }
    }
}

/// One level of the Saved path: click opens it; dropped items and folders move into it.
private struct BreadcrumbSegment: View {
    let title: String
    let symbol: String?
    let isCurrent: Bool
    let target: PanelDropDelegate.Target
    let model: PanelViewModel
    let action: () -> Void
    @State private var targeted = false

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
                } else {
                    Text(title)
                }
            }
            .fontWeight(isCurrent ? .semibold : .regular)
            .truncationMode(.middle)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background {
                if targeted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
        .disabled(isCurrent && !targeted)
        .onDrop(of: [.clipboard2Clip], delegate: PanelDropDelegate(target: target, model: model, isTargeted: $targeted))
        .help(isCurrent ? title : "Go to \(title) (esc goes up one level). Drop items or folders here to move them.")
    }
}

/// A folder row in the Saved list: click opens it; dragged clips, secrets and folders drop into
/// it, and it can be dragged into another folder or onto the path above.
struct FolderDropRow: View {
    let entry: PanelEntry
    let folder: ClipFolder
    let model: PanelViewModel
    @State private var targeted = false

    var body: some View {
        PanelRow(entry: entry, shortcut: nil, isSelected: model.isSelected(entry), showsCheckmark: model.isMultiSelecting,
                 query: model.query, folderCaption: model.folderCaptions[entry.id],
                 folderCount: model.folderCounts[folder.id] ?? 0, subfolderCount: model.subfolderCounts[folder.id] ?? 0,
                 dropHighlighted: targeted)
            .onTapGesture {
                let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains(.command) || flags.contains(.shift) {
                    model.click(entry)
                } else {
                    model.openFolder(folder)
                }
            }
            .onDrag {
                model.draggingFolderID = model.canChangeFolder(folder) ? folder.id : nil
                return PanelDrag.provider(forFolder: folder)
            }
            .onDrop(of: [.clipboard2Clip], delegate: PanelDropDelegate(target: .folder(folder.id), model: model, isTargeted: $targeted))
    }
}

/// Names a folder: a rename, or a new one that may take the selection with it. In the panel,
/// never a dialog: Return saves, esc cancels.
struct FolderNameView: View {
    @Bindable var form: FolderNameState
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(form.isRename ? "Rename Folder" : "New Folder", systemImage: form.isRename ? "folder" : "folder.badge.plus")
                .font(.headline)
            Text(form.isRename ? "Folders sort by name in Saved."
                 : form.movingCount == 0 ? (form.parent.map { "A folder inside “\($0.name)”. Drag items onto it, or use Move to Folder." }
                                            ?? "A folder in Saved. Drag items onto it, or use Move to Folder.")
                 : form.copies ? "A folder in your Saved. Copies of the selected group items go into it; the group's stay as they are."
                 : form.movingCount == 1 ? "The selected item moves into it and stays saved."
                 : "The \(form.movingCount) selected items move into it and stay saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $form.name, prompt: Text("e.g. Deploy"))
                    .focused($focused)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button(form.isRename ? "Rename" : "Create", action: onSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .onAppear { focused = true }
    }
}

/// Move to Folder ▸ as a tree: a folder with subfolders is a submenu whose first entry is the
/// folder itself, then its children; New Folder… comes last at each level (when `onNew` is set).
struct FolderMoveMenu: View {
    let tree: FolderTree
    let byID: [UUID: ClipFolder]
    let parent: UUID?
    var excluding: Set<UUID> = []
    /// Only these can be picked (others still show, to reach their children); nil: all.
    var allowed: Set<UUID>?
    let onPick: (ClipFolder) -> Void
    let onNew: ((ClipFolder?) -> Void)?

    init(folders: [ClipFolder], parent: UUID?, excluding: Set<UUID> = [], allowed: Set<UUID>? = nil,
         onPick: @escaping (ClipFolder) -> Void, onNew: ((ClipFolder?) -> Void)?) {
        self.init(tree: FolderTree(folders), byID: Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                  parent: parent, excluding: excluding, allowed: allowed, onPick: onPick, onNew: onNew)
    }

    init(tree: FolderTree, byID: [UUID: ClipFolder], parent: UUID?, excluding: Set<UUID>, allowed: Set<UUID>?,
         onPick: @escaping (ClipFolder) -> Void, onNew: ((ClipFolder?) -> Void)?) {
        self.tree = tree
        self.byID = byID
        self.parent = parent
        self.excluding = excluding
        self.allowed = allowed
        self.onPick = onPick
        self.onNew = onNew
    }

    var body: some View {
        let children = tree.children(of: parent).filter { !excluding.contains($0.id) }
        ForEach(children, id: \.id) { node in
            if let folder = byID[node.id] {
                let grandchildren = tree.children(of: node.id).filter { !excluding.contains($0.id) }
                let pickable = allowed?.contains(node.id) ?? true
                if grandchildren.isEmpty {
                    Button(folder.name) { onPick(folder) }.disabled(!pickable)
                } else {
                    Menu(folder.name) {
                        Button(folder.name) { onPick(folder) }.disabled(!pickable)
                        Divider()
                        AnyView(FolderMoveMenu(tree: tree, byID: byID, parent: node.id, excluding: excluding, allowed: allowed,
                                               onPick: onPick, onNew: onNew))
                    }
                }
            }
        }
        if let onNew, parent == nil || parent.map(tree.canCreate(in:)) == true {
            if !children.isEmpty { Divider() }
            Button("New Folder…") { onNew(parent.flatMap { byID[$0] }) }
        }
    }
}

/// The preview of a selected folder: its name, label and size, and what can be done with it.
struct FolderPreview: View {
    let folder: ClipFolder
    let count: Int
    let model: PanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ContentBadge(kind: .folder, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(FolderCaption.text(folders: model.subfolderCounts[folder.id] ?? 0, items: count))
                        .foregroundStyle(.secondary)
                    if model.savedTree.parent(of: folder.id) != nil {
                        Text("In " + model.folderPathName(folder).components(separatedBy: " › ").dropLast().joined(separator: " › "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if let label = folder.label {
                Label(label, systemImage: "tag.fill")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Open") { model.openFolder(folder) }
                    .buttonStyle(.borderedProminent)
                Button("Rename…") { model.beginRename(folder) }
                Button(folder.label == nil ? "Label…" : "Edit Label…") { model.beginLabel(.folder(folder)) }
            }
            Spacer(minLength: 0)
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                DetailLabelRow(entry: .folder(folder), label: folder.label, model: model)
                GridRow {
                    Text("Created").foregroundStyle(.secondary)
                    Text(folder.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                GridRow {
                    Text("Visible to").foregroundStyle(.secondary)
                    Text(folder.spaceID.flatMap { id in model.env.sync.groups.first { $0.id == id }?.name } ?? "Only you")
                }
            }
            .font(.caption)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
