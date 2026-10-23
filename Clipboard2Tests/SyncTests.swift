import Testing
import Foundation
import SwiftData
@testable import Clipboard2

// MARK: - Crypto vectors (docs/sync/test-vectors.json)

private enum Vectors {
    static let json: [String: Any] = {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/sync/test-vectors.json")
        let data = (try? Data(contentsOf: url)) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }()

    static func section(_ name: String) -> [String: Any] { json[name] as? [String: Any] ?? [:] }
    static func list(_ name: String) -> [[String: Any]] { json[name] as? [[String: Any]] ?? [] }
}

private extension Dictionary where Key == String, Value == Any {
    func bytes(_ key: String) -> Data { Data(base64Encoded: self[key] as? String ?? "") ?? Data([0xFF]) }
    func string(_ key: String) -> String { self[key] as? String ?? "" }
    func int(_ key: String) -> Int { self[key] as? Int ?? 0 }
}

struct SyncCryptoVectorTests {
    @Test func vectorFileLoads() {
        #expect(!Vectors.list("pbkdf2").isEmpty)
        #expect(!Vectors.list("aead").isEmpty)
    }

    @Test func pbkdf2() throws {
        for v in Vectors.list("pbkdf2") {
            let kek = try SyncCrypto.kek(password: v.string("password"), salt: v.bytes("salt"), iterations: v.int("iterations"))
            #expect(kek == v.bytes("kek"), "password \(v.string("password"))")
        }
    }

    @Test func aeadSealAndOpen() throws {
        for v in Vectors.list("aead") {
            let sealed = try SyncCrypto.seal(v.bytes("plaintext"), key: v.bytes("key"), aad: v.string("aad"), nonce: v.bytes("nonce"))
            #expect(sealed == v.bytes("sealed"))
            #expect(try SyncCrypto.open(v.bytes("sealed"), key: v.bytes("key"), aad: v.string("aad")) == v.bytes("plaintext"))
        }
    }

    @Test func aeadRejectsTamperingWrongAADAndVersion() throws {
        let v = try #require(Vectors.list("aead").first)
        var tampered = v.bytes("sealed")
        tampered[tampered.count - 1] ^= 0x01
        #expect(throws: (any Error).self) { try SyncCrypto.open(tampered, key: v.bytes("key"), aad: v.string("aad")) }
        #expect(throws: (any Error).self) { try SyncCrypto.open(v.bytes("sealed"), key: v.bytes("key"), aad: "other") }
        var version = v.bytes("sealed")
        version[0] = 0x02
        #expect(throws: SyncCryptoError.badEnvelope) { try SyncCrypto.open(version, key: v.bytes("key"), aad: v.string("aad")) }
    }

    @Test func hkdf() {
        for v in Vectors.list("hkdf") {
            #expect(SyncCrypto.hkdf(v.bytes("ikm"), salt: v.bytes("salt"), info: v.string("info")) == v.bytes("okm"))
        }
    }

    @Test func ecdh() throws {
        let v = Vectors.section("ecdh")
        #expect(try SyncCrypto.publicKey(of: v.bytes("privA")) == v.bytes("pubA"))
        #expect(try SyncCrypto.publicKey(of: v.bytes("privB")) == v.bytes("pubB"))
        #expect(try SyncCrypto.ecdh(privateKey: v.bytes("privA"), publicKey: v.bytes("pubB")) == v.bytes("shared"))
        #expect(try SyncCrypto.ecdh(privateKey: v.bytes("privB"), publicKey: v.bytes("pubA")) == v.bytes("shared"))
    }

    @Test func passwordKeysAndAccountKeys() throws {
        let v = Vectors.section("account")
        let uid = v.string("uid")
        let keys = try SyncCrypto.passwordKeys(password: v.string("password"), salt: v.bytes("salt"), iterations: v.int("iterations"))
        #expect(keys.master == v.bytes("master"))
        #expect(keys.authKey == v.bytes("authKey"))
        #expect(keys.wrapKey == v.bytes("wrapKey"))
        let wrapKey = keys.wrapKey
        let wrappedAK = try SyncCrypto.seal(v.bytes("accountKey"), key: wrapKey, aad: SyncCrypto.AAD.accountKey(uid: uid), nonce: v.bytes("akNonce"))
        #expect(wrappedAK == v.bytes("wrappedAccountKey"))
        #expect(try SyncCrypto.open(v.bytes("wrappedAccountKey"), key: wrapKey, aad: SyncCrypto.AAD.accountKey(uid: uid)) == v.bytes("accountKey"))
        #expect(try SyncCrypto.publicKey(of: v.bytes("idPriv")) == v.bytes("idPub"))
        let wrappedPriv = try SyncCrypto.seal(v.bytes("idPriv"), key: v.bytes("accountKey"), aad: SyncCrypto.AAD.privateKey(uid: uid),
                                              nonce: v.bytes("privNonce"))
        #expect(wrappedPriv == v.bytes("wrappedPrivateKey"))
        #expect(try SyncCrypto.open(v.bytes("wrappedPrivateKey"), key: v.bytes("accountKey"), aad: SyncCrypto.AAD.privateKey(uid: uid))
                == v.bytes("idPriv"))
    }

    @Test func spaceKeyWrap() throws {
        let v = Vectors.section("spaceWrap")
        #expect(try SyncCrypto.publicKey(of: v.bytes("ephPriv")) == v.bytes("ephPub"))
        let wrapped = try SyncCrypto.wrapSpaceKey(v.bytes("spaceKey"), spaceId: v.string("spaceId"), memberUid: v.string("memberUid"),
                                                  memberPublicKey: v.bytes("memberPub"), ephemeralPrivateKey: v.bytes("ephPriv"),
                                                  nonce: v.bytes("nonce"))
        #expect(wrapped == v.bytes("wrappedKey"))
        let unwrapped = try SyncCrypto.unwrapSpaceKey(v.bytes("wrappedKey"), spaceId: v.string("spaceId"), uid: v.string("memberUid"),
                                                      privateKey: v.bytes("memberPriv"))
        #expect(unwrapped == v.bytes("spaceKey"))
        // A fresh ephemeral key still unwraps.
        let fresh = try SyncCrypto.wrapSpaceKey(v.bytes("spaceKey"), spaceId: v.string("spaceId"), memberUid: v.string("memberUid"),
                                                memberPublicKey: v.bytes("memberPub"))
        #expect(try SyncCrypto.unwrapSpaceKey(fresh, spaceId: v.string("spaceId"), uid: v.string("memberUid"),
                                              privateKey: v.bytes("memberPriv")) == v.bytes("spaceKey"))
    }

    @Test func itemEncryption() throws {
        let v = Vectors.section("item")
        let itemKey = SyncCrypto.itemKey(spaceKey: v.bytes("spaceKey"))
        #expect(itemKey == v.bytes("itemKey"))
        let aad = SyncCrypto.AAD.item(spaceId: v.string("spaceId"), itemId: v.string("itemId"), category: v.string("category"))
        let payload = Data(v.string("payload").utf8)
        #expect(try SyncCrypto.seal(payload, key: itemKey, aad: aad, nonce: v.bytes("nonce")) == v.bytes("ciphertext"))
        #expect(try SyncCrypto.open(v.bytes("ciphertext"), key: itemKey, aad: aad) == payload)
    }

    @Test func blobEncryption() throws {
        let v = Vectors.section("blob")
        let itemKey = Vectors.section("item").bytes("itemKey")
        let aad = SyncCrypto.AAD.blob(spaceId: v.string("spaceId"), blobId: v.string("blobId"))
        #expect(try SyncCrypto.seal(v.bytes("plaintext"), key: itemKey, aad: aad, nonce: v.bytes("nonce")) == v.bytes("ciphertext"))
        #expect(try SyncCrypto.open(v.bytes("ciphertext"), key: itemKey, aad: aad) == v.bytes("plaintext"))
    }

    @Test func groupName() throws {
        let v = Vectors.section("groupName")
        let spaceKey = Vectors.section("spaceWrap").bytes("spaceKey")
        #expect(SyncCrypto.nameKey(spaceKey: spaceKey) == v.bytes("nameKey"))
        #expect(try SyncCrypto.encryptGroupName(v.string("name"), spaceKey: spaceKey, spaceId: v.string("spaceId"), nonce: v.bytes("nonce"))
                == v.bytes("encryptedName"))
        #expect(try SyncCrypto.decryptGroupName(v.bytes("encryptedName"), spaceKey: spaceKey, spaceId: v.string("spaceId")) == v.string("name"))
    }
}

struct InviteCodeVectorTests {
    let v = Vectors.section("invite")

    @Test func codeFormat() {
        #expect(SyncCrypto.Invite.format(v.bytes("codeBytes")) == v.string("code"))
    }

    @Test func lenientParsing() throws {
        #expect(SyncCrypto.Invite.parse(v.string("code")) == v.bytes("codeBytes"))
        for typed in v["typedVariants"] as? [String] ?? [] {
            #expect(SyncCrypto.Invite.parse(typed) == v.bytes("codeBytes"), "\(typed)")
        }
    }

    @Test func invalidCodesAreRejected() {
        let invalid = v["invalidCodes"] as? [String] ?? []
        #expect(!invalid.isEmpty)
        for typed in invalid {
            #expect(SyncCrypto.Invite.parse(typed) == nil, "\(typed)")
        }
        // Non-zero spare bits: the last character must encode two trailing zero bits.
        #expect(SyncCrypto.Invite.parse(String(v.string("code").dropLast()) + "B") == nil)
    }

    @Test func confusablesMapToLetters() throws {
        let code = Data(repeating: 0, count: 16)
        // Typed 0 and 1 are read as O and I.
        let formatted = SyncCrypto.Invite.format(Data([0x73, 0x10, 0x40] + Array(repeating: 0, count: 13)))
        #expect(formatted.hasPrefix("OMIE"))
        let typed = formatted.replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "I", with: "1")
        #expect(SyncCrypto.Invite.parse(typed) == Data([0x73, 0x10, 0x40] + Array(repeating: 0, count: 13)))
        #expect(SyncCrypto.Invite.parse(SyncCrypto.Invite.format(code)) == code)
        let random = SyncCrypto.Invite.newCode()
        #expect(SyncCrypto.Invite.parse(SyncCrypto.Invite.format(random)) == random)
    }

    @Test func inviteIdKeyAndSealedKey() throws {
        let code = v.bytes("codeBytes")
        #expect(SyncCrypto.Invite.id(code) == v.string("inviteId"))
        #expect(SyncCrypto.Invite.key(code) == v.bytes("inviteKey"))
        let sealed = try SyncCrypto.Invite.sealSpaceKey(v.bytes("spaceKey"), code: code, spaceId: v.string("spaceId"), nonce: v.bytes("nonce"))
        #expect(sealed == v.bytes("sealedKey"))
        #expect(try SyncCrypto.Invite.openSpaceKey(v.bytes("sealedKey"), code: code, spaceId: v.string("spaceId")) == v.bytes("spaceKey"))
    }
}

// MARK: - Payloads

@MainActor
struct SyncPayloadTests {
    let container: ModelContainer
    let store: ClipStore

    init() throws {
        container = try ModelContainer(for: AppEnvironment.schema,
                                       configurations: ModelConfiguration(schema: AppEnvironment.schema, isStoredInMemoryOnly: true))
        store = ClipStore(context: container.mainContext,
                          blobs: BlobStore(directory: FileManager.default.temporaryDirectory.appending(path: "SyncPayload-\(UUID())")))
    }

    @Test func vectorPayloadDecodesIntoAClip() throws {
        let json = Data(Vectors.section("item").string("payload").utf8)
        guard case .clip(let clip) = try SyncPayload.decode(json) else {
            Issue.record("not a clip")
            return
        }
        #expect(clip.text == "Grüße aus Wien 👋")
        #expect(clip.copyCount == 2)
        #expect(clip.category == .history)
        let item = ClipItem(syncID: UUID(), spaceID: nil)
        clip.apply(to: item)
        #expect(item.kind == .text)
        #expect(item.sourceAppName == "Safari")
        #expect(item.lastCopiedAt.syncMillis == 1_792_400_400_000)
        #expect(item.contentHash == clip.contentHash)
    }

    @Test func clipRoundTripKeepsEveryField() throws {
        let item = store.ingest(.text("Round trip", rtf: Data("{\\rtf1 x}".utf8), source: AppRef(bundleID: "com.apple.Notes", name: "Notes")),
                                now: Date(timeIntervalSince1970: 1_700_000_000.123))
        store.setLabel("A label", for: item)
        item.copyCount = 7
        let payload = SyncPayload.clip(ClipPayload(item: item))
        let decoded = try SyncPayload.decode(payload.canonicalJSON())
        #expect(decoded == payload)

        guard case .clip(let clip) = decoded else { return }
        let copy = ClipItem(syncID: item.id, spaceID: nil)
        clip.apply(to: copy)
        #expect(SyncPayload.clip(ClipPayload(item: copy)) == payload)
        #expect(copy.kind == .richText && copy.rtfData == item.rtfData && copy.isPinned && copy.label == "A label")
        #expect(try SyncPayload.clip(ClipPayload(item: copy)).fingerprint() == payload.fingerprint())
    }

    @Test func snippetAndSecretRoundTrip() throws {
        let snippet = SyncPayload.snippet(SnippetPayload(name: "Sig", keyword: ";sig", body: "Best,\n{name}", createdAt: 1, updatedAt: 2))
        #expect(try SyncPayload.decode(snippet.canonicalJSON()) == snippet)
        let secret = SyncPayload.secret(SecretPayload(name: "DB", value: "hunter2/ü", createdAt: 3))
        #expect(try SyncPayload.decode(secret.canonicalJSON()) == secret)
        #expect(secret.category == .secret)
    }

    @Test func canonicalJSONIsStableSortedAndOmitsNulls() throws {
        let payload = SyncPayload.clip(ClipPayload(kind: "text", text: "a/b", preview: "a/b", createdAt: 1, lastCopiedAt: 2, contentHash: "text:x"))
        let first = try payload.canonicalJSON()
        #expect(first == (try payload.canonicalJSON()))
        let string = String(decoding: first, as: UTF8.self)
        #expect(string.hasPrefix("{\"contentHash\""))
        #expect(string.contains("a/b"))           // slashes aren't escaped
        #expect(!string.contains("null") && !string.contains("label"))
        #expect(try payload.fingerprint() == SyncCrypto.sha256Hex(first))
    }

    @Test func readersIgnoreUnknownFieldsAndToleratemissingOnes() throws {
        let json = Data(#"{"v":1,"type":"clip","kind":"file","files":["file:///tmp/a.txt"],"future":true,"createdAt":5}"#.utf8)
        guard case .clip(let clip) = try SyncPayload.decode(json) else { return }
        let item = ClipItem(syncID: UUID(), spaceID: "g")
        clip.apply(to: item)
        // Paths sync as metadata only: they arrive as text.
        #expect(item.kind == .text)
        #expect(item.text == "/tmp/a.txt")
        #expect(item.copyCount == 1)
        #expect(throws: SyncPayloadError.unknownType("note")) { try SyncPayload.decode(Data(#"{"type":"note"}"#.utf8)) }
    }

    @Test func oversizedRichTextIsDroppedForPush() {
        var payload = ClipPayload(kind: "richText", text: "x", createdAt: 0, lastCopiedAt: 0, contentHash: "text:x")
        payload.rtf = Data(count: 10)
        let plain = payload.withoutRichText
        #expect(plain.kind == "text" && plain.rtf == nil)
    }
}

// MARK: - HTTP clients

nonisolated final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    let status: Int
    let body: String

    init(status: Int = 200, body: String = "{}") {
        self.status = status
        self.body = body
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "7"])!
        return (Data(body.utf8), response)
    }
}

struct SyncAPITests {
    let api = SyncAPI(base: URL(string: "https://api.example")!, transport: StubTransport()) { "TOKEN" }

    @Test func requestsCarryBearerTokenAndEncodedQuery() {
        let request = api.makeRequest("GET", "v1/things", query: ["q": "a+b@c.at"], token: "T")
        #expect(request.url?.absoluteString == "https://api.example/v1/things?q=a%2Bb@c.at")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer T")
        let changes = api.makeRequest("GET", "v1/spaces/s1/changes", query: ["since": "3", "limit": "500"], token: "T")
        #expect(changes.url?.absoluteString == "https://api.example/v1/spaces/s1/changes?limit=500&since=3")
    }

    @Test func conflictReturnsCurrentItem() async throws {
        let body = #"{"error":"conflict","message":"A newer version exists","current":{"id":"i","category":"snippet","seq":9,"sortAt":1,"updatedAt":5,"deleted":null,"ciphertext":"AQ==","blobIds":[],"authorUid":"u"}}"#
        let api = SyncAPI(base: URL(string: "https://api.example")!, transport: StubTransport(status: 409, body: body)) { "T" }
        let outcome = try await api.putItem(spaceId: "s", itemId: "i", ItemUpload(category: "snippet", sortAt: 1, updatedAt: 1, ciphertext: Data([1]), blobIds: []))
        guard case .conflict(let current) = outcome else {
            Issue.record("expected a conflict")
            return
        }
        #expect(current.seq == 9 && current.updatedAt == 5)
    }

    @Test func errorsCarryCodeAndRetryAfter() async {
        let api = SyncAPI(base: URL(string: "https://api.example")!,
                          transport: StubTransport(status: 429, body: #"{"error":"rate_limited","message":"slow down"}"#)) { "T" }
        do {
            _ = try await api.spaces()
            Issue.record("expected an error")
        } catch let error as SyncAPIError {
            #expect(error == .server(status: 429, code: "rate_limited", message: "slow down", retryAfter: 7))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func authRoutesSendNoTokenAndOnlyTheAuthKey() async throws {
        let transport = StubTransport(body: #"{"kdf":{"alg":"pbkdf2-sha256","salt":"AAECAwQFBgcICQoLDA0ODw==","iterations":600000}}"#)
        let api = SyncAPI(base: URL(string: "https://api.example")!, transport: transport) {
            Issue.record("auth routes must not ask for a token")
            return "T"
        }
        let kdf = try await api.prelogin(email: "a@b.at")
        #expect(kdf.iterations == 600_000 && kdf.salt.count == 16)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.example/v1/auth/prelogin")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func unknownInviteIsNil() async throws {
        let api = SyncAPI(base: URL(string: "https://api.example")!,
                          transport: StubTransport(status: 404, body: #"{"error":"not_found","message":"Not found"}"#)) { "T" }
        #expect(try await api.invite(id: "abc") == nil)
    }

    @Test func emailsAreTrimmedAndLowercased() {
        #expect(SyncAccount.normalize(email: "  Alice@Example.COM \n") == "alice@example.com")
    }
}

// MARK: - In-memory server

/// Mirrors the server's rules: global seq, last-write-wins on `updatedAt` (tombstones included),
/// registered blobs, and trimming history to the newest `historyLimit` after each history upsert.
actor FakeSyncServer {
    struct Space {
        var id: String
        var kind: String
        var owner: String
        var encryptedName: Data?
        var members: [String: (role: String, wrappedKey: Data)]
        var createdAt: Int64
    }

    struct Account {
        var uid: String
        var email: String
        var authKey: Data
        var kdf: KDFParams
        var wrappedAccountKey: Data
        var publicKey: Data
        var wrappedPrivateKey: Data
        var personalSpaceId: String
        var username: String?

        var remote: RemoteAccount {
            RemoteAccount(uid: uid, email: email, kdf: kdf, wrappedAccountKey: wrappedAccountKey, publicKey: publicKey,
                          wrappedPrivateKey: wrappedPrivateKey, personalSpaceId: personalSpaceId, username: username)
        }

        var displayName: String { username ?? String(email.prefix { $0 != "@" }) }
    }

    struct Invite {
        var space: String
        var sealedKey: Data
        var createdAt: Int64
        var used = false
    }

    private(set) var accounts: [String: Account] = [:]      // by email
    private var tokens: [String: String] = [:]               // token → uid
    private var invites: [String: Invite] = [:]
    private(set) var spaces: [String: Space] = [:]
    private var items: [String: [String: RemoteItem]] = [:]
    private var blobs: [String: Data] = [:]
    private var registered: Set<String> = []
    private(set) var seq: Int64 = 0
    let historyLimit = 200
    private(set) var putCount = 0
    /// false behaves like a server from before usernames: no `members` in the space list.
    var listsMembers = true

    func setListsMembers(_ value: Bool) { listsMembers = value }

    static func usernameTaken() -> SyncAPIError {
        .server(status: 409, code: "username_taken", message: "", retryAfter: nil)
    }

    private func isTaken(_ username: String, except uid: String? = nil) -> Bool {
        accounts.values.contains { $0.uid != uid && $0.username?.lowercased() == username.lowercased() }
    }

    func setUsername(uid: String, _ username: String) throws -> String {
        guard !isTaken(username, except: uid) else { throw Self.usernameTaken() }
        guard let email = accounts.first(where: { $0.value.uid == uid })?.key else { throw Self.unauthenticated() }
        accounts[email]?.username = username
        return username
    }

    // MARK: Auth

    static func unauthenticated() -> SyncAPIError {
        .server(status: 401, code: "unauthenticated", message: "", retryAfter: nil)
    }

    func issueToken(for uid: String) -> String {
        let token = "token-\(uid)-\(UUID().uuidString)"
        tokens[token] = uid
        return token
    }

    func uid(forToken token: String) throws -> String {
        guard let uid = tokens[token] else { throw Self.unauthenticated() }
        return uid
    }

    func prelogin(email: String) -> KDFParams {
        accounts[email]?.kdf ?? KDFParams(salt: Data(SHA256Fake.bytes(email).prefix(16)), iterations: 600_000)
    }

    func signup(_ body: SignupRequest) throws -> RemoteSession {
        guard accounts[body.email] == nil else { throw SyncAPIError.server(status: 409, code: "conflict", message: "", retryAfter: nil) }
        if let name = body.username, isTaken(name) { throw Self.usernameTaken() }
        let account = Account(uid: body.uid, email: body.email, authKey: body.authKey, kdf: body.kdf,
                              wrappedAccountKey: body.wrappedAccountKey, publicKey: body.publicKey,
                              wrappedPrivateKey: body.wrappedPrivateKey, personalSpaceId: body.personalSpace.id,
                              username: body.username)
        accounts[body.email] = account
        createSpace(id: body.personalSpace.id, kind: "personal", owner: body.uid, wrappedKey: body.personalSpace.wrappedKey)
        return RemoteSession(token: issueToken(for: body.uid), expiresAt: nil, account: account.remote)
    }

    func login(email: String, authKey: Data) throws -> RemoteSession {
        guard let account = accounts[email], account.authKey == authKey else {
            throw SyncAPIError.server(status: 401, code: "invalid_credentials", message: "", retryAfter: nil)
        }
        return RemoteSession(token: issueToken(for: account.uid), expiresAt: nil, account: account.remote)
    }

    func logout(token: String) { tokens[token] = nil }

    private func account(uid: String) throws -> Account {
        guard let account = accounts.values.first(where: { $0.uid == uid }) else {
            throw SyncAPIError.server(status: 404, code: "no_account", message: "", retryAfter: nil)
        }
        return account
    }

    func remoteAccount(uid: String) throws -> RemoteAccount { try account(uid: uid).remote }

    func changePassword(uid: String, token: String, _ body: PasswordChange) throws {
        var account = try account(uid: uid)
        guard account.authKey == body.authKey else {
            throw SyncAPIError.server(status: 401, code: "invalid_credentials", message: "", retryAfter: nil)
        }
        account.authKey = body.newAuthKey
        account.kdf = body.kdf
        account.wrappedAccountKey = body.wrappedAccountKey
        accounts[account.email] = account
        tokens = tokens.filter { $0.value != uid || $0.key == token }   // other sessions end
    }

    func deleteAccount(uid: String, authKey: Data) throws {
        let account = try account(uid: uid)
        guard account.authKey == authKey else {
            throw SyncAPIError.server(status: 401, code: "invalid_credentials", message: "", retryAfter: nil)
        }
        accounts[account.email] = nil
        tokens = tokens.filter { $0.value != uid }
        for (id, space) in spaces where space.owner == uid { spaces[id] = nil }
        for id in spaces.keys { spaces[id]?.members[uid] = nil }
    }

    // MARK: Invites

    func createInvite(uid: String, group: String, inviteId: String, sealedKey: Data) throws {
        guard spaces[group]?.owner == uid else { throw SyncAPIError.server(status: 403, code: "forbidden", message: "", retryAfter: nil) }
        invites[inviteId] = Invite(space: group, sealedKey: sealedKey, createdAt: Int64(invites.count))
    }

    func pendingInvites(group: String) -> [PendingInvite] {
        invites.filter { $0.value.space == group && !$0.value.used }
            .map { PendingInvite(inviteId: $0.key, createdAt: $0.value.createdAt, expiresAt: Date.now.addingTimeInterval(7 * 86_400).syncMillis) }
    }

    func revokeInvite(group: String, inviteId: String) {
        if invites[inviteId]?.space == group { invites[inviteId] = nil }
    }

    func invite(id: String) -> InviteDetails? {
        guard let invite = invites[id], !invite.used, let space = spaces[invite.space] else { return nil }
        return InviteDetails(spaceId: space.id, sealedKey: invite.sealedKey, encryptedName: space.encryptedName,
                             memberCount: space.members.count, expiresAt: Date.now.addingTimeInterval(86_400).syncMillis)
    }

    func accept(uid: String, inviteId: String, wrappedKey: Data) throws -> RemoteSpace {
        guard var invite = invites[inviteId], !invite.used, spaces[invite.space] != nil else {
            throw SyncAPIError.server(status: 404, code: "not_found", message: "", retryAfter: nil)
        }
        guard spaces[invite.space]?.members[uid] == nil else {
            throw SyncAPIError.server(status: 409, code: "conflict", message: "", retryAfter: nil)
        }
        invite.used = true
        invites[inviteId] = invite
        spaces[invite.space]?.members[uid] = ("member", wrappedKey)
        guard let space = spaces(for: uid).first(where: { $0.id == invite.space }) else { throw Self.unauthenticated() }
        return space
    }

    // MARK: Spaces

    func createSpace(id: String, kind: String, owner: String, wrappedKey: Data, encryptedName: Data? = nil) {
        spaces[id] = Space(id: id, kind: kind, owner: owner, encryptedName: encryptedName,
                           members: [owner: ("owner", wrappedKey)], createdAt: Int64(spaces.count))
    }

    func addMember(space: String, uid: String, wrappedKey: Data) {
        spaces[space]?.members[uid] = ("member", wrappedKey)
    }

    func removeMember(space: String, uid: String) {
        spaces[space]?.members[uid] = nil
    }

    func spaces(for uid: String) -> [RemoteSpace] {
        spaces.values.compactMap { space in
            guard let member = space.members[uid] else { return nil }
            let names = space.members.keys.sorted().compactMap { uid in
                accounts.values.first { $0.uid == uid }.map { MemberName(uid: uid, name: $0.displayName) }
            }
            return RemoteSpace(id: space.id, kind: space.kind, role: member.role, ownerUid: space.owner,
                               wrappedKey: member.wrappedKey, encryptedName: space.encryptedName,
                               memberCount: space.members.count, createdAt: space.createdAt,
                               members: listsMembers ? names : nil)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func changes(space: String, since: Int64, limit: Int) -> ChangesPage {
        let all = (items[space] ?? [:]).values.filter { $0.seq > since }.sorted { $0.seq < $1.seq }
        let page = Array(all.prefix(limit))
        return ChangesPage(items: page, nextSince: page.last?.seq ?? since, hasMore: all.count > limit, resetRequired: false)
    }

    func put(space: String, id: String, body: ItemUpload, uid: String) throws -> WriteOutcome {
        guard spaces[space]?.members[uid] != nil else { throw SyncAPIError.server(status: 404, code: "not_found", message: "", retryAfter: nil) }
        if let existing = items[space]?[id], existing.updatedAt > body.updatedAt { return .conflict(existing) }
        for blob in body.blobIds where !registered.contains("\(space)/\(blob)") {
            throw SyncAPIError.server(status: 400, code: "invalid", message: "Upload the item's blobs first", retryAfter: nil)
        }
        putCount += 1
        seq += 1
        items[space, default: [:]][id] = RemoteItem(id: id, category: body.category, seq: seq, sortAt: body.sortAt,
                                                    updatedAt: body.updatedAt, deleted: nil, ciphertext: body.ciphertext,
                                                    blobIds: body.blobIds, authorUid: uid)
        var trimmed: [String] = []
        if body.category == "history" {
            let live = (items[space] ?? [:]).values.filter { $0.category == "history" && $0.deleted == nil }
                .sorted { $0.sortAt != $1.sortAt ? $0.sortAt > $1.sortAt : $0.id > $1.id }
            for doomed in live.dropFirst(historyLimit) {
                markDeleted(space: space, id: doomed.id, kind: "trimmed")
                trimmed.append(doomed.id)
            }
        }
        return .saved(seq: seq, trimmed: trimmed)
    }

    func delete(space: String, id: String, updatedAt: Int64) -> WriteOutcome {
        guard let existing = items[space]?[id] else { return .saved(seq: 0, trimmed: []) }
        if existing.deleted == "user" { return .saved(seq: existing.seq, trimmed: []) }
        if existing.deleted == nil && existing.updatedAt > updatedAt { return .conflict(existing) }
        markDeleted(space: space, id: id, kind: "user", updatedAt: max(existing.updatedAt, updatedAt))
        return .saved(seq: seq, trimmed: [])
    }

    private func markDeleted(space: String, id: String, kind: String, updatedAt: Int64? = nil) {
        guard var item = items[space]?[id] else { return }
        seq += 1
        item.seq = seq
        item.deleted = kind
        item.ciphertext = nil
        for blob in item.blobIds { blobs["\(space)/\(blob)"] = nil }
        item.blobIds = []
        if let updatedAt { item.updatedAt = updatedAt }
        items[space]?[id] = item
    }

    func register(space: String, blob: String) -> BlobUploadTicket {
        registered.insert("\(space)/\(blob)")
        return BlobUploadTicket(url: URL(string: "fake://\(space)/\(blob)")!, method: "PUT", headers: [:], expiresAt: nil)
    }

    func upload(_ ticket: BlobUploadTicket, data: Data) {
        blobs[(ticket.url.host() ?? "") + ticket.url.path()] = data
    }

    func download(space: String, blob: String) throws -> Data {
        guard let data = blobs["\(space)/\(blob)"] else {
            throw SyncAPIError.server(status: 404, code: "not_found", message: "", retryAfter: nil)
        }
        return data
    }

    // MARK: Inspection

    func live(space: String) -> [RemoteItem] {
        (items[space] ?? [:]).values.filter { $0.deleted == nil }
    }

    func item(space: String, id: String) -> RemoteItem? { items[space]?[id] }
}

/// One signed-in client of the fake server; the token decides who the caller is.
nonisolated struct FakeClient: SyncService {
    let server: FakeSyncServer
    let token: @Sendable () async throws -> String

    private func caller() async throws -> String { try await server.uid(forToken: try await token()) }

    func prelogin(email: String) async throws -> KDFParams { await server.prelogin(email: email) }
    func signup(_ body: SignupRequest) async throws -> RemoteSession { try await server.signup(body) }
    func login(email: String, authKey: Data, deviceName: String?) async throws -> RemoteSession {
        try await server.login(email: email, authKey: authKey)
    }
    func logout() async throws { await server.logout(token: try await token()) }
    func changePassword(_ body: PasswordChange) async throws {
        try await server.changePassword(uid: try await caller(), token: try await token(), body)
    }
    func account() async throws -> RemoteAccount { try await server.remoteAccount(uid: try await caller()) }
    func setUsername(_ username: String) async throws -> String { try await server.setUsername(uid: try await caller(), username) }
    func deleteAccount(authKey: Data) async throws { try await server.deleteAccount(uid: try await caller(), authKey: authKey) }

    func spaces() async throws -> [RemoteSpace] { await server.spaces(for: try await caller()) }
    func createGroup(id: String, encryptedName: Data, wrappedKey: Data) async throws -> RemoteSpace {
        let uid = try await caller()
        await server.createSpace(id: id, kind: "group", owner: uid, wrappedKey: wrappedKey, encryptedName: encryptedName)
        return try #require(await server.spaces(for: uid).first { $0.id == id })
    }
    func renameGroup(id: String, encryptedName: Data) async throws {}
    func deleteGroup(id: String) async throws {}
    func members(groupId: String) async throws -> [RemoteMember] { [] }
    func removeMember(groupId: String, uid: String) async throws { await server.removeMember(space: groupId, uid: uid) }

    func createInvite(groupId: String, inviteId: String, sealedKey: Data) async throws {
        try await server.createInvite(uid: try await caller(), group: groupId, inviteId: inviteId, sealedKey: sealedKey)
    }
    func invites(groupId: String) async throws -> [PendingInvite] { await server.pendingInvites(group: groupId) }
    func revokeInvite(groupId: String, inviteId: String) async throws { await server.revokeInvite(group: groupId, inviteId: inviteId) }
    func invite(id: String) async throws -> InviteDetails? {
        _ = try await caller()
        return await server.invite(id: id)
    }
    func acceptInvite(id: String, wrappedKey: Data) async throws -> RemoteSpace {
        try await server.accept(uid: try await caller(), inviteId: id, wrappedKey: wrappedKey)
    }

    func changes(spaceId: String, since: Int64, limit: Int) async throws -> ChangesPage {
        _ = try await caller()
        return await server.changes(space: spaceId, since: since, limit: limit)
    }
    func putItem(spaceId: String, itemId: String, _ body: ItemUpload) async throws -> WriteOutcome {
        try await server.put(space: spaceId, id: itemId, body: body, uid: try await caller())
    }
    func deleteItem(spaceId: String, itemId: String, updatedAt: Int64) async throws -> WriteOutcome {
        await server.delete(space: spaceId, id: itemId, updatedAt: updatedAt)
    }
    func registerBlob(spaceId: String, blobId: String, size: Int) async throws -> BlobUploadTicket {
        await server.register(space: spaceId, blob: blobId)
    }
    func uploadBlob(_ ticket: BlobUploadTicket, data: Data) async throws { await server.upload(ticket, data: data) }
    func downloadBlob(spaceId: String, blobId: String) async throws -> Data {
        try await server.download(space: spaceId, blob: blobId)
    }
}

/// Stand-in for the server's salt for unknown emails.
nonisolated enum SHA256Fake {
    static func bytes(_ text: String) -> Data { Data(SyncCrypto.sha256Hex(Data(text.utf8)).utf8) }
}

final class FakeSecrets: SyncSecretSource {
    var refs: [String: SecretRef] = [:]
    var values: [String: String] = [:]

    var syncSecrets: [SecretRef] { Array(refs.values) }
    func syncValue(id: String) -> String? { values[id] }
    func syncUpsert(id: String, name: String, value: String, spaceID: String?) {
        let created = refs[id]?.createdAt ?? Date(timeIntervalSince1970: 1_000)
        refs[id] = SecretRef(id: id, name: name, createdAt: created, spaceID: refs[id]?.spaceID ?? spaceID, updatedAt: .now)
        values[id] = value
    }
    func syncDelete(id: String) {
        refs[id] = nil
        values[id] = nil
    }
    func syncDidChange() {}

    func add(name: String, value: String, spaceID: String? = nil) {
        let id = UUID().uuidString
        refs[id] = SecretRef(id: id, name: name, createdAt: Date(timeIntervalSince1970: 1_000), spaceID: spaceID, updatedAt: .now)
        values[id] = value
    }
}

/// A user with an identity key and a personal space on the fake server.
struct FakeUser {
    let identity: SyncIdentity
    let server: FakeSyncServer
    let token: String

    static func make(_ uid: String, on server: FakeSyncServer) async throws -> FakeUser {
        let priv = SyncCrypto.newPrivateKey()
        let pub = try SyncCrypto.publicKey(of: priv)
        let personal = SyncCrypto.newID()
        let key = SyncCrypto.randomBytes(32)
        let wrapped = try SyncCrypto.wrapSpaceKey(key, spaceId: personal, memberUid: uid, memberPublicKey: pub)
        await server.createSpace(id: personal, kind: "personal", owner: uid, wrappedKey: wrapped)
        let token = await server.issueToken(for: uid)
        return FakeUser(identity: SyncIdentity(uid: uid, privateKey: priv, publicKey: pub, personalSpaceId: personal),
                        server: server, token: token)
    }

    var personal: String { identity.personalSpaceId }
}

/// One Mac: its own database, blob folder, secrets and engine.
@MainActor
final class FakeDevice {
    let container: ModelContainer
    let store: ClipStore
    let snippets: SnippetStore
    let secrets = FakeSecrets()
    let engine: SyncEngine

    init(_ user: FakeUser) throws {
        container = try ModelContainer(for: AppEnvironment.schema,
                                       configurations: ModelConfiguration(schema: AppEnvironment.schema, isStoredInMemoryOnly: true))
        store = ClipStore(context: container.mainContext,
                          blobs: BlobStore(directory: FileManager.default.temporaryDirectory.appending(path: "SyncDevice-\(UUID())")))
        snippets = SnippetStore(context: container.mainContext)
        let token = user.token
        engine = SyncEngine(api: FakeClient(server: user.server, token: { token }), identity: user.identity,
                            context: container.mainContext, store: store, snippets: snippets, secrets: secrets)
    }

    func texts(inSpace space: String? = nil) -> Set<String> { Set(store.items(inSpace: space).map(\.text)) }
}

/// Creates a group owned by `owner` with `members`; returns its id.
@MainActor
func makeGroup(_ name: String, owner: FakeUser, members: [FakeUser] = []) async throws -> String {
    let id = SyncCrypto.newID()
    let key = SyncCrypto.randomBytes(32)
    await owner.server.createSpace(id: id, kind: "group", owner: owner.identity.uid,
                                   wrappedKey: try SyncCrypto.wrapSpaceKey(key, spaceId: id, memberUid: owner.identity.uid,
                                                                          memberPublicKey: owner.identity.publicKey),
                                   encryptedName: try SyncCrypto.encryptGroupName(name, spaceKey: key, spaceId: id))
    for member in members {
        await owner.server.addMember(space: id, uid: member.identity.uid,
                                     wrappedKey: try SyncCrypto.wrapSpaceKey(key, spaceId: id, memberUid: member.identity.uid,
                                                                            memberPublicKey: member.identity.publicKey))
    }
    return id
}

// MARK: - Engine

@MainActor
struct SyncEngineTests {
    @Test func pushThenPullOnAnotherDevice() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)

        mac1.store.ingest(.text("hello"), now: Date(timeIntervalSince1970: 1_000))
        let pinned = mac1.store.ingest(.text("pinned one"), now: Date(timeIntervalSince1970: 2_000))
        mac1.store.setLabel("Server", for: pinned)
        let snippet = mac1.snippets.create(name: "Sig", keyword: ";sig", body: "Best, Alice")
        mac1.secrets.add(name: "DB password", value: "hunter2")
        try await mac1.engine.tick()

        #expect(await server.live(space: user.personal).count == 4)
        try await mac2.engine.tick()
        #expect(mac2.texts() == ["hello", "pinned one"])
        let received = try #require(mac2.store.item(withID: pinned.id))
        #expect(received.isPinned && received.label == "Server")
        #expect(mac2.snippets.snippet(withID: snippet.id)?.body == "Best, Alice")
        #expect(mac2.secrets.syncSecrets.first?.name == "DB password")
        #expect(mac2.secrets.values.values.first == "hunter2")

        // Nothing changed: a second tick pushes nothing.
        let puts = await server.putCount
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        #expect(await server.putCount == puts)
    }

    @Test func editsAndPinChangesPropagate() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)
        let item = mac1.store.ingest(.text("note"))
        try await mac1.engine.tick()
        try await mac2.engine.tick()

        mac1.store.togglePin(item)
        try await mac1.engine.tick()
        #expect(await server.item(space: user.personal, id: item.id.uuidString.lowercased())?.category == "pinned")
        try await mac2.engine.tick()
        #expect(mac2.store.item(withID: item.id)?.isPinned == true)
    }

    @Test func imagesTravelAsEncryptedBlobs() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)
        let png = Data((0..<500).map { UInt8($0 % 251) })
        try mac1.store.blobs.write(png, name: "pic.png")
        try mac1.store.blobs.write(Data([9, 9]), name: "pic-thumb.png")
        mac1.store.ingest(ProcessedCapture(kind: .image, text: "", preview: "Image", fileURLs: [], hash: "image:px:2x2:abc",
                                           imageFile: "pic.png", thumbnailFile: "pic-thumb.png", imageWidth: 2, imageHeight: 2))
        try await mac1.engine.tick()
        let remote = try #require(await server.live(space: user.personal).first)
        #expect(remote.blobIds.count == 2)

        try await mac2.engine.tick()
        let item = try #require(mac2.store.allItems().first)
        #expect(item.kind == .image && item.imageWidth == 2)
        let file = try #require(item.imageFile)
        #expect(try Data(contentsOf: mac2.store.blobs.url(for: file)) == png)
        #expect(item.thumbnailFile != nil)

        // Pinning re-encrypts the item but reuses the uploaded blobs.
        mac1.store.togglePin(try #require(mac1.store.allItems().first))
        try await mac1.engine.tick()
        #expect(await server.live(space: user.personal).first?.blobIds == remote.blobIds)
    }

    @Test func filesTravelAsEncryptedBlobsAndArriveAsFiles() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)
        let dir = FileManager.default.temporaryDirectory.appending(path: "SyncFiles-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir.appending(path: "Folder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = Data((0..<3000).map { UInt8($0 % 241) })
        try report.write(to: dir.appending(path: "Report.pdf"))
        try Data("hello".utf8).write(to: dir.appending(path: "notes.txt"))
        let urls = [dir.appending(path: "Report.pdf"), dir.appending(path: "notes.txt"), dir.appending(path: "Folder")]
        mac1.store.ingest(ProcessedCapture(kind: .file, text: urls.map(\.path).joined(separator: "\n"), preview: "3 files",
                                           fileURLs: urls, hash: ContentHasher.hash(fileURLs: urls)))
        try await mac1.engine.tick()
        let remote = try #require(await server.live(space: user.personal).first)
        #expect(remote.blobIds.count == 2)   // the folder travels as its name only

        try await mac2.engine.tick()
        let item = try #require(mac2.store.allItems().first)
        defer { mac2.store.delete(item) }
        #expect(item.kind == .file)
        #expect(item.fileURLs.map(\.lastPathComponent) == ["Report.pdf", "notes.txt"])
        #expect(item.fileURLs.allSatisfy { $0.path.hasPrefix(AppPaths.syncedFilesDirectory.path) })
        #expect(try Data(contentsOf: item.fileURLs[0]) == report)

        // Nothing changes on the next round trip: no re-upload, no re-download.
        try await mac2.engine.tick()
        try await mac1.engine.tick()
        #expect(await server.live(space: user.personal).first?.blobIds == remote.blobIds)
        #expect(await server.live(space: user.personal).first?.seq == remote.seq)

        let folder = AppPaths.syncedFilesFolder(for: item.id)
        mac2.store.delete(item)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func fileNamesFromOtherDevicesCantEscapeTheirFolder() {
        var taken = Set<String>()
        #expect(SyncEngine.safeFileName("../../.ssh/id_rsa", taken: &taken) == "id_rsa")
        #expect(SyncEngine.safeFileName("..", taken: &taken) == "File")
        #expect(SyncEngine.safeFileName("a:b", taken: &taken) == "a-b")
        #expect(SyncEngine.safeFileName("ID_RSA", taken: &taken) == "ID_RSA 2")
    }

    @Test func filesFromOlderClientsStillArriveAsText() throws {
        let json = Data(#"{"v":1,"type":"clip","kind":"file","files":["file:///tmp/a.txt"],"createdAt":5}"#.utf8)
        guard case .clip(let clip) = try SyncPayload.decode(json) else { return }
        let item = ClipItem(syncID: UUID(), spaceID: "g")
        clip.apply(to: item, localFiles: [])
        #expect(item.kind == .text && item.text == "/tmp/a.txt")
    }

    @Test func deletesBecomeTombstones() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)
        let doomed = mac1.store.ingest(.text("delete me"))
        mac1.store.ingest(.text("keep me"))
        let snippet = mac1.snippets.create(name: "Gone")
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        #expect(mac2.store.count() == 2)

        mac1.store.delete(doomed)
        mac1.snippets.delete(snippet)
        try await mac1.engine.tick()
        #expect(await server.item(space: user.personal, id: doomed.id.uuidString.lowercased())?.deleted == "user")
        try await mac2.engine.tick()
        #expect(mac2.texts() == ["keep me"])
        #expect(mac2.snippets.all().isEmpty)
    }

    @Test func firstSyncUploadsNewest200HistoryPlusAllPinnedSnippetsAndSecrets() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac = try FakeDevice(user)
        let base = Date(timeIntervalSince1970: 100_000)
        for i in 0..<250 { mac.store.ingest(.text("item \(i)"), now: base.addingTimeInterval(Double(i))) }
        for i in 0..<3 {
            let old = mac.store.ingest(.text("pinned \(i)"), now: base.addingTimeInterval(Double(-1_000 - i)))
            mac.store.togglePin(old)
        }
        mac.snippets.create(name: "S1")
        mac.secrets.add(name: "K", value: "v")

        try await mac.engine.tick()
        let live = await server.live(space: user.personal)
        let history = live.filter { $0.category == "history" }
        #expect(history.count == 200)
        #expect(history.map(\.sortAt).min() == base.addingTimeInterval(50).syncMillis)
        #expect(live.filter { $0.category == "pinned" }.count == 3)
        #expect(live.filter { $0.category == "snippet" }.count == 1)
        #expect(live.filter { $0.category == "secret" }.count == 1)
        #expect(mac.store.count() == 253)   // nothing local was dropped
    }

    @Test func trimmedHistoryStaysLocalInThePersonalSpace() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)
        let base = Date(timeIntervalSince1970: 100_000)
        for i in 0..<200 { mac1.store.ingest(.text("old \(i)"), now: base.addingTimeInterval(Double(i))) }
        try await mac1.engine.tick()
        let oldest = try #require(mac1.store.items(inSpace: nil).last)

        try await mac2.engine.tick()
        mac2.store.ingest(.text("brand new"), now: base.addingTimeInterval(10_000))
        try await mac2.engine.tick()   // the server trims `oldest`
        #expect(await server.item(space: user.personal, id: oldest.id.uuidString.lowercased())?.deleted == "trimmed")
        #expect(mac2.store.count() == 201)

        try await mac1.engine.tick()
        #expect(mac1.store.count() == 201)
        #expect(mac1.store.item(withID: oldest.id) != nil)
        #expect(mac1.engine.meta(for: oldest.id.uuidString.lowercased()) == nil)
        #expect(await server.live(space: user.personal).count == 200)
    }

    @Test func trimmedHistoryIsDeletedInAGroup() async throws {
        let server = FakeSyncServer()
        let alice = try await FakeUser.make("alice", on: server)
        let bob = try await FakeUser.make("bob", on: server)
        let group = try await makeGroup("Team", owner: alice, members: [bob])
        let aliceMac = try FakeDevice(alice), bobMac = try FakeDevice(bob)
        let base = Date(timeIntervalSince1970: 100_000)
        for i in 0..<200 { aliceMac.store.ingest(.text("g \(i)"), spaceID: group, now: base.addingTimeInterval(Double(i))) }
        try await aliceMac.engine.tick()
        let oldest = try #require(aliceMac.store.items(inSpace: group).last)

        try await bobMac.engine.tick()
        #expect(bobMac.store.items(inSpace: group).count == 200)
        #expect(bobMac.engine.allSpaces().first { $0.id == group }?.name == "Team")
        bobMac.store.ingest(.text("from bob"), spaceID: group, now: base.addingTimeInterval(10_000))
        try await bobMac.engine.tick()
        #expect(bobMac.store.item(withID: oldest.id) == nil)

        try await aliceMac.engine.tick()
        #expect(aliceMac.store.items(inSpace: group).count == 200)
        #expect(aliceMac.store.item(withID: oldest.id) == nil)
        #expect(aliceMac.texts(inSpace: group).contains("from bob"))
    }

    @Test func conflictAppliesTheServersNewerVersion() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)
        let snippet = mac1.snippets.create(name: "Shared", body: "v1")
        snippet.updatedAt = Date(timeIntervalSince1970: 1_000)
        try await mac1.engine.tick()
        try await mac2.engine.tick()

        let remoteCopy = try #require(mac2.snippets.snippet(withID: snippet.id))
        remoteCopy.body = "v2 from mac2"
        remoteCopy.updatedAt = Date(timeIntervalSince1970: 3_000)
        try await mac2.engine.tick()

        // mac1 edited earlier and never saw mac2's version before pushing (its cursor skips it).
        snippet.body = "older edit on mac1"
        snippet.updatedAt = Date(timeIntervalSince1970: 2_000)
        let latest = await server.seq
        for space in mac1.engine.allSpaces() { space.since = latest }
        try await mac1.engine.tick()

        #expect(mac1.snippets.snippet(withID: snippet.id)?.body == "v2 from mac2")
        let stored = try #require(await server.item(space: user.personal, id: snippet.id.uuidString.lowercased()))
        #expect(stored.updatedAt == Date(timeIntervalSince1970: 3_000).syncMillis)
    }

    @Test func duplicatesAcrossDevicesConvergeOnTheSmallestID() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)
        let a = mac1.store.ingest(.text("same text"), now: Date(timeIntervalSince1970: 1_000))
        let b = mac2.store.ingest(.text("same text"), now: Date(timeIntervalSince1970: 2_000))
        let winner = min(a.id.uuidString.lowercased(), b.id.uuidString.lowercased())

        try await mac1.engine.tick()
        try await mac2.engine.tick()
        try await mac1.engine.tick()

        for mac in [mac1, mac2] {
            let items = mac.store.allItems()
            #expect(items.count == 1)
            #expect(items.first?.id.uuidString.lowercased() == winner)
            #expect(items.first?.copyCount == 2)
            #expect(items.first?.lastCopiedAt == Date(timeIntervalSince1970: 2_000))
        }
        #expect(await server.live(space: user.personal).map(\.id) == [winner])
    }

    @Test func sharedItemsReachGroupMembersAndLeavingRemovesThem() async throws {
        let server = FakeSyncServer()
        let alice = try await FakeUser.make("alice", on: server)
        let bob = try await FakeUser.make("bob", on: server)
        let group = try await makeGroup("Team", owner: alice, members: [bob])
        let aliceMac = try FakeDevice(alice), bobMac = try FakeDevice(bob)
        let original = aliceMac.store.ingest(.text("for the team"))
        try await aliceMac.engine.tick()
        let shared = aliceMac.store.shareCopy(of: original, toSpace: group)
        #expect(shared.id != original.id)
        try await aliceMac.engine.tick()

        try await bobMac.engine.tick()
        #expect(bobMac.texts(inSpace: group) == ["for the team"])
        #expect(bobMac.texts(inSpace: nil).isEmpty)          // alice's personal items stay hers

        await server.removeMember(space: group, uid: bob.identity.uid)
        try await bobMac.engine.tick()
        #expect(bobMac.store.allItems().isEmpty)
        #expect(bobMac.engine.allSpaces().allSatisfy { $0.id != group })
    }

    @Test func retentionStopsTrackingInsteadOfDeletingRemotely() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac = try FakeDevice(user)
        mac.store.onExpire = { [engine = mac.engine] ids in engine.forget(ids) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        mac.store.ingest(.text("old"), now: now.addingTimeInterval(-40 * 86_400))
        try await mac.engine.tick()
        mac.store.enforceRetention(maxItems: 0, maxAge: 30 * 86_400, now: now)
        #expect(mac.store.count() == 0)
        try await mac.engine.tick()
        #expect(await server.live(space: user.personal).count == 1)
    }

    @Test func groupHistoryKeepsNewest200LocallyAndPersonalLimitsDontTouchGroups() {
        let container = try! ModelContainer(for: AppEnvironment.schema,
                                            configurations: ModelConfiguration(schema: AppEnvironment.schema, isStoredInMemoryOnly: true))
        let store = ClipStore(context: container.mainContext,
                              blobs: BlobStore(directory: FileManager.default.temporaryDirectory.appending(path: "Ret-\(UUID())")))
        let base = Date(timeIntervalSince1970: 10_000)
        for i in 0..<205 { store.ingest(.text("g\(i)"), spaceID: "group-1", now: base.addingTimeInterval(Double(i))) }
        for i in 0..<5 { store.ingest(.text("p\(i)"), now: base.addingTimeInterval(Double(i))) }
        store.enforceRetention(maxItems: 2, maxAge: nil, now: base.addingTimeInterval(1_000))
        #expect(store.items(inSpace: "group-1").count == 200)
        #expect(store.items(inSpace: nil).count == 2)
        // Dedupe is per space: the same text can live in personal and a group.
        store.ingest(.text("p4"), spaceID: "group-1")
        #expect(store.items(inSpace: "group-1").contains { $0.text == "p4" })
    }
}

// MARK: - Account flows against the fake server

final class MemoryCredentials: SyncSessionStore {
    var saved: StoredSyncSession?
    func load() -> StoredSyncSession? { saved }
    func save(_ session: StoredSyncSession) { saved = session }
    func clear() { saved = nil }
}

/// One Mac's SyncAccount wired to the fake server.
@MainActor
final class AccountHarness {
    let container: ModelContainer
    let store: ClipStore
    let snippets: SnippetStore
    let credentials = MemoryCredentials()
    let prefs: Preferences
    let account: SyncAccount
    /// Background ticks can outlive a test; freeing the container would reset the context under
    /// them (the app's container lives as long as the process), so keep every one alive.
    private static var keepAlive: [ModelContainer] = []

    init(_ server: FakeSyncServer) throws {
        container = try ModelContainer(for: AppEnvironment.schema,
                                       configurations: ModelConfiguration(schema: AppEnvironment.schema, isStoredInMemoryOnly: true))
        Self.keepAlive.append(container)
        store = ClipStore(context: container.mainContext,
                          blobs: BlobStore(directory: FileManager.default.temporaryDirectory.appending(path: "SyncAccount-\(UUID())")))
        snippets = SnippetStore(context: container.mainContext)
        prefs = Preferences(defaults: try #require(UserDefaults(suiteName: "SyncAccountTests-\(UUID())")))
        account = SyncAccount(prefs: prefs, context: container.mainContext, store: store, snippets: snippets,
                              secrets: FakeSecrets(), credentials: credentials) { token in
            FakeClient(server: server, token: token)
        }
    }

    /// Waits for background ticks, then runs one more to completion.
    func settle() async {
        for _ in 0..<500 where account.isSyncing { try? await Task.sleep(for: .milliseconds(5)) }
        await account.runTick()
        for _ in 0..<500 where account.isSyncing { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

@MainActor
struct SyncAccountTests {
    @Test func signUpSignInAndWrongPassword() async throws {
        let server = FakeSyncServer()
        let mac1 = try AccountHarness(server)
        await mac1.account.signUp(email: "  Alice@Example.com ", password: "correct horse", username: "useralice")
        #expect(mac1.account.state == .signedIn(email: "alice@example.com"))
        let stored = try #require(mac1.credentials.saved)
        #expect(stored.token != nil && stored.accountKey.count == 32)
        #expect(await server.accounts["alice@example.com"]?.kdf.iterations == 600_000)

        let mac2 = try AccountHarness(server)
        await mac2.account.signIn(email: "alice@example.com", password: "wrong horse")
        #expect(mac2.account.state == .signedOut)
        #expect(mac2.account.errorMessage == "Wrong email or password.")

        await mac2.account.signIn(email: "ALICE@example.com", password: "correct horse")
        #expect(mac2.account.state == .signedIn(email: "alice@example.com"))
        #expect(mac2.credentials.saved?.uid == stored.uid)
        #expect(mac2.credentials.saved?.accountKey == stored.accountKey)

        let mac3 = try AccountHarness(server)
        await mac3.account.signUp(email: "alice@example.com", password: "another one", username: "useralice")
        #expect(mac3.account.errorMessage == SyncAccountError.emailTaken.errorDescription)
    }

    @Test func passwordChangeEndsOtherSessionsAndTheyUnlockWithTheNewOne() async throws {
        let server = FakeSyncServer()
        let mac1 = try AccountHarness(server), mac2 = try AccountHarness(server)
        await mac1.account.signUp(email: "a@b.at", password: "old password", username: "usera")
        await mac2.account.signIn(email: "a@b.at", password: "old password")
        mac1.store.ingest(.text("before the change"))
        await mac1.settle()

        #expect(await mac1.account.changePassword(current: "nope", new: "new password") == false)
        #expect(mac1.account.errorMessage == "The current password is wrong.")
        #expect(await mac1.account.changePassword(current: "old password", new: "new password"))

        await mac2.settle()
        #expect(mac2.account.state == .needsPassword(email: "a@b.at"))
        await mac2.account.unlock(password: "new password")
        #expect(mac2.account.isSignedIn)
        await mac2.settle()
        #expect(mac2.store.allItems().map(\.text) == ["before the change"])
    }

    @Test func inviteCodeJoinsAGroupOnce() async throws {
        let server = FakeSyncServer()
        let alice = try AccountHarness(server), bob = try AccountHarness(server), carol = try AccountHarness(server)
        await alice.account.signUp(email: "alice@x.at", password: "alice password", username: "useralice")
        await bob.account.signUp(email: "bob@x.at", password: "bob password", username: "userbob")
        await carol.account.signUp(email: "carol@x.at", password: "carol password", username: "usercarol")

        let group = try await alice.account.createGroup(named: "Team Wien")
        #expect(alice.prefs.syncDefaultGroupID == group.id)
        let code = try await alice.account.createInviteCode(for: group)
        #expect(code.count == 32 && SyncCrypto.Invite.parse(code) != nil)
        #expect(try await alice.account.pendingInvites(for: group).count == 1)

        let typed = code.lowercased().replacingOccurrences(of: "-", with: " ")
        let preview = try await bob.account.previewInvite(code: typed)
        #expect(preview.name == "Team Wien" && preview.spaceId == group.id)
        try await bob.account.join(preview)
        #expect(bob.account.groups.map(\.name) == ["Team Wien"])
        #expect(bob.prefs.syncDefaultGroupID == group.id)

        // Single use, and nonsense is caught before any request.
        await #expect(throws: SyncAccountError.inviteNotFound) { try await carol.account.previewInvite(code: code) }
        await #expect(throws: SyncAccountError.invalidInviteCode) { try await carol.account.previewInvite(code: "not-a-code") }

        alice.store.ingest(.text("hi team"), spaceID: group.id)
        await alice.settle()
        await bob.settle()
        #expect(bob.store.items(inSpace: group.id).map(\.text) == ["hi team"])
        #expect(bob.account.groupName(for: group.id) == "Team Wien")
    }

    @Test func groupItemsShowWhoCopiedThem() async throws {
        let server = FakeSyncServer()
        let alice = try AccountHarness(server), bob = try AccountHarness(server)
        await alice.account.signUp(email: "alice@x.at", password: "alice password", username: "Alice")
        await bob.account.signUp(email: "bob@x.at", password: "bob password", username: "bobby")
        #expect(alice.account.username == "Alice")
        let group = try await alice.account.createGroup(named: "Team")
        try await bob.account.join(try await bob.account.previewInvite(code: try await alice.account.createInviteCode(for: group)))

        let mine = alice.store.ingest(.text("from alice"), spaceID: group.id)
        #expect(alice.account.copiedBy(mine) == "Alice")              // not synced yet: still yours
        #expect(alice.account.copiedBy(alice.store.ingest(.text("personal"))) == nil)
        await alice.settle()
        await bob.settle()
        let received = try #require(bob.store.items(inSpace: group.id).first)
        #expect(bob.account.copiedBy(received) == "Alice")

        // A new name reaches the other member with the next sync.
        #expect(await alice.account.setUsername("  Ali  "))
        await alice.settle()
        await bob.settle()
        #expect(bob.account.copiedBy(received) == "Ali")

        // Taken (any case) and invalid names are refused.
        #expect(await bob.account.setUsername("ALI") == false)
        #expect(bob.account.errorMessage == SyncAccountError.usernameTaken.localizedDescription)
        #expect(await bob.account.setUsername("x") == false)
        #expect(bob.account.username == "bobby")

        // A server without member names: fall back to the group's name.
        await server.setListsMembers(false)
        let other = try AccountHarness(server)
        await other.account.signUp(email: "carol@x.at", password: "carol password", username: "carol")
        try await other.account.join(try await other.account.previewInvite(code: try await alice.account.createInviteCode(for: group)))
        await other.settle()
        let seen = try #require(other.store.items(inSpace: group.id).first)
        #expect(other.account.copiedBy(seen) == "Team")
    }

    @Test func itemsSyncedBeforeUsernamesLearnTheirAuthor() async throws {
        let server = FakeSyncServer()
        let alice = try AccountHarness(server), bob = try AccountHarness(server)
        await alice.account.signUp(email: "alice@x.at", password: "alice password", username: "Alice")
        await bob.account.signUp(email: "bob@x.at", password: "bob password", username: "bobby")
        let group = try await alice.account.createGroup(named: "Team")
        try await bob.account.join(try await bob.account.previewInvite(code: try await alice.account.createInviteCode(for: group)))
        alice.store.ingest(.text("old item"), spaceID: group.id)
        await alice.settle()
        await bob.settle()
        let received = try #require(bob.store.items(inSpace: group.id).first)

        // As on a Mac updated from a version without authors: nothing recorded, no backfill yet.
        let context = bob.container.mainContext
        for meta in try context.fetch(FetchDescriptor<SyncMeta>()) { meta.authorUid = nil }
        for space in try context.fetch(FetchDescriptor<SyncSpace>()) { space.authorsBackfilled = false }
        try context.save()
        bob.account.loadGroups()
        #expect(bob.account.copiedBy(received) == "Team")   // unknown, never shown as bob's own

        await bob.settle()
        #expect(bob.account.copiedBy(received) == "Alice")
    }

    @Test func signUpRefusesATakenOrInvalidUsername() async throws {
        let server = FakeSyncServer()
        let a = try AccountHarness(server), b = try AccountHarness(server)
        await a.account.signUp(email: "a@x.at", password: "a password", username: "sam")
        await b.account.signUp(email: "b@x.at", password: "b password", username: "SAM")
        #expect(!b.account.isSignedIn)
        #expect(b.account.errorMessage == SyncAccountError.usernameTaken.localizedDescription)
        await b.account.signUp(email: "b@x.at", password: "b password", username: "-sam")
        #expect(!b.account.isSignedIn)
        #expect(SyncAccount.usernameProblem("ab") != nil)
        #expect(SyncAccount.usernameProblem("Größe_2.0") == nil)
        #expect(SyncAccount.usernameProblem("has space") != nil)
        #expect(SyncAccount.usernameProblem(String(repeating: "a", count: 25)) != nil)
    }

    @Test func revokedInvitesStopWorking() async throws {
        let server = FakeSyncServer()
        let alice = try AccountHarness(server), bob = try AccountHarness(server)
        await alice.account.signUp(email: "alice@x.at", password: "alice password", username: "useralice")
        await bob.account.signUp(email: "bob@x.at", password: "bob password", username: "userbob")
        let group = try await alice.account.createGroup(named: "Ops")
        let code = try await alice.account.createInviteCode(for: group)
        let pending = try #require(try await alice.account.pendingInvites(for: group).first)
        try await alice.account.revoke(pending, in: group)
        await #expect(throws: SyncAccountError.inviteNotFound) { try await bob.account.previewInvite(code: code) }
    }

    @Test func signOutAndDeleteAccount() async throws {
        let server = FakeSyncServer()
        let mac = try AccountHarness(server)
        await mac.account.signUp(email: "a@b.at", password: "a password", username: "usera")
        let group = try await mac.account.createGroup(named: "G")
        mac.store.ingest(.text("mine"))
        mac.store.ingest(.text("group item"), spaceID: group.id)
        await mac.settle()

        mac.account.signOut()
        #expect(mac.account.state == .signedOut)
        #expect(mac.credentials.saved == nil)
        #expect(mac.store.allItems().map(\.text) == ["mine"])     // personal history stays

        await mac.account.signIn(email: "a@b.at", password: "a password")
        #expect(await mac.account.deleteAccount(password: "wrong") == false)
        #expect(await mac.account.deleteAccount(password: "a password"))
        #expect(mac.account.state == .signedOut)
        #expect(await server.accounts["a@b.at"] == nil)
    }
}
