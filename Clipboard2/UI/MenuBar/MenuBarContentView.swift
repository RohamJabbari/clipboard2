import SwiftUI
import SwiftData

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

/// The menu bar popover: recent history, search, pinned items and quick actions.
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
    @State private var confirmClear = false
    @State private var savingSecret: ClipItem?
    @State private var labelling: ClipItem?
    @State private var labelText = ""
    @State private var secretName = ""
    @FocusState private var secretNameFocused: Bool
    @FocusState private var searchFocused: Bool

    private var filtered: [ClipItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return pinnedItems + recentItems }
        return env.store.allItems()
            .compactMap { item in FuzzyMatcher.score(query: query, in: item.searchableText).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(200)
            .map(\.0)
    }

    var body: some View {
        let results = filtered
        let pinned = results.filter(\.isPinned)
        let recent = results.filter { !$0.isPinned }.prefix(100)

        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()

            if let status = UpdateStatusRow.visible(for: env.updates) {
                status
                Divider()
            }

            if env.sync.indicator.isVisible {
                SyncStatusRow(sync: env.sync)
                Divider()
            }

            if results.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? "No Clipboard History" : "No Results", systemImage: search.isEmpty ? "list.clipboard" : "magnifyingglass")
                } description: {
                    Text(search.isEmpty ? "Copy something and it shows up here." : "Try a different search.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                        if !pinned.isEmpty {
                            Section { rows(pinned) } header: { sectionHeader("Pinned") }
                        }
                        if !recent.isEmpty {
                            Section { rows(Array(recent)) } header: { sectionHeader("Recent") }
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
        .frame(width: 380, height: 520)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .background(.bar)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func rows(_ items: [ClipItem]) -> some View {
        ForEach(items) { item in
            MenuBarRow(item: item) {
                dismiss()
                env.paste.paste(item)
            }
            .contextMenu {
                Button("Paste") { dismiss(); env.paste.paste(item) }
                Button("Paste as Plain Text") { dismiss(); env.paste.paste(item, transform: .plainText) }
                Button("Copy") { env.paste.copy(item) }
                Divider()
                Button(item.isPinned ? "Unpin" : "Pin") { env.store.togglePin(item) }
                Button(item.label == nil ? "Label…" : "Edit Label…") {
                    confirmClear = false
                    savingSecret = nil
                    labelText = item.label ?? ""
                    labelling = item
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

    private func labelBar(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Label — labelled items are pinned and never expire")
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

    private func saveLabel(_ item: ClipItem) {
        env.store.setLabel(labelText, for: item)
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
            Text("Clear history? Pinned items are kept.")
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

    private var footer: some View {
        HStack(spacing: 2) {
            footerButton("Open Quick Panel", symbol: "rectangle.and.text.magnifyingglass") {
                dismiss()
                env.showQuickPanel()
            }
            footerButton("Capture Text from Screen", symbol: "text.viewfinder") {
                dismiss()
                // Let the popover close before the screenshot crosshair appears.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { env.captureScreenText() }
            }
            Spacer()
            footerButton(env.prefs.isPaused ? "Resume Capture" : "Pause Capture",
                         symbol: env.prefs.isPaused ? "play.fill" : "pause.fill") {
                env.prefs.isPaused.toggle()
            }
            footerButton("Clear History", symbol: "trash") { confirmClear = true }
            footerButton("Settings", symbol: "gearshape") {
                dismiss()
                NSApp.activate()
                openSettings()
            }
            footerButton("Quit Clipboard2", symbol: "power") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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

private struct MenuBarRow: View {
    let item: ClipItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ClipIconView(item: item, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    if let label = item.label {
                        Text(label).fontWeight(.semibold).lineLimit(1)
                        Text(item.preview.isEmpty ? item.kind.displayName : item.preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(item.preview.isEmpty ? item.kind.displayName : item.preview)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if item.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                }
                Text(item.lastCopiedAt.shortRelative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(item.accessibilityDescription)
        .accessibilityHint("Pastes into the previous app")
    }
}
