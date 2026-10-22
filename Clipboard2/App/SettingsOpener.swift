import SwiftUI

/// Settings tabs that can be opened directly (stored, so the window remembers the last one).
enum SettingsTab: String {
    case general, appearance, ignoredApps, snippets, secrets, transforms, ai, permissions, sync, about

    static let storageKey = "settingsTab"
}

/// SwiftUI only exposes `openSettings` through the environment. The menu bar label lives for the
/// whole app lifetime, so it registers the action here and AppKit code can call `open()`.
enum SettingsOpener {
    private static var action: OpenSettingsAction?

    static func register(_ action: OpenSettingsAction) {
        self.action = action
    }

    static func open(tab: SettingsTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.storageKey) }
        NSApp.activate()
        action?()
        // Accessory apps sometimes open Settings behind the frontmost app; nudge it forward.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate()
            NSApp.windows
                .first { $0.identifier?.rawValue.contains("Settings") == true && $0.isVisible }?
                .makeKeyAndOrderFront(nil)
        }
    }
}
