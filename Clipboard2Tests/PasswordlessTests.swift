import Testing
import Foundation
@testable import Clipboard2

// Passwordless accounts (docs/features/passwordless.md): crypto against the shared vectors,
// share splitting, session windows and expiry, and the account flows against the fake server.

private enum PasswordlessVectors {
    static let section: [String: Any] = {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/sync/test-vectors.json")
        let data = (try? Data(contentsOf: url)) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return json["passwordless"] as? [String: Any] ?? [:]
    }()

    static func object(_ name: String) -> [String: Any] { section[name] as? [String: Any] ?? [:] }
    static func list(_ name: String) -> [[String: Any]] { section[name] as? [[String: Any]] ?? [] }
}

private extension Dictionary where Key == String, Value == Any {
    func data(_ key: String) -> Data { Data(base64Encoded: self[key] as? String ?? "") ?? Data([0xFF]) }
    func text(_ key: String) -> String { self[key] as? String ?? "" }
}

struct PasswordlessCryptoTests {
    @Test func vectorsArePresent() {
        #expect(!PasswordlessVectors.object("deviceWrap").isEmpty)
        #expect(PasswordlessVectors.list("numbers").count == 5)
    }

    @Test func wrapsTheAccountKeyToADeviceExactlyLikeTheServer() throws {
        let v = PasswordlessVectors.object("deviceWrap")
        #expect(try SyncCrypto.publicKey(of: v.data("devicePriv")) == v.data("devicePub"))
        #expect(PasswordlessCrypto.deviceInfo(requestId: v.text("requestId")) == v.text("info"))
        #expect(PasswordlessCrypto.deviceAAD(uid: v.text("uid"), requestId: v.text("requestId")) == v.text("aad"))
        let wrapped = try PasswordlessCrypto.wrapAccountKey(v.data("accountKey"), uid: v.text("uid"), requestId: v.text("requestId"),
                                                            devicePublicKey: v.data("devicePub"),
                                                            ephemeralPrivateKey: v.data("ephPriv"), nonce: v.data("nonce"))
        #expect(wrapped == v.data("wrapped"))
        let opened = try PasswordlessCrypto.unwrapAccountKey(v.data("wrapped"), uid: v.text("uid"), requestId: v.text("requestId"),
                                                             devicePrivateKey: v.data("devicePriv"))
        #expect(opened == v.data("accountKey"))
    }

    @Test func aWrappedKeyOpensOnlyForThatDeviceUserAndRequest() throws {
        let ak = SyncCrypto.randomBytes(32)
        let device = SyncCrypto.newPrivateKey(), other = SyncCrypto.newPrivateKey()
        let wrapped = try PasswordlessCrypto.wrapAccountKey(ak, uid: "u1", requestId: "r1", devicePublicKey: try SyncCrypto.publicKey(of: device))
        #expect(try PasswordlessCrypto.unwrapAccountKey(wrapped, uid: "u1", requestId: "r1", devicePrivateKey: device) == ak)
        #expect(throws: (any Error).self) { try PasswordlessCrypto.unwrapAccountKey(wrapped, uid: "u1", requestId: "r1", devicePrivateKey: other) }
        #expect(throws: (any Error).self) { try PasswordlessCrypto.unwrapAccountKey(wrapped, uid: "u2", requestId: "r1", devicePrivateKey: device) }
        #expect(throws: (any Error).self) { try PasswordlessCrypto.unwrapAccountKey(wrapped, uid: "u1", requestId: "r2", devicePrivateKey: device) }
        var tampered = wrapped
        tampered[tampered.count - 1] ^= 1
        #expect(throws: (any Error).self) { try PasswordlessCrypto.unwrapAccountKey(tampered, uid: "u1", requestId: "r1", devicePrivateKey: device) }
    }

    @Test func numbersMatchTheServer() {
        for v in PasswordlessVectors.list("numbers") {
            let number = PasswordlessCrypto.matchNumber(requestId: v.text("requestId"), devicePublicKey: v.data("devicePub"))
            #expect(number == v["number"] as? Int)
            #expect((10...99).contains(number))
        }
    }

    @Test func aSwappedDeviceKeyChangesTheNumber() throws {
        // What lets an approver notice a server that substituted its own key.
        var differing = 0
        for _ in 0..<50 {
            let real = try SyncCrypto.publicKey(of: SyncCrypto.newPrivateKey())
            let fake = try SyncCrypto.publicKey(of: SyncCrypto.newPrivateKey())
            if PasswordlessCrypto.matchNumber(requestId: "r", devicePublicKey: real) != PasswordlessCrypto.matchNumber(requestId: "r", devicePublicKey: fake) {
                differing += 1
            }
        }
        #expect(differing >= 40)
    }

    @Test func choicesAreThreeDistinctTwoDigitNumbersIncludingTheRightOne() {
        for correct in [10, 42, 99] {
            for _ in 0..<200 {
                let choices = PasswordlessCrypto.choices(correct: correct)
                #expect(choices.count == 3)
                #expect(Set(choices).count == 3)
                #expect(choices.contains(correct))
                #expect(choices.allSatisfy { (10...99).contains($0) })
            }
        }
        // The right one isn't always in the same place.
        let positions = Set((0..<100).map { _ in PasswordlessCrypto.choices(correct: 50).firstIndex(of: 50)! })
        #expect(positions.count == 3)
    }

    @Test func sharesCombineOnlyWhenAllArePresent() {
        let secret = SyncCrypto.randomBytes(32)
        for count in 2...3 {
            let shares = PasswordlessCrypto.split(secret, into: count)
            #expect(shares.count == count)
            #expect(shares.allSatisfy { $0.count == 32 && $0 != secret })
            #expect(PasswordlessCrypto.combine(shares) == secret)
            // Any proper subset gives something else.
            for left in 0..<count {
                var some = shares
                some.remove(at: left)
                #expect(PasswordlessCrypto.combine(some) != secret)
            }
        }
    }

    @Test func sharesMatchTheServerVectors() throws {
        let v = PasswordlessVectors.object("shares")
        let shares = (v["shares"] as? [String] ?? []).compactMap { Data(base64Encoded: $0) }
        #expect(shares.count == 3)
        #expect(PasswordlessCrypto.combine(shares) == v.data("secret"))
        // Splitting with the same random shares gives the same last share.
        var given = Array(shares.prefix(2))
        let split = PasswordlessCrypto.split(v.data("secret"), into: 3) { _ in given.removeFirst() }
        #expect(split == shares)
    }

    @Test func contactSharesWrapLikeTheServer() throws {
        let v = PasswordlessVectors.object("recoveryShare")
        #expect(PasswordlessCrypto.shareInfo(setupId: v.text("setupId")) == v.text("info"))
        #expect(PasswordlessCrypto.shareAAD(setupId: v.text("setupId"), contactUid: v.text("contactUid")) == v.text("aad"))
        let wrapped = try PasswordlessCrypto.wrap(v.data("share"), to: v.data("contactPub"), info: v.text("info"), aad: v.text("aad"),
                                                  ephemeralPrivateKey: v.data("ephPriv"), nonce: v.data("nonce"))
        #expect(wrapped == v.data("wrapped"))
        #expect(try PasswordlessCrypto.unwrap(v.data("wrapped"), privateKey: v.data("contactPriv"), info: v.text("info"), aad: v.text("aad"))
                == v.data("share"))
        let requestId = PasswordlessVectors.object("deviceWrap").text("requestId")
        #expect(PasswordlessCrypto.recoveredInfo(recoveryId: requestId) == v.text("deviceInfo"))
        #expect(PasswordlessCrypto.recoveredAAD(recoveryId: requestId, holder: v.text("contactUid")) == v.text("deviceAad"))
    }

    @Test func aRecoveryPutsTheAccountKeyBackTogether() throws {
        // Owner splits, the contact re-wraps to the new device, the server wraps its own share.
        let ak = SyncCrypto.randomBytes(32)
        let contact = SyncCrypto.newPrivateKey(), device = SyncCrypto.newPrivateKey()
        let devicePub = try SyncCrypto.publicKey(of: device)
        let setupId = SyncCrypto.newID(), recoveryId = SyncCrypto.newID()
        let shares = PasswordlessCrypto.split(ak, into: 2)
        let toContact = try PasswordlessCrypto.wrap(shares[0], to: try SyncCrypto.publicKey(of: contact),
                                                    info: PasswordlessCrypto.shareInfo(setupId: setupId),
                                                    aad: PasswordlessCrypto.shareAAD(setupId: setupId, contactUid: "c"))
        let opened = try PasswordlessCrypto.unwrap(toContact, privateKey: contact, info: PasswordlessCrypto.shareInfo(setupId: setupId),
                                                   aad: PasswordlessCrypto.shareAAD(setupId: setupId, contactUid: "c"))
        let fromContact = try PasswordlessCrypto.wrap(opened, to: devicePub, info: PasswordlessCrypto.recoveredInfo(recoveryId: recoveryId),
                                                      aad: PasswordlessCrypto.recoveredAAD(recoveryId: recoveryId, holder: "c"))
        let fromServer = try PasswordlessCrypto.wrap(shares[1], to: devicePub, info: PasswordlessCrypto.recoveredInfo(recoveryId: recoveryId),
                                                     aad: PasswordlessCrypto.recoveredAAD(recoveryId: recoveryId, holder: "server"))
        let parts = try [(fromContact, "c"), (fromServer, "server")].map {
            try PasswordlessCrypto.unwrap($0.0, privateKey: device, info: PasswordlessCrypto.recoveredInfo(recoveryId: recoveryId),
                                          aad: PasswordlessCrypto.recoveredAAD(recoveryId: recoveryId, holder: $0.1))
        }
        #expect(PasswordlessCrypto.combine(parts) == ak)
        // A share labelled as the server's can't pass as the contact's.
        #expect(throws: (any Error).self) {
            try PasswordlessCrypto.unwrap(fromServer, privateKey: device, info: PasswordlessCrypto.recoveredInfo(recoveryId: recoveryId),
                                          aad: PasswordlessCrypto.recoveredAAD(recoveryId: recoveryId, holder: "c"))
        }
    }
}

struct SessionWindowTests {
    @Test func windowsInMillisecondsAndBack() {
        #expect(SessionWindow.hour.milliseconds == 3_600_000)
        #expect(SessionWindow.day.milliseconds == 86_400_000)
        #expect(SessionWindow.week.milliseconds == 604_800_000)
        #expect(SessionWindow.indefinitely.milliseconds == nil)
        #expect(SessionWindow.custom(3 * 86_400).milliseconds == 259_200_000)
        for window in [SessionWindow.hour, .day, .week, .indefinitely, .custom(90 * 60)] {
            #expect(SessionWindow(milliseconds: window.milliseconds) == window)
        }
    }

    @Test func customWindowsStayInRange() {
        #expect(SessionWindow.custom(15 * 60).isValid)
        #expect(SessionWindow.custom(365 * 86_400).isValid)
        #expect(!SessionWindow.custom(14 * 60).isValid)
        #expect(!SessionWindow.custom(366 * 86_400).isValid)
        #expect(!SessionWindow.custom(60).canStart(acknowledgement: ""))
    }

    @Test func indefinitelyNeedsTheExactSentence() {
        #expect(!SessionWindow.indefinitely.canStart(acknowledgement: ""))
        #expect(!SessionWindow.indefinitely.canStart(acknowledgement: "i understand the risks and i wish to proceed"))
        #expect(!SessionWindow.indefinitely.canStart(acknowledgement: "I understand the risks and I wish to proceed."))
        #expect(!SessionWindow.indefinitely.canStart(acknowledgement: "I understand"))
        #expect(SessionWindow.indefinitely.canStart(acknowledgement: "I understand the risks and I wish to proceed"))
        #expect(SessionWindow.indefinitely.canStart(acknowledgement: "  I understand the risks and I wish to proceed\n"))
        #expect(SessionWindow.day.canStart(acknowledgement: ""))
    }

    @Test func titles() {
        #expect(SessionWindow.hour.title == "1 hour")
        #expect(SessionWindow.custom(3 * 86_400).title == "3 days")
        #expect(SessionWindow.custom(14 * 86_400).title == "2 weeks")
        #expect(SessionWindow.custom(90 * 60).title == "90 minutes")
        #expect(SessionWindow.custom(5 * 3600).title == "5 hours")
    }

    @Test func expiryRules() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SessionWindow.day.expiry(from: now) == now.addingTimeInterval(86_400))
        #expect(SessionWindow.indefinitely.expiry(from: now) == nil)
        #expect(!SessionExpiry.isExpired(nil, now: now))
        #expect(!SessionExpiry.isExpired(now.addingTimeInterval(1), now: now))
        #expect(SessionExpiry.isExpired(now, now: now))
        #expect(SessionExpiry.isExpired(now.addingTimeInterval(-1), now: now))
        #expect(SessionExpiry.remaining(now.addingTimeInterval(-5), now: now) == 0)
        #expect(SessionExpiry.remaining(nil, now: now) == nil)
    }

    @Test func otherDevicesMayOnlyShortenAWindow() {
        let now = Date.now
        let day = now.addingTimeInterval(86_400), hour = now.addingTimeInterval(3600)
        #expect(SessionExpiry.canChange(current: day, to: hour, isThisDevice: false))
        #expect(!SessionExpiry.canChange(current: hour, to: day, isThisDevice: false))
        #expect(!SessionExpiry.canChange(current: hour, to: nil, isThisDevice: false))
        #expect(SessionExpiry.canChange(current: nil, to: day, isThisDevice: false))
        #expect(SessionExpiry.canChange(current: hour, to: nil, isThisDevice: true))
    }

    @Test func requestsSendNullForIndefinitelyWithTheAcknowledgement() throws {
        let device = DeviceInfo(publicKey: Data([4]), name: "Mac", platform: "macos")
        let forever = WindowedRequest(identifier: "alice", method: nil, device: device, window: .indefinitely,
                                      acknowledgement: SessionWindow.acknowledgement)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(forever)) as? [String: Any])
        #expect(json.keys.contains("windowMs"))
        #expect(json["windowMs"] is NSNull)
        #expect(json["acknowledgement"] as? String == SessionWindow.acknowledgement)
        let hour = WindowedRequest(identifier: "alice", method: "contacts", device: device, window: .hour, acknowledgement: "x")
        let hourJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(hour)) as? [String: Any])
        #expect(hourJSON["windowMs"] as? Int == 3_600_000)
        #expect(hourJSON["acknowledgement"] == nil)
        #expect(hourJSON["method"] as? String == "contacts")
    }

    @Test func devicesReadTheirWindow() {
        let remote = RemoteDevice(id: "d", deviceName: "Mac", createdAt: 0, lastUsedAt: 0, current: false, kind: "device",
                                  platform: "macos", windowMs: 3_600_000, expiresAt: 1_800_000_000_000, country: "AT", city: "Vienna")
        let device = SyncDevice(remote)
        #expect(device.isDeviceSession)
        #expect(device.window == .hour)
        #expect(device.expiresAt == Date(syncMillis: 1_800_000_000_000))
        #expect(device.location == "Vienna, AT")
        let password = SyncDevice(RemoteDevice(id: "p", deviceName: nil, createdAt: 0, lastUsedAt: 0, current: true))
        #expect(!password.isDeviceSession && password.window == nil && password.expiresAt == nil)
    }
}

@MainActor
struct PasswordlessAccountTests {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func signsUpWithoutAPasswordAndTrustsThisMacIndefinitely() async throws {
        let server = FakeSyncServer()
        let mac = try AccountHarness(server)
        await mac.account.signUpPasswordless(email: "Alice@Example.com", username: "alice", inviteCode: "AAAA-BBBB-CCCC-DDDD")
        #expect(mac.account.isSignedIn)
        let stored = try #require(mac.credentials.saved)
        #expect(stored.isDeviceSession == true)
        #expect(stored.expiresAt == nil)
        #expect(stored.devicePrivateKey?.count == 32)
        #expect(stored.accountKey.count == 32)
        #expect(await server.accounts["alice@example.com"]?.passwordless == true)
        #expect(mac.account.isPasswordlessDevice)
    }

    @Test func aNewMacGetsInOnlyWithTheRightNumber() async throws {
        let server = FakeSyncServer()
        let mac1 = try AccountHarness(server), mac2 = try AccountHarness(server)
        await mac1.account.signUpPasswordless(email: "a@b.at", username: "alice", inviteCode: "AAAA-BBBB-CCCC-DDDD")
        mac1.store.ingest(.text("from the first Mac"))
        await mac1.settle()

        // Wrong number: refused, and the new Mac is told.
        await mac2.account.startDeviceLogin(identifier: "alice", window: .hour)
        let first = try #require(mac2.account.deviceLogin)
        await mac1.account.refreshSecurity()
        let request = try #require(mac1.account.deviceRequests.first)
        let wrong = first.number == 99 ? 98 : first.number + 1
        await #expect(throws: SyncAccountError.numberMismatch) { try await mac1.account.approve(request, picked: wrong) }
        await waitUntil { mac2.account.deviceLogin?.status != .waiting }
        #expect(mac2.account.deviceLogin?.status == .mismatch)
        #expect(!mac2.account.isSignedIn)
        mac2.account.dismissDeviceLogin()

        // Right number: in, with the same account key and a one-hour window.
        await mac2.account.startDeviceLogin(identifier: "a@b.at", window: .hour)
        let second = try #require(mac2.account.deviceLogin)
        await mac1.account.refreshSecurity()
        let next = try #require(mac1.account.deviceRequests.first)
        try await mac1.account.approve(next, picked: second.number)
        await waitUntil { mac2.account.isSignedIn }
        #expect(mac2.account.isSignedIn)
        let stored = try #require(mac2.credentials.saved)
        #expect(stored.accountKey == mac1.credentials.saved?.accountKey)
        #expect(stored.isDeviceSession == true)
        let left = try #require(stored.expiresAt).timeIntervalSinceNow
        #expect(left > 3500 && left <= 3600)
        await mac2.settle()
        #expect(mac2.store.allItems().map(\.text) == ["from the first Mac"])
    }

    @Test func indefinitelyIsRefusedWithoutTheSentence() async throws {
        let server = FakeSyncServer()
        let mac = try AccountHarness(server)
        await mac.account.startDeviceLogin(identifier: "alice", window: .indefinitely, acknowledgement: "yes")
        #expect(mac.account.deviceLogin == nil)
        #expect(mac.account.errorMessage == SyncAccountError.acknowledgementNeeded.errorDescription)
        await mac.account.startDeviceLogin(identifier: "alice", window: .indefinitely, acknowledgement: SessionWindow.acknowledgement)
        #expect(mac.account.deviceLogin != nil)
        mac.account.cancelDeviceLogin()
    }

    @Test func theWindowEndingWipesKeysAndSyncedData() async throws {
        let server = FakeSyncServer()
        let mac1 = try AccountHarness(server), mac2 = try AccountHarness(server)
        await mac1.account.signUpPasswordless(email: "a@b.at", username: "alice", inviteCode: "AAAA-BBBB-CCCC-DDDD")
        mac1.store.ingest(.text("secret plans"))
        await mac1.settle()
        await mac2.account.startDeviceLogin(identifier: "alice", window: .hour)
        let progress = try #require(mac2.account.deviceLogin)
        await mac1.account.refreshSecurity()
        try await mac1.account.approve(try #require(mac1.account.deviceRequests.first), picked: progress.number)
        await waitUntil { mac2.account.isSignedIn }
        await mac2.settle()
        #expect(mac2.store.allItems().map(\.text) == ["secret plans"])
        mac2.store.ingest(.text("copied on the borrowed Mac only"))

        // Two hours later the window is over.
        mac2.account.clock = { Date.now.addingTimeInterval(2 * 3600) }
        await mac2.account.poll()
        #expect(!mac2.account.isSignedIn)
        #expect(mac2.credentials.saved == nil)
        #expect(!mac2.store.allItems().map(\.text).contains("secret plans"))
        #expect(mac2.account.notice?.contains("window ended") == true)
        // The first Mac is untouched.
        #expect(mac1.account.isSignedIn)
        #expect(mac1.store.allItems().map(\.text) == ["secret plans"])
    }

    @Test func anExpiredSessionIsWipedAtLaunch() async throws {
        let server = FakeSyncServer()
        let mac = try AccountHarness(server)
        await mac.account.signUpPasswordless(email: "a@b.at", username: "alice", inviteCode: "AAAA-BBBB-CCCC-DDDD")
        var stored = try #require(mac.credentials.saved)
        stored.expiresAt = Date.now.addingTimeInterval(-60)
        mac.credentials.saved = stored
        let relaunched = try AccountHarnessSharing(credentials: mac.credentials, server: server)
        relaunched.account.start()
        #expect(!relaunched.account.isSignedIn)
        #expect(mac.credentials.saved == nil)
    }
}

/// A second SyncAccount over the same stored credentials, like relaunching the app.
@MainActor
final class AccountHarnessSharing {
    let harness: AccountHarness
    var account: SyncAccount { harness.account }

    init(credentials: MemoryCredentials, server: FakeSyncServer) throws {
        harness = try AccountHarness(server, credentials: credentials)
    }
}
