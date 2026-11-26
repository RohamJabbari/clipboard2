import Foundation

nonisolated enum SyncCategory: String, Codable, Sendable, CaseIterable {
    case history, pinned, snippet, secret, folder, otp, origin

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
    /// The id of the Saved folder (a `folder` item) the clip is in; only with `isPinned`.
    var folder: String?
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
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        rev = try c.decodeIfPresent(Int64.self, forKey: .rev)
        toDevice = try c.decodeIfPresent(String.self, forKey: .toDevice)
        fromDevice = try c.decodeIfPresent(String.self, forKey: .fromDevice)
    }

    var category: SyncCategory { isPinned ? .pinned : .history }
    var blobIds: [String] { [imageBlob, thumbBlob].compactMap { $0 } + (fileBlobs ?? []).map(\.blob) }
}

/// One file of a file clip: its name, the blob holding its contents, and its plaintext size.
/// A folder is a zip of its contents, named `<folder>.zip`, with `folder` set (omitted otherwise,
/// so older payloads keep their fingerprints and older apps receive the zip as a file).
nonisolated struct FileBlob: Codable, Equatable, Sendable {
    var name: String
    var blob: String
    var size: Int
    var folder: Bool?

    /// The name to save it under: a folder without its `.zip`.
    var localName: String {
        folder == true && name.lowercased().hasSuffix(".zip") ? String(name.dropLast(4)) : name
    }
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
    /// The id of the Saved folder (a `folder` item) the secret is in, like a clip's.
    var folder: String?
    /// A password's username (1.11+). Omitted when empty, so plain secrets keep their fingerprints.
    var username: String?
    /// A password's sites (1.11+). Omitted when empty.
    var urls: [String]?
    /// A password's notes (1.11+). Omitted when empty.
    var notes: String?
    /// The origin (Auth's site edited by hand, an `origin` item) it's filed under (1.13+). Omitted
    /// when unset: then it's grouped by its sites.
    var origin: String?
    var rev: Int64?

    init(name: String, value: String, createdAt: Int64, folder: String? = nil, username: String? = nil,
         urls: [String]? = nil, notes: String? = nil, origin: String? = nil) {
        self.name = name
        self.value = value
        self.createdAt = createdAt
        self.folder = folder
        self.username = SecretExtras.cleanUsername(username)
        let sites = SecretExtras.cleanURLs(urls ?? [])
        self.urls = sites.isEmpty ? nil : sites
        self.notes = notes?.isEmpty == true ? nil : notes
        self.origin = origin?.isEmpty == true ? nil : origin?.lowercased()
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "secret"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        username = try? c.decodeIfPresent(String.self, forKey: .username)
        urls = try? c.decodeIfPresent([String].self, forKey: .urls)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        origin = try? c.decodeIfPresent(String.self, forKey: .origin)
        rev = try c.decodeIfPresent(Int64.self, forKey: .rev)
    }
}

/// `type: "folder"`: a Saved folder. Its clips point at it with their `folder` field.
nonisolated struct FolderPayload: Codable, Equatable, Sendable {
    var v = 1
    var type = "folder"
    var name: String
    var label: String?
    /// The folder item it's in (1.8+); omitted at the top level, so older folders keep their
    /// fingerprints.
    var parent: String?
    var createdAt: Int64
    var updatedAt: Int64
    var rev: Int64?

    init(name: String, label: String? = nil, parent: String? = nil, createdAt: Int64, updatedAt: Int64) {
        self.name = name
        self.label = label
        self.parent = parent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "folder"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Folder"
        label = try c.decodeIfPresent(String.self, forKey: .label)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? createdAt
        rev = try c.decodeIfPresent(Int64.self, forKey: .rev)
    }
}

/// `type: "otp"`: an authenticator's seed and settings. Only in authenticator spaces, so only the
/// owner's devices ever read it.
nonisolated struct OTPPayload: Codable, Equatable, Sendable {
    var v = 1
    var type = "otp"
    var issuer: String
    var account: String
    /// Base32, no padding.
    var secret: String
    var algorithm: String
    var digits: Int
    var period: Int
    var createdAt: Int64
    var updatedAt: Int64
    /// The sites the user set (Edit → Website, 1.11+). Omitted when empty.
    var urls: [String]?
    /// The origin it's filed under (1.13+), like a secret's. Omitted when unset.
    var origin: String?
    var rev: Int64?

    init(issuer: String, account: String, secret: String, algorithm: String, digits: Int, period: Int,
         createdAt: Int64, updatedAt: Int64, urls: [String]? = nil, origin: String? = nil) {
        let sites = SecretExtras.cleanURLs(urls ?? [])
        self.urls = sites.isEmpty ? nil : sites
        self.origin = origin?.isEmpty == true ? nil : origin?.lowercased()
        self.issuer = issuer
        self.account = account
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "otp"
        issuer = try c.decodeIfPresent(String.self, forKey: .issuer) ?? ""
        account = try c.decodeIfPresent(String.self, forKey: .account) ?? ""
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ""
        algorithm = try c.decodeIfPresent(String.self, forKey: .algorithm) ?? "SHA1"
        digits = try c.decodeIfPresent(Int.self, forKey: .digits) ?? 6
        period = try c.decodeIfPresent(Int.self, forKey: .period) ?? 30
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? createdAt
        urls = try? c.decodeIfPresent([String].self, forKey: .urls)
        origin = try? c.decodeIfPresent(String.self, forKey: .origin)
        rev = try c.decodeIfPresent(Int64.self, forKey: .rev)
    }
}

/// `type: "origin"` (1.13+): a site in Auth edited by hand. Only in the personal space. Its
/// documents are blobs of the item, each document's `id` being its blob id.
nonisolated struct OriginPayload: Codable, Equatable, Sendable {
    nonisolated struct Note: Codable, Equatable, Hashable, Sendable {
        var id: String
        var text: String
        var createdAt: Int64
        var updatedAt: Int64
    }

    nonisolated struct Document: Codable, Equatable, Hashable, Sendable {
        /// Also its blob's id.
        var id: String
        var name: String
        /// Plaintext bytes.
        var size: Int64
        var addedAt: Int64
    }

    var v = 1
    var type = "origin"
    var name: String
    /// Its sites (hosts or URLs as typed); every registrable domain among them is the origin's.
    var domains: [String]?
    /// `favicon:<domain>`, `letter`, `symbol:<SF Symbol>` or `emoji:<text>`; omitted: the first domain's favicon.
    var icon: String?
    var notes: [Note]?
    var documents: [Document]?
    /// Entries filed here that can't carry an `origin` of their own: `shared:<authenticator space id>`
    /// and `secret:<id>` for someone else's secret in a group.
    var entries: [String]?
    var createdAt: Int64
    var updatedAt: Int64
    var rev: Int64?

    init(name: String, domains: [String] = [], icon: String? = nil, notes: [Note] = [], documents: [Document] = [],
         entries: [String] = [], createdAt: Int64, updatedAt: Int64) {
        self.name = name
        let sites = SecretExtras.cleanURLs(domains)
        self.domains = sites.isEmpty ? nil : sites
        self.icon = icon?.isEmpty == true ? nil : icon
        self.notes = notes.isEmpty ? nil : notes
        self.documents = documents.isEmpty ? nil : documents
        self.entries = entries.isEmpty ? nil : entries
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "origin"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        domains = try? c.decodeIfPresent([String].self, forKey: .domains)
        icon = try? c.decodeIfPresent(String.self, forKey: .icon)
        notes = try? c.decodeIfPresent([Note].self, forKey: .notes)
        documents = try? c.decodeIfPresent([Document].self, forKey: .documents)
        entries = try? c.decodeIfPresent([String].self, forKey: .entries)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? createdAt
        rev = try c.decodeIfPresent(Int64.self, forKey: .rev)
    }

    /// The documents' blob ids, in order.
    var blobIds: [String] { (documents ?? []).map(\.id) }
}

nonisolated enum SyncPayloadError: Error, Equatable {
    case unknownType(String)
}

nonisolated enum SyncPayload: Equatable, Sendable {
    case clip(ClipPayload)
    case snippet(SnippetPayload)
    case secret(SecretPayload)
    case folder(FolderPayload)
    case otp(OTPPayload)
    case origin(OriginPayload)

    nonisolated private struct TypeProbe: Decodable { var type: String? }

    static func decode(_ data: Data) throws -> SyncPayload {
        let decoder = JSONDecoder()
        switch try decoder.decode(TypeProbe.self, from: data).type {
        case "clip": return .clip(try decoder.decode(ClipPayload.self, from: data))
        case "snippet": return .snippet(try decoder.decode(SnippetPayload.self, from: data))
        case "secret": return .secret(try decoder.decode(SecretPayload.self, from: data))
        case "folder": return .folder(try decoder.decode(FolderPayload.self, from: data))
        case "otp": return .otp(try decoder.decode(OTPPayload.self, from: data))
        case "origin": return .origin(try decoder.decode(OriginPayload.self, from: data))
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
        case .folder(let p): return try encoder.encode(p)
        case .otp(let p): return try encoder.encode(p)
        case .origin(let p): return try encoder.encode(p)
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
        case .folder(var p):
            p.rev = nil
            return .folder(p)
        case .otp(var p):
            p.rev = nil
            return .otp(p)
        case .origin(var p):
            p.rev = nil
            return .origin(p)
        }
    }

    var rev: Int64? {
        switch self {
        case .clip(let p): p.rev
        case .snippet(let p): p.rev
        case .secret(let p): p.rev
        case .folder(let p): p.rev
        case .otp(let p): p.rev
        case .origin(let p): p.rev
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
        case .folder(var p):
            p.rev = rev
            return .folder(p)
        case .otp(var p):
            p.rev = rev
            return .otp(p)
        case .origin(var p):
            p.rev = rev
            return .origin(p)
        }
    }

    var category: SyncCategory {
        switch self {
        case .clip(let p): p.category
        case .snippet: .snippet
        case .secret: .secret
        case .folder: .folder
        case .otp: .otp
        case .origin: .origin
        }
    }
}
