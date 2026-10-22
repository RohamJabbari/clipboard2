import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(SettingsTab.appearance.rawValue)
            IgnoredAppsSettingsView()
                .tabItem { Label("Ignored Apps", systemImage: "hand.raised") }
                .tag(SettingsTab.ignoredApps.rawValue)
            SnippetsSettingsView()
                .tabItem { Label("Snippets", systemImage: "text.badge.star") }
                .tag(SettingsTab.snippets.rawValue)
            SecretsSettingsView()
                .tabItem { Label("Secrets", systemImage: "key") }
                .tag(SettingsTab.secrets.rawValue)
            TransformsSettingsView()
                .tabItem { Label("Transforms", systemImage: "wand.and.stars") }
                .tag(SettingsTab.transforms.rawValue)
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsTab.ai.rawValue)
            PermissionsSettingsView()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions.rawValue)
            SyncSettingsView()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath.icloud") }
                .tag(SettingsTab.sync.rawValue)
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about.rawValue)
        }
        .frame(width: 780)
        .frame(minHeight: 460)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var axTrusted = AXPermission.isTrusted
    @State private var confirmClear = false

    var body: some View {
        @Bindable var prefs = env.prefs
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        LoginItem.setEnabled(on)
                        launchAtLogin = LoginItem.isEnabled
                    }
                if LoginItem.requiresApproval {
                    Text("Approve Clipboard2 in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                KeyboardShortcuts.Recorder("Open quick panel", name: .toggleQuickPanel)
                KeyboardShortcuts.Recorder("Actions on selected text", name: .selectionActions)
                KeyboardShortcuts.Recorder("Capture text from screen", name: .captureText)
                KeyboardShortcuts.Recorder("Paste as text", name: .pasteAsText)
                KeyboardShortcuts.Recorder("Send selection to default group", name: .sendToGroup)
                Text("Actions on selected text: select text in any app to transform it or ask AI; Return replaces the selection (also under right-click → Services → Clipboard2 Actions…). Capture text: drag over anything on screen and its text is pasted. Paste as text: pastes plain text, or — if an image or screenshot is on the clipboard — the text in it. Text recognition runs on this Mac. Send selection: stores the selected text in your default sync group (Settings → Sync). It's active only while you're signed in to sync; then the ⌥⌘C default replaces Chrome's Inspect Elements, Safari's JavaScript Console and Finder's Copy as Pathname.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open Clipboard2's menu with \(prefs.contextMenuModifier.symbol)-right-click", isOn: $prefs.contextMenuEnabled)
                Picker("Modifier", selection: $prefs.contextMenuModifier) {
                    ForEach(ContextMenuModifier.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!prefs.contextMenuEnabled)
            } header: {
                Text("Right-click menu")
            } footer: {
                Text("Works in every app: Clipboard2's actions plus Cut, Copy, Paste, Select All and the usual items (Finder items in Finder). “Show ‹App› Menu” opens the app's own menu. Plain right-clicks are never changed. Needs Accessibility access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: prefs.contextMenuEnabled) { env.contextMenu.update() }

            Section("Capture") {
                LabeledContent("Permissions") {
                    Button("Review Permissions…") { env.showPermissions() }
                }
                Toggle("Pause clipboard capture", isOn: $prefs.isPaused)
                LabeledContent("Auto-paste") {
                    HStack(spacing: 8) {
                        Label(axTrusted ? "Enabled" : "Needs Accessibility access",
                              systemImage: axTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(axTrusted ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                            .labelStyle(.titleAndIcon)
                        if !axTrusted {
                            Button("Set Up…") { env.showPermissions() }
                        }
                    }
                }
            }

            QuickSlotsSection()

            Section("History") {
                Picker("Keep up to", selection: $prefs.maxItems) {
                    ForEach(Preferences.maxItemChoices, id: \.self) { Text($0 == 0 ? "Unlimited" : "\($0) items").tag($0) }
                }
                Picker("Delete items after", selection: $prefs.maxAgeMinutes) {
                    ForEach(Preferences.maxAgeChoices, id: \.self) { minutes in
                        Text(Preferences.describeAge(minutes: minutes)).tag(minutes)
                    }
                }
                Text("Measured from the last time an item was copied. Pinned and labelled items and secrets never expire.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Stored items", value: "\(env.store.count())")
                    .id(env.store.revision)
                Button("Clear History…", role: .destructive) { confirmClear = true }
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.maxItems) { env.runMaintenance() }
        .onChange(of: prefs.maxAgeMinutes) { env.runMaintenance() }
        .task {
            while !Task.isCancelled {
                axTrusted = AXPermission.isTrusted
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { env.store.clearHistory() }
            Button("Clear Including Pinned", role: .destructive) { env.store.clearHistory(includingPinned: true) }
        } message: {
            Text("This can't be undone.")
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
                        Text(env.slots.title(for: n) ?? "Empty — falls back to row \(n)")
                            .foregroundStyle(env.slots.target(for: n) == nil ? .tertiary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        KeyboardShortcuts.Recorder("", name: KeyboardShortcuts.Name.quickSlots[n - 1])
                            .accessibilityLabel("Global shortcut for quick slot \(n)")
                        if env.slots.target(for: n) != nil {
                            Button {
                                env.slots.clear(n)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
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
            Text("In the quick panel, select an item, snippet or secret and press ⌘⇧1–9 to bind it; ⌘1–9 then always pastes it. Record a global shortcut to paste a slot from any app without opening the panel.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Picker("Appearance", selection: $prefs.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
            Section("Quick Panel") {
                Picker("Size", selection: $prefs.panelSize) {
                    ForEach(PanelSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Transparency and motion follow your Accessibility display settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.appearance) { env.applyAppearance() }
    }
}

// MARK: - Ignored apps

struct IgnoredAppsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selection: AppRef.ID?

    var body: some View {
        @Bindable var prefs = env.prefs
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(prefs.ignoredApps) { app in
                        AppRow(app: app).tag(app.id)
                    }
                    .onDelete { prefs.ignoredApps.remove(atOffsets: $0) }
                }
                .frame(minHeight: 220)
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
                Text("Never record copies from these apps")
            } footer: {
                Text("Passwords and other items that apps mark as concealed or transient are always skipped, no matter which app they come from.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

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

// MARK: - About

struct UpdatesSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var autoCheck = true
    @State private var autoInstall = false

    var body: some View {
        Section {
            Toggle("Check for updates every hour", isOn: $autoCheck)
                .onChange(of: autoCheck) { env.updates.automaticallyChecks = autoCheck }
            Toggle("Install updates automatically", isOn: $autoInstall)
                .onChange(of: autoInstall) { env.updates.automaticallyInstalls = autoInstall }
                .disabled(!autoCheck)
            LabeledContent("Last checked") {
                Text(env.updates.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
            }
            HStack {
                if let version = env.updates.availableVersion {
                    Label("Version \(version) is available", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.tint)
                }
                Spacer()
                Button("Check for Updates…") { env.updates.checkForUpdates() }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Updates come from GitHub, are verified with your Developer ID signature, and install in place — Clipboard2 relaunches with your data intact.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            autoCheck = env.updates.automaticallyChecks
            autoInstall = env.updates.automaticallyInstalls
        }
    }
}

struct AboutSettingsView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    Text("Clipboard2").font(.title.weight(.semibold))
                    Text(version).foregroundStyle(.secondary)
                    Text("A native clipboard manager for macOS.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            UpdatesSection()
            Section("Data") {
                LabeledContent("Location") {
                    Text(AppPaths.supportDirectory.path(percentEncoded: false))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory])
                }
            }
        }
        .formStyle(.grouped)
    }
}
