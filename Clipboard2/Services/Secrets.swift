import AppKit
import Security
import LocalAuthentication
import Observation

nonisolated struct SecretRef: Identifiable, Hashable, Sendable {
    let id: String          // keychain account (UUID)
    var name: String
    var createdAt: Date?
    /// Sync group the secret belongs to; nil is the personal space.
    var spaceID: String? = nil
    /// Keychain modification date (last-write-wins for sync).
    var updatedAt: Date? = nil
    /// The Saved folder (`ClipFolder.id`) it's in. An id with no folder in its space (deleted, or
    /// not synced yet) reads as the root of Saved.
    var folderID: UUID? = nil
    /// A password's username (nil for a plain secret, or a password without one).
    var username: String? = nil
    /// A password's sites, as typed or imported (`https://accounts.google.com`, `google.com`).
    var urls: [String] = []
    /// Short hash of the notes, if any (the notes themselves live in a Keychain item of their own).
    var notesStamp: String? = nil
    /// The origin (Auth's site edited by hand) it's filed under; nil: grouped by its sites.
    var originID: String? = nil

    /// A secret with a site or a username is a password.
    var isPassword: Bool { username?.isEmpty == false || !urls.isEmpty }
}

/// Secret values live only in the Keychain (one generic-password item each): the login Keychain, or
/// in AutoFill builds the shared data-protection one (`AuthKeychain.current`, SharedKeychain.swift). Names are
/// stored as the item label so listing never needs to touch the values; a sync group id, if
/// any, as the generic attribute; the Saved folder, if any, as the comment; a password's username
/// and sites as JSON in the description (`SecretExtras`). Notes get an item of their own in
/// `notesService` (same account), so they're encrypted like the value.
nonisolated enum SecretVault {
    static let service = KeychainServices.secrets
    static let notesService = KeychainServices.secretNotes

    private static var keychain: any KeychainBackend { AuthKeychain.current }

    static func list() -> [SecretRef] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        let (status, result) = keychain.copyMatching(query)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { attrs in
            guard let account = attrs[kSecAttrAccount as String] as? String else { return nil }
            let space = (attrs[kSecAttrGeneric as String] as? Data).map { String(decoding: $0, as: UTF8.self) }
            let extras = SecretExtras(descriptionValue: attrs[kSecAttrDescription as String] as? String)
            return SecretRef(
                id: account,
                name: attrs[kSecAttrLabel as String] as? String ?? "Untitled",
                createdAt: extras.created.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
                    ?? attrs[kSecAttrCreationDate as String] as? Date,
                spaceID: space?.isEmpty == false ? space : nil,
                updatedAt: attrs[kSecAttrModificationDate as String] as? Date,
                folderID: (attrs[kSecAttrComment as String] as? String).flatMap(UUID.init(uuidString:)),
                username: extras.username,
                urls: extras.urls ?? [],
                notesStamp: extras.notes,
                originID: extras.origin
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `id` is given for secrets that arrive through sync.
    @discardableResult
    static func add(name: String, value: String, id: String = UUID().uuidString, spaceID: String? = nil,
                    folderID: UUID? = nil, username: String? = nil, urls: [String] = [], notes: String? = nil,
                    origin: String? = nil) -> SecretRef? {
        let extras = SecretExtras(username: username, urls: urls, notes: SecretExtras.notesStamp(notes), origin: origin)
        var attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id,
            kSecAttrLabel: name,
            kSecAttrDescription: extras.descriptionValue,
            kSecValueData: Data(value.utf8),
        ]
        if let spaceID { attributes[kSecAttrGeneric] = Data(spaceID.utf8) }
        if let folderID { attributes[kSecAttrComment] = folderID.uuidString.lowercased() }
        guard keychain.add(attributes) == errSecSuccess else { return nil }
        writeNotes(notes, id: id)
        return SecretRef(id: id, name: name, createdAt: .now, spaceID: spaceID, updatedAt: .now, folderID: folderID,
                         username: extras.username, urls: extras.urls ?? [], notesStamp: extras.notes, originID: extras.origin)
    }

    /// `folder` sets the Saved folder: `.some(nil)` takes the secret out of its folder. `username`,
    /// `urls`, `notes` and `origin` replace what's there when given (`.some(nil)` and `[]` clear them).
    @discardableResult
    static func update(id: String, name: String? = nil, value: String? = nil, folder: UUID?? = nil,
                       username: String?? = nil, urls: [String]? = nil, notes: String?? = nil,
                       origin: String?? = nil) -> Bool {
        var changes: [CFString: Any] = [:]
        if let name { changes[kSecAttrLabel] = name }
        if let value { changes[kSecValueData] = Data(value.utf8) }
        if let folder { changes[kSecAttrComment] = folder?.uuidString.lowercased() ?? "" }
        if username != nil || urls != nil || notes != nil || origin != nil {
            let current = extras(id: id)
            let extras = SecretExtras(username: username ?? current.username, urls: urls ?? current.urls,
                                      notes: notes.map(SecretExtras.notesStamp) ?? current.notes, created: current.created,
                                      origin: origin ?? current.origin)
            if extras != current { changes[kSecAttrDescription] = extras.descriptionValue }
            if let notes, SecretExtras.notesStamp(notes) != current.notes { writeNotes(notes, id: id) }
        }
        guard !changes.isEmpty else { return true }
        return keychain.update(baseQuery(id), changes) == errSecSuccess
    }

    /// The username, sites and notes stamp, without the value.
    static func extras(id: String) -> SecretExtras {
        var query = baseQuery(id)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        let (status, result) = keychain.copyMatching(query)
        guard status == errSecSuccess, let attrs = result as? [String: Any] else { return SecretExtras() }
        return SecretExtras(descriptionValue: attrs[kSecAttrDescription as String] as? String)
    }

    static func notes(id: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: notesService,
                                      kSecAttrAccount: id, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        let (status, result) = keychain.copyMatching(query)
        guard status == errSecSuccess, let data = result as? Data,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    private static func writeNotes(_ notes: String?, id: String) {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: notesService, kSecAttrAccount: id]
        guard let notes, !notes.isEmpty else {
            keychain.delete(base)
            return
        }
        let data = Data(notes.utf8)
        if keychain.update(base, [kSecValueData: data]) == errSecItemNotFound {
            var add = base
            add[kSecValueData] = data
            add[kSecAttrLabel] = "Clipboard2 notes"
            _ = keychain.add(add)
        }
    }

    static func value(id: String) -> String? {
        var query = baseQuery(id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        let (status, result) = keychain.copyMatching(query)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(id: String) {
        keychain.delete(baseQuery(id))
        writeNotes(nil, id: id)
    }

    private static func baseQuery(_ id: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id]
    }
}

nonisolated enum UnlockDuration: Int, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes = 900
    case oneHour = 3_600
    case eightHours = 28_800
    case oneDay = 86_400
    case oneWeek = 604_800

    var id: Int { rawValue }
    var interval: TimeInterval { TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .fifteenMinutes: "15 Minutes"
        case .oneHour: "1 Hour"
        case .eightHours: "8 Hours"
        case .oneDay: "1 Day"
        case .oneWeek: "1 Week"
        }
    }
}

/// Lists secrets, gates access behind Touch ID / password, and pastes them so that no
/// clipboard manager (including Clipboard2) records them.
@Observable
final class SecretStore {
    private(set) var secrets: [SecretRef] = []
    private(set) var revision = 0
    /// Content hashes of secret values (never the values), so matching copies stay out of history.
    @ObservationIgnored private(set) var valueHashes: Set<String> = []
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var lastAuthentication: Date? { didSet { publishUnlockWindow() } }
    /// Explicit "Leave Unlocked For…" choice. Unlike the automatic window it survives sleep and
    /// screen lock (that's the point of choosing it), but not quitting Clipboard2.
    private(set) var unlockedUntil: Date? { didSet { publishUnlockWindow() } }
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let prefs: Preferences
    /// True while the Touch ID / password sheet is up, so the quick panel doesn't close under it.
    @ObservationIgnored private(set) var isAuthenticating = false
    /// When the last Touch ID / password prompt closed. macOS gives focus back to the previous app a
    /// moment after a password prompt, which mustn't close the panel that asked.
    @ObservationIgnored private(set) var authenticationEndedAt: Date?

    nonisolated static let authenticationEnded = Notification.Name("at.softmaze.Clipboard2.authenticationEnded")

    init(prefs: Preferences) {
        self.prefs = prefs
        reload()
        // Forget the unlock window whenever the Mac sleeps or locks.
        let lock: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.lastAuthentication = nil }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: lock))
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lock))
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lock))
        // Quitting ends every window, the AutoFill extension's copy included.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AutoFillIdentities.publishUnlockWindow(until: nil) }
        })
    }

    func reload() {
        secrets = SecretVault.list()
        valueHashes = Set(secrets.compactMap { SecretVault.value(id: $0.id).map(ContentHasher.hash(text:)) })
        revision &+= 1
        onChange?()
    }

    @discardableResult
    func add(name: String, value: String, spaceID: String? = nil, folderID: UUID? = nil,
             username: String? = nil, urls: [String] = [], notes: String? = nil, origin: String? = nil) -> SecretRef? {
        let ref = SecretVault.add(name: name, value: value, spaceID: spaceID, folderID: folderID,
                                  username: username, urls: urls, notes: notes, origin: origin)
        reload()
        return ref
    }

    /// Files secrets under an origin, or (nil) back under their sites. Only the ones that change are written.
    func setOrigin(_ originID: String?, for refs: [SecretRef]) {
        let changing = refs.filter { $0.originID != originID }
        guard !changing.isEmpty else { return }
        for ref in changing { SecretVault.update(id: ref.id, origin: .some(originID)) }
        reload()
    }

    /// Edit on a password or secret: everything given replaces what's there.
    @discardableResult
    func update(_ ref: SecretRef, name: String? = nil, value: String? = nil, username: String?? = nil,
                urls: [String]? = nil, notes: String?? = nil) -> Bool {
        let ok = SecretVault.update(id: ref.id, name: name, value: value, username: username, urls: urls, notes: notes)
        reload()
        return ok
    }

    /// A password's notes (they're in the Keychain like the value; ask for Touch ID before showing them).
    func notes(of ref: SecretRef) -> String? {
        ref.notesStamp == nil ? nil : SecretVault.notes(id: ref.id)
    }

    /// Moves secrets into a Saved folder, or (nil) out to the root of Saved. Only the ones whose
    /// folder actually changes are written, so nothing re-syncs for nothing.
    func setFolder(_ folderID: UUID?, for refs: [SecretRef]) {
        let changing = refs.filter { $0.folderID != folderID }
        guard !changing.isEmpty else { return }
        for ref in changing { SecretVault.update(id: ref.id, folder: .some(folderID)) }
        reload()
    }

    /// Secrets in a folder of their own space.
    func secrets(inFolder folder: ClipFolder) -> [SecretRef] {
        secrets.filter { $0.folderID == folder.id && $0.spaceID == folder.spaceID }
    }

    func rename(_ ref: SecretRef, to name: String) {
        SecretVault.update(id: ref.id, name: name)
        reload()
    }

    func setValue(_ value: String, for ref: SecretRef) {
        SecretVault.update(id: ref.id, value: value)
        reload()
    }

    func delete(_ ref: SecretRef) {
        SecretVault.delete(id: ref.id)
        reload()
    }

    /// Hashes of the values of the secrets in one space, for "remove history copies of saved
    /// secrets" within that space.
    func valueHashes(inSpace spaceID: String?) -> Set<String> {
        Set(secrets.filter { $0.spaceID == spaceID }.compactMap { SecretVault.value(id: $0.id).map(ContentHasher.hash(text:)) })
    }

    /// Spaces that hold at least one secret (nil = personal).
    var spaceIDs: Set<String?> { Set(secrets.map(\.spaceID)) }

    /// Deletes every secret of a group, e.g. after leaving it or signing out.
    func removeAll(inSpace spaceID: String) {
        let doomed = secrets.filter { $0.spaceID == spaceID }
        guard !doomed.isEmpty else { return }
        for ref in doomed { SecretVault.delete(id: ref.id) }
        reload()
    }

    var isUnlocked: Bool {
        if isManuallyUnlocked { return true }
        guard prefs.secretGraceMinutes > 0, let lastAuthentication else { return false }
        return Date.now.timeIntervalSince(lastAuthentication) < TimeInterval(prefs.secretGraceMinutes * 60)
    }

    /// Until when nothing asks for Touch ID; nil: it asks now. The AutoFill extension shares it.
    var unlockWindowEnd: Date? {
        AutoFillUnlock.until(lastAuthentication: lastAuthentication, graceMinutes: prefs.secretGraceMinutes,
                             unlockedUntil: unlockedUntil, now: .now)
    }

    private func publishUnlockWindow() {
        AutoFillIdentities.publishUnlockWindow(until: unlockWindowEnd)
    }

    var isManuallyUnlocked: Bool {
        guard let unlockedUntil else { return false }
        return unlockedUntil > .now
    }

    /// Always asks for Touch ID (even inside the automatic window), then stays unlocked.
    @discardableResult
    func unlock(for duration: UnlockDuration) async -> Bool {
        guard await evaluate(reason: "leave secrets unlocked for \(duration.title.lowercased())") else { return false }
        unlockedUntil = Date.now.addingTimeInterval(duration.interval)
        return true
    }

    func lock() {
        lastAuthentication = nil
        unlockedUntil = nil
    }

    /// Always asks, even inside the unlock window (e.g. before exporting every secret at once).
    func authenticateNow(reason: String) async -> Bool {
        await evaluate(reason: reason)
    }

    /// Touch ID (or the login password) unless still inside the unlock window.
    func authenticate(reason: String) async -> Bool {
        if isUnlocked { return true }
        return await evaluate(reason: reason)
    }

    private func evaluate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            Log.app.error("Authentication unavailable: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return false
        }
        isAuthenticating = true
        defer {
            isAuthenticating = false
            authenticationEndedAt = .now
            NotificationCenter.default.post(name: Self.authenticationEnded, object: self)
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            lastAuthentication = .now
            return true
        } catch {
            return false
        }
    }

    /// Unlocks and returns the value, or nil if the user cancelled.
    func reveal(_ ref: SecretRef, reason: String) async -> String? {
        guard await authenticate(reason: reason) else { return nil }
        return SecretVault.value(id: ref.id)
    }
}
