import SwiftUI

struct QuickPanelView: View {
    @Bindable var model: PanelViewModel
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            FilterChips(selection: $model.filter, thisAppName: model.targetRef?.name)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Divider()
            HStack(spacing: 0) {
                resultsList
                    .frame(width: listWidth)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HintBar(entry: model.selectedEntry, mode: model.mode, notice: model.notice,
                    selectionCount: model.isMultiSelecting ? model.selectedClips.count : nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusToken) { searchFocused = ![.actions, .snippetForm, .saveSecret, .label].contains(model.mode) }
        .onChange(of: env.store.revision) { model.refresh() }
        .onChange(of: env.snippets.revision) { model.refresh() }
        .onChange(of: env.secrets.revision) { model.refresh() }
    }

    private var listWidth: CGFloat {
        env.prefs.panelSize.size.width * 0.44
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search clipboard history and snippets", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($searchFocused)
                .accessibilityLabel("Search")
            if let target = model.targetRef {
                HStack(spacing: 4) {
                    Image(nsImage: AppIconCache.icon(for: target.bundleID))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(target.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help("Pastes into \(target.name)")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Pastes into \(target.name)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
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
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                                PanelRow(entry: entry, shortcut: model.shortcutNumber(for: entry, at: index),
                                         isSelected: model.isSelected(entry),
                                         showsCheckmark: model.isMultiSelecting)
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
                            }
                        }
                        .padding(8)
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
            Button("Rename…") { model.beginLabel(entry) }
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
                PreviewPane(entry: entry)
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - Filter chips

struct FilterChips: View {
    @Binding var selection: PanelFilter
    let thisAppName: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(PanelFilter.allCases) { filter in
                let selected = filter == selection
                Button {
                    if reduceMotion { selection = filter } else {
                        withAnimation(.snappy(duration: 0.15)) { selection = filter }
                    }
                } label: {
                    Label(title(for: filter), systemImage: filter.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .background {
                            Capsule(style: .continuous)
                                .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.7)))
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title(for: filter)) filter")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    private func title(for filter: PanelFilter) -> String {
        if filter == .thisApp, let thisAppName { return thisAppName }
        return filter.title
    }
}

// MARK: - Row

struct PanelRow: View {
    let entry: PanelEntry
    let shortcut: (number: Int, isSlot: Bool)?
    let isSelected: Bool
    var showsCheckmark = false

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
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Text(subtitle)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 4)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText + (shortcut?.isSlot == true ? ", quick slot \(shortcut?.number ?? 0)" : ""))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Double-click or press Return to paste")
    }

    @ViewBuilder
    private var leading: some View {
        switch entry {
        case .clip(let item):
            ClipIconView(item: item, size: 26)
        case .snippet:
            Image(systemName: "text.badge.star")
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
        case .secret:
            Image(systemName: "key.fill")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .frame(width: 26, height: 26)
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
    var selectionCount: Int?

    var body: some View {
        HStack(spacing: 14) {
            switch mode {
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
                    hint("⌘⇧1–9", "Assign Slot")
                }
            case .actions:
                hint("↑↓", "Choose")
                hint("⏎", "Run")
            case .snippetForm:
                hint("⇥", "Next Field")
                hint("⏎", "Paste")
            case .saveSecret, .label:
                hint("⏎", "Save")
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
            } else if mode == .browse {
                hint("⇥", "Filter")
            }
            hint("esc", mode == .browse ? "Close" : "Back")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.8), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
        }
    }
}
