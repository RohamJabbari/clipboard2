import Testing
import Foundation
import Security
@testable import Clipboard2

// System autofill (docs/features/auth-autofill.md, phase 3): the move to the shared Keychain,
// what the extension offers and the identities macOS suggests, and the shared unlock window.

/// A Keychain in memory with the SecItem semantics Clipboard2 relies on. Like the data-protection
/// Keychain, an added item always gets a new creation date.
nonisolated final class MemoryKeychain: KeychainBackend, @unchecked Sendable {
    private struct Key: Hashable { var service: String; var account: String }
    private var items: [Key: (attributes: [String: Any], data: Data)] = [:]
    private var order: [Key] = []
    private let lock = NSLock()

    /// Adds fail after this many succeeded.
    var addsAllowed = Int.max
    /// Reads of values return something else (a copy that didn't come out right).
    var garbleReads = false
    var now = Date(timeIntervalSince1970: 2_000_000_000)

    private static var kept: [CFString] { [kSecAttrLabel, kSecAttrDescription, kSecAttrComment, kSecAttrGeneric] }

    private func matching(_ query: [CFString: Any]) -> [Key] {
        let service = query[kSecAttrService] as? String
        let account = query[kSecAttrAccount] as? String
        return order.filter { (service == nil || $0.service == service) && (account == nil || $0.account == account) }
    }

    func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        lock.lock(); defer { lock.unlock() }
        let keys = matching(query)
        guard let first = keys.first else { return (errSecItemNotFound, nil) }
        let all = (query[kSecMatchLimit] as? String) == (kSecMatchLimitAll as String)
        if query[kSecReturnData] as? Bool == true {
            guard !all else { return (errSecParam, nil) }   // like the login Keychain
            let data = items[first]!.data
            return (errSecSuccess, (garbleReads ? Data("garbled".utf8) : data) as CFData)
        }
        if all { return (errSecSuccess, keys.map { items[$0]!.attributes } as CFArray) }
        return (errSecSuccess, items[first]!.attributes as CFDictionary)
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        guard let service = attributes[kSecAttrService] as? String, let account = attributes[kSecAttrAccount] as? String
        else { return errSecParam }
        let key = Key(service: service, account: account)
        guard items[key] == nil else { return errSecDuplicateItem }
        guard addsAllowed > 0 else { return errSecIO }
        addsAllowed -= 1
        var stored: [String: Any] = [kSecAttrService as String: service, kSecAttrAccount as String: account,
                                     kSecAttrCreationDate as String: now, kSecAttrModificationDate as String: now]
        for attribute in Self.kept { if let value = attributes[attribute] { stored[attribute as String] = value } }
        items[key] = (stored, attributes[kSecValueData] as? Data ?? Data())
        order.append(key)
        return errSecSuccess
    }

    func update(_ query: [CFString: Any], _ changes: [CFString: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let keys = matching(query)
        guard !keys.isEmpty else { return errSecItemNotFound }
        for key in keys {
            for attribute in Self.kept { if let value = changes[attribute] { items[key]!.attributes[attribute as String] = value } }
            if let data = changes[kSecValueData] as? Data { items[key]!.data = data }
            items[key]!.attributes[kSecAttrModificationDate as String] = now
        }
        return errSecSuccess
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let keys = Set(matching(query))
        guard !keys.isEmpty else { return errSecItemNotFound }
        for key in keys { items[key] = nil }
        order.removeAll { keys.contains($0) }
        return errSecSuccess
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }

    /// An item as the app's login Keychain has it.
    func put(service: String, account: String, value: String, label: String? = nil, description: String? = nil,
             comment: String? = nil, generic: String? = nil, created: Date? = nil) {
        var attributes: [CFString: Any] = [kSecAttrService: service, kSecAttrAccount: account, kSecValueData: Data(value.utf8)]
        if let label { attributes[kSecAttrLabel] = label }
        if let description { attributes[kSecAttrDescription] = description }
        if let comment { attributes[kSecAttrComment] = comment }
        if let generic { attributes[kSecAttrGeneric] = Data(generic.utf8) }
        let previous = now
        if let created { now = created }
        _ = add(attributes)
        now = previous
    }

    func string(service: String, account: String) -> String? {
        data(service: service, account: account).map { String(decoding: $0, as: UTF8.self) }
    }
}

@MainActor
struct KeychainMigrationTests {
    private let created = Date(timeIntervalSince1970: 1_700_000_000)

    private func loginKeychain() -> MemoryKeychain {
        let login = MemoryKeychain()
        let extras = SecretExtras(username: "me@gmail.com", urls: ["https://accounts.google.com"]).descriptionValue
        login.put(service: KeychainServices.secrets, account: "pw-1", value: "hunter2", label: "Google", description: extras,
                  comment: "6f3a8f2e-0000-0000-0000-000000000001", generic: "space-1", created: created)
        login.put(service: KeychainServices.secrets, account: "plain-1", value: "token", label: "API token",
                  description: SecretExtras.plainDescription, created: created)
        login.put(service: KeychainServices.secretNotes, account: "pw-1", value: "recovery codes", label: "Clipboard2 notes")
        login.put(service: KeychainServices.authenticators, account: "otp-1", value: #"{"secret":"JBSWY3DPEHPK3PXP"}"#,
                  label: "GitHub", description: "Clipboard2 authenticator", generic: "auth-space")
        login.put(service: KeychainServices.sharedCodes, account: "share-1", value: "{}", label: "Shared")
        login.put(service: "at.softmaze.Clippy.other", account: "x", value: "stays")
        return login
    }

    @Test func movesEverythingThenDeletesTheOriginals() {
        let login = loginKeychain()
        let shared = MemoryKeychain()
        #expect(KeychainMigration.run(services: KeychainLocation.services, from: login, to: shared) == .moved(5))

        #expect(shared.string(service: KeychainServices.secrets, account: "pw-1") == "hunter2")
        #expect(shared.string(service: KeychainServices.secretNotes, account: "pw-1") == "recovery codes")
        #expect(shared.string(service: KeychainServices.authenticators, account: "otp-1") == #"{"secret":"JBSWY3DPEHPK3PXP"}"#)
        #expect(shared.string(service: KeychainServices.sharedCodes, account: "share-1") == "{}")
        let attrs = shared.attributes(service: KeychainServices.secrets, account: "pw-1") ?? [:]
        #expect(attrs[kSecAttrLabel as String] as? String == "Google")
        #expect(attrs[kSecAttrComment as String] as? String == "6f3a8f2e-0000-0000-0000-000000000001")
        #expect(attrs[kSecAttrGeneric as String] as? Data == Data("space-1".utf8))
        #expect(shared.attributes(service: KeychainServices.authenticators, account: "otp-1")?[kSecAttrGeneric as String] as? Data
                == Data("auth-space".utf8))

        // The username and sites stay; the creation date (part of what syncs) joins them.
        let extras = SecretExtras(descriptionValue: attrs[kSecAttrDescription as String] as? String)
        #expect(extras.username == "me@gmail.com")
        #expect(extras.urls == ["https://accounts.google.com"])
        #expect(extras.created == 1_700_000_000_000)
        let plain = SecretExtras(descriptionValue: shared.attributes(service: KeychainServices.secrets, account: "plain-1")?[kSecAttrDescription as String] as? String)
        #expect(plain.created == 1_700_000_000_000)
        #expect(plain.username == nil && plain.urls == nil)

        // Originals gone; other services untouched.
        #expect(login.count == 1)
        #expect(login.string(service: "at.softmaze.Clippy.other", account: "x") == "stays")
    }

    @Test func aFailedCopyKeepsTheOriginalsAndLeavesNoCopies() {
        let login = loginKeychain()
        let shared = MemoryKeychain()
        shared.addsAllowed = 2
        guard case .failed = KeychainMigration.run(services: KeychainLocation.services, from: login, to: shared) else {
            Issue.record("expected a failure"); return
        }
        #expect(login.count == 6)
        #expect(shared.count == 0)
        #expect(login.string(service: KeychainServices.secrets, account: "pw-1") == "hunter2")
    }

    @Test func aCopyThatDoesntReadBackTheSameIsUndone() {
        let login = loginKeychain()
        let shared = MemoryKeychain()
        shared.garbleReads = true
        guard case .failed = KeychainMigration.run(services: KeychainLocation.services, from: login, to: shared) else {
            Issue.record("expected a failure"); return
        }
        #expect(login.count == 6)
        #expect(shared.count == 0)
    }

    @Test func nothingToMoveTouchesNothing() {
        let login = MemoryKeychain()
        let shared = MemoryKeychain()
        shared.put(service: KeychainServices.secrets, account: "already", value: "moved earlier")
        #expect(KeychainMigration.run(services: KeychainLocation.services, from: login, to: shared) == .nothingToMove)
        #expect(shared.string(service: KeychainServices.secrets, account: "already") == "moved earlier")
    }

    @Test func leftoversInTheOldPlaceReplaceStaleCopies() {
        let login = MemoryKeychain()
        let shared = MemoryKeychain()
        login.put(service: KeychainServices.secrets, account: "a", value: "new", label: "A")
        shared.put(service: KeychainServices.secrets, account: "a", value: "old", label: "A")
        shared.put(service: KeychainServices.secrets, account: "b", value: "kept", label: "B")
        #expect(KeychainMigration.run(services: KeychainLocation.services, from: login, to: shared) == .moved(1))
        #expect(shared.string(service: KeychainServices.secrets, account: "a") == "new")
        #expect(shared.string(service: KeychainServices.secrets, account: "b") == "kept")
        #expect(login.count == 0)
    }

    @Test func anExistingCreationDateIsKept() {
        let description = SecretExtras(username: "me", created: 42).descriptionValue
        #expect(SecretExtras.movedDescription(description, created: created) == description)
        #expect(SecretExtras(descriptionValue: SecretExtras.movedDescription(nil, created: nil)).isEmpty)
    }

    @Test func whichKeychainAfterAMove() {
        #expect(KeychainLocation.useShared(after: .moved(3), movedBefore: false))
        #expect(KeychainLocation.useShared(after: .nothingToMove, movedBefore: false))
        // A failure keeps reading the old place, unless everything moved on an earlier launch.
        #expect(!KeychainLocation.useShared(after: .failed("x"), movedBefore: false))
        #expect(KeychainLocation.useShared(after: .failed("x"), movedBefore: true))
    }

    @Test func authenticatorsReadTheSameFromEitherKeychain() {
        let login = MemoryKeychain()
        let owned = Authenticator(account: OTPAccount(issuer: "GitHub", account: "octo", secret: "JBSWY3DPEHPK3PXP"), spaceID: "s1")
        #expect(KeychainAuthenticatorBacking(keychain: login).saveOwned(owned))
        let shared = MemoryKeychain()
        #expect(KeychainMigration.run(services: KeychainLocation.services, from: login, to: shared) == .moved(1))
        let loaded = KeychainAuthenticatorBacking(keychain: shared).loadOwned()
        #expect(loaded.map(\.id) == [owned.id])
        #expect(loaded.first?.spaceID == "s1")
        #expect(KeychainAuthenticatorBacking(keychain: login).loadOwned().isEmpty)
    }
}

@MainActor
struct AutoFillIdentityTests {
    private let github = Authenticator(account: OTPAccount(issuer: "GitHub", account: "octo", secret: "JBSWY3DPEHPK3PXP"))

    private func shared(issuer: String) -> SharedAuthenticator {
        SharedAuthenticator(spaceId: "share-1", ownerUid: "u", ownerName: "Ann", codesUntil: 0, updatedAt: 0, batch: nil,
                            issuer: issuer, account: "team@acme.com", addedAt: 0)
    }

    @Test func passwordsGetTheirSitesDomainsAndUsername() {
        let secrets = [
            SecretRef(id: "pw-1", name: "Google", createdAt: nil, username: "me@gmail.com",
                      urls: ["https://accounts.google.com/login", "youtube.com", "mail.google.com"]),
            SecretRef(id: "pw-2", name: "Router", createdAt: nil, username: "admin"),
            SecretRef(id: "plain", name: "API token", createdAt: nil),
        ]
        let inputs = AutoFillIdentities.passwordInputs(secrets)
        #expect(inputs.map(\.id) == ["pw-1", "pw-2"])   // plain secrets aren't offered
        #expect(inputs[0].domains == ["google.com", "youtube.com"])
        #expect(inputs[0].username == "me@gmail.com")
        #expect(inputs[1].domains.isEmpty)

        let entries = AutoFillIndex.build(passwords: inputs, codes: [])
        let identities = AutoFillIndex.identities(for: entries)
        #expect(identities == [
            .init(domain: "google.com", user: "me@gmail.com", recordIdentifier: "password:pw-1", isCode: false),
            .init(domain: "youtube.com", user: "me@gmail.com", recordIdentifier: "password:pw-1", isCode: false),
        ])
        // Without a site it's in the extension's list, never suggested.
        #expect(entries.map(\.id) == ["password:pw-1", "password:pw-2"])
    }

    @Test func authenticatorsBecomeOneTimeCodeIdentities() {
        var custom = Authenticator(account: OTPAccount(issuer: "Acme Corp", account: "me", secret: "JBSWY3DPEHPK3PXP"))
        custom.urls = ["https://login.acme.example.com"]
        let unknown = Authenticator(account: OTPAccount(issuer: "Some VPN", account: "me", secret: "JBSWY3DPEHPK3PXP"))
        let inputs = AutoFillIdentities.codeInputs([.owned(github), .owned(custom), .owned(unknown), .shared(shared(issuer: "Microsoft"))])
        #expect(inputs.map(\.domains) == [["github.com"], ["example.com"], [], ["microsoft.com"]])
        #expect(inputs.map(\.kind) == [.authenticator, .authenticator, .authenticator, .sharedCode])
        #expect(inputs[3].id == "share-1")

        let identities = AutoFillIndex.identities(for: AutoFillIndex.build(passwords: [], codes: inputs))
        #expect(identities.allSatisfy { $0.isCode })
        #expect(identities.contains(.init(domain: "github.com", user: "GitHub (octo)", recordIdentifier: "authenticator:\(github.id)", isCode: true)))
        #expect(identities.contains(.init(domain: "microsoft.com", user: "Microsoft (team@acme.com)", recordIdentifier: "sharedCode:share-1", isCode: true)))
        #expect(identities.count == 3)
    }

    @Test func freshEmailCodesOnly() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let codes = [
            AutoFillEmailCode(id: "e1", code: "123456", domain: "google.com", receivedAt: now.addingTimeInterval(-60)),
            AutoFillEmailCode(id: "e2", code: "654321", domain: "amazon.de", receivedAt: now.addingTimeInterval(-11 * 60)),
        ]
        let inputs = AutoFillIdentities.emailInputs(codes, now: now)
        #expect(inputs.map(\.id) == ["e1"])
        let identities = AutoFillIndex.identities(for: AutoFillIndex.build(passwords: [], codes: inputs))
        #expect(identities == [.init(domain: "google.com", user: "google.com", recordIdentifier: "emailCode:e1", isCode: true)])
    }

    @Test func listIsByTitlePasswordsBeforeCodes() {
        let entries = AutoFillIndex.build(
            passwords: [.init(id: "p", name: "GitHub", username: "octo", domains: ["github.com"]),
                        .init(id: "a", name: "Amazon", username: nil, domains: ["AMAZON.de", "amazon.de"])],
            codes: [.init(kind: .authenticator, id: "c", title: "GitHub", user: "octo", domains: ["github.com"])])
        #expect(entries.map(\.id) == ["password:a", "password:p", "authenticator:c"])
        #expect(entries[0].domains == ["amazon.de"])
        #expect(AutoFillEntry(recordIdentifier: "authenticator:c", in: entries)?.title == "GitHub")
        #expect(AutoFillEntry(recordIdentifier: "password:gone", in: entries) == nil)
    }

    @Test func theSitesItemsComeFirst() {
        let entries = AutoFillIndex.build(
            passwords: [.init(id: "1", name: "Amazon", username: "a", domains: ["amazon.de"]),
                        .init(id: "2", name: "Google", username: "g", domains: ["google.com"]),
                        .init(id: "3", name: "Not Google", username: "n", domains: ["notgoogle.com"])],
            codes: [])
        let ranked = AutoFillMatch.ranked(entries, serviceIdentifiers: ["https://accounts.google.com/signin"])
        #expect(ranked.map(\.itemID) == ["2", "1", "3"])
        #expect(AutoFillMatch.ranked(entries, serviceIdentifiers: ["google.com"]).first?.itemID == "2")
        #expect(AutoFillMatch.ranked(entries, serviceIdentifiers: [], search: "amaz").map(\.itemID) == ["1"])
        #expect(AutoFillMatch.ranked(entries, serviceIdentifiers: [], search: "notgoogle").map(\.itemID) == ["3"])
    }

    @Test func theExtensionReadsValuesAndCodes() throws {
        let keychain = MemoryKeychain()
        keychain.put(service: KeychainServices.secrets, account: "pw-1", value: "hunter2")
        #expect(KeychainAuthenticatorBacking(keychain: keychain).saveOwned(github))
        let now = Date(timeIntervalSince1970: 1_800_000_015)
        let batch = try #require(CodeBatch.make(for: github, now: now))
        var share = shared(issuer: "GitHub")
        share.batch = batch
        #expect(KeychainAuthenticatorBacking(keychain: keychain).saveShared(share))
        let vault = AutoFillVault(keychain: keychain)
        vault.writeEmailCodes([AutoFillEmailCode(id: "e1", code: "777111", domain: "google.com", receivedAt: now)])

        let entries = AutoFillIndex.build(
            passwords: [.init(id: "pw-1", name: "Google", username: "me", domains: ["google.com"])],
            codes: AutoFillIdentities.codeInputs([.owned(github), .shared(share)])
                + AutoFillIdentities.emailInputs(vault.emailCodes(), now: now))
        #expect(vault.writeIndex(entries))
        #expect(vault.index() == entries)

        let byKind = Dictionary(uniqueKeysWithValues: vault.index().map { ($0.kind, $0) })
        #expect(vault.password(for: byKind[.password]!) == "hunter2")
        #expect(vault.code(for: byKind[.authenticator]!, at: now) == github.code(at: now))
        #expect(vault.code(for: byKind[.sharedCode]!, at: now) == github.code(at: now))
        #expect(vault.code(for: byKind[.emailCode]!, at: now) == "777111")
        #expect(vault.code(for: byKind[.emailCode]!, at: now.addingTimeInterval(11 * 60)) == nil)
        #expect(vault.code(for: byKind[.password]!, at: now) == nil)
    }
}

@MainActor
struct AutoFillUnlockTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theWindowIsTheLaterOfGraceAndLeaveUnlocked() {
        let touchID = now.addingTimeInterval(-60)
        #expect(AutoFillUnlock.until(lastAuthentication: touchID, graceMinutes: 5, unlockedUntil: nil, now: now)
                == touchID.addingTimeInterval(300))
        #expect(AutoFillUnlock.until(lastAuthentication: touchID, graceMinutes: 5, unlockedUntil: now.addingTimeInterval(3_600), now: now)
                == now.addingTimeInterval(3_600))
        // "Ask every time": only an explicit Leave Unlocked counts.
        #expect(AutoFillUnlock.until(lastAuthentication: touchID, graceMinutes: 0, unlockedUntil: nil, now: now) == nil)
        // Over: nothing to share.
        #expect(AutoFillUnlock.until(lastAuthentication: now.addingTimeInterval(-600), graceMinutes: 5, unlockedUntil: nil, now: now) == nil)
        #expect(AutoFillUnlock.until(lastAuthentication: nil, graceMinutes: 5, unlockedUntil: now.addingTimeInterval(-1), now: now) == nil)
    }

    @Test func theExtensionOnlyTrustsAnOpenPlausibleWindow() {
        #expect(!AutoFillUnlock.isOpen(until: nil, now: now))
        #expect(AutoFillUnlock.isOpen(until: now.addingTimeInterval(60), now: now))
        #expect(!AutoFillUnlock.isOpen(until: now.addingTimeInterval(-1), now: now))
        #expect(AutoFillUnlock.isOpen(until: now.addingTimeInterval(UnlockDuration.oneWeek.interval), now: now))
        #expect(!AutoFillUnlock.isOpen(until: now.addingTimeInterval(30 * 86_400), now: now))
    }

    @Test func theWindowGoesThroughTheSharedKeychain() {
        let vault = AutoFillVault(keychain: MemoryKeychain())
        #expect(vault.unlockedUntil() == nil)
        vault.writeUnlock(until: now.addingTimeInterval(300))
        #expect(vault.unlockedUntil() == now.addingTimeInterval(300))
        vault.writeUnlock(until: now.addingTimeInterval(900))
        #expect(vault.unlockedUntil() == now.addingTimeInterval(900))
        vault.writeUnlock(until: nil)   // locked, slept or quit
        #expect(vault.unlockedUntil() == nil)
        #expect(AutoFillUnlock.decode(Data("junk".utf8)) == nil)
    }
}
