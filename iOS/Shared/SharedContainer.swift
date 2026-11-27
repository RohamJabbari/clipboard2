import Foundation
import Security

/// What the iOS app and its share extension share (docs/features/ios.md → Signing and capabilities):
/// an App Group container for the item store and files, and a Keychain access group for the session.
nonisolated enum SharedContainer {
    static let appGroup = "group.at.softmaze.Clippy.ios"
    /// Without the team prefix; `keychainGroup` adds it.
    static let keychainGroupSuffix = "at.softmaze.Clippy.ios.shared"

    /// `<TEAMID>.at.softmaze.Clippy.ios.shared`, from the `AppIdentifierPrefix` the build writes into
    /// Info.plist. nil if it's missing (then items go in the target's default group, unshared).
    static var keychainGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              !prefix.isEmpty, !prefix.contains("$") else { return nil }
        return prefix + keychainGroupSuffix
    }

    /// The App Group container, or (without the entitlement, e.g. in unit tests) Application Support.
    static let directory: URL = {
        let fm = FileManager.default
        if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url
        }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let dir = base.appending(path: "Clipboard2", directoryHint: .isDirectory)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var storeURL: URL { directory.appending(path: "Items.json") }
    /// Decrypted images and thumbnails, by blob id (or a local name until uploaded).
    static var blobsDirectory: URL { folder("Blobs") }
    /// Shared files, one folder per item: `Files/<item id>/<name>`.
    static var filesDirectory: URL { folder("Files") }

    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: appGroup) ?? .standard

    private static func folder(_ name: String) -> URL {
        let url = directory.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return url
    }
}

/// A generic-password Keychain item holding JSON, in the shared access group when there is one.
/// Accessible after first unlock, never backed up or moved to another device.
nonisolated struct KeychainJSON<Value: Codable>: Sendable {
    let service: String
    let account: String
    var shared = true

    private var group: String? { shared ? SharedContainer.keychainGroup : nil }

    private func query(group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    func read() -> Value? {
        let groups: [String?] = group == nil ? [nil] : [group, nil]
        for group in groups {
            var q = query(group: group)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
                return try? JSONDecoder().decode(Value.self, from: data)
            }
        }
        return nil
    }

    @discardableResult
    func write(_ value: Value) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        if save(data, group: group) { return true }
        // Built without the Keychain-sharing entitlement: keep it to this target.
        return group != nil && save(data, group: nil)
    }

    private func save(_ data: Data, group: String?) -> Bool {
        let q = query(group: group)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    func delete() {
        SecItemDelete(query(group: group) as CFDictionary)
        SecItemDelete(query(group: nil) as CFDictionary)
    }
}
