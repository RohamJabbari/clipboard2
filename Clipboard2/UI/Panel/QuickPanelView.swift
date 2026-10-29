import SwiftUI

struct QuickPanelView: View {
    @Bindable var model: PanelViewModel
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    /// The content-type row that drops down from under the search bar.
    @State private var showsTypes = false
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
                .zIndex(1)
            if showsTypes {
                typeRow
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            FilterChips(selection: $model.filter, groupSelection: $model.groupFilter, groups: env.sync.groups,
                        thisAppName: model.targetRef?.name, dropModel: model)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Hairline()
            HStack(spacing: 0) {
                resultsList
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
                    updateVersion: env.updates.readyVersion,
                    syncIndicator: env.sync.indicator,
                    onUpdate: { env.updates.installNow() })
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
            typeFilterMenu
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

    private var activeType: PanelFilter? {
        model.groupFilter == nil && model.filter.isContentType ? model.filter : nil
    }

    private func setTypesShown(_ shown: Bool) {
        if reduceMotion { showsTypes = shown } else {
            withAnimation(.snappy(duration: 0.22)) { showsTypes = shown }
        }
    }

    /// Opens the type row under the search bar. Shows the active type so a filtered list is never a surprise.
    private var typeFilterMenu: some View {
        let active = activeType
        return Button { setTypesShown(!showsTypes) } label: {
            HStack(spacing: 4) {
                Image(systemName: active == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                if let active { Text(active.title).font(.callout.weight(.medium)) }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(showsTypes ? 180 : 0))
            }
            .foregroundStyle(active == nil && !showsTypes ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Show only text, images, files or snippets")
        .accessibilityLabel(active.map { "Filter: \($0.title)" } ?? "Filter by type")
        .accessibilityValue(showsTypes ? "Expanded" : "Collapsed")
    }

    /// Everything, Text, Images, Files, Snippets. Picking one applies it and folds the row back up.
    private var typeRow: some View {
        HStack(spacing: 6) {
            FilterChip(title: "Everything", symbol: PanelFilter.all.symbol, selected: activeType == nil) {
                model.groupFilter = nil
                model.filter = .all
                setTypesShown(false)
            }
            ForEach(PanelFilter.contentTypes) { type in
                FilterChip(title: type.title, symbol: type.symbol, selected: activeType == type) {
                    model.groupFilter = nil
                    model.filter = type
                    setTypesShown(false)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: List

    private var resultsList: some View {
        Group {
            if model.entries.isEmpty {
                ContentUnavailableView {
                    Label(model.query.isEmpty ? "Nothing Here Yet" : "No Matches",
                          systemImage: model.query.isEmpty ? model.filter.symbol : "magnifyingglass")
                } description: {
                    Text(model.query.isEmpty ? "Items appear as you copy them." : "Try fewer letters or another filter.")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                                PanelRow(entry: entry, shortcut: model.shortcutNumber(for: entry, at: index),
                                         isSelected: model.isSelected(entry),
                                         showsCheckmark: model.isMultiSelecting,
                                         groupName: entry.clip.flatMap(env.sync.copiedBy))
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
                                                             blobs: env.blobs))
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
            Button("Copy") { env.paste.copy(item) }
            Divider()
            Button(item.isPinned ? "Unpin" : "Pin") { env.store.togglePin(item); model.refresh() }
            Button(item.label == nil ? "Label…" : "Edit Label…") { model.beginLabel(entry) }
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
            Button("Delete", role: .destructive) { env.store.delete(item); model.refresh() }
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
                PreviewPane(entry: entry, onEditSecret: model.beginEditSecret, model: model)
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - Filter chips

struct FilterChips: View {
    @Binding var selection: PanelFilter
    @Binding var groupSelection: String?
    var groups: [SyncGroup] = []
    let thisAppName: String?
    /// When set, group chips accept dropped history items and files and share them to the group.
    var dropModel: PanelViewModel?

    var body: some View {
        if groups.isEmpty {
            chips
        } else {
            ScrollView(.horizontal, showsIndicators: false) { chips }
        }
    }

    private var chips: some View {
        HStack(spacing: 4) {
            ForEach(PanelFilter.chips) { filter in
                chip(title(for: filter), symbol: filter.symbol, selected: groupSelection == nil && filter == selection) {
                    groupSelection = nil
                    selection = filter
                }
            }
            ForEach(groups) { group in
                let select = {
                    groupSelection = group.id
                    selection = .all
                }
                if let dropModel {
                    GroupDropChip(group: group, selected: groupSelection == group.id, model: dropModel, action: select)
                } else {
                    chip(group.name, symbol: "person.2", selected: groupSelection == group.id, action: select)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        FilterChip(title: title, symbol: symbol, selected: selected, action: action)
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
        FilterChip(title: group.name, symbol: targeted ? "person.2.fill" : "person.2", selected: selected,
                   dropHighlighted: targeted, action: action)
            .onDrop(of: [.clipboard2Clip, .fileURL],
                    delegate: PanelDropDelegate(target: .group(group.id), model: model, isTargeted: $targeted))
            .help("Click to show \(group.name). Drop an item or a file here to share it.")
            .accessibilityHint("Drop items here to share them with \(group.name)")
    }
}

/// One capsule in the filter rows.
struct FilterChip: View {
    let title: String
    let symbol: String
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
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).imageScale(.small)
            }
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(dropHighlighted ? AnyShapeStyle(Color.accentColor)
                                 : selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .background {
                    if dropHighlighted {
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.16))
                            .overlay(Capsule(style: .continuous).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5))
                    } else if selected {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.09))
                            .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
                    }
                }
                .contentShape(Capsule())
                .scaleEffect(dropHighlighted && !reduceMotion ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) filter")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Row

struct PanelRow: View {
    let entry: PanelEntry
    let shortcut: (number: Int, isSlot: Bool)?
    let isSelected: Bool
    var showsCheckmark = false
    /// For a sync group item: who copied it (their username), shown as a badge.
    var groupName: String?

    var body: some View {
        HStack(spacing: 10) {
            if showsCheckmark {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Text(subtitle)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 4)
            if let groupName {
                Label(groupName, systemImage: "person.2.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .background(Capsule().strokeBorder(isSelected ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(.quaternary)))
                    .help("Shared with \(groupName)")
                    .accessibilityHidden(true)
            }
            if case .clip(let item) = entry, item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
            }
            if let shortcut {
                Text("⌘\(shortcut.number)")
                    .font(.caption.monospacedDigit().weight(shortcut.isSlot ? .semibold : .regular))
                    .padding(.horizontal, shortcut.isSlot ? 5 : 0)
                    .padding(.vertical, shortcut.isSlot ? 1 : 0)
                    .background {
                        if shortcut.isSlot {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tint))
                        }
                    }
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.9))
                                     : shortcut.isSlot ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .help(shortcut.isSlot ? "Quick slot ⌘\(shortcut.number)" : "")
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.12)))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText + (groupName.map { ", in group \($0)" } ?? "")
                            + (shortcut?.isSlot == true ? ", quick slot \(shortcut?.number ?? 0)" : ""))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Double-click or press Return to paste")
    }

    @ViewBuilder
    private var leading: some View {
        switch entry {
        case .clip(let item):
            ClipIconView(item: item, size: 28)
        case .snippet:
            Image(systemName: "text.badge.star")
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        case .secret:
            Image(systemName: "key.fill")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
    }

    private var title: String {
        switch entry {
        case .clip(let item): item.displayTitle
        case .snippet(let snippet): snippet.name.isEmpty ? "Untitled Snippet" : snippet.name
        case .secret(let ref): ref.name
        }
    }

    private var subtitle: String {
        switch entry {
        case .clip(let item):
            if item.label != nil {
                // Labelled: the label is the title, the value goes underneath.
                item.preview.isEmpty ? item.kind.displayName : item.preview
            } else {
                [item.sourceAppName, item.lastCopiedAt.shortRelative].compactMap { $0 }.joined(separator: " · ")
            }
        case .snippet(let snippet):
            snippet.keyword.isEmpty ? "Snippet" : "Snippet · \(snippet.keyword)"
        case .secret:
            "••••••••"
        }
    }

    private var accessibilityText: String {
        switch entry {
        case .clip(let item): item.accessibilityDescription
        case .snippet(let snippet): "Snippet \(snippet.name)"
        case .secret(let ref): "Secret \(ref.name)"
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
    /// A downloaded update waiting for a relaunch: shown quietly at the trailing end.
    var updateVersion: String?
    /// Sync state, shown as a dot and a few words at the trailing end while signed in.
    var syncIndicator: SyncIndicator = .hidden
    var onUpdate: () -> Void = {}

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
                hint("⌘P", "Pin")
                hint("⌫", "Delete")
            case .browse:
                hint("⏎", "Paste")
                if entry?.clip != nil {
                    hint("⌥⏎", "Plain Text")
                }
                if entry != nil {
                    hint("⌘K", "Actions")
                    if canEditText { hint("⌘E", "Edit") }
                    hint("⌘⇧1–9", "Assign Slot")
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
            Spacer()
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
            } else if mode == .browse && !syncIndicator.isVisible {
                hint("⇥", "Filter")
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
