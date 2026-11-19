import AppKit
import Observation
import SwiftUI

nonisolated enum PanelFilter: String, CaseIterable, Identifiable, Sendable {
    // Raw values are stored settings: `labelled` stays the Saved chip's.
    case all, labelled, thisApp, inbox
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .inbox: "Inbox"
        case .labelled: "Saved"
        case .thisApp: "This App"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .labelled: "bookmark"
        case .thisApp: "app"
        case .inbox: "tray.and.arrow.down"
        }
    }

    /// A stored filter: one whose chip is gone (Text, Images, Files, Snippets and Secrets before
    /// 1.7) or anything unknown falls back to All.
    init(storedValue: String?) {
        self = storedValue.flatMap(PanelFilter.init(rawValue:)) ?? .all
    }

    /// All · Saved · This App, then the Inbox once there are contacts.
    static let chips: [PanelFilter] = [.all, .labelled, .thisApp]
    static func chips(hasContacts: Bool) -> [PanelFilter] { hasContacts ? chips + [.inbox] : chips }
}

/// A stop in the filter row for ⇥: a chip, or one segment of a group's pill.
nonisolated enum FilterStop: Equatable, Sendable {
    case chip(PanelFilter)
    case group(String, saved: Bool)
}

enum PanelEntry: Identifiable {
    case clip(ClipItem)
    case snippet(Snippet)
    case secret(SecretRef)
    /// A Saved folder row (Saved tab only).
    case folder(ClipFolder)

    var id: String {
        switch self {
        case .clip(let item): "c-" + item.id.uuidString
        case .snippet(let snippet): "s-" + snippet.id.uuidString
        case .secret(let ref): "k-" + ref.id
        case .folder(let folder): "f-" + folder.id.uuidString
        }
    }

    var clip: ClipItem? {
        if case .clip(let item) = self { return item }
        return nil
    }

    var folder: ClipFolder? {
        if case .folder(let folder) = self { return folder }
        return nil
    }

    var secret: SecretRef? {
        if case .secret(let ref) = self { return ref }
        return nil
    }

    /// Where it sorts in Saved, newest first: when a clip was saved or last copied (the later),
    /// a secret's creation, a snippet's last edit.
    var savedDate: Date {
        switch self {
        case .clip(let item): max(item.pinnedAt ?? .distantPast, item.lastCopiedAt)
        case .snippet(let snippet): snippet.updatedAt
        case .secret(let ref): ref.createdAt ?? .distantPast
        case .folder(let folder): folder.createdAt
        }
    }

    /// Nil for folders, which can't be put on a quick slot.
    var slotTarget: SlotTarget? {
        switch self {
        case .clip(let item): .clip(item.id)
        case .snippet(let snippet): .snippet(snippet.id)
        case .secret(let ref): .secret(ref.id)
        case .folder: nil
        }
    }
}

enum PanelMode: Equatable {
    case browse
    case actions
    case snippetForm
    case saveSecret
    case label
    case editSecret
    case shareToGroup
    case ai
    /// Naming a folder: renaming one, or a new one (which may take the selection with it).
    case folderName
}

enum PanelAction: Identifiable, Hashable {
    case paste
    case pastePlain
    case copy
    case quickLook
    case transform(Transform)
    case ai(AIAction)
    case saveAsSecret
    case setLabel
    case shareToGroup
    case sendToDevice(DeviceTarget)
    case sendToContact(SyncContact)
    case setUpAI
    case clearSlot(Int)
    case removeFromLabelled
    case addToSaved
    /// A personal copy, saved at the root of Saved (a group item you can't change).
    case saveCopy
    /// Into a folder of the items' space; a personal folder for group items saves copies.
    case moveToFolder(ClipFolder)
    /// A new folder in the items' space.
    case moveToNewFolder
    /// A new personal folder, with personal copies of the (group) items.
    case copyToNewFolder
    case removeFromFolder
    case openFolder
    case renameFolder
    case deleteFolder
    case saveToFolder
    case saveToChosenFolder
    case delete

    var id: String {
        switch self {
        case .paste: "paste"
        case .pastePlain: "pastePlain"
        case .copy: "copy"
        case .quickLook: "quickLook"
        case .transform(let t): "transform-" + t.rawValue
        case .ai(let a): "ai-" + a.id
        case .saveAsSecret: "saveAsSecret"
        case .setLabel: "setLabel"
        case .shareToGroup: "shareToGroup"
        case .sendToDevice(let device): "sendToDevice-" + device.id
        case .sendToContact(let contact): "sendToContact-" + contact.id
        case .setUpAI: "setUpAI"
        case .clearSlot(let n): "clearSlot-\(n)"
        case .removeFromLabelled: "removeFromLabelled"
        case .addToSaved: "addToSaved"
        case .saveCopy: "saveCopy"
        case .moveToFolder(let folder): "moveToFolder-" + folder.id.uuidString
        case .moveToNewFolder: "moveToNewFolder"
        case .copyToNewFolder: "copyToNewFolder"
        case .removeFromFolder: "removeFromFolder"
        case .openFolder: "openFolder"
        case .renameFolder: "renameFolder"
        case .deleteFolder: "deleteFolder"
        case .saveToFolder: "saveToFolder"
        case .saveToChosenFolder: "saveToChosenFolder"
        case .delete: "delete"
        }
    }

    func section(aiName: String) -> String {
        switch self {
        case .paste, .pastePlain, .copy, .quickLook: "Paste"
        case .transform: "Transform & Paste"
        case .ai, .setUpAI: "Ask \(aiName)"
        case .sendToDevice, .sendToContact: "Send"
        case .saveToFolder, .saveToChosenFolder: "Save"
        case .addToSaved, .saveCopy, .moveToFolder, .moveToNewFolder, .copyToNewFolder, .removeFromFolder,
             .removeFromLabelled: "Saved"
        case .openFolder, .renameFolder, .deleteFolder: "Folder"
        case .saveAsSecret, .setLabel, .shareToGroup, .clearSlot, .delete: "Item"
        }
    }

    /// `folderName` is the save folder's name ("Save to Downloads").
    func title(folderName: String) -> String {
        switch self {
        case .paste: "Paste"
        case .pastePlain: "Paste as Plain Text"
        case .copy: "Copy to Clipboard"
        case .quickLook: "Quick Look"
        case .transform(let t): t.title
        case .ai(.instruction(let text)): "Ask: “\(text)”"
        case .ai(let a): a.title
        case .saveAsSecret: "Save as Secret…"
        case .setLabel: "Label…"
        case .shareToGroup: "Share to Group…"
        case .sendToDevice(let device): "Send to \(device.name)"
        case .sendToContact(let contact): "Send to \(contact.name)"
        case .setUpAI: "Set Up AI…"
        case .clearSlot(let n): "Remove from Quick Slot ⌘\(n)"
        case .removeFromLabelled: "Remove from Saved"
        case .addToSaved: "Add to Saved"
        case .saveCopy: "Save a Copy"
        case .moveToFolder(let folder): "Move to “\(folder.name)”"
        case .moveToNewFolder: "Move to New Folder…"
        case .copyToNewFolder: "Save a Copy to New Folder…"
        case .removeFromFolder: "Remove from Folder"
        case .openFolder: "Open"
        case .renameFolder: "Rename…"
        case .deleteFolder: "Delete Folder"
        case .saveToFolder: "Save to \(folderName)"
        case .saveToChosenFolder: "Save to…"
        case .delete: "Delete"
        }
    }

    var symbol: String {
        switch self {
        case .paste: "doc.on.clipboard"
        case .pastePlain: "doc.plaintext"
        case .copy: "doc.on.doc"
        case .quickLook: "eye"
        case .transform(let t): t.symbol
        case .ai(let a): a.symbol
        case .saveAsSecret: "key"
        case .setLabel: "tag"
        case .shareToGroup: "person.2"
        case .sendToDevice: "laptopcomputer.and.arrow.down"
        case .sendToContact: "paperplane"
        case .setUpAI: "sparkles"
        case .clearSlot: "number.square"
        case .removeFromLabelled: "bookmark.slash"
        case .addToSaved: "bookmark"
        case .saveCopy: "bookmark.square"
        case .moveToFolder: "folder"
        case .moveToNewFolder: "folder.badge.plus"
        case .copyToNewFolder: "folder.badge.plus"
        case .removeFromFolder: "folder.badge.minus"
        case .openFolder: "folder"
        case .renameFolder: "pencil"
        case .deleteFolder: "trash"
        case .saveToFolder: "square.and.arrow.down"
        case .saveToChosenFolder: "folder"
        case .delete: "trash"
        }
    }
}

@Observable
final class SnippetFormState {
    let snippet: Snippet
    let fields: [String]
    var values: [String: String]

    init(snippet: Snippet, fields: [String]) {
        self.snippet = snippet
        self.fields = fields
        self.values = Dictionary(uniqueKeysWithValues: fields.map { ($0, "") })
    }
}

@Observable
final class SaveSecretState {
    let item: ClipItem
    var name: String

    init(item: ClipItem) {
        self.item = item
        self.name = item.sourceAppName.map { "Password from \($0)" } ?? "New Secret"
    }
}

/// Name and value of a secret, filled in after Touch ID. The value lives only as long as the form.
@Observable
final class EditSecretState {
    let ref: SecretRef
    let originalValue: String
    var name: String
    var value: String

    init(ref: SecretRef, value: String) {
        self.ref = ref
        self.originalValue = value
        self.name = ref.name
        self.value = value
    }
}

/// Picks the sync group that the selected items are copied into.
@Observable
final class ShareGroupState {
    let items: [ClipItem]
    /// Set when sharing a secret instead of clips; its value is read (after Touch ID) only on submit.
    let secret: SecretRef?
    /// Set when sharing a Saved folder: it's copied with its clips (`items`).
    let folder: ClipFolder?
    let groups: [SyncGroup]
    var selection: Int {
        didSet { if selection != oldValue { destinationID = nil } }
    }
    /// Set when a text item looks like a password or key, so the form warns before it's shared.
    let sensitiveKind: SensitiveText.Kind?
    /// Each group's folders (by name), offered as the destination of clips and secrets.
    let foldersByGroup: [String: [ClipFolder]]
    /// The chosen group's folder the copies go in; nil is the root (the default).
    var destinationID: UUID?

    init(items: [ClipItem] = [], secret: SecretRef? = nil, folder: ClipFolder? = nil, groups: [SyncGroup],
         defaultGroupID: String?, foldersByGroup: [String: [ClipFolder]] = [:]) {
        self.items = items
        self.secret = secret
        self.folder = folder
        self.groups = groups
        self.selection = groups.firstIndex { $0.id == defaultGroupID } ?? 0
        self.sensitiveKind = items.lazy.filter(\.kind.isTextual).compactMap { SensitiveText.detect($0.text) }.first
        // A folder is copied as a folder (folders don't nest), so it has no destination.
        self.foldersByGroup = folder == nil ? foldersByGroup : [:]
    }

    var selectedGroup: SyncGroup? { groups.indices.contains(selection) ? groups[selection] : nil }

    /// The chosen group's folders: the destinations besides the root.
    var destinations: [ClipFolder] { selectedGroup.flatMap { foldersByGroup[$0.id] } ?? [] }

    /// The chosen destination, if it's (still) one of the chosen group's folders.
    var destination: ClipFolder? { destinations.first { $0.id == destinationID } }

    /// ← → walk Root, then each folder.
    func moveDestination(by delta: Int) {
        let choices: [UUID?] = [nil] + destinations.map(\.id)
        guard choices.count > 1 else { return }
        let current = choices.firstIndex { $0 == destination?.id } ?? 0
        destinationID = choices[min(max(current + delta, 0), choices.count - 1)]
    }
}

@Observable
final class LabelFormState {
    enum Target {
        case clip(ClipItem)
        case secret(SecretRef)
        case folder(ClipFolder)
    }

    let target: Target
    var text: String

    init(target: Target) {
        self.target = target
        switch target {
        case .clip(let item): text = item.label ?? ""
        case .secret(let ref): text = ref.name
        case .folder(let folder): text = folder.label ?? ""
        }
    }

    var valuePreview: String {
        switch target {
        case .clip(let item): item.preview.isEmpty ? item.kind.displayName : item.preview
        case .secret: "••••••••"
        case .folder(let folder): folder.name
        }
    }

    var isSecret: Bool {
        if case .secret = target { return true }
        return false
    }

    var isFolder: Bool {
        if case .folder = target { return true }
        return false
    }
}

/// The name of a folder being renamed or created, typed in the panel (never a dialog).
@Observable
final class FolderNameState {
    enum Purpose {
        case rename(ClipFolder)
        /// A new folder in `spaceID`; `moving` clips and `secrets` go into it (as personal copies
        /// when they're group items and the folder is personal).
        case create(spaceID: String?, moving: [ClipItem], secrets: [SecretRef] = [])
    }

    let purpose: Purpose
    var name: String

    init(purpose: Purpose) {
        self.purpose = purpose
        switch purpose {
        case .rename(let folder): name = folder.name
        case .create: name = "New Folder"
        }
    }

    var isRename: Bool {
        if case .rename = purpose { return true }
        return false
    }

    var movingCount: Int {
        if case .create(_, let moving, let secrets) = purpose { return moving.count + secrets.count }
        return 0
    }

    /// The new folder is personal and takes copies of group items.
    var copies: Bool {
        guard case .create(let space, let moving, let secrets) = purpose, space == nil else { return false }
        return moving.contains { $0.spaceID != nil } || secrets.contains { $0.spaceID != nil }
    }
}

@Observable
final class PanelViewModel {
    @ObservationIgnored let env: AppEnvironment
    @ObservationIgnored var onClose: () -> Void = {}

    var query = "" { didSet { if query != oldValue { refresh(resetSelection: true) } } }
    var filter: PanelFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            openFolderID = nil
            refresh(resetSelection: true)
            // Fetch what contacts sent since the last sync; the list refreshes when it lands.
            if filter == .inbox { env.sync.syncNow() }
        }
    }
    /// A sync group chosen in the filter row; when set it replaces `filter`.
    var groupFilter: String? {
        didSet {
            guard groupFilter != oldValue else { return }
            openFolderID = nil
            refresh(resetSelection: true)
            // Fetch what group members sent since the last sync; the list refreshes when it lands.
            if groupFilter != nil { env.sync.syncNow() }
        }
    }

    // MARK: Saved and folders

    /// The folder open in the Saved list (nil: its root).
    private(set) var openFolderID: UUID?
    /// Number of saved clips and secrets in each folder of the Saved list being shown.
    private(set) var folderCounts: [UUID: Int] = [:]
    /// Search results inside a folder, from the Saved root, by entry id: the folder's name, shown
    /// under them.
    private(set) var folderCaptions: [String: String] = [:]
    /// Groups showing their Saved items instead of their Copies (remembered per group).
    private(set) var groupsShowingSaved: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "panelGroupsShowingSaved") ?? [])

    /// The selected group pill's Copies | Saved segment.
    var groupShowsSaved: Bool {
        get { groupFilter.map(groupsShowingSaved.contains) ?? false }
        set {
            guard let groupFilter, newValue != groupShowsSaved else { return }
            if newValue { groupsShowingSaved.insert(groupFilter) } else { groupsShowingSaved.remove(groupFilter) }
            UserDefaults.standard.set(Array(groupsShowingSaved).sorted(), forKey: "panelGroupsShowingSaved")
            openFolderID = nil
            refresh(resetSelection: true)
        }
    }

    /// The list shows Saved: the Saved chip, or a group switched to Saved.
    var isSavedView: Bool {
        groupFilter == nil ? filter == .labelled && selectionItem == nil : groupShowsSaved
    }

    /// The space whose Saved items are shown (nil: personal).
    var savedSpaceID: String? { groupFilter }

    var openFolder: ClipFolder? {
        guard isSavedView, let openFolderID, let folder = env.store.folder(withID: openFolderID),
              folder.spaceID == savedSpaceID else { return nil }
        return folder
    }

    func openFolder(_ folder: ClipFolder) {
        guard isSavedView, folder.spaceID == savedSpaceID else { return }
        openFolderID = folder.id
        query = ""
        refresh(resetSelection: true)
        userMovedSelection = false
    }

    /// Back to the root of Saved, with the folder selected.
    func closeFolder() {
        guard let id = openFolderID else { return }
        openFolderID = nil
        refresh(resetSelection: true)
        if entries.contains(where: { $0.id == "f-" + id.uuidString }) { selectedID = "f-" + id.uuidString }
    }
    private(set) var entries: [PanelEntry] = []
    /// Date headings ("Today", "Yesterday"…) keyed by the first row under each; empty while searching.
    private(set) var sectionStarts: [String: String] = [:]
    /// ⌘ is down: every row shows its ⌘-number, not just the selected one.
    var isCommandHeld = false
    /// Which tip the hint bar shows; moves on with every open.
    var tipIndex = 0
    /// The focused row (drives the preview and keyboard navigation).
    var selectedID: String? {
        didSet {
            if selectedID != oldValue { clearPickedFiles() }
            guard !adjustingSelection else { return }
            selectedIDs = selectedID.map { [$0] } ?? []
            anchorID = selectedID
        }
    }
    /// Every selected row; more than one after ⌘-click, ⇧-click, ⇧-arrows or ⌘A.
    private(set) var selectedIDs: Set<String> = [] {
        didSet { if selectedIDs != oldValue { onQuickLookItemsChanged() } }
    }
    @ObservationIgnored private var anchorID: String?
    @ObservationIgnored private var adjustingSelection = false
    /// Bumped each time the panel opens so the view can refocus the search field.
    private(set) var focusToken = 0

    private(set) var mode: PanelMode = .browse {
        // Returning to the list hands keyboard focus back to the search field.
        didSet { if mode == .browse && oldValue != .browse { focusToken &+= 1 } }
    }
    var actionQuery = "" { didSet { if actionQuery != oldValue { actionSelection = 0 } } }
    var actionSelection = 0
    private(set) var snippetForm: SnippetFormState?
    private(set) var saveSecretForm: SaveSecretState?
    private(set) var labelForm: LabelFormState?
    private(set) var editSecretForm: EditSecretState?
    private(set) var shareForm: ShareGroupState?
    private(set) var folderNameForm: FolderNameState?
    private(set) var aiRun: AIRun?
    /// Transient status line ("Copied", "Not valid JSON", …).
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    /// The app that was frontmost when the panel opened — pastes go here.
    private(set) var targetApp: NSRunningApplication?
    var targetRef: AppRef? { targetApp.flatMap(FrontmostAppTracker.ref(for:)) }

    static let maxEntries = 300

    init(env: AppEnvironment) {
        self.env = env
        quickLookFiles = QuickLookFiles(blobs: env.blobs, directory: AppPaths.quickLookDirectory)
    }

    // MARK: Lifecycle

    /// Text selected in another app (via ⌥⌘K or the Services menu). It's a transient item:
    /// never saved to history unless the user explicitly saves it.
    private(set) var selectionItem: ClipItem?

    var isSelectionMode: Bool { selectionItem != nil }

    func prepareForSelection(_ text: String, target: NSRunningApplication?) {
        prepareForOpen(target: target)
        let item = ClipItem(capture: .text(text, source: target.flatMap(FrontmostAppTracker.ref(for:))))
        selectionItem = item
        entries = [.clip(item)]
        selectedID = PanelEntry.clip(item).id
        actionQuery = ""
        mode = .actions
    }

    func prepareForOpen(target: NSRunningApplication?) {
        selectionItem = nil
        resetMode()
        notice = nil
        targetApp = target
        query = ""
        // Back to All without the group pill animating closed behind the opening panel.
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            filter = .all
            groupFilter = nil
        }
        openFolderID = nil
        userMovedSelection = false
        isCommandHeld = false
        tipIndex &+= 1
        env.sync.periodicSync()
        refresh(resetSelection: true)
        focusToken &+= 1
        openToken &+= 1
    }

    /// Bumped on every open so the list scrolls back to the top.
    private(set) var openToken = 0
    /// Until the user moves the selection, it stays on the newest item — even when a copy made
    /// just before opening lands a moment later.
    @ObservationIgnored private var userMovedSelection = false

    func didClose() {
        flushEditor?()
        isEditingText = false
        selectionItem = nil
        clearPickedFiles()
        resetMode()
    }

    // MARK: Picking files of a multi-file item

    /// Files chosen in the preview of the selected multi-file item. While some (not all) are
    /// chosen, paste, copy, save and drag use only those; the item itself is unchanged.
    private(set) var pickedFiles: Set<URL> = [] {
        didSet { if pickedFiles != oldValue { onQuickLookItemsChanged() } }
    }
    @ObservationIgnored private var pickedFileAnchor: URL?

    /// Click toggles a file, ⇧-click adds the range from the last clicked one.
    func clickFile(_ url: URL, in item: ClipItem) {
        if NSEvent.modifierFlags.contains(.shift) {
            extendPickedFiles(to: url, in: item)
        } else {
            togglePickedFile(url)
        }
    }

    func togglePickedFile(_ url: URL) {
        if pickedFiles.contains(url) { pickedFiles.remove(url) } else { pickedFiles.insert(url) }
        pickedFileAnchor = url
    }

    func extendPickedFiles(to url: URL, in item: ClipItem) {
        let urls = item.fileURLs
        guard let anchor = pickedFileAnchor, let from = urls.firstIndex(of: anchor), let to = urls.firstIndex(of: url) else {
            togglePickedFile(url)
            return
        }
        pickedFiles.formUnion(urls[min(from, to)...max(from, to)])
        pickedFileAnchor = url
    }

    func clearPickedFiles() {
        if !pickedFiles.isEmpty { pickedFiles = [] }
        pickedFileAnchor = nil
    }

    /// The chosen files of `item` in item order, or nil when the whole item applies (nothing or
    /// everything chosen, another item, or several rows selected).
    func pickedFileURLs(for item: ClipItem) -> [URL]? {
        guard !pickedFiles.isEmpty, item.kind == .file, !isMultiSelecting, selectedEntry?.clip?.id == item.id else { return nil }
        let urls = item.fileURLs.filter(pickedFiles.contains)
        return urls.isEmpty || urls.count == item.fileURLs.count ? nil : urls
    }

    /// "2 of 3" for the footer and the preview while a subset is chosen.
    var pickedFileCount: (picked: Int, total: Int)? {
        guard let item = selectedEntry?.clip, let urls = pickedFileURLs(for: item) else { return nil }
        return (urls.count, item.fileURLs.count)
    }

    /// Copies the item, or just its chosen files.
    func copy(_ item: ClipItem) {
        if let files = pickedFileURLs(for: item) {
            env.paste.write(fileURLs: files)
        } else {
            env.paste.copy(item)
        }
    }

    // MARK: Editing the previewed text

    /// The preview's text editor has keyboard focus (keys go to it, not the list).
    var isEditingText = false
    /// Bumped by ⌘E to move keyboard focus into the editor.
    private(set) var editorFocusToken = 0
    /// Set by the editor: saves pending edits now (before pasting or closing).
    @ObservationIgnored var flushEditor: (() -> Void)?
    /// Set by the editor: styles the selection (style bar and ⌘B/⌘I/⌘U).
    @ObservationIgnored var applyStyle: (TextStyle) -> Void = { _ in }

    /// Only this account's own plain text items: transient selections aren't saved, group items
    /// belong to everyone in the group, and recognised content (a color, a link, JSON, a password…)
    /// keeps its own preview.
    func isEditable(_ item: ClipItem) -> Bool {
        item.kind.isTextual && !item.isTransient && item.spaceID == nil && ClipContentCache.content(of: item) == .plain
    }

    func beginEditing() {
        guard let item = selectedEntry?.clip, isEditable(item), !isMultiSelecting else { return }
        editorFocusToken &+= 1
    }

    /// Saves and hands the keyboard back to the search field and list.
    func endEditing() {
        flushEditor?()
        isEditingText = false
        focusToken &+= 1
    }

    func saveEdit(_ item: ClipItem, text: String, rtf: Data?, html: Data?) {
        env.store.editText(of: item, text: text, rtf: rtf, html: html)
    }

    /// Keys while the editor has focus: everything is typing except leaving and pasting.
    func handleEditorKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case KeyCode.escape:
            endEditing()
            return true
        case KeyCode.returnKey where flags.contains(.command), KeyCode.keypadEnter where flags.contains(.command):
            flushEditor?()
            isEditingText = false
            activate(selectedEntry, transform: flags.contains(.option) ? .plainText : nil)
            return true
        default:
            return false
        }
    }

    func resetMode() {
        aiRun?.cancel()
        aiRun = nil
        snippetForm = nil
        saveSecretForm = nil
        labelForm = nil
        editSecretForm = nil
        shareForm = nil
        folderNameForm = nil
        actionQuery = ""
        actionSelection = 0
        mode = .browse
        focusToken &+= 1
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func refresh(resetSelection: Bool = false) {
        if let selectionItem {
            entries = [.clip(selectionItem)]
            selectedID = PanelEntry.clip(selectionItem).id
            return
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetBundle = targetApp?.bundleIdentifier

        var clips: [ClipItem] = []
        var folders: [ClipFolder] = []
        var snippets: [Snippet] = []
        var secrets: [SecretRef] = []
        folderCaptions = [:]
        let savedView = isSavedView
        if savedView {
            // Saved: everything one space keeps. Folder rows first (by name), then its saved clips,
            // secrets and snippets mixed, newest first; inside a folder only its clips and secrets.
            // Searching from the root finds what's in folders too, captioned with the folder's name.
            let all = env.store.folders(inSpace: savedSpaceID)
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let saved = env.store.items(inSpace: savedSpaceID).filter(\.isPinned)
            let spaceSecrets = env.secrets.secrets.filter { $0.spaceID == savedSpaceID }
            if let open = openFolderID, byID[open] == nil { openFolderID = nil }   // deleted meanwhile
            var counts: [UUID: Int] = [:]
            for id in saved.compactMap(\.folderID) + spaceSecrets.compactMap(\.folderID) where byID[id] != nil {
                counts[id, default: 0] += 1
            }
            folderCounts = counts
            if let open = openFolderID {
                clips = saved.filter { $0.folderID == open }
                secrets = spaceSecrets.filter { $0.folderID == open }
            } else {
                folders = all
                snippets = env.snippets.snippets(inSpace: savedSpaceID)
                if q.isEmpty {
                    clips = saved.filter { $0.folderID.flatMap { byID[$0] } == nil }
                    secrets = spaceSecrets.filter { $0.folderID.flatMap { byID[$0] } == nil }
                } else {
                    clips = saved
                    secrets = spaceSecrets
                    for item in saved {
                        if let id = item.folderID, let folder = byID[id] { folderCaptions[PanelEntry.clip(item).id] = folder.name }
                    }
                    for ref in spaceSecrets {
                        if let id = ref.folderID, let folder = byID[id] { folderCaptions[PanelEntry.secret(ref).id] = folder.name }
                    }
                }
            }
        } else if let groupFilter {
            clips = env.store.allItems().filter { $0.spaceID == groupFilter }
        } else {
            // What contacts send lives in the Inbox only; what you sent them isn't listed again.
            clips = env.store.allItems().filter { item in
                guard env.sync.isListed(item, inInbox: filter == .inbox) else { return false }
                return switch filter {
                case .all, .inbox: true
                case .labelled: item.isPinned
                case .thisApp: targetBundle != nil && item.sourceBundleID == targetBundle
                }
            }
            // Snippets and secrets join "All" only while searching, so history stays uncluttered.
            if filter == .all && !q.isEmpty {
                snippets = env.snippets.all()
                secrets = env.secrets.secrets
            }
        }

        var result: [PanelEntry]
        if q.isEmpty && savedView {
            let kept = clips.map(PanelEntry.clip) + secrets.map(PanelEntry.secret) + snippets.map(PanelEntry.snippet)
            result = folders.map(PanelEntry.folder) + kept.sorted { $0.savedDate > $1.savedDate }
        } else if q.isEmpty {
            result = clips.map(PanelEntry.clip) + snippets.map(PanelEntry.snippet) + secrets.map(PanelEntry.secret)
        } else {
            var scored: [(PanelEntry, Int, Date)] = []
            for folder in folders {
                // Folders whose name matches come first.
                if let s = FuzzyMatcher.score(query: q, in: folder.name + (folder.label.map { " " + $0 } ?? "")) {
                    scored.append((.folder(folder), s + 1_000, folder.createdAt))
                }
            }
            for item in clips {
                if let s = FuzzyMatcher.score(query: q, in: item.searchableText) {
                    scored.append((.clip(item), s, item.lastCopiedAt))
                }
            }
            let lowered = q.lowercased()
            for snippet in snippets {
                let keywordHit = !snippet.keyword.isEmpty && snippet.keyword.lowercased() == lowered
                let haystack = snippet.name + " " + snippet.keyword + " " + snippet.body
                if let s = FuzzyMatcher.score(query: q, in: haystack) {
                    scored.append((.snippet(snippet), s + (keywordHit ? 10_000 : 0), snippet.updatedAt))
                } else if keywordHit {
                    scored.append((.snippet(snippet), 10_000, snippet.updatedAt))
                }
            }
            for secret in secrets {
                // Only names are searchable — values never leave the keychain for search.
                if let s = FuzzyMatcher.score(query: q, in: secret.name) {
                    scored.append((.secret(secret), s + 500, secret.createdAt ?? .distantPast))
                }
            }
            scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 > $1.2 }
            result = scored.map(\.0)
        }

        entries = Array(result.prefix(Self.maxEntries))
        sectionStarts = q.isEmpty ? Self.dateSections(entries, date: savedView ? { $0.folder == nil ? $0.savedDate : nil }
                                                                         : { $0.clip?.lastCopiedAt }) : [:]
        if resetSelection || !userMovedSelection || !entries.contains(where: { $0.id == selectedID }) {
            selectedID = entries.first?.id
        } else {
            let live = Set(entries.map(\.id))
            setSelection(selectedIDs.intersection(live), focus: selectedID)
        }
    }

    /// Today, Yesterday, This Week, Earlier: the first row of each, in list (newest-first) order.
    private static func dateSections(_ entries: [PanelEntry], date entryDate: (PanelEntry) -> Date?,
                                     now: Date = .now) -> [String: String] {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)) ?? now
        var starts: [String: String] = [:]
        var current: String?
        for entry in entries {
            guard let date = entryDate(entry) else { continue }
            let title = calendar.isDateInToday(date) ? "Today"
                : calendar.isDateInYesterday(date) ? "Yesterday"
                : date >= weekAgo ? "This Week" : "Earlier"
            if title != current {
                starts[entry.id] = title
                current = title
            }
        }
        return starts
    }

    // MARK: Selection

    var selectedIndex: Int? { entries.firstIndex { $0.id == selectedID } }

    var selectedEntry: PanelEntry? {
        selectedIndex.map { entries[$0] }
    }

    func moveSelection(by delta: Int, extending: Bool = false) {
        guard !entries.isEmpty else { return }
        userMovedSelection = true
        let current = selectedIndex ?? (delta > 0 ? -1 : entries.count)
        let next = min(max(current + delta, 0), entries.count - 1)
        if extending {
            extendSelection(to: entries[next].id)
        } else {
            selectedID = entries[next].id
        }
    }

    // MARK: Multi-selection

    var isMultiSelecting: Bool { selectedIDs.count > 1 }

    /// Selected history items in list order (snippets and secrets are single-select only).
    var selectedClips: [ClipItem] {
        entries.compactMap { selectedIDs.contains($0.id) ? $0.clip : nil }
    }

    /// Selected secrets in list order (they can be moved between folders together).
    var selectedSecrets: [SecretRef] {
        entries.compactMap { selectedIDs.contains($0.id) ? $0.secret : nil }
    }

    func isSelected(_ entry: PanelEntry) -> Bool { selectedIDs.contains(entry.id) }

    /// Mouse selection following macOS conventions: ⌘ toggles, ⇧ selects a range.
    func click(_ entry: PanelEntry) {
        userMovedSelection = true
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            toggleSelection(entry.id)
        } else if flags.contains(.shift) {
            extendSelection(to: entry.id)
        } else {
            selectedID = entry.id
        }
    }

    func toggleSelection(_ id: String) {
        var ids = selectedIDs
        if ids.contains(id), ids.count > 1 {
            ids.remove(id)
            let focus = id == selectedID ? entries.first { ids.contains($0.id) }?.id : selectedID
            setSelection(ids, focus: focus)
        } else {
            ids.insert(id)
            setSelection(ids, focus: id)
        }
        anchorID = id
    }

    func extendSelection(to id: String) {
        guard let anchor = anchorID ?? selectedID,
              let from = entries.firstIndex(where: { $0.id == anchor }),
              let to = entries.firstIndex(where: { $0.id == id })
        else {
            selectedID = id
            return
        }
        let range = min(from, to)...max(from, to)
        setSelection(Set(entries[range].map(\.id)), focus: id)
    }

    func selectAll() {
        guard let first = entries.first else { return }
        anchorID = first.id
        setSelection(Set(entries.map(\.id)), focus: selectedID ?? first.id)
    }

    private func setSelection(_ ids: Set<String>, focus: String?) {
        adjustingSelection = true
        selectedIDs = ids
        selectedID = focus
        adjustingSelection = false
    }

    func pasteSelection(transform: Transform? = nil) {
        let clips = selectedClips
        guard !clips.isEmpty else { return }
        if clips.count == 1 {
            activate(.clip(clips[0]), transform: transform)
            return
        }
        let target = targetApp
        onClose()
        env.paste.paste(clips, transform: transform, into: target)
    }

    func deleteSelectedClips() {
        let clips = selectedClips
        guard !clips.isEmpty else { return }
        let firstIndex = entries.firstIndex { selectedIDs.contains($0.id) } ?? 0
        for item in clips {
            env.slots.remove(target: .clip(item.id))
            env.store.delete(item)
        }
        refresh()
        if !entries.isEmpty { selectedID = entries[min(firstIndex, entries.count - 1)].id }
        showNotice("Deleted \(clips.count) items")
    }

    /// The filter row as ⇥ walks it: each chip (the Inbox once there are contacts), then each
    /// group's Copies and Saved.
    var filterStops: [FilterStop] {
        PanelFilter.chips(hasContacts: !env.sync.contacts.isEmpty).map(FilterStop.chip)
            + env.sync.groups.flatMap { [FilterStop.group($0.id, saved: false), .group($0.id, saved: true)] }
    }

    var currentStop: FilterStop {
        groupFilter.map { .group($0, saved: groupShowsSaved) } ?? .chip(filter)
    }

    func select(_ stop: FilterStop) {
        switch stop {
        case .chip(let chip):
            groupFilter = nil
            filter = chip
        case .group(let id, let saved):
            groupFilter = id
            filter = .all
            groupShowsSaved = saved
        }
    }

    /// ⇥ walks the filter row: the chips, then Copies → Saved → the next group.
    func cycleFilter(forward: Bool) {
        let stops = filterStops
        let current = stops.firstIndex(of: currentStop) ?? 0
        select(stops[(current + (forward ? 1 : stops.count - 1)) % stops.count])
    }

    // MARK: Quick slots

    /// The ⌘-number shown on a row: its assigned slot, or its position if that number is unassigned.
    func shortcutNumber(for entry: PanelEntry, at index: Int) -> (number: Int, isSlot: Bool)? {
        guard let target = entry.slotTarget else { return nil }
        if let slot = env.slots.slot(for: target) { return (slot, true) }
        let position = index + 1
        guard position <= 9, env.slots.target(for: position) == nil else { return nil }
        return (position, false)
    }

    /// ⌘N: the item assigned to slot N, otherwise the Nth row.
    func activateShortcut(_ number: Int, transform: Transform? = nil) {
        if let entry = env.slots.entry(for: number) {
            activate(entry, transform: transform)
        } else if entries.indices.contains(number - 1) {
            activate(entries[number - 1], transform: transform)
        }
    }

    func assignSelection(toSlot number: Int) {
        guard let entry = selectedEntry else { return }
        env.slots.assign(entry, to: number)
        refresh()
        showNotice("Assigned to ⌘\(number)")
    }

    // MARK: Activation

    /// Pastes text made from the selection (a color as RGB, a phone number's digits) into the target app.
    func pasteText(_ text: String) {
        let target = targetApp
        onClose()
        env.paste.paste(text: text, into: target)
    }

    func activate(_ entry: PanelEntry?, transform: Transform? = nil) {
        guard let entry else { return }
        flushEditor?()
        switch entry {
        case .clip(let item):
            let target = targetApp
            let files = pickedFileURLs(for: item)
            onClose()
            if let files {
                env.paste.paste(fileURLs: files, into: target)
            } else {
                env.paste.paste(item, transform: transform, into: target)
            }
        case .snippet(let snippet):
            let fields = SnippetExpander.customFields(in: snippet.body)
            if fields.isEmpty {
                let target = targetApp
                onClose()
                env.pasteSnippet(snippet, values: [:], into: target)
            } else {
                snippetForm = SnippetFormState(snippet: snippet, fields: fields)
                mode = .snippetForm
            }
        case .secret(let ref):
            let target = targetApp
            onClose()
            env.pasteSecret(ref, into: target)
        case .folder(let folder):
            openFolder(folder)
        }
    }

    func submitSnippetForm() {
        guard let form = snippetForm else { return }
        let target = targetApp
        onClose()
        env.pasteSnippet(form.snippet, values: form.values, into: target)
    }

    func beginLabel(_ entry: PanelEntry) {
        selectedID = entry.id
        switch entry {
        case .clip(let item): labelForm = LabelFormState(target: .clip(item))
        case .secret(let ref): labelForm = LabelFormState(target: .secret(ref))
        case .folder(let folder): labelForm = LabelFormState(target: .folder(folder))
        case .snippet: return
        }
        mode = .label
    }

    func submitLabel() {
        guard let form = labelForm else { return }
        switch form.target {
        case .clip(let item):
            // A quick slot keeps its item even without a label.
            env.store.setLabel(form.text, for: item, keepPinned: env.slots.slot(for: .clip(item.id)) != nil)
            showNotice(item.label == nil ? "Label removed" : "Labelled")
        case .folder(let folder):
            env.store.setLabel(form.text, for: folder)
            showNotice(folder.label == nil ? "Label removed" : "Labelled")
        case .secret(let ref):
            let name = form.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            env.secrets.rename(ref, to: name)
        }
        let id = selectedID
        resetMode()
        refresh()
        selectedID = id
    }

    func beginEditSecret(_ ref: SecretRef) {
        selectedID = PanelEntry.secret(ref).id
        Task {
            guard let value = await env.secrets.reveal(ref, reason: "edit “\(ref.name)”") else { return }
            showEditSecret(ref, value: value)
        }
    }

    /// Opens the edit form once the value has been unlocked.
    func showEditSecret(_ ref: SecretRef, value: String) {
        editSecretForm = EditSecretState(ref: ref, value: value)
        mode = .editSecret
    }

    func submitEditSecret() {
        guard let form = editSecretForm else { return }
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !form.value.isEmpty else { return }
        if name != form.ref.name { env.secrets.rename(form.ref, to: name) }
        if form.value != form.originalValue { env.secrets.setValue(form.value, for: form.ref) }
        let id = selectedID
        resetMode()
        refresh()
        selectedID = id
        showNotice("Saved “\(name)”")
    }

    func beginSaveSecret(_ item: ClipItem) {
        selectedID = PanelEntry.clip(item).id
        saveSecretForm = SaveSecretState(item: item)
        mode = .saveSecret
    }

    func submitSaveSecret() {
        guard let form = saveSecretForm else { return }
        let name = form.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, env.secrets.add(name: name, value: form.item.text) != nil else {
            showNotice("Couldn't save to the Keychain")
            return
        }
        if !form.item.isTransient { env.store.delete(form.item) }
        resetMode()
        refresh()
        showNotice("Saved “\(name)” to Secrets and removed it from history")
    }

    // MARK: Share to group

    var canShareToGroup: Bool { env.sync.isSignedIn && !env.sync.groups.isEmpty }

    func beginShare(_ items: [ClipItem]) {
        guard canShareToGroup, !items.isEmpty else { return }
        shareForm = ShareGroupState(items: items, groups: env.sync.groups, defaultGroupID: env.prefs.syncDefaultGroupID,
                                    foldersByGroup: groupFolders)
        mode = .shareToGroup
    }

    /// Every group's folders, for the share form's destination.
    private var groupFolders: [String: [ClipFolder]] {
        Dictionary(env.sync.groups.map { ($0.id, env.store.folders(inSpace: $0.id)) }, uniquingKeysWith: { first, _ in first })
    }

    func submitShare() {
        guard let form = shareForm, let group = form.selectedGroup else { return }
        let destination = form.destination
        resetMode()
        if let ref = form.secret {
            Task {
                guard let value = await env.secrets.reveal(ref, reason: "share “\(ref.name)” with \(group.name)") else { return }
                shareSecret(ref, value: value, to: group, folder: destination)
            }
        } else if let folder = form.folder {
            share(folder, to: group)
        } else {
            share(form.items, to: group, folder: destination)
        }
    }

    /// Share to Group… on a personal folder: picks the group, then copies the folder and its clips.
    func beginShareFolder(_ folder: ClipFolder) {
        guard canShareToGroup, folder.spaceID == nil else { return }
        selectedID = PanelEntry.folder(folder).id
        shareForm = ShareGroupState(items: env.store.items(inFolder: folder), folder: folder, groups: env.sync.groups,
                                    defaultGroupID: env.prefs.syncDefaultGroupID)
        mode = .shareToGroup
    }

    /// Copies a personal folder (new id, same name and label) and copies of its clips and
    /// secrets into the group. Yours stays as it is; later changes don't follow. Secrets are read
    /// after Touch ID.
    func share(_ folder: ClipFolder, to group: SyncGroup) {
        let items = env.store.items(inFolder: folder)
        if let problem = items.lazy.compactMap(SyncEngine.groupShareProblem).first {
            refuseGroupShare(problem)
            return
        }
        let secrets = env.secrets.secrets(inFolder: folder)
        let finish = { [self] (values: [(SecretRef, String)]) in
            let copy = env.store.shareCopy(of: folder, toSpace: group.id)
            for (ref, value) in values { env.secrets.add(name: ref.name, value: value, spaceID: group.id, folderID: copy.id) }
            env.sync.syncNow()
            refresh()
            showNotice("Shared “\(folder.name)” to \(group.name)")
        }
        guard !secrets.isEmpty else {
            finish([])
            return
        }
        Task {
            guard await env.secrets.authenticate(reason: "share “\(folder.name)” with \(group.name)") else { return }
            finish(secrets.compactMap { ref in SecretVault.value(id: ref.id).map { (ref, $0) } })
        }
    }

    func beginShareSecret(_ ref: SecretRef) {
        let groups = env.sync.groups.filter { $0.id != ref.spaceID }
        guard canShareToGroup, !groups.isEmpty else { return }
        selectedID = PanelEntry.secret(ref).id
        shareForm = ShareGroupState(secret: ref, groups: groups, defaultGroupID: env.prefs.syncDefaultGroupID,
                                    foldersByGroup: groupFolders)
        mode = .shareToGroup
    }

    /// Stores a copy of the secret in the group's space (in one of its folders, if given). Yours
    /// stays as it is; later edits don't follow.
    func shareSecret(_ ref: SecretRef, value: String, to group: SyncGroup, folder: ClipFolder? = nil) {
        let folder = folder?.spaceID == group.id ? folder : nil
        let existing = env.secrets.secrets.first {
            $0.spaceID == group.id && $0.name == ref.name && SecretVault.value(id: $0.id) == value
        }
        let already = existing != nil
        if let existing, let folder, existing.folderID != folder.id, env.sync.canChange(itemID: existing.id, spaceID: group.id) {
            env.secrets.setFolder(folder.id, for: [existing])
            env.sync.syncNow()
        }
        if !already {
            guard env.secrets.add(name: ref.name, value: value, spaceID: group.id, folderID: folder?.id) != nil else {
                showNotice("Couldn't save to the Keychain")
                return
            }
            env.sync.syncNow()
            refresh()
        }
        showNotice(already ? "“\(ref.name)” is already in \(group.name)" : "Shared “\(ref.name)” with \(group.name)")
    }

    /// Copies items into a group's space with new ids (selected text from another app is stored
    /// there); with `folder` (one of the group's), the copies go in it.
    func share(_ items: [ClipItem], to group: SyncGroup, folder: ClipFolder? = nil) {
        if let problem = items.lazy.compactMap(SyncEngine.groupShareProblem).first {
            refuseGroupShare(problem)
            return
        }
        let copies = copy(items, intoSpace: group.id)
        if let folder, folder.spaceID == group.id {
            // Copies that were already in the group (same content) only move if this account may change them.
            env.store.move(copies.filter { env.sync.canChange($0) }, to: folder)
        }
        if isSelectionMode {
            onClose()
            HUD.show("Sent to \(group.name)", symbol: "person.2.fill")
        } else {
            refresh()
            showNotice(items.count == 1 ? "Shared to \(group.name)" : "Shared \(items.count) items to \(group.name)")
        }
    }

    /// Stores copies in a group's or contact's space; the next sync uploads them. A contact gets
    /// them without this user's labels. Returns the copies.
    @discardableResult
    private func copy(_ items: [ClipItem], intoSpace spaceID: String, keepLabel: Bool = true) -> [ClipItem] {
        var copies: [ClipItem] = []
        for item in items {
            if item.isTransient {
                copies.append(env.store.ingest(.text(item.text, source: item.source), spaceID: spaceID))
            } else if item.spaceID != spaceID {
                copies.append(env.store.shareCopy(of: item, toSpace: spaceID, keepLabel: keepLabel))
            }
        }
        env.sync.syncNow()
        return copies
    }

    // MARK: Send to contact

    /// Contacts the selection can be sent to (established ones: both people are in the space).
    var sendableContacts: [SyncContact] { env.sync.isSignedIn ? env.sync.contacts : [] }

    /// "Send to ‹contact›" rows, one per contact, for saved and transient items alike.
    var sendToContactActions: [PanelAction] { sendableContacts.map(PanelAction.sendToContact) }

    /// Puts copies of the items in the contact's space: they show up in the contact's Inbox. Same
    /// limits as sharing to a group.
    func send(_ items: [ClipItem], to contact: SyncContact) {
        guard !items.isEmpty else { return }
        if let problem = items.lazy.compactMap(SyncEngine.groupShareProblem).first {
            refuseGroupShare(problem.replacingOccurrences(of: "Groups take", with: "Sync takes"))
            return
        }
        copy(items, intoSpace: contact.id, keepLabel: false)
        if isSelectionMode {
            onClose()
            HUD.show("Sent to \(contact.name)", symbol: "paperplane.fill")
        } else {
            if mode == .actions { mode = .browse }
            refresh()
            showNotice(items.count == 1 ? "Sent to \(contact.name)" : "Sent \(items.count) items to \(contact.name)")
        }
    }

    /// Nothing is shared; the reason shows big enough not to be missed.
    private func refuseGroupShare(_ problem: String) {
        NSSound.beep()
        if mode == .actions || mode == .shareToGroup { mode = .browse }
        HUD.show(problem, symbol: "exclamationmark.triangle.fill", duration: .seconds(3.5))
        showNotice("Not shared")
    }

    // MARK: Send to device

    func send(_ item: ClipItem, to device: DeviceTarget) {
        if let problem = SyncEngine.groupShareProblem(item) {
            refuseGroupShare(problem.replacingOccurrences(of: "Groups take", with: "Sync takes"))
            return
        }
        env.sync.sendToDevice(item, deviceId: device.id)
        if mode == .actions { mode = .browse }
        showNotice("Sent to \(device.name)")
    }

    // MARK: Save to folder

    /// True while the folder picker is up, so the panel doesn't close when it loses focus.
    @ObservationIgnored private(set) var isChoosingFolder = false
    /// Set by the controller: makes the panel key again (after the folder picker).
    @ObservationIgnored var onRefocus: () -> Void = {}

    /// The clips a context-menu action on `entry` applies to: the whole selection if it's part of one.
    func clipsForContextAction(on entry: PanelEntry) -> [ClipItem] {
        guard let item = entry.clip else { return [] }
        return isMultiSelecting && isSelected(entry) ? selectedClips : [item]
    }

    /// The clips and secrets a context-menu action on `entry` applies to: the whole selection if
    /// it's part of one.
    func itemsForContextAction(on entry: PanelEntry) -> (clips: [ClipItem], secrets: [SecretRef]) {
        if isMultiSelecting && isSelected(entry) { return (selectedClips.filter { !$0.isTransient }, selectedSecrets) }
        return (entry.clip.flatMap { $0.isTransient ? nil : [$0] } ?? [], entry.secret.map { [$0] } ?? [])
    }

    /// Writes the items into `folder` as files and says how it went. The panel stays open, like Copy.
    func save(_ items: [ClipItem], to folder: URL) {
        guard !items.isEmpty else { return }
        if mode == .actions { mode = .browse }
        let outcome = FolderSaver(blobs: env.blobs).save(items, to: folder) { self.pickedFileURLs(for: $0) ?? $0.fileURLs }
        let name = FileManager.default.displayName(atPath: folder.path)
        let saved = outcome.saved.count
        if outcome.failures.isEmpty {
            showNotice(saved == 1 ? "Saved to \(name)" : "Saved \(saved) files to \(name)")
        } else if saved == 0 {
            NSSound.beep()
            showNotice("Not saved: \(outcome.failures[0])")
        } else {
            showNotice("Saved \(saved) to \(name) · \(outcome.failures.count) failed: \(outcome.failures[0])")
        }
    }

    /// Asks for a folder first (starting in the usual save folder).
    func saveChoosingFolder(_ items: [ClipItem]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = env.prefs.saveFolder
        panel.prompt = "Save"
        panel.message = items.count == 1 ? "Choose where to save this item" : "Choose where to save \(items.count) items"
        isChoosingFolder = true
        NSApp.activate()
        let response = panel.runModal()
        isChoosingFolder = false
        onRefocus()
        guard response == .OK, let folder = panel.url else { return }
        save(items, to: folder)
    }

    // MARK: Quick Look

    /// Writes text items out for Quick Look and finds the files of the rest.
    @ObservationIgnored var quickLookFiles: QuickLookFiles
    /// Set by the controller: whether the Quick Look panel is up.
    @ObservationIgnored var isQuickLookOpen: () -> Bool = { false }
    /// Set by the controller: shows (true) or closes (false) the Quick Look panel.
    @ObservationIgnored var onQuickLook: (Bool) -> Void = { _ in }
    /// Set by the controller: the selection (or the files picked in it) changed, so an open
    /// Quick Look panel follows it.
    @ObservationIgnored var onQuickLookItemsChanged: () -> Void = {}

    /// Selected entries in list order; snippets and secrets are never previewed.
    private var quickLookEntries: [PanelEntry] {
        if isMultiSelecting { return selectedClips.map(PanelEntry.clip) }
        return selectedEntry.map { [$0] } ?? []
    }

    /// Something in the selection can be shown in Quick Look (⌘Y).
    var canQuickLook: Bool {
        quickLookEntries.contains { entry in
            entry.clip.map { !$0.isTransient } == true && quickLookFiles.canPreview(entry)
        }
    }

    /// What Quick Look shows for the selection: every selected item, and only the picked files
    /// of a multi-file item.
    func quickLookURLs() -> [URL] {
        let entries = quickLookEntries.filter { $0.clip?.isTransient == false }
        return quickLookFiles.urls(for: entries) { self.pickedFileURLs(for: $0) ?? $0.fileURLs }
    }

    /// ⌘Y: opens Quick Look on the selection, or closes it.
    func toggleQuickLook() {
        if isQuickLookOpen() {
            onQuickLook(false)
        } else if canQuickLook {
            if mode == .actions { mode = .browse }
            onQuickLook(true)
        } else {
            NSSound.beep()
        }
    }

    /// The row menu's Quick Look: previews the row (with the rest of the selection, if it's part of one).
    func quickLook(_ entry: PanelEntry) {
        if !isSelected(entry) { selectedID = entry.id }
        if !isQuickLookOpen() { toggleQuickLook() }
    }

    // MARK: Drag and drop

    /// Called after a drop was accepted, so the panel takes keyboard focus back (a drag from
    /// Finder makes Finder the key app on the way in).
    @ObservationIgnored var onDropFinished: () -> Void = {}

    /// A history item dragged onto a group chip: share it (with the rest of the selection, if it
    /// was part of one) to that group.
    @discardableResult
    func dropClip(id: UUID, onGroup groupID: String) -> Bool {
        guard canShareToGroup, let group = env.sync.groups.first(where: { $0.id == groupID }),
              let item = env.store.item(withID: id)
        else { return false }
        let dragged = PanelEntry.clip(item).id
        let items = isMultiSelecting && selectedIDs.contains(dragged) ? selectedClips : [item]
        let toShare = items.filter { $0.spaceID != group.id }
        onDropFinished()
        guard !toShare.isEmpty else {
            showNotice("Already in \(group.name)")
            return true
        }
        share(toShare, to: group)
        return true
    }

    /// The dragged row's clips and secrets, with the rest of the selection if it was part of one.
    private func dragged(_ reference: PanelDrag.Reference) -> (clips: [ClipItem], secrets: [SecretRef]) {
        let entry: PanelEntry
        switch reference {
        case .clip(let id):
            guard let item = env.store.item(withID: id) else { return ([], []) }
            entry = .clip(item)
        case .secret(let id):
            guard let ref = env.secrets.secrets.first(where: { $0.id == id }) else { return ([], []) }
            entry = .secret(ref)
        }
        if isMultiSelecting && selectedIDs.contains(entry.id) { return (selectedClips, selectedSecrets) }
        return (entry.clip.map { [$0] } ?? [], entry.secret.map { [$0] } ?? [])
    }

    /// Clips dragged onto a folder row: they move in (only clips of the folder's own space).
    @discardableResult
    func dropClip(id: UUID, onFolder folderID: UUID) -> Bool {
        drop(.clip(id), onFolder: folderID)
    }

    /// Clips and secrets dragged onto a folder row: they move in.
    @discardableResult
    func drop(_ reference: PanelDrag.Reference, onFolder folderID: UUID) -> Bool {
        guard let folder = env.store.folder(withID: folderID) else { return false }
        onDropFinished()
        let (clips, secrets) = dragged(reference)
        place(clips, secrets: secrets, in: folder)
        return true
    }

    /// Clips dragged onto the "Saved" breadcrumb from inside a folder: out to the root.
    @discardableResult
    func dropClipOnSavedRoot(id: UUID) -> Bool {
        dropOnSavedRoot(.clip(id))
    }

    @discardableResult
    func dropOnSavedRoot(_ reference: PanelDrag.Reference) -> Bool {
        let (clips, secrets) = dragged(reference)
        onDropFinished()
        let inFolders = (clips.filter { $0.folderID != nil }, secrets.filter { $0.folderID != nil })
        guard !inFolders.0.isEmpty || !inFolders.1.isEmpty else { return false }
        removeFromFolder(inFolders.0, secrets: inFolders.1)
        return true
    }

    /// A secret dragged onto a group chip: shared there after Touch ID.
    @discardableResult
    func dropSecret(id: String, onGroup groupID: String) -> Bool {
        guard canShareToGroup, let group = env.sync.groups.first(where: { $0.id == groupID }),
              let ref = env.secrets.secrets.first(where: { $0.id == id })
        else { return false }
        onDropFinished()
        guard ref.spaceID != group.id else {
            showNotice("Already in \(group.name)")
            return true
        }
        Task {
            guard let value = await env.secrets.reveal(ref, reason: "share “\(ref.name)” with \(group.name)") else { return }
            shareSecret(ref, value: value, to: group)
        }
        return true
    }

    /// Files dragged in from Finder. On a group chip they're shared to that group; on the list
    /// they're added to history (or to the group being shown).
    func dropFiles(_ urls: [URL], onGroup groupID: String? = nil) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        let target = groupID ?? groupFilter
        let group = target.flatMap { id in env.sync.groups.first { $0.id == id } }
        if target != nil && group == nil { return }
        onDropFinished()
        if group != nil, let problem = SyncEngine.groupShareProblem(fileURLs: files) {
            refuseGroupShare(problem)
            return
        }
        let raw = RawCapture(kind: .file, fileURLs: files)
        Task {
            guard let capture = await CaptureProcessor.process(raw, blobs: env.blobs) else { return }
            env.store.ingest(capture, spaceID: group?.id)
            env.sync.reportActivity()
            let what = files.count == 1 ? "“\(files[0].lastPathComponent)”" : "\(files.count) files"
            if let group {
                env.sync.syncNow()
                showNotice(groupID == nil ? "Added \(what) to \(group.name)" : "Shared \(what) to \(group.name)")
            } else {
                if filter != .all { filter = .all }
                showNotice("Added \(what) to history")
            }
            refresh(resetSelection: true)
        }
    }

    // MARK: Action menu

    func openActions() {
        guard selectedEntry != nil || isMultiSelecting else { return }
        actionQuery = ""
        actionSelection = 0
        mode = .actions
    }

    var aiName: String { env.isAIReady ? env.prefs.aiProvider.shortName : "AI" }

    /// AI rows for the action menu: the real actions once a provider is set up, otherwise a
    /// single "Set Up AI…" so nothing pretends to be ready.
    private var aiActions: [PanelAction] {
        guard env.isAIReady else { return [.setUpAI] }
        return AIAction.builtIn.map(PanelAction.ai) + env.prefs.customPrompts.map { PanelAction.ai(.custom($0)) }
    }

    var availableActions: [PanelAction] {
        if isMultiSelecting {
            let clips = selectedClips
            let secrets = selectedSecrets
            // With secrets in it, a selection only moves between folders.
            if !secrets.isEmpty { return savedActions(for: clips, secrets: secrets) }
            guard !clips.isEmpty else { return [] }
            var actions: [PanelAction] = [.paste]
            if clips.allSatisfy(\.kind.isTextual) {
                actions.append(.pastePlain)
                actions.append(.copy)
                actions += Transform.allCases.filter { $0 != .plainText }.map(PanelAction.transform)
            } else {
                actions.append(.copy)
            }
            if canQuickLook { actions.append(.quickLook) }
            actions += savedActions(for: clips)
            if canShareToGroup { actions.append(.shareToGroup) }
            actions += sendToContactActions
            return actions + [.saveToFolder, .saveToChosenFolder, .delete]
        }
        guard let entry = selectedEntry else { return [] }
        if case .folder(let folder) = entry {
            var actions: [PanelAction] = [.openFolder, .renameFolder, .setLabel]
            if folder.spaceID == nil && canShareToGroup { actions.append(.shareToGroup) }
            return actions + [.deleteFolder]
        }
        var actions: [PanelAction] = [.paste]
        switch entry {
        case .clip(let item) where item.isTransient:
            // Selected text from another app: only transform it, ask AI, or keep it.
            actions = [.copy]
            actions += aiActions
            actions += Transform.allCases.filter { $0 != .plainText }.map(PanelAction.transform)
            actions.append(.saveAsSecret)
            if canShareToGroup { actions.append(.shareToGroup) }
            return actions + sendToContactActions
        case .clip(let item):
            if item.kind.isTextual { actions.append(.pastePlain) }
            actions.append(.copy)
            if canQuickLook { actions.append(.quickLook) }
            if item.kind.isTextual {
                actions += Transform.allCases.filter { $0 != .plainText }.map(PanelAction.transform)
                actions += aiActions
                actions.append(.saveAsSecret)
            } else if item.kind == .image {
                actions += aiActions.filter { if case .ai(let ai) = $0 { ai.worksOnImages } else { true } }
            }
            actions.append(.setLabel)
            actions += savedActions(for: [item])
            if canShareToGroup { actions.append(.shareToGroup) }
            actions += PanelAction.sendToDeviceActions(for: item, multiSelecting: false, targets: DeviceTarget.others(in: env.sync))
            actions += sendableContacts.filter { $0.id != item.spaceID }.map(PanelAction.sendToContact)
            actions += [.saveToFolder, .saveToChosenFolder]
        case .snippet, .folder:
            break
        case .secret(let ref):
            actions.append(.copy)
            actions.append(.setLabel)
            actions += savedActions(for: [], secrets: [ref])
            if canShareToGroup && env.sync.groups.contains(where: { $0.id != ref.spaceID }) { actions.append(.shareToGroup) }
        }
        if let target = entry.slotTarget, let slot = env.slots.slot(for: target) {
            actions.append(.clearSlot(slot))
        }
        if entry.clip != nil || { if case .secret = entry { return true } else { return false } }() {
            actions.append(.delete)
        }
        return actions
    }

    /// Add to Saved (or Save a Copy), Remove from Saved, Move to ‹folder›, New Folder… and Remove
    /// from Folder for the clips and secrets, as they apply.
    private func savedActions(for clips: [ClipItem], secrets: [SecretRef] = []) -> [PanelAction] {
        guard !clips.isEmpty || !secrets.isEmpty, clips.allSatisfy({ !$0.isTransient }) else { return [] }
        var actions: [PanelAction] = []
        let changeable = clips.allSatisfy(env.sync.canChange)
        if clips.contains(where: { !$0.isPinned }) && changeable { actions.append(.addToSaved) }
        // The server refuses changes to another member's group item: keep a copy of your own instead.
        if !changeable { actions.append(.saveCopy) }
        if let menu = folderMenu(for: clips, secrets: secrets) {
            if let group = menu.group {
                actions += group.folders.map(PanelAction.moveToFolder)
                actions.append(.moveToNewFolder)
            }
            actions += menu.personal.map(PanelAction.moveToFolder)
            actions.append(menu.copiesToPersonal ? .copyToNewFolder : .moveToNewFolder)
        }
        let mayChangeAll = changeable && secrets.allSatisfy { env.sync.canChange(itemID: $0.id, spaceID: $0.spaceID) }
        if mayChangeAll && (clips.contains { env.store.folder(of: $0) != nil } || secrets.contains { folder(of: $0) != nil }) {
            actions.append(.removeFromFolder)
        }
        // A label keeps an item saved; it's released by removing the label.
        if changeable && clips.contains(where: { $0.isPinned && $0.label == nil }) { actions.append(.removeFromLabelled) }
        return actions
    }

    /// An action's title for the current selection.
    func title(for action: PanelAction) -> String {
        if let count = pickedFileCount {
            switch action {
            case .paste: return "Paste \(count.picked) of \(count.total) Files"
            case .copy: return "Copy \(count.picked) of \(count.total) Files"
            default: break
            }
        }
        if action == .delete, isRemovingFromGroup { return "Remove from Group" }
        if case .moveToFolder(let folder) = action, folder.spaceID == nil, selectionHasGroupItems {
            return "Save a Copy to “\(folder.name)”"
        }
        if case .moveToFolder(let folder) = action, let space = folder.spaceID, let name = env.sync.groupName(for: space) {
            return "Move to “\(folder.name)” in \(name)"
        }
        if action == .moveToNewFolder, let space = (selectedClips.first?.spaceID ?? selectedSecrets.first?.spaceID),
           let name = env.sync.groupName(for: space) {
            return "Move to New Folder in \(name)…"
        }
        return action.title(folderName: env.prefs.saveFolderName)
    }

    /// The selection holds items of a group (moving them to a personal folder saves copies).
    private var selectionHasGroupItems: Bool {
        let rows = isMultiSelecting ? entries.filter { selectedIDs.contains($0.id) } : selectedEntry.map { [$0] } ?? []
        return rows.contains { isGroupSpace($0.clip?.spaceID ?? $0.secret?.spaceID) }
    }

    /// Delete on group items removes them for everyone in the group.
    var isRemovingFromGroup: Bool {
        let clips = isMultiSelecting ? selectedClips : selectedEntry?.clip.map { [$0] } ?? []
        return !clips.isEmpty && clips.allSatisfy { isGroupSpace($0.spaceID) }
    }

    var filteredActions: [PanelAction] {
        let q = actionQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return availableActions }
        var matches = availableActions
            .compactMap { action in
                FuzzyMatcher.score(query: q, in: title(for: action) + " " + action.section(aiName: aiName))
                    .map { (action, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        // Anything typed can also be sent as a question or instruction about the selected item.
        if !isMultiSelecting, let kind = selectedEntry?.clip?.kind, kind.isTextual || kind == .image {
            if env.isAIReady {
                // A sentence or question is meant for the AI, not a filter: offer it first.
                let looksLikeQuestion = q.contains(" ") || q.hasSuffix("?")
                if looksLikeQuestion { matches.insert(.ai(.instruction(q)), at: 0) } else { matches.append(.ai(.instruction(q))) }
            } else if !matches.contains(.setUpAI) {
                matches.append(.setUpAI)
            }
        }
        return matches
    }

    func perform(_ action: PanelAction) {
        if isMultiSelecting {
            performOnSelection(action)
            return
        }
        guard let entry = selectedEntry else { return }
        switch action {
        case .paste:
            activate(entry)
        case .pastePlain:
            activate(entry, transform: .plainText)
        case .copy:
            switch entry {
            case .clip(let item) where item.isTransient: env.paste.write(text: item.text)
            case .clip(let item): copy(item)
            case .secret(let ref): env.copySecret(ref)
            case .snippet, .folder: break
            }
            onClose()
        case .transform(let transform):
            guard let item = entry.clip else { return }
            guard let result = transform.apply(item.text) else {
                showNotice("Can't apply “\(transform.title)” to this item")
                return
            }
            let target = targetApp
            onClose()
            env.paste.paste(text: result, into: target)
        case .ai(let aiAction):
            guard let item = entry.clip else { return }
            var image: AIImage?
            if item.kind == .image {
                guard let file = item.imageFile, let loaded = AIImage.load(from: env.blobs.url(for: file)) else {
                    showNotice("Couldn't read this image")
                    return
                }
                image = loaded
            }
            let run = AIRun(action: aiAction, item: item, providerName: env.prefs.aiProvider.title, image: image)
            aiRun = run
            mode = .ai
            run.start(prefs: env.prefs)
        case .saveAsSecret:
            guard let item = entry.clip else { return }
            beginSaveSecret(item)
        case .setLabel:
            beginLabel(entry)
        case .shareToGroup:
            if let item = entry.clip {
                beginShare([item])
            } else if case .secret(let ref) = entry {
                beginShareSecret(ref)
            } else if let folder = entry.folder {
                beginShareFolder(folder)
            }
        case .addToSaved:
            guard let item = entry.clip else { return }
            addToSaved([item])
        case .saveCopy:
            guard let item = entry.clip else { return }
            saveCopies([item])
        case .moveToFolder(let folder):
            place(entry.clip.map { [$0] } ?? [], secrets: entry.secret.map { [$0] } ?? [], in: folder)
        case .moveToNewFolder:
            beginNewFolder(moving: entry.clip.map { [$0] } ?? [], secrets: entry.secret.map { [$0] } ?? [])
        case .copyToNewFolder:
            beginNewFolder(moving: entry.clip.map { [$0] } ?? [], secrets: entry.secret.map { [$0] } ?? [], personal: true)
        case .removeFromFolder:
            removeFromFolder(entry.clip.map { [$0] } ?? [], secrets: entry.secret.map { [$0] } ?? [])
        case .openFolder:
            mode = .browse
            if let folder = entry.folder { openFolder(folder) }
        case .renameFolder:
            if let folder = entry.folder { beginRename(folder) }
        case .deleteFolder:
            if let folder = entry.folder { deleteFolder(folder) }
        case .sendToDevice(let device):
            guard let item = entry.clip else { return }
            send(item, to: device)
        case .sendToContact(let contact):
            guard let item = entry.clip else { return }
            send([item], to: contact)
        case .quickLook:
            toggleQuickLook()
        case .setUpAI:
            onClose()
            SettingsOpener.open()
        case .clearSlot(let number):
            env.slots.clear(number)
            mode = .browse
            refresh()
        case .removeFromLabelled:
            guard let item = entry.clip else { return }
            mode = .browse
            removeFromLabelled(item)
        case .saveToFolder:
            guard let item = entry.clip else { return }
            save([item], to: env.prefs.saveFolder)
        case .saveToChosenFolder:
            guard let item = entry.clip else { return }
            saveChoosingFolder([item])
        case .delete:
            mode = .browse
            deleteSelection(includingSecrets: true)
        }
    }

    private func performOnSelection(_ action: PanelAction) {
        let clips = selectedClips
        let secrets = selectedSecrets
        switch action {
        case .paste:
            pasteSelection()
        case .pastePlain:
            pasteSelection(transform: .plainText)
        case .copy:
            env.paste.write(clips, transform: nil)
            onClose()
        case .quickLook:
            toggleQuickLook()
        case .transform(let transform):
            let parts = clips.map { transform.apply($0.text) }
            guard parts.allSatisfy({ $0 != nil }) else {
                showNotice("Can't apply “\(transform.title)” to every selected item")
                return
            }
            let target = targetApp
            onClose()
            env.paste.paste(text: parts.compactMap { $0 }.joined(separator: "\n"), into: target)
        case .shareToGroup:
            beginShare(clips)
        case .sendToContact(let contact):
            send(clips, to: contact)
        case .addToSaved:
            addToSaved(clips)
        case .saveCopy:
            saveCopies(clips)
        case .moveToFolder(let folder):
            place(clips, secrets: secrets, in: folder)
        case .moveToNewFolder:
            beginNewFolder(moving: clips, secrets: secrets)
        case .copyToNewFolder:
            beginNewFolder(moving: clips, secrets: secrets, personal: true)
        case .removeFromFolder:
            removeFromFolder(clips, secrets: secrets)
        case .removeFromLabelled:
            removeFromSaved(clips)
        case .saveToFolder:
            save(clips, to: env.prefs.saveFolder)
        case .saveToChosenFolder:
            saveChoosingFolder(clips)
        case .delete:
            mode = .browse
            deleteSelectedClips()
        default:
            break
        }
    }

    // MARK: AI result

    /// Runs the same action again (e.g. after switching model).
    func rerunAI() {
        guard let old = aiRun else { return }
        old.cancel()
        let run = AIRun(action: old.action, item: old.item, providerName: env.prefs.aiProvider.title, image: old.image)
        aiRun = run
        run.start(prefs: env.prefs)
    }

    func pasteAIOutput() {
        guard let run = aiRun, !run.output.isEmpty else { return }
        let target = targetApp
        let text = run.output
        onClose()
        env.paste.paste(text: text, into: target)
    }

    func copyAIOutput() {
        guard let run = aiRun, !run.output.isEmpty else { return }
        env.paste.write(text: run.output)
        showNotice("Copied")
    }

    /// The words recognised in an image, copied as plain text (marked as our own write, so it
    /// doesn't come back as a new history item).
    func copyImageText(_ text: String) {
        guard !text.isEmpty else { return }
        env.paste.write(text: text)
        showNotice("Copied text")
    }

    func replaceItemWithAIOutput() {
        guard let run = aiRun, run.isFinished, !run.item.isTransient else { return }
        env.store.replaceText(of: run.item, with: run.output)
        resetMode()
        refresh()
        selectedID = PanelEntry.clip(run.item).id
        showNotice("Item replaced")
    }

    // MARK: Item actions

    /// Lets an item kept without a label expire like the rest of history.
    func removeFromLabelled(_ item: ClipItem) {
        removeFromSaved([item])
    }

    // MARK: Saved and folder actions

    /// Whether a clip can go into a folder: saved to history, and yours or a group's. A contact's
    /// items stay as they arrived (edits to them never sync).
    func canUseFolders(_ item: ClipItem) -> Bool {
        guard !item.isTransient else { return false }
        guard let space = item.spaceID else { return true }
        return isGroupSpace(space)
    }

    func isGroupSpace(_ spaceID: String?) -> Bool {
        guard let spaceID else { return false }
        return env.sync.groups.contains { $0.id == spaceID }
    }

    /// Whether a secret can go into a folder: yours or a group's (never a contact's).
    func canUseFolders(_ ref: SecretRef) -> Bool {
        guard let space = ref.spaceID else { return true }
        return isGroupSpace(space)
    }

    /// Clips that may move into a folder together: all of one space, folders allowed there.
    func canMoveToFolder(_ clips: [ClipItem]) -> Bool {
        guard let first = clips.first else { return false }
        return clips.allSatisfy { canUseFolders($0) && $0.spaceID == first.spaceID }
    }

    /// The folders the clips can move into (their space's, except the one they're all in already).
    func folderTargets(for clips: [ClipItem]) -> [ClipFolder] {
        guard canMoveToFolder(clips), let first = clips.first else { return [] }
        return env.store.folders(inSpace: first.spaceID).filter { folder in !clips.allSatisfy { $0.folderID == folder.id } }
    }

    /// What Move to Folder offers for a selection.
    struct FolderMenu {
        /// The group the items are all in, with its folders, when they may be moved there.
        var group: (id: String, name: String, folders: [ClipFolder])?
        /// Personal folders ("Mine"): group items go in as personal copies.
        var personal: [ClipFolder]
        /// Some items are a group's, so the personal choices (and New Folder…) save copies.
        var copiesToPersonal: Bool
    }

    /// Move to Folder for clips and secrets: a group's items list the group's folders under its
    /// name (if this account may move them) and your own under "Mine", where they're copied to;
    /// items of several spaces only get "Mine". Nil when the items can't use folders.
    func folderMenu(for clips: [ClipItem], secrets: [SecretRef] = []) -> FolderMenu? {
        let clips = clips.filter { !$0.isTransient }
        guard !clips.isEmpty || !secrets.isEmpty,
              clips.allSatisfy(canUseFolders), secrets.allSatisfy(canUseFolders) else { return nil }
        let spaces = Set(clips.map(\.spaceID) + secrets.map(\.spaceID))
        let allIn = { (folder: ClipFolder) in
            clips.allSatisfy { $0.folderID == folder.id } && secrets.allSatisfy { $0.folderID == folder.id }
        }
        let personal = env.store.folders(inSpace: nil)
        if spaces == [nil] {
            return FolderMenu(group: nil, personal: personal.filter { !allIn($0) }, copiesToPersonal: false)
        }
        var group: (id: String, name: String, folders: [ClipFolder])?
        if spaces.count == 1, let id = spaces.first ?? nil,
           clips.allSatisfy(env.sync.canChange), secrets.allSatisfy({ env.sync.canChange(itemID: $0.id, spaceID: $0.spaceID) }) {
            group = (id, env.sync.groupName(for: id) ?? "Group", env.store.folders(inSpace: id).filter { !allIn($0) })
        }
        return FolderMenu(group: group, personal: personal, copiesToPersonal: true)
    }

    /// The folder an item shows in, if any.
    func folder(of item: ClipItem) -> ClipFolder? { env.store.folder(of: item) }

    /// The folder a secret shows in: nil when it has none, or one that isn't in its space.
    func folder(of ref: SecretRef) -> ClipFolder? {
        guard let id = ref.folderID, let folder = env.store.folder(withID: id), folder.spaceID == ref.spaceID else { return nil }
        return folder
    }

    func move(_ clips: [ClipItem], to folder: ClipFolder) {
        place(clips, secrets: [], in: folder)
    }

    /// Puts clips and secrets in a folder. Items of the folder's space move in (a group's only if
    /// this account may change them); group items going into a personal folder are saved there as
    /// personal copies, and the group's stay as they are.
    func place(_ clips: [ClipItem], secrets: [SecretRef], in folder: ClipFolder) {
        if mode == .actions { mode = .browse }
        let clips = clips.filter { !$0.isTransient && canUseFolders($0) }
        let secrets = secrets.filter(canUseFolders)
        let mayMove = { [env] (id: String, space: String?) in space == folder.spaceID && env.sync.canChange(itemID: id, spaceID: space) }
        let movingClips = clips.filter { mayMove($0.id.uuidString, $0.spaceID) }
        let movingSecrets = secrets.filter { mayMove($0.id, $0.spaceID) }
        // Only a personal folder takes copies of other spaces' items.
        let copyingClips = folder.spaceID == nil ? clips.filter { $0.spaceID != nil } : []
        let copyingSecrets = folder.spaceID == nil ? secrets.filter { $0.spaceID != nil } : []
        guard !movingClips.isEmpty || !movingSecrets.isEmpty || !copyingClips.isEmpty || !copyingSecrets.isEmpty else {
            NSSound.beep()
            let refused = clips.contains { $0.spaceID == folder.spaceID } || secrets.contains { $0.spaceID == folder.spaceID }
            showNotice(refused ? "Only its author or the group's owner can move it"
                       : "Only items from the same place can go in “\(folder.name)”")
            return
        }
        env.store.move(movingClips, to: folder)
        env.secrets.setFolder(folder.id, for: movingSecrets)
        env.store.savePersonalCopies(of: copyingClips, into: folder)
        let moved = movingClips.count + movingSecrets.count
        let copied = copyingClips.count + copyingSecrets.count
        let notice = copied == 0
            ? (moved == 1 ? "Moved to “\(folder.name)”" : "Moved \(moved) items to “\(folder.name)”")
            : (copied == 1 ? "Saved a copy to “\(folder.name)”" : "Saved \(copied) copies to “\(folder.name)”")
        if copyingSecrets.isEmpty {
            refresh()
            showNotice(notice)
        } else {
            copySecretsToPersonal(copyingSecrets, folder: folder) { [weak self] in
                self?.refresh()
                self?.showNotice(notice)
            }
        }
    }

    /// Personal copies of group secrets (after Touch ID), in `folder` or at the root of Saved.
    private func copySecretsToPersonal(_ refs: [SecretRef], folder: ClipFolder?, then: @escaping () -> Void) {
        Task {
            let what = refs.count == 1 ? "“\(refs[0].name)”" : "\(refs.count) secrets"
            guard await env.secrets.authenticate(reason: "save a copy of \(what)") else { return }
            let personal = env.secrets.secrets.filter { $0.spaceID == nil }
            for ref in refs {
                guard let value = SecretVault.value(id: ref.id) else { continue }
                if let same = personal.first(where: { $0.name == ref.name && SecretVault.value(id: $0.id) == value }) {
                    if let folder { env.secrets.setFolder(folder.id, for: [same]) }
                } else {
                    env.secrets.add(name: ref.name, value: value, folderID: folder?.id)
                }
            }
            then()
        }
    }

    func removeFromFolder(_ clips: [ClipItem], secrets: [SecretRef] = []) {
        if mode == .actions { mode = .browse }
        env.store.removeFromFolder(clips)
        env.secrets.setFolder(nil, for: secrets)
        refresh()
        showNotice("Moved to Saved")
    }

    func addToSaved(_ clips: [ClipItem]) {
        if mode == .actions { mode = .browse }
        env.store.addToSaved(clips)
        refresh()
        showNotice(clips.count == 1 ? "Added to Saved" : "Added \(clips.count) items to Saved")
    }

    /// Save a Copy: personal copies of (another member's) group items, at the root of your Saved.
    /// The group's items don't change.
    func saveCopies(_ clips: [ClipItem]) {
        if mode == .actions { mode = .browse }
        let copies = env.store.savePersonalCopies(of: clips.filter { $0.spaceID != nil })
        refresh()
        showNotice(copies.count == 1 ? "Saved a copy to Saved" : "Saved \(copies.count) copies to Saved")
    }

    /// Lets saved items without a label expire again (out of their folder too).
    func removeFromSaved(_ clips: [ClipItem]) {
        if mode == .actions { mode = .browse }
        env.store.removeFromSaved(clips)
        refresh()
        showNotice("Removed from Saved")
    }

    /// Names a new folder in the panel; `moving` clips and `secrets` go into it (Move to Folder ▸
    /// New Folder…). `personal`: a personal folder, taking copies of group items.
    func beginNewFolder(moving clips: [ClipItem] = [], secrets: [SecretRef] = [], personal: Bool = false) {
        let space = personal ? nil : clips.first?.spaceID ?? secrets.first?.spaceID ?? (clips.isEmpty && secrets.isEmpty ? savedSpaceID : nil)
        if clips.isEmpty && secrets.isEmpty {
            guard space == nil || isGroupSpace(space) else { return }
        } else {
            guard let menu = folderMenu(for: clips, secrets: secrets) else { return }
            // Into a group's new folder only when its items may be moved there.
            if space != nil && menu.group == nil { return }
        }
        folderNameForm = FolderNameState(purpose: .create(spaceID: space, moving: clips, secrets: secrets))
        mode = .folderName
    }

    func beginRename(_ folder: ClipFolder) {
        selectedID = PanelEntry.folder(folder).id
        folderNameForm = FolderNameState(purpose: .rename(folder))
        mode = .folderName
    }

    func submitFolderName() {
        guard let form = folderNameForm else { return }
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            NSSound.beep()
            return
        }
        switch form.purpose {
        case .rename(let folder):
            env.store.rename(folder, to: name)
            resetMode()
            refresh()
            selectedID = PanelEntry.folder(folder).id
            showNotice("Renamed to “\(folder.name)”")
        case .create(let space, let moving, let secrets):
            let folder = env.store.createFolder(named: name, inSpace: space)
            resetMode()
            if moving.isEmpty && secrets.isEmpty {
                refresh()
                let id = PanelEntry.folder(folder).id
                if entries.contains(where: { $0.id == id }) { selectedID = id }
                showNotice("Created “\(folder.name)”")
            } else {
                place(moving, secrets: secrets, in: folder)
            }
        }
    }

    /// Its clips stay saved, at the root; nothing to confirm.
    func deleteFolder(_ folder: ClipFolder) {
        if mode == .actions { mode = .browse }
        let index = selectedIndex
        if openFolderID == folder.id { openFolderID = nil }
        // Its secrets go to the root (and re-sync without it), like its clips.
        let secrets = env.secrets.secrets(inFolder: folder)
        env.secrets.setFolder(nil, for: secrets)
        let moved = env.store.deleteFolder(folder) + secrets.count
        refresh()
        if let index, !entries.isEmpty { selectedID = entries[min(index, entries.count - 1)].id }
        showNotice("Folder deleted · \(moved) \(moved == 1 ? "item" : "items") moved to Saved")
    }

    /// ⌫ never deletes secrets (too easy to hit by accident); ⌘K → Delete does.
    func deleteSelection(includingSecrets: Bool = false) {
        guard let entry = selectedEntry, let index = selectedIndex else { return }
        switch entry {
        case .clip(let item):
            env.slots.remove(target: .clip(item.id))
            env.store.delete(item)
        case .secret(let ref):
            guard includingSecrets else { return }
            env.slots.remove(target: .secret(ref.id))
            env.secrets.delete(ref)
        case .folder(let folder):
            deleteFolder(folder)   // nothing is lost: its clips move to the root
            return
        case .snippet:
            return   // snippets are edited in Settings
        }
        refresh()
        if !entries.isEmpty {
            selectedID = entries[min(index, entries.count - 1)].id
        }
    }

    // MARK: Keyboard

    /// Returns true when the event was handled and must not reach the search field.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch mode {
        case .browse: handleBrowseKey(event)
        case .actions: handleActionKey(event)
        case .snippetForm, .saveSecret, .label, .editSecret, .folderName: handleFormKey(event)
        case .shareToGroup: handleShareKey(event)
        case .ai: handleAIKey(event)
        }
    }

    private func handleBrowseKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch event.keyCode {
        case KeyCode.escape:
            // Quick Look closes first, then an open folder; the panel on the next press.
            if isQuickLookOpen() {
                onQuickLook(false)
            } else if openFolderID != nil {
                closeFolder()
            } else {
                onClose()
            }
            return true
        case KeyCode.leftArrow where openFolderID != nil && query.isEmpty && !command && !shift:
            closeFolder()
            return true
        case KeyCode.rightArrow where query.isEmpty && !command && !shift && selectedEntry?.folder != nil && !isMultiSelecting:
            activate(selectedEntry)
            return true
        case KeyCode.upArrow:
            moveSelection(by: -1, extending: shift)
            return true
        case KeyCode.downArrow:
            moveSelection(by: 1, extending: shift)
            return true
        case KeyCode.pageUp:
            moveSelection(by: -8, extending: shift)
            return true
        case KeyCode.pageDown:
            moveSelection(by: 8, extending: shift)
            return true
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if isMultiSelecting {
                pasteSelection(transform: option ? .plainText : nil)
            } else {
                activate(selectedEntry, transform: option ? .plainText : nil)
            }
            return true
        case KeyCode.tab:
            cycleFilter(forward: !shift)
            return true
        case KeyCode.delete, KeyCode.forwardDelete:
            // With text in the search field every delete variant edits the text
            // (⌥⌫ deletes a word, ⌘⌫ the line); only an empty field deletes items.
            guard query.isEmpty else { return false }
            if isMultiSelecting { deleteSelectedClips() } else { deleteSelection() }
            return true
        default:
            break
        }

        if command {
            // Digits by key code so ⌘⇧1 works on every keyboard layout.
            if let digit = KeyCode.digit(for: event.keyCode) {
                if shift {
                    assignSelection(toSlot: digit)
                } else {
                    activateShortcut(digit, transform: option ? .plainText : nil)
                }
                return true
            }
            switch chars {
            case "a":
                // With an empty search field ⌘A selects every row; otherwise it selects the text.
                guard query.isEmpty else { return false }
                selectAll()
                return true
            case "k":
                openActions()
                return true
            case "e":
                beginEditing()
                return true
            case "y":
                toggleQuickLook()
                return true
            case ",":
                onClose()
                SettingsOpener.open()
                return true
            default:
                break
            }
        }
        return false
    }

    /// The action filter is a real text field, so typing and text editing (⌥⌫, ⌘⌫, ⌘A…)
    /// go to it; only navigation keys are intercepted here.
    private func handleActionKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let actions = filteredActions
        switch event.keyCode {
        case KeyCode.escape:
            if isSelectionMode { onClose() } else { mode = .browse }
        case KeyCode.upArrow:
            actionSelection = max(0, actionSelection - 1)
        case KeyCode.downArrow:
            actionSelection = min(max(0, actions.count - 1), actionSelection + 1)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if actions.indices.contains(actionSelection) { perform(actions[actionSelection]) }
        default:
            guard flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "k" else { return false }
            mode = .browse
        }
        return true
    }

    private func handleFormKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case KeyCode.escape:
            resetMode()
            return true
        case KeyCode.returnKey, KeyCode.keypadEnter:
            switch mode {
            case .saveSecret: submitSaveSecret()
            case .label: submitLabel()
            case .folderName: submitFolderName()
            case .editSecret: submitEditSecret()
            default: submitSnippetForm()
            }
            return true
        default:
            return false
        }
    }

    private func handleShareKey(_ event: NSEvent) -> Bool {
        guard let form = shareForm else { return false }
        switch event.keyCode {
        case KeyCode.escape:
            if isSelectionMode { mode = .actions } else { resetMode() }
        case KeyCode.upArrow:
            form.selection = max(0, form.selection - 1)
        case KeyCode.downArrow:
            form.selection = min(form.groups.count - 1, form.selection + 1)
        case KeyCode.leftArrow:
            form.moveDestination(by: -1)
        case KeyCode.rightArrow:
            form.moveDestination(by: 1)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            submitShare()
        default:
            return false
        }
        return true
    }

    private func handleAIKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case KeyCode.escape:
            if isSelectionMode {
                aiRun?.cancel()
                aiRun = nil
                mode = .actions
            } else {
                resetMode()
            }
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if aiRun?.isFinished == true { pasteAIOutput() }
        default:
            if flags.contains(.command) {
                if chars == "c" { copyAIOutput() }
                if chars == "r" { replaceItemWithAIOutput() }
            }
        }
        return true
    }
}

nonisolated enum KeyCode {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let keypadEnter: UInt16 = 76
    static let pageUp: UInt16 = 116
    static let forwardDelete: UInt16 = 117
    static let pageDown: UInt16 = 121
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126

    /// kVK_ANSI_1 … kVK_ANSI_9 (positional, layout independent).
    private static let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
    static func digit(for keyCode: UInt16) -> Int? { digits[keyCode] }
}
