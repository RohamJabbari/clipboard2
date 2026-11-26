import AppKit

/// The file shown in the preview pane while its name is changed or its contents edited. Edits
/// never touch the user's file: saving keeps a new copy as a new item (see `PanelViewModel.saveFileEdit`).
@Observable
final class FileEditState {
    let itemID: UUID
    /// The file shown (the item's only file, or the one picked of several).
    let url: URL
    /// The name field: what the copy is called (and pasted as).
    var name: String
    /// The contents are open for editing.
    var isEditing = false
    /// The text editing started from.
    var original = ""
    /// Typed into since editing started.
    var isDirty = false
    /// esc was pressed once with unsaved edits; the next esc discards them.
    var confirmingDiscard = false
    /// The editor's text view, read when saving.
    @ObservationIgnored weak var editor: NSTextView?

    init(itemID: UUID, url: URL, name: String) {
        self.itemID = itemID
        self.url = url
        self.name = name
    }

    var draft: String { editor?.string ?? original }

    func matches(_ item: ClipItem, _ url: URL) -> Bool { itemID == item.id && self.url == url }
}

/// Where the file pane should put keyboard focus.
enum FileFocus: Equatable {
    case name, editor
}

extension PanelViewModel {
    // MARK: The file in the preview

    /// The one file the preview shows contents and a name field for: a single-file item's file,
    /// or the only file picked of several. Nil otherwise.
    func shownFile(of item: ClipItem) -> URL? {
        guard item.kind == .file, !item.isTransient, !isMultiSelecting else { return nil }
        if item.fileURLs.count == 1 { return item.fileURLs[0] }
        if let picked = pickedFileURLs(for: item), picked.count == 1 { return picked[0] }
        return nil
    }

    /// The selected item's shown file is text that can be edited (up to 1 MB, not a key file).
    func canEditFile(_ item: ClipItem) -> Bool {
        shownFile(of: item).map { TextFileContents.canEdit($0) } ?? false
    }

    /// The selected item's shown file is still there, so a renamed copy can be made.
    func canRenameFile(_ item: ClipItem) -> Bool {
        shownFile(of: item).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// ⌘E applies: a text clip opens its editor, a text file its contents.
    var canEditPreview: Bool {
        guard let item = selectedEntry?.clip, !isMultiSelecting else { return false }
        return isEditable(item) || canEditFile(item)
    }

    /// The name field's text for `item`'s file `url`; typing into it starts a rename.
    func fileName(for item: ClipItem, url: URL) -> String {
        if let state = fileEdit, state.matches(item, url) { return state.name }
        return url.lastPathComponent
    }

    func setFileName(_ name: String, for item: ClipItem, url: URL) {
        if let state = fileEdit, state.matches(item, url) {
            state.name = name
        } else {
            fileEdit = FileEditState(itemID: item.id, url: url, name: name)
        }
    }

    /// The renamed name differs from the file's own.
    func hasPendingRename(_ item: ClipItem, url: URL) -> Bool {
        guard let state = fileEdit, state.matches(item, url), !state.isEditing else { return false }
        return state.name.trimmingCharacters(in: .whitespacesAndNewlines) != url.lastPathComponent
    }

    /// Renaming changes the item itself (its file is one Clipboard2 keeps) rather than keeping a renamed copy.
    func renamesInPlace(_ item: ClipItem) -> Bool {
        item.spaceID == nil && item.fileURLs.count == 1 && env.store.keepsFiles(of: item)
    }

    /// Names of the files of every personal file item, so an edited copy gets a name of its own.
    private func takenFileNames() -> Set<String> {
        Set(env.store.items(inSpace: nil).filter { $0.kind == .file }.flatMap { $0.fileURLs.map(\.lastPathComponent) })
    }

    // MARK: Rename

    /// ⌘K → Rename File…: focuses the name field.
    func beginRenameFile() {
        guard let item = selectedEntry?.clip, let url = shownFile(of: item), canRenameFile(item) else {
            NSSound.beep()
            return
        }
        if fileEdit?.matches(item, url) != true { fileEdit = FileEditState(itemID: item.id, url: url, name: url.lastPathComponent) }
        fileFocusRequest = .name
    }

    /// Return in the name field: renames the paste name. A file Clipboard2 keeps (an edited copy)
    /// is renamed in place; any other file gets a renamed copy as a new item, and the user's own
    /// file on disk keeps its name.
    func renameFile() {
        guard let state = fileEdit, !state.isEditing, let item = env.store.item(withID: state.itemID), item.kind == .file else { return }
        let current = state.url.lastPathComponent
        guard let name = TextFileContents.sanitizedName(state.name) else {
            NSSound.beep()
            state.name = current
            return
        }
        guard name != current else {
            fileEdit = nil
            focusSearch()
            return
        }
        do {
            if renamesInPlace(item) {
                try env.store.renameKeptFile(of: item, to: name)
                fileEdit = nil
                refresh()
                focusSearch()
                showNotice("Renamed to “\(name)”")
            } else {
                guard FileManager.default.fileExists(atPath: state.url.path) else {
                    NSSound.beep()
                    showNotice("The file isn't there any more")
                    return
                }
                let copy = try env.store.addKeptFile(named: name, copying: state.url, like: item)
                fileEdit = nil
                reveal(copy)
                showNotice("Kept a copy named “\(name)”")
            }
        } catch {
            Log.panel.error("Couldn't rename a file: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            showNotice("Couldn't rename the file")
        }
    }

    // MARK: Edit

    /// ⌘E / Edit: opens the shown file's contents for editing. The name field switches to the
    /// copy's name (`‹name›-edited.‹ext›`) unless one was typed already.
    func beginFileEdit() {
        guard let item = selectedEntry?.clip, let url = shownFile(of: item) else { return }
        guard case .text(let loaded) = TextFileContents.load(url), !loaded.isTruncated else {
            NSSound.beep()
            showNotice("Only text files up to 1 MB can be edited")
            return
        }
        let typed = fileEdit.flatMap { $0.matches(item, url) ? $0.name : nil }
        let name = typed.flatMap { $0 == url.lastPathComponent ? nil : TextFileContents.sanitizedName($0) }
            ?? TextFileContents.editedName(for: url.lastPathComponent, taken: takenFileNames())
        let state = FileEditState(itemID: item.id, url: url, name: name)
        state.original = loaded.text
        state.isEditing = true
        fileEdit = state
        previewSelection = nil
        fileFocusRequest = .editor
    }

    /// Leaves the editor. With unsaved edits and `confirming`, the first call only warns (inline).
    func cancelFileEdit(confirming: Bool = false) {
        guard let state = fileEdit, state.isEditing else { return }
        if confirming, state.isDirty, !state.confirmingDiscard {
            state.confirmingDiscard = true
            showNotice("Unsaved edits: ⌘S keeps a copy, esc discards")
            return
        }
        fileEdit = nil
        focusSearch()
    }

    /// Keeps the edited text as a new file item; the original item and file stay as they are.
    func saveFileEdit() {
        guard let state = fileEdit, state.isEditing, let item = env.store.item(withID: state.itemID) else { return }
        let name = TextFileContents.sanitizedName(state.name)
            ?? TextFileContents.editedName(for: state.url.lastPathComponent, taken: takenFileNames())
        do {
            let copy = try env.store.addKeptFile(named: name, contents: Data(state.draft.utf8), like: item)
            fileEdit = nil
            reveal(copy)
            showNotice("Saved “\(name)” as a new item")
        } catch {
            Log.panel.error("Couldn't save an edited file: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            showNotice("Couldn't save the copy")
        }
    }

    /// Selects a new personal item, switching to Copies when the current view doesn't list it.
    private func reveal(_ item: ClipItem) {
        let id = PanelEntry.clip(item).id
        refresh()
        if !entries.contains(where: { $0.id == id }) {
            query = ""
            onlyThisApp = false
            if openFolder != nil { closeFolder() }
            if filter != .copies { filter = .copies }
            refresh()
        }
        selectedID = id
        focusSearch()
    }

    // MARK: Keys

    /// Keys while the name field has focus: Return renames (or saves the edit), esc backs out.
    func handleFileNameKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case KeyCode.escape:
            if fileEdit?.isEditing == true {
                cancelFileEdit(confirming: true)
            } else {
                fileEdit = nil
                focusSearch()
            }
            return true
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if fileEdit?.isEditing == true { saveFileEdit() } else { renameFile() }
            return true
        default:
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "s", fileEdit?.isEditing == true {
                saveFileEdit()
                return true
            }
            return false
        }
    }

    /// Keys while editing a file's contents: everything is typing except ⌘S / ⌘Return (save a
    /// copy) and esc (cancel; asks once inline when there are unsaved edits).
    func handleFileEditorKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case KeyCode.escape:
            cancelFileEdit(confirming: true)
            return true
        case KeyCode.returnKey where flags.contains(.command), KeyCode.keypadEnter where flags.contains(.command):
            saveFileEdit()
            return true
        default:
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "s" {
                saveFileEdit()
                return true
            }
            return false
        }
    }

    /// Text copied out of the file editor: plain, and marked as our own write (no history item).
    func copyPlainText(_ text: String) {
        guard !text.isEmpty else { return }
        env.paste.write(text: text)
        showNotice("Copied selection")
    }
}
