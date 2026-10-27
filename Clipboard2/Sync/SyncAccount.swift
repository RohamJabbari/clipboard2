import Foundation
import Security
import SwiftData
import Observation

/// What stays on this Mac between launches: the session token and the unwrapped keys, so the
/// password is asked for only when the session ends. Kept in the Keychain, never in settings files.
nonisolated struct StoredSyncSession: Codable, Sendable, Equatable {
    var uid: String
    var email: String
    /// nil once the server has ended the session; the keys stay so sync resumes after the password.
    var token: String?
    var accountKey: Data
    var privateKey: Data
    var personalSpaceId: String
    var username: String?
    /// SHA-256 (hex) of each space key as first unwrapped, by space id (key pinning).
    var spaceKeyPins: [String: String]?
    /// This Mac's session id from `/v1/sessions`.
    var deviceId: String?
}

protocol SyncSessionStore: AnyObject {
    func load() -> StoredSyncSession?
    func save(_ session: StoredSyncSession)
    func clear()
    /// The PBKDF2 iterations last used successfully, by email digest. Survives sign-out.
    func kdfFloors() -> [String: Int]
    func saveKDFFloors(_ floors: [String: Int])
}

/// Generic-password items (service `<bundle id>.sync`), readable only on this device: the session,
/// and the remembered KDF parameters.
final class KeychainSyncSessionStore: SyncSessionStore {
    private let sessionAccount = "session"
    private let kdfAccount = "kdf"

    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: SyncConfig.keychainService, kSecAttrAccount: account]
    }

    private func read(_ account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func write(_ data: Data, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var attributes = query(account)
        attributes[kSecAttrLabel] = "Clipboard2 Sync"
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess { Log.sync.error("Keychain save failed: \(status)") }
    }

    func load() -> StoredSyncSession? {
        read(sessionAccount).flatMap { try? JSONDecoder().decode(StoredSyncSession.self, from: $0) }
    }

    func save(_ session: StoredSyncSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        write(data, account: sessionAccount)
    }

    func clear() {
        SecItemDelete(query(sessionAccount) as CFDictionary)
    }

    func kdfFloors() -> [String: Int] {
        read(kdfAccount).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
    }

    func saveKDFFloors(_ floors: [String: Int]) {
        guard let data = try? JSONEncoder().encode(floors) else { return }
        write(data, account: kdfAccount)
    }
}

/// A group as the UI shows it (the name is decrypted on this device).
nonisolated struct SyncGroup: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var isOwner: Bool
    var memberCount: Int
}

/// A device signed in to the account (one session).
nonisolated struct SyncDevice: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var createdAt: Date
    var lastUsedAt: Date
    /// This Mac.
    var isCurrent: Bool

    init(_ remote: RemoteDevice) {
        id = remote.id
        name = remote.deviceName?.isEmpty == false ? remote.deviceName! : "Unnamed device"
        createdAt = Date(syncMillis: remote.createdAt)
        lastUsedAt = Date(syncMillis: remote.lastUsedAt)
        isCurrent = remote.current
    }
}

/// A pasted invite code, opened: enough to ask "Join ‹name›?" and then join.
nonisolated struct InvitePreview: Sendable, Equatable {
    var inviteId: String
    var spaceId: String
    var name: String
    var memberCount: Int
    var expiresAt: Date
    var spaceKey: Data
}

nonisolated enum SyncAccountError: LocalizedError, Equatable {
    case notSignedIn
    case missingGroupKey
    case invalidInviteCode
    case inviteNotFound
    case alreadyMember(String)
    case emailTaken
    case usernameTaken
    case inviteRequired
    case unsafePasswordSettings
    case weakerPasswordSettings
    case cantSendToThisDevice
    case notSaved

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to sync first."
        case .missingGroupKey: "This group's key isn't available yet. Try again after the next sync."
        case .invalidInviteCode: "That isn't a valid invite code. Check it and try again."
        case .inviteNotFound: "This invite code is unknown, already used or expired. Ask for a new one."
        case .alreadyMember(let name): "You're already in “\(name)”."
        case .emailTaken: "An account with this email already exists. Sign in instead."
        case .usernameTaken: "That username is taken. Try another one."
        case .inviteRequired: "Enter the invite code you were sent. Sign-up is by invitation only."
        case .unsafePasswordSettings:
            "The sync service asked for password settings outside the safe range, so your password wasn't used. Try again later."
        case .weakerPasswordSettings:
            "The sync service asked for weaker password protection than this Mac used before, so your password wasn't used."
        case .cantSendToThisDevice: "That's this Mac. Pick another device."
        case .notSaved: "Only items in your history can be sent."
        }
    }
}

/// Sync sign-in state and the account-level actions (PROTOCOL.md → Auth and sessions, Invites),
/// plus scheduling of sync ticks. The engine does the actual data sync.
@Observable
final class SyncAccount {
    enum State: Equatable {
        case signedOut
        /// Talking to the server; the text says what for.
        case working(String)
        /// The session ended; the password signs in again (the keys are still on this Mac).
        case needsPassword(email: String)
        case signedIn(email: String)
    }

    /// One line of sync health for the menu bar and the panel.
    enum Status: Equatable, Sendable {
        case idle
        case syncing
        /// The last tick couldn't reach the server.
        case offline
        case error(String)
        case signedOut
    }

    private(set) var state: State = .signedOut
    private(set) var errorMessage: String?
    private(set) var notice: String?
    private(set) var isSyncing = false
    private(set) var isOffline = false
    private(set) var lastSyncAt: Date?
    private(set) var lastSyncError: String?
    private(set) var groups: [SyncGroup] = []
    /// The account's signed-in devices, after `refreshDevices()`; this Mac first.
    private(set) var devices: [SyncDevice] = []
    /// Shown to group members on the items you copy. nil until you pick one.
    private(set) var username: String?
    /// Space id → member uid → display name, for "copied by" badges.
    private(set) var memberNames: [String: [String: String]] = [:]
    /// Synced item id → uid of whoever last wrote it (nil: synced, author not known yet).
    @ObservationIgnored private var authors: [String: String?] = [:]

    @ObservationIgnored private let credentials: any SyncSessionStore
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let store: ClipStore
    @ObservationIgnored private let snippets: SnippetStore
    @ObservationIgnored private let secrets: any SyncSecretSource
    @ObservationIgnored private let makeService: (@escaping @Sendable () async throws -> String) -> any SyncService

    @ObservationIgnored private(set) var engine: SyncEngine?
    @ObservationIgnored private var session: StoredSyncSession?
    /// The 3 s debounce after local changes (and the wait out of a rate limit). Cancelling it
    /// never touches a running tick.
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isTicking = false
    /// A tick task was created and hasn't started yet.
    @ObservationIgnored private var tickPending = false
    @ObservationIgnored private var tickRequested = false
    @ObservationIgnored private var startedTicks = 0
    @ObservationIgnored private var finishedTicks = 0
    /// After a 429: no tick starts before this.
    @ObservationIgnored private(set) var backoffUntil: Date?
    @ObservationIgnored private(set) var isPanelOpen = false
    @ObservationIgnored private var lastActivity: Date = .distantPast
    /// The time source for polling and back-off (tests move it).
    @ObservationIgnored var clock: () -> Date = { .now }
    /// true once a session is active, false after sign-out (drives the ⌥⌘C shortcut).
    @ObservationIgnored var onSessionChange: ((Bool) -> Void)?
    /// Another device sent an item here; the argument is that device's name.
    @ObservationIgnored var onItemSentHere: ((String) -> Void)?

    /// `makeService` builds the API client from a token provider (tests pass an in-memory server).
    init(prefs: Preferences, context: ModelContext, store: ClipStore, snippets: SnippetStore,
         secrets: any SyncSecretSource, credentials: any SyncSessionStore = KeychainSyncSessionStore(),
         makeService: ((@escaping @Sendable () async throws -> String) -> any SyncService)? = nil) {
        self.prefs = prefs
        self.context = context
        self.store = store
        self.snippets = snippets
        self.secrets = secrets
        self.credentials = credentials
        self.makeService = makeService ?? { token in
            SyncAPI(base: SyncConfig.apiBase, transport: URLSessionTransport(), token: token)
        }
    }

    // MARK: Derived state

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var email: String? { session?.email }

    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    var status: Status {
        switch state {
        case .signedOut: return .signedOut
        case .working: return .syncing
        case .needsPassword: return .error("Enter your password to keep syncing.")
        case .signedIn:
            if isSyncing { return .syncing }
            if isOffline { return .offline }
            if let lastSyncError { return .error(lastSyncError) }
            return .idle
        }
    }

    var defaultGroup: SyncGroup? {
        guard let id = prefs.syncDefaultGroupID else { return nil }
        return groups.first { $0.id == id }
    }

    func groupName(for spaceID: String?) -> String? {
        guard let spaceID else { return nil }
        return groups.first { $0.id == spaceID }?.name ?? "Group"
    }

    /// Who copied a group item: their username. Falls back to the group's name when that isn't
    /// known (no username yet, or a server that doesn't list member names). Unsynced items are yours.
    func copiedBy(_ item: ClipItem) -> String? {
        guard let spaceID = item.spaceID else { return nil }
        let author = authors[item.id.uuidString.lowercased()] ?? session?.uid
        if let author, author == session?.uid { return username ?? groupName(for: spaceID) }
        if let author, let name = memberNames[spaceID]?[author] { return name }
        return groupName(for: spaceID)
    }

    /// Why a username can't be used, or nil when it's fine (PROTOCOL.md → Usernames).
    nonisolated static func usernameProblem(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...24).contains(name.count) else { return "Use 3 to 24 characters for your username." }
        guard name.wholeMatch(of: /[\p{L}\p{Nd}][\p{L}\p{Nd}_.\-]*/) != nil else {
            return "Use letters, digits, _ . or -, starting with a letter or digit."
        }
        return nil
    }

    func clearMessages() {
        errorMessage = nil
        notice = nil
    }

    /// Trimmed and lowercased, as the protocol requires before every use.
    nonisolated static func normalize(email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Lifecycle

    /// Restores the stored session at launch.
    func start() {
        guard let saved = credentials.load() else {
            state = .signedOut
            return
        }
        session = saved
        username = saved.username
        loadGroups()
        if saved.token == nil {
            state = .needsPassword(email: saved.email)
            onSessionChange?(true)
        } else if let identity = identity(from: saved) {
            activate(identity)
            Task {
                await refreshAccount()
                await refreshDevices()
            }
        } else {
            state = .needsPassword(email: saved.email)
        }
    }

    private func identity(from session: StoredSyncSession) -> SyncIdentity? {
        guard let pub = try? SyncCrypto.publicKey(of: session.privateKey) else { return nil }
        return SyncIdentity(uid: session.uid, privateKey: session.privateKey, publicKey: pub, personalSpaceId: session.personalSpaceId)
    }

    private func activate(_ identity: SyncIdentity, adopting keys: [String: Data] = [:]) {
        self.engine?.stop()
        let engine = SyncEngine(api: makeAPI(), identity: identity, context: context, store: store,
                                snippets: snippets, secrets: secrets, keyPins: session?.spaceKeyPins ?? [:])
        engine.deviceId = session?.deviceId
        engine.deviceName = deviceName
        engine.onPinsChanged = { [weak self] pins in self?.rememberPins(pins) }
        engine.onSentToThisDevice = { [weak self] _, from in self?.onItemSentHere?(from ?? "another device") }
        for (space, key) in keys { engine.adoptSpaceKey(key, for: space) }
        self.engine = engine
        backoffUntil = nil
        isOffline = false
        state = .signedIn(email: session?.email ?? "")
        onSessionChange?(true)
        requestTick(after: .zero)
        restartPolling()
    }

    /// The API client, authenticated with the current session token.
    func makeAPI() -> any SyncService {
        makeService { [weak self] in
            guard let token = await self?.session?.token else {
                throw SyncAPIError.server(status: 401, code: "unauthenticated", message: "", retryAfter: nil)
            }
            return token
        }
    }

    private var deviceName: String? { Host.current().localizedName }

    private func rememberPins(_ pins: [String: String]) {
        guard var current = session, current.spaceKeyPins != pins else { return }
        current.spaceKeyPins = pins
        session = current
        credentials.save(current)
    }

    // MARK: KDF parameters

    nonisolated static func kdfKey(email: String) -> String { SyncCrypto.sha256Hex(Data(email.utf8)) }

    /// Refuses KDF parameters outside the safe range, or weaker than the ones this Mac last used
    /// for the account, before the password is put through them.
    private func checkedKDF(_ kdf: KDFParams, email: String) throws -> KDFParams {
        guard kdf.alg == nil || kdf.alg == "pbkdf2-sha256",
              SyncConfig.kdfIterationRange.contains(kdf.iterations),
              kdf.salt.count >= 16
        else { throw SyncAccountError.unsafePasswordSettings }
        if let last = credentials.kdfFloors()[Self.kdfKey(email: email)], kdf.iterations < last {
            throw SyncAccountError.weakerPasswordSettings
        }
        return kdf
    }

    /// The parameters that just worked (the account key opened with them, or we chose them).
    private func rememberKDF(iterations: Int, email: String) {
        var floors = credentials.kdfFloors()
        guard floors[Self.kdfKey(email: email)] != iterations else { return }
        floors[Self.kdfKey(email: email)] = iterations
        credentials.saveKDFFloors(floors)
    }

    // MARK: Sign up / sign in

    /// Creates the account: every key is made and wrapped here; the server gets only `authKey`.
    /// `inviteCode` is a sign-up code or a group invite code (then the new account joins that
    /// group right away). nil sends none, for servers from before invite-only sign-up.
    func signUp(email rawEmail: String, password: String, username rawUsername: String, inviteCode: String? = nil) async {
        clearMessages()
        let email = Self.normalize(email: rawEmail)
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.usernameProblem(username) {
            errorMessage = problem
            return
        }
        var signupCode: String?
        var groupCode: Data?
        if let typed = inviteCode {
            if typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorMessage = SyncAccountError.inviteRequired.errorDescription
                return
            } else if let code = SyncCrypto.Invite.parse(typed) {
                groupCode = code
            } else if let code = SyncCrypto.Invite.normalizeSignupCode(typed) {
                signupCode = code
            } else {
                errorMessage = SyncAccountError.invalidInviteCode.errorDescription
                return
            }
        }
        state = .working("Creating your account…")
        do {
            let salt = SyncCrypto.randomBytes(16)
            let keys = try await SyncCrypto.derivePasswordKeys(password: password, salt: salt, iterations: SyncConfig.kdfIterations)
            let uid = SyncCrypto.newID()
            let ak = SyncCrypto.randomBytes(32)
            let priv = SyncCrypto.newPrivateKey()
            let pub = try SyncCrypto.publicKey(of: priv)
            let personalId = SyncCrypto.newID()
            let spaceKey = SyncCrypto.randomBytes(32)
            let body = SignupRequest(
                email: email,
                authKey: keys.authKey,
                kdf: KDFParams(salt: salt, iterations: SyncConfig.kdfIterations),
                uid: uid,
                wrappedAccountKey: try SyncCrypto.seal(ak, key: keys.wrapKey, aad: SyncCrypto.AAD.accountKey(uid: uid)),
                publicKey: pub,
                wrappedPrivateKey: try SyncCrypto.seal(priv, key: ak, aad: SyncCrypto.AAD.privateKey(uid: uid)),
                personalSpace: .init(id: personalId, wrappedKey: try SyncCrypto.wrapSpaceKey(
                    spaceKey, spaceId: personalId, memberUid: uid, memberPublicKey: pub)),
                deviceName: deviceName,
                username: username,
                signupCode: signupCode,
                groupInviteId: groupCode.map(SyncCrypto.Invite.id)
            )
            let remote: RemoteSession
            do {
                remote = try await makeAPI().signup(body)
            } catch let error as SyncAPIError where error.code == "username_taken" {
                throw SyncAccountError.usernameTaken
            } catch let error as SyncAPIError where error.code == "conflict" {
                throw SyncAccountError.emailTaken
            }
            try adopt(remote, wrapKey: keys.wrapKey, adopting: [remote.account.personalSpaceId: spaceKey])
            rememberKDF(iterations: SyncConfig.kdfIterations, email: email)
        } catch {
            fail(error)
            return
        }
        if let groupCode {
            do {
                let preview = try await previewInvite(code: SyncCrypto.Invite.format(groupCode))
                try await join(preview)
                notice = "You joined “\(preview.name)”."
            } catch {
                errorMessage = "Your account is ready, but joining the group didn't work: \(error.localizedDescription)"
            }
        }
    }

    func signIn(email rawEmail: String, password: String) async {
        clearMessages()
        let email = Self.normalize(email: rawEmail)
        state = .working("Signing in…")
        do {
            let api = makeAPI()
            let kdf = try checkedKDF(try await api.prelogin(email: email), email: email)
            let keys = try await SyncCrypto.derivePasswordKeys(password: password, salt: kdf.salt, iterations: kdf.iterations)
            let remote = try await api.login(email: email, authKey: keys.authKey, deviceName: deviceName)
            try adopt(remote, wrapKey: keys.wrapKey)
            rememberKDF(iterations: kdf.iterations, email: email)
        } catch {
            fail(error)
        }
    }

    /// After the session ended: sign in again as the stored email.
    func unlock(password: String) async {
        guard let email = session?.email else { return }
        await signIn(email: email, password: password)
    }

    /// Opens the account key from a fresh `Account`, stores the session and starts syncing.
    private func adopt(_ remote: RemoteSession, wrapKey: Data, adopting keys: [String: Data] = [:]) throws {
        let account = remote.account
        let ak = try SyncCrypto.open(account.wrappedAccountKey, key: wrapKey, aad: SyncCrypto.AAD.accountKey(uid: account.uid))
        let priv = try SyncCrypto.open(account.wrappedPrivateKey, key: ak, aad: SyncCrypto.AAD.privateKey(uid: account.uid))
        let previous = session
        if let previous, previous.uid != account.uid {
            // A different account: nothing of the old one may stay.
            engine?.stop()
            engine = nil
            SyncEngine.wipeLocalState(context: context, store: store, snippets: snippets, secrets: secrets)
            groups = []
        }
        let sameAccount = previous?.uid == account.uid
        let stored = StoredSyncSession(uid: account.uid, email: account.email, token: remote.token, accountKey: ak,
                                       privateKey: priv, personalSpaceId: account.personalSpaceId, username: account.username,
                                       spaceKeyPins: sameAccount ? previous?.spaceKeyPins : nil,
                                       deviceId: nil)
        session = stored
        username = account.username
        credentials.save(stored)
        guard let identity = identity(from: stored) else { throw SyncCryptoError.badKey }
        activate(identity, adopting: keys)
        Task { await refreshDevices() }
    }

    // MARK: Account management

    /// Sets or changes the username. False (with `errorMessage`) when it's invalid or taken.
    func setUsername(_ raw: String) async -> Bool {
        clearMessages()
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.usernameProblem(name) {
            errorMessage = problem
            return false
        }
        guard let api = engine?.api else { return false }
        do {
            let stored = try await api.setUsername(name)
            rememberUsername(stored)
            syncNow()   // refreshes the member names other devices show
            return true
        } catch let error as SyncAPIError where error.code == "username_taken" {
            errorMessage = SyncAccountError.usernameTaken.localizedDescription
        } catch {
            fail(error)
        }
        return false
    }

    /// The username as the server has it (another device may have changed it).
    private func refreshAccount() async {
        guard let api = engine?.api, let account = try? await api.account() else { return }
        rememberUsername(account.username)
    }

    private func rememberUsername(_ name: String?) {
        username = name
        guard var current = session, current.username != name else { return }
        current.username = name
        session = current
        credentials.save(current)
    }

    func changePassword(current: String, new: String) async -> Bool {
        clearMessages()
        guard let session, let api = engine?.api else { return false }
        do {
            let kdf = try checkedKDF(try await api.prelogin(email: session.email), email: session.email)
            let currentKeys = try await SyncCrypto.derivePasswordKeys(password: current, salt: kdf.salt, iterations: kdf.iterations)
            let salt = SyncCrypto.randomBytes(16)
            let newKeys = try await SyncCrypto.derivePasswordKeys(password: new, salt: salt, iterations: SyncConfig.kdfIterations)
            let change = PasswordChange(
                authKey: currentKeys.authKey,
                newAuthKey: newKeys.authKey,
                kdf: KDFParams(salt: salt, iterations: SyncConfig.kdfIterations),
                wrappedAccountKey: try SyncCrypto.seal(session.accountKey, key: newKeys.wrapKey,
                                                       aad: SyncCrypto.AAD.accountKey(uid: session.uid))
            )
            do {
                try await api.changePassword(change)
            } catch let error as SyncAPIError where error.code == "invalid_credentials" {
                errorMessage = "The current password is wrong."
                return false
            }
            rememberKDF(iterations: SyncConfig.kdfIterations, email: session.email)
            notice = "Password changed. Your other devices will ask for the new password."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Deletes the account and everything synced on the server. Local personal history stays.
    func deleteAccount(password: String) async -> Bool {
        clearMessages()
        guard let session else { return false }
        do {
            let api = makeAPI()
            let kdf = try checkedKDF(try await api.prelogin(email: session.email), email: session.email)
            let keys = try await SyncCrypto.derivePasswordKeys(password: password, salt: kdf.salt, iterations: kdf.iterations)
            do {
                try await api.deleteAccount(authKey: keys.authKey)
            } catch let error as SyncAPIError where error.code == "invalid_credentials" {
                errorMessage = "Wrong password."
                return false
            }
            forgetLocally()
            notice = "Your account and synced data were deleted."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Ends the session on the server (best effort) and removes group data, sync state and keys
    /// from this Mac. Personal history stays.
    func signOut() {
        if let token = session?.token {
            let api = makeService { token }
            Task { try? await api.logout() }
        }
        forgetLocally()
    }

    private func forgetLocally() {
        debounceTask?.cancel()
        pollTask?.cancel()
        engine?.stop()
        engine = nil
        SyncEngine.wipeLocalState(context: context, store: store, snippets: snippets, secrets: secrets)
        credentials.clear()
        session = nil
        groups = []
        devices = []
        lastSyncAt = nil
        lastSyncError = nil
        isOffline = false
        backoffUntil = nil
        prefs.syncDefaultGroupID = nil
        clearMessages()
        state = .signedOut
        onSessionChange?(false)
    }

    // MARK: Devices

    /// Loads the signed-in devices and learns this Mac's session id.
    func refreshDevices() async {
        guard engine != nil else { return }
        do {
            let remote = try await call { try await $0.api.sessions() }
            devices = remote.map(SyncDevice.init).sorted {
                $0.isCurrent != $1.isCurrent ? $0.isCurrent : $0.lastUsedAt > $1.lastUsedAt
            }
            if let current = remote.first(where: \.current) {
                engine?.deviceId = current.id
                if var stored = session, stored.deviceId != current.id {
                    stored.deviceId = current.id
                    session = stored
                    credentials.save(stored)
                }
            }
        } catch {
            Log.sync.notice("Can't load devices: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Signs a device out. This Mac signs out the usual way (its group items are removed here).
    func signOut(_ device: SyncDevice) async throws {
        if device.isCurrent {
            signOut()
            return
        }
        try await call { try await $0.api.revokeSession(id: device.id) }
        devices.removeAll { $0.id == device.id }
    }

    /// Pushes the item (a personal copy, for a group item) with `toDevice`, so that device shows
    /// "Sent from ‹this Mac›" and puts it at the top. Returns at once; a failure lands in
    /// `errorMessage`.
    func sendToDevice(_ item: ClipItem, deviceId: String) {
        Task {
            do {
                if try await send(item, toDevice: deviceId) == false {
                    notice = "Not sent yet. It goes out with the next sync."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// `sendToDevice`, awaitable: waits briefly for the push; false when it hasn't gone out yet
    /// (it will with a later sync).
    @discardableResult
    func send(_ item: ClipItem, toDevice deviceId: String) async throws -> Bool {
        let engine = try requireEngine()
        guard item.modelContext != nil else { throw SyncAccountError.notSaved }
        if let mine = engine.deviceId, mine == deviceId { throw SyncAccountError.cantSendToThisDevice }
        let target = item.spaceID == nil ? item : store.shareCopy(of: item, toSpace: nil)
        let id = target.id
        engine.send(itemID: id, toDevice: deviceId)
        store.touch(target)
        await syncAndWait(timeout: .seconds(8))
        return self.engine.map { !$0.isSendPending(itemID: id) } ?? false
    }

    // MARK: Invite someone (sign-up codes)

    /// A new sign-up code, shown once (the server keeps only its hash).
    func createSignupCode() async throws -> SignupCode {
        try await call { try await $0.api.createSignupCode() }
    }

    func openSignupCodes() async throws -> [OpenSignupCode] {
        try await call { try await $0.api.signupCodes() }
    }

    func revoke(_ code: OpenSignupCode) async throws {
        try await call { try await $0.api.revokeSignupCode(id: code.id) }
    }

    // MARK: Scheduling

    /// A local store changed: sync after the debounce. Commits sync makes itself don't count.
    func localChange() {
        guard let engine, !engine.isApplyingRemote else { return }
        reportActivity()
        requestTick(after: SyncConfig.debounce)
    }

    /// Panel opens (and a manual nudge): sync now unless a tick is already running.
    func periodicSync() {
        guard engine != nil, !isTicking else { return }
        requestTick(after: .zero)
    }

    func syncNow() {
        guard engine != nil else { return }
        requestTick(after: .zero)
    }

    /// The user did something (a copy, paste, panel or menu): poll faster for a while.
    func reportActivity() {
        let before = pollInterval
        lastActivity = clock()
        if pollInterval < before { restartPolling() }
    }

    /// The quick panel opened or closed. Opening syncs at once and polls every 3 s while open.
    func setPanelOpen(_ open: Bool) {
        guard open != isPanelOpen else { return }
        isPanelOpen = open
        if open {
            lastActivity = clock()
            syncNow()
        }
        restartPolling()
    }

    /// 3 s while the panel is open, 15 s after recent activity, otherwise 60 s.
    var pollInterval: Duration {
        if isPanelOpen { return SyncConfig.pollWhilePanelOpen }
        if clock().timeIntervalSince(lastActivity) < SyncConfig.activeWindow { return SyncConfig.pollWhileActive }
        return SyncConfig.pollWhileIdle
    }

    private func restartPolling() {
        pollTask?.cancel()
        guard engine != nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.engine != nil else { return }
                if !self.isTicking { self.startTick() }
            }
        }
    }

    /// Syncs now and waits up to `timeout` for a tick that started after this call (so its pull is
    /// fresh) to finish, e.g. before pasting from a group.
    func syncAndWait(timeout: Duration) async {
        guard engine != nil else { return }
        let target = startedTicks + 1
        requestTick(after: .zero)
        let deadline = ContinuousClock.now + timeout
        while finishedTicks < target, engine != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func requestTick(after delay: Duration) {
        guard delay > .zero else {
            startTick()
            return
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.startTick()
        }
    }

    /// Starts a tick, or asks the running one for another pass. Never cancels a running tick.
    private func startTick() {
        guard engine != nil else { return }
        if let until = backoffUntil {
            let wait = until.timeIntervalSince(clock())
            if wait > 0 {
                requestTick(after: .milliseconds(Int((wait * 1000).rounded(.up))))
                return
            }
            backoffUntil = nil
        }
        if isTicking {
            tickRequested = true
            return
        }
        guard !tickPending else { return }
        tickPending = true
        Task { [weak self] in await self?.runTick() }
    }

    /// One tick at a time; requests that arrive mid-tick get one more pass.
    func runTick() async {
        tickPending = false
        guard let engine else { return }
        if isTicking {
            tickRequested = true
            return
        }
        isTicking = true
        isSyncing = true
        repeat {
            tickRequested = false
            startedTicks &+= 1
            do {
                try await engine.tick()
                lastSyncAt = .now
                isOffline = false
                lastSyncError = engine.problem
            } catch {
                finishedTicks = startedTicks
                handleSyncError(error)
                break
            }
            finishedTicks = startedTicks
            loadGroups()
        } while tickRequested && self.engine === engine
        isTicking = false
        isSyncing = false
        // A request that arrived while this tick failed, or a new session started meanwhile.
        if tickRequested, self.engine != nil {
            tickRequested = false
            startTick()
        }
    }

    private func handleSyncError(_ error: any Error) {
        if error is CancellationError { return }
        Log.sync.error("Sync failed: \(String(describing: error), privacy: .public)")
        if let api = error as? SyncAPIError {
            if api.code == "unauthenticated" || api.code == "no_account" {
                sessionEnded()
                return
            }
            if api.isRateLimited {
                // Wait it out; the next tick starts with deletions, so nothing starves.
                let seconds = max(1, api.retryAfter ?? 30)
                backoffUntil = clock().addingTimeInterval(TimeInterval(seconds))
                requestTick(after: .seconds(seconds))
                return
            }
            isOffline = api.isNetwork
        }
        lastSyncError = error.localizedDescription
    }

    /// `401 unauthenticated`: keep the keys, drop the token, ask for the password.
    private func sessionEnded() {
        engine?.stop()
        engine = nil
        debounceTask?.cancel()
        pollTask?.cancel()
        guard var current = session else { return }
        current.token = nil
        session = current
        credentials.save(current)
        lastSyncError = nil
        errorMessage = "Your sync session ended. Enter your password to continue."
        state = .needsPassword(email: current.email)
    }

    // MARK: Groups

    func loadGroups() {
        let spaces = (try? context.fetch(FetchDescriptor<SyncSpace>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let loaded = spaces.filter { !$0.isPersonal }.map {
            SyncGroup(id: $0.id, name: $0.name.isEmpty ? "Group" : $0.name, isOwner: $0.isOwner, memberCount: $0.memberCount)
        }
        if loaded != groups { groups = loaded }
        let names = Dictionary(spaces.map { ($0.id, $0.memberNames) }, uniquingKeysWith: { first, _ in first })
        if names != memberNames { memberNames = names }
        let metas = (try? context.fetch(FetchDescriptor<SyncMeta>())) ?? []
        authors = Dictionary(metas.map { ($0.localId, $0.authorUid) }, uniquingKeysWith: { first, _ in first })
        if let id = prefs.syncDefaultGroupID, !groups.isEmpty, !groups.contains(where: { $0.id == id }) {
            prefs.syncDefaultGroupID = nil
        }
    }

    private func requireEngine() throws -> SyncEngine {
        guard let engine else { throw SyncAccountError.notSignedIn }
        return engine
    }

    /// Runs a server call and turns `401` into the needs-password state.
    private func call<T>(_ operation: (SyncEngine) async throws -> T) async throws -> T {
        let engine = try requireEngine()
        do {
            return try await operation(engine)
        } catch let error as SyncAPIError where error.code == "unauthenticated" {
            sessionEnded()
            throw error
        }
    }

    @discardableResult
    func createGroup(named name: String) async throws -> SyncGroup {
        try await call { engine in
            let id = SyncCrypto.newID()
            let key = SyncCrypto.randomBytes(32)
            let space = try await engine.api.createGroup(
                id: id,
                encryptedName: try SyncCrypto.encryptGroupName(name, spaceKey: key, spaceId: id),
                wrappedKey: try SyncCrypto.wrapSpaceKey(key, spaceId: id, memberUid: engine.identity.uid,
                                                       memberPublicKey: engine.identity.publicKey)
            )
            engine.adoptSpaceKey(key, for: id)
            let group = SyncGroup(id: space.id, name: name, isOwner: true, memberCount: space.memberCount)
            groups.append(group)
            if prefs.syncDefaultGroupID == nil { prefs.syncDefaultGroupID = id }
            syncNow()
            return group
        }
    }

    func renameGroup(_ group: SyncGroup, to name: String) async throws {
        try await call { engine in
            guard let key = engine.spaceKey(for: group.id) else { throw SyncAccountError.missingGroupKey }
            try await engine.api.renameGroup(id: group.id,
                                             encryptedName: try SyncCrypto.encryptGroupName(name, spaceKey: key, spaceId: group.id))
            if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index].name = name }
            syncNow()
        }
    }

    func members(of group: SyncGroup) async throws -> [RemoteMember] {
        try await call { try await $0.api.members(groupId: group.id) }
    }

    func remove(_ member: RemoteMember, from group: SyncGroup) async throws {
        try await call { try await $0.api.removeMember(groupId: group.id, uid: member.uid) }
        syncNow()
    }

    func leave(_ group: SyncGroup) async throws {
        try await call { try await $0.api.removeMember(groupId: group.id, uid: $0.identity.uid) }
        syncNow()
    }

    func delete(_ group: SyncGroup) async throws {
        try await call { try await $0.api.deleteGroup(id: group.id) }
        syncNow()
    }

    // MARK: Invites

    /// Seals the group key with a fresh code and returns the code, formatted for display. It's
    /// shown once: the server only keeps its hash.
    func createInviteCode(for group: SyncGroup) async throws -> String {
        try await call { engine in
            guard let key = engine.spaceKey(for: group.id) else { throw SyncAccountError.missingGroupKey }
            let code = SyncCrypto.Invite.newCode()
            try await engine.api.createInvite(groupId: group.id, inviteId: SyncCrypto.Invite.id(code),
                                              sealedKey: try SyncCrypto.Invite.sealSpaceKey(key, code: code, spaceId: group.id))
            return SyncCrypto.Invite.format(code)
        }
    }

    func pendingInvites(for group: SyncGroup) async throws -> [PendingInvite] {
        try await call { try await $0.api.invites(groupId: group.id) }
    }

    func revoke(_ invite: PendingInvite, in group: SyncGroup) async throws {
        try await call { try await $0.api.revokeInvite(groupId: group.id, inviteId: invite.inviteId) }
    }

    /// Looks up a pasted code and opens the group key and name it carries.
    func previewInvite(code typed: String) async throws -> InvitePreview {
        guard let code = SyncCrypto.Invite.parse(typed) else { throw SyncAccountError.invalidInviteCode }
        return try await call { engine in
            let id = SyncCrypto.Invite.id(code)
            guard let details = try await engine.api.invite(id: id) else { throw SyncAccountError.inviteNotFound }
            guard let key = try? SyncCrypto.Invite.openSpaceKey(details.sealedKey, code: code, spaceId: details.spaceId) else {
                throw SyncAccountError.invalidInviteCode
            }
            let name = details.encryptedName.flatMap {
                try? SyncCrypto.decryptGroupName($0, spaceKey: key, spaceId: details.spaceId)
            } ?? "Group"
            if groups.contains(where: { $0.id == details.spaceId }) { throw SyncAccountError.alreadyMember(name) }
            return InvitePreview(inviteId: id, spaceId: details.spaceId, name: name, memberCount: details.memberCount,
                                 expiresAt: Date(syncMillis: details.expiresAt), spaceKey: key)
        }
    }

    /// Accepts the invite with the group key wrapped to this account's own public key.
    @discardableResult
    func join(_ invite: InvitePreview) async throws -> SyncGroup {
        try await call { engine in
            let wrapped = try SyncCrypto.wrapSpaceKey(invite.spaceKey, spaceId: invite.spaceId, memberUid: engine.identity.uid,
                                                     memberPublicKey: engine.identity.publicKey)
            let space: RemoteSpace
            do {
                space = try await engine.api.acceptInvite(id: invite.inviteId, wrappedKey: wrapped)
            } catch let error as SyncAPIError where error.code == "conflict" {
                throw SyncAccountError.alreadyMember(invite.name)
            } catch let error as SyncAPIError where error.status == 404 {
                throw SyncAccountError.inviteNotFound
            }
            engine.adoptSpaceKey(invite.spaceKey, for: invite.spaceId)
            let group = SyncGroup(id: space.id, name: invite.name, isOwner: false, memberCount: space.memberCount)
            if !groups.contains(where: { $0.id == group.id }) { groups.append(group) }
            if prefs.syncDefaultGroupID == nil { prefs.syncDefaultGroupID = group.id }
            syncNow()
            return group
        }
    }

    // MARK: Errors

    private func fail(_ error: any Error) {
        Log.sync.error("Account action failed: \(String(describing: error), privacy: .public)")
        errorMessage = (error as? SyncCryptoError) != nil
            ? "This password can't unlock your synced data."
            : error.localizedDescription
        if let session {
            state = engine != nil ? .signedIn(email: session.email) : .needsPassword(email: session.email)
        } else {
            state = .signedOut
        }
    }
}

// MARK: - Keychain-backed secrets for sync

extension SecretStore: SyncSecretSource {
    var syncSecrets: [SecretRef] { SecretVault.list() }

    func syncValue(id: String) -> String? { SecretVault.value(id: id) }

    func syncUpsert(id: String, name: String, value: String, spaceID: String?) {
        if let existing = SecretVault.list().first(where: { $0.id.lowercased() == id.lowercased() }) {
            SecretVault.update(id: existing.id, name: name, value: value)
        } else {
            SecretVault.add(name: name, value: value, id: id, spaceID: spaceID)
        }
    }

    func syncDelete(id: String) {
        for ref in SecretVault.list() where ref.id.lowercased() == id.lowercased() {
            SecretVault.delete(id: ref.id)
        }
    }

    func syncDidChange() {
        reload()
    }
}
