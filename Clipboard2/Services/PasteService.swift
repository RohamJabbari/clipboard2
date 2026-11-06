import AppKit
import CoreGraphics

/// Writes items to the pasteboard and, when Accessibility is granted, sends ⌘V to the target app.
final class PasteService {
    private let store: ClipStore
    private let prefs: Preferences
    private let tracker: FrontmostAppTracker
    private let pasteboard: NSPasteboard

    /// Called when a paste needed Accessibility but it isn't granted (the item is still copied).
    var onAccessibilityMissing: (() -> Void)?
    /// Called on every paste (sync polls more often while the user is active).
    var onPaste: (() -> Void)?

    init(store: ClipStore, prefs: Preferences, tracker: FrontmostAppTracker, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.prefs = prefs
        self.tracker = tracker
        self.pasteboard = pasteboard
    }

    // MARK: Pasteboard writes

    /// Writes an item. `transform` (or the target app's default transform) applies to text items.
    func write(_ item: ClipItem, transform explicit: Transform? = nil, targetBundleID: String? = nil) {
        let transform = explicit ?? prefs.defaultTransform(for: targetBundleID)
        pasteboard.clearContents()

        switch item.kind {
        case .text, .richText:
            if let transform, transform != .plainText {
                pasteboard.setString(transform.apply(item.text) ?? item.text, forType: .string)
            } else {
                if transform == nil {
                    if let rtf = item.rtfData { pasteboard.setData(rtf, forType: .rtf) }
                    if let html = item.htmlData { pasteboard.setData(html, forType: .html) }
                }
                pasteboard.setString(item.text, forType: .string)
            }

        case .image:
            if let name = item.imageFile, let data = try? Data(contentsOf: store.blobs.url(for: name)) {
                pasteboard.setData(data, forType: .png)
                if let tiff = NSImage(data: data)?.tiffRepresentation {
                    pasteboard.setData(tiff, forType: .tiff)
                }
            }

        case .file:
            let urls = item.fileURLs
            if !urls.isEmpty {
                pasteboard.writeObjects(urls as [NSURL])
            }
            if transform != nil {
                pasteboard.setString(item.text, forType: .string)
            }
        }
        markAsOwnWrite()
    }

    /// Several items at once: text is joined with line breaks (what nearly every app expects).
    /// Anything else goes out as files, the way Finder copies several: documents and folders as
    /// they are, images as PNG files, and any text items alongside as plain text.
    func write(_ items: [ClipItem], transform: Transform?) {
        if items.count == 1, let item = items.first {
            write(item, transform: transform)
            return
        }
        pasteboard.clearContents()
        let text = items.filter(\.kind.isTextual).map { transform?.apply($0.text) ?? $0.text }.joined(separator: "\n")
        if items.allSatisfy(\.kind.isTextual) {
            pasteboard.setString(text, forType: .string)
        } else {
            var imageNumber = 0
            let urls: [URL] = items.flatMap { item -> [URL] in
                switch item.kind {
                case .file: return item.fileURLs
                case .image:
                    imageNumber += 1
                    return exportedImage(item, number: imageNumber).map { [$0] } ?? []
                case .text, .richText: return []
                }
            }
            setFiles(urls)
            if !text.isEmpty { pasteboard.setString(text, forType: .string) }
        }
        markAsOwnWrite()
    }

    /// Just these files (some of a multi-file item), as Finder would copy them.
    func write(fileURLs urls: [URL]) {
        pasteboard.clearContents()
        setFiles(urls)
        markAsOwnWrite()
    }

    func paste(fileURLs urls: [URL], into target: NSRunningApplication? = nil) {
        let target = target ?? tracker.targetApp
        write(fileURLs: urls)
        sendPasteKeystroke(to: target)
    }

    private func setFiles(_ urls: [URL]) {
        pasteboard.writeObjects(urls as [NSURL])
        // Older and Chromium-based apps (Slack, Teams, WhatsApp…) still read the legacy list of paths.
        pasteboard.setPropertyList(urls.map(\.path), forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
    }

    /// An image clip as a real PNG file, so it can travel with other files. Numbered so several
    /// pasted into one folder don't collide; kept per item so a later ⌘V still finds it.
    private func exportedImage(_ item: ClipItem, number: Int) -> URL? {
        guard let name = item.imageFile else { return nil }
        let source = store.blobs.url(for: name)
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Clipboard2 Paste").appending(path: item.id.uuidString)
        let url = folder.appending(path: number == 1 ? "Image.png" : "Image \(number).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: url)
            return url
        } catch {
            Log.paste.error("Couldn't export image for paste: \(error.localizedDescription)")
            return nil
        }
    }

    func paste(_ items: [ClipItem], transform: Transform? = nil, into target: NSRunningApplication? = nil) {
        let target = target ?? tracker.targetApp
        write(items, transform: transform)
        sendPasteKeystroke(to: target)
    }

    func write(text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        markAsOwnWrite()
    }

    /// Writes a secret marked concealed + transient so clipboard managers (Clipboard2 included) skip it,
    /// then clears the clipboard after `clearAfter` seconds unless something else was copied since.
    func writeSecret(_ value: String, clearAfter seconds: Int) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardFilter.concealedType))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardFilter.transientType))
        markAsOwnWrite()
        guard seconds > 0 else { return }
        let changeCount = pasteboard.changeCount
        let pasteboard = self.pasteboard
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if pasteboard.changeCount == changeCount { pasteboard.clearContents() }
        }
    }

    /// Pastes `text`, then puts the previous clipboard back so the user's clipboard is unchanged.
    /// Without Accessibility the text simply stays on the clipboard for a manual ⌘V.
    func pastePreservingClipboard(text: String, into target: NSRunningApplication?, onRestored: @escaping () -> Void) {
        let saved = snapshot()
        write(text: text)
        guard AXPermission.isTrusted else {
            sendPasteKeystroke(to: target)      // shows the Accessibility onboarding
            return
        }
        sendPasteKeystroke(to: target)
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            restore(saved)
            onRestored()
        }
    }

    func pasteSecret(_ value: String, into target: NSRunningApplication?, clearAfter seconds: Int) {
        writeSecret(value, clearAfter: seconds)
        sendPasteKeystroke(to: target)
    }

    private func markAsOwnWrite() {
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardFilter.internalMarkerType))
    }

    // MARK: Copy / paste

    /// Copying or pasting from the list leaves the item where it is; only a new copy moves it up.
    func copy(_ item: ClipItem) {
        write(item)
    }

    /// Copies the item and pastes it into `target` (defaults to the last non-Clipboard2 app).
    func paste(_ item: ClipItem, transform: Transform? = nil, into target: NSRunningApplication? = nil) {
        let target = target ?? tracker.targetApp
        write(item, transform: transform, targetBundleID: target?.bundleIdentifier)
        sendPasteKeystroke(to: target)
    }

    /// Pastes arbitrary text; `cursorOffsetFromEnd` moves the caret left afterwards ({cursor}).
    func paste(text: String, into target: NSRunningApplication? = nil, cursorOffsetFromEnd: Int = 0) {
        let target = target ?? tracker.targetApp
        write(text: text)
        sendPasteKeystroke(to: target, cursorOffsetFromEnd: cursorOffsetFromEnd)
    }

    private func sendPasteKeystroke(to target: NSRunningApplication?, cursorOffsetFromEnd: Int = 0) {
        onPaste?()
        guard AXPermission.isTrusted else {
            Log.paste.info("Accessibility not granted; copied only")
            onAccessibilityMissing?()
            return
        }
        if let target, !target.isActive {
            target.activate()
        }
        Task {
            // Give the target app a moment to become key after our panel/popover closes.
            try? await Task.sleep(for: .milliseconds(90))
            Self.postKey(9, flags: .maskCommand)            // kVK_ANSI_V
            if cursorOffsetFromEnd > 0 {
                try? await Task.sleep(for: .milliseconds(60))
                for _ in 0..<min(cursorOffsetFromEnd, 5_000) {
                    Self.postKey(123, flags: [])            // kVK_LeftArrow
                }
            }
        }
    }

    /// Posts a mouse click (or double-click) at a global, top-left-origin location.
    static func postClick(at location: CGPoint, button: CGMouseButton = .left, count: Int = 1) {
        let (downType, upType): (CGEventType, CGEventType) = button == .right
            ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        let source = CGEventSource(stateID: .combinedSessionState)
        for click in 1...max(1, count) {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: location, mouseButton: button),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: location, mouseButton: button)
            else { return }
            for event in [down, up] {
                event.flags = []
                event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
                event.post(tap: .cgSessionEventTap)
            }
        }
    }

    // MARK: Reading the current selection

    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    func snapshot() -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { data[type] = item.data(forType: type) }
            return data
        }
    }

    func restore(_ snapshot: Snapshot) {
        pasteboard.clearContents()
        let items = snapshot.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// Sends ⌘C to the frontmost app and returns the copied text (nil if nothing was selected).
    /// The caller restores the previous clipboard afterwards.
    func copySelectedText() async -> String? {
        let before = pasteboard.changeCount
        Self.postKey(8, flags: .maskCommand)                 // kVK_ANSI_C
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(20))
            if pasteboard.changeCount != before { break }
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        return text?.isEmpty == false ? text : nil
    }

    /// Presses ⌘C in the frontmost app and reads what it copied the way history capture does, so a
    /// document selected in Finder arrives as the file, not its name. Nil when nothing was copied or
    /// the copy is marked concealed (password managers). Call `restore` afterwards.
    func copySelection(source: AppRef?) async -> RawCapture? {
        let before = pasteboard.changeCount
        Self.postKey(8, flags: .maskCommand)                 // kVK_ANSI_C
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(20))
            if pasteboard.changeCount != before { break }
        }
        guard pasteboard.changeCount != before else { return nil }
        let types = pasteboard.types?.map(\.rawValue) ?? []
        guard !types.contains(where: ClipboardFilter.blockedTypes.contains) else { return nil }
        return PasteboardReader.read(pasteboard, source: source)
    }

    /// Value stamped on every event Clipboard2 synthesises, so Clipboard2's own event tap ignores them.
    static let syntheticEventMarker: Int64 = 0x436C_6970   // "Clip"

    static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
