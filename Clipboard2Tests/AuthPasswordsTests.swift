import Testing
import Foundation
@testable import Clipboard2

// Passwords (docs/features/auth-autofill.md, phase 1): secrets with a username, sites and notes.

@MainActor
struct PasswordPayloadTests {
    @Test func plainSecretsKeepTheirBytesAndFingerprints() throws {
        let plain = SyncPayload.secret(SecretPayload(name: "DB", value: "hunter2", createdAt: 1_000))
        #expect(String(decoding: try plain.canonicalJSON(), as: UTF8.self)
                == #"{"createdAt":1000,"name":"DB","type":"secret","v":1,"value":"hunter2"}"#)
        // Empty extras are omitted, so a secret without them is byte-for-byte what 1.10 wrote.
        let empty = SyncPayload.secret(SecretPayload(name: "DB", value: "hunter2", createdAt: 1_000,
                                                     username: "  ", urls: ["", " "], notes: ""))
        #expect(try empty.canonicalJSON() == plain.canonicalJSON())
        #expect(try empty.fingerprint() == plain.fingerprint())
    }

    @Test func passwordFieldsRoundTripAndAreInTheFingerprint() throws {
        let base = SecretPayload(name: "Google", value: "pw", createdAt: 1_000)
        let password = SecretPayload(name: "Google", value: "pw", createdAt: 1_000, username: "me@gmail.com",
                                     urls: ["https://accounts.google.com", "youtube.com", "YouTube.com"], notes: "recovery")
        #expect(password.urls == ["https://accounts.google.com", "youtube.com"])
        let payload = SyncPayload.secret(password)
        let json = String(decoding: try payload.canonicalJSON(), as: UTF8.self)
        #expect(json.contains(#""username":"me@gmail.com""#))
        #expect(json.contains(#""urls":["https://accounts.google.com","youtube.com"]"#))
        #expect(json.contains(#""notes":"recovery""#))
        #expect(try SyncPayload.decode(try payload.canonicalJSON()) == payload)
        #expect(try payload.fingerprint() != SyncPayload.secret(base).fingerprint())
        #expect(try payload.withRev(9).fingerprint() == payload.fingerprint())

        var otherUser = password
        otherUser.username = "you@gmail.com"
        #expect(try SyncPayload.secret(otherUser).fingerprint() != payload.fingerprint())
        var otherSites = password
        otherSites.urls = ["google.com"]
        #expect(try SyncPayload.secret(otherSites).fingerprint() != payload.fingerprint())
    }

    @Test func oldPayloadsStillDecode() throws {
        let old = Data(#"{"v":1,"type":"secret","name":"DB","value":"x","createdAt":5}"#.utf8)
        guard case .secret(let secret) = try SyncPayload.decode(old) else { Issue.record("not a secret"); return }
        #expect(secret.username == nil && secret.urls == nil && secret.notes == nil)
        // A wrong type in an optional field doesn't lose the secret.
        let odd = Data(#"{"v":1,"type":"secret","name":"DB","value":"x","createdAt":5,"urls":"google.com"}"#.utf8)
        guard case .secret(let tolerated) = try SyncPayload.decode(odd) else { Issue.record("not a secret"); return }
        #expect(tolerated.value == "x" && tolerated.urls == nil)

        let otp = Data(#"{"v":1,"type":"otp","issuer":"GitHub","account":"a","secret":"JBSWY3DPEHPK3PXP","algorithm":"SHA1","digits":6,"period":30,"createdAt":1,"updatedAt":1}"#.utf8)
        guard case .otp(let decoded) = try SyncPayload.decode(otp) else { Issue.record("not an otp"); return }
        #expect(decoded.urls == nil)
    }

    @Test func authenticatorURLsRoundTripAndAreInTheFingerprint() throws {
        var authenticator = Authenticator(account: OTPAccount(issuer: "Acme", account: "me", secret: "JBSWY3DPEHPK3PXP"),
                                          createdAt: Date(timeIntervalSince1970: 1))
        let before = try SyncPayload.otp(authenticator.payload).fingerprint()
        #expect(!String(decoding: try SyncPayload.otp(authenticator.payload).canonicalJSON(), as: UTF8.self).contains("urls"))
        authenticator.urls = ["acme.io"]
        let payload = SyncPayload.otp(authenticator.payload)
        #expect(try payload.fingerprint() != before)
        guard case .otp(let decoded) = try SyncPayload.decode(try payload.canonicalJSON()) else { Issue.record("not an otp"); return }
        #expect(Authenticator(id: authenticator.id, payload: decoded, spaceID: nil)?.urls == ["acme.io"])
    }

    @Test func aRefCarriesItsExtrasIntoThePayload() {
        let ref = SecretRef(id: "x", name: "Google", createdAt: Date(timeIntervalSince1970: 1), username: "me",
                            urls: ["google.com"])
        let payload = SecretPayload(ref: ref, value: "pw", notes: "n")
        #expect(payload.username == "me" && payload.urls == ["google.com"] && payload.notes == "n")
        #expect(ref.isPassword)
        #expect(!SecretRef(id: "y", name: "Token", createdAt: nil).isPassword)
    }
}

@MainActor
struct PasswordSyncTests {
    @Test func passwordsSyncWithTheirFieldsAndEditsReSync() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)
        let id = mac1.secrets.add(name: "Google", value: "pw", username: "me@gmail.com",
                                  urls: ["accounts.google.com"], notes: "codes: 1234")
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        let received = try #require(mac2.secrets.refs[id.lowercased()])
        #expect(received.username == "me@gmail.com" && received.urls == ["accounts.google.com"])
        #expect(mac2.secrets.notes[id.lowercased()] == "codes: 1234")

        // A new site on mac1 reaches mac2.
        mac1.secrets.refs[id]?.urls = ["accounts.google.com", "youtube.com"]
        mac1.secrets.refs[id]?.updatedAt = .now.addingTimeInterval(1)
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        #expect(mac2.secrets.refs[id.lowercased()]?.urls == ["accounts.google.com", "youtube.com"])

        // Nothing changed: nothing is pushed again.
        let puts = await server.putCount
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        #expect(await server.putCount == puts)
    }

    /// Passwords are secrets: a member without Secrets never gets them.
    @Test func membersWithoutSecretsNeverGetPasswords() async throws {
        let server = FakeSyncServer()
        let alice = try await FakeUser.make("alice", on: server)
        let bob = try await FakeUser.make("bob", on: server)
        let group = try await makeGroup("Team", owner: alice, members: [bob])
        let aliceMac = try FakeDevice(alice), bobMac = try FakeDevice(bob)
        _ = try await server.setAccess(caller: "alice", space: group, uid: "bob", canSend: nil, canSeeSecrets: false)
        aliceMac.secrets.add(name: "Shared login", value: "pw", spaceID: group, username: "team", urls: ["acme.io"])
        try await aliceMac.engine.tick()
        try await bobMac.engine.tick()
        #expect(bobMac.secrets.syncSecrets.filter { $0.spaceID == group }.isEmpty)
        #expect(await server.live(space: group).contains { $0.category == "secret" })
    }
}

@MainActor
struct PasswordKeychainTests {
    @Test func usernameSitesAndNotesRoundTripThroughTheKeychain() throws {
        let ref = try #require(SecretVault.add(name: "Clipboard2 password test", value: "hunter2", username: " me ",
                                               urls: ["google.com", "google.com", "youtube.com"], notes: "n1"))
        defer { SecretVault.delete(id: ref.id) }
        let listed = try #require(SecretVault.list().first { $0.id == ref.id })
        #expect(listed.username == "me" && listed.urls == ["google.com", "youtube.com"] && listed.isPassword)
        #expect(listed.notesStamp != nil && SecretVault.notes(id: ref.id) == "n1")
        #expect(SecretVault.value(id: ref.id) == "hunter2")

        SecretVault.update(id: ref.id, username: .some(nil), urls: ["github.com"], notes: .some("n2"))
        let updated = try #require(SecretVault.list().first { $0.id == ref.id })
        #expect(updated.username == nil && updated.urls == ["github.com"] && SecretVault.notes(id: ref.id) == "n2")
        #expect(updated.notesStamp != listed.notesStamp)

        // Clearing everything makes it a plain secret again, with the original description.
        SecretVault.update(id: ref.id, urls: [], notes: .some(nil))
        #expect(SecretVault.extras(id: ref.id).descriptionValue == SecretExtras.plainDescription)
        #expect(SecretVault.notes(id: ref.id) == nil)
        #expect(SecretVault.list().first { $0.id == ref.id }?.isPassword == false)

        SecretVault.delete(id: ref.id)
        #expect(SecretVault.notes(id: ref.id) == nil)
    }

    @Test func plainSecretsAreStoredAsBefore() throws {
        let ref = try #require(SecretVault.add(name: "Clipboard2 plain test", value: "v"))
        defer { SecretVault.delete(id: ref.id) }
        #expect(SecretVault.extras(id: ref.id).isEmpty)
        #expect(SecretExtras(descriptionValue: "Clipboard2 secret").isEmpty)
        #expect(SecretExtras(descriptionValue: nil).isEmpty)
        // Renaming touches nothing else.
        SecretVault.update(id: ref.id, name: "Clipboard2 plain test 2")
        #expect(SecretVault.extras(id: ref.id).descriptionValue == SecretExtras.plainDescription)
    }
}

@MainActor
struct PasswordBackupTests {
    @Test func backupsCarryThePasswordFields() throws {
        let secret = BackupSecret(id: "a", name: "Google", value: "pw", createdAt: 1, username: "me",
                                  urls: ["google.com"], notes: "n")
        let encoded = try JSONEncoder().encode(secret)
        let decoded = try JSONDecoder().decode(BackupSecret.self, from: encoded)
        #expect(decoded == secret)
        // Old backups decode without them.
        let old = try JSONDecoder().decode(BackupSecret.self, from: Data(#"{"id":"a","name":"n","value":"v","createdAt":1}"#.utf8))
        #expect(old.username == nil && old.urls == nil && old.notes == nil)

        var authenticator = Authenticator(account: OTPAccount(issuer: "Acme", account: "me", secret: "JBSWY3DPEHPK3PXP"))
        authenticator.urls = ["acme.io"]
        let backup = BackupAuthenticator(authenticator)
        let round = try JSONDecoder().decode(BackupAuthenticator.self, from: try JSONEncoder().encode(backup))
        #expect(round.urls == ["acme.io"])
        let store = AuthenticatorStore(backing: MemoryAuthenticatorBacking())
        let document = BackupDocument(createdAt: 1, clips: [], snippets: [], folders: nil, secrets: nil, authenticators: [round])
        let stores = try TestStores()
        let summary = BackupImporter.merge(document, store: stores.store, snippets: stores.snippets, secrets: nil,
                                           authenticators: store, maxAge: nil)
        #expect(summary.authenticatorsAdded == 1)
        #expect(store.owned.first?.urls == ["acme.io"])
    }
}
