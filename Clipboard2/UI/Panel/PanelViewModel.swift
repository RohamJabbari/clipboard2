import AppKit
import Observation

nonisolated enum PanelFilter: String, CaseIterable, Identifiable, Sendable {
    case all, pinned, text, images, files, snippets, secrets, thisApp
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .pinned: "Pinned"
        case .text: "Text"
        case .images: "Images"
        case .files: "Files"
        case .snippets: "Snippets"
        case .secrets: "Secrets"
        case .thisApp: "This App"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .pinned: "pin"
        case .text: "text.alignleft"
        case .images: "photo"
        case .files: "doc"
        case .snippets: "text.badge.star"
        case .secrets: "key"
        case .thisApp: "app"
        }
    }
}

enum PanelEntry: Identifiable {
    case clip(ClipItem)
    case snippet(Snippet)
    case secret(SecretRef)

    var id: String {
        switch self {
        case .clip(let item): "c-" + item.id.uuidString
        case .snippet(let snippet): "s-" + snippet.id.uuidString
        case .secret(let ref): "k-" + ref.id
        }
    }

    var clip: ClipItem? {
        if case .clip(let item) = self { return item }
        return nil
    }

    var slotTarget: SlotTarget {
        switch self {
        case .clip(let item): .clip(item.id)
        case .snippet(let snippet): .snippet(snippet.id)
        case .secret(let ref): .secret(ref.id)
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
}

enum PanelAction: Identifiable, Hashable {
    case paste
    case pastePlain
    case copy
    case transform(Transform)
    case ai(AIAction)
    case saveAsSecret
    case setLabel
    case shareToGroup
    case setUpAI
    case clearSlot(Int)
    case togglePin
    case delete

    var id: String {
        switch self {
        case .paste: "paste"
        case .pastePlain: "pastePlain"
        case .copy: "copy"
        case .transform(let t): "transform-" + t.rawValue
        case .ai(let a): "ai-" + a.id
        case .saveAsSecret: "saveAsSecret"
        case .setLabel: "setLabel"
        case .shareToGroup: "shareToGroup"
        case .setUpAI: "setUpAI"
        case .clearSlot(let n): "clearSlot-\(n)"
        case .togglePin: "pin"
        case .delete: "delete"
        }
    }

    func section(aiName: String) -> String {
        switch self {
        case .paste, .pastePlain, .copy: "Paste"
        case .transform: "Transform & Paste"
        case .ai, .setUpAI: "Ask \(aiName)"
        case .saveAsSecret, .setLabel, .shareToGroup, .clearSlot, .togglePin, .delete: "Item"
        }
    }

    func title(isPinned: Bool) -> String {
        switch self {
        case .paste: "Paste"
        case .pastePlain: "Paste as Plain Text"
        case .copy: "Copy to Clipboard"
        case .transform(let t): t.title
        case .ai(.instruction(let text)): "Ask: “\(text)”"
        case .ai(let a): a.title
        case .saveAsSecret: "Save as Secret…"
        case .setLabel: "Label…"
        case .shareToGroup: "Share to Group…"
        case .setUpAI: "Set Up AI…"
        case .clearSlot(let n): "Remove from Quick Slot ⌘\(n)"
        case .togglePin: isPinned ? "Unpin" : "Pin"
        case .delete: "Delete"
        }
    }

    var symbol: String {
        switch self {
        case .paste: "doc.on.clipboard"
        case .pastePlain: "doc.plaintext"
        case .copy: "doc.on.doc"
        case .transform(let t): t.symbol
        case .ai(let a): a.symbol
        case .saveAsSecret: "key"
        case .setLabel: "tag"
        case .shareToGroup: "person.2"
        case .setUpAI: "sparkles"
        case .clearSlot: "number.square"
        case .togglePin: "pin"
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
    let groups: [SyncGroup]
    var selection: Int

    init(items: [ClipItem], groups: [SyncGroup], defaultGroupID: String?) {
        self.items = items
        self.groups = groups
        self.selection = groups.firstIndex { $0.id == defaultGroupID } ?? 0
    }

    var selectedGroup: SyncGroup? { groups.indices.contains(selection) ? groups[selection] : nil }
}

@Observable
final class LabelFormState {
    enum Target {
        case clip(ClipItem)
        case secret(SecretRef)
    }

    let target: Target
    var text: String

    init(target: Target) {
        self.target = target
        switch target {
        case .clip(let item): text = item.label ?? ""
        case .secret(let ref): text = ref.name
        }
    }

    var valuePreview: String {
        switch target {
        case .clip(let item): item.preview.isEmpty ? item.kind.displayName : item.preview
        case .secret: "••••••••"
        }
    }

    var isSecret: Bool {
        if case .secret = target { return true }
        return false
    }
}

@Observable
final class PanelViewModel {
    @ObservationIgnored let env: AppEnvironment
    @ObservationIgnored var onClose: () -> Void = {}

    var query = "" { didSet { if query != oldValue { refresh(resetSelection: true) } } }
    var filter: PanelFilter = .all { didSet { if filter != oldValue { refresh(resetSelection: true) } } }
    /// A sync group chosen in the filter row; when set it replaces `filter`.
    var groupFilter: String? {
        didSet {
            guard groupFilter != oldValue else { return }
            refresh(resetSelection: true)
            // Fetch what group members sent since the last sync; the list refreshes when it lands.
            if groupFilter != nil { env.sync.syncNow() }
        }
    }
    private(set) var entries: [PanelEntry] = []
    /// The focused row (drives the preview and keyboard navigation).
    var selectedID: String? {
        didSet {
            guard !adjustingSelection else { return }
            selectedIDs = selectedID.map { [$0] } ?? []
            anchorID = selectedID
        }
    }
    /// Every selected row; more than one after ⌘-click, ⇧-click, ⇧-arrows or ⌘A.
    private(set) var selectedIDs: Set<String> = []
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
        filter = .all
        groupFilter = nil
        userMovedSelection = false
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
        selectionItem = nil
        resetMode()
    }

    func resetMode() {
        aiRun?.cancel()
        aiRun = nil
        snippetForm = nil
        saveSecretForm = nil
        labelForm = nil
        editSecretForm = nil
        shareForm = nil
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
        if let groupFilter {
            clips = env.store.allItems().filter { $0.spaceID == groupFilter }
        } else if filter != .snippets && filter != .secrets {
            clips = env.store.allItems().filter { item in
                switch filter {
                case .all: true
                case .pinned: item.isPinned
                case .text: item.kind.isTextual
                case .images: item.kind == .image
                case .files: item.kind == .file
                case .snippets, .secrets: false
                case .thisApp: targetBundle != nil && item.sourceBundleID == targetBundle
                }
            }
        }
        // Snippets and secrets join "All" only while searching, so history stays uncluttered.
        let searchingAll = filter == .all && groupFilter == nil && !q.isEmpty
        let snippets = groupFilter == nil && (filter == .snippets || searchingAll) ? env.snippets.all() : []
        let secrets = groupFilter == nil && (filter == .secrets || searchingAll) ? env.secrets.secrets : []

        var result: [PanelEntry]
        if q.isEmpty {
            result = clips.map(PanelEntry.clip) + snippets.map(PanelEntry.snippet) + secrets.map(PanelEntry.secret)
        } else {
            var scored: [(PanelEntry, Int, Date)] = []
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
        if resetSelection || !userMovedSelection || !entries.contains(where: { $0.id == selectedID }) {
            selectedID = entries.first?.id
        } else {
            let live = Set(entries.map(\.id))
            setSelection(selectedIDs.intersection(live), focus: selectedID)
        }
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

    func togglePinOnSelectedClips() {
        let clips = selectedClips
        let pin = clips.contains { !$0.isPinned }
        for item in clips where item.isPinned != pin { env.store.togglePin(item) }
        refresh()
        showNotice(pin ? "Pinned \(clips.count) items" : "Unpinned \(clips.count) items")
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

    /// ⇥ walks the built-in filters, then each sync group.
    func cycleFilter(forward: Bool) {
        let choices: [(PanelFilter, String?)] = PanelFilter.allCases.map { ($0, nil) } + env.sync.groups.map { (.all, $0.id) }
        let current = choices.firstIndex { groupFilter == nil ? $0.0 == filter && $0.1 == nil : $0.1 == groupFilter } ?? 0
        let next = choices[(current + (forward ? 1 : choices.count - 1)) % choices.count]
        groupFilter = next.1
        filter = next.0
    }

    // MARK: Quick slots

    /// The ⌘-number shown on a row: its assigned slot, or its position if that number is unassigned.
    func shortcutNumber(for entry: PanelEntry, at index: Int) -> (number: Int, isSlot: Bool)? {
        if let slot = env.slots.slot(for: entry.slotTarget) { return (slot, true) }
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

    func activate(_ entry: PanelEntry?, transform: Transform? = nil) {
        guard let entry else { return }
        switch entry {
        case .clip(let item):
            let target = targetApp
            onClose()
            env.paste.paste(item, transform: transform, into: target)
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
        case .snippet: return
        }
        mode = .label
    }

    func submitLabel() {
        guard let form = labelForm else { return }
        switch form.target {
        case .clip(let item):
            env.store.setLabel(form.text, for: item)
            showNotice(item.label == nil ? "Label removed" : "Labelled and pinned")
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
        shareForm = ShareGroupState(items: items, groups: env.sync.groups, defaultGroupID: env.prefs.syncDefaultGroupID)
        mode = .shareToGroup
    }

    func submitShare() {
        guard let form = shareForm, let group = form.selectedGroup else { return }
        share(form.items, to: group)
        resetMode()
    }

    /// Copies items into a group's space with new ids (selected text from another app is stored there).
    func share(_ items: [ClipItem], to group: SyncGroup) {
        for item in items {
            if item.isTransient {
                env.store.ingest(.text(item.text, source: item.source), spaceID: group.id)
            } else if item.spaceID != group.id {
                env.store.shareCopy(of: item, toSpace: group.id)
            }
        }
        env.sync.syncNow()
        if isSelectionMode {
            onClose()
            HUD.show("Sent to \(group.name)", symbol: "person.2.fill")
        } else {
            refresh()
            showNotice(items.count == 1 ? "Shared to \(group.name)" : "Shared \(items.count) items to \(group.name)")
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
            guard !clips.isEmpty else { return [] }
            var actions: [PanelAction] = [.paste]
            if clips.allSatisfy(\.kind.isTextual) {
                actions.append(.pastePlain)
                actions.append(.copy)
                actions += Transform.allCases.filter { $0 != .plainText }.map(PanelAction.transform)
            } else {
                actions.append(.copy)
            }
            if canShareToGroup { actions.append(.shareToGroup) }
            return actions + [.togglePin, .delete]
        }
        guard let entry = selectedEntry else { return [] }
        var actions: [PanelAction] = [.paste]
        switch entry {
        case .clip(let item) where item.isTransient:
            // Selected text from another app: only transform it, ask AI, or keep it.
            actions = [.copy]
            actions += aiActions
            actions += Transform.allCases.filter { $0 != .plainText }.map(PanelAction.transform)
            actions.append(.saveAsSecret)
            if canShareToGroup { actions.append(.shareToGroup) }
            return actions
        case .clip(let item):
            if item.kind.isTextual { actions.append(.pastePlain) }
            actions.append(.copy)
            if item.kind.isTextual {
                actions += Transform.allCases.filter { $0 != .plainText }.map(PanelAction.transform)
                actions += aiActions
                actions.append(.saveAsSecret)
            } else if item.kind == .image {
                actions += aiActions.filter { if case .ai(let ai) = $0 { ai.worksOnImages } else { true } }
            }
            actions.append(.setLabel)
            if canShareToGroup { actions.append(.shareToGroup) }
            actions.append(.togglePin)
        case .snippet:
            break
        case .secret:
            actions.append(.copy)
            actions.append(.setLabel)
        }
        if let slot = env.slots.slot(for: entry.slotTarget) {
            actions.append(.clearSlot(slot))
        }
        if entry.clip != nil || { if case .secret = entry { return true } else { return false } }() {
            actions.append(.delete)
        }
        return actions
    }

    var filteredActions: [PanelAction] {
        let isPinned = selectedEntry?.clip?.isPinned ?? false
        let q = actionQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return availableActions }
        var matches = availableActions
            .compactMap { action in
                FuzzyMatcher.score(query: q, in: action.title(isPinned: isPinned) + " " + action.section(aiName: aiName))
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
            case .clip(let item): env.paste.copy(item)
            case .secret(let ref): env.copySecret(ref)
            case .snippet: break
            }
            onClose()
        case .transform(let transform):
            guard let item = entry.clip else { return }
            guard let result = transform.apply(item.text) else {
                showNotice("Can't apply “\(transform.title)” to this item")
                return
            }
            let target = targetApp
            if !item.isTransient { env.store.touch(item) }
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
            if let item = entry.clip { beginShare([item]) }
        case .setUpAI:
            onClose()
            SettingsOpener.open()
        case .clearSlot(let number):
            env.slots.clear(number)
            mode = .browse
            refresh()
        case .togglePin:
            togglePinOnSelection()
            mode = .browse
        case .delete:
            mode = .browse
            deleteSelection(includingSecrets: true)
        }
    }

    private func performOnSelection(_ action: PanelAction) {
        let clips = selectedClips
        switch action {
        case .paste:
            pasteSelection()
        case .pastePlain:
            pasteSelection(transform: .plainText)
        case .copy:
            env.paste.write(clips, transform: nil)
            onClose()
        case .transform(let transform):
            let parts = clips.map { transform.apply($0.text) }
            guard parts.allSatisfy({ $0 != nil }) else {
                showNotice("Can't apply “\(transform.title)” to every selected item")
                return
            }
            let target = targetApp
            onClose()
            env.paste.paste(text: parts.compactMap { $0 }.joined(separator: "\n"), into: target)
        case .togglePin:
            togglePinOnSelectedClips()
            mode = .browse
        case .shareToGroup:
            beginShare(clips)
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

    func replaceItemWithAIOutput() {
        guard let run = aiRun, run.isFinished, !run.item.isTransient else { return }
        env.store.replaceText(of: run.item, with: run.output)
        resetMode()
        refresh()
        selectedID = PanelEntry.clip(run.item).id
        showNotice("Item replaced")
    }

    // MARK: Item actions

    func togglePinOnSelection() {
        guard let item = selectedEntry?.clip else { return }
        env.store.togglePin(item)
        refresh()
    }

    /// ⌫ never deletes secrets (too easy to hit by accident); ⌘K → Delete does.
    func deleteSelection(includingSecrets: Bool = false) {
        guard let entry = selectedEntry, let index = selectedIndex else { return }
        switch entry {
        case .clip(let item):
            env.slots.remove(target: entry.slotTarget)
            env.store.delete(item)
        case .secret(let ref):
            guard includingSecrets else { return }
            env.slots.remove(target: entry.slotTarget)
            env.secrets.delete(ref)
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
        case .snippetForm, .saveSecret, .label, .editSecret: handleFormKey(event)
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
            onClose()
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
            case "p":
                if isMultiSelecting { togglePinOnSelectedClips() } else { togglePinOnSelection() }
                return true
            case "a":
                // With an empty search field ⌘A selects every row; otherwise it selects the text.
                guard query.isEmpty else { return false }
                selectAll()
                return true
            case "k":
                openActions()
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
