import AppKit
import SwiftUI

/// Borderless, non-activating panel: it takes keyboard focus without making Clipboard2 the active
/// app, so the app the user was typing in stays frontmost and receives the paste.
final class QuickPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        setAccessibilityLabel("Clipboard2 Quick Panel")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class QuickPanelController: NSObject, NSWindowDelegate {
    private let env: AppEnvironment
    let model: PanelViewModel
    private var panel: QuickPanel?
    private var keyMonitor: Any?
    private var authObserver: NSObjectProtocol?

    static let cornerRadius: CGFloat = 22

    init(env: AppEnvironment) {
        self.env = env
        self.model = PanelViewModel(env: env)
        super.init()
        model.onClose = { [weak self] in self?.close() }
        // Touch ID takes key focus; take it back afterwards if the panel is still meant to be up.
        authObserver = NotificationCenter.default.addObserver(forName: SecretStore.authenticationEnded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible, !panel.isKeyWindow else { return }
                panel.makeKey()
            }
        }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        let target = env.appTracker.targetApp
        model.prepareForOpen(target: target)
        present(target: target)
    }

    /// Opens straight into the action menu for text selected in `target`.
    func showForSelection(_ text: String, target: NSRunningApplication?) {
        model.prepareForSelection(text, target: target)
        present(target: target)
    }

    private func present(target: NSRunningApplication?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        guard let screen = ScreenLocator.screen(forActiveWindowOf: target?.processIdentifier) else { return }
        let size = env.prefs.panelSize.size
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2 + visible.height * 0.08).rounded()
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animate ? 0 : 1
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        installKeyMonitor()
    }

    func close() {
        removeKeyMonitor()
        model.didClose()
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    #if DEBUG
    func writeSnapshot(to url: URL) {
        guard let container = panel?.contentView else { return }
        let view = hostingView(in: container) ?? container
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func hostingView(in view: NSView) -> NSView? {
        for sub in view.subviews {
            if String(describing: type(of: sub)).hasPrefix("NSHostingView") { return sub }
            if let found = hostingView(in: sub) { return found }
        }
        return nil
    }
    #endif

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // The Touch ID / password sheet steals focus; that isn't the user leaving the panel.
        if env.secrets.isAuthenticating { return }
        close()
    }

    // MARK: Private

    private func makePanel() -> QuickPanel {
        let panel = QuickPanel()
        panel.delegate = self

        let root = QuickPanelView(model: model)
            .environment(env)
            .modelContainer(env.container)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]

        let container: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = hosting
            container = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.cornerRadius
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            hosting.frame = effect.bounds
            effect.addSubview(hosting)
            container = effect
        }
        container.frame = NSRect(origin: .zero, size: panel.frame.size)
        container.autoresizingMask = [.width, .height]
        panel.contentView = container
        return panel
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors are always invoked on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.panel, event.window === window else { return false }
                return self.model.handleKeyDown(event)
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

enum ScreenLocator {
    /// The screen containing the frontmost window of `pid`, falling back to the main screen.
    static func screen(forActiveWindowOf pid: pid_t?) -> NSScreen? {
        let fallback = NSScreen.main ?? NSScreen.screens.first
        guard let pid,
              let primary = NSScreen.screens.first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return fallback }

        for window in info {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 50, bounds.height > 50
            else { continue }
            // CG window coordinates are top-left based on the primary display.
            let center = NSPoint(x: bounds.midX, y: primary.frame.maxY - bounds.midY)
            return NSScreen.screens.first { $0.frame.contains(center) } ?? fallback
        }
        return fallback
    }
}
