import AppKit
import CryptoKit
import Observation
import Security

// Origins (docs/features/auth-autofill.md → Origins): a site in Auth edited by hand. Its name,
// domains and icon, notes and documents, synced as an `origin` item in the personal space. Auth's
// entries are filed under an origin by their own `origin` reference, by the origin's `entries`
// (for ones that can't carry a reference), or by a domain the origin claims; otherwise they're
// grouped automatically, as before.

// MARK: - Model

/// A note on an origin: free text, shown as is (it isn't a secret).
nonisolated struct OriginNote: Identifiable, Hashable, Sendable {
    var id: String
    var text: String
    var createdAt: Date
    var updatedAt: Date

    /// The first line, for lists.
    var title: String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Note" : trimmed
    }
}

/// A file kept with an origin. Its bytes are encrypted on this Mac (`OriginDocumentVault`) and
/// sync as a blob whose id is the document's id.
nonisolated struct OriginDocument: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var size: Int64
    var addedAt: Date
}

/// What an origin's row shows.
nonisolated enum OriginIcon: Hashable, Sendable {
    /// A site's favicon: the given domain's, or (nil) the origin's first domain's.
    case favicon(String?)
    /// The first letter of its name on a coloured badge.
    case letter
    /// An SF Symbol.
    case symbol(String)
    /// An emoji (or any short text).
    case emoji(String)

    init(raw: String?) {
        guard let raw, !raw.isEmpty else { self = .favicon(nil); return }
        if raw == "letter" { self = .letter; return }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count == 2 ? parts[1] : ""
        switch parts.first {
        case "favicon": self = .favicon(value.isEmpty ? nil : value.lowercased())
        case "symbol" where !value.isEmpty: self = .symbol(value)
        case "emoji" where !value.isEmpty: self = .emoji(String(value.prefix(4)))
        default: self = .favicon(nil)
        }
    }

    /// Nil for the default (the first domain's favicon), so it's omitted from the payload.
    var raw: String? {
        switch self {
        case .favicon(nil): nil
        case .favicon(let domain?): "favicon:" + domain
        case .letter: "letter"
        case .symbol(let name): "symbol:" + name
        case .emoji(let text): "emoji:" + text
        }
    }

    /// Symbols offered in the icon menu.
    static let symbols = ["building.2", "briefcase", "house", "cart", "creditcard", "banknote", "server.rack",
                          "network", "envelope", "phone", "doc.text", "lock.shield", "person.2", "car", "airplane",
                          "graduationcap", "cross.case", "gamecontroller", "cloud", "wrench.and.screwdriver"]
}

nonisolated struct AuthOrigin: Identifiable, Hashable, Sendable {
    /// The `origin` item's id (lowercase UUID).
    var id: String
    var name: String
    /// Its sites as typed (hosts or URLs). Every registrable domain among them is the origin's.
    var domains: [String]
    var icon: OriginIcon
    var notes: [OriginNote]
    var documents: [OriginDocument]
    /// Entries filed here that can't carry an origin reference themselves (`AuthEntryKey`).
    var entries: [String]
    var createdAt: Date
    var updatedAt: Date

    init(id: String = SyncCrypto.newID(), name: String, domains: [String] = [], icon: OriginIcon = .favicon(nil),
         notes: [OriginNote] = [], documents: [OriginDocument] = [], entries: [String] = [],
         createdAt: Date = .now, updatedAt: Date? = nil) {
        self.id = id.lowercased()
        self.name = name
        self.domains = SecretExtras.cleanURLs(domains)
        self.icon = icon
        self.notes = notes
        self.documents = documents
        self.entries = entries
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    init(id: String, payload: OriginPayload) {
        self.init(id: id, name: payload.name, domains: payload.domains ?? [], icon: OriginIcon(raw: payload.icon),
                  notes: (payload.notes ?? []).map {
                      OriginNote(id: $0.id, text: $0.text, createdAt: Date(syncMillis: $0.createdAt), updatedAt: Date(syncMillis: $0.updatedAt))
                  },
                  documents: (payload.documents ?? []).map {
                      OriginDocument(id: $0.id.lowercased(), name: $0.name, size: $0.size, addedAt: Date(syncMillis: $0.addedAt))
                  },
                  entries: payload.entries ?? [],
                  createdAt: Date(syncMillis: payload.createdAt), updatedAt: Date(syncMillis: payload.updatedAt))
    }

    var payload: OriginPayload {
        OriginPayload(name: name, domains: domains, icon: icon.raw,
                      notes: notes.map { .init(id: $0.id, text: $0.text, createdAt: $0.createdAt.syncMillis, updatedAt: $0.updatedAt.syncMillis) },
                      documents: documents.map { .init(id: $0.id, name: $0.name, size: $0.size, addedAt: $0.addedAt.syncMillis) },
                      entries: entries, createdAt: createdAt.syncMillis, updatedAt: updatedAt.syncMillis)
    }

    /// The registrable domains it claims, in order.
    func claimedDomains(list: PublicSuffixList = .shared) -> [String] {
        AuthSource.domains(ofSites: domains, list: list)
    }

    /// The domain its favicon comes from.
    func faviconDomain(list: PublicSuffixList = .shared) -> String? {
        if case .favicon(let domain?) = icon { return domain }
        return domains.lazy.compactMap { AuthSource.host(ofSite: $0) }.first ?? claimedDomains(list: list).first
    }

    /// The name shown: its own, else its first domain.
    var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return claimedDomains().first ?? "Untitled Site"
    }

    /// Nothing filed here is kept by the origin itself: no notes and no documents.
    var holdsNothing: Bool { notes.isEmpty && documents.isEmpty }
}

/// How an entry is known to an origin's `entries`.
nonisolated enum AuthEntryKey {
    static func secret(_ id: String) -> String { "secret:" + id.lowercased() }
    static func shared(_ spaceId: String) -> String { "shared:" + spaceId.lowercased() }
    static func owned(_ id: String) -> String { "otp:" + id.lowercased() }

    static func of(_ ref: SecretRef) -> String { secret(ref.id) }

    static func of(_ item: AuthenticatorItem) -> String {
        switch item {
        case .owned(let a): owned(a.id)
        case .shared(let s): shared(s.spaceId)
        }
    }
}

// MARK: - Grouping

/// What a row in Auth is listed under.
nonisolated enum AuthGroupKey: Hashable, Sendable {
    /// An origin edited by hand.
    case origin(String)
    /// Grouped automatically: a site's registrable domain or an issuer.
    case source(AuthSource)
    /// "No website".
    case none

    init(_ source: AuthSource?) {
        self = source.map(AuthGroupKey.source) ?? .none
    }

    /// The key `AuthSourceUsage` remembers it by.
    var usageKey: String {
        switch self {
        case .origin(let id): "origin:" + id
        case .source(let source): source.key
        case .none: ""
        }
    }

    var originID: String? {
        if case .origin(let id) = self { return id }
        return nil
    }

    var source: AuthSource? {
        if case .source(let source) = self { return source }
        return nil
    }
}

/// Every origin, indexed for filing entries.
nonisolated struct OriginDirectory: Sendable {
    let origins: [AuthOrigin]
    private let byID: [String: AuthOrigin]
    /// Registrable domain → the origin that claims it (the oldest, when several do).
    private let byDomain: [String: AuthOrigin]
    private let byEntry: [String: AuthOrigin]
    private let byName: [String: AuthOrigin]

    static let empty = OriginDirectory(origins: [])

    init(origins: [AuthOrigin], list: PublicSuffixList = .shared) {
        let ordered = origins.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }
        self.origins = ordered
        var byID: [String: AuthOrigin] = [:], byDomain: [String: AuthOrigin] = [:]
        var byEntry: [String: AuthOrigin] = [:], byName: [String: AuthOrigin] = [:]
        for origin in ordered {
            byID[origin.id] = byID[origin.id] ?? origin
            for domain in origin.claimedDomains(list: list) where byDomain[domain] == nil { byDomain[domain] = origin }
            for entry in origin.entries where byEntry[entry] == nil { byEntry[entry] = origin }
            let name = Self.nameKey(origin.name)
            if !name.isEmpty, byName[name] == nil { byName[name] = origin }
        }
        self.byID = byID
        self.byDomain = byDomain
        self.byEntry = byEntry
        self.byName = byName
    }

    static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func origin(withID id: String?) -> AuthOrigin? { id.flatMap { byID[$0.lowercased()] } }

    func origin(claiming domain: String) -> AuthOrigin? { byDomain[domain.lowercased()] }

    func origin(named name: String) -> AuthOrigin? { byName[Self.nameKey(name)] }

    func origin(pinning entry: String) -> AuthOrigin? { byEntry[entry] }

    /// Where an entry goes: its own reference to an origin that exists, else an origin that lists
    /// it, else one that claims one of its domains (in order) or has its issuer's name, else its
    /// automatic source.
    func key(reference: String?, entry: String, domains: [String], automatic: AuthSource?) -> AuthGroupKey {
        if let origin = origin(withID: reference) { return .origin(origin.id) }
        if let origin = origin(pinning: entry) { return .origin(origin.id) }
        for domain in domains {
            if let origin = origin(claiming: domain) { return .origin(origin.id) }
        }
        switch automatic {
        case .domain(let domain):
            if let origin = origin(claiming: domain) { return .origin(origin.id) }
        case .issuer(let issuer):
            if let origin = origin(named: issuer) { return .origin(origin.id) }
        case nil:
            break
        }
        return AuthGroupKey(automatic)
    }

    func key(of ref: SecretRef, list: PublicSuffixList = .shared) -> AuthGroupKey {
        key(reference: ref.originID, entry: AuthEntryKey.of(ref), domains: AuthSource.domains(ofSites: ref.urls, list: list),
            automatic: AuthSource.of(ref, list: list))
    }

    func key(of item: AuthenticatorItem, list: PublicSuffixList = .shared) -> AuthGroupKey {
        key(reference: item.originID, entry: AuthEntryKey.of(item), domains: AuthSource.domains(ofSites: item.urls, list: list),
            automatic: AuthSource.of(item, list: list))
    }

    /// An email code's group: an origin claiming the sender's domain, else that domain.
    func key(ofCodeFrom domain: String) -> AuthGroupKey {
        if let origin = origin(claiming: domain) { return .origin(origin.id) }
        return .source(.domain(domain))
    }
}

nonisolated enum AuthOriginGrouping {
    /// Items by group: the most recently used first, then the others by title; "No website" last.
    /// Items within a group by title. Origins with nothing in them aren't listed (see `emptyOrigins`).
    static func group<Item>(_ items: [Item], key: (Item) -> AuthGroupKey, title: (Item) -> String,
                            lastUsed: [String: Date], origins: OriginDirectory) -> [AuthSourceGroup<Item>] {
        var byKey: [AuthGroupKey: [Item]] = [:]
        var none: [Item] = []
        for item in items {
            let groupKey = key(item)
            if groupKey == .none { none.append(item) } else { byKey[groupKey, default: []].append(item) }
        }
        func byTitle(_ a: Item, _ b: Item) -> Bool { title(a).localizedStandardCompare(title(b)) == .orderedAscending }
        func name(_ key: AuthGroupKey) -> String {
            switch key {
            case .origin(let id): origins.origin(withID: id)?.title ?? ""
            case .source(let source): source.name
            case .none: ""
            }
        }
        var groups = byKey.keys.sorted { a, b in
            let ua = lastUsed[a.usageKey], ub = lastUsed[b.usageKey]
            switch (ua, ub) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let order = name(a).localizedStandardCompare(name(b))
                return order == .orderedSame ? a.usageKey < b.usageKey : order == .orderedAscending
            }
        }.map { groupKey in
            AuthSourceGroup(key: groupKey, origins: origins, items: byKey[groupKey, default: []].sorted(by: byTitle))
        }
        if !none.isEmpty { groups.append(AuthSourceGroup(source: nil, items: none.sorted(by: byTitle))) }
        return groups
    }

    /// Origins none of `keys` points at, by title: they're listed on their own.
    static func emptyOrigins(_ origins: OriginDirectory, used keys: Set<AuthGroupKey>) -> [AuthOrigin] {
        origins.origins.filter { !keys.contains(.origin($0.id)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

nonisolated extension AuthSourceGroup {
    init(key: AuthGroupKey, origins: OriginDirectory, items: [Item]) {
        switch key {
        case .origin(let id):
            let origin = origins.origin(withID: id)
            self.init(source: origin?.faviconDomain().map(AuthSource.domain), items: items, origin: origin)
        case .source(let source):
            self.init(source: source, items: items)
        case .none:
            self.init(source: nil, items: items)
        }
    }
}

// MARK: - Storage

/// Where origins live: the Keychain in the app, memory in tests.
protocol OriginBacking: AnyObject {
    func loadAll() -> [AuthOrigin]
    @discardableResult func save(_ origin: AuthOrigin) -> Bool
    func delete(id: String)
}

/// One generic-password item per origin, its payload as the value (notes may hold anything, so
/// they're encrypted like secrets). Always the login Keychain: the AutoFill extension never reads
/// origins, so they don't move to the shared one.
final class KeychainOriginBacking: OriginBacking {
    nonisolated static var service: String { KeychainServices.origins }
    private let keychain: any KeychainBackend

    init(keychain: any KeychainBackend = SystemKeychain.login) {
        self.keychain = keychain
    }

    func loadAll() -> [AuthOrigin] {
        keychain.allAttributes(service: Self.service).compactMap { attrs in
            guard let account = attrs[kSecAttrAccount as String] as? String,
                  let data = keychain.data(service: Self.service, account: account),
                  let payload = try? JSONDecoder().decode(OriginPayload.self, from: data) else { return nil }
            return AuthOrigin(id: account, payload: payload)
        }
    }

    func save(_ origin: AuthOrigin) -> Bool {
        guard let data = try? SyncPayload.origin(origin.payload).canonicalJSON() else { return false }
        return keychain.setData(data, service: Self.service, account: origin.id, label: "Clipboard2 site " + origin.title)
    }

    func delete(id: String) { keychain.remove(service: Self.service, account: id) }
}

final class MemoryOriginBacking: OriginBacking {
    var origins: [String: AuthOrigin] = [:]
    func loadAll() -> [AuthOrigin] { Array(origins.values) }
    func save(_ origin: AuthOrigin) -> Bool { origins[origin.id] = origin; return true }
    func delete(id: String) { origins[id] = nil }
}

/// Documents' bytes, encrypted at rest.
nonisolated protocol OriginDocumentVault: AnyObject, Sendable {
    func write(_ data: Data, id: String) -> Bool
    func read(id: String) -> Data?
    func delete(id: String)
    func contains(id: String) -> Bool
}

/// One file per document in Application Support, sealed with AES-GCM under a key kept in the
/// Keychain (made on first use). Without the key the files are unreadable.
nonisolated final class EncryptedFileDocumentVault: OriginDocumentVault {
    let directory: URL
    private let keyProvider: @Sendable () -> SymmetricKey?

    init(directory: URL, keyProvider: @escaping @Sendable () -> SymmetricKey?) {
        self.directory = directory
        self.keyProvider = keyProvider
    }

    /// The app's vault: `Origin Documents/` and a key in the login Keychain.
    static func standard() -> EncryptedFileDocumentVault {
        EncryptedFileDocumentVault(directory: AppPaths.supportDirectory.appending(path: "Origin Documents", directoryHint: .isDirectory),
                                   keyProvider: { KeychainDocumentKey.key() })
    }

    private func url(for id: String) -> URL? {
        let safe = id.lowercased()
        guard !safe.isEmpty, safe.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return directory.appending(path: safe + ".c2doc", directoryHint: .notDirectory)
    }

    func write(_ data: Data, id: String) -> Bool {
        guard let url = url(for: id), let key = keyProvider(),
              let sealed = try? AES.GCM.seal(data, using: key, authenticating: Data(id.lowercased().utf8)).combined else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try sealed.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func read(id: String) -> Data? {
        guard let url = url(for: id), let key = keyProvider(), let sealed = try? Data(contentsOf: url),
              let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: Data(id.lowercased().utf8))
    }

    func delete(id: String) {
        guard let url = url(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func contains(id: String) -> Bool {
        url(for: id).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
}

/// The documents' key: 32 random bytes in the login Keychain, never synced.
nonisolated enum KeychainDocumentKey {
    private static let lock = NSLock()

    static func key() -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        let keychain = SystemKeychain.login
        let service = KeychainServices.originDocumentsKey
        if let data = keychain.data(service: service, account: "key"), data.count == 32 { return SymmetricKey(data: data) }
        let fresh = SymmetricKey(size: .bits256)
        let data = fresh.withUnsafeBytes { Data($0) }
        guard keychain.setData(data, service: service, account: "key", label: "Clipboard2 site documents") else { return nil }
        return fresh
    }
}

nonisolated final class MemoryDocumentVault: OriginDocumentVault, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]

    func write(_ data: Data, id: String) -> Bool { lock.withLock { files[id.lowercased()] = data }; return true }
    func read(id: String) -> Data? { lock.withLock { files[id.lowercased()] } }
    func delete(id: String) { _ = lock.withLock { files.removeValue(forKey: id.lowercased()) } }
    func contains(id: String) -> Bool { lock.withLock { files[id.lowercased()] != nil } }
}

// MARK: - Store

/// Every origin on this Mac.
@Observable
final class OriginStore {
    private(set) var origins: [AuthOrigin] = []
    private(set) var revision = 0
    /// A local change that sync should upload.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let backing: any OriginBacking
    @ObservationIgnored let documents: any OriginDocumentVault
    /// Documents above this size aren't added (the sync blob limit, with room for the seal).
    nonisolated static let maxDocumentBytes: Int64 = 95 * 1024 * 1024
    /// At most this many documents per origin (an item references at most 12 blobs).
    nonisolated static let maxDocuments = 12

    init(backing: any OriginBacking, documents: any OriginDocumentVault) {
        self.backing = backing
        self.documents = documents
        reload()
    }

    func reload() {
        origins = backing.loadAll().sorted { $0.createdAt < $1.createdAt }
        revision &+= 1
    }

    var directory: OriginDirectory { OriginDirectory(origins: origins) }

    func origin(withID id: String?) -> AuthOrigin? {
        guard let id = id?.lowercased() else { return nil }
        return origins.first { $0.id == id }
    }

    // MARK: Local changes

    @discardableResult
    func create(name: String, domains: [String] = [], icon: OriginIcon = .favicon(nil), entries: [String] = [],
                now: Date = .now) -> AuthOrigin? {
        let origin = AuthOrigin(name: name.trimmingCharacters(in: .whitespacesAndNewlines), domains: domains, icon: icon,
                                entries: entries, createdAt: now)
        guard backing.save(origin) else { return nil }
        changed()
        return origin
    }

    /// Writes an edited origin (its `updatedAt` moves on).
    @discardableResult
    func save(_ origin: AuthOrigin, now: Date = .now) -> Bool {
        var next = origin
        next.name = origin.name.trimmingCharacters(in: .whitespacesAndNewlines)
        next.domains = SecretExtras.cleanURLs(origin.domains)
        var seen = Set<String>()
        next.entries = origin.entries.filter { seen.insert($0).inserted }
        let previous = self.origin(withID: origin.id)
        next.updatedAt = max(now, (previous?.updatedAt ?? origin.updatedAt).addingTimeInterval(0.001))
        if let previous, previous.updatedAt == origin.updatedAt, Self.sameContent(previous, next) { return true }
        guard backing.save(next) else { return false }
        changed()
        return true
    }

    /// Deletes it and its documents here; sync deletes it elsewhere. What was filed under it goes
    /// back to automatic grouping.
    func delete(id: String) {
        guard let origin = origin(withID: id) else { return }
        for document in origin.documents { documents.delete(id: document.id) }
        backing.delete(id: origin.id)
        changed()
    }

    @discardableResult
    func addNote(_ text: String, to id: String, now: Date = .now) -> OriginNote? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var origin = origin(withID: id) else { return nil }
        let note = OriginNote(id: SyncCrypto.newID(), text: trimmed, createdAt: now, updatedAt: now)
        origin.notes.append(note)
        return save(origin, now: now) ? note : nil
    }

    func updateNote(_ noteID: String, text: String, in id: String, now: Date = .now) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var origin = origin(withID: id), let index = origin.notes.firstIndex(where: { $0.id == noteID }) else { return }
        guard !trimmed.isEmpty else { return deleteNote(noteID, in: id, now: now) }
        guard origin.notes[index].text != trimmed else { return }
        origin.notes[index].text = trimmed
        origin.notes[index].updatedAt = now
        save(origin, now: now)
    }

    func deleteNote(_ noteID: String, in id: String, now: Date = .now) {
        guard var origin = origin(withID: id) else { return }
        origin.notes.removeAll { $0.id == noteID }
        save(origin, now: now)
    }

    enum DocumentError: Error, Equatable {
        case tooLarge, tooMany, unreadable, notSaved
    }

    /// Encrypts the file's bytes into the vault and lists it on the origin.
    func addDocument(_ data: Data, name: String, to id: String, now: Date = .now) -> Result<OriginDocument, DocumentError> {
        guard var origin = origin(withID: id) else { return .failure(.notSaved) }
        guard origin.documents.count < Self.maxDocuments else { return .failure(.tooMany) }
        guard Int64(data.count) <= Self.maxDocumentBytes else { return .failure(.tooLarge) }
        let document = OriginDocument(id: SyncCrypto.newID(), name: Self.cleanFileName(name), size: Int64(data.count), addedAt: now)
        guard documents.write(data, id: document.id) else { return .failure(.notSaved) }
        origin.documents.append(document)
        guard save(origin, now: now) else {
            documents.delete(id: document.id)
            return .failure(.notSaved)
        }
        return .success(document)
    }

    func addDocument(at url: URL, to id: String, now: Date = .now) -> Result<OriginDocument, DocumentError> {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, Int64(size) > Self.maxDocumentBytes {
            return .failure(.tooLarge)
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        return addDocument(data, name: url.lastPathComponent, to: id, now: now)
    }

    func renameDocument(_ documentID: String, to name: String, in id: String, now: Date = .now) {
        let cleaned = Self.cleanFileName(name)
        guard var origin = origin(withID: id), let index = origin.documents.firstIndex(where: { $0.id == documentID }),
              origin.documents[index].name != cleaned else { return }
        origin.documents[index].name = cleaned
        save(origin, now: now)
    }

    func removeDocument(_ documentID: String, from id: String, now: Date = .now) {
        guard var origin = origin(withID: id), origin.documents.contains(where: { $0.id == documentID }) else { return }
        origin.documents.removeAll { $0.id == documentID }
        guard save(origin, now: now) else { return }
        documents.delete(id: documentID)
    }

    func documentData(_ documentID: String) -> Data? { documents.read(id: documentID) }

    /// Files an entry that can't carry a reference here (and nowhere else), or (nil) nowhere.
    func pin(_ entry: String, to id: String?, now: Date = .now) {
        for var origin in origins where origin.id != id && origin.entries.contains(entry) {
            origin.entries.removeAll { $0 == entry }
            save(origin, now: now)
        }
        if let id, var origin = origin(withID: id), !origin.entries.contains(entry) {
            origin.entries.append(entry)
            save(origin, now: now)
        }
    }

    /// Moves everything `source` holds into `target` (domains, notes, documents, entries) and
    /// deletes `source`. Documents move under new ids, so the target's item uploads them again
    /// before the source's deletion drops its blobs on the server. Entries that reference
    /// `source` are moved by the caller (they live in other stores). Returns the merged origin.
    @discardableResult
    func merge(_ sourceID: String, into targetID: String, now: Date = .now) -> AuthOrigin? {
        guard sourceID != targetID, let source = origin(withID: sourceID), var target = origin(withID: targetID),
              target.documents.count + source.documents.count <= Self.maxDocuments else { return nil }
        target.domains += source.domains
        target.notes += source.notes
        for entry in source.entries where !target.entries.contains(entry) { target.entries.append(entry) }
        var copies: [String] = []
        for document in source.documents {
            var copy = document
            copy.id = SyncCrypto.newID()
            // Its bytes not here yet (still downloading): don't merge, or they'd be lost.
            guard let data = documents.read(id: document.id), documents.write(data, id: copy.id) else {
                for id in copies { documents.delete(id: id) }
                return nil
            }
            copies.append(copy.id)
            target.documents.append(copy)
        }
        if case .favicon(nil) = target.icon, source.icon != .favicon(nil) { target.icon = source.icon }
        guard save(target, now: now) else {
            for id in copies { documents.delete(id: id) }
            return nil
        }
        for document in source.documents { documents.delete(id: document.id) }
        backing.delete(id: source.id)
        changed()
        return origin(withID: targetID)
    }

    private func changed() {
        reload()
        onChange?()
    }

    private static func sameContent(_ a: AuthOrigin, _ b: AuthOrigin) -> Bool {
        var a = a, b = b
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }

    /// A file name without any path, never empty.
    nonisolated static func cleanFileName(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "-")
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? "Document" : trimmed
    }

    // MARK: Sync

    /// Creates or replaces the origin with this id. Documents whose bytes aren't here yet are
    /// listed anyway; `syncStoreDocument` fills them in.
    func syncUpsert(id: String, payload: OriginPayload) {
        let incoming = AuthOrigin(id: id, payload: payload)
        if let existing = origin(withID: id) {
            let kept = Set(incoming.documents.map(\.id))
            for document in existing.documents where !kept.contains(document.id) { documents.delete(id: document.id) }
        }
        backing.save(incoming)
    }

    func syncStoreDocument(_ data: Data, id: String) {
        _ = documents.write(data, id: id)
    }

    func syncDelete(id: String) {
        if let origin = origin(withID: id) ?? backing.loadAll().first(where: { $0.id == id.lowercased() }) {
            for document in origin.documents { documents.delete(id: document.id) }
        }
        backing.delete(id: id.lowercased())
    }

    func syncDidChange() { reload() }

    /// Fresh from the backing (sync reads it mid-tick).
    var syncOrigins: [AuthOrigin] { backing.loadAll() }
}

// MARK: - Opening documents

/// Decrypted copies of documents for Open, Quick Look and Paste, in the app's temporary folder.
/// They're removed at the next launch (and Quick Look's when it closes).
nonisolated enum OriginDocumentFiles {
    static var openDirectory: URL {
        FileManager.default.temporaryDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "at.softmaze.Clippy", directoryHint: .isDirectory)
            .appending(path: "Site Documents", directoryHint: .isDirectory)
    }

    /// Writes `data` as `<directory>/<document id>/<name>` (owner-only) and returns the file.
    static func export(_ data: Data, document: OriginDocument, in directory: URL = openDirectory) -> URL? {
        let folder = directory.appending(path: document.id, directoryHint: .isDirectory)
        let file = folder.appending(path: OriginStore.cleanFileName(document.name), directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file
        } catch {
            return nil
        }
    }

    static func removeAll(in directory: URL = openDirectory) {
        try? FileManager.default.removeItem(at: directory)
    }
}
