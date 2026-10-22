import AppKit
import SwiftData
import Observation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleQuickPanel = Self("toggleQuickPanel", default: .init(.v, modifiers: [.command, .shift]))
    static let selectionActions = Self("selectionActions", default: .init(.k, modifiers: [.command, .option]))
    static let captureText = Self("captureText", default: .init(.two, modifiers: [.command, .shift, .option]))
    static let pasteAsText = Self("pasteAsText", default: .init(.v, modifiers: [.command, .shift, .option]))
    static let sendToGroup = Self("sendToGroup", default: .init(.c, modifiers: [.command, .option]))
    static let pasteFromGroup = Self("pasteFromGroup", default: .init(.v, modifiers: [.command, .option]))
}

/// Owns every long-lived service. Created once at launch and injected into SwiftUI via `.environment`.
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    let prefs: Preferences
    let container: ModelContainer
    let blobs: BlobStore
    let store: ClipStore
    let appTracker: FrontmostAppTracker
    let monitor: ClipboardMonitor
    let paste: PasteService
    let snippets: SnippetStore
    let secrets: SecretStore
    let slots: QuickSlots
    let sync: SyncAccount
    let claudeAccount = SubscriptionAccount(cli: .claude)
    let chatGPTAccount = SubscriptionAccount(cli: .codex)
    let updates = UpdateController()
    let modelCatalog = AIModelCatalog()

    @ObservationIgnored private(set) lazy var panel = QuickPanelController(env: self)
    @ObservationIgnored private let permissionsWindow = PermissionsWindowController()

    @ObservationIgnored private var maintenanceTimer: Timer?
    @ObservationIgnored private lazy var serviceProvider = ServiceProvider(env: self)
    @ObservationIgnored private(set) lazy var contextMenu = ContextMenuController(env: self)
    @ObservationIgnored private var maintenanceRuns = 0
    #if DEBUG
    @ObservationIgnored private var stressMonitor: ClipboardMonitor?
    #endif

    private init() {
        prefs = Preferences(defaults: .standard)
        blobs = BlobStore(directory: AppPaths.blobsDirectory)
        container = Self.makeContainer(url: AppPaths.storeURL)
        store = ClipStore(context: container.mainContext, blobs: blobs)
        appTracker = FrontmostAppTracker()
        monitor = ClipboardMonitor(store: store, prefs: prefs, tracker: appTracker, blobs: blobs)
        paste = PasteService(store: store, prefs: prefs, tracker: appTracker)
        snippets = SnippetStore(context: container.mainContext)
        secrets = SecretStore(prefs: prefs)
        slots = QuickSlots(defaults: .standard, store: store, snippets: snippets, secrets: secrets)
        sync = SyncAccount(prefs: prefs, context: container.mainContext, store: store, snippets: snippets, secrets: secrets)
    }

    /// Every persisted model; tests build in-memory containers from the same list.
    static let schema = Schema([ClipItem.self, Snippet.self, SyncMeta.self, SyncSpace.self])

    private static func makeContainer(url: URL) -> ModelContainer {
        let schema = Self.schema
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        } catch {
            Log.store.error("Failed to open store at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public). Falling back to in-memory.")
            do {
                return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            } catch {
                fatalError("SwiftData is unavailable: \(error)")
            }
        }
    }

    // MARK: Lifecycle

    func start() {
        updates.start()
        monitor.shouldDiscard = { [weak self] capture in
            guard let self, capture.kind.isTextual else { return false }
            return self.secrets.valueHashes.contains(capture.hash)
        }
        secrets.onChange = { [weak self] in
            guard let self else { return }
            self.removeHistoryCopiesOfSecrets()
            self.sync.localChange()
        }
        removeHistoryCopiesOfSecrets()
        store.onCommit = { [weak self] in self?.sync.localChange() }
        snippets.onCommit = { [weak self] in self?.sync.localChange() }
        // Retention only stops tracking items; it never deletes them on other devices.
        store.onExpire = { [weak self] ids in self?.sync.engine?.forget(ids) }
        sync.onSessionChange = { [weak self] active in self?.setSendToGroupShortcut(active: active) }
        sync.start()
        migrateDedupeIfNeeded()
        applyAppearance()
        monitor.start()
        runMaintenance()

        // Every minute so short expiry times (15 min, 1 h) are honoured promptly; the work is a
        // single indexed fetch when nothing has expired.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runMaintenance() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer

        KeyboardShortcuts.onKeyDown(for: .toggleQuickPanel) { [weak self] in
            self?.panel.toggle()
        }
        // Key-up, so the user's ⌥⌘ are released before we send ⌘C to the other app.
        KeyboardShortcuts.onKeyUp(for: .selectionActions) { [weak self] in
            self?.showSelectionActions()
        }
        // v1.0 shipped ⇧⌘2 as the default, which collides with a common screenshot remap.
        if KeyboardShortcuts.getShortcut(for: .captureText) == .init(.two, modifiers: [.command, .shift]) {
            KeyboardShortcuts.setShortcut(.init(.two, modifiers: [.command, .shift, .option]), for: .captureText)
        }
        KeyboardShortcuts.onKeyUp(for: .captureText) { [weak self] in
            self?.captureScreenText()
        }
        KeyboardShortcuts.onKeyUp(for: .pasteAsText) { [weak self] in
            self?.pasteClipboardAsText()
        }

        contextMenu.update()
        Task {
            await claudeAccount.refresh()
            await chatGPTAccount.refresh()
        }
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
        for (index, name) in KeyboardShortcuts.Name.quickSlots.enumerated() {
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                self?.pasteSlot(index + 1)
            }
        }
        paste.onAccessibilityMissing = { [weak self] in
            self?.showPermissions()
        }

        if !prefs.hasLaunchedBefore {
            prefs.hasLaunchedBefore = true
            LoginItem.setEnabled(true)
        }
        // First launch after install: walk through the permissions.
        if !prefs.hasShownPermissions {
            prefs.hasShownPermissions = true
            showPermissions()
        }
    }

    /// The signed-in account behind a subscription provider, if it is one.
    func account(for provider: AIProviderKind) -> SubscriptionAccount? {
        switch provider {
        case .claudeCode: claudeAccount
        case .chatGPT: chatGPTAccount
        default: nil
        }
    }

    /// Whether the chosen AI provider can actually be used right now.
    var isAIReady: Bool {
        let provider = prefs.aiProvider
        if let account = account(for: provider) { return account.isSignedIn }
        return !provider.requiresAPIKey || provider.apiKey != nil
    }

    func showPermissions() {
        permissionsWindow.show()
    }

    /// One-time: re-hash existing history with the current rules and merge duplicates.
    private func migrateDedupeIfNeeded() {
        let currentVersion = 2
        guard prefs.dedupeVersion < currentVersion else { return }
        let images = store.allItems().compactMap { item -> (id: UUID, url: URL)? in
            guard item.kind == .image, let file = item.imageFile else { return nil }
            return (item.id, blobs.url(for: file))
        }
        Task {
            let hashes = await DedupeMigration.pixelHashes(for: images)
            store.applyHashes(images: hashes)
            store.mergeDuplicates()
            prefs.dedupeVersion = currentVersion
        }
    }

    /// "Remove history copies of saved secrets", within each space.
    private func removeHistoryCopiesOfSecrets() {
        for space in secrets.spaceIDs {
            store.removeUnpinned(matching: secrets.valueHashes(inSpace: space), inSpace: space)
        }
    }

    func runMaintenance() {
        store.enforceRetention(maxItems: prefs.maxItems, maxAge: prefs.maxAge)
        sync.periodicSync()
        contextMenu.update()   // starts the right-click tap once Accessibility is granted
        maintenanceRuns &+= 1
        if maintenanceRuns % 30 == 1 { store.removeOrphanedBlobs() }   // directory scan: every ~30 min
    }

    func applyAppearance() {
        NSApp.appearance = prefs.appearance.nsAppearance
    }

    // MARK: Shared paste flows (quick panel, popover and global slot shortcuts)

    func pasteSnippet(_ snippet: Snippet, values: [String: String], into target: NSRunningApplication?) {
        let expansion = SnippetExpander.expand(
            snippet.body,
            values: values,
            clipboard: NSPasteboard.general.string(forType: .string)
        )
        paste.paste(text: expansion.text, into: target, cursorOffsetFromEnd: expansion.cursorOffsetFromEnd)
    }

    /// Touch ID (unless recently unlocked), then a concealed paste that clears itself.
    func pasteSecret(_ ref: SecretRef, into target: NSRunningApplication?) {
        Task {
            guard let value = await secrets.reveal(ref, reason: "paste “\(ref.name)”") else { return }
            paste.pasteSecret(value, into: target ?? appTracker.targetApp, clearAfter: prefs.secretClearSeconds)
        }
    }

    func copySecret(_ ref: SecretRef) {
        Task {
            guard let value = await secrets.reveal(ref, reason: "copy “\(ref.name)”") else { return }
            paste.writeSecret(value, clearAfter: prefs.secretClearSeconds)
        }
    }

    // MARK: Actions on selected text (⌥⌘K and Services menu)

    /// Copies the selection in the frontmost app, restores the clipboard, and opens the action
    /// menu for that text. The temporary copy is never recorded in history.
    func showSelectionActions() {
        guard AXPermission.isTrusted else {
            showPermissions()
            return
        }
        let target = appTracker.targetApp
        Task {
            monitor.isSuspended = true
            let saved = paste.snapshot()
            let text = await paste.copySelectedText()
            paste.restore(saved)
            monitor.acknowledgeCurrentChange()
            monitor.isSuspended = false
            guard let text else {
                NSSound.beep()
                return
            }
            panel.showForSelection(text, target: target)
        }
    }

    // MARK: Send selection to the default group (⌥⌘C)

    @ObservationIgnored private var sendToGroupRegistered = false

    /// ⌥⌘C belongs to Chrome, Safari and Finder until the user signs in to sync, so the shortcut
    /// is registered only while a sync session exists.
    private func setSendToGroupShortcut(active: Bool) {
        guard active != sendToGroupRegistered else { return }
        sendToGroupRegistered = active
        if active {
            KeyboardShortcuts.onKeyUp(for: .sendToGroup) { [weak self] in
                self?.sendSelectionToGroup()
            }
            KeyboardShortcuts.onKeyUp(for: .pasteFromGroup) { [weak self] in
                self?.pasteFromDefaultGroup()
            }
            warnAboutSendToGroupShortcutOnce()
        } else {
            KeyboardShortcuts.removeHandler(for: .sendToGroup)
            KeyboardShortcuts.removeHandler(for: .pasteFromGroup)
        }
    }

    /// Pastes the newest item of the default group. Fetches first (briefly), so something a group
    /// member just sent is pasted; if the server is slow or unreachable, the newest known one is.
    func pasteFromDefaultGroup() {
        guard sync.isSignedIn, let group = sync.defaultGroup else {
            SettingsOpener.open(tab: .sync)
            return
        }
        let target = appTracker.targetApp
        Task {
            await sync.syncAndWait(timeout: .milliseconds(1500))
            guard let item = store.items(inSpace: group.id).first else {
                HUD.show("Nothing in \(group.name) yet", symbol: "person.2")
                return
            }
            paste.paste(item, into: target)
        }
    }

    /// Copies the selection in the frontmost app and stores it as history in the default sync
    /// group, then confirms with a HUD. Without a default group it opens Settings → Sync.
    func sendSelectionToGroup() {
        guard sync.isSignedIn, let group = sync.defaultGroup else {
            SettingsOpener.open(tab: .sync)
            return
        }
        guard AXPermission.isTrusted else {
            showPermissions()
            return
        }
        let source = appTracker.targetApp.flatMap(FrontmostAppTracker.ref(for:))
        Task {
            monitor.isSuspended = true
            let saved = paste.snapshot()
            let text = await paste.copySelectedText()
            paste.restore(saved)
            monitor.acknowledgeCurrentChange()
            monitor.isSuspended = false
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSSound.beep()
                return
            }
            store.ingest(.text(text, source: source), spaceID: group.id)
            HUD.show("Sent to \(group.name)", symbol: "person.2.fill")
            sync.syncNow()
        }
    }

    /// The ⌥⌘C default replaces a few well-known shortcuts; say so once.
    private func warnAboutSendToGroupShortcutOnce() {
        guard !prefs.hasShownSendToGroupWarning else { return }
        prefs.hasShownSendToGroupWarning = true
        guard KeyboardShortcuts.getShortcut(for: .sendToGroup) == .init(.c, modifiers: [.command, .option]) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let alert = NSAlert()
            alert.messageText = "⌥⌘C Now Sends Selected Text to a Sync Group"
            alert.informativeText = "Clipboard2 uses ⌥⌘C to send the selected text to your default sync group. While you're signed in to sync, this replaces ⌥⌘C in other apps: Chrome's Inspect Elements, Safari's JavaScript Console and Finder's Copy as Pathname.\n\nTo change or clear the shortcut, open Settings → General → Send selection to default group."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Change Shortcut…")
            NSApp.activate()
            if alert.runModal() == .alertSecondButtonReturn {
                SettingsOpener.open(tab: .general)
            }
        }
    }

    // MARK: Text from screen

    /// Screenshot a region, recognise its text on-device, paste it at the cursor and keep it
    /// in history.
    func captureScreenText() {
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt (first time) and adds Clipboard2 to Screen Recording settings.
            if !CGRequestScreenCaptureAccess() {
                showScreenRecordingHelp()
            }
            return
        }
        let target = appTracker.targetApp
        Task {
            // Capture to the clipboard (a file capture shows the floating thumbnail and the
            // image ends up being used instead of its text), then put the old clipboard back.
            monitor.isSuspended = true
            let saved = paste.snapshot()
            let image = await ScreenTextCapture.captureRegionToClipboard()
            paste.restore(saved)
            monitor.acknowledgeCurrentChange()
            monitor.isSuspended = false
            guard let image else { return }        // cancelled with Esc
            let text = (try? await ScreenTextCapture.recognizeText(in: image)) ?? ""
            guard !text.isEmpty else {
                NSSound.beep()
                return
            }
            let source = AppRef(bundleID: Bundle.main.bundleIdentifier ?? "at.softmaze.Clippy", name: "Text from Screen")
            store.ingest(.text(text, source: source))
            pasteKeepingClipboard(text, into: target)
        }
    }

    private func showScreenRecordingHelp() {
        let alert = NSAlert()
        alert.messageText = "Allow Clipboard2 to Read Text from the Screen"
        alert.informativeText = "Turn on Clipboard2 in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. Screenshots are processed on this Mac and deleted immediately."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Paste as text (⌥⇧⌘V)

    /// Text on the clipboard → pasted as plain text. An image (screenshot, copied picture or image
    /// file) → its text is recognised on-device and pasted. The clipboard is restored afterwards.
    func pasteClipboardAsText() {
        let pasteboard = NSPasteboard.general
        let target = appTracker.targetApp
        guard let image = ClipboardImage.current(in: pasteboard) else {
            if let string = pasteboard.string(forType: .string), !string.isEmpty {
                pasteKeepingClipboard(string, into: target)
            } else {
                NSSound.beep()
            }
            return
        }
        Task {
            let text = (try? await ScreenTextCapture.recognizeText(in: image)) ?? ""
            guard !text.isEmpty else {
                NSSound.beep()
                return
            }
            let source = AppRef(bundleID: Bundle.main.bundleIdentifier ?? "at.softmaze.Clippy", name: "Text from Image")
            store.ingest(.text(text, source: source))
            pasteKeepingClipboard(text, into: target)
        }
    }

    private func pasteKeepingClipboard(_ text: String, into target: NSRunningApplication?) {
        paste.pastePreservingClipboard(text: text, into: target) { [weak self] in
            self?.monitor.acknowledgeCurrentChange()
        }
    }

    /// Services menu entry point: the system hands us the selected text directly.
    func showSelectionActions(text: String) {
        panel.showForSelection(text, target: appTracker.targetApp)
    }

    /// Global quick-slot shortcut: paste straight into the frontmost app.
    func pasteSlot(_ number: Int) {
        guard let entry = slots.entry(for: number) else {
            NSSound.beep()
            return
        }
        let target = appTracker.targetApp
        switch entry {
        case .clip(let item):
            paste.paste(item, into: target)
        case .snippet(let snippet):
            if SnippetExpander.customFields(in: snippet.body).isEmpty {
                pasteSnippet(snippet, values: [:], into: target)
            } else {
                panel.show()
                panel.model.activate(entry)
            }
        case .secret(let ref):
            pasteSecret(ref, into: target)
        }
    }

    func showQuickPanel() {
        panel.show()
    }

    func handle(url: URL) {
        guard url.scheme == "clipboard2" || url.scheme == "clippy" else { return }
        switch url.host() {
        case "settings": SettingsOpener.open()
        case "panel": panel.show()
        case "accessibility", "permissions": showPermissions()
        #if DEBUG
        case "stress":
            // Debug aid: drives the capture pipeline through a private pasteboard, so memory can
            // be measured without touching the user's real clipboard.
            let count = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "count" }?.value.flatMap(Int.init) ?? 300
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("at.softmaze.clippy.stress"))
            let monitor = ClipboardMonitor(store: store, prefs: prefs, tracker: appTracker, blobs: blobs, pasteboard: pasteboard)
            stressMonitor = monitor
            monitor.start()
            Task {
                for i in 0..<count {
                    pasteboard.clearContents()
                    pasteboard.setString("stress \(i) " + String(repeating: "x", count: 300), forType: .string)
                    try? await Task.sleep(for: .milliseconds(550))
                }
                monitor.stop()
                stressMonitor = nil
                Log.app.notice("stress done: \(count) writes, store has \(self.store.count()) items")
            }
        case "snapshot":
            // Debug aid: renders the quick panel to a PNG (no Screen Recording permission needed).
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "path" }?.value ?? "/tmp/clippy-panel.png"
            panel.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.panel.writeSnapshot(to: URL(fileURLWithPath: path))
            }
        #endif
        default: break
        }
    }
}
