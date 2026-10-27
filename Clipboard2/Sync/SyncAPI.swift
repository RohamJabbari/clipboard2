import Foundation

/// The one seam between sync and the network, so requests can be checked in tests.
nonisolated protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated struct URLSessionTransport: HTTPTransport {
    var session: URLSession = .shared

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

// MARK: - Wire types (docs/sync/PROTOCOL.md → API). Bytes are base64, times Unix milliseconds.

nonisolated struct KDFParams: Codable, Sendable, Equatable {
    var alg: String? = "pbkdf2-sha256"
    var salt: Data
    var iterations: Int
}

nonisolated struct RemoteAccount: Codable, Sendable, Equatable {
    var uid: String
    var email: String
    var kdf: KDFParams
    var wrappedAccountKey: Data
    var publicKey: Data
    var wrappedPrivateKey: Data
    var personalSpaceId: String
    /// nil for accounts made before usernames, and from servers that don't have them yet.
    var username: String?
}

/// `POST /v1/auth/signup`: the verifier plus everything the account's keys need, all wrapped.
nonisolated struct SignupRequest: Codable, Sendable {
    nonisolated struct PersonalSpace: Codable, Sendable {
        var id: String
        var wrappedKey: Data
    }
    var email: String
    var authKey: Data
    var kdf: KDFParams
    var uid: String
    var wrappedAccountKey: Data
    var publicKey: Data
    var wrappedPrivateKey: Data
    var personalSpace: PersonalSpace
    var deviceName: String?
    var username: String?
    /// Sign-up is invite-only: a sign-up code, or the `inviteId` of an open group invite.
    var signupCode: String?
    var groupInviteId: String?
}

/// `POST /v1/signup-codes`: a fresh code, shown once.
nonisolated struct SignupCode: Codable, Sendable, Equatable {
    var id: String
    var code: String
    var expiresAt: Int64
}

/// `GET /v1/signup-codes`: an unused code (the code itself is never listed again).
nonisolated struct OpenSignupCode: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var createdAt: Int64
    var expiresAt: Int64
}

/// `GET /v1/sessions`: one signed-in device of the account.
nonisolated struct RemoteDevice: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var deviceName: String?
    var createdAt: Int64
    var lastUsedAt: Int64
    var current: Bool
}

/// `PUT /v1/account/password`.
nonisolated struct PasswordChange: Codable, Sendable {
    var authKey: Data
    var newAuthKey: Data
    var kdf: KDFParams
    var wrappedAccountKey: Data
}

nonisolated struct RemoteSession: Codable, Sendable, Equatable {
    var token: String
    var expiresAt: Int64?
    var account: RemoteAccount
}

nonisolated struct PendingInvite: Codable, Sendable, Equatable, Identifiable {
    var inviteId: String
    var createdAt: Int64
    var expiresAt: Int64
    var id: String { inviteId }
}

/// `GET /v1/invites/:inviteId`: what an invitee needs to open the group key and show its name.
nonisolated struct InviteDetails: Codable, Sendable, Equatable {
    var spaceId: String
    var sealedKey: Data
    var encryptedName: Data?
    var memberCount: Int
    var expiresAt: Int64
}

nonisolated struct RemoteSpace: Codable, Sendable, Equatable {
    var id: String
    var kind: String          // personal | group
    var role: String          // owner | member
    var ownerUid: String
    var wrappedKey: Data
    var encryptedName: Data?
    var memberCount: Int
    var createdAt: Int64
    /// Who is in the space, to show who copied an item (absent on servers without usernames).
    var members: [MemberName]?

    var isPersonal: Bool { kind == "personal" }
}

/// A space member's display name: the username, or the part of the email before the @.
nonisolated struct MemberName: Codable, Sendable, Equatable {
    var uid: String
    var name: String
}

/// A group member as the server lists them. No email (servers from before October 2026 still
/// send one); `name` is the username or the email's part before the @.
nonisolated struct RemoteMember: Codable, Sendable, Equatable, Identifiable {
    var uid: String
    var email: String?
    var role: String
    var username: String?
    var name: String?
    var id: String { uid }

    var displayName: String { username ?? name ?? email.map { String($0.prefix { $0 != "@" }) } ?? "Member" }
}

nonisolated struct RemoteItem: Codable, Sendable, Equatable {
    var id: String
    var category: String
    var seq: Int64
    var sortAt: Int64
    var updatedAt: Int64
    var deleted: String?      // nil | user | trimmed
    var ciphertext: Data?
    var blobIds: [String]
    var authorUid: String?
}

nonisolated struct ChangesPage: Codable, Sendable {
    var items: [RemoteItem]
    var nextSince: Int64
    var hasMore: Bool
    var resetRequired: Bool
}

nonisolated struct ItemUpload: Codable, Sendable, Equatable {
    var category: String
    var sortAt: Int64
    var updatedAt: Int64
    var ciphertext: Data
    var blobIds: [String]
}

nonisolated enum WriteOutcome: Sendable, Equatable {
    case saved(seq: Int64, trimmed: [String])
    /// 409: the server holds a newer version.
    case conflict(RemoteItem)
}

nonisolated struct BlobUploadTicket: Codable, Sendable, Equatable {
    var url: URL
    var method: String
    var headers: [String: String]
    var expiresAt: Int64?
}

nonisolated struct BlobDownloadTicket: Codable, Sendable, Equatable {
    var url: URL
    var expiresAt: Int64?
}

nonisolated enum SyncAPIError: LocalizedError, Equatable {
    /// `scope` says which quota a `quota_exceeded` hit: `user` (absent), `group` or `server`.
    case server(status: Int, code: String, message: String, retryAfter: Int?, scope: String? = nil)
    case network(String)
    case invalidResponse

    var code: String? {
        if case .server(_, let code, _, _, _) = self { return code }
        return nil
    }

    var status: Int? {
        if case .server(let status, _, _, _, _) = self { return status }
        return nil
    }

    var retryAfter: Int? {
        if case .server(_, _, _, let retryAfter, _) = self { return retryAfter }
        return nil
    }

    var scope: String? {
        if case .server(_, _, _, _, let scope) = self { return scope }
        return nil
    }

    var isRateLimited: Bool { status == 429 }

    var isNetwork: Bool {
        if case .network = self { return true }
        return false
    }

    /// Retrying the same item write won't help (too big, over quota, rejected, clock off, or
    /// someone else's item in a group). `forbidden` on a read means the space is gone instead.
    var isPermanentForItem: Bool {
        ["too_large", "quota_exceeded", "invalid", "clock_skew", "forbidden"].contains(code ?? "")
    }

    var errorDescription: String? {
        switch self {
        case .network(let message): "Can't reach the sync service (\(message))."
        case .invalidResponse: "The sync service sent an unexpected response."
        case .server(let status, let code, let message, let retryAfter, let scope):
            switch code {
            case "quota_exceeded":
                switch scope {
                case "group": "This group's sync storage is full. Delete some of its items to make room."
                case "server": "The sync service is full right now. Try again later."
                default: message.isEmpty ? "Your sync storage is full." : message
                }
            case "rate_limited":
                retryAfter.map { "Too many requests. Try again in \($0 < 60 ? "\($0) seconds" : "\(($0 + 59) / 60) minutes")." }
                    ?? "Too many requests. Try again in a minute."
            case "invalid_credentials": "Wrong email or password."
            case "unauthenticated": "Your sync session ended. Enter your password again."
            case "clock_skew": "Your clock is off, so sync can't save changes. Turn on “Set time and date automatically” in System Settings → General → Date & Time."
            case "forbidden": "Only the person who shared an item, or the group's owner, can change or delete it."
            case "invite_required": "Sign-up needs an invite code. Ask someone who uses Clipboard2 Sync for one."
            case "invite_invalid": "This invite code is unknown, already used or expired. Ask for a new one."
            case "too_many_codes": "You already have 10 open invite codes. Revoke one or wait until one is used."
            default: message.isEmpty ? "Sync failed (\(status) \(code))." : message
            }
        }
    }
}

// MARK: - Service

/// Every server call sync makes. `SyncAPI` talks HTTP; tests use an in-memory server.
nonisolated protocol SyncService: Sendable {
    // Auth (prelogin, signup and login need no session)
    func prelogin(email: String) async throws -> KDFParams
    func signup(_ body: SignupRequest) async throws -> RemoteSession
    func login(email: String, authKey: Data, deviceName: String?) async throws -> RemoteSession
    func logout() async throws
    func changePassword(_ body: PasswordChange) async throws
    /// Returns the username as stored. `username_taken` (409) when someone has it.
    func setUsername(_ username: String) async throws -> String
    func account() async throws -> RemoteAccount
    func deleteAccount(authKey: Data) async throws

    // Sign-up codes and devices
    func createSignupCode() async throws -> SignupCode
    func signupCodes() async throws -> [OpenSignupCode]
    func revokeSignupCode(id: String) async throws
    func sessions() async throws -> [RemoteDevice]
    /// Signs that device out. It may be this one.
    func revokeSession(id: String) async throws

    func spaces() async throws -> [RemoteSpace]
    func createGroup(id: String, encryptedName: Data, wrappedKey: Data) async throws -> RemoteSpace
    func renameGroup(id: String, encryptedName: Data) async throws
    func deleteGroup(id: String) async throws
    func members(groupId: String) async throws -> [RemoteMember]
    func removeMember(groupId: String, uid: String) async throws

    // Invites
    func createInvite(groupId: String, inviteId: String, sealedKey: Data) async throws
    func invites(groupId: String) async throws -> [PendingInvite]
    func revokeInvite(groupId: String, inviteId: String) async throws
    /// nil when the invite is unknown, used or expired.
    func invite(id: String) async throws -> InviteDetails?
    func acceptInvite(id: String, wrappedKey: Data) async throws -> RemoteSpace

    /// `full` while walking a space from 0 after a reset, so passing the purge horizon doesn't reset again.
    func changes(spaceId: String, since: Int64, limit: Int, full: Bool) async throws -> ChangesPage
    func putItem(spaceId: String, itemId: String, _ body: ItemUpload) async throws -> WriteOutcome
    func deleteItem(spaceId: String, itemId: String, updatedAt: Int64) async throws -> WriteOutcome

    func registerBlob(spaceId: String, blobId: String, size: Int) async throws -> BlobUploadTicket
    func uploadBlob(_ ticket: BlobUploadTicket, data: Data) async throws
    func downloadBlob(spaceId: String, blobId: String) async throws -> Data
}

/// HTTP client for clipboard2-api. `token` returns the session token (auth routes don't use it).
nonisolated struct SyncAPI: SyncService {
    let base: URL
    let transport: any HTTPTransport
    let token: @Sendable () async throws -> String

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    nonisolated private struct Empty: Codable {}
    nonisolated private struct SpacesBody: Codable { var spaces: [RemoteSpace] }
    nonisolated private struct MembersBody: Codable { var members: [RemoteMember] }
    nonisolated private struct SavedBody: Codable { var seq: Int64; var trimmed: [String]? }
    nonisolated private struct ConflictBody: Codable { var current: RemoteItem }
    nonisolated private struct ErrorBody: Codable { var error: String?; var message: String?; var scope: String?; var retryAfter: Int? }
    nonisolated private struct GroupBody: Codable { var id: String; var encryptedName: Data; var wrappedKey: Data }
    nonisolated private struct RenameBody: Codable { var encryptedName: Data }
    nonisolated private struct EmailBody: Codable { var email: String }
    nonisolated private struct PreloginBody: Codable { var kdf: KDFParams }
    nonisolated private struct LoginBody: Codable { var email: String; var authKey: Data; var deviceName: String? }
    nonisolated private struct AuthKeyBody: Codable { var authKey: Data }
    nonisolated private struct InviteBody: Codable { var inviteId: String; var sealedKey: Data }
    nonisolated private struct InvitesBody: Codable { var invites: [PendingInvite] }
    nonisolated private struct AcceptBody: Codable { var wrappedKey: Data }
    nonisolated private struct BlobBody: Codable { var id: String; var size: Int; var ifGenerationMatch = true }
    nonisolated private struct SignupCodesBody: Codable { var codes: [OpenSignupCode] }
    nonisolated private struct SessionsBody: Codable { var sessions: [RemoteDevice] }

    // MARK: Auth and account

    func prelogin(email: String) async throws -> KDFParams {
        try await send("POST", "v1/auth/prelogin", body: EmailBody(email: email), as: PreloginBody.self, authenticated: false).kdf
    }

    func signup(_ body: SignupRequest) async throws -> RemoteSession {
        try await send("POST", "v1/auth/signup", body: body, as: RemoteSession.self, authenticated: false)
    }

    func login(email: String, authKey: Data, deviceName: String?) async throws -> RemoteSession {
        try await send("POST", "v1/auth/login", body: LoginBody(email: email, authKey: authKey, deviceName: deviceName),
                       as: RemoteSession.self, authenticated: false)
    }

    func logout() async throws {
        _ = try await send("POST", "v1/auth/logout", as: Empty.self)
    }

    func changePassword(_ body: PasswordChange) async throws {
        _ = try await send("PUT", "v1/account/password", body: body, as: Empty.self)
    }

    func setUsername(_ username: String) async throws -> String {
        struct Body: Codable { var username: String }
        return try await send("PUT", "v1/account/username", body: Body(username: username), as: Body.self).username
    }

    func account() async throws -> RemoteAccount {
        try await send("GET", "v1/account", as: RemoteAccount.self)
    }

    func deleteAccount(authKey: Data) async throws {
        _ = try await send("DELETE", "v1/account", body: AuthKeyBody(authKey: authKey), as: Empty.self)
    }

    // MARK: Sign-up codes and devices

    func createSignupCode() async throws -> SignupCode {
        try await send("POST", "v1/signup-codes", body: Empty(), as: SignupCode.self)
    }

    func signupCodes() async throws -> [OpenSignupCode] {
        try await send("GET", "v1/signup-codes", as: SignupCodesBody.self).codes
    }

    func revokeSignupCode(id: String) async throws {
        _ = try await send("DELETE", "v1/signup-codes/\(Self.escaped(id))", as: Empty.self)
    }

    func sessions() async throws -> [RemoteDevice] {
        try await send("GET", "v1/sessions", as: SessionsBody.self).sessions
    }

    func revokeSession(id: String) async throws {
        _ = try await send("DELETE", "v1/sessions/\(Self.escaped(id))", as: Empty.self)
    }

    private static func escaped(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? id
    }

    // MARK: Spaces and groups

    func spaces() async throws -> [RemoteSpace] {
        try await send("GET", "v1/spaces", as: SpacesBody.self).spaces
    }

    func createGroup(id: String, encryptedName: Data, wrappedKey: Data) async throws -> RemoteSpace {
        try await send("POST", "v1/groups", body: GroupBody(id: id, encryptedName: encryptedName, wrappedKey: wrappedKey),
                       as: RemoteSpace.self)
    }

    func renameGroup(id: String, encryptedName: Data) async throws {
        _ = try await send("PATCH", "v1/groups/\(id)", body: RenameBody(encryptedName: encryptedName), as: Empty.self)
    }

    func deleteGroup(id: String) async throws {
        _ = try await send("DELETE", "v1/groups/\(id)", as: Empty.self)
    }

    func members(groupId: String) async throws -> [RemoteMember] {
        try await send("GET", "v1/groups/\(groupId)/members", as: MembersBody.self).members
    }

    func removeMember(groupId: String, uid: String) async throws {
        let escaped = uid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? uid
        _ = try await send("DELETE", "v1/groups/\(groupId)/members/\(escaped)", as: Empty.self)
    }

    // MARK: Invites

    func createInvite(groupId: String, inviteId: String, sealedKey: Data) async throws {
        _ = try await send("POST", "v1/groups/\(groupId)/invites", body: InviteBody(inviteId: inviteId, sealedKey: sealedKey),
                           as: Empty.self)
    }

    func invites(groupId: String) async throws -> [PendingInvite] {
        try await send("GET", "v1/groups/\(groupId)/invites", as: InvitesBody.self).invites
    }

    func revokeInvite(groupId: String, inviteId: String) async throws {
        _ = try await send("DELETE", "v1/groups/\(groupId)/invites/\(inviteId)", as: Empty.self)
    }

    func invite(id: String) async throws -> InviteDetails? {
        do {
            return try await send("GET", "v1/invites/\(id)", as: InviteDetails.self)
        } catch SyncAPIError.server(404, _, _, _, _) {
            return nil
        }
    }

    func acceptInvite(id: String, wrappedKey: Data) async throws -> RemoteSpace {
        try await send("POST", "v1/invites/\(id)/accept", body: AcceptBody(wrappedKey: wrappedKey), as: RemoteSpace.self)
    }

    // MARK: Items

    func changes(spaceId: String, since: Int64, limit: Int, full: Bool) async throws -> ChangesPage {
        try await send("GET", "v1/spaces/\(spaceId)/changes", query: ["since": "\(since)", "limit": "\(limit)"].merging(full ? ["full": "1"] : [:]) { a, _ in a },
                       as: ChangesPage.self)
    }

    func putItem(spaceId: String, itemId: String, _ body: ItemUpload) async throws -> WriteOutcome {
        do {
            let saved = try await send("PUT", "v1/spaces/\(spaceId)/items/\(itemId)", body: body, as: SavedBody.self)
            return .saved(seq: saved.seq, trimmed: saved.trimmed ?? [])
        } catch let ConflictError.current(item) {
            return .conflict(item)
        }
    }

    func deleteItem(spaceId: String, itemId: String, updatedAt: Int64) async throws -> WriteOutcome {
        do {
            let saved = try await send("DELETE", "v1/spaces/\(spaceId)/items/\(itemId)",
                                       query: ["updatedAt": "\(updatedAt)"], as: SavedBody.self)
            return .saved(seq: saved.seq, trimmed: [])
        } catch let ConflictError.current(item) {
            return .conflict(item)
        }
    }

    // MARK: Blobs

    func registerBlob(spaceId: String, blobId: String, size: Int) async throws -> BlobUploadTicket {
        try await send("POST", "v1/spaces/\(spaceId)/blobs", body: BlobBody(id: blobId, size: size), as: BlobUploadTicket.self)
    }

    /// PUT to the signed GCS URL with exactly the headers the server returned.
    static let generationMatchHeader = "x-goog-if-generation-match"

    func uploadBlob(_ ticket: BlobUploadTicket, data: Data) async throws {
        var request = URLRequest(url: ticket.url)
        request.httpMethod = ticket.method
        for (name, value) in ticket.headers { request.setValue(value, forHTTPHeaderField: name) }
        // Registered with `ifGenerationMatch`: the signed URL requires this, so a blob is never overwritten.
        if request.value(forHTTPHeaderField: Self.generationMatchHeader) == nil {
            request.setValue("0", forHTTPHeaderField: Self.generationMatchHeader)
        }
        request.httpBody = data
        request.timeoutInterval = 120
        let (_, response) = try await perform(request)
        // 412: this blob id is already uploaded, which is all we wanted.
        guard (200..<300).contains(response.statusCode) || response.statusCode == 412 else {
            throw SyncAPIError.server(status: response.statusCode, code: "upload_failed", message: "Blob upload failed", retryAfter: nil)
        }
    }

    func downloadBlob(spaceId: String, blobId: String) async throws -> Data {
        let ticket = try await send("GET", "v1/spaces/\(spaceId)/blobs/\(blobId)", as: BlobDownloadTicket.self)
        var request = URLRequest(url: ticket.url)
        request.timeoutInterval = 120
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw SyncAPIError.server(status: response.statusCode, code: "download_failed", message: "Blob download failed", retryAfter: nil)
        }
        return data
    }

    // MARK: Plumbing

    nonisolated private enum ConflictError: Error {
        case current(RemoteItem)
    }

    /// Builds an API request (public so tests can check paths, queries and bodies).
    func makeRequest(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil,
                     token: String?) -> URLRequest {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // `+` survives URLComponents unescaped and would read as a space on the server.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 60
        return request
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:],
                                    as type: T.Type) async throws -> T {
        try await send(method, path, query: query, bodyData: nil, as: type, authenticated: true)
    }

    private func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:],
                                                  body: B, as type: T.Type, authenticated: Bool = true) async throws -> T {
        try await send(method, path, query: query, bodyData: try Self.encoder.encode(body), as: type,
                       authenticated: authenticated)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [String: String],
                                    bodyData: Data?, as type: T.Type, authenticated: Bool) async throws -> T {
        let request = makeRequest(method, path, query: query, body: bodyData,
                                  token: authenticated ? try await token() : nil)
        let (data, response) = try await perform(request)
        let status = response.statusCode
        if status == 409, let conflict = try? Self.decoder.decode(ConflictBody.self, from: data) {
            throw ConflictError.current(conflict.current)
        }
        guard (200..<300).contains(status) else {
            let body = try? Self.decoder.decode(ErrorBody.self, from: data)
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) ?? body?.retryAfter
            throw SyncAPIError.server(status: status, code: body?.error ?? (status == 429 ? "rate_limited" : "http_\(status)"),
                                      message: body?.message ?? "", retryAfter: retryAfter, scope: body?.scope)
        }
        if status == 204 || data.isEmpty, let empty = Empty() as? T { return empty }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw SyncAPIError.invalidResponse
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            throw SyncAPIError.network(error.localizedDescription)
        }
    }
}
