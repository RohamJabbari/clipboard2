import Foundation
import Security

// Where secrets, password notes and authenticators live (docs/features/auth-autofill.md →
// Phase 3). Compiled into the app and the AutoFill extension, so keep it Foundation-only.
//
// Builds without CLIPBOARD2_AUTOFILL=1 keep everything in the login Keychain, exactly as before.
// AutoFill builds (signed with provisioning profiles, docs/features/autofill-setup.md) move it once
// to the data-protection Keychain in the access group the extension shares.

nonisolated enum AutoFillConfig {
    /// True in builds made with CLIPBOARD2_AUTOFILL=1 (the `AUTOFILL` compilation condition).
    static let isEnabled: Bool = {
        #if AUTOFILL
        true
        #else
        false
        #endif
    }()

    /// `keychain-access-groups` in both targets' AutoFill entitlements.
    static let accessGroup = "XWTH2647FF.at.softmaze.Clippy.shared"

    /// The app's bundle id, also from inside the extension (`<app id>.autofill`).
    static let appBundleID: String = {
        let id = Bundle.main.bundleIdentifier ?? "at.softmaze.Clippy"
        let suffix = ".autofill"
        if Bundle.main.bundleURL.pathExtension == "appex", id.hasSuffix(suffix) { return String(id.dropLast(suffix.count)) }
        return id
    }()
}

/// Keychain service names. Same in both Keychains, so a move only changes where an item lives.
nonisolated enum KeychainServices {
    static var secrets: String { AutoFillConfig.appBundleID + ".secrets" }
    static var secretNotes: String { AutoFillConfig.appBundleID + ".secretnotes" }
    static var authenticators: String { AutoFillConfig.appBundleID + ".authenticators" }
    static var sharedCodes: String { AutoFillConfig.appBundleID + ".sharedcodes" }
    /// What the extension lists (`AutoFillEntry`s): titles, usernames and domains, never values.
    static var autofillIndex: String { AutoFillConfig.appBundleID + ".autofill-index" }
    /// Until when the app's Touch ID window is open (`AutoFillUnlock`).
    static var autofillUnlock: String { AutoFillConfig.appBundleID + ".autofill-unlock" }
    /// Email codes (phase 4) for the extension, deleted after 10 minutes.
    static var autofillEmailCodes: String { AutoFillConfig.appBundleID + ".autofill-emailcodes" }

    /// What moves to the shared Keychain.
    static var migrated: [String] { [secrets, secretNotes, authenticators, sharedCodes] }
}

// MARK: - Backends

/// The four SecItem calls, so the login Keychain, the shared data-protection Keychain and an
/// in-memory fake (tests) share every query.
nonisolated protocol KeychainBackend: AnyObject, Sendable {
    func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, result: CFTypeRef?)
    func add(_ attributes: [CFString: Any]) -> OSStatus
    func update(_ query: [CFString: Any], _ changes: [CFString: Any]) -> OSStatus
    @discardableResult func delete(_ query: [CFString: Any]) -> OSStatus
}

/// The real Keychain: the login (file-based) one, or the data-protection one in an access group.
nonisolated final class SystemKeychain: KeychainBackend {
    /// Nil: the login Keychain.
    let accessGroup: String?

    init(accessGroup: String?) { self.accessGroup = accessGroup }

    static let login = SystemKeychain(accessGroup: nil)
    static let shared = SystemKeychain(accessGroup: AutoFillConfig.accessGroup)

    private func scoped(_ query: [CFString: Any]) -> [CFString: Any] {
        guard let accessGroup else { return query }
        var query = query
        query[kSecUseDataProtectionKeychain] = true
        query[kSecAttrAccessGroup] = accessGroup
        return query
    }

    func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(scoped(query) as CFDictionary, &result)
        return (status, result)
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        var attributes = scoped(attributes)
        if accessGroup != nil, attributes[kSecAttrAccessible] == nil {
            // Readable by the extension whenever the Mac is unlocked; never leaves this Mac.
            attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [CFString: Any], _ changes: [CFString: Any]) -> OSStatus {
        SecItemUpdate(scoped(query) as CFDictionary, changes as CFDictionary)
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        SecItemDelete(scoped(query) as CFDictionary)
    }
}

/// The Keychain the app reads and writes: the login one until a move to the shared one worked.
nonisolated enum AuthKeychain {
    /// Set once at launch (before any store reads it) by `KeychainLocation.prepare()`.
    nonisolated(unsafe) static var current: any KeychainBackend = SystemKeychain.login
}

// MARK: - Generic-password helpers

nonisolated extension KeychainBackend {
    /// Attributes of every item of `service`. (The login Keychain refuses kSecReturnData with
    /// kSecMatchLimitAll, so values are read one by one.)
    func allAttributes(service: String) -> [[String: Any]] {
        let (status, result) = copyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ])
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items
    }

    func attributes(service: String, account: String) -> [String: Any]? {
        let (status, result) = copyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne,
        ])
        guard status == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    func data(service: String, account: String) -> Data? {
        let (status, result) = copyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ])
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Creates or replaces one item's value (and label).
    @discardableResult
    func setData(_ data: Data, service: String, account: String, label: String) -> Bool {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let status = update(base, [kSecValueData: data, kSecAttrLabel: label])
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var attributes = base
        attributes[kSecValueData] = data
        attributes[kSecAttrLabel] = label
        return add(attributes) == errSecSuccess
    }

    func remove(service: String, account: String? = nil) {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        if let account { query[kSecAttrAccount] = account }
        delete(query)
    }
}

// MARK: - Moving to the shared Keychain

/// Copies every item of some services from one Keychain to another, reads each copy back, and
/// only then deletes the originals. All or nothing: on any failure the copies made so far are
/// removed again and the originals stay where they were.
nonisolated enum KeychainMigration {
    struct Service: Sendable {
        var name: String
        /// Rewrites an item's description on the way (secrets keep their creation date in it,
        /// since a new item gets a new one). Gets the old description and creation date.
        var description: (@Sendable (String?, Date?) -> String?)?

        init(_ name: String, description: (@Sendable (String?, Date?) -> String?)? = nil) {
            self.name = name
            self.description = description
        }
    }

    enum Outcome: Equatable, Sendable {
        case nothingToMove
        case moved(Int)
        case failed(String)
    }

    /// The attributes an item keeps: everything Clipboard2 reads besides the dates.
    private static var kept: [CFString] { [kSecAttrLabel, kSecAttrDescription, kSecAttrComment, kSecAttrGeneric] }

    static func run(services: [Service], from source: any KeychainBackend, to target: any KeychainBackend) -> Outcome {
        var copied: [(service: String, account: String, item: [CFString: Any])] = []

        func undo(_ reason: String) -> Outcome {
            for copy in copied { target.remove(service: copy.service, account: copy.account) }
            return .failed(reason)
        }

        for service in services {
            for attrs in source.allAttributes(service: service.name) {
                guard let account = attrs[kSecAttrAccount as String] as? String else { continue }
                guard let data = source.data(service: service.name, account: account) else {
                    return undo("couldn't read an item of \(service.name)")
                }
                var item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service.name,
                                             kSecAttrAccount: account, kSecValueData: data]
                for key in kept { if let value = attrs[key as String] { item[key] = value } }
                if let rewrite = service.description {
                    item[kSecAttrDescription] = rewrite(attrs[kSecAttrDescription as String] as? String,
                                                        attrs[kSecAttrCreationDate as String] as? Date)
                }
                // Whatever an earlier, failed or older run left there is replaced.
                target.remove(service: service.name, account: account)
                guard target.add(item) == errSecSuccess else { return undo("couldn't add an item to \(service.name)") }
                copied.append((service.name, account, item))
            }
        }

        for copy in copied {
            guard let back = target.attributes(service: copy.service, account: copy.account),
                  let data = target.data(service: copy.service, account: copy.account),
                  data == copy.item[kSecValueData] as? Data,
                  kept.allSatisfy({ same(copy.item[$0], back[$0 as String]) })
            else { return undo("an item of \(copy.service) didn't read back the same") }
        }

        for copy in copied { source.remove(service: copy.service, account: copy.account) }
        return copied.isEmpty ? .nothingToMove : .moved(copied.count)
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (x as String, y as String): x == y
        case let (x as Data, y as Data): x == y
        // An empty attribute may read back as missing.
        case let (x as String, nil), let (nil, x as String): x.isEmpty
        case let (x as Data, nil), let (nil, x as Data): x.isEmpty
        default: false
        }
    }
}
