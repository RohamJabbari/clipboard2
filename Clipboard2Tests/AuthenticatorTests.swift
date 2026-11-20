import AppKit
import SwiftData
import Testing
@testable import Clipboard2

// MARK: - Codes (RFC 6238 appendix B) and base32

struct TOTPTests {
    static let sha1Key = Data("12345678901234567890".utf8)
    static let sha256Key = Data("12345678901234567890123456789012".utf8)
    static let sha512Key = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    static let vectors: [(time: TimeInterval, sha1: String, sha256: String, sha512: String)] = [
        (59, "94287082", "46119246", "90693936"),
        (1_111_111_109, "07081804", "68084774", "25091201"),
        (1_111_111_111, "14050471", "67062674", "99943326"),
        (1_234_567_890, "89005924", "91819424", "93441116"),
        (2_000_000_000, "69279037", "90698825", "38618901"),
        (20_000_000_000, "65353130", "77737706", "47863826"),
    ]

    @Test func rfc6238AppendixBVectors() {
        for vector in Self.vectors {
            let time = Date(timeIntervalSince1970: vector.time)
            #expect(TOTP.code(key: Self.sha1Key, time: time, algorithm: .sha1, digits: 8) == vector.sha1)
            #expect(TOTP.code(key: Self.sha256Key, time: time, algorithm: .sha256, digits: 8) == vector.sha256)
            #expect(TOTP.code(key: Self.sha512Key, time: time, algorithm: .sha512, digits: 8) == vector.sha512)
        }
    }

    @Test func sixDigitsAndOtherPeriods() {
        let time = Date(timeIntervalSince1970: 59)
        #expect(TOTP.code(key: Self.sha1Key, time: time) == "287082")
        // Step 1 of a 59 s period is the same counter as step 1 of 30 s.
        #expect(TOTP.code(key: Self.sha1Key, time: Date(timeIntervalSince1970: 59), period: 59) == "287082")
        #expect(TOTP.code(key: Self.sha1Key, time: time, digits: 9) == nil)
        #expect(TOTP.code(key: Data(), time: time) == nil)
        #expect(TOTP.secondsRemaining(at: Date(timeIntervalSince1970: 59), period: 30) == 1)
        #expect(TOTP.secondsRemaining(at: Date(timeIntervalSince1970: 60), period: 30) == 30)
        #expect(TOTP.grouped("123456") == "123 456")
        #expect(TOTP.grouped("12345678") == "1234 5678")
        #expect(TOTP.grouped("1234567") == "123 4567")
    }

    @Test func base32ForgivesSpacesCaseAndPadding() throws {
        let bytes = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x21, 0xDE, 0xAD, 0xBE, 0xEF])
        #expect(Base32.decode("JBSWY3DPEHPK3PXP") == bytes)
        #expect(Base32.decode("jbsw y3dp ehpk 3pxp") == bytes)
        #expect(Base32.decode("JBSWY3DPEHPK3PXP====") == bytes)
        #expect(Base32.decode("JBSW-Y3DP-EHPK-3PXP") == bytes)
        #expect(Base32.normalize("jbsw y3dp ehpk 3pxp==") == "JBSWY3DPEHPK3PXP")
        #expect(Base32.decode("JBSW1") == nil)   // 1 isn't in the alphabet
        #expect(Base32.decode("   ") == nil)
        #expect(Base32.encode(bytes) == "JBSWY3DPEHPK3PXP")
        #expect(Base32.decode(Base32.encode(Self.sha1Key)) == Self.sha1Key)
    }
}

// MARK: - otpauth links

struct OTPAuthURITests {
    @Test func parsesATypicalLink() throws {
        let link = "otpauth://totp/GitHub:me%40example.com?secret=jbswy3dpehpk3pxp&issuer=GitHub&algorithm=SHA256&digits=8&period=60"
        let account = try OTPAuthURI.parse(link).get()
        #expect(account == OTPAccount(issuer: "GitHub", account: "me@example.com", secret: "JBSWY3DPEHPK3PXP",
                                      algorithm: .sha256, digits: 8, period: 60))
    }

    @Test func issuerParameterWinsOverTheLabel() throws {
        let both = try OTPAuthURI.parse("otpauth://totp/Old%20Name:alice?secret=JBSWY3DPEHPK3PXP&issuer=New%20Name").get()
        #expect(both.issuer == "New Name" && both.account == "alice")
        let labelOnly = try OTPAuthURI.parse("otpauth://totp/ACME%20Co:%20john@example.com?secret=JBSWY3DPEHPK3PXP").get()
        #expect(labelOnly.issuer == "ACME Co" && labelOnly.account == "john@example.com")
        let neither = try OTPAuthURI.parse("otpauth://totp/john?secret=JBSWY3DPEHPK3PXP").get()
        #expect(neither.issuer == "" && neither.account == "john")
        #expect(neither.algorithm == .sha1 && neither.digits == 6 && neither.period == 30)
        // Raw spaces, as some sites copy them.
        let spaced = try OTPAuthURI.parse("otpauth://totp/My Bank:me?secret=JBSW Y3DP EHPK 3PXP").get()
        #expect(spaced.issuer == "My Bank" && spaced.secret == "JBSWY3DPEHPK3PXP")
    }

    @Test func refusesHOTPMigrationAndBadParameters() {
        #expect(OTPAuthURI.parse("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=1") == .failure(.hotpUnsupported))
        #expect(OTPAuthURI.parse("otpauth-migration://offline?data=abc") == .failure(.migrationUnsupported))
        #expect(OTPAuthURI.parse("otpauth://totp/x") == .failure(.missingSecret))
        #expect(OTPAuthURI.parse("otpauth://totp/x?secret=not!base32") == .failure(.invalidSecret))
        #expect(OTPAuthURI.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=9") == .failure(.unsupportedDigits))
        #expect(OTPAuthURI.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=MD5") == .failure(.unsupportedAlgorithm))
        #expect(OTPAuthURI.parse("https://example.com") == .failure(.notALink))
        #expect(OTPAuthURI.hotpMessageIsClear)
    }

    @Test func madeLinksParseBack() throws {
        let account = OTPAccount(issuer: "Ex Ample", account: "a b@c.d", secret: "JBSWY3DPEHPK3PXP", algorithm: .sha512, digits: 7, period: 45)
        #expect(try OTPAuthURI.parse(OTPAuthURI.make(account)).get() == account)
    }

    @Test func secretLinksAreRecognised() {
        #expect(OTPAuthURI.isSecretLink(" otpauth://totp/x?secret=A "))
        #expect(OTPAuthURI.isSecretLink("OTPAUTH://TOTP/x?secret=A"))
        #expect(OTPAuthURI.isSecretLink("otpauth-migration://offline?data=x"))
        #expect(!OTPAuthURI.isSecretLink("see otpauth://totp/x"))
        #expect(!OTPAuthURI.isSecretLink("https://example.com/otpauth://"))
    }
}

extension OTPAuthURI {
    static var hotpMessageIsClear: Bool { OTPAuthError.hotpUnsupported.message.contains("HOTP") }
}

// MARK: - Capture and QR codes

@MainActor
struct AuthenticatorCaptureTests {
    let container: ModelContainer
    let store: ClipStore
    let prefs: Preferences

    init() throws {
        let schema = AppEnvironment.schema
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        store = ClipStore(context: container.mainContext,
                          blobs: BlobStore(directory: FileManager.default.temporaryDirectory.appending(path: "OTP-\(UUID())")))
        prefs = Preferences(defaults: try #require(UserDefaults(suiteName: "Clipboard2Tests-\(UUID().uuidString)")))
    }

    @Test func copiedLinkIsNeverStored() async throws {
        let pasteboard = NSPasteboard(name: .init("Clipboard2Tests-\(UUID().uuidString)"))
        let monitor = ClipboardMonitor(store: store, prefs: prefs, tracker: FrontmostAppTracker(), blobs: store.blobs,
                                       pasteboard: pasteboard)
        var links: [String] = []
        monitor.onAuthenticatorLink = { links.append($0) }
        let link = "otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        monitor.captureCurrent()
        pasteboard.clearContents()
        pasteboard.setString("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP", forType: .string)
        monitor.captureCurrent()
        try await Task.sleep(for: .milliseconds(300))
        #expect(links == [link, "otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP"])
        #expect(store.count() == 0)

        // Ordinary text still goes in.
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        monitor.captureCurrent()
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.count() == 1)
    }

    @Test func qrCodeInAGeneratedImageIsFound() throws {
        let link = OTPAuthURI.make(OTPAccount(issuer: "GitHub", account: "me@example.com", secret: "JBSWY3DPEHPK3PXP"))
        let image = try #require(OTPQRCode.image(for: link))
        #expect(OTPQRCode.link(in: image) == link)
        let plain = try #require(OTPQRCode.image(for: "https://example.com"))
        #expect(OTPQRCode.link(in: plain) == nil)
    }

    @Test func capturedQRImageIsConcealedAndOffered() async throws {
        let link = OTPAuthURI.make(OTPAccount(issuer: "Bank", account: "me", secret: "JBSWY3DPEHPK3PXP"))
        let png = try #require(OTPQRCode.image(for: link).flatMap(ImageProcessor.encodePNG))
        let name = "\(UUID().uuidString).png"
        try store.blobs.write(png, name: name)
        var capture = ProcessedCapture.text("")
        capture.kind = .image
        capture.imageFile = name
        capture.hash = UUID().uuidString
        let item = store.ingest(capture)

        let indexer = ImageTextIndexer(store: store, blobs: store.blobs)
        indexer.recognize = { _ in "" }
        var offered: [String] = []
        indexer.onAuthenticatorLink = { offered.append($0) }
        indexer.enqueue(item)
        await indexer.waitUntilIdle()
        #expect(item.isConcealed)
        #expect(offered == [link])
        #expect(SyncEngine.groupShareProblem(item) == SyncEngine.concealedShareProblem)
        let share = ShareGroupState(items: [item], groups: [], defaultGroupID: nil)
        #expect(share.sensitiveKind == .authenticatorQR)
    }
}

// MARK: - Code batches and sealing

struct CodeBatchTests {
    static let authenticator = Authenticator(account: OTPAccount(issuer: "GitHub", account: "me", secret: Base32.encode(TOTPTests.sha1Key)),
                                             createdAt: Date(timeIntervalSince1970: 0))

    @Test func batchCoversTheNext24HoursFromTheCurrentStep() throws {
        let now = Date(timeIntervalSince1970: 1_111_111_111)
        let batch = try #require(CodeBatch.make(for: Self.authenticator, now: now))
        #expect(batch.codes.count == 2_880)
        #expect(batch.from == 1_111_111_110)
        #expect(batch.until == Date(timeIntervalSince1970: 1_111_111_110 + 86_400))
        for offset in [0.0, 29, 30, 3_600, 86_398] {   // the batch started 1 s before `now`
            let time = now.addingTimeInterval(offset)
            #expect(batch.code(at: time) == Self.authenticator.code(at: time))
        }
        #expect(batch.code(at: now.addingTimeInterval(86_400)) == nil)
        #expect(batch.code(at: now.addingTimeInterval(-60)) == nil)
        // About 26 KB: well under the 64 KiB limit.
        #expect(try batch.encoded().count < 40_000)
    }

    @Test func sealedCodesOpenOnlyForTheirRecipient() throws {
        let bobKey = SyncCrypto.newPrivateKey()
        let bobPub = try SyncCrypto.publicKey(of: bobKey)
        let batch = try #require(CodeBatch.make(for: Self.authenticator, now: .now))
        let sealed = try SyncCrypto.sealCodes(try batch.encoded(), spaceId: "space", recipientUid: "bob", recipientPublicKey: bobPub)
        let bob = SyncIdentity(uid: "bob", privateKey: bobKey, publicKey: bobPub, personalSpaceId: "p")
        #expect(SyncEngine.openBatch(sealed, spaceId: "space", identity: bob) == batch)
        // Another space, another uid or another key: nothing.
        #expect(SyncEngine.openBatch(sealed, spaceId: "other", identity: bob) == nil)
        var mallory = bob
        mallory.uid = "mallory"
        #expect(SyncEngine.openBatch(sealed, spaceId: "space", identity: mallory) == nil)
        let eve = try SyncCrypto.newPrivateKey()
        #expect(SyncEngine.openBatch(sealed, spaceId: "space",
                                     identity: SyncIdentity(uid: "bob", privateKey: eve, publicKey: try SyncCrypto.publicKey(of: eve),
                                                            personalSpaceId: "p")) == nil)
        // It can't be read as a space key either.
        #expect(throws: (any Error).self) { try SyncCrypto.unwrapSpaceKey(sealed, spaceId: "space", uid: "bob", privateKey: bobKey) }
    }

    @Test func emptySharesDecode() throws {
        let shared = try JSONDecoder().decode(SharedCodesEntry.self, from: Data(
            #"{"spaceId":"s","ownerUid":"a","ownerName":"A","codesUntil":null,"sealedCodes":null,"updatedAt":3}"#.utf8))
        #expect(shared.codesUntil == nil && shared.sealedCodes == nil)
        let share = try JSONDecoder().decode(AuthenticatorShare.self, from: Data(
            #"{"uid":"b","username":null,"name":"b","codesUntil":null,"createdAt":1}"#.utf8))
        #expect(share.codesUntil == nil)
    }

    @Test func topUpBelowTwelveHours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SyncEngine.needsTopUp(codesUntil: nil, now: now))   // an empty share
        #expect(SyncEngine.needsTopUp(codesUntil: 0, now: now))
        #expect(SyncEngine.needsTopUp(codesUntil: now.addingTimeInterval(11 * 3600).syncMillis, now: now))
        #expect(!SyncEngine.needsTopUp(codesUntil: now.addingTimeInterval(13 * 3600).syncMillis, now: now))
    }

    @Test func recipientDisplayStates() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let batch = try #require(CodeBatch.make(for: Self.authenticator, now: now))
        var shared = SharedAuthenticator(spaceId: "s", ownerUid: "alice", ownerName: "Alice", codesUntil: batch.until.syncMillis,
                                         updatedAt: 1, batch: batch, issuer: "GitHub", account: "me", addedAt: 0)
        #expect(shared.status(at: now) == .ok)
        #expect(AuthenticatorStatus.line(for: .shared(shared), shareCount: nil, now: now)?.text == "Shared by Alice")
        let late = batch.until.addingTimeInterval(-3600)
        #expect(shared.status(at: late) == .runningOut(until: batch.until))
        #expect(AuthenticatorStatus.line(for: .shared(shared), shareCount: nil, now: late)?.text.hasPrefix("Codes until") == true)
        #expect(shared.status(at: batch.until) == .empty)
        #expect(shared.code(at: batch.until) == nil)
        #expect(AuthenticatorStatus.line(for: .shared(shared), shareCount: nil, now: batch.until)?.text
                == "No codes, Alice's devices have been offline")
        shared.batch = nil
        #expect(shared.status(at: now) == .empty)
        #expect(AuthenticatorStatus.line(for: .owned(Self.authenticator), shareCount: 2, now: now)?.text == "Shared with 2")
        #expect(AuthenticatorStatus.line(for: .owned(Self.authenticator), shareCount: 0, now: now) == nil)
    }
}

// MARK: - Actions

struct AuthenticatorActionTests {
    @Test func ownerOnlyActionsAreHiddenFromOthers() {
        let owned = AuthenticatorItem.owned(CodeBatchTests.authenticator)
        let shared = AuthenticatorItem.shared(SharedAuthenticator(spaceId: "s", ownerUid: "a", ownerName: "A", codesUntil: 0,
                                                                  updatedAt: 0, batch: nil, issuer: "X", account: "", addedAt: 0))
        let ownerActions = PanelAction.authenticatorActions(for: owned, signedIn: true, shareCount: 2)
        #expect(ownerActions == [.paste, .copy, .authenticator(.rename), .authenticator(.share), .authenticator(.people),
                                 .authenticator(.transfer), .authenticator(.showSecret), .authenticator(.delete)])
        #expect(PanelAction.authenticatorActions(for: shared, signedIn: true, shareCount: nil)
                == [.paste, .copy, .authenticator(.leave)])
        // Nobody to transfer to or list yet.
        #expect(!PanelAction.authenticatorActions(for: owned, signedIn: true, shareCount: 0).contains(.authenticator(.transfer)))
        // Signed out: no sharing at all.
        let signedOut = PanelAction.authenticatorActions(for: owned, signedIn: false, shareCount: nil)
        #expect(!signedOut.contains(.authenticator(.share)) && !signedOut.contains(.authenticator(.people)))
        #expect(signedOut.contains(.authenticator(.showSecret)) && signedOut.contains(.authenticator(.delete)))
    }

    @Test func shareCandidatesAreContactsAndGroupMembersOnceEach() {
        let contacts = [SyncContact(id: "d1", name: "Sam", uid: "sam"), SyncContact(id: "d2", name: "Ann", uid: "ann")]
        let groups = [SyncGroup(id: "g", name: "Team", isOwner: true, memberCount: 4)]
        let names = ["g": ["me": "Me", "sam": "Sam", "zoe": "Zoe", "bob": "Bob"]]
        let people = SyncAccount.shareCandidates(contacts: contacts, groups: groups, memberNames: names, me: "me", excluding: ["bob"])
        #expect(people.map(\.uid) == ["ann", "sam", "zoe"])
    }

    @Test func formChecksTheSetupKey() throws {
        let form = AuthenticatorFormState(purpose: .add(from: nil))
        form.issuer = "Site"
        form.secret = "not base32!"
        guard case .failure = form.makeAccount() else { Issue.record("accepted a bad key"); return }
        form.secret = "jbsw y3dp ehpk 3pxp"
        #expect(try form.makeAccount().get().secret == "JBSWY3DPEHPK3PXP")
        // From a link: the secret comes along unseen.
        let linked = AuthenticatorFormState(purpose: .add(from: OTPAccount(issuer: "A", account: "b", secret: "JBSWY3DPEHPK3PXP")))
        #expect(!linked.asksForSecret)
        #expect(try linked.makeAccount().get().secret == "JBSWY3DPEHPK3PXP")
    }
}

// MARK: - Sync (against the fake server)

@MainActor
struct AuthenticatorSyncTests {
    static let account = OTPAccount(issuer: "GitHub", account: "alice@example.com", secret: "JBSWY3DPEHPK3PXP")

    /// Alice and Bob as contacts (a direct space with both in it).
    static func contacts(_ server: FakeSyncServer) async throws -> (FakeUser, FakeUser) {
        let alice = try await FakeUser.make("alice", on: server)
        let bob = try await FakeUser.make("bob", on: server)
        let key = SyncCrypto.randomBytes(32)
        let direct = SyncCrypto.newID()
        await server.createSpace(id: direct, kind: "direct", owner: "alice",
                                 wrappedKey: try SyncCrypto.wrapSpaceKey(key, spaceId: direct, memberUid: "alice",
                                                                         memberPublicKey: alice.identity.publicKey))
        await server.addMember(space: direct, uid: "bob",
                               wrappedKey: try SyncCrypto.wrapSpaceKey(key, spaceId: direct, memberUid: "bob",
                                                                       memberPublicKey: bob.identity.publicKey))
        return (alice, bob)
    }

    @Test func createdOnOneMacSyncsToTheOwnersOtherMacs() async throws {
        let server = FakeSyncServer()
        let alice = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(alice), mac2 = try FakeDevice(alice)
        let added = try #require(mac1.authenticators.add(Self.account))
        try await mac1.engine.tick()

        let space = try #require(mac1.authenticators.owned.first?.spaceID)
        #expect(await server.spaces[space]?.kind == "authenticator")
        #expect(await server.live(space: space).map(\.category) == ["otp"])
        // Never in the personal space, and no group appears for it.
        #expect(await server.live(space: alice.personal).isEmpty)

        try await mac2.engine.tick()
        let received = try #require(mac2.authenticators.owned.first)
        #expect(received.id == added.id && received.secret == Self.account.secret && received.spaceID == space)
        #expect(mac2.engine.allSpaces().first { $0.id == space }?.isGroup == false)

        mac2.authenticators.rename(id: received.id, issuer: "GitHub Work", account: "a@work")
        try await mac2.engine.tick()
        try await mac1.engine.tick()
        #expect(mac1.authenticators.owned.first?.issuer == "GitHub Work")

        // Delete removes it on the server and then on every Mac.
        mac1.authenticators.delete(id: added.id)
        try await mac1.engine.tick()
        #expect(await server.spaces[space] == nil)
        try await mac2.engine.tick()
        #expect(mac2.authenticators.owned.isEmpty)
    }

    @Test func sharingSendsCodesNeverTheSecret() async throws {
        let server = FakeSyncServer()
        let (alice, bob) = try await Self.contacts(server)
        let aliceMac = try FakeDevice(alice), bobMac = try FakeDevice(bob)
        aliceMac.authenticators.add(Self.account)
        try await aliceMac.engine.tick()
        let authenticator = try #require(aliceMac.authenticators.owned.first)
        let space = try #require(authenticator.spaceID)

        try await aliceMac.engine.share(authenticator, with: "bob")
        #expect(aliceMac.authenticators.shareCounts[space] == 1)
        // The space itself stays Alice's alone: Bob can't read the item.
        #expect(await server.spaces[space]?.members.keys.sorted() == ["alice"])

        try await bobMac.engine.tick()
        #expect(bobMac.authenticators.owned.isEmpty)
        let shared = try #require(bobMac.authenticators.shared.first)
        #expect(shared.ownerName == "alice" && shared.issuer == "GitHub")
        #expect(shared.code(at: .now) == authenticator.code(at: .now))
        #expect(!(bobMac.engine.allSpaces().contains { $0.id == space }))

        // A stranger can't be shared with.
        _ = try await FakeUser.make("eve", on: server)
        await #expect(throws: SyncAPIError.self) { try await aliceMac.engine.share(authenticator, with: "eve") }

        // Removing stops new codes; Bob's list drops it on his next sync.
        try await aliceMac.engine.removeShare(spaceId: space, uid: "bob")
        try await bobMac.engine.tick()
        #expect(bobMac.authenticators.shared.isEmpty)
    }

    @Test func topUpWhenFewerThanTwelveHoursAreLeft() async throws {
        let server = FakeSyncServer()
        let (alice, bob) = try await Self.contacts(server)
        let aliceMac = try FakeDevice(alice), bobMac = try FakeDevice(bob)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        aliceMac.engine.now = { clock }
        aliceMac.authenticators.add(Self.account)
        try await aliceMac.engine.tick()
        let authenticator = try #require(aliceMac.authenticators.owned.first)
        let space = try #require(authenticator.spaceID)
        try await aliceMac.engine.share(authenticator, with: "bob")
        let first = try #require(await server.shares[space]?["bob"])

        clock = clock.addingTimeInterval(11 * 3600)   // 13 h left: nothing to do
        try await aliceMac.engine.tick()
        #expect(await server.shares[space]?["bob"]?.updatedAt == first.updatedAt)

        clock = clock.addingTimeInterval(2 * 3600)    // 11 h left: a fresh 24 h
        try await aliceMac.engine.tick()
        let second = try #require(await server.shares[space]?["bob"])
        #expect(second.updatedAt > first.updatedAt)
        #expect((second.codesUntil ?? 0) > (first.codesUntil ?? 0) + 12 * 3_600_000)

        bobMac.engine.now = { clock }
        try await bobMac.engine.tick()
        #expect(bobMac.authenticators.shared.first?.code(at: clock) == authenticator.code(at: clock))
    }

    @Test func leaveRemovesTheShare() async throws {
        let server = FakeSyncServer()
        let (alice, bob) = try await Self.contacts(server)
        let aliceMac = try FakeDevice(alice), bobMac = try FakeDevice(bob)
        aliceMac.authenticators.add(Self.account)
        try await aliceMac.engine.tick()
        let authenticator = try #require(aliceMac.authenticators.owned.first)
        try await aliceMac.engine.share(authenticator, with: "bob")
        try await bobMac.engine.tick()
        let shared = try #require(bobMac.authenticators.shared.first)

        try await bobMac.engine.leave(sharedIn: shared.spaceId)
        #expect(bobMac.authenticators.shared.isEmpty)
        #expect(await server.shares[shared.spaceId]?["bob"] == nil)
        // Alice still owns it.
        try await aliceMac.engine.tick()
        #expect(aliceMac.authenticators.owned.count == 1)
    }

    @Test func transferHandsOverTheSeedAndTheOldOwnerGetsCodes() async throws {
        let server = FakeSyncServer()
        let (alice, bob) = try await Self.contacts(server)
        let aliceMac = try FakeDevice(alice), aliceMac2 = try FakeDevice(alice), bobMac = try FakeDevice(bob)
        aliceMac.authenticators.add(Self.account)
        try await aliceMac.engine.tick()
        try await aliceMac2.engine.tick()
        #expect(aliceMac2.authenticators.owned.count == 1)
        let authenticator = try #require(aliceMac.authenticators.owned.first)
        let space = try #require(authenticator.spaceID)
        try await aliceMac.engine.share(authenticator, with: "bob")
        try await bobMac.engine.tick()

        try await aliceMac.engine.transfer(authenticator, to: "bob")
        // The seed leaves Alice's Macs: this one at once, the other when the space is gone.
        #expect(aliceMac.authenticators.owned.isEmpty)
        try await aliceMac2.engine.tick()
        #expect(aliceMac2.authenticators.owned.isEmpty)

        // Bob owns it now (with the secret) and tops Alice up.
        try await bobMac.engine.tick()
        let owned = try #require(bobMac.authenticators.owned.first)
        #expect(owned.secret == Self.account.secret && owned.spaceID == space)
        #expect(bobMac.authenticators.shared.isEmpty)
        #expect(await server.shares[space]?["alice"]?.sealedCodes != nil)

        try await aliceMac.engine.tick()
        let shared = try #require(aliceMac.authenticators.shared.first)
        #expect(shared.ownerName == "bob")
        #expect(shared.code(at: .now) == owned.code(at: .now))
        #expect(aliceMac.authenticators.owned.isEmpty)
    }

    @Test func signingOutKeepsYourOwnAndDropsSharedOnes() async throws {
        let server = FakeSyncServer()
        let (alice, bob) = try await Self.contacts(server)
        let aliceMac = try FakeDevice(alice), bobMac = try FakeDevice(bob)
        aliceMac.authenticators.add(Self.account)
        bobMac.authenticators.add(OTPAccount(issuer: "Bob's", account: "b", secret: "GEZDGNBV"))
        try await aliceMac.engine.tick()
        try await bobMac.engine.tick()
        try await aliceMac.engine.share(try #require(aliceMac.authenticators.owned.first), with: "bob")
        try await bobMac.engine.tick()
        #expect(bobMac.authenticators.shared.count == 1)

        SyncEngine.wipeLocalState(context: bobMac.container.mainContext, store: bobMac.store, snippets: bobMac.snippets,
                                  secrets: bobMac.secrets, authenticators: bobMac.authenticators)
        #expect(bobMac.authenticators.shared.isEmpty)
        #expect(bobMac.authenticators.owned.map(\.issuer) == ["Bob's"])
        #expect(bobMac.authenticators.owned.first?.spaceID == nil)
    }
}

// MARK: - Backups

@MainActor
struct AuthenticatorBackupTests {
    @Test func ownedAuthenticatorsRoundTripOnlyWithSecrets() throws {
        let schema = AppEnvironment.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let store = ClipStore(context: container.mainContext,
                              blobs: BlobStore(directory: FileManager.default.temporaryDirectory.appending(path: "OTPBackup-\(UUID())")))
        let snippets = SnippetStore(context: container.mainContext)
        let source = AuthenticatorStore(backing: MemoryAuthenticatorBacking())
        source.add(OTPAccount(issuer: "GitHub", account: "me", secret: "JBSWY3DPEHPK3PXP", algorithm: .sha256, digits: 8, period: 60))

        let without = BackupExporter.contents(store: store, snippets: snippets, secrets: nil, authenticators: source.owned)
        #expect(without.authenticators == nil)

        let with = BackupExporter.contents(store: store, snippets: snippets, secrets: [], authenticators: source.owned)
        let file = try BackupExporter.seal(with, passphrase: "pass")
        let document = try BackupImporter.open(file, passphrase: "pass")
        #expect(document.authenticators?.count == 1)
        #expect(document.authenticators?.first?.type == "otp")
        #expect(document.authenticators?.first?.secret == "JBSWY3DPEHPK3PXP")

        let target = AuthenticatorStore(backing: MemoryAuthenticatorBacking())
        let summary = BackupImporter.merge(document, store: store, snippets: snippets, secrets: nil, authenticators: target, maxAge: nil)
        #expect(summary.authenticatorsAdded == 1)
        let imported = try #require(target.owned.first)
        #expect(imported.spaceID == nil && imported.id != source.owned.first?.id)
        #expect(imported.algorithm == .sha256 && imported.digits == 8 && imported.period == 60)
        #expect(imported.code(at: .now) == source.owned.first?.code(at: .now))
        // Again: already here.
        let again = BackupImporter.merge(document, store: store, snippets: snippets, secrets: nil, authenticators: target, maxAge: nil)
        #expect(again.authenticatorsSkipped == 1 && target.owned.count == 1)
    }
}
