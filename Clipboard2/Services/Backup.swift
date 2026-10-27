import Foundation
import CryptoKit
import CommonCrypto

// Encrypted export and import of history, pinned items, snippets and (optionally) secrets.
// The file format is shared with the Windows app: docs/BACKUP-FORMAT.md.

nonisolated enum BackupError: LocalizedError, Equatable {
    case notABackup
    case newerVersion
    case unsupportedIterations
    case wrongPassphraseOrDamaged
    case emptyPassphrase
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .notABackup: "This isn't a Clipboard2 backup."
        case .newerVersion: "This backup was made by a newer version of Clipboard2. Update Clipboard2 and try again."
        case .unsupportedIterations: "This backup uses settings Clipboard2 doesn't accept, so it wasn't opened."
        case .wrongPassphraseOrDamaged: "The passphrase is wrong, or the file is damaged."
        case .emptyPassphrase: "Enter the backup's passphrase."
        case .keyDerivationFailed: "Couldn't derive the encryption key."
        }
    }
}

// MARK: - Encryption

/// `"C2BK" | 0x01 | salt(16) | iterations(u32 BE) | nonce(12)` (37 bytes, the AAD), then the
/// AES-256-GCM ciphertext and its 16-byte tag. Key = PBKDF2-SHA256(NFC passphrase, salt, iterations).
nonisolated enum BackupCrypto {
    static let magic = Data("C2BK".utf8)
    static let version: UInt8 = 1
    static let saltLength = 16
    static let nonceLength = 12
    static let tagLength = 16
    static let headerLength = 4 + 1 + 16 + 4 + 12
    static let iterations: UInt32 = 600_000
    /// Readers refuse anything weaker than what we write, and absurd values (a slow-down attack).
    static let acceptedIterations: ClosedRange<UInt32> = 600_000...10_000_000

    static func header(salt: Data, iterations: UInt32, nonce: Data) -> Data {
        var header = magic
        header.append(version)
        header.append(salt)
        withUnsafeBytes(of: iterations.bigEndian) { header.append(contentsOf: $0) }
        header.append(nonce)
        return header
    }

    static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        let password = Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var output = Data(count: 32)
        let status = output.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { pw in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), 32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw BackupError.keyDerivationFailed }
        return SymmetricKey(data: output)
    }

    static func seal(_ plaintext: Data, passphrase: String, salt: Data? = nil, nonce: Data? = nil) throws -> Data {
        guard !passphrase.isEmpty else { throw BackupError.emptyPassphrase }
        let salt = salt ?? randomBytes(saltLength)
        let nonce = nonce ?? randomBytes(nonceLength)
        let header = header(salt: salt, iterations: iterations, nonce: nonce)
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: header)
        return header + box.ciphertext + box.tag
    }

    static func open(_ file: Data, passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else { throw BackupError.emptyPassphrase }
        let bytes = Data(file)   // re-base indices at 0
        guard bytes.count >= headerLength + tagLength, bytes.prefix(4) == magic else { throw BackupError.notABackup }
        guard bytes[4] == version else { throw bytes[4] > version ? BackupError.newerVersion : BackupError.notABackup }
        let salt = bytes.subdata(in: 5..<21)
        let iterations = bytes.subdata(in: 21..<25).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let nonce = bytes.subdata(in: 25..<37)
        guard acceptedIterations.contains(iterations) else { throw BackupError.unsupportedIterations }
        let header = bytes.subdata(in: 0..<headerLength)
        let body = bytes.subdata(in: headerLength..<bytes.count)
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                            ciphertext: body.dropLast(tagLength), tag: body.suffix(tagLength))
            return try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw BackupError.wrongPassphraseOrDamaged
        }
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return data
    }
}

// MARK: - Document

/// The decrypted JSON. Readers ignore unknown fields and tolerate missing ones.
nonisolated struct BackupDocument: Codable, Equatable, Sendable {
    static let formatName = "clipboard2-backup"

    var format = BackupDocument.formatName
    var version = 1
    var createdAt: Int64
    var app = "mac"
    var clips: [BackupClip] = []
    var snippets: [BackupSnippet] = []
    /// Omitted unless the user chose to include secrets.
    var secrets: [BackupSecret]?

    init(createdAt: Int64, clips: [BackupClip], snippets: [BackupSnippet], secrets: [BackupSecret]?) {
        self.createdAt = createdAt
        self.clips = clips
        self.snippets = snippets
        self.secrets = secrets
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        clips = try c.decodeIfPresent([BackupClip].self, forKey: .clips) ?? []
        snippets = try c.decodeIfPresent([BackupSnippet].self, forKey: .snippets) ?? []
        secrets = try c.decodeIfPresent([BackupSecret].self, forKey: .secrets)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> BackupDocument {
        let document: BackupDocument
        do {
            document = try JSONDecoder().decode(BackupDocument.self, from: data)
        } catch {
            throw BackupError.notABackup
        }
        guard document.format == formatName else { throw BackupError.notABackup }
        guard document.version <= 1 else { throw BackupError.newerVersion }
        return document
    }
}

/// A ClipPayload (PROTOCOL.md) plus `id`, the image and thumbnail as base64 PNG, and `files` as
/// their URLs only (never the files' contents). Blob ids aren't written.
nonisolated struct BackupClip: Codable, Equatable, Sendable {
    var v = 1
    var type = "clip"
    var id: String
    var kind: String
    var text: String?
    var preview: String?
    var rtf: Data?
    var html: Data?
    var files: [String]?
    var image: Data?
    var thumb: Data?
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

    init(id: String, kind: String, isPinned: Bool = false, copyCount: Int = 1, createdAt: Int64,
         lastCopiedAt: Int64, contentHash: String) {
        self.id = id
        self.kind = kind
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
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ClipKind.text.rawValue
        text = try c.decodeIfPresent(String.self, forKey: .text)
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        rtf = try c.decodeIfPresent(Data.self, forKey: .rtf)
        html = try c.decodeIfPresent(Data.self, forKey: .html)
        files = try c.decodeIfPresent([String].self, forKey: .files)
        image = try c.decodeIfPresent(Data.self, forKey: .image)
        thumb = try c.decodeIfPresent(Data.self, forKey: .thumb)
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
    }
}

nonisolated struct BackupSnippet: Codable, Equatable, Sendable {
    var v = 1
    var type = "snippet"
    var id: String
    var name: String
    var keyword: String
    var body: String
    var createdAt: Int64
    var updatedAt: Int64

    init(id: String, name: String, keyword: String, body: String, createdAt: Int64, updatedAt: Int64) {
        self.id = id
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
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        keyword = try c.decodeIfPresent(String.self, forKey: .keyword) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? createdAt
    }
}

nonisolated struct BackupSecret: Codable, Equatable, Sendable {
    var v = 1
    var type = "secret"
    var id: String
    var name: String
    var value: String
    var createdAt: Int64

    init(id: String, name: String, value: String, createdAt: Int64) {
        self.id = id
        self.name = name
        self.value = value
        self.createdAt = createdAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "secret"
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
    }
}

nonisolated extension Date {
    /// Unix milliseconds, as in the backup (and sync) format.
    var backupMillis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
    init(backupMillis: Int64) { self.init(timeIntervalSince1970: TimeInterval(backupMillis) / 1000) }
}

// MARK: - Export

extension BackupClip {
    /// Everything but the image bytes, which are read off the main actor.
    init(item: ClipItem) {
        self.init(id: item.id.uuidString.lowercased(), kind: item.kind.rawValue, isPinned: item.isPinned,
                  copyCount: item.copyCount, createdAt: item.createdAt.backupMillis,
                  lastCopiedAt: item.lastCopiedAt.backupMillis, contentHash: item.contentHash)
        text = item.text
        preview = item.preview
        rtf = item.rtfData
        html = item.htmlData
        files = item.fileURLStrings.isEmpty ? nil : item.fileURLStrings
        if item.kind == .image {
            imageWidth = item.imageWidth
            imageHeight = item.imageHeight
        }
        byteCount = item.byteCount > 0 ? item.byteCount : nil
        sourceId = item.sourceBundleID
        sourceName = item.sourceAppName
        pinnedAt = item.isPinned ? item.pinnedAt?.backupMillis : nil
        label = item.label
    }
}

/// What goes into a backup, gathered on the main actor; `write` does the heavy part elsewhere.
nonisolated struct BackupContents: Sendable {
    var clips: [BackupClip]
    /// Image and thumbnail files of each clip, by index.
    var imageFiles: [Int: (image: URL?, thumb: URL?)]
    var snippets: [BackupSnippet]
    var secrets: [BackupSecret]?

    var summary: String {
        var parts = [BackupSummary.count(clips.count, "item")]
        parts.append(BackupSummary.count(snippets.count, "snippet"))
        if let secrets { parts.append(BackupSummary.count(secrets.count, "secret")) }
        return BackupSummary.list(parts)
    }
}

enum BackupExporter {
    /// The personal space only: group items belong to their groups and stay there.
    static func contents(store: ClipStore, snippets: SnippetStore, secrets: [(ref: SecretRef, value: String)]?) -> BackupContents {
        var clips: [BackupClip] = []
        var files: [Int: (image: URL?, thumb: URL?)] = [:]
        for item in store.items(inSpace: nil) {
            if item.kind == .image {
                guard let image = item.imageFile else { continue }
                files[clips.count] = (store.blobs.url(for: image), item.thumbnailFile.map(store.blobs.url(for:)))
            }
            clips.append(BackupClip(item: item))
        }
        let snippetList = snippets.snippets(inSpace: nil).map {
            BackupSnippet(id: $0.id.uuidString.lowercased(), name: $0.name, keyword: $0.keyword, body: $0.body,
                          createdAt: $0.createdAt.backupMillis, updatedAt: $0.updatedAt.backupMillis)
        }
        let secretList = secrets?.map {
            BackupSecret(id: $0.ref.id.lowercased(), name: $0.ref.name, value: $0.value,
                         createdAt: ($0.ref.createdAt ?? .now).backupMillis)
        }
        return BackupContents(clips: clips, imageFiles: files, snippets: snippetList, secrets: secretList)
    }

    /// Reads the images, encrypts and writes the file atomically. Images that can't be read are
    /// left out (their items too).
    @concurrent
    static func write(_ contents: BackupContents, passphrase: String, to url: URL, now: Date = .now) async throws {
        let data = try seal(contents, passphrase: passphrase, now: now)
        try data.write(to: url, options: .atomic)
    }

    nonisolated static func seal(_ contents: BackupContents, passphrase: String, now: Date = .now) throws -> Data {
        var clips: [BackupClip] = []
        clips.reserveCapacity(contents.clips.count)
        for (index, clip) in contents.clips.enumerated() {
            var clip = clip
            if let files = contents.imageFiles[index] {
                guard let url = files.image, let png = try? Data(contentsOf: url) else { continue }
                clip.image = png
                clip.thumb = files.thumb.flatMap { try? Data(contentsOf: $0) }
            }
            clips.append(clip)
        }
        let document = BackupDocument(createdAt: now.backupMillis, clips: clips, snippets: contents.snippets,
                                      secrets: contents.secrets)
        return try BackupCrypto.seal(try document.encoded(), passphrase: passphrase)
    }
}

// MARK: - Import

/// Where imported secrets go (the Keychain in the app, a list in tests).
protocol BackupSecretSink {
    /// Personal secrets already saved, for skipping duplicates.
    func existingSecrets() -> [(name: String, value: String)]
    func addSecret(name: String, value: String) -> Bool
    func finishImport()
}

extension SecretStore: BackupSecretSink {
    func existingSecrets() -> [(name: String, value: String)] {
        secrets.filter { $0.spaceID == nil }.compactMap { ref in SecretVault.value(id: ref.id).map { (ref.name, $0) } }
    }

    func addSecret(name: String, value: String) -> Bool {
        SecretVault.add(name: name, value: value) != nil
    }

    func finishImport() {
        reload()
    }
}

nonisolated struct BackupImportSummary: Equatable, Sendable {
    var clipsAdded = 0
    var clipsSkipped = 0
    /// Not pinned and older than the "Forget items after" setting.
    var clipsExpired = 0
    var clipsUnreadable = 0
    var snippetsAdded = 0
    var snippetsSkipped = 0
    var secretsAdded = 0
    var secretsSkipped = 0
    var secretsFailed = 0

    var added: Int { clipsAdded + snippetsAdded + secretsAdded }
    var skipped: Int { clipsSkipped + snippetsSkipped + secretsSkipped }

    var message: String {
        var lines: [String] = []
        var addedParts: [String] = []
        if clipsAdded > 0 { addedParts.append(BackupSummary.count(clipsAdded, "item")) }
        if snippetsAdded > 0 { addedParts.append(BackupSummary.count(snippetsAdded, "snippet")) }
        if secretsAdded > 0 { addedParts.append(BackupSummary.count(secretsAdded, "secret")) }
        lines.append(addedParts.isEmpty ? "Nothing new to add." : "Added \(BackupSummary.list(addedParts)).")
        if skipped > 0 { lines.append("\(skipped) already here, so skipped.") }
        if clipsExpired > 0 {
            lines.append("\(BackupSummary.count(clipsExpired, "item")) older than your “Forget items after” setting left out.")
        }
        if clipsUnreadable > 0 { lines.append("\(BackupSummary.count(clipsUnreadable, "item")) couldn't be read.") }
        if secretsFailed > 0 { lines.append("\(BackupSummary.count(secretsFailed, "secret")) couldn't be saved to the Keychain.") }
        return lines.joined(separator: " ")
    }
}

nonisolated enum BackupSummary {
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        default: parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }
}

enum BackupImporter {
    /// Decrypts and decodes, off the main actor.
    @concurrent
    static func read(from url: URL, passphrase: String) async throws -> BackupDocument {
        try open(try Data(contentsOf: url), passphrase: passphrase)
    }

    nonisolated static func open(_ data: Data, passphrase: String) throws -> BackupDocument {
        try BackupDocument.decode(try BackupCrypto.open(data, passphrase: passphrase))
    }

    /// Adds what isn't here yet to the personal space: clips by content hash, snippets by
    /// (name, body), secrets by (name, value). Nothing existing is changed.
    static func merge(_ document: BackupDocument, store: ClipStore, snippets: SnippetStore,
                      secrets: (any BackupSecretSink)?, maxAge: TimeInterval?, now: Date = .now) -> BackupImportSummary {
        var summary = BackupImportSummary()
        mergeClips(document.clips, into: store, maxAge: maxAge, now: now, summary: &summary)
        mergeSnippets(document.snippets, into: snippets, summary: &summary)
        if let secrets, let incoming = document.secrets {
            mergeSecrets(incoming, into: secrets, summary: &summary)
        }
        return summary
    }

    private static func mergeClips(_ clips: [BackupClip], into store: ClipStore, maxAge: TimeInterval?, now: Date,
                                   summary: inout BackupImportSummary) {
        var known = Set(store.items(inSpace: nil).map(\.contentHash).filter { !$0.isEmpty })
        var inserted = false
        for clip in clips {
            if !clip.contentHash.isEmpty && known.contains(clip.contentHash) {
                summary.clipsSkipped += 1
                continue
            }
            guard let item = makeItem(clip, store: store) else {
                summary.clipsUnreadable += 1
                continue
            }
            if known.contains(item.contentHash) {
                discard(item, store: store)
                summary.clipsSkipped += 1
                continue
            }
            if !item.isPinned, let maxAge, item.lastCopiedAt < now.addingTimeInterval(-maxAge) {
                discard(item, store: store)
                summary.clipsExpired += 1
                continue
            }
            known.insert(item.contentHash)
            store.insertSynced(item)
            inserted = true
            summary.clipsAdded += 1
        }
        if inserted { store.commitSynced() }
    }

    /// Builds an unsaved item (writing its image files), or nil if the clip is unusable.
    private static func makeItem(_ clip: BackupClip, store: ClipStore) -> ClipItem? {
        var kind = ClipKind(rawValue: clip.kind) ?? .text
        let item = ClipItem(capture: .text(""))
        if let id = UUID(uuidString: clip.id), store.item(withID: id) == nil { item.id = id }
        item.text = clip.text ?? ""
        item.fileURLStrings = []

        switch kind {
        case .file:
            let urls = (clip.files ?? []).compactMap(URL.init(string:)).filter(\.isFileURL)
            if urls.isEmpty {
                // Only names (e.g. from another platform): keep them as text.
                kind = .text
                if item.text.isEmpty { item.text = (clip.files ?? []).joined(separator: "\n") }
            } else {
                item.fileURLStrings = urls.map(\.absoluteString)
                if item.text.isEmpty { item.text = urls.map(\.path).joined(separator: "\n") }
            }
        case .image:
            guard let png = clip.image, !png.isEmpty else { return nil }
            let base = UUID().uuidString
            var thumb = clip.thumb
            if thumb == nil || thumb?.isEmpty == true { thumb = ImageProcessor.process(png)?.thumbnail }
            guard let thumb else { return nil }
            do {
                try store.blobs.write(png, name: base + ".png")
                try store.blobs.write(thumb, name: base + "-thumb.png")
            } catch {
                store.blobs.delete(base + ".png")
                return nil
            }
            item.imageFile = base + ".png"
            item.thumbnailFile = base + "-thumb.png"
            item.imageWidth = clip.imageWidth ?? 0
            item.imageHeight = clip.imageHeight ?? 0
        case .text, .richText:
            break
        }
        if kind == .richText && clip.rtf == nil && clip.html == nil { kind = .text }
        if kind.isTextual && item.text.isEmpty { return nil }

        item.kind = kind
        item.rtfData = kind == .richText ? clip.rtf : nil
        item.htmlData = kind == .richText ? clip.html : nil
        item.preview = clip.preview ?? TextPreview.make(kind == .image ? "Image \(item.imageWidth)×\(item.imageHeight)" : item.text)
        item.contentHash = clip.contentHash.isEmpty || kind != ClipKind(rawValue: clip.kind)
            ? recomputedHash(for: item, image: clip.image) : clip.contentHash
        item.byteCount = clip.byteCount ?? item.text.utf8.count
        item.sourceBundleID = clip.sourceId
        item.sourceAppName = clip.sourceName
        item.isPinned = clip.isPinned
        item.pinnedAt = clip.isPinned ? clip.pinnedAt.map(Date.init(backupMillis:)) ?? .now : nil
        item.label = clip.label?.isEmpty == true ? nil : clip.label
        item.copyCount = max(1, clip.copyCount)
        item.createdAt = Date(backupMillis: clip.createdAt)
        item.lastCopiedAt = Date(backupMillis: clip.lastCopiedAt)
        return item
    }

    private static func recomputedHash(for item: ClipItem, image: Data?) -> String {
        switch item.kind {
        case .text, .richText: ContentHasher.hash(text: item.text)
        case .file: ContentHasher.hash(fileURLs: item.fileURLs)
        case .image: ContentHasher.hash(imageData: image ?? Data())
        }
    }

    /// An item that won't be inserted: drop the image files written for it.
    private static func discard(_ item: ClipItem, store: ClipStore) {
        store.blobs.delete(item.imageFile)
        store.blobs.delete(item.thumbnailFile)
    }

    private static func mergeSnippets(_ incoming: [BackupSnippet], into snippets: SnippetStore, summary: inout BackupImportSummary) {
        var known = Set(snippets.snippets(inSpace: nil).map { SnippetKey(name: $0.name, body: $0.body) })
        var inserted = false
        for backup in incoming {
            let key = SnippetKey(name: backup.name, body: backup.body)
            guard known.insert(key).inserted else {
                summary.snippetsSkipped += 1
                continue
            }
            let snippet = Snippet(name: backup.name, keyword: backup.keyword, body: backup.body)
            if let id = UUID(uuidString: backup.id), snippets.snippet(withID: id) == nil { snippet.id = id }
            snippet.createdAt = Date(backupMillis: backup.createdAt)
            snippet.updatedAt = Date(backupMillis: backup.updatedAt)
            snippets.insertSynced(snippet)
            inserted = true
            summary.snippetsAdded += 1
        }
        if inserted { snippets.commitSynced() }
    }

    private static func mergeSecrets(_ incoming: [BackupSecret], into sink: any BackupSecretSink, summary: inout BackupImportSummary) {
        var known = Set(sink.existingSecrets().map { SecretKey(name: $0.name, value: $0.value) })
        for secret in incoming where !secret.value.isEmpty {
            guard known.insert(SecretKey(name: secret.name, value: secret.value)).inserted else {
                summary.secretsSkipped += 1
                continue
            }
            if sink.addSecret(name: secret.name, value: secret.value) {
                summary.secretsAdded += 1
            } else {
                summary.secretsFailed += 1
            }
        }
        sink.finishImport()
    }
}

nonisolated private struct SnippetKey: Hashable {
    let name: String
    let body: String
}

nonisolated private struct SecretKey: Hashable {
    let name: String
    let value: String
}
