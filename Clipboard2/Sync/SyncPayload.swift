import Foundation

nonisolated enum SyncCategory: String, Codable, Sendable, CaseIterable {
    case history, pinned, snippet, secret

    var isClip: Bool { self == .history || self == .pinned }
}

nonisolated extension Date {
    /// Unix milliseconds, the protocol's time format.
    var syncMillis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    init(syncMillis: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(syncMillis) / 1000)
    }
}

// MARK: - Payloads (the plaintext inside an item)

/// `type: "clip"`. Writers omit nulls; readers ignore unknown fields and tolerate missing ones.
nonisolated struct ClipPayload: Codable, Equatable, Sendable {
    var v = 1
    var type = "clip"
    var kind: String
    var text: String?
    var preview: String?
    var rtf: Data?
    var html: Data?
    var files: [String]?
    /// File contents for `kind: "file"`, in upload order; files too large or not regular aren't listed.
    var fileBlobs: [FileBlob]?
    var imageBlob: String?
    var thumbBlob: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var byteCount: Int?
    var sourceId: String?
    var sourceName: String?
    var isPinned: Bool
    var pinnedAt: Int64?
    var label: String?
    var copyCount: Int
    var createdAt: Int64
    var lastCopiedAt: Int64
    var contentHash: String
    /// The `updatedAt` the writer sent with this version (rollback protection); nil from older apps.
    var rev: Int64?
    /// A session id from `/v1/sessions`: that device shows "Sent from ‹fromDevice›" and puts the
    /// item at the top. Everyone else treats it as a normal item.
    var toDevice: String?
    /// The sending device's name, for that notice (an extension; readers ignore unknown fields).
    var fromDevice: String?

    init(kind: String, text: String? = nil, preview: String? = nil, isPinned: Bool = false, copyCount: Int = 1,
         createdAt: Int64, lastCopiedAt: Int64, contentHash: String) {
        self.kind = kind
        self.text = text
        self.preview = preview
        self.isPinned = isPinned
        self.copyCount = copyCount
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.contentHash = contentHash
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "clip"
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ClipKind.text.rawValue
        text = try c.decodeIfPresent(String.self, forKey: .text)
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        rtf = try c.decodeIfPresent(Data.self, forKey: .rtf)
        html = try c.decodeIfPresent(Data.self, forKey: .html)
        files = try c.decodeIfPresent([String].self, forKey: .files)
        fileBlobs = try c.decodeIfPresent([FileBlob].self, forKey: .fileBlobs)
        imageBlob = try c.decodeIfPresent(String.self, forKey: .imageBlob)
        thumbBlob = try c.decodeIfPresent(String.self, forKey: .thumbBlob)
        imageWidth = try c.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try c.decodeIfPresent(Int.self, forKey: .imageHeight)
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount)
        sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        pinnedAt = try c.decodeIfPresent(Int64.self, forKey: .pinnedAt)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        copyCount = try c.decodeIfPresent(Int.self, forKey: .copyCount) ?? 1
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        lastCopiedAt = try c.decodeIfPresent(Int64.self, forKey: .lastCopiedAt) ?? createdAt
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash) ?? ""
        rev = try c.decodeIfPresent(Int64.self, forKey: .rev)
        toDevice = try c.decodeIfPresent(String.self, forKey: .toDevice)
        fromDevice = try c.decodeIfPresent(String.self, forKey: .fromDevice)
    }

    var category: SyncCategory { isPinned ? .pinned : .history }
    var blobIds: [String] { [imageBlob, thumbBlob].compactMap { $0 } + (fileBlobs ?? []).map(\.blob) }
}

/// One file of a file clip: its name, the blob holding its contents, and its plaintext size.
nonisolated struct FileBlob: Codable, Equatable, Sendable {
    var name: String
    var blob: String
    var size: Int
}

/// `type: "snippet"`.
nonisolated struct SnippetPayload: Codable, Equatable, Sendable {
    var v = 1
    var type = "snippet"
    var name: String
    var keyword: String
    var body: String
    var createdAt: Int64
    var updatedAt: Int64
    var rev: Int64?

    init(name: String, keyword: String, body: String, createdAt: Int64, updatedAt: Int64) {
        self.name = name
        self.keyword = keyword
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "snippet"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        keyword = try c.decodeIfPresent(String.self, forKey: .keyword) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? createdAt
        rev = try c.decodeIfPresent(Int64.self, forKey: .rev)
    }
}

/// `type: "secret"`.
nonisolated struct SecretPayload: Codable, Equatable, Sendable {
    var v = 1
    var type = "secret"
    var name: String
    var value: String
    var createdAt: Int64
    var rev: Int64?

    init(name: String, value: String, createdAt: Int64) {
        self.name = name
        self.value = value
        self.createdAt = createdAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "secret"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        rev = try c.decodeIfPresent(Int64.self, forKey: .rev)
    }
}

nonisolated enum SyncPayloadError: Error, Equatable {
    case unknownType(String)
}

nonisolated enum SyncPayload: Equatable, Sendable {
    case clip(ClipPayload)
    case snippet(SnippetPayload)
    case secret(SecretPayload)

    nonisolated private struct TypeProbe: Decodable { var type: String? }

    static func decode(_ data: Data) throws -> SyncPayload {
        let decoder = JSONDecoder()
        switch try decoder.decode(TypeProbe.self, from: data).type {
        case "clip": return .clip(try decoder.decode(ClipPayload.self, from: data))
        case "snippet": return .snippet(try decoder.decode(SnippetPayload.self, from: data))
        case "secret": return .secret(try decoder.decode(SecretPayload.self, from: data))
        case let other: throw SyncPayloadError.unknownType(other ?? "nil")
        }
    }

    /// Canonical JSON: sorted keys, no escaped slashes, nulls omitted. Sent as the item plaintext
    /// and hashed for the fingerprint, so equal payloads always produce equal bytes.
    func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch self {
        case .clip(let p): return try encoder.encode(p)
        case .snippet(let p): return try encoder.encode(p)
        case .secret(let p): return try encoder.encode(p)
        }
    }

    /// SHA-256 of the canonical JSON without the per-write fields (`rev`, `toDevice`,
    /// `fromDevice`), so it only changes when the content does.
    func fingerprint() throws -> String {
        SyncCrypto.sha256Hex(try content.canonicalJSON())
    }

    /// The payload without the per-write fields.
    var content: SyncPayload {
        switch self {
        case .clip(var p):
            p.rev = nil
            p.toDevice = nil
            p.fromDevice = nil
            return .clip(p)
        case .snippet(var p):
            p.rev = nil
            return .snippet(p)
        case .secret(var p):
            p.rev = nil
            return .secret(p)
        }
    }

    var rev: Int64? {
        switch self {
        case .clip(let p): p.rev
        case .snippet(let p): p.rev
        case .secret(let p): p.rev
        }
    }

    /// The payload as written with this `updatedAt`.
    func withRev(_ rev: Int64) -> SyncPayload {
        switch self {
        case .clip(var p):
            p.rev = rev
            return .clip(p)
        case .snippet(var p):
            p.rev = rev
            return .snippet(p)
        case .secret(var p):
            p.rev = rev
            return .secret(p)
        }
    }

    var category: SyncCategory {
        switch self {
        case .clip(let p): p.category
        case .snippet: .snippet
        case .secret: .secret
        }
    }
}

// MARK: - Mapping to and from the local models

extension ClipPayload {
    /// The payload for a local item. `blobs` are the server ids of its image and thumbnail, or of its files.
    init(item: ClipItem, imageBlob: String? = nil, thumbBlob: String? = nil, fileBlobs: [FileBlob] = []) {
        self.init(kind: item.kind.rawValue, text: item.text, preview: item.preview, isPinned: item.isPinned,
                  copyCount: item.copyCount, createdAt: item.createdAt.syncMillis,
                  lastCopiedAt: item.lastCopiedAt.syncMillis, contentHash: item.contentHash)
        rtf = item.rtfData
        html = item.htmlData
        files = item.fileURLStrings.isEmpty ? nil : item.fileURLStrings
        if item.kind == .file && !fileBlobs.isEmpty { self.fileBlobs = fileBlobs }
        if item.kind == .image {
            self.imageBlob = imageBlob
            self.thumbBlob = thumbBlob
            imageWidth = item.imageWidth
            imageHeight = item.imageHeight
        }
        byteCount = item.byteCount > 0 ? item.byteCount : nil
        sourceId = item.sourceBundleID
        sourceName = item.sourceAppName
        pinnedAt = item.isPinned ? item.pinnedAt?.syncMillis : nil
        label = item.label
    }

    /// Without rich text, for items whose RTF/HTML would push the ciphertext past the limit.
    var withoutRichText: ClipPayload {
        var copy = self
        copy.rtf = nil
        copy.html = nil
        if copy.kind == ClipKind.richText.rawValue { copy.kind = ClipKind.text.rawValue }
        return copy
    }

    /// Writes the payload into a local item. Image files are set by the caller. A file clip stays a
    /// file clip when its contents arrived (`localFiles`); otherwise it arrives as the names, as text.
    /// Times are clamped to `arrivedAt`, so an item can't claim to come from the future.
    func apply(to item: ClipItem, localFiles: [URL] = [], arrivedAt: Date = .now) {
        var kind = ClipKind(rawValue: self.kind) ?? .text
        item.text = text ?? ""
        item.preview = preview ?? TextPreview.make(item.text)
        item.contentHash = contentHash
        item.fileURLStrings = []
        if kind == .file && !localFiles.isEmpty {
            item.fileURLStrings = localFiles.map(\.absoluteString)
            item.text = localFiles.map(\.path).joined(separator: "\n")
            if preview == nil { item.preview = TextPreview.make(localFiles.map(\.lastPathComponent).joined(separator: ", ")) }
        } else if kind == .file {
            kind = .text
            if item.text.isEmpty { item.text = (files ?? []).compactMap { URL(string: $0)?.path }.joined(separator: "\n") }
            if item.preview.isEmpty { item.preview = TextPreview.make(item.text) }
            item.contentHash = ContentHasher.hash(text: item.text)
        }
        if kind == .image && imageBlob == nil { kind = .text }
        item.kind = kind
        item.rtfData = kind == .richText ? rtf : nil
        item.htmlData = kind == .richText ? html : nil
        item.imageWidth = imageWidth ?? 0
        item.imageHeight = imageHeight ?? 0
        item.byteCount = byteCount ?? item.text.utf8.count
        item.sourceBundleID = sourceId
        item.sourceAppName = sourceName
        item.isPinned = isPinned
        item.pinnedAt = isPinned ? pinnedAt.map(Date.init(syncMillis:)) ?? item.pinnedAt ?? .now : nil
        item.label = label
        item.copyCount = max(1, copyCount)
        let arrived = arrivedAt.syncMillis
        item.createdAt = Date(syncMillis: min(createdAt, arrived))
        item.lastCopiedAt = Date(syncMillis: min(lastCopiedAt, arrived))
    }
}

extension SnippetPayload {
    init(snippet: Snippet) {
        self.init(name: snippet.name, keyword: snippet.keyword, body: snippet.body,
                  createdAt: snippet.createdAt.syncMillis, updatedAt: snippet.updatedAt.syncMillis)
    }

    func apply(to snippet: Snippet, arrivedAt: Date = .now) {
        let arrived = arrivedAt.syncMillis
        snippet.name = name
        snippet.keyword = keyword
        snippet.body = body
        snippet.createdAt = Date(syncMillis: min(createdAt, arrived))
        snippet.updatedAt = Date(syncMillis: min(updatedAt, arrived))
    }
}

extension ClipItem {
    /// An empty item with a given id, filled in from a sync payload.
    convenience init(syncID: UUID, spaceID: String?) {
        self.init(capture: .text(""))
        id = syncID
        self.spaceID = spaceID
    }
}

extension Snippet {
    convenience init(syncID: UUID, spaceID: String?) {
        self.init(name: "")
        id = syncID
        self.spaceID = spaceID
    }
}
