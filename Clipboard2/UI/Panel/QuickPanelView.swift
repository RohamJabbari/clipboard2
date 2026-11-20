import SwiftUI
import KeyboardShortcuts

struct QuickPanelView: View {
    @Bindable var model: PanelViewModel
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    /// Files from Finder hovering over the list.
    @State private var listDropTargeted = false

    /// Tells the user a drop here adds to history.
    @ViewBuilder
    private var listDropHighlight: some View {
        if listDropTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                Label(model.groupFilter.flatMap(env.sync.groupName(for:)).map { "Add to \($0)" } ?? "Add to History",
                      systemImage: "plus.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule(style: .continuous))
            }
            .padding(6)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            FilterChips(selection: $model.filter, groupSelection: $model.groupFilter,
                        groupShowsSaved: $model.groupShowsSaved, groups: env.sync.groups,
                        showsInbox: !model.sendableContacts.isEmpty,
                        thisAppName: model.targetRef?.name, dropModel: model)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Hairline()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if model.isSavedView {
                        SavedHeader(model: model)
                    }
                    IncomingDownloadsBanner(downloads: env.sync.downloads.filter { download in
                        model.groupFilter.map { $0 == download.spaceId } ?? true
                    })
                    resultsList
                }
                .animation(.smooth(duration: 0.3), value: env.sync.downloads.isEmpty)
                .frame(width: listWidth)
                .overlay { listDropHighlight }
                .onDrop(of: [.fileURL, .clipboard2Clip],
                        delegate: PanelDropDelegate(target: .list, model: model, isTargeted: $listDropTargeted))
                Hairline(vertical: true)
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.025))
            }
            Hairline()
            HintBar(entry: model.selectedEntry, mode: model.mode, notice: model.notice,
                    isEditingText: model.isEditingText,
                    canEditText: model.selectedEntry?.clip.map(model.isEditable) ?? false,
                    inFolder: model.openFolder != nil,
                    selectionCount: model.isMultiSelecting ? model.selectedClips.count : nil,
                    pickedFiles: model.pickedFileCount,
                    canQuickLook: model.canQuickLook,
                    updateVersion: env.updates.readyVersion,
                    syncIndicator: env.sync.indicator,
                    onUpdate: { env.updates.installNow() },
                    tip: tips.isEmpty ? nil : tips[model.tipIndex % tips.count],
                    onNextTip: { model.tipIndex &+= 1 })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusToken) {
            searchFocused = ![.actions, .snippetForm, .saveSecret, .label, .editSecret, .shareToGroup, .folderName,
                              .authenticatorForm, .authenticatorPeople].contains(model.mode)
        }
        .onChange(of: env.store.revision) { model.refresh() }
        .onChange(of: env.authenticators.revision) { model.refresh() }
        .onChange(of: env.authenticators.suggestion) { model.refresh() }
        .onChange(of: env.snippets.revision) { model.refresh() }
        .onChange(of: env.secrets.revision) { model.refresh() }
    }

    private var listWidth: CGFloat {
        env.prefs.panelSize.size.width * 0.44
    }

    /// One rotates into the hint bar on every open, with the user's own shortcuts.
    private var tips: [String] {
        var tips = ["Hold ⌘ to see each row's quick-paste number",
                    "⌘⇧1–9 keeps the selected item on that number"]
        if let keys = KeyboardShortcuts.getShortcut(for: .selectionActions) {
            tips.append("Select text in any app, then \(keys) to fix or translate it")
        }
        if env.prefs.contextMenuEnabled {
            tips.append("\(env.prefs.contextMenuModifier.symbol)-right-click in any app for Clipboard2's menu")
        }
        if let keys = KeyboardShortcuts.getShortcut(for: .pasteAsText) {
            tips.append("\(keys) pastes the text inside a screenshot")
        }
        if let keys = KeyboardShortcuts.getShortcut(for: .captureText) {
            tips.append("\(keys) copies text from anywhere on screen")
        }
        return tips
    }

    /// Group and member for an item that lives in a sync group.
    private func sharing(for entry: PanelEntry) -> PreviewSharing? {
        guard let clip = entry.clip, let spaceID = clip.spaceID,
              let group = env.sync.groups.first(where: { $0.id == spaceID }) else { return nil }
        let person = env.sync.copiedBy(clip)
        return PreviewSharing(group: group.name, person: person == group.name ? nil : person, memberCount: group.memberCount)
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search clipboard", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .regular))
                .focused($searchFocused)
                .accessibilityLabel("Search clipboard history and snippets")
            if let target = model.targetRef {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Image(nsImage: AppIconCache.icon(for: target.bundleID))
                        .resizable()
                        .frame(width: 15, height: 15)
                    Text(target.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 7)
                .padding(.trailing, 9)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
                .help("Pastes into \(target.name)")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Pastes into \(target.name)")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: List

    private var resultsList: some View {
        Group {
            if model.entries.isEmpty && model.isSavedView && model.query.isEmpty {
                ContentUnavailableView {
                    Label(model.openFolder != nil ? "This Folder Is Empty" : "Nothing Saved Yet",
                          systemImage: model.openFolder != nil ? "folder" : "bookmark")
                } description: {
                    Text(model.openFolder != nil
                         ? "Drag items here, or use Move to Folder in an item's actions."
                         : "Use Add to Saved or a label to keep an item forever.")
                }
            } else if model.entries.isEmpty {
                let inbox = model.filter == .inbox && model.groupFilter == nil
                ContentUnavailableView {
                    Label(model.query.isEmpty ? (inbox ? "Your Inbox Is Empty" : "Nothing Here Yet") : "No Matches",
                          systemImage: model.query.isEmpty ? model.filter.symbol : "magnifyingglass")
                } description: {
                    Text(model.query.isEmpty
                         ? (inbox ? "What your contacts send you shows up here." : "Items appear as you copy them.")
                         : "Try fewer letters or another filter.")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                                if let title = model.sectionStarts[entry.id] {
                                    SectionHeading(title: title, isFirst: index == 0)
                                }
                                if let folder = entry.folder {
                                    FolderDropRow(entry: entry, folder: folder, model: model)
                                        .id(entry.id)
                                        .contextMenu { folderContextMenu(folder) }
                                } else if let item = entry.authenticator {
                                    AuthenticatorRow(item: item, isSelected: model.isSelected(entry),
                                                     showsCheckmark: model.isMultiSelecting, query: model.query,
                                                     shareCount: model.shareCount(of: item), clock: model.otpClock)
                                        .id(entry.id)
                                        .onTapGesture { tap(entry) }
                                        .contextMenu { authenticatorContextMenu(item) }
                                } else if case .authenticatorSuggestion(let account) = entry {
                                    AuthenticatorSuggestionRow(account: account, isSelected: model.isSelected(entry))
                                        .id(entry.id)
                                        .onTapGesture { tap(entry) }
                                        .contextMenu {
                                            Button("Add…") { model.beginAddAuthenticator(from: account) }
                                            Button("Dismiss") { model.dismissSuggestion() }
                                        }
                                } else {
                                    row(for: entry, at: index)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .onChange(of: model.openToken) {
                        if let first = model.entries.first?.id { proxy.scrollTo(first, anchor: .top) }
                    }
                    .onChange(of: model.selectedID) { _, id in
                        guard let id else { return }
                        if reduceMotion {
                            proxy.scrollTo(id)
                        } else {
                            withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(id) }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Results")
    }

    private func row(for entry: PanelEntry, at index: Int) -> some View {
        PanelRow(entry: entry, shortcut: model.shortcutNumber(for: entry, at: index),
                 isSelected: model.isSelected(entry),
                 showsCheckmark: model.isMultiSelecting,
                 query: model.query,
                 commandHeld: model.isCommandHeld,
                 sharing: sharing(for: entry),
                 badge: entry.clip.flatMap(env.sync.badge),
                 folderCaption: model.folderCaptions[entry.id])
            .id(entry.id)
            // One recogniser reading AppKit's click count: SwiftUI's stacked
            // count:2 / count:1 gestures miss double-clicks in a non-activating panel.
            .onTapGesture {
                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                    if model.isMultiSelecting && model.isSelected(entry) {
                        model.pasteSelection()
                    } else {
                        model.activate(entry)
                    }
                } else {
                    model.click(entry)
                }
            }
            .contextMenu { contextMenu(for: entry) }
            .modifier(ClipDragSource(item: entry.clip.flatMap { $0.isTransient ? nil : $0 },
                                     blobs: env.blobs, pickedFiles: model.pickedFileURLs))
            .modifier(SecretDragSource(ref: entry.secret))
    }

    /// A click selects; a double-click activates (pastes the code, or opens the add form).
    private func tap(_ entry: PanelEntry) {
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            model.activate(entry)
        } else {
            model.click(entry)
        }
    }

    @ViewBuilder
    private func authenticatorContextMenu(_ item: AuthenticatorItem) -> some View {
        let actions = PanelAction.authenticatorActions(for: item, signedIn: env.sync.isSignedIn,
                                                       shareCount: model.shareCount(of: item))
        Button("Paste Code") { model.pasteCode(of: item) }
        Button("Copy Code") { model.copyCode(of: item) }
        let more = actions.compactMap { action -> AuthenticatorAction? in
            if case .authenticator(let a) = action { a } else { nil }
        }
        if !more.isEmpty { Divider() }
        ForEach(more, id: \.self) { action in
            if action == .delete || action == .leave {
                Divider()
                Button(action == .delete ? "Delete…" : action.title, role: .destructive) { model.perform(action, on: item) }
            } else {
                Button(action.title) { model.perform(action, on: item) }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: PanelEntry) -> some View {
        Button("Paste") { model.activate(entry) }
        if let ref = entry.secret {
            Button("Edit…") { model.beginEditSecret(ref) }
            Button("Rename…") { model.beginLabel(entry) }
            folderMenuItems(for: entry)
            if model.canShareToGroup, env.sync.groups.contains(where: { $0.id != ref.spaceID }) {
                Button("Share to Group…") { model.beginShareSecret(ref) }
            }
        }
        Menu("Assign to Quick Slot") {
            ForEach(QuickSlots.range, id: \.self) { n in
                Button("⌘\(n)\(env.slots.title(for: n).map { " — " + $0 } ?? "")") {
                    model.selectedID = entry.id
                    model.assignSelection(toSlot: n)
                }
            }
        }
        if let item = entry.clip {
            Button("Paste as Plain Text") { model.activate(entry, transform: .plainText) }
            Button("Copy") { model.copy(item) }
            if !item.isTransient && model.quickLookFiles.canPreview(entry) {
                Button("Quick Look") { model.quickLook(entry) }
            }
            Divider()
            Button(item.label == nil ? "Label…" : "Edit Label…") { model.beginLabel(entry) }
            savedMenuItems(for: entry, item: item)
            if item.kind.isTextual {
                Button("Save as Secret…") { model.beginSaveSecret(item) }
            }
            let sends = PanelAction.sendToDeviceActions(for: item, multiSelecting: false,
                                                        targets: DeviceTarget.others(in: env.sync))
            ForEach(sends) { action in
                if case .sendToDevice(let device) = action {
                    Button("Send to \(device.name)") { model.send(item, to: device) }
                }
            }
            if model.canShareToGroup {
                Menu("Share to Group") {
                    ForEach(env.sync.groups) { group in
                        Button(group.name) { model.share([item], to: group) }
                            .disabled(item.spaceID == group.id)
                    }
                }
            }
            contactSends(for: entry, item: item)
            Divider()
            Button("Save to \(env.prefs.saveFolderName)") {
                model.save(model.clipsForContextAction(on: entry), to: env.prefs.saveFolder)
            }
            Button("Save to…") { model.saveChoosingFolder(model.clipsForContextAction(on: entry)) }
            Divider()
            if model.isGroupSpace(item.spaceID) {
                // Gone for everyone in the group, like Delete always was there.
                Button("Remove from Group", role: .destructive) { removeFromGroup(model.clipsForContextAction(on: entry)) }
            } else {
                Button("Delete", role: .destructive) { env.store.delete(item); model.refresh() }
            }
        }
    }

    private func removeFromGroup(_ clips: [ClipItem]) {
        for clip in clips where model.isGroupSpace(clip.spaceID) {
            env.slots.remove(target: .clip(clip.id))
            env.store.delete(clip)
        }
        model.refresh()
    }

    /// Add to Saved (or Save a Copy), Remove from Saved, Move to Folder ▸ and Remove from Folder,
    /// for the row or the selection it's part of.
    @ViewBuilder
    private func savedMenuItems(for entry: PanelEntry, item: ClipItem) -> some View {
        let clips = model.clipsForContextAction(on: entry).filter { !$0.isTransient }
        if !clips.isEmpty {
            let changeable = clips.allSatisfy(env.sync.canChange)
            if changeable && clips.contains(where: { !$0.isPinned }) {
                Button("Add to Saved") { model.addToSaved(clips) }
            }
            if !changeable {
                Button("Save a Copy") { model.saveCopies(clips) }
            }
            folderMenuItems(for: entry)
            if changeable && clips.contains(where: { $0.isPinned && $0.label == nil }) {
                Button("Remove from Saved") { model.removeFromSaved(clips) }
            }
        }
    }

    /// Move to Folder ▸ (the group's folders under its name, yours under "Mine") and Remove from
    /// Folder, for a clip or secret row or the selection it's part of.
    @ViewBuilder
    private func folderMenuItems(for entry: PanelEntry) -> some View {
        let (clips, secrets) = model.itemsForContextAction(on: entry)
        if let menu = model.folderMenu(for: clips, secrets: secrets) {
            Menu("Move to Folder") {
                if let group = menu.group {
                    Section(group.name) {
                        ForEach(group.folders) { folder in
                            Button(folder.name) { model.place(clips, secrets: secrets, in: folder) }
                        }
                        Button("New Folder…") { model.beginNewFolder(moving: clips, secrets: secrets) }
                    }
                }
                if menu.copiesToPersonal {
                    Section("Mine") { personalFolderItems(menu, clips: clips, secrets: secrets) }
                } else {
                    personalFolderItems(menu, clips: clips, secrets: secrets)
                }
            }
        }
        let inFolder = clips.contains { model.folder(of: $0) != nil } || secrets.contains { model.folder(of: $0) != nil }
        let changeable = clips.allSatisfy(env.sync.canChange)
            && secrets.allSatisfy { env.sync.canChange(itemID: $0.id, spaceID: $0.spaceID) }
        if inFolder && changeable {
            Button("Remove from Folder") { model.removeFromFolder(clips, secrets: secrets) }
        }
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: ClipFolder) -> some View {
        Button("Open") { model.openFolder(folder) }
        Button("Rename…") { model.beginRename(folder) }
        Button(folder.label == nil ? "Label…" : "Edit Label…") { model.beginLabel(.folder(folder)) }
        if folder.spaceID == nil && model.canShareToGroup {
            Button("Share to Group…") { model.beginShareFolder(folder) }
        }
        Divider()
        Button("Delete Folder", role: .destructive) { model.deleteFolder(folder) }
    }

    @ViewBuilder
    private func personalFolderItems(_ menu: PanelViewModel.FolderMenu, clips: [ClipItem], secrets: [SecretRef]) -> some View {
        ForEach(menu.personal) { folder in
            Button(folder.name) { model.place(clips, secrets: secrets, in: folder) }
        }
        if !menu.personal.isEmpty { Divider() }
        Button("New Folder…") { model.beginNewFolder(moving: clips, secrets: secrets, personal: menu.copiesToPersonal) }
    }

    /// "Send to ‹contact›" for the row (or the selection it's part of); a submenu once there are many.
    @ViewBuilder
    private func contactSends(for entry: PanelEntry, item: ClipItem) -> some View {
        let contacts = model.sendableContacts.filter { $0.id != item.spaceID }
        let send = { (contact: SyncContact) in model.send(model.clipsForContextAction(on: entry), to: contact) }
        if contacts.count > 4 {
            Menu("Send to Contact") {
                ForEach(contacts) { contact in Button(contact.name) { send(contact) } }
            }
        } else {
            ForEach(contacts) { contact in Button("Send to \(contact.name)") { send(contact) } }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPane: some View {
        switch model.mode {
        case .actions:
            ActionMenuView(model: model)
        case .snippetForm:
            if let form = model.snippetForm {
                SnippetFormView(form: form) { model.submitSnippetForm() }
            }
        case .label:
            if let form = model.labelForm {
                LabelFormView(form: form) { model.submitLabel() }
            }
        case .editSecret:
            if let form = model.editSecretForm {
                EditSecretView(form: form) { model.submitEditSecret() }
            }
        case .shareToGroup:
            if let form = model.shareForm {
                ShareToGroupView(form: form) { model.submitShare() }
            }
        case .saveSecret:
            if let form = model.saveSecretForm {
                SaveSecretView(form: form) { model.submitSaveSecret() }
            }
        case .folderName:
            if let form = model.folderNameForm {
                FolderNameView(form: form) { model.submitFolderName() }
            }
        case .authenticatorForm:
            if let form = model.authenticatorForm {
                AuthenticatorFormView(form: form) { model.submitAuthenticatorForm() }
            }
        case .authenticatorPeople:
            if let form = model.peopleForm {
                AuthenticatorPeopleView(form: form, model: model)
            }
        case .ai:
            if let run = model.aiRun {
                AIResultView(run: run, model: model)
            }
        case .browse:
            if model.isMultiSelecting {
                MultiSelectionPreview(clips: model.selectedClips, totalSelected: model.selectedIDs.count)
            } else if let folder = model.selectedEntry?.folder {
                FolderPreview(folder: folder, count: model.folderCounts[folder.id] ?? 0, model: model)
                    .id(folder.id)
            } else if let item = model.selectedEntry?.authenticator {
                AuthenticatorPreview(item: item, model: model)
                    .id(item.id)
            } else if case .authenticatorSuggestion(let account) = model.selectedEntry {
                AuthenticatorSuggestionPreview(account: account, model: model)
            } else if let entry = model.selectedEntry {
                PreviewPane(entry: entry, sharing: sharing(for: entry), onEditSecret: model.beginEditSecret,
                            onPasteText: model.pasteText, onSaveAsSecret: model.beginSaveSecret, model: model)
                    .id(entry.id)
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - Filter chips

/// Every filter in one row, then the sync groups. The selected group's chip grows into a pill
/// with its Copies | Saved segments.
struct FilterChips: View {
    @Binding var selection: PanelFilter
    @Binding var groupSelection: String?
    /// The selected group's segment: its Saved (true) or its Copies.
    @Binding var groupShowsSaved: Bool
    var groups: [SyncGroup] = []
    /// The Inbox chip: what contacts sent you. Only once there are contacts.
    var showsInbox = false
    let thisAppName: String?
    /// When set, group chips accept dropped history items and files and share them to the group.
    var dropModel: PanelViewModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if groups.isEmpty && !showsInbox {
            chips
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) { chips }
                    // A pill that opens near the trailing edge slides into view as it grows.
                    .onChange(of: groupSelection) { _, id in
                        guard let id else { return }
                        if reduceMotion {
                            proxy.scrollTo(id)
                        } else {
                            withAnimation(ChipMotion.morph) { proxy.scrollTo(id) }
                        }
                    }
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 2) {
            ForEach(PanelFilter.chips(hasContacts: showsInbox)) { filter in
                FilterChip(title: title(for: filter), selected: groupSelection == nil && filter == selection) {
                    groupSelection = nil
                    selection = filter
                }
            }
            if !groups.isEmpty {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 6)
                    .accessibilityHidden(true)
            }
            ForEach(groups) { group in
                GroupChip(group: group, selected: groupSelection == group.id, showsSaved: $groupShowsSaved,
                          dropModel: dropModel) {
                    groupSelection = group.id
                    selection = .all
                }
                .id(group.id)
            }
            Spacer(minLength: 0)
        }
        // The morph runs however the selection changes: a click or ⇥ (opening the panel resets it
        // without animating).
        .animation(reduceMotion ? nil : ChipMotion.morph, value: groupSelection)
        .animation(reduceMotion ? nil : ChipMotion.morph, value: groupShowsSaved)
    }

    private func title(for filter: PanelFilter) -> String {
        if filter == .thisApp, let thisAppName { return thisAppName }
        return filter.title
    }
}

/// The filter row's motion: one spring for the group pill opening, closing and its segment
/// highlight sliding. Critically damped enough not to overshoot, quick enough to feel direct.
enum ChipMotion {
    static let morph = Animation.spring(response: 0.35, dampingFraction: 0.9)
    /// The segment labels wait for the pill to start widening, then fade in.
    static let labelsIn = Animation.easeOut(duration: 0.2).delay(0.08)
    /// On the way back they go first, quickly, so the pill closes on its own name.
    static let labelsOut = Animation.easeIn(duration: 0.1)
    static let tint = Color.purple
}

/// A sync group in the filter row. Unselected it's a compact chip; selected it grows into one
/// pill — the group, then **Copies · Saved** — with the active segment filled and its highlight
/// sliding between them. Also a drop target: drop a row or a file on it to share it.
struct GroupChip: View {
    let group: SyncGroup
    let selected: Bool
    @Binding var showsSaved: Bool
    var dropModel: PanelViewModel?
    let onSelect: () -> Void
    @State private var dropTargeted = false
    @Namespace private var segmentSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        let pill = HStack(spacing: 0) {
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
        .background { background }
        // The segments are revealed by the growing pill, never drawn outside it.
        .clipShape(shape)
        .overlay {
            if dropTargeted { shape.strokeBorder(ChipMotion.tint.opacity(0.8), lineWidth: 1.5) }
        }
        .scaleEffect(dropTargeted && !reduceMotion ? 1.06 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.name) group")

        if let dropModel {
            pill
                .onDrop(of: [.clipboard2Clip, .fileURL],
                        delegate: PanelDropDelegate(target: .group(group.id), model: dropModel, isTargeted: $dropTargeted))
                .help(selected ? "Drop an item or a file here to share it with \(group.name)."
                      : "Click to show \(group.name). Drop an item or a file here to share it.")
                .accessibilityHint("Drop items here to share them with \(group.name)")
        } else {
            pill
        }
    }

    /// The group's icon and name. Clicking it on an open pill changes nothing.
    private var nameButton: some View {
        Button {
            guard !selected else { return }
            onSelect()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.2.fill").imageScale(.small)
                Text(group.name)
            }
            .padding(.leading, 10)
            .padding(.trailing, selected ? 4 : 10)
            .padding(.vertical, 4)
            .foregroundStyle(ChipMotion.tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.name) filter")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var segments: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(ChipMotion.tint.opacity(0.3))
                .frame(width: 1, height: 13)
                .padding(.trailing, 3)
                .accessibilityHidden(true)
            segment("Copies", saved: false)
            segment("Saved", saved: true)
        }
        .padding(.vertical, 2)
        .padding(.trailing, 2)
    }

    private func segment(_ title: String, saved: Bool) -> some View {
        let active = showsSaved == saved
        return Button {
            showsSaved = saved
        } label: {
            Text(title)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(ChipMotion.tint))
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ChipMotion.tint)
                            .matchedGeometryEffect(id: "highlight", in: segmentSpace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.name) \(title.lowercased())")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var background: some View {
        if dropTargeted {
            shape.fill(ChipMotion.tint.opacity(0.16))
        } else {
            shape.fill(ChipMotion.tint.opacity(selected ? 0.16 : 0.13))
        }
    }
}

/// One tab in the filter row. Sync groups are tinted, so shared items read as shared everywhere.
struct FilterChip: View {
    let title: String
    var symbol: String?
    var tint: Color?
    let selected: Bool
    /// Something droppable is hovering over this chip.
    var dropHighlighted = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if reduceMotion { action() } else {
                withAnimation(.snappy(duration: 0.15)) { action() }
            }
        } label: {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).imageScale(.small)
                }
                Text(title)
            }
            .font(.callout.weight(selected ? .semibold : .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(foreground)
            .background { background }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(dropHighlighted && !reduceMotion ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) filter")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var foreground: AnyShapeStyle {
        if dropHighlighted { return AnyShapeStyle(tint ?? .accentColor) }
        if let tint { return selected ? AnyShapeStyle(.white) : AnyShapeStyle(tint) }
        return selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if dropHighlighted {
            let color = tint ?? .accentColor
            shape.fill(color.opacity(0.16))
                .overlay(shape.strokeBorder(color.opacity(0.8), lineWidth: 1.5))
        } else if let tint {
            shape.fill(selected ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.13)))
        } else if selected {
            shape.fill(.background)
                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

/// "Today", "Yesterday"… above the first row of each day in the list.
struct SectionHeading: View {
    let title: String
    var isFirst = false

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, isFirst ? 4 : 12)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Row

struct PanelRow: View {
    let entry: PanelEntry
    let shortcut: (number: Int, isSlot: Bool)?
    let isSelected: Bool
    var showsCheckmark = false
    /// Characters it matched are highlighted in the title.
    var query = ""
    /// ⌘ is held: show every row's ⌘-number.
    var commandHeld = false
    /// For a sync group item: the group and who copied it, shown under the title.
    var sharing: PreviewSharing?
    /// For a contact's item: who it's from or to (group items show `sharing` instead).
    var badge: SyncBadge?
    /// A search result inside a folder (from the Saved root): the folder's name.
    var folderCaption: String?
    /// A folder row: how many saved items it holds.
    var folderCount = 0
    /// Something droppable hovers over this folder row.
    var dropHighlighted = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if showsCheckmark {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
            ContentBadge(kind: badgeKind, isSelected: isSelected)
            VStack(alignment: .leading, spacing: 2) {
                Text(SearchHighlight.text(title, query: query, onAccent: isSelected))
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                subtitleLine
            }
            Spacer(minLength: 4)
            if let badge, sharing == nil {
                Label(badge.text, systemImage: badge.symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .background(Capsule().strokeBorder(isSelected ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(.quaternary)))
                    .help(badge.help)
                    .accessibilityHidden(true)
            }
            if case .clip(let item) = entry, item.isPinned {
                Image(systemName: item.label == nil ? "bookmark.fill" : "tag.fill")
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
            }
            if case .folder(let folder) = entry {
                folderTrailing(folder)
            }
            if let shortcut, shortcut.isSlot || isSelected || hovering || commandHeld {
                Text("⌘\(shortcut.number)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(isSelected ? AnyShapeStyle(.white.opacity(0.6))
                                          : shortcut.isSlot ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    }
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white)
                                     : shortcut.isSlot ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .help(shortcut.isSlot ? "Quick slot ⌘\(shortcut.number)" : "⌘\(shortcut.number) pastes this row")
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background { rowBackground }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fullAccessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(entry.folder == nil ? "Double-click or press Return to paste" : "Click or press Return to open")
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if dropHighlighted {
            shape.fill(Color.accentColor.opacity(0.16))
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5))
        } else {
            shape.fill(isSelected ? AnyShapeStyle(Color.accentColor)
                       : hovering ? AnyShapeStyle(Color.primary.opacity(0.05)) : AnyShapeStyle(.clear))
        }
    }

    private var fullAccessibilityLabel: String {
        var text = accessibilityText
        if let sharing { text += ", shared in \(sharing.group)" } else if let badge { text += ", \(badge.help)" }
        if let folderCaption { text += ", in folder \(folderCaption)" }
        if let shortcut, shortcut.isSlot { text += ", quick slot \(shortcut.number)" }
        return text
    }

    /// A folder row's label tag and disclosure chevron.
    @ViewBuilder
    private func folderTrailing(_ folder: ClipFolder) -> some View {
        if let label = folder.label {
            Label(label, systemImage: "tag.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .background(Capsule().strokeBorder(isSelected ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(.quaternary)))
                .accessibilityHidden(true)
        }
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            .accessibilityHidden(true)
    }

    private var badgeKind: ContentBadge.Kind {
        switch entry {
        case .clip(let item): .clip(item)
        case .snippet: .snippet
        case .secret: .secret
        case .folder: .folder
        case .authenticator, .authenticatorSuggestion: .authenticator
        }
    }

    /// A confidently recognised credential, hidden in the list until selected and revealed.
    private var hiddenKind: SensitiveText.Kind? {
        guard case .clip(let item) = entry, case .sensitive(let kind) = ClipContentCache.content(of: item),
              kind.isConfident else { return nil }
        return kind
    }

    private var title: String {
        switch entry {
        case .clip(let item):
            if item.label == nil, let hiddenKind { return SensitiveText.masked(item.text, kind: hiddenKind) }
            return item.displayTitle
        case .snippet(let snippet): return snippet.name.isEmpty ? "Untitled Snippet" : snippet.name
        case .secret(let ref): return ref.name
        case .folder(let folder): return folder.name
        case .authenticator(let item): return item.title
        case .authenticatorSuggestion: return "Add to Authenticator"
        }
    }

    private var subtitleLine: some View {
        HStack(spacing: 4) {
            if let folderCaption {
                Image(systemName: "folder.fill")
                    .imageScale(.small)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.blue))
                Text(folderCaption)
                    .fontWeight(.semibold)
                Text("·")
            }
            if let sharing {
                Image(systemName: "person.2.fill")
                    .imageScale(.small)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.purple))
                Text(sharing.person.map { "\($0) in \(sharing.group)" } ?? sharing.group)
                    .fontWeight(.semibold)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.purple))
                Text("·")
            } else if let hiddenKind {
                Image(systemName: "eye.slash.fill")
                    .imageScale(.small)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.orange))
                Text("Hidden \(hiddenKind.inlineName)")
                    .fontWeight(.semibold)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.orange))
                Text("·")
            }
            if case .clip(let item) = entry, item.label == nil, let bundleID = item.sourceBundleID {
                Image(nsImage: AppIconCache.icon(for: bundleID))
                    .resizable()
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            }
            Text(subtitle)
        }
        .font(.caption)
        .lineLimit(1)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
    }

    private var subtitle: String {
        switch entry {
        case .clip(let item):
            if item.label != nil {
                // Labelled: the label is the title, the value goes underneath.
                if let hiddenKind { return SensitiveText.masked(item.text, kind: hiddenKind) }
                return item.preview.isEmpty ? item.kind.displayName : item.preview
            }
            if sharing != nil { return item.lastCopiedAt.shortRelative }
            return [item.sourceAppName, item.lastCopiedAt.shortRelative].compactMap { $0 }.joined(separator: " · ")
        case .snippet(let snippet):
            return snippet.keyword.isEmpty ? "Snippet" : "Snippet · \(snippet.keyword)"
        case .secret:
            return "Secret · ••••••••"
        case .folder:
            return folderCount == 1 ? "Folder · 1 item" : "Folder · \(folderCount) items"
        case .authenticator(let item): return item.subtitle
        case .authenticatorSuggestion(let account): return account.issuer
        }
    }

    private var accessibilityText: String {
        switch entry {
        case .clip(let item):
            if let hiddenKind {
                return "Hidden \(hiddenKind.inlineName)" + (item.sourceAppName.map { ", from \($0)" } ?? "")
            }
            return item.accessibilityDescription
        case .snippet(let snippet): return "Snippet \(snippet.name)"
        case .secret(let ref): return "Secret \(ref.name)"
        case .folder(let folder):
            return "Folder \(folder.name)" + (folder.label.map { ", label \($0)" } ?? "")
                + ", \(folderCount) \(folderCount == 1 ? "item" : "items")"
        case .authenticator(let item): return "Authenticator \(item.title)"
        case .authenticatorSuggestion: return "Add to Authenticator"
        }
    }
}

// MARK: - Hint bar

struct HintBar: View {
    let entry: PanelEntry?
    let mode: PanelMode
    let notice: String?
    var isEditingText = false
    var canEditText = false
    /// A Saved folder is open: esc goes back to the root.
    var inFolder = false
    var selectionCount: Int?
    /// Some files of a multi-file item are picked in the preview: Return pastes only those.
    var pickedFiles: (picked: Int, total: Int)?
    /// The selection can be shown in Quick Look (⌘Y).
    var canQuickLook = false
    /// A downloaded update waiting for a relaunch: shown quietly at the trailing end.
    var updateVersion: String?
    /// Sync state, shown as a dot and a few words at the trailing end while signed in.
    var syncIndicator: SyncIndicator = .hidden
    var onUpdate: () -> Void = {}
    /// A rotating tip that teaches one shortcut at a time; clicking shows the next.
    var tip: String?
    var onNextTip: () -> Void = {}

    var body: some View {
        HStack(spacing: 14) {
            switch mode {
            case .browse where isEditingText:
                hint("esc", "Done")
                hint("⌘⏎", "Paste")
                hint("⌘B ⌘I ⌘U", "Style")
                hint("⌘Z", "Undo")
            case .browse where selectionCount != nil:
                hint("⏎", "Paste \(selectionCount ?? 0) Items")
                hint("⌥⏎", "Plain Text")
                hint("⌘K", "Actions")
                hint("⌫", "Delete")
            case .browse where entry?.folder != nil:
                hint("⏎", "Open")
                hint("⌘K", "Actions")
            case .browse where entry?.authenticator != nil:
                hint("⏎", "Paste Code")
                hint("⌘K", "Actions")
            case .browse where entry?.isSuggestion == true:
                hint("⏎", "Add")
                hint("esc", "Dismiss")
            case .browse:
                hint("⏎", pickedFiles.map { "Paste \($0.picked) of \($0.total) Files" } ?? "Paste")
                if entry?.clip != nil {
                    hint("⌥⏎", "Plain Text")
                }
                if entry != nil {
                    hint("⌘K", "Actions")
                    if canQuickLook { hint("⌘Y", "Preview") }
                    if canEditText { hint("⌘E", "Edit") }
                }
            case .actions:
                hint("↑↓", "Choose")
                hint("⏎", "Run")
            case .snippetForm:
                hint("⇥", "Next Field")
                hint("⏎", "Paste")
            case .saveSecret, .label, .editSecret, .folderName, .authenticatorForm:
                hint("⏎", "Save")
            case .authenticatorPeople:
                hint("↑↓", "Choose")
                hint("⏎", "Choose")
            case .shareToGroup:
                hint("↑↓", "Choose")
                hint("⏎", "Share")
            case .ai:
                hint("⏎", "Paste")
                hint("⌘C", "Copy")
                hint("⌘R", "Replace Item")
            }
            Spacer(minLength: 8)
            if let notice {
                Text(notice)
                    .foregroundStyle(.primary)
                    .transition(.opacity)
            } else if let updateVersion, mode == .browse {
                Button(action: onUpdate) {
                    Label("Restart to Update", systemImage: "arrow.down.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Clipboard2 \(updateVersion) is ready. Relaunches in a second; your history stays.")
            } else if let tip, mode == .browse, selectionCount == nil, !syncIndicator.isVisible {
                Button(action: onNextTip) {
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb")
                        Text(tip).lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.right").imageScale(.small)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Next tip")
                .accessibilityLabel("Tip: \(tip)")
                .accessibilityHint("Shows the next tip")
            }
            if notice == nil && syncIndicator.isVisible {
                // Quiet by design: the dot carries the state, the text says when.
                SyncStatusLabel(indicator: syncIndicator)
                    .layoutPriority(-1)
                    .help(syncIndicator.offersSyncNow ? "\(syncIndicator.title()) — use Sync Now in the menu bar menu" : syncIndicator.title())
            }
            if !isEditingText { hint("esc", mode == .browse && !inFolder ? "Close" : "Back") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
        }
        .fixedSize()
    }
}

/// Synced items still downloading (a big file someone just sent): they appear in the list once
/// they're complete, so this says something is coming and how far along it is.
struct IncomingDownloadsBanner: View {
    let downloads: [IncomingDownload]

    var body: some View {
        if let first = downloads.first {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeating)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Receiving \(first.name)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if downloads.count > 1 {
                            Text("+\(downloads.count - 1)")
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(first.progressText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout.weight(.medium))
                    if let fraction = first.fraction {
                        ProgressView(value: fraction)
                            .animation(.smooth(duration: 0.2), value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}

/// A 1-pt separator that sits quietly on glass.
struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}
