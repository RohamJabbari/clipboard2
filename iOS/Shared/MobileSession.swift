import Foundation

/// The signed-in account on this device: the session token and the unwrapped keys
/// (PROTOCOL.md → On the device). Kept in the shared Keychain group so the share extension can push.
nonisolated struct MobileSession: Codable, Equatable, Sendable {
    var uid: String
    var email: String
    var token: String
    var accountKey: Data
    var privateKey: Data
    var personalSpaceId: String
    var username: String?
    /// Space id → SHA-256 of the space key first seen for it. A server that later hands out a
    /// different key for the same space is refused (docs/sync/HARDENING-2026-10.md).
    var spaceKeyPins: [String: String] = [:]
    /// The server ended the session (401): sign in again before syncing.
    var expired = false
}

nonisolated enum SessionKeychain {
    static let item = KeychainJSON<MobileSession>(service: "at.softmaze.Clippy.ios.sync", account: "session")

    static func load() -> MobileSession? { item.read() }
    static func save(_ session: MobileSession) { item.write(session) }
    static func clear() { item.delete() }
}

// MARK: - Signing in

nonisolated enum SignInError: LocalizedError, Equatable {
    case unsafePasswordSettings
    case notAvailable
    case approvalDenied
    case approvalExpired

    var errorDescription: String? {
        switch self {
        case .unsafePasswordSettings: "The sync service asked for unsafe password settings. Sign-in was stopped."
        case .notAvailable: "Signing in without a password isn't available yet."
        case .approvalDenied: "Sign-in was declined on your other device."
        case .approvalExpired: "The sign-in request expired. Try again."
        }
    }
}

/// Email and password (PROTOCOL.md → Password-derived keys): the password never leaves the device.
nonisolated struct PasswordSignIn: Sendable {
    let api: any SyncService

    static func normalize(email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func signIn(email rawEmail: String, password: String, deviceName: String?) async throws -> MobileSession {
        let email = Self.normalize(email: rawEmail)
        let kdf = try await api.prelogin(email: email)
        guard kdf.alg == nil || kdf.alg == "pbkdf2-sha256", SyncConfig.kdfIterationRange.contains(kdf.iterations),
              kdf.salt.count >= 16
        else { throw SignInError.unsafePasswordSettings }
        let keys = try await SyncCrypto.derivePasswordKeys(password: password, salt: kdf.salt, iterations: kdf.iterations)
        let remote = try await api.login(email: email, authKey: keys.authKey, deviceName: deviceName)
        return try Self.unlock(remote, wrapKey: keys.wrapKey)
    }

    /// Opens the account key and identity key of a fresh `Account`.
    static func unlock(_ remote: RemoteSession, wrapKey: Data, previous: MobileSession? = nil) throws -> MobileSession {
        let account = remote.account
        let ak = try SyncCrypto.open(account.wrappedAccountKey, key: wrapKey, aad: SyncCrypto.AAD.accountKey(uid: account.uid))
        let priv = try SyncCrypto.open(account.wrappedPrivateKey, key: ak, aad: SyncCrypto.AAD.privateKey(uid: account.uid))
        return MobileSession(uid: account.uid, email: account.email, token: remote.token, accountKey: ak, privateKey: priv,
                             personalSpaceId: account.personalSpaceId, username: account.username,
                             spaceKeyPins: previous?.uid == account.uid ? previous?.spaceKeyPins ?? [:] : [:])
    }
}

/// What another device shows to approve this one, and what this device shows to match it.
nonisolated struct ApprovalRequest: Equatable, Sendable {
    var id: String
    /// Shown on both devices so the user can tell the request is theirs.
    var matchCode: String
    var expiresAt: Date
}

/// Passwordless sign-in with approval from a signed-in device (docs/features/passwordless.md,
/// built on another branch). The sign-in screen only talks to this protocol, so the real flow
/// drops in without UI changes: `begin` asks the server to notify the account's devices,
/// `waitForApproval` returns the session once one approves (with the keys sealed to this device).
protocol PasswordlessSignIn: AnyObject {
    var isAvailable: Bool { get }
    func begin(email: String, deviceName: String?) async throws -> ApprovalRequest
    func waitForApproval(_ request: ApprovalRequest) async throws -> MobileSession
    func cancel(_ request: ApprovalRequest) async
}

/// Until the passwordless protocol ships: not offered.
final class PasswordlessSignInStub: PasswordlessSignIn {
    var isAvailable: Bool { false }
    func begin(email: String, deviceName: String?) async throws -> ApprovalRequest { throw SignInError.notAvailable }
    func waitForApproval(_ request: ApprovalRequest) async throws -> MobileSession { throw SignInError.notAvailable }
    func cancel(_ request: ApprovalRequest) async {}
}
