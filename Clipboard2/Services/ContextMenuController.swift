import AppKit
import KeyboardShortcuts

nonisolated enum ContextMenuModifier: String, CaseIterable, Identifiable, Sendable {
    case command, option

    var id: String { rawValue }
    var title: String { self == .command ? "⌘ Command" : "⌥ Option" }
    var symbol: String { self == .command ? "⌘" : "⌥" }
    var flag: CGEventFlags { self == .command ? .maskCommand : .maskAlternate }
}

/// ⌘-right-click anywhere opens Clipboard2's menu: Clipboard2 items, the standard edit items, Finder
/// items in Finder, and "Show ‹App› Menu" to open the app's own menu at the same spot.
///
/// macOS has no API to add items to other apps' context menus, so a session event tap
/// (Accessibility permission) swallows only the modified right-click and Clipboard2 shows a regular
/// NSMenu there instead. Plain right-clicks are never touched.
final class ContextMenuController: NSObject {
    private unowned let env: AppEnvironment
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowNextRightMouseUp = false
    private var clickLocation: CGPoint = .zero          // global, top-left origin
    private var target: NSRunningApplication?
    /// The global shortcuts shown in the menu, paused while it's open so they don't also fire after it closes.
    private var pausedShortcuts: [KeyboardShortcuts.Name] = []

    init(env: AppEnvironment) {
        self.env = env
    }

    var isRunning: Bool { tap != nil }

    /// Starts the event tap if enabled and Accessibility is granted; safe to call repeatedly.
    func update() {
        if env.prefs.contextMenuEnabled && AXPermission.isTrusted {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: contextMenuTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.app.error("Couldn't create the right-click event tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    /// Returns true to swallow the event.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .rightMouseDown:
            guard event.getIntegerValueField(.eventSourceUserData) != PasteService.syntheticEventMarker,
                  Self.matches(event.flags, env.prefs.contextMenuModifier)
            else { return false }
            // Every item needs Accessibility; without it, leave the click alone and explain.
            guard AXPermission.isTrusted else {
                DispatchQueue.main.async { [weak self] in self?.env.showPermissions() }
                return false
            }
            swallowNextRightMouseUp = true
            clickLocation = event.location
            DispatchQueue.main.async { [weak self] in self?.showMenu() }
            return true
        case .rightMouseUp:
            guard swallowNextRightMouseUp else { return false }
            swallowNextRightMouseUp = false
            return true
        default:
            return false
        }
    }

    nonisolated static func matches(_ flags: CGEventFlags, _ modifier: ContextMenuModifier) -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return flags.intersection(relevant) == modifier.flag
    }

    // MARK: Menu

    private func showMenu() {
        target = NSWorkspace.shared.frontmostApplication.flatMap {
            $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0
        } ?? env.appTracker.targetApp
        let isFinder = target?.bundleIdentifier == "com.apple.finder"
        if isFinder {
            // A real right-click selects the item under the pointer; do the same, and give the
            // click time to land before the menu opens (otherwise it hits the menu).
            PasteService.postClick(at: clickLocation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.presentMenu(isFinder: true) }
        } else {
            presentMenu(isFinder: false)
        }
    }

    private func presentMenu(isFinder: Bool) {
        let menu = buildMenu(isFinder: isFinder)
        guard let primary = NSScreen.screens.first else { return }
        let point = NSPoint(x: clickLocation.x, y: primary.frame.maxY - clickLocation.y)
        // Don't activate Clipboard2: activation finishing mid-tracking closes the menu, and the
        // right-clicked app keeps focus so keystrokes from the items reach it.
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    private func buildMenu(isFinder: Bool) -> NSMenu {
        let menu = NSMenu(title: "Clipboard2")
        menu.autoenablesItems = false
        menu.delegate = self
        pausedShortcuts = []
        let appName = target?.localizedName ?? "App"

        // Clipboard2 — every global shortcut is listed with its keys, as a reminder.
        menu.addItem(.sectionHeader(title: "Clipboard2"))
        menu.addItem(item("Search Clipboard2…", symbol: "magnifyingglass", shortcut: .toggleQuickPanel) { [weak self] in
            self?.inTarget { $0.env.showQuickPanel() }
        })
        if !isFinder {
            menu.addItem(item("Actions on Selection…", symbol: "wand.and.stars", shortcut: .selectionActions) { [weak self] in
                self?.inTarget { $0.env.showSelectionActions() }
            })
        }
        let imageOnClipboard = ClipboardImage.current(in: .general) != nil
        menu.addItem(item("Paste Text from Clipboard Image", symbol: "text.viewfinder", enabled: imageOnClipboard,
                          shortcut: .pasteAsText) { [weak self] in
            self?.inTarget { $0.env.pasteClipboardAsText() }
        })
        menu.addItem(item("Capture Text from Screen…", symbol: "rectangle.dashed", shortcut: .captureText) { [weak self] in
            self?.inTarget { $0.env.captureScreenText() }
        })
        if env.sync.isSignedIn {
            menu.addItem(item("Send Selection to Group", symbol: "person.2", shortcut: .sendToGroup) { [weak self] in
                self?.inTarget { $0.env.sendSelectionToGroup() }
            })
            menu.addItem(item("Paste from Group", symbol: "person.2.fill", shortcut: .pasteFromGroup) { [weak self] in
                self?.inTarget { $0.env.pasteFromDefaultGroup() }
            })
        }
        menu.addItem(submenuItem("Recent", symbol: "clock", items: recentItems()))
        menu.addItem(submenuItem("Snippets", symbol: "text.badge.star", items: snippetItems()))
        menu.addItem(submenuItem("Secrets", symbol: "key", items: secretItems()))
        let slots = slotItems()
        if !slots.isEmpty { menu.addItem(submenuItem("Quick Slots", symbol: "number", items: slots)) }

        menu.addItem(.separator())
        if isFinder {
            menu.addItem(keyItem("Open", symbol: "arrow.up.forward.app", key: 31, flags: .maskCommand))
            menu.addItem(keyItem("Quick Look", symbol: "eye", key: 49, flags: []))
            menu.addItem(keyItem("Get Info", symbol: "info.circle", key: 34, flags: .maskCommand))
            menu.addItem(.separator())
            menu.addItem(keyItem("Copy", symbol: "doc.on.doc", key: 8, flags: .maskCommand))
            menu.addItem(keyItem("Copy Path", symbol: "link", key: 8, flags: [.maskCommand, .maskAlternate]))
            menu.addItem(keyItem("Paste", symbol: "doc.on.clipboard", key: 9, flags: .maskCommand))
            menu.addItem(keyItem("Duplicate", symbol: "plus.square.on.square", key: 2, flags: .maskCommand))
            menu.addItem(.separator())
            menu.addItem(keyItem("Move to Trash", symbol: "trash", key: 51, flags: .maskCommand))
        } else {
            menu.addItem(keyItem("Look Up", symbol: "character.book.closed", key: 2, flags: [.maskControl, .maskCommand]))
            menu.addItem(.separator())
            menu.addItem(keyItem("Cut", symbol: "scissors", key: 7, flags: .maskCommand))
            menu.addItem(keyItem("Copy", symbol: "doc.on.doc", key: 8, flags: .maskCommand))
            menu.addItem(keyItem("Paste", symbol: "doc.on.clipboard", key: 9, flags: .maskCommand))
            menu.addItem(item("Paste as Plain Text", symbol: "doc.plaintext", shortcut: .pasteAsText) { [weak self] in
                self?.inTarget { $0.env.pasteClipboardAsText() }
            })
            menu.addItem(.separator())
            menu.addItem(keyItem("Select All", symbol: "selection.pin.in.out", key: 0, flags: .maskCommand))
            let location = clickLocation
            menu.addItem(item("Select Word", symbol: "character.cursor.ibeam") { [weak self] in
                self?.inTarget { _ in PasteService.postClick(at: location, count: 2) }
            })
            menu.addItem(.separator())
            menu.addItem(keyItem("Undo", symbol: "arrow.uturn.backward", key: 6, flags: .maskCommand))
            menu.addItem(keyItem("Redo", symbol: "arrow.uturn.forward", key: 6, flags: [.maskCommand, .maskShift]))
        }

        menu.addItem(.separator())
        let location = clickLocation
        menu.addItem(item("Show “\(appName)” Menu", symbol: "contextualmenu.and.cursorarrow") { [weak self] in
            self?.inTarget { _ in PasteService.postClick(at: location, button: .right) }
        })
        return menu
    }

    /// Assigned quick slots, each with its global shortcut if one is set.
    private func slotItems() -> [NSMenuItem] {
        QuickSlots.range.compactMap { number in
            guard let title = env.slots.title(for: number) else { return nil }
            return item("\(number) — \(String(title.prefix(50)))", symbol: "\(number).square",
                        shortcut: KeyboardShortcuts.Name.quickSlots[number - 1]) { [weak self] in
                self?.inTarget { $0.env.pasteSlot(number) }
            }
        }
    }

    private func recentItems() -> [NSMenuItem] {
        let recent = env.store.allItems().prefix(12)
        guard !recent.isEmpty else { return [disabled("No History")] }
        return recent.map { clip in
            let title = String(clip.displayTitle.prefix(60))
            let menuItem = item(title, symbol: clip.isPinned ? "pin" : clip.kind.symbol) { [weak self] in
                self?.inTarget { controller in controller.env.paste.paste(clip, into: controller.target) }
            }
            return menuItem
        }
    }

    private func snippetItems() -> [NSMenuItem] {
        let snippets = env.snippets.all()
        guard !snippets.isEmpty else { return [disabled("No Snippets")] }
        return snippets.map { snippet in
            item(snippet.name.isEmpty ? "Untitled" : snippet.name, symbol: "text.badge.star") { [weak self] in
                self?.inTarget { controller in
                    if SnippetExpander.customFields(in: snippet.body).isEmpty {
                        controller.env.pasteSnippet(snippet, values: [:], into: controller.target)
                    } else {
                        controller.env.panel.show()
                        controller.env.panel.model.activate(.snippet(snippet))
                    }
                }
            }
        }
    }

    private func secretItems() -> [NSMenuItem] {
        let secrets = env.secrets.secrets
        guard !secrets.isEmpty else { return [disabled("No Secrets")] }
        return secrets.map { ref in
            item(ref.name, symbol: "key.fill") { [weak self] in
                self?.inTarget { controller in controller.env.pasteSecret(ref, into: controller.target) }
            }
        }
    }

    // MARK: Helpers

    /// Gives focus back to the app that was right-clicked, then runs `work` once it's frontmost.
    private func inTarget(_ work: @escaping (ContextMenuController) -> Void) {
        guard AXPermission.isTrusted else {
            env.showPermissions()
            return
        }
        if let target, !target.isActive { target.activate() }
        // Let the menu finish closing and the target settle before sending keys or clicks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            Log.app.debug("Context menu action for \(self.target?.bundleIdentifier ?? "unknown", privacy: .public)")
            work(self)
        }
    }

    private func keyItem(_ title: String, symbol: String, key: CGKeyCode, flags: CGEventFlags) -> NSMenuItem {
        let menuItem = item(title, symbol: symbol) { [weak self] in
            self?.inTarget { _ in PasteService.postKey(key, flags: flags) }
        }
        if let equivalent = Self.keyEquivalent(for: key) {
            menuItem.keyEquivalent = equivalent
            var mask: NSEvent.ModifierFlags = []
            if flags.contains(.maskCommand) { mask.insert(.command) }
            if flags.contains(.maskShift) { mask.insert(.shift) }
            if flags.contains(.maskAlternate) { mask.insert(.option) }
            if flags.contains(.maskControl) { mask.insert(.control) }
            menuItem.keyEquivalentModifierMask = mask
        }
        return menuItem
    }

    nonisolated private static func keyEquivalent(for key: CGKeyCode) -> String? {
        switch key {
        case 0: "a"
        case 2: "d"
        case 6: "z"
        case 7: "x"
        case 8: "c"
        case 9: "v"
        case 31: "o"
        case 34: "i"
        case 49: " "
        case 51: "\u{8}"
        default: nil
        }
    }

    /// `shortcut` shows that global shortcut's keys next to the title (nothing when it's unassigned).
    private func item(_ title: String, symbol: String, enabled: Bool = true, shortcut: KeyboardShortcuts.Name? = nil,
                      action: @escaping () -> Void) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: #selector(MenuActionTarget.perform(_:)), keyEquivalent: "")
        menuItem.target = MenuActionTarget.shared
        menuItem.representedObject = MenuActionTarget.Handler(action)
        menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menuItem.isEnabled = enabled
        if let shortcut, let keys = KeyboardShortcuts.getShortcut(for: shortcut) {
            menuItem.setShortcut(keys)
            pausedShortcuts.append(shortcut)
        }
        return menuItem
    }

    private func submenuItem(_ title: String, symbol: String, items: [NSMenuItem]) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        items.forEach(submenu.addItem)
        menuItem.submenu = submenu
        return menuItem
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }
}

/// Runs the closure stored in a menu item's `representedObject`.
final class MenuActionTarget: NSObject {
    static let shared = MenuActionTarget()

    final class Handler {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc func perform(_ sender: NSMenuItem) {
        (sender.representedObject as? Handler)?.run()
    }
}

/// C callback for the event tap; it runs on the main run loop (where the source is installed).
nonisolated private func contextMenuTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let rawPointer = userInfo else { return Unmanaged.passUnretained(event) }
    nonisolated(unsafe) let event = event
    nonisolated(unsafe) let pointer = rawPointer
    let swallow = MainActor.assumeIsolated {
        Unmanaged<ContextMenuController>.fromOpaque(pointer).takeUnretainedValue().handle(type: type, event: event)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

extension ContextMenuController: NSMenuDelegate {
    // While the menu tracks, global shortcut presses queue up and would fire after it closes;
    // the menu's own key equivalents handle them instead.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu.supermenu == nil, !pausedShortcuts.isEmpty else { return }
        KeyboardShortcuts.disable(pausedShortcuts)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu.supermenu == nil, !pausedShortcuts.isEmpty else { return }
        KeyboardShortcuts.enable(pausedShortcuts)
    }
}

