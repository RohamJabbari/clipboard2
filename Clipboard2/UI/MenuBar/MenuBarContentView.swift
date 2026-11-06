import SwiftUI
import SwiftData
import KeyboardShortcuts

struct MenuBarLabel: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let indicator = env.sync.indicator
        let description = [env.prefs.isPaused ? "Clipboard2, capture paused" : "Clipboard2",
                           indicator.badge.map { $0 == .ring ? "sync offline" : "sync problem" }]
            .compactMap { $0 }.joined(separator: ", ")
        Image(nsImage: MenuBarIcon.image(symbol: env.prefs.isPaused ? "clipboard" : "list.clipboard",
                                         badge: indicator.badge, description: description))
            .accessibilityLabel(description)
            .onAppear { SettingsOpener.register(openSettings) }
    }
}

/// The menu bar popover: recent history, search, labelled items and quick actions.
struct MenuBarContentView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Query(Self.recentDescriptor) private var recentItems: [ClipItem]
    @Query(filter: #Predicate<ClipItem> { $0.isPinned }, sort: \ClipItem.lastCopiedAt, order: .reverse)
    private var pinnedItems: [ClipItem]

    /// The popover only renders recent history; search falls back to the full store.
    private static var recentDescriptor: FetchDescriptor<ClipItem> {
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.isPinned == false },
            sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        return descriptor
    }

    @State private var search = ""
    @State private var filter: MenuBarFilter = .all
    @State private var confirmClear = false
    @State private var savingSecret: ClipItem?
    @State private var labelling: ClipItem?
    @State private var labelText = ""
    @State private var secretName = ""
    @FocusState private var secretNameFocused: Bool
    @FocusState private var searchFocused: Bool

    private var filtered: [ClipItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let items: [ClipItem]
        if query.isEmpty {
            items = pinnedItems + recentItems
        } else {
            items = env.store.allItems()
                .compactMap { item in FuzzyMatcher.score(query: query, in: item.searchableText).map { (item, $0) } }
                .sorted { $0.1 > $1.1 }
                .prefix(200)
                .map(\.0)
        }
        // Contacts' items live in the panel's Inbox only.
        return items.filter { filter.includes($0) && env.sync.isListed($0, inInbox: false) }
    }

    /// Labelled first, then Today / Yesterday / This Week / Earlier; one plain list while searching.
    private func sections(_ results: [ClipItem]) -> [(title: String?, items: [ClipItem])] {
        guard search.trimmingCharacters(in: .whitespaces).isEmpty else { return [(nil, results)] }
        var sections: [(title: String?, items: [ClipItem])] = []
        let pinned = results.filter(\.isPinned)
        if !pinned.isEmpty { sections.append(("Labelled", pinned)) }
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: .now)) ?? .now
        for item in results.filter({ !$0.isPinned }).prefix(100) {
            let date = item.lastCopiedAt
            let title = calendar.isDateInToday(date) ? "Today"
                : calendar.isDateInYesterday(date) ? "Yesterday"
                : date >= weekAgo ? "This Week" : "Earlier"
            if sections.last?.title == title {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append((title, [item]))
            }
        }
        return sections
    }

    var body: some View {
        let results = filtered

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                searchField
                filterRow
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if let status = UpdateStatusRow.visible(for: env.updates) {
                status
                Divider()
            }

            if env.sync.indicator.isVisible {
                SyncStatusRow(sync: env.sync)
                Divider()
            }

            if env.sync.isSignedIn && !env.sync.contactRequests.incoming.isEmpty {
                ContactRequestsRow(requests: env.sync.contactRequests.incoming) {
                    dismiss()
                    SettingsOpener.open(tab: .sync)
                }
                Divider()
            }

            if results.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty && filter == .all ? "No Clipboard History" : "No Results",
                          systemImage: search.isEmpty && filter == .all ? "list.clipboard" : "magnifyingglass")
                } description: {
                    Text(search.isEmpty && filter == .all ? "Copy something and it shows up here." : "Try a different search or filter.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(sections(results).enumerated()), id: \.offset) { index, section in
                            if let title = section.title {
                                SectionHeading(title: title, isFirst: index == 0)
                            }
                            rows(section.items)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
            }

            Divider()
            if let item = labelling {
                labelBar(item)
            } else if let item = savingSecret {
                saveSecretBar(item)
            } else if confirmClear {
                clearConfirmation
            } else {
                footer
            }
        }
        .frame(width: 380, height: 560)
        .onAppear {
            searchFocused = true
            env.sync.reportActivity()
        }
        .onDisappear {
            confirmClear = false
            savingSecret = nil
            labelling = nil
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search History", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var filterRow: some View {
        HStack(spacing: 2) {
            ForEach(MenuBarFilter.allCases) { choice in
                FilterChip(title: choice.title, selected: filter == choice) { filter = choice }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func rows(_ items: [ClipItem]) -> some View {
        ForEach(items) { item in
            MenuBarRow(item: item, sharedBy: sharedBy(item), onLabel: { beginLabel(item) }) {
                dismiss()
                env.paste.paste(item)
            }
            .contextMenu {
                Button("Paste") { dismiss(); env.paste.paste(item) }
                Button("Paste as Plain Text") { dismiss(); env.paste.paste(item, transform: .plainText) }
                Button("Copy") { env.paste.copy(item) }
                Divider()
                Button(item.label == nil ? "Label…" : "Edit Label…") { beginLabel(item) }
                if item.isPinned && item.label == nil {
                    Button("Remove from Labelled") { env.store.removeFromLabelled(item) }
                }
                if item.kind.isTextual {
                    Button("Save as Secret…") {
                        confirmClear = false
                        secretName = item.sourceAppName.map { "Password from \($0)" } ?? "New Secret"
                        savingSecret = item
                    }
                }
                Menu("Assign to Quick Slot") {
                    ForEach(QuickSlots.range, id: \.self) { n in
                        Button("⌘\(n)\(env.slots.title(for: n).map { " — " + $0 } ?? "")") {
                            env.slots.assign(.clip(item), to: n)
                        }
                    }
                }
                let devices = DeviceTarget.others(in: env.sync)
                if !devices.isEmpty {
                    Divider()
                    ForEach(devices) { device in
                        Button("Send to \(device.name)") {
                            env.sync.sendToDevice(item, deviceId: device.id)
                        }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) { env.store.delete(item) }
            }
        }
    }

    /// "Sara in Team" for an item that lives in a sync group.
    private func sharedBy(_ item: ClipItem) -> String? {
        guard let spaceID = item.spaceID, let group = env.sync.groups.first(where: { $0.id == spaceID }) else { return nil }
        let person = env.sync.copiedBy(item)
        return person == nil || person == group.name ? group.name : "\(person ?? "") in \(group.name)"
    }

    private func labelBar(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Label — labelled items never expire")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Label", text: $labelText, prompt: Text("e.g. Staging DB host"))
                    .textFieldStyle(.roundedBorder)
                    .focused($secretNameFocused)
                    .onSubmit { saveLabel(item) }
                Button("Cancel") { labelling = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveLabel(item) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .onAppear { secretNameFocused = true }
    }

    private func beginLabel(_ item: ClipItem) {
        confirmClear = false
        savingSecret = nil
        labelText = item.label ?? ""
        labelling = item
    }

    private func saveLabel(_ item: ClipItem) {
        env.store.setLabel(labelText, for: item, keepPinned: env.slots.slot(for: .clip(item.id)) != nil)
        labelling = nil
    }

    private func saveSecretBar(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Save as secret — moves it to the Keychain and out of history")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Name", text: $secretName, prompt: Text("e.g. Prod DB password"))
                    .textFieldStyle(.roundedBorder)
                    .focused($secretNameFocused)
                    .onSubmit { saveSecret(item) }
                Button("Cancel") { savingSecret = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveSecret(item) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(secretName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .onAppear { secretNameFocused = true }
    }

    private func saveSecret(_ item: ClipItem) {
        let name = secretName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, env.secrets.add(name: name, value: item.text) != nil else { return }
        env.slots.remove(target: .clip(item.id))
        env.store.delete(item)
        savingSecret = nil
    }

    /// Inline instead of a dialog: a modal sheet steals focus from the menu bar window,
    /// which closes the popover before the click lands.
    private var clearConfirmation: some View {
        HStack(spacing: 8) {
            Text("Clear history? Labelled items are kept.")
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Button("Cancel") { confirmClear = false }
                .keyboardShortcut(.cancelAction)
            Button("Clear", role: .destructive) {
                env.store.clearHistory()
                confirmClear = false
            }
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// The panel is the main way in, so it gets a named button with its shortcut; rare and
    /// destructive things (Clear History, Quit) sit behind "…".
    private var footer: some View {
        HStack(spacing: 2) {
            Button {
                dismiss()
                env.showQuickPanel()
            } label: {
                HStack(spacing: 7) {
                    Text("Open Clipboard2").fontWeight(.semibold)
                    if let keys = KeyboardShortcuts.getShortcut(for: .toggleQuickPanel) {
                        Text("\(keys)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            Spacer()
            footerButton("Copy Text from Screen", symbol: "text.viewfinder") {
                dismiss()
                // Let the popover close before the screenshot crosshair appears.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { env.captureScreenText() }
            }
            footerButton(env.prefs.isPaused ? "Resume Recording" : "Pause Recording",
                         symbol: env.prefs.isPaused ? "play.fill" : "pause.fill") {
                env.prefs.isPaused.toggle()
            }
            footerButton("Settings", symbol: "gearshape") {
                dismiss()
                NSApp.activate()
                openSettings()
            }
            Menu {
                Button("Clear History…") { confirmClear = true }
                Divider()
                Button("Quit Clipboard2") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Clear History, Quit")
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func footerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// What the popover's filter row can show.
private enum MenuBarFilter: String, CaseIterable, Identifiable {
    case all, labelled, text, images, links
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    func includes(_ item: ClipItem) -> Bool {
        switch self {
        case .all: true
        case .labelled: item.isPinned
        case .text: item.kind.isTextual
        case .images: item.kind == .image
        case .links:
            if case .link = ClipContentCache.content(of: item) { true } else { false }
        }
    }
}

/// One line per item: what it is (badge), the item itself, and where and when it came from.
private struct MenuBarRow: View {
    let item: ClipItem
    var sharedBy: String?
    /// Opens the label field: labels are how items are kept.
    let onLabel: () -> Void
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ContentBadge(kind: .clip(item), size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    title
                        .lineLimit(1)
                        .truncationMode(item.kind == .file ? .middle : .tail)
                    subtitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Room for the label button that appears on hover.
                Color.clear.frame(width: hovering || item.isPinned ? 22 : 0, height: 1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(.clear))
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if hovering || item.isPinned {
                Button(action: onLabel) {
                    Image(systemName: item.isPinned ? "tag.fill" : "tag")
                        .font(.caption)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(item.isPinned ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.trailing, 8)
                .help(item.label == nil ? "Label…" : "Edit Label…")
                .accessibilityLabel(item.label == nil ? "Label" : "Edit Label")
            }
        }
        .onHover { hovering = $0 }
        .accessibilityLabel(hiddenKind.map { "Hidden \($0.inlineName)" } ?? item.accessibilityDescription)
        .accessibilityHint("Pastes into the previous app")
    }

    /// A confidently recognised credential: masked here like in the quick panel.
    private var hiddenKind: SensitiveText.Kind? {
        guard case .sensitive(let kind) = ClipContentCache.content(of: item), kind.isConfident else { return nil }
        return kind
    }

    @ViewBuilder
    private var title: some View {
        if let label = item.label {
            Text(label).fontWeight(.semibold)
        } else if let hiddenKind {
            Text(SensitiveText.masked(item.text, kind: hiddenKind)).font(.system(.body, design: .monospaced))
        } else {
            switch ClipContentCache.content(of: item) {
            case .link(let url):
                // swift.org/documentation reads faster than https://www.swift.org/documentation/.
                let host = (url.host() ?? "").replacingOccurrences(of: "www.", with: "", options: .anchored)
                let path = url.path() == "/" ? "" : url.path()
                (Text(host).fontWeight(.semibold) + Text(path).foregroundStyle(.secondary))
            case .color, .command:
                Text(item.preview).font(.system(.body, design: .monospaced))
            default:
                Text(item.preview.isEmpty ? item.kind.displayName : item.preview)
            }
        }
    }

    private var subtitle: Text {
        let when = item.lastCopiedAt.shortRelative
        if item.label != nil {
            let value = hiddenKind.map { SensitiveText.masked(item.text, kind: $0) } ?? item.preview
            return Text(value)
        }
        if let sharedBy {
            return Text(sharedBy).fontWeight(.semibold).foregroundStyle(.purple) + Text(" · \(when)")
        }
        let place = [item.sourceAppName, when].compactMap { $0 }.joined(separator: " · ")
        if let hiddenKind {
            return Text("Hidden \(hiddenKind.inlineName)").fontWeight(.semibold).foregroundStyle(.orange) + Text(" · \(place)")
        }
        return Text(place)
    }
}
