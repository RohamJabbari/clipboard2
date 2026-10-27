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

    /// Why the history database couldn't be opened. While set, the app runs on an empty
    /// in-memory store and never captures, sweeps files or syncs, so nothing on disk is touched.
    let storeOpenError: String?

    private init() {
        prefs = Preferences(defaults: .standard)
        blobs = BlobStore(directory: AppPaths.blobsDirectory)
        let opened = Self.openContainer(url: AppPaths.storeURL)
        container = opened.container
        storeOpenError = opened.error
        store = ClipStore(context: container.mainContext, blobs: blobs)
        appTracker = FrontmostAppTracker()
        monitor = ClipboardMonitor(store: store, prefs: prefs, tracker: appTracker, blobs: blobs)
        paste = PasteService(store: store, prefs: prefs, tracker: appTracker)
        snippets = SnippetStore(context: container.mainContext)
        secrets = SecretStore(prefs: prefs)
        slots = QuickSlots(defaults: .standard, store: store, snippets: snippets, secrets: secrets)
        sync = SyncAccount(prefs: prefs, context: container.mainContext, store: store, snippets: snippets, secrets: secrets)
    }

    /// Every persisted model (the newest store version); tests build in-memory containers from it.
    static let schema = Schema(versionedSchema: StoreSchemaV2.self)

    /// Opens the store with the migration plan. Stores from before the versioned schema (older
    /// than 1.3.0) match no version, so they get the automatic lightweight migration they always
    /// had. If neither works, an in-memory store and the error, never a wiped history.
    static func openContainer(url: URL) -> (container: ModelContainer, error: String?) {
        let schema = Self.schema
        let configuration = ModelConfiguration(schema: schema, url: url)
        do {
            return (try ModelContainer(for: schema, migrationPlan: StoreMigrationPlan.self, configurations: configuration), nil)
        } catch {
            Log.store.error("Opening the store with the migration plan failed: \(error.localizedDescription, privacy: .public)")
        }
        do {
            return (try ModelContainer(for: schema, configurations: configuration), nil)
        } catch {
            Log.store.error("Failed to open store at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public). Running without history.")
            do {
                let memory = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
                return (memory, error.localizedDescription)
            } catch {
                fatalError("SwiftData is unavailable: \(error)")
            }
        }
    }

    /// The history couldn't be opened: say so instead of quietly starting over.
    private func showStoreOpenError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Clipboard2 Can't Open Your History"
        alert.informativeText = "Your history, images and files are untouched, but Clipboard2 won't record or sync anything until it can open them. Quit and open Clipboard2 again; if this keeps happening, restart your Mac or contact support.\n\n\(message)"
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Continue Without History")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
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
        // Retention only stops tracking items (ClipStore drops their sync metadata itself), so
        // they're never deleted on other devices.
        sync.onSessionChange = { [weak self] active in self?.setSendToGroupShortcut(active: active) }
        sync.onItemSentHere = { device in HUD.show("Sent from \(device)", symbol: "arrow.down.circle.fill") }
        applyAppearance()
        if let storeOpenError {
            // On the stand-in store: no capture, no sync, no sweeps (they'd delete every file).
            DispatchQueue.main.async { [weak self] in self?.showStoreOpenError(storeOpenError) }
        } else {
            sync.start()
            migrateDedupeIfNeeded()
            monitor.start()
            runMaintenance()
        }

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
        // Build and render the quick panel once, off screen, so the first ⇧⌘V has nothing to set up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.panel.warmUp() }
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
        contextMenu.update()   // starts the right-click tap once Accessibility is granted
        guard storeOpenError == nil else { return }
        store.enforceRetention(maxItems: prefs.maxItems, maxAge: prefs.maxAge)
        // Sync polls on its own cadence (3 s / 15 s / 60 s).
        maintenanceRuns &+= 1
        if maintenanceRuns % 30 == 1 {   // directory scans: every ~30 min
            store.removeOrphanedBlobs()
            store.removeOrphanedSyncedFiles()
        }
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

    /// Copies the selection in the frontmost app (text, rich text, images or files) and stores it
    /// as history in the default sync group, then confirms with a HUD. Without a default group it
    /// opens Settings → Sync.
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
            let raw = await paste.copySelection(source: source)
            paste.restore(saved)
            monitor.acknowledgeCurrentChange()
            monitor.isSuspended = false
            guard let raw, let capture = await CaptureProcessor.process(raw, blobs: store.blobs) else {
                NSSound.beep()
                return
            }
            if monitor.shouldDiscard?(capture) == true || (capture.kind.isTextual && capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                // A saved secret (or blank text) never goes to a group this way.
                store.blobs.delete(capture.imageFile)
                store.blobs.delete(capture.thumbnailFile)
                NSSound.beep()
                return
            }
            store.ingest(capture, spaceID: group.id)
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
            alert.informativeText = "Clipboard2 uses ⌥⌘C to send the selected text to your default sync group. While you're signed in to sync, this replaces ⌥⌘C in other apps: Chrome's Inspect Elements, Safari's JavaScript Console and Finder's Copy as Pathname.\n\nTo change or clear the shortcut, open Settings → Shortcuts → Send selection to default group."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Change Shortcut…")
            NSApp.activate()
            if alert.runModal() == .alertSecondButtonReturn {
                SettingsOpener.open(tab: .shortcuts)
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
                panel.show { [weak self] in self?.panel.model.activate(entry) }
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
        case "settings":
            // clipboard2://settings?tab=history opens a specific tab.
            let tab = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "tab" }?.value.flatMap(SettingsTab.init(stored:))
            SettingsOpener.open(tab: tab)
        case "panel":
            #if DEBUG
            // Debug aid: clipboard2://panel?origin=left opens from that edge (and keeps it).
            if let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "origin" })?.value,
               let origin = PanelOrigin(rawValue: raw) {
                prefs.panelOrigin = origin
            }
            // …&action=open / close / toggle (default), like pressing the shortcut.
            let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "action" })?.value
            switch action {
            case "close": panel.close(); return
            case "open": if panel.isVisible { return }
            default: if panel.isVisible { panel.close(); return }
            }
            #endif
            panel.show()
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
        case "check-updates":
            updates.checkForUpdates()
        case "demo":
            // Debug aid: neutral sample history for screenshots (Debug builds keep separate data).
            guard store.count() == 0 else { return }
            let samples: [(String, String, String, Int)] = [
                ("Let's move the design review to Thursday at 10 — I'll send a new invite.", "com.apple.mail", "Mail", 2),
                ("https://developer.apple.com/documentation/quartzcore/caspringanimation", "com.apple.Safari", "Safari", 9),
                ("func spring(response: Double, dampingRatio: Double) -> Animation", "com.apple.dt.Xcode", "Xcode", 25),
                ("brew install xcodegen && make debug", "com.apple.Terminal", "Terminal", 48),
                ("{\n  \"name\": \"Clipboard2\",\n  \"version\": \"1.4.0\"\n}", "com.apple.dt.Xcode", "Xcode", 75),
                ("Grocery list: oat milk, lemons, basil, sourdough", "com.apple.Notes", "Notes", 130),
                ("#0A84FF", "com.apple.Safari", "Safari", 200),
                ("Thanks for the quick turnaround — looks great!", "com.apple.MobileSMS", "Messages", 320),
                ("Meeting notes: ship the panel motion, simplify Settings, quiet updates.", "com.apple.Notes", "Notes", 600),
                ("+43 1 234 5678", "com.apple.Safari", "Safari", 1500),
            ]
            for (index, sample) in samples.enumerated().reversed() {
                let item = store.ingest(.text(sample.0, source: AppRef(bundleID: sample.1, name: sample.2)),
                                        now: .now.addingTimeInterval(-Double(sample.3 * 60)))
                if index == 5 { store.togglePin(item) }
            }
            if snippets.all().isEmpty {
                _ = snippets.create(name: "Email sign-off", keyword: ";sig", body: "Best,\n{name}")
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
