import Foundation
import OSLog

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
