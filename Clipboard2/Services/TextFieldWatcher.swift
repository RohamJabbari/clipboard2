import AppKit
import ApplicationServices

/// Follows the focused text field in the frontmost app through the Accessibility API, for the
/// paste icon in text fields. It reads only when focus changes and never reads text. Password
/// fields are reported too (flagged `isSecure`), for Auth's items there; it gives up quickly on
/// apps that don't answer.
///
/// It deliberately doesn't set `AXManualAccessibility` on Electron apps: that makes them build
/// their whole accessibility tree, which slowed typing and copying in them by seconds.
final class TextFieldWatcher {
    /// A focused, editable text field and its visible frame on screen (AppKit coordinates).
    struct Field: Equatable {
        let frame: CGRect
        let app: NSRunningApplication
        /// A password field.
        var isSecure = false
        /// The field itself, for Fill (its kind, the form around it).
        var element: AXElement?
    }

    /// Called on the main thread whenever the focused field changes (nil: none).
    var onChange: (Field?) -> Void = { _ in }

    private var app: NSRunningApplication?
    private var appElement: AXUIElement?
    private var observer: AXObserver?
    private var workspaceObserver: NSObjectProtocol?
    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var reported: Field?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private(set) var isRunning = false

    func start() {
        guard !isRunning, AXPermission.isTrusted else { return }
        isRunning = true
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid, pid != self.ownPID else { return }
                self.attach(to: NSRunningApplication(processIdentifier: pid))
            }
        }
        // Scrolling moves the field.
        if let scroll = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.report(nil)
                self?.schedule(after: 0.4)
            }
        }) {
            monitors.append(scroll)
        }
        attach(to: NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        detach()
        report(nil)
    }

    // MARK: Observing one app

    private func attach(to app: NSRunningApplication?) {
        detach()
        guard let app, app.processIdentifier != ownPID else {
            report(nil)
            return
        }
        self.app = app
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app must not stall Clipboard2: every query gives up after a quarter second.
        AXUIElementSetMessagingTimeout(element, 0.25)
        appElement = element

        var created: AXObserver?
        guard AXObserverCreate(app.processIdentifier, textFieldWatcherCallback, &created) == .success, let created else {
            report(nil)
            return
        }
        observer = created
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedUIElementChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        schedule(after: 0.05)
    }

    private func detach() {
        pending?.cancel()
        pending = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        app = nil
    }

    fileprivate func handle(_ notification: String) {
        switch notification {
        case kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification:
            schedule(after: 0.15)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            report(nil)
            schedule(after: 0.35)
        default:
            schedule(after: 0.25)
        }
    }

    private func schedule(after delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Reading

    private func evaluate() {
        guard isRunning, let app, let appElement else { return }
        guard let element = Self.element(appElement, kAXFocusedUIElementAttribute) else {
            report(nil)
            return
        }
        let subrole: String? = Self.value(element, kAXSubroleAttribute)
        let role: String? = Self.value(element, kAXRoleAttribute)
        let secure = subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField"
        guard secure || Self.isEditable(element) else {
            report(nil)
            return
        }
        report(Self.visibleFrame(of: element).map { Field(frame: $0, app: app, isSecure: secure, element: AXElement(raw: element)) })
    }

    private func report(_ field: Field?) {
        guard reported != field else { return }
        reported = field
        onChange(field)
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        let role: String? = value(element, kAXRoleAttribute)
        let textRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole] as [String]
        guard let role, textRoles.contains(role) else { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    /// The element's frame, cut to its window so a long document doesn't reach off screen.
    private static func visibleFrame(of element: AXUIElement) -> CGRect? {
        guard var frame = frame(of: element) else { return nil }
        if let window = Self.element(element, kAXWindowAttribute), let windowFrame = Self.frame(of: window) {
            frame = frame.intersection(windowFrame)
        }
        guard !frame.isNull, frame.width >= 60, frame.height >= 16 else { return nil }
        return appKitRect(frame)
    }

    // MARK: Accessibility helpers

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = axValue(element, kAXPositionAttribute),
              let sizeValue = axValue(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Accessibility measures from the top-left of the main screen; AppKit from its bottom-left.
    private static func appKitRect(_ rect: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// AXObserver callback; it runs on the main run loop, where the observer's source is installed.
nonisolated private func textFieldWatcherCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    nonisolated(unsafe) let pointer = refcon
    let name = notification as String
    MainActor.assumeIsolated {
        Unmanaged<TextFieldWatcher>.fromOpaque(pointer).takeUnretainedValue().handle(name)
    }
}
