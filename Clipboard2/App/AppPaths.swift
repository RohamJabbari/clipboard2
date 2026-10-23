import Foundation
import OSLog

nonisolated enum AppPaths {
    /// `~/Library/Application Support/<bundle id>/` — separate per build flavour so
    /// Debug runs never touch the installed app's history.
    static let supportDirectory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let dir = base.appending(path: Bundle.main.bundleIdentifier ?? "at.softmaze.Clippy", directoryHint: .isDirectory)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var storeURL: URL { supportDirectory.appending(path: "Clipboard2.store") }
    static var blobsDirectory: URL { supportDirectory.appending(path: "Blobs", directoryHint: .isDirectory) }
    /// Files received through sync, one folder per item: `Synced Files/<item id>/<name>`.
    static var syncedFilesDirectory: URL { supportDirectory.appending(path: "Synced Files", directoryHint: .isDirectory) }

    static func syncedFilesFolder(for itemID: UUID) -> URL {
        syncedFilesDirectory.appending(path: itemID.uuidString.lowercased(), directoryHint: .isDirectory)
    }
}

nonisolated enum Log {
    private static let subsystem = "at.softmaze.Clippy"
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let paste = Logger(subsystem: subsystem, category: "paste")
    static let claude = Logger(subsystem: subsystem, category: "claude")
    static let app = Logger(subsystem: subsystem, category: "app")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let panel = Logger(subsystem: subsystem, category: "panel")
    static let updates = Logger(subsystem: subsystem, category: "updates")
}
