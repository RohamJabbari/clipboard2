import Foundation

/// Where sync talks to and the limits it plans around (docs/sync/PROTOCOL.md).
nonisolated enum SyncConfig {
    /// The self-hosted API on the origin server (branch origin-server). Tailnet only.
    static let defaultAPIBase = URL(string: "https://origin.tail9bf9d6.ts.net/clipboard2")!

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
    static let maxBlobCiphertext = 100 * 1024 * 1024
    /// Files whose contents a single file clip carries.
    static let maxFilesPerItem = 10
    static let changesPageSize = 500
    static let debounce: Duration = .seconds(3)
    /// Polling `GET /v1/heads` (PROTOCOL.md → Heads): while the quick panel is open or the user
    /// was active in the last `activeWindow` (a copy, paste, panel or menu), and otherwise. A full
    /// sync runs only when heads moved, or after `fullSyncInterval` regardless.
    static let headsWhileActive: Duration = .seconds(2)
    static let headsWhileIdle: Duration = .seconds(10)
    /// A server that can wait (heads carry `rev`) holds each poll open until something changes, up
    /// to this long, and the next poll starts right after, so changes arrive as they're written.
    /// Well under the request timeout, and under the server's own cap it is clamped to.
    static let headsWaitSeconds = 25
    /// Never poll more often than this, even when waits answer at once (a tick is running).
    static let headsMinGap: Duration = .seconds(1)
    /// After failed polls the wait doubles from 2 s up to this.
    static let headsMaxBackoff: Duration = .seconds(60)
    static let fullSyncInterval: TimeInterval = 5 * 60
    /// A server without heads (`404`) is asked again after this.
    static let headsRetryInterval: TimeInterval = 60 * 60
    /// Without heads (an older server) every poll is a full sync, at this cadence instead.
    static let pollWhilePanelOpen: Duration = .seconds(3)
    static let pollWhileActive: Duration = .seconds(15)
    static let pollWhileIdle: Duration = .seconds(60)
    static let activeWindow: TimeInterval = 5 * 60
    /// How often a sync also looks for new contact requests.
    static let contactsRefreshInterval: TimeInterval = 60
    /// Synced Files folders without an item are swept once they are this old.
    static let orphanedFilesAge: TimeInterval = 60 * 60
}
