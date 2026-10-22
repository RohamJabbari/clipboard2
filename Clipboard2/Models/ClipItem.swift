import Foundation
import SwiftData

nonisolated enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text
    case richText
    case image
    case file

    var displayName: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich Text"
        case .image: "Image"
        case .file: "File"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .image: "photo"
        case .file: "doc"
        }
    }

    var isTextual: Bool { self == .text || self == .richText }
}

@Model
final class ClipItem {
    var id: UUID = UUID()
    var createdAt: Date = Date.now
    /// Sort key: bumped whenever the same content is copied again or pasted from Clipboard2.
    var lastCopiedAt: Date = Date.now
    var kindRaw: String = ClipKind.text.rawValue
    /// Plain text. For files: newline-separated paths. Empty for images.
    var text: String = ""
    /// Short single-line excerpt for list rows.
    var preview: String = ""
    @Attribute(.externalStorage) var rtfData: Data?
    @Attribute(.externalStorage) var htmlData: Data?
    var contentHash: String = ""
    var fileURLStrings: [String] = []
    /// File names inside the blob directory (never absolute paths).
    var imageFile: String?
    var thumbnailFile: String?
    var imageWidth: Int = 0
    var imageHeight: Int = 0
    var byteCount: Int = 0
    var sourceBundleID: String?
    var sourceAppName: String?
    var isPinned: Bool = false
    /// User-chosen name for pinned items ("Prod DB host"); the content stays in `text`.
    var label: String?
    var pinnedAt: Date?
    var copyCount: Int = 1
    /// The sync group this item belongs to; nil is the personal space (also when not signed in).
    var spaceID: String?

    init(capture: ProcessedCapture, now: Date = .now) {
        id = UUID()
        createdAt = now
        lastCopiedAt = now
        kindRaw = capture.kind.rawValue
        text = capture.text
        preview = capture.preview
        rtfData = capture.rtfData
        htmlData = capture.htmlData
        contentHash = capture.hash
        fileURLStrings = capture.fileURLs.map(\.absoluteString)
        imageFile = capture.imageFile
        thumbnailFile = capture.thumbnailFile
        imageWidth = capture.imageWidth
        imageHeight = capture.imageHeight
        byteCount = capture.byteCount
        sourceBundleID = capture.source?.bundleID
        sourceAppName = capture.source?.name
    }

    var kind: ClipKind {
        get { ClipKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }

    var fileURLs: [URL] { fileURLStrings.compactMap { URL(string: $0) } }

    var source: AppRef? {
        guard let sourceBundleID else { return nil }
        return AppRef(bundleID: sourceBundleID, name: sourceAppName ?? sourceBundleID)
    }

    /// True for text selected in another app that hasn't been saved to history.
    var isTransient: Bool { modelContext == nil }

    /// Row title: the label if there is one, otherwise the content excerpt.
    var displayTitle: String {
        if let label, !label.isEmpty { return label }
        return preview.isEmpty ? kind.displayName : preview
    }

    /// Text used for searching.
    var searchableText: String {
        (label.map { $0 + " " } ?? "") + contentSearchText
    }

    private var contentSearchText: String {
        switch kind {
        case .image: "Image \(imageWidth)×\(imageHeight)"
        case .file: fileURLs.map(\.lastPathComponent).joined(separator: " ") + " " + text
        default: text
        }
    }

    /// When this item will be removed by the age limit, or nil if it never expires.
    func expiryDate(maxAge: TimeInterval?) -> Date? {
        guard !isPinned, let maxAge else { return nil }
        return lastCopiedAt.addingTimeInterval(maxAge)
    }

    var accessibilityDescription: String {
        let app = sourceAppName.map { ", from \($0)" } ?? ""
        let pin = isPinned ? ", pinned" : ""
        let name = label.map { "\($0), " } ?? ""
        return "\(name)\(kind.displayName): \(preview)\(app)\(pin)"
    }
}

@Model
final class Snippet {
    var id: UUID = UUID()
    var name: String = ""
    var keyword: String = ""
    var body: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    /// The sync group this snippet belongs to; nil is the personal space.
    var spaceID: String?

    init(name: String, keyword: String = "", body: String = "") {
        self.id = UUID()
        self.name = name
        self.keyword = keyword
        self.body = body
        self.createdAt = .now
        self.updatedAt = .now
    }
}
