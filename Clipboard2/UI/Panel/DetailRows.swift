import SwiftUI

/// The details section's first row: the label as a tag chip (click edits it) or "＋ Add label".
/// Hidden where labelling isn't allowed (a group item someone else wrote).
struct DetailLabelRow: View {
    let entry: PanelEntry
    let label: String?
    let model: PanelViewModel

    var body: some View {
        if let item = entry.clip {
            // A history item's label is set in Save… (⌘S), along with where it's kept.
            if model.canSave([item]) {
                GridRow {
                    Text("Label").foregroundStyle(.secondary)
                    if let label, !label.isEmpty {
                        Button { model.beginSave(entry) } label: { chip(label) }
                            .buttonStyle(.plain)
                            .help("Edit Saved… (⌘S)")
                    } else {
                        Button(model.isSaved(item) ? "＋ Edit Saved…" : "＋ Save…") { model.beginSave(entry) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                            .help("Label it and choose where it's kept (⌘S)")
                    }
                }
            }
        } else if model.canLabel(entry) {
            GridRow {
                Text("Label").foregroundStyle(.secondary)
                if let label, !label.isEmpty {
                    Button { model.beginLabel(entry) } label: {
                        Label(label, systemImage: "tag.fill")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(.tint)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Edit label (⌘L)")
                } else {
                    Button("＋ Add label") { model.beginLabel(entry) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .help("Add a label (⌘L)")
                }
            }
        } else if let label, !label.isEmpty {
            GridRow {
                Text("Label").foregroundStyle(.secondary)
                Text(label).lineLimit(2)
            }
        }
    }

    private func chip(_ label: String) -> some View {
        Label(label, systemImage: "tag.fill")
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(.tint)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
    }
}

/// Right under Label: where the item is ("Saved › Work › Clients"), or "＋ Move to folder".
/// Either opens the folder picker in this pane. Hidden for items that can't use folders.
struct DetailFolderRow: View {
    let entry: PanelEntry
    let model: PanelViewModel

    var body: some View {
        let clips = entry.clip.map { [$0] } ?? []
        let secrets = entry.secret.map { [$0] } ?? []
        let path = model.folderPath(of: entry)
        if let item = entry.clip {
            // Where it's kept; Save… moves it.
            if let path {
                GridRow {
                    Text("Folder").foregroundStyle(.secondary)
                    if model.canSave([item]) {
                        FolderChip(path: path) { model.beginSave(entry) }
                    } else {
                        Text(path).lineLimit(2)
                    }
                }
            }
        } else if model.canPickFolder(clips: clips, secrets: secrets) {
            GridRow {
                Text("Folder").foregroundStyle(.secondary)
                FolderChip(path: path) {
                    model.selectedID = entry.id
                    model.beginFolderPicker()
                }
            }
        } else if let path {
            GridRow {
                Text("Folder").foregroundStyle(.secondary)
                Text(path).lineLimit(2)
            }
        }
    }
}

/// A path chip ("Saved › Work") or "＋ Move to folder".
struct FolderChip: View {
    let path: String?
    let action: () -> Void

    var body: some View {
        if let path {
            Button(action: action) {
                Label(path, systemImage: "folder.fill")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(.blue)
                    .background(Color.blue.opacity(0.12), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Move to another folder (⌘⇧M)")
        } else {
            Button("＋ Move to folder", action: action)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Move to a folder in Saved (⌘⇧M)")
        }
    }
}

/// The folder picker in the right pane: the tree, the top level and New Folder….
struct FolderPickerView: View {
    @Bindable var form: FolderPickerState
    let model: PanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Move to Folder", systemImage: "folder")
                .font(.headline)
            Text(form.count == 1 ? "Choose where it goes in Saved." : "Choose where the \(form.count) items go in Saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(form.rows.enumerated()), id: \.element.id) { index, row in
                            if let section = row.section {
                                Text(section)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, index == 0 ? 0 : 8)
                                    .padding(.horizontal, 8)
                            }
                            rowView(row, selected: index == form.selection)
                                .id(row.id)
                                .onTapGesture {
                                    form.selection = index
                                    model.pick(row)
                                }
                        }
                    }
                }
                .onChange(of: form.selection) { _, index in
                    if form.rows.indices.contains(index) { proxy.scrollTo(form.rows[index].id) }
                }
            }
        }
        .padding(16)
    }

    private func rowView(_ row: FolderPickerState.Row, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(row))
                .frame(width: 18)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.blue))
            Text(row.title)
                .lineLimit(1)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Spacer()
        }
        .padding(.leading, 8 + CGFloat(row.level) * 16)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func symbol(_ row: FolderPickerState.Row) -> String {
        switch row.kind {
        case .topLevel: "bookmark"
        case .folder: "folder"
        case .newFolder: "folder.badge.plus"
        }
    }
}

/// Add Items: search and tick recent history; Return saves the ticked ones here.
struct AddItemsView: View {
    @Bindable var form: AddItemsState
    let onSubmit: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let shown = form.shown
        VStack(alignment: .leading, spacing: 10) {
            if let contact = form.contact {
                Label("Send to \(contact.name)", systemImage: "paperplane")
                    .font(.headline)
            } else {
                Label(form.folder.map { "Add to “\($0.name)”" } ?? "Add to Saved", systemImage: "plus.circle")
                    .font(.headline)
            }
            TextField("Search history", text: $form.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            if shown.isEmpty {
                Text(form.candidates.isEmpty
                     ? (form.contact == nil ? "Everything in your history is saved already." : "Your history is empty.")
                     : "No matches.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == form.selection)
                                    .id(item.id)
                                    .onTapGesture {
                                        form.selection = index
                                        form.toggle(item)
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
                Text("↑↓ choose · space ticks · esc cancels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                let verb = form.contact == nil ? "Add" : "Send"
                Button(form.checked.isEmpty ? verb : "\(verb) \(form.checked.count)", action: onSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.checked.isEmpty)
            }
        }
        .padding(16)
        .onAppear { searchFocused = true }
    }

    private func row(_ item: ClipItem, selected: Bool) -> some View {
        let checked = form.checked.contains(item.id)
        return HStack(spacing: 8) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? AnyShapeStyle(.white) : checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            ClipIconView(item: item, size: 18)
            Text(item.displayTitle)
                .lineLimit(1)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Spacer(minLength: 4)
            Text(item.lastCopiedAt.shortRelative)
                .font(.caption)
                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? [.isButton, .isSelected] : .isButton)
    }
}
