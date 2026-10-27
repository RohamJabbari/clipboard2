import Foundation

/// Where sync talks to and the limits it plans around (docs/sync/PROTOCOL.md).
nonisolated enum SyncConfig {
    static let defaultAPIBase = URL(string: "https://clipboard2-api-120641536104.europe-west1.run.app")!

    /// Debug builds can point at a local server: `defaults write <bundle id> syncAPIBase http://localhost:8080`.
    static var apiBase: URL {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "syncAPIBase"), let url = URL(string: override) {
            return url
        }
        #endif
        return defaultAPIBase
    }

    /// Keychain service holding the session token and the unwrapped keys.
    static let keychainService = (Bundle.main.bundleIdentifier ?? "at.softmaze.Clippy") + ".sync"

    static let kdfIterations = 600_000
    /// PBKDF2 iterations a prelogin may ask for; anything else is refused before deriving.
    static let kdfIterationRange = 600_000...10_000_000
    /// Newest history items kept per space, on the server and locally for groups.
    static let historyLimit = 200
    static let maxItemCiphertext = 2 * 1024 * 1024
    static let maxBlobCiphertext = 25 * 1024 * 1024
    /// Files whose contents a single file clip carries.
    static let maxFilesPerItem = 10
    static let changesPageSize = 500
    static let debounce: Duration = .seconds(3)
    /// Polling cadence: while the quick panel is open, while the user was active in the last
    /// `activeWindow` (a copy, paste, panel or menu), and otherwise.
    static let pollWhilePanelOpen: Duration = .seconds(3)
    static let pollWhileActive: Duration = .seconds(15)
    static let pollWhileIdle: Duration = .seconds(60)
    static let activeWindow: TimeInterval = 5 * 60
    /// Synced Files folders without an item are swept once they are this old.
    static let orphanedFilesAge: TimeInterval = 60 * 60
}
