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
            FilterChips(selection: $model.filter, groupSelection: $model.groupFilter, groups: env.sync.groups,
                        showsInbox: !model.sendableContacts.isEmpty,
                        thisAppName: model.targetRef?.name, dropModel: model)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Hairline()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
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
                    selectionCount: model.isMultiSelecting ? model.selectedClips.count : nil,
                    pickedFiles: model.pickedFileCount,
                    updateVersion: env.updates.readyVersion,
                    syncIndicator: env.sync.indicator,
                    onUpdate: { env.updates.installNow() },
                    tip: tips.isEmpty ? nil : tips[model.tipIndex % tips.count],
                    onNextTip: { model.tipIndex &+= 1 })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusToken) { searchFocused = ![.actions, .snippetForm, .saveSecret, .label, .editSecret, .shareToGroup].contains(model.mode) }
        .onChange(of: env.store.revision) { model.refresh() }
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
            if model.entries.isEmpty {
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
                                PanelRow(entry: entry, shortcut: model.shortcutNumber(for: entry, at: index),
                                         isSelected: model.isSelected(entry),
                                         showsCheckmark: model.isMultiSelecting,
                                         query: model.query,
                                         commandHeld: model.isCommandHeld,
                                         sharing: sharing(for: entry),
                                         badge: entry.clip.flatMap(env.sync.badge))
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

    @ViewBuilder
    private func contextMenu(for entry: PanelEntry) -> some View {
        Button("Paste") { model.activate(entry) }
        if case .secret = entry {
            Button("Edit…") { if case .secret(let ref) = entry { model.beginEditSecret(ref) } }
            Button("Rename…") { model.beginLabel(entry) }
            if case .secret(let ref) = entry, model.canShareToGroup, env.sync.groups.contains(where: { $0.id != ref.spaceID }) {
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
            Divider()
            Button(item.label == nil ? "Label…" : "Edit Label…") { model.beginLabel(entry) }
            if item.isPinned && item.label == nil {
                Button("Remove from Labelled") { model.removeFromLabelled(item) }
            }
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
            Button("Delete", role: .destructive) { env.store.delete(item); model.refresh() }
        }
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
        case .ai:
            if let run = model.aiRun {
                AIResultView(run: run, model: model)
            }
        case .browse:
            if model.isMultiSelecting {
                MultiSelectionPreview(clips: model.selectedClips, totalSelected: model.selectedIDs.count)
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

/// Every filter in one row, then the sync groups.
struct FilterChips: View {
    @Binding var selection: PanelFilter
    @Binding var groupSelection: String?
    var groups: [SyncGroup] = []
    /// The Inbox chip: what contacts sent you. Only once there are contacts.
    var showsInbox = false
    let thisAppName: String?
    /// When set, group chips accept dropped history items and files and share them to the group.
    var dropModel: PanelViewModel?

    var body: some View {
        if groups.isEmpty && !showsInbox {
            chips
        } else {
            ScrollView(.horizontal, showsIndicators: false) { chips }
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
                let select = {
                    groupSelection = group.id
                    selection = .all
                }
                if let dropModel {
                    GroupDropChip(group: group, selected: groupSelection == group.id, model: dropModel, action: select)
                } else {
                    FilterChip(title: group.name, symbol: "person.2.fill", tint: .purple, selected: groupSelection == group.id,
                               action: select)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func title(for filter: PanelFilter) -> String {
        if filter == .thisApp, let thisAppName { return thisAppName }
        return filter.title
    }
}

/// A group chip that's also a drop target: drag a row (or files from Finder) onto it to share.
private struct GroupDropChip: View {
    let group: SyncGroup
    let selected: Bool
    let model: PanelViewModel
    let action: () -> Void
    @State private var targeted = false

    var body: some View {
        FilterChip(title: group.name, symbol: "person.2.fill", tint: .purple, selected: selected,
                   dropHighlighted: targeted, action: action)
            .onDrop(of: [.clipboard2Clip, .fileURL],
                    delegate: PanelDropDelegate(target: .group(group.id), model: model, isTargeted: $targeted))
            .help("Click to show \(group.name). Drop an item or a file here to share it.")
            .accessibilityHint("Drop items here to share them with \(group.name)")
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
                Image(systemName: "tag.fill")
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
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
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor)
                      : hovering ? AnyShapeStyle(Color.primary.opacity(0.05)) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText + (sharing.map { ", shared in \($0.group)" } ?? badge.map { ", \($0.help)" } ?? "")
                            + (shortcut?.isSlot == true ? ", quick slot \(shortcut?.number ?? 0)" : ""))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Double-click or press Return to paste")
    }

    private var badgeKind: ContentBadge.Kind {
        switch entry {
        case .clip(let item): .clip(item)
        case .snippet: .snippet
        case .secret: .secret
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
        }
    }

    private var subtitleLine: some View {
        HStack(spacing: 4) {
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
    var selectionCount: Int?
    /// Some files of a multi-file item are picked in the preview: Return pastes only those.
    var pickedFiles: (picked: Int, total: Int)?
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
            case .browse:
                hint("⏎", pickedFiles.map { "Paste \($0.picked) of \($0.total) Files" } ?? "Paste")
                if entry?.clip != nil {
                    hint("⌥⏎", "Plain Text")
                }
                if entry != nil {
                    hint("⌘K", "Actions")
                    if canEditText { hint("⌘E", "Edit") }
                }
            case .actions:
                hint("↑↓", "Choose")
                hint("⏎", "Run")
            case .snippetForm:
                hint("⇥", "Next Field")
                hint("⏎", "Paste")
            case .saveSecret, .label, .editSecret:
                hint("⏎", "Save")
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
            if !isEditingText { hint("esc", mode == .browse ? "Close" : "Back") }
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
