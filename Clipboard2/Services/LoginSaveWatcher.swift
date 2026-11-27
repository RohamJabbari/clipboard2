import AppKit
import ApplicationServices

/// Offering to save new logins, for real (docs/features/auth-autofill.md → Saving logins).
///
/// - A paste into a password field is noticed two ways: Clipboard2's own paste (it knows when it
///   sends ⌘V), and the field's length jumping by exactly the clipboard text's length in one change
///   (`AXValueChanged` on the focused password field). A user's ⌘V can't be seen as a key press:
///   password fields turn on Secure Event Input, which hides keys from every other app. Either way
///   the value is read from the pasteboard at that moment; a password field's value is never read
///   through Accessibility (only its length).
/// - Submitting: Return (when keys are visible), focus leaving the field for a button or the page
///   (checked after a click too), or the window title / document changing within 10 s.
@MainActor
final class LoginSaveWatcher {
    private unowned let env: AppEnvironment
    private(set) lazy var coordinator: LoginSaveCoordinator = {
        let coordinator = LoginSaveCoordinator(
            store: env.secrets, presenter: ToastSaveOfferPresenter(),
            isEnabled: { [weak env] in env?.prefs.offerToSavePasswords ?? false },
            neverSites: { [weak env] in Set(env?.prefs.neverSavePasswordSites.map(\.key) ?? []) },
            addNeverSite: { [weak env] site in
                guard let env, !env.prefs.neverSavePasswordSites.contains(where: { $0.key == site.key }) else { return }
                env.prefs.neverSavePasswordSites.append(NeverSaveSite(site))
            })
        coordinator.onResult = { HUD.show($0, symbol: "key.fill") }
        return coordinator
    }()

    /// The focused password field, while there is one.
    private var secureField: AXElement?
    private var secureApp: NSRunningApplication?
    private var secureLength: Int?
    private var valueObserver: AXObserver?
    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var focusCheck: Task<Void, Never>?
    private(set) var isRunning = false

    init(env: AppEnvironment) {
        self.env = env
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let keyCode = event.keyCode
            let command = event.modifierFlags.contains(.command)
            MainActor.assumeIsolated { self?.keyDown(keyCode, command: command) }
        }) { monitors.append(keys) }
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFocusCheck(after: .milliseconds(350)) }
        }) { monitors.append(clicks) }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        detachValueObserver()
        secureField = nil
        secureApp = nil
        stopPolling()
        coordinator.drop()
    }

    // MARK: Focus

    /// The text field watcher's report (nil: no text field focused, or it scrolled away).
    func fieldChanged(_ field: TextFieldWatcher.Field?) {
        guard isRunning else { return }
        if let field, field.isSecure, let element = field.element, !isIgnored(field.app) {
            if element != secureField {
                if secureField != nil { leftSecureField(to: .textField) }
                attach(to: element, in: field.app)
            }
            if isPendingField(element) { coordinator.handle(.secureActivity) }
            return
        }
        guard secureField != nil else { return }
        if field != nil {
            leftSecureField(to: .textField)
        } else {
            // Nil also means "scrolled" or "moved": look again before deciding.
            scheduleFocusCheck(after: .milliseconds(200))
        }
    }

    private func scheduleFocusCheck(after delay: Duration) {
        guard secureField != nil || coordinator.pending != nil else { return }
        focusCheck?.cancel()
        focusCheck = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.checkFocus()
        }
    }

    /// Where focus is now, compared with the password field.
    private func checkFocus() {
        guard let field = secureField ?? (coordinator.pending?.fieldID?.base as? AXElement),
              let app = secureApp ?? NSWorkspace.shared.frontmostApplication else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            leftSecureField(to: .otherApp)
            return
        }
        guard let focused = FieldAX.focusedElement(pid: app.processIdentifier) else {
            leftSecureField(to: .page)
            return
        }
        if focused == field { return }
        if FieldAX.isTextField(focused) {
            leftSecureField(to: .textField)
        } else {
            let role: String? = FieldAX.value(focused.raw, kAXRoleAttribute)
            let buttons = [kAXButtonRole, "AXLink", kAXCheckBoxRole, kAXPopUpButtonRole] as [String]
            leftSecureField(to: role.map(buttons.contains) == true ? .button : .page)
        }
    }

    private func leftSecureField(to target: SubmitDetector.FocusTarget) {
        let field = secureField
        detachValueObserver()
        secureField = nil
        secureApp = nil
        secureLength = nil
        guard let field, isPendingField(field) else {
            if target != .textField, target != .otherApp { coordinator.handle(.focusLeft(to: target)) }
            return
        }
        coordinator.updateUsername(FieldAX.usernameAbove(field))
        coordinator.handle(.focusLeft(to: target))
        if coordinator.pending == nil { stopPolling() }
    }

    private func isPendingField(_ element: AXElement) -> Bool {
        (coordinator.pending?.fieldID?.base as? AXElement) == element
    }

    private func isIgnored(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return true }
        return bundleID == Bundle.main.bundleIdentifier || env.prefs.ignoredBundleIDs.contains(bundleID)
    }

    // MARK: Pastes

    private func attach(to element: AXElement, in app: NSRunningApplication) {
        detachValueObserver()
        secureField = element
        secureApp = app
        secureLength = Self.length(of: element)
        var created: AXObserver?
        guard AXObserverCreate(app.processIdentifier, loginSaveWatcherCallback, &created) == .success, let created else { return }
        valueObserver = created
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(created, element.raw, kAXValueChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    private func detachValueObserver() {
        if let valueObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(valueObserver), .defaultMode)
        }
        valueObserver = nil
    }

    /// The password field changed: a paste if it grew by the clipboard text's length at once.
    fileprivate func valueChanged() {
        guard let field = secureField else { return }
        let old = secureLength
        let new = Self.length(of: field)
        secureLength = new
        if let old, let new, let text = Self.pasteboardText(),
           PasteGuess.isPaste(oldLength: old, newLength: new, clipboard: text) {
            capture(text, field: field)
            return
        }
        guard isPendingField(field), let pending = coordinator.pending else { return }
        if let new, !pending.value.fits(length: new) {
            coordinator.invalidate()   // typed into after the paste: the value isn't known any more
            stopPolling()
        } else {
            coordinator.handle(.secureActivity)
        }
    }

    /// Clipboard2 is about to send ⌘V (its own paste): exact, no guessing.
    func willPostPaste() {
        guard isRunning, let app = NSWorkspace.shared.frontmostApplication, !isIgnored(app),
              let focused = FieldAX.focusedElement(pid: app.processIdentifier), FieldAX.isSecure(focused),
              let text = Self.pasteboardText() else { return }
        if secureField != focused { attach(to: focused, in: app) }
        capture(text, field: focused)
    }

    /// Fill and Suggest Strong Password: the value is saved already (no offer, but a later paste
    /// of the same value into the field doesn't offer either).
    func filled(_ value: String, field: AXElement?, in app: NSRunningApplication?) {
        guard isRunning, let field, let app, !isIgnored(app) else { return }
        capture(value, field: field, in: app, alreadySaved: true)
    }

    private func keyDown(_ keyCode: UInt16, command: Bool) {
        if command, keyCode == 9 {   // ⌘V where keys are visible (no Secure Event Input)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                self?.userPasted()
            }
        } else if keyCode == 36 || keyCode == 76, coordinator.pending != nil,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pendingApp?.processIdentifier {
            coordinator.handle(.returnKey)
            stopPolling()
        }
    }

    private func userPasted() {
        guard let field = secureField, let text = Self.pasteboardText(), !isPendingValue(text) else { return }
        capture(text, field: field)
    }

    private func isPendingValue(_ text: String) -> Bool { coordinator.pending?.value.equals(text) == true }

    private func capture(_ value: String, field: AXElement, in app: NSRunningApplication? = nil, alreadySaved: Bool = false) {
        guard let app = app ?? secureApp else { return }
        let pid = app.processIdentifier
        let site: LoginSite
        if let domain = FieldAX.pageDomain(pid: pid, bundleID: app.bundleIdentifier) {
            site = .web(domain: domain)
        } else if BrowserKind.of(bundleID: app.bundleIdentifier) != nil {
            return   // a browser page with no readable address: no site to save it for
        } else {
            site = .app(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? app.bundleIdentifier ?? "App")
        }
        coordinator.captured(value, site: site, username: FieldAX.usernameAbove(field), alreadySaved: alreadySaved,
                             page: Self.pageSignature(pid: pid), fieldID: AnyHashable(field))
        pendingApp = app
        startPolling()
    }

    // MARK: The page changing

    private var pendingApp: NSRunningApplication?

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        coordinator.expire()
        guard coordinator.pending != nil, let app = pendingApp else {
            stopPolling()
            return
        }
        coordinator.handle(.page(app.isTerminated ? "" : Self.pageSignature(pid: app.processIdentifier)))
        if coordinator.pending == nil { stopPolling() }
    }

    /// The front window's title and document (a browser's page URL): changes when the page does.
    private static func pageSignature(pid: pid_t) -> String {
        let app = FieldAX.application(pid)
        guard let window = FieldAX.element(app, kAXFocusedWindowAttribute) ?? FieldAX.element(app, kAXMainWindowAttribute) else {
            return ""
        }
        let title: String = FieldAX.value(window, kAXTitleAttribute) ?? ""
        let document: String = FieldAX.value(window, kAXDocumentAttribute) ?? ""
        return title + "\u{1F}" + document
    }

    // MARK: Helpers

    /// A field's length without its value: the character count, else the length of the bullets
    /// browsers report as a password field's value.
    private static func length(of element: AXElement) -> Int? {
        if let count: Int = FieldAX.value(element.raw, kAXNumberOfCharactersAttribute) { return count }
        let bullets: String? = FieldAX.value(element.raw, kAXValueAttribute)
        return bullets?.count
    }

    private static func pasteboardText() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return nil }
        return text
    }
}

/// Whether a password field's change was a paste of the clipboard text.
nonisolated enum PasteGuess {
    /// Shorter texts are too easily typed in one go to tell apart.
    static let minimumLength = 4

    /// The field grew by exactly the text's length in one change (or was replaced by it), and
    /// the text could be a password (one line, not too long).
    static func isPaste(oldLength: Int, newLength: Int, clipboard text: String) -> Bool {
        guard !text.contains(where: \.isNewline), text.count <= 256 else { return false }
        let lengths = Set([text.count, text.utf16.count])
        guard lengths.contains(where: { $0 >= minimumLength }) else { return false }
        let grew = newLength - oldLength
        return lengths.contains(grew) || (lengths.contains(newLength) && grew > 1)
    }
}

/// The offer as a toast: Save · Not now · Never for this site (Update · Not now), 20 seconds.
@MainActor
final class ToastSaveOfferPresenter: SaveOfferPresenting {
    func present(_ offer: SaveOffer, respond: @escaping (SaveOfferResponse) -> Void) {
        var actions: [ActionToast.Action] = [
            ActionToast.Action(title: offer.kind == .save ? "Save" : "Update", isPrimary: true) { respond(.save) },
            ActionToast.Action(title: "Not now") { respond(.notNow) },
        ]
        if offer.kind == .save {
            actions.append(ActionToast.Action(title: "Never for this site") { respond(.never) })
        }
        ActionToast.show(offer.title, detail: offer.detail, symbol: "key.fill", actions: actions,
                         duration: LoginSaveCoordinator.offerDuration, onDismiss: { respond(.timedOut) })
    }

    func dismiss() {
        ActionToast.hide()
    }
}

extension SecretStore: LoginSaveStore {
    func savedLogins(for site: LoginSite) -> [SavedLoginRef] {
        secrets.filter { site.matches($0) }.map { SavedLoginRef(id: $0.id, username: $0.username) }
    }

    func hasValue(_ value: SensitiveValue, id: String) -> Bool {
        SecretVault.value(id: id).map(value.equals) ?? false
    }

    func isKnownSecret(_ value: SensitiveValue) -> Bool {
        value.string.map { valueHashes.contains(ContentHasher.hash(text: $0)) } ?? false
    }

    func saveLogin(site: LoginSite, username: String?, value: String) -> Bool {
        add(name: site.title, value: value, username: username, urls: site.urls) != nil
    }
    // updateLogin(id:value:) is PasswordImportSink's too (PasswordImport.swift).
}

/// AXObserver callback; it runs on the main run loop, where the observer's source is installed.
nonisolated private func loginSaveWatcherCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    nonisolated(unsafe) let pointer = refcon
    MainActor.assumeIsolated {
        Unmanaged<LoginSaveWatcher>.fromOpaque(pointer).takeUnretainedValue().valueChanged()
    }
}
