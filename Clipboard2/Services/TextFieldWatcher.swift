import AppKit
import ApplicationServices

/// Follows the focused text field and its selection in the frontmost app through the
/// Accessibility API, for the icon beside selected text and the paste icon in text fields.
/// It reads only when something changes, keeps nothing it reads, skips password fields, and
/// gives up quickly on apps that don't answer.
final class TextFieldWatcher {
    /// Text selected in another app, and where its last character is on screen (AppKit coordinates).
    struct Selection: Equatable {
        let text: String
        let anchor: CGRect
        let app: NSRunningApplication
    }

    /// A focused, editable text field and its visible frame on screen (AppKit coordinates).
    struct Field: Equatable {
        let frame: CGRect
        let app: NSRunningApplication
    }

    /// Called on the main thread whenever the selection or focused field changes (nil: none).
    var onChange: (Selection?, Field?) -> Void = { _, _ in }

    private var app: NSRunningApplication?
    private var appElement: AXUIElement?
    private var observer: AXObserver?
    private var focused: AXUIElement?
    private var workspaceObserver: NSObjectProtocol?
    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var lastMouseUp: (point: NSPoint, time: Date)?
    private var reported: (Selection?, Field?) = (nil, nil)
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
        // A selection made with the mouse is final on mouse-up; scrolling moves everything.
        if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastMouseUp = (NSEvent.mouseLocation, .now)
                self?.schedule(after: 0.12)
            }
        }) {
            monitors.append(up)
        }
        if let scroll = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.report(nil, nil)
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
        report(nil, nil)
    }

    // MARK: Observing one app

    private func attach(to app: NSRunningApplication?) {
        detach()
        guard let app, app.processIdentifier != ownPID else {
            report(nil, nil)
            return
        }
        self.app = app
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app must not stall Clipboard2: every query gives up after a quarter second.
        AXUIElementSetMessagingTimeout(element, 0.25)
        // Electron apps build their accessibility tree only when asked.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        appElement = element

        var created: AXObserver?
        guard AXObserverCreate(app.processIdentifier, textFieldWatcherCallback, &created) == .success, let created else {
            report(nil, nil)
            return
        }
        observer = created
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedUIElementChangedNotification, kAXSelectedTextChangedNotification,
                     kAXWindowMovedNotification, kAXWindowResizedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        followFocus()
        schedule(after: 0.05)
    }

    private func detach() {
        pending?.cancel()
        pending = nil
        if let observer {
            if let focused { unfollow(focused, observer: observer) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        focused = nil
        app = nil
    }

    /// Some apps only send selection and value changes to the focused element itself.
    private func followFocus() {
        guard let observer, let appElement else { return }
        if let focused { unfollow(focused, observer: observer) }
        focused = Self.element(appElement, kAXFocusedUIElementAttribute)
        guard let focused else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, focused, kAXSelectedTextChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, focused, kAXValueChangedNotification as CFString, refcon)
    }

    private func unfollow(_ element: AXUIElement, observer: AXObserver) {
        AXObserverRemoveNotification(observer, element, kAXSelectedTextChangedNotification as CFString)
        AXObserverRemoveNotification(observer, element, kAXValueChangedNotification as CFString)
    }

    fileprivate func handle(_ notification: String) {
        switch notification {
        case kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification:
            followFocus()
            schedule(after: 0.15)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            report(nil, nil)
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
        // Still dragging out a selection: wait for the mouse-up.
        if NSEvent.pressedMouseButtons != 0 {
            schedule(after: 0.15)
            return
        }
        guard let element = Self.element(appElement, kAXFocusedUIElementAttribute) else {
            report(nil, nil)
            return
        }
        let subrole: String? = Self.value(element, kAXSubroleAttribute)
        if subrole == (kAXSecureTextFieldSubrole as String) {
            report(nil, nil)
            return
        }
        var selection: Selection?
        if let text: String = Self.value(element, kAXSelectedTextAttribute),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 20_000,
           let anchor = selectionAnchor(in: element) {
            selection = Selection(text: text, anchor: anchor, app: app)
        }
        let field = Self.isEditable(element) ? Self.visibleFrame(of: element).map { Field(frame: $0, app: app) } : nil
        report(selection, field)
    }

    private func report(_ selection: Selection?, _ field: Field?) {
        guard reported.0 != selection || reported.1 != field else { return }
        reported = (selection, field)
        onChange(selection, field)
    }

    /// The last selected character's box, or the whole selection's, or where the mouse let go.
    private func selectionAnchor(in element: AXUIElement) -> CGRect? {
        if let range = Self.selectedRange(element), range.length > 0 {
            let last = CFRange(location: range.location + range.length - 1, length: 1)
            if let rect = Self.bounds(of: last, in: element) ?? Self.bounds(of: range, in: element) {
                return Self.appKitRect(rect)
            }
        }
        if let lastMouseUp, Date.now.timeIntervalSince(lastMouseUp.time) < 1.5 {
            return CGRect(origin: lastMouseUp.point, size: .zero)
        }
        return nil
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

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = axValue(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    private static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0,
              rect.height < 400 else { return nil }
        return rect
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
