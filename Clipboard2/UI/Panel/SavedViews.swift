import SwiftUI

/// "Saved › Folder" and New Folder above the Saved list. Inside a folder, "Saved" goes back and
/// takes dropped clips out of the folder.
struct SavedHeader: View {
    let model: PanelViewModel
    @State private var rootTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            if let folder = model.openFolder {
                Button {
                    model.closeFolder()
                } label: {
                    Label("Saved", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            if rootTargeted {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.16))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .onDrop(of: [.clipboard2Clip],
                        delegate: PanelDropDelegate(target: .savedRoot, model: model, isTargeted: $rootTargeted))
                .help("Back to Saved (esc). Drop items here to take them out of the folder.")
                Text("›").foregroundStyle(.tertiary)
                Label(folder.name, systemImage: "folder.fill")
                    .labelStyle(.titleAndIcon)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Label("Saved", systemImage: "bookmark.fill")
                    .labelStyle(.titleAndIcon)
                    .fontWeight(.semibold)
            }
            Spacer(minLength: 4)
            if model.openFolder == nil {
                Button {
                    model.beginNewFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("New Folder")
                .accessibilityLabel("New Folder")
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

/// A folder row in the Saved list: click opens it, and dragged clips drop into it.
struct FolderDropRow: View {
    let entry: PanelEntry
    let folder: ClipFolder
    let model: PanelViewModel
    @State private var targeted = false

    var body: some View {
        PanelRow(entry: entry, shortcut: nil, isSelected: model.isSelected(entry), showsCheckmark: model.isMultiSelecting,
                 query: model.query, folderCount: model.folderCounts[folder.id] ?? 0, dropHighlighted: targeted)
            .onTapGesture {
                let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains(.command) || flags.contains(.shift) {
                    model.click(entry)
                } else {
                    model.openFolder(folder)
                }
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
                 : form.movingCount == 0 ? "A folder in Saved. Drag items onto it, or use Move to Folder."
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
                    Text(count == 1 ? "1 saved item" : "\(count) saved items")
                        .foregroundStyle(.secondary)
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
