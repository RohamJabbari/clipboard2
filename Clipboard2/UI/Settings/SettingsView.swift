import SwiftUI
import KeyboardShortcuts

/// Settings, grouped by what people come here to do:
/// General (is it working, startup, updates), History (what's kept and for how long, what's
/// never recorded), Appearance (theme and the quick panel), Shortcuts (every key and the
/// right-click menu), Snippets, Secrets, Actions (AI and paste transforms), Sync.
struct SettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var stored = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: Binding(
            get: { SettingsTab(stored: stored) ?? .general },
            set: { stored = $0.rawValue }
        )) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            HistorySettingsView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(SettingsTab.history)
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(SettingsTab.appearance)
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "command") }
                .tag(SettingsTab.shortcuts)
            SnippetsSettingsView()
                .tabItem { Label("Snippets", systemImage: "text.badge.star") }
                .tag(SettingsTab.snippets)
            SecretsSettingsView()
                .tabItem { Label("Secrets", systemImage: "key") }
                .tag(SettingsTab.secrets)
            ActionsSettingsView()
                .tabItem { Label("Actions", systemImage: "wand.and.stars") }
                .tag(SettingsTab.actions)
            SyncSettingsView()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath.icloud") }
                .tag(SettingsTab.sync)
        }
        .frame(width: 720)
        .frame(minHeight: 480, idealHeight: 680)
    }
}

/// A caption under a control: one short sentence about what it does.
private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var axTrusted = AXPermission.isTrusted

    var body: some View {
        Form {
            if !axTrusted {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Clipboard2 can't paste for you yet").font(.headline)
                            Text("Allow Accessibility and Return pastes straight into your app. Until then, items are copied and you press ⌘V yourself.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Set Up…") { env.showPermissions() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Toggle(isOn: $launchAtLogin) {
                    Text("Open at login")
                    Text("Keeps your history recording from the moment you log in.")
                }
                .onChange(of: launchAtLogin) { _, on in
                    LoginItem.setEnabled(on)
                    launchAtLogin = LoginItem.isEnabled
                }
                if LoginItem.requiresApproval {
                    Hint("Approve Clipboard2 in System Settings → General → Login Items.")
                }
                LabeledContent {
                    KeyboardShortcuts.Recorder(for: .toggleQuickPanel)
                } label: {
                    Text("Open the quick panel")
                    Text("All other shortcuts are in the Shortcuts tab.")
                }
            }

            UpdatesSection()

            PermissionsSection(permissions: [.accessibility, .screenRecording])

            Section {
                LabeledContent {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory])
                    }
                } label: {
                    Text("Stored only on this Mac")
                    Text(AppPaths.supportDirectory.path(percentEncoded: false))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                BackupRows()
            } header: {
                Text("Your data")
            } footer: {
                LegalLinks()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                axTrusted = AXPermission.isTrusted
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - History

struct HistorySettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmClear = false
    @State private var selection: AppRef.ID?

    var body: some View {
        @Bindable var prefs = env.prefs
        Form {
            Section {
                Toggle(isOn: Binding(get: { !prefs.isPaused }, set: { prefs.isPaused = !$0 })) {
                    Text("Record what I copy")
                    Text(prefs.isPaused
                         ? "Paused: nothing new is saved. Everything already in history still pastes."
                         : "Everything you copy is saved here, except from the apps below.")
                }
            }

            Section {
                Picker("Keep up to", selection: $prefs.maxItems) {
                    ForEach(Preferences.maxItemChoices, id: \.self) { Text($0 == 0 ? "Unlimited" : "\($0) items").tag($0) }
                }
                Picker(selection: $prefs.maxAgeMinutes) {
                    ForEach(Preferences.maxAgeChoices, id: \.self) { minutes in
                        Text(Preferences.describeAge(minutes: minutes)).tag(minutes)
                    }
                } label: {
                    Text("Forget items after")
                    Text("Counted from the last time you copied an item. Pinned and labelled items never expire.")
                }
                LabeledContent {
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                } label: {
                    Text("\(env.store.count()) items in history")
                        .id(env.store.revision)
                }
            } header: {
                Text("How much to keep")
            }

            Section {
                List(selection: $selection) {
                    ForEach(prefs.ignoredApps) { app in
                        AppRow(app: app).tag(app.id)
                    }
                    .onDelete { prefs.ignoredApps.remove(atOffsets: $0) }
                }
                .frame(minHeight: 150)
                .contextMenu(forSelectionType: AppRef.ID.self) { ids in
                    Button("Remove") { prefs.ignoredApps.removeAll { ids.contains($0.id) } }
                }
                HStack {
                    AppPickerMenu(title: "Add App", exclude: Set(prefs.ignoredApps.map(\.bundleID))) { app in
                        prefs.ignoredApps.append(app)
                    }
                    Button("Remove") {
                        prefs.ignoredApps.removeAll { $0.id == selection }
                        selection = nil
                    }
                    .disabled(selection == nil)
                    Spacer()
                    Button("Restore Defaults") {
                        let existing = Set(prefs.ignoredApps.map(\.bundleID))
                        prefs.ignoredApps += AppRef.defaultIgnored.filter { !existing.contains($0.bundleID) }
                    }
                }
            } header: {
                Text("Never record from these apps")
            } footer: {
                Hint("Passwords and anything an app marks as private are always skipped, whichever app they come from.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.maxItems) { env.runMaintenance() }
        .onChange(of: prefs.maxAgeMinutes) { env.runMaintenance() }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { env.store.clearHistory() }
            Button("Clear Including Pinned", role: .destructive) { env.store.clearHistory(includingPinned: true) }
        } message: {
            Text("Snippets and secrets are kept. This can't be undone.")
        }
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var prefs = env.prefs
        Form {
            Section {
                Picker("Theme", selection: $prefs.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0 == .system ? "Auto" : $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Opens from")
                    HStack(spacing: 10) {
                        ForEach(PanelOrigin.allCases) { origin in
                            OriginTile(origin: origin, selected: prefs.panelOrigin == origin) {
                                prefs.panelOrigin = origin
                            }
                        }
                    }
                    Hint(prefs.panelOrigin.summary)
                }
                .padding(.vertical, 4)
                Picker("Size", selection: $prefs.panelSize) {
                    ForEach(PanelSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent {
                    Button("Try It") { env.showQuickPanel() }
                } label: {
                    Text("Preview")
                    Text("With Reduce Motion it fades instead; with Reduce Transparency the glass turns solid.")
                }
            } header: {
                Text("Quick panel")
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.appearance) { env.applyAppearance() }
    }
}

/// A tiny screen with the panel against the chosen edge.
private struct OriginTile: View {
    let origin: PanelOrigin
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: alignment) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                                      lineWidth: selected ? 2 : 1)
                    RoundedRectangle(cornerRadius: origin == .center ? 3 : 4, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary.opacity(0.6)))
                        .frame(width: panelSize.width, height: panelSize.height)
                        .padding(5)
                }
                .frame(width: 70, height: 46)
                Text(origin.title)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open from \(origin.title)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var alignment: Alignment {
        switch origin {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        case .center: .center
        }
    }

    private var panelSize: CGSize {
        switch origin {
        case .top, .bottom: CGSize(width: 34, height: 18)
        case .left, .right: CGSize(width: 26, height: 24)
        case .center: CGSize(width: 34, height: 22)
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var prefs = env.prefs
        Form {
            Section("Everywhere") {
                shortcut(.toggleQuickPanel, "Open the quick panel",
                         "Search history, snippets and secrets; Return pastes into the app you were in.")
                shortcut(.selectionActions, "Actions on selected text",
                         "Transform the selection or ask AI about it; Return replaces it. Also in right-click → Services.")
                shortcut(.pasteAsText, "Paste as plain text",
                         "Drops formatting. With an image or screenshot on the clipboard, pastes the text in it.")
                shortcut(.captureText, "Capture text from screen",
                         "Drag over anything; the text is recognised on this Mac and pasted.")
            }

            Section {
                shortcut(.sendToGroup, "Send selection to default group",
                         "Copies what's selected into your default sync group.")
                shortcut(.pasteFromGroup, "Paste from default group",
                         "Pastes the newest item a group member sent.")
            } header: {
                Text("Sync groups")
            } footer: {
                Hint(env.sync.isSignedIn
                     ? "While you're signed in, these replace ⌥⌘C and ⌥⌘V in other apps (e.g. Chrome's Inspect Elements, Finder's Copy as Pathname). Change them here if you use those."
                     : "Only active while you're signed in to Sync.")
            }

            Section {
                Toggle(isOn: $prefs.contextMenuEnabled) {
                    Text("\(prefs.contextMenuModifier.symbol)-right-click opens Clipboard2's menu")
                    Text("Recent items, snippets, secrets and text actions, plus Cut, Copy and Paste — in any app. Plain right-clicks are untouched.")
                }
                Picker("Modifier key", selection: $prefs.contextMenuModifier) {
                    ForEach(ContextMenuModifier.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!prefs.contextMenuEnabled)
            } header: {
                Text("Right-click menu")
            }
            .onChange(of: prefs.contextMenuEnabled) { env.contextMenu.update() }

            QuickSlotsSection()
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ name: KeyboardShortcuts.Name, _ title: String, _ detail: String) -> some View {
        LabeledContent {
            KeyboardShortcuts.Recorder(for: name)
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

// MARK: - Quick slots

struct QuickSlotsSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Section {
            ForEach(QuickSlots.range, id: \.self) { n in
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(env.slots.title(for: n) ?? "Empty — pastes row \(n)")
                            .foregroundStyle(env.slots.target(for: n) == nil ? .tertiary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        KeyboardShortcuts.Recorder(for: KeyboardShortcuts.Name.quickSlots[n - 1])
                            .accessibilityLabel("Global shortcut for quick slot \(n)")
                        if env.slots.target(for: n) != nil {
                            Button {
                                env.slots.clear(n)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear slot")
                            .accessibilityLabel("Clear quick slot \(n)")
                        }
                    }
                } label: {
                    Text("⌘\(n)").monospacedDigit()
                }
            }
        } header: {
            Text("Quick slots")
        } footer: {
            Hint("In the quick panel, ⌘⇧1–9 pins the selected item to a slot and ⌘1–9 pastes it. Give a slot a shortcut to paste it from any app.")
        }
    }
}

// MARK: - Shared rows

struct AppRow: View {
    let app: AppRef

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIconCache.icon(for: app.bundleID))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(app.name)
            Spacer()
            Text(app.bundleID)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Add App" menu: running apps plus a file picker for anything in /Applications.
struct AppPickerMenu: View {
    let title: String
    var exclude: Set<String> = []
    let onPick: (AppRef) -> Void

    var body: some View {
        Menu(title) {
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                .compactMap(FrontmostAppTracker.ref(for:))
                .filter { !exclude.contains($0.bundleID) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Section("Running Apps") {
                ForEach(running) { app in
                    Button {
                        onPick(app)
                    } label: {
                        Label {
                            Text(app.name)
                        } icon: {
                            Image(nsImage: AppIconCache.icon(for: app.bundleID))
                        }
                    }
                }
            }
            Divider()
            Button("Choose Application…") { chooseApp() }
        }
        .fixedSize()
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        guard !exclude.contains(id) else { return }
        onPick(AppRef(bundleID: id, name: name))
    }
}
