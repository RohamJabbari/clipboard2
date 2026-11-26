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

    /// Text written out for Quick Look, one folder per item; cleared whenever Quick Look closes.
    static var quickLookDirectory: URL {
        FileManager.default.temporaryDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "at.softmaze.Clippy", directoryHint: .isDirectory)
            .appending(path: "Quick Look", directoryHint: .isDirectory)
    }

    static func syncedFilesFolder(for itemID: UUID) -> URL {
        syncedFilesDirectory.appending(path: itemID.uuidString.lowercased(), directoryHint: .isDirectory)
    }
}
