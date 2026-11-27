import Foundation

nonisolated struct AppRef: Codable, Hashable, Identifiable, Sendable {
    var bundleID: String
    var name: String
    var id: String { bundleID }

    static let defaultIgnored: [AppRef] = [
        AppRef(bundleID: "com.1password.1password", name: "1Password"),
        AppRef(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
        AppRef(bundleID: "com.bitwarden.desktop", name: "Bitwarden"),
        AppRef(bundleID: "com.apple.keychainaccess", name: "Keychain Access"),
        AppRef(bundleID: "com.apple.Passwords", name: "Passwords"),
    ]
}

/// What we read synchronously off the pasteboard on the main thread.
nonisolated struct RawCapture: Sendable {
    var kind: ClipKind
    var text: String = ""
    var rtfData: Data?
    var htmlData: Data?
    var fileURLs: [URL] = []
    var imageData: Data?
    var source: AppRef?
}

/// A capture after off-main processing (hashing, PNG/thumbnail encoding, blob writes).
nonisolated struct ProcessedCapture: Sendable {
    var kind: ClipKind
    var text: String
    var preview: String
    var rtfData: Data?
    var htmlData: Data?
    var fileURLs: [URL]
    var source: AppRef?
    var hash: String
    var imageFile: String?
    var thumbnailFile: String?
    var imageWidth: Int = 0
    var imageHeight: Int = 0
    var byteCount: Int = 0

    /// Convenience for text captures (used by tests and "Replace item").
    static func text(_ text: String, rtf: Data? = nil, source: AppRef? = nil) -> ProcessedCapture {
        ProcessedCapture(
            kind: rtf == nil ? .text : .richText,
            text: text,
            preview: TextPreview.make(text),
            rtfData: rtf,
            htmlData: nil,
            fileURLs: [],
            source: source,
            hash: ContentHasher.hash(text: text),
            byteCount: text.utf8.count
        )
    }
}
