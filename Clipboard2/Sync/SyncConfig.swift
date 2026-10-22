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
    /// Newest history items kept per space, on the server and locally for groups.
    static let historyLimit = 200
    static let maxItemCiphertext = 2 * 1024 * 1024
    static let maxBlobCiphertext = 25 * 1024 * 1024
    /// Files whose contents a single file clip carries.
    static let maxFilesPerItem = 10
    static let changesPageSize = 500
    static let debounce: Duration = .seconds(3)
}
