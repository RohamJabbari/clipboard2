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
}

/// Secret values live only in the login keychain (one generic-password item each). Names are
/// stored as the item label so listing never needs to touch the values; a sync group id, if
/// any, as the generic attribute.
nonisolated enum SecretVault {
    static let service = (Bundle.main.bundleIdentifier ?? "at.softmaze.Clippy") + ".secrets"

    static func list() -> [SecretRef] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return [] }
        return items.compactMap { attrs in
            guard let account = attrs[kSecAttrAccount as String] as? String else { return nil }
            let space = (attrs[kSecAttrGeneric as String] as? Data).map { String(decoding: $0, as: UTF8.self) }
            return SecretRef(
                id: account,
                name: attrs[kSecAttrLabel as String] as? String ?? "Untitled",
                createdAt: attrs[kSecAttrCreationDate as String] as? Date,
                spaceID: space?.isEmpty == false ? space : nil,
                updatedAt: attrs[kSecAttrModificationDate as String] as? Date
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `id` is given for secrets that arrive through sync.
    @discardableResult
    static func add(name: String, value: String, id: String = UUID().uuidString, spaceID: String? = nil) -> SecretRef? {
        var attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id,
            kSecAttrLabel: name,
            kSecAttrDescription: "Clipboard2 secret",
            kSecValueData: Data(value.utf8),
        ]
        if let spaceID { attributes[kSecAttrGeneric] = Data(spaceID.utf8) }
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { return nil }
        return SecretRef(id: id, name: name, createdAt: .now, spaceID: spaceID, updatedAt: .now)
    }

    @discardableResult
    static func update(id: String, name: String? = nil, value: String? = nil) -> Bool {
        var changes: [CFString: Any] = [:]
        if let name { changes[kSecAttrLabel] = name }
        if let value { changes[kSecValueData] = Data(value.utf8) }
        guard !changes.isEmpty else { return true }
        return SecItemUpdate(baseQuery(id) as CFDictionary, changes as CFDictionary) == errSecSuccess
    }

    static func value(id: String) -> String? {
        var query = baseQuery(id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(id: String) {
        SecItemDelete(baseQuery(id) as CFDictionary)
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
    @ObservationIgnored private var lastAuthentication: Date?
    /// Explicit "Leave Unlocked For…" choice. Unlike the automatic window it survives sleep and
    /// screen lock (that's the point of choosing it), but not quitting Clipboard2.
    private(set) var unlockedUntil: Date?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let prefs: Preferences
    /// True while the Touch ID / password sheet is up, so the quick panel doesn't close under it.
    @ObservationIgnored private(set) var isAuthenticating = false

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
    }

    func reload() {
        secrets = SecretVault.list()
        valueHashes = Set(secrets.compactMap { SecretVault.value(id: $0.id).map(ContentHasher.hash(text:)) })
        revision &+= 1
        onChange?()
    }

    @discardableResult
    func add(name: String, value: String) -> SecretRef? {
        let ref = SecretVault.add(name: name, value: value)
        reload()
        return ref
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
