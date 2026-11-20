import AppKit
import Security
import Observation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

// Authenticators (docs/features/authenticator.md): your own, with the seed, and ones shared with
// you, which only ever hold pre-computed codes.

/// One you own: the seed and settings, and the authenticator space it syncs in.
nonisolated struct Authenticator: Identifiable, Hashable, Sendable {
    /// The `otp` item's id (lowercase UUID).
    var id: String
    var issuer: String
    var account: String
    /// Normalised base32. Never logged, shown only after Touch ID.
    var secret: String
    var algorithm: OTPAlgorithm
    var digits: Int
    var period: Int
    var createdAt: Date
    var updatedAt: Date
    /// The authenticator space; nil until it's been created on the server (or while signed out).
    var spaceID: String?

    init(id: String = SyncCrypto.newID(), account: OTPAccount, createdAt: Date = .now, spaceID: String? = nil) {
        self.id = id
        issuer = account.issuer
        self.account = account.account
        secret = account.secret
        algorithm = account.algorithm
        digits = account.digits
        period = account.period
        self.createdAt = createdAt
        updatedAt = createdAt
        self.spaceID = spaceID
    }

    /// nil when the payload's secret or settings are unusable.
    init?(id: String, payload: OTPPayload, spaceID: String?) {
        guard let secret = Base32.normalize(payload.secret), TOTP.digitRange.contains(payload.digits), payload.period > 0
        else { return nil }
        self.id = id.lowercased()
        issuer = payload.issuer
        account = payload.account
        self.secret = secret
        algorithm = OTPAlgorithm(parsing: payload.algorithm) ?? .sha1
        digits = payload.digits
        period = payload.period
        createdAt = Date(syncMillis: payload.createdAt)
        updatedAt = Date(syncMillis: payload.updatedAt)
        self.spaceID = spaceID
    }

    var payload: OTPPayload {
        OTPPayload(issuer: issuer, account: account, secret: secret, algorithm: algorithm.rawValue, digits: digits,
                   period: period, createdAt: createdAt.syncMillis, updatedAt: updatedAt.syncMillis)
    }

    var otpAccount: OTPAccount {
        OTPAccount(issuer: issuer, account: account, secret: secret, algorithm: algorithm, digits: digits, period: period)
    }

    func code(at time: Date) -> String? {
        guard let key = Base32.decode(secret) else { return nil }
        return TOTP.code(key: key, time: time, algorithm: algorithm, digits: digits, period: period)
    }
}

/// `codesJSON` (PROTOCOL.md → Authenticators): the codes from `from` (Unix seconds, start of a
/// step) on, one per step.
nonisolated struct CodeBatch: Codable, Equatable, Hashable, Sendable {
    var v = 1
    var issuer: String
    var account: String
    var digits: Int
    var period: Int
    var from: Int64
    var codes: [String]

    static let duration: TimeInterval = 24 * 3600
    /// Keeps a batch under the server's 64 KiB for very short periods.
    static let maxCodes = 4_000
    /// Owner devices top a share up once fewer than this many seconds of codes remain.
    static let topUpThreshold: TimeInterval = 12 * 3600

    init(issuer: String, account: String, digits: Int, period: Int, from: Int64, codes: [String]) {
        self.issuer = issuer
        self.account = account
        self.digits = digits
        self.period = period
        self.from = from
        self.codes = codes
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        issuer = try c.decodeIfPresent(String.self, forKey: .issuer) ?? ""
        account = try c.decodeIfPresent(String.self, forKey: .account) ?? ""
        digits = try c.decodeIfPresent(Int.self, forKey: .digits) ?? 6
        period = max(1, try c.decodeIfPresent(Int.self, forKey: .period) ?? 30)
        from = try c.decodeIfPresent(Int64.self, forKey: .from) ?? 0
        codes = try c.decodeIfPresent([String].self, forKey: .codes) ?? []
    }

    /// The next 24 hours of codes, starting with the current step.
    static func make(for authenticator: Authenticator, now: Date) -> CodeBatch? {
        guard let key = Base32.decode(authenticator.secret), authenticator.period > 0 else { return nil }
        let period = authenticator.period
        let step = Int64(floor(now.timeIntervalSince1970)) / Int64(period)
        let count = min(Int((duration / Double(period)).rounded(.up)), maxCodes)
        var codes: [String] = []
        codes.reserveCapacity(count)
        for offset in 0..<count {
            codes.append(TOTP.hotp(key: key, counter: UInt64(step + Int64(offset)), algorithm: authenticator.algorithm,
                                   digits: authenticator.digits))
        }
        return CodeBatch(issuer: authenticator.issuer, account: authenticator.account, digits: authenticator.digits,
                         period: period, from: step * Int64(period), codes: codes)
    }

    /// End of the last code's step.
    var until: Date { Date(timeIntervalSince1970: TimeInterval(from + Int64(codes.count * period))) }

    func code(at time: Date) -> String? {
        let seconds = Int64(floor(time.timeIntervalSince1970))
        guard seconds >= from else { return nil }
        let index = Int((seconds - from) / Int64(period))
        return codes.indices.contains(index) ? codes[index] : nil
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// One shared with you: codes only, sealed to you by the owner's devices.
nonisolated struct SharedAuthenticator: Identifiable, Codable, Hashable, Sendable {
    var spaceId: String
    var ownerUid: String
    var ownerName: String
    /// Unix ms, as the server lists it.
    var codesUntil: Int64
    var updatedAt: Int64
    /// The last batch that could be opened; nil before the owner's devices sent one.
    var batch: CodeBatch?
    /// Kept from the last batch, so the row keeps its name when the codes run out.
    var issuer: String
    var account: String
    /// When it first showed up here (sorts it in Saved).
    var addedAt: Int64

    var id: String { spaceId }

    enum Status: Equatable {
        case ok
        /// Fewer than 2 hours of codes left.
        case runningOut(until: Date)
        /// No code for now: the owner's devices haven't topped it up.
        case empty
    }

    static let runningOutWindow: TimeInterval = 2 * 3600

    func code(at time: Date) -> String? { batch?.code(at: time) }

    func status(at time: Date) -> Status {
        guard let batch, batch.code(at: time) != nil else { return .empty }
        let until = batch.until
        return until.timeIntervalSince(time) < Self.runningOutWindow ? .runningOut(until: until) : .ok
    }

    var period: Int { batch?.period ?? 30 }
    var digits: Int { batch?.digits ?? 6 }
}

/// A row in Saved: one you own or one shared with you.
nonisolated enum AuthenticatorItem: Identifiable, Hashable, Sendable {
    case owned(Authenticator)
    case shared(SharedAuthenticator)

    var id: String {
        switch self {
        case .owned(let a): "o-" + a.id
        case .shared(let s): "s-" + s.spaceId
        }
    }

    var isOwned: Bool { if case .owned = self { true } else { false } }
    var owned: Authenticator? { if case .owned(let a) = self { a } else { nil } }
    var shared: SharedAuthenticator? { if case .shared(let s) = self { s } else { nil } }

    var issuer: String {
        switch self {
        case .owned(let a): a.issuer
        case .shared(let s): s.issuer
        }
    }

    var account: String {
        switch self {
        case .owned(let a): a.account
        case .shared(let s): s.account
        }
    }

    /// The issuer, or the account when there's no issuer.
    var title: String {
        let issuer = issuer.trimmingCharacters(in: .whitespaces)
        if !issuer.isEmpty { return issuer }
        return account.isEmpty ? "Authenticator" : account
    }

    var subtitle: String { issuer.trimmingCharacters(in: .whitespaces).isEmpty ? "" : account }

    var period: Int {
        switch self {
        case .owned(let a): a.period
        case .shared(let s): s.period
        }
    }

    var digits: Int {
        switch self {
        case .owned(let a): a.digits
        case .shared(let s): s.digits
        }
    }

    var createdAt: Date {
        switch self {
        case .owned(let a): a.createdAt
        case .shared(let s): Date(syncMillis: s.addedAt)
        }
    }

    func code(at time: Date) -> String? {
        switch self {
        case .owned(let a): a.code(at: time)
        case .shared(let s): s.code(at: time)
        }
    }

    var searchText: String { issuer + " " + account }
}

// MARK: - Storage

/// Where authenticators live: the Keychain in the app, memory in tests.
protocol AuthenticatorBacking: AnyObject {
    func loadOwned() -> [Authenticator]
    @discardableResult func saveOwned(_ authenticator: Authenticator) -> Bool
    func deleteOwned(id: String)
    func loadShared() -> [SharedAuthenticator]
    @discardableResult func saveShared(_ shared: SharedAuthenticator) -> Bool
    func deleteShared(spaceId: String)
}

/// One generic-password item per authenticator, like secrets: the payload (with the seed) as the
/// value, the authenticator space as the generic attribute. Code batches shared with you get
/// their own service.
final class KeychainAuthenticatorBacking: AuthenticatorBacking {
    nonisolated static let ownedService = (Bundle.main.bundleIdentifier ?? "at.softmaze.Clippy") + ".authenticators"
    nonisolated static let sharedService = (Bundle.main.bundleIdentifier ?? "at.softmaze.Clippy") + ".sharedcodes"

    private func all(service: String) -> [(account: String, generic: String?, data: Data)] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { attrs in
            guard let account = attrs[kSecAttrAccount as String] as? String,
                  let data = attrs[kSecValueData as String] as? Data else { return nil }
            let generic = (attrs[kSecAttrGeneric as String] as? Data).map { String(decoding: $0, as: UTF8.self) }
            return (account, generic?.isEmpty == false ? generic : nil, data)
        }
    }

    private func write(service: String, account: String, label: String, data: Data, generic: String?) -> Bool {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        var changes: [CFString: Any] = [kSecValueData: data, kSecAttrLabel: label,
                                        kSecAttrGeneric: Data((generic ?? "").utf8)]
        let status = SecItemUpdate(base as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        changes.merge(base) { new, _ in new }
        changes[kSecAttrDescription] = "Clipboard2 authenticator"
        return SecItemAdd(changes as CFDictionary, nil) == errSecSuccess
    }

    private func remove(service: String, account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    }

    func loadOwned() -> [Authenticator] {
        all(service: Self.ownedService).compactMap { entry in
            guard let payload = try? JSONDecoder().decode(OTPPayload.self, from: entry.data) else { return nil }
            return Authenticator(id: entry.account, payload: payload, spaceID: entry.generic)
        }
    }

    func saveOwned(_ authenticator: Authenticator) -> Bool {
        guard let data = try? SyncPayload.otp(authenticator.payload).canonicalJSON() else { return false }
        let label = AuthenticatorItem.owned(authenticator).title
        return write(service: Self.ownedService, account: authenticator.id, label: label, data: data, generic: authenticator.spaceID)
    }

    func deleteOwned(id: String) { remove(service: Self.ownedService, account: id) }

    func loadShared() -> [SharedAuthenticator] {
        all(service: Self.sharedService).compactMap { try? JSONDecoder().decode(SharedAuthenticator.self, from: $0.data) }
    }

    func saveShared(_ shared: SharedAuthenticator) -> Bool {
        guard let data = try? JSONEncoder().encode(shared) else { return false }
        return write(service: Self.sharedService, account: shared.spaceId, label: AuthenticatorItem.shared(shared).title,
                     data: data, generic: nil)
    }

    func deleteShared(spaceId: String) { remove(service: Self.sharedService, account: spaceId) }
}

/// For tests.
final class MemoryAuthenticatorBacking: AuthenticatorBacking {
    var owned: [String: Authenticator] = [:]
    var shared: [String: SharedAuthenticator] = [:]

    func loadOwned() -> [Authenticator] { Array(owned.values) }
    func saveOwned(_ authenticator: Authenticator) -> Bool { owned[authenticator.id] = authenticator; return true }
    func deleteOwned(id: String) { owned[id] = nil }
    func loadShared() -> [SharedAuthenticator] { Array(shared.values) }
    func saveShared(_ shared: SharedAuthenticator) -> Bool { self.shared[shared.spaceId] = shared; return true }
    func deleteShared(spaceId: String) { shared[spaceId] = nil }
}

// MARK: - Store

/// Every authenticator on this Mac, and the one-off "Add to Authenticator" suggestion.
@Observable
final class AuthenticatorStore {
    private(set) var owned: [Authenticator] = []
    private(set) var shared: [SharedAuthenticator] = []
    private(set) var revision = 0
    /// From a copied `otpauth://` link or QR code, until it's added or dismissed. Memory only.
    var suggestion: OTPAccount?
    /// How many people each owned authenticator (by space id) is shared with, from the last sync.
    private(set) var shareCounts: [String: Int] = [:]
    /// A local change that sync should upload.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let backing: any AuthenticatorBacking

    init(backing: any AuthenticatorBacking) {
        self.backing = backing
        reload()
    }

    func reload() {
        owned = backing.loadOwned().sorted { $0.createdAt > $1.createdAt }
        shared = backing.loadShared().sorted { $0.addedAt > $1.addedAt }
        revision &+= 1
    }

    /// Owned and shared, newest first.
    var items: [AuthenticatorItem] {
        (owned.map(AuthenticatorItem.owned) + shared.map(AuthenticatorItem.shared)).sorted { $0.createdAt > $1.createdAt }
    }

    var isEmpty: Bool { owned.isEmpty && shared.isEmpty }

    func authenticator(withID id: String) -> Authenticator? {
        owned.first { $0.id == id.lowercased() }
    }

    func shared(inSpace spaceId: String) -> SharedAuthenticator? {
        shared.first { $0.spaceId == spaceId }
    }

    func item(withID id: String) -> AuthenticatorItem? { items.first { $0.id == id } }

    // MARK: Local changes

    @discardableResult
    func add(_ account: OTPAccount, now: Date = .now) -> Authenticator? {
        let authenticator = Authenticator(account: account, createdAt: now)
        guard backing.saveOwned(authenticator) else { return nil }
        if suggestion?.secret == account.secret { suggestion = nil }
        changed()
        return authenticator
    }

    /// Edits issuer and account (the owner's Rename).
    func rename(id: String, issuer: String, account: String, now: Date = .now) {
        guard var authenticator = authenticator(withID: id) else { return }
        authenticator.issuer = issuer
        authenticator.account = account
        authenticator.updatedAt = max(now, authenticator.updatedAt.addingTimeInterval(0.001))
        backing.saveOwned(authenticator)
        changed()
    }

    /// Removes it here; sync deletes it on the server for everyone.
    func delete(id: String) {
        backing.deleteOwned(id: id.lowercased())
        changed()
    }

    /// Gone from this Mac after leaving it.
    func removeShared(spaceId: String) {
        backing.deleteShared(spaceId: spaceId)
        reload()
    }

    private func changed() {
        reload()
        onChange?()
    }

    // MARK: Sync

    /// Creates or replaces the one with this id (it stays in `spaceID`).
    func syncUpsert(id: String, payload: OTPPayload, spaceID: String) {
        guard let authenticator = Authenticator(id: id, payload: payload, spaceID: spaceID) else { return }
        backing.saveOwned(authenticator)
    }

    func syncSetSpace(id: String, spaceID: String?) {
        guard var authenticator = backing.loadOwned().first(where: { $0.id == id.lowercased() }) else { return }
        authenticator.spaceID = spaceID
        backing.saveOwned(authenticator)
    }

    func syncDelete(id: String) { backing.deleteOwned(id: id.lowercased()) }

    func removeAll(inSpace spaceId: String) {
        for authenticator in backing.loadOwned() where authenticator.spaceID == spaceId { backing.deleteOwned(id: authenticator.id) }
    }

    /// The batches shared with you, as listed by the server: new and changed ones are stored,
    /// unlisted ones dropped. Returns whether anything changed.
    @discardableResult
    func syncReplaceShared(_ incoming: [SharedAuthenticator]) -> Bool {
        let current = Dictionary(backing.loadShared().map { ($0.spaceId, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for entry in incoming where current[entry.spaceId] != entry {
            backing.saveShared(entry)
            changed = true
        }
        let listed = Set(incoming.map(\.spaceId))
        for gone in current.keys where !listed.contains(gone) {
            backing.deleteShared(spaceId: gone)
            changed = true
        }
        return changed
    }

    func setShareCounts(_ counts: [String: Int]) {
        if counts != shareCounts { shareCounts = counts }
    }

    func syncDidChange() { reload() }

    /// Signing out: your own stay here (they sync again after the next sign-in), the ones shared
    /// with you go.
    func detachForSignOut() {
        for var authenticator in backing.loadOwned() where authenticator.spaceID != nil {
            authenticator.spaceID = nil
            backing.saveOwned(authenticator)
        }
        for entry in backing.loadShared() { backing.deleteShared(spaceId: entry.spaceId) }
        shareCounts = [:]
        reload()
    }
}

// MARK: - QR codes

nonisolated enum OTPQRCode {
    /// The first `otpauth://` link in a QR code in the image (Vision, on this Mac).
    static func link(in image: CGImage) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        return (request.results ?? []).lazy.compactMap(\.payloadStringValue).first(where: OTPAuthURI.isSecretLink)
    }

    /// Off the main actor; nil if the file can't be read or has no such code.
    @concurrent
    static func link(at url: URL) async -> String? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return link(in: image)
        }
    }

    /// A crisp QR code of `text` (CoreImage), `size` points square.
    static func image(for text: String, size: CGFloat = 220) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = max(1, (size * 2 / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(scaled, from: scaled.extent)
    }
}
