import Testing
import Foundation
import CryptoKit
@testable import Clipboard2

// Origins: Auth's sites edited by hand (docs/features/auth-autofill.md → Origins).

private func secretRef(_ name: String, sites: [String] = [], username: String? = nil, origin: String? = nil,
                       id: String = UUID().uuidString) -> SecretRef {
    SecretRef(id: id, name: name, createdAt: .now, username: username, urls: sites, originID: origin)
}

private func ownedAuthenticator(_ issuer: String, account: String = "me", urls: [String] = [], origin: String? = nil) -> AuthenticatorItem {
    var authenticator = Authenticator(account: OTPAccount(issuer: issuer, account: account, secret: "JBSWY3DPEHPK3PXP"))
    authenticator.urls = urls
    authenticator.originID = origin
    return .owned(authenticator)
}

private func sharedAuthenticator(_ issuer: String, spaceId: String = UUID().uuidString.lowercased()) -> AuthenticatorItem {
    .shared(SharedAuthenticator(spaceId: spaceId, ownerUid: "o", ownerName: "Owner", codesUntil: 0, updatedAt: 0, batch: nil,
                                issuer: issuer, account: "", addedAt: 0))
}

@MainActor
struct OriginGroupingTests {
    @Test func originsClaimRegistrableDomainsOfTheirSites() {
        let google = AuthOrigin(name: "Google", domains: ["accounts.google.com", "youtube.com"])
        let directory = OriginDirectory(origins: [google])
        #expect(directory.key(of: secretRef("Mail", sites: ["mail.google.com"])) == .origin(google.id))
        #expect(directory.key(of: secretRef("YT", sites: ["https://www.youtube.com/login"])) == .origin(google.id))
        #expect(directory.key(of: secretRef("Other", sites: ["github.com"])) == .source(.domain("github.com")))
        #expect(directory.key(of: secretRef("Plain")) == AuthGroupKey.none)
        // Any of a password's sites can file it, in order.
        #expect(directory.key(of: secretRef("Both", sites: ["github.com", "google.com"])) == .origin(google.id))
    }

    @Test func aReferenceWinsOverDomainsAndFallsBackWhenTheOriginIsGone() {
        let google = AuthOrigin(name: "Google", domains: ["google.com"])
        let work = AuthOrigin(name: "Work")
        let directory = OriginDirectory(origins: [google, work])
        let filed = secretRef("Work Google", sites: ["google.com"], origin: work.id)
        #expect(directory.key(of: filed) == .origin(work.id))
        // The reference names an origin this Mac doesn't have (deleted, or not synced yet): automatic.
        let orphan = secretRef("Lost", sites: ["github.com"], origin: UUID().uuidString.lowercased())
        #expect(directory.key(of: orphan) == .source(.domain("github.com")))
        let authenticator = ownedAuthenticator("GitHub", origin: work.id)
        #expect(directory.key(of: authenticator) == .origin(work.id))
    }

    @Test func entriesThatCantCarryAReferenceAreListedOnTheOrigin() {
        let shared = sharedAuthenticator("Acme Corp")
        let pj = AuthOrigin(name: "PJ Logistik", entries: [AuthEntryKey.of(shared)])
        let directory = OriginDirectory(origins: [pj])
        #expect(directory.key(of: shared) == .origin(pj.id))
        #expect(directory.key(of: sharedAuthenticator("Acme Corp")) == .source(.issuer("Acme Corp")))
    }

    @Test func issuerGroupsJoinAnOriginOfTheSameName() {
        let acme = AuthOrigin(name: " acme corp ")
        let directory = OriginDirectory(origins: [acme])
        #expect(directory.key(of: ownedAuthenticator("Acme Corp")) == .origin(acme.id))
        #expect(directory.key(of: ownedAuthenticator("GitHub")) == .source(.domain("github.com")))
    }

    @Test func theOldestOriginKeepsADomainTwoClaim() {
        let old = AuthOrigin(name: "Old", domains: ["example.org"], createdAt: Date(timeIntervalSince1970: 1))
        let new = AuthOrigin(name: "New", domains: ["www.example.org"], createdAt: Date(timeIntervalSince1970: 2))
        #expect(OriginDirectory(origins: [new, old]).origin(claiming: "example.org")?.id == old.id)
    }

    @Test func authGroupsUseOriginNamesAndKeepEmptyOriginsApart() {
        let google = AuthOrigin(name: "Google", domains: ["google.com"])
        let pj = AuthOrigin(name: "PJ Logistik")
        let directory = OriginDirectory(origins: [google, pj])
        let secrets = [secretRef("a", sites: ["accounts.google.com"], username: "me"), secretRef("b", sites: ["zed.dev"]),
                       secretRef("c")]
        let groups = PanelViewModel.authGroups(secrets: secrets, authenticators: [ownedAuthenticator("Google", account: "me")],
                                               lastUsed: [:], origins: directory)
        #expect(groups.map(\.title) == ["Google", "zed.dev", "No website"])
        #expect(groups[0].items.count == 2)
        #expect(groups[0].key == .origin(google.id))
        #expect(groups[0].origin?.id == google.id)
        let empty = AuthOriginGrouping.emptyOrigins(directory, used: Set(groups.map(\.key)))
        #expect(empty.map(\.id) == [pj.id])
        // An origin used recently comes first, by its own usage key.
        let recent = PanelViewModel.authGroups(secrets: secrets, authenticators: [], lastUsed: ["zed.dev": .now.addingTimeInterval(-9),
                                                                                                 "origin:" + google.id: .now],
                                               origins: directory)
        #expect(recent.map(\.title) == ["Google", "zed.dev", "No website"])
    }

    @Test func headingsOfOriginsOpenTheOrigin() {
        let origin = AuthOrigin(name: "Bank", domains: ["bank.example"], icon: .symbol("banknote"))
        let heading = AuthSourceHeading(source: .domain("bank.example"), origin: origin)
        #expect(heading.title == "Bank" && heading.key == .origin(origin.id))
        #expect(AuthSourceHeading(source: .domain("x.example")).key == .source(.domain("x.example")))
        #expect(AuthSourceHeading(source: nil).key == AuthGroupKey.none)
        #expect(AuthSourceHeading(source: .domain("x.example"), isSuggestion: true).key == nil)
    }

    @Test func suggestionsForAPageIncludeWhatItsOriginHolds() {
        let google = AuthOrigin(name: "Google", domains: ["google.com", "youtube.com"])
        let youtube = secretRef("yt", sites: ["youtube.com"])
        let filed = secretRef("filed", origin: google.id)
        let other = secretRef("other", sites: ["github.com"])
        let suggested = PanelViewModel.authSuggestions(secrets: [youtube, filed, other], authenticators: [], site: "google.com",
                                                       origins: OriginDirectory(origins: [google]))
        #expect(Set(suggested.map(\.id)) == Set([youtube, filed].map { PanelEntry.secret($0).id }))
        // Without origins, only the site's own passwords.
        #expect(PanelViewModel.authSuggestions(secrets: [youtube, filed, other], authenticators: [], site: "google.com").isEmpty)
    }

    @Test func iconsRoundTrip() {
        for icon: OriginIcon in [.favicon(nil), .favicon("accounts.google.com"), .letter, .symbol("house"), .emoji("🚚")] {
            #expect(OriginIcon(raw: icon.raw) == icon)
        }
        #expect(OriginIcon.favicon(nil).raw == nil)
        #expect(OriginIcon(raw: "bogus") == .favicon(nil))
    }
}

@MainActor
struct OriginStoreTests {
    private func makeStore() -> (OriginStore, MemoryOriginBacking, MemoryDocumentVault) {
        let backing = MemoryOriginBacking(), vault = MemoryDocumentVault()
        return (OriginStore(backing: backing, documents: vault), backing, vault)
    }

    @Test func persistsNotesDocumentsAndDetails() throws {
        let (store, backing, vault) = makeStore()
        var changes = 0
        store.onChange = { changes += 1 }
        let origin = try #require(store.create(name: " PJ Logistik ", domains: ["pj-logistik.at", " ", "PJ-LOGISTIK.at"]))
        #expect(origin.name == "PJ Logistik" && origin.domains == ["pj-logistik.at"])
        let note = try #require(store.addNote("Customer no. 4711\nCall Maria", to: origin.id))
        #expect(note.title == "Customer no. 4711")
        guard case .success(let document) = store.addDocument(Data("contract".utf8), name: "../Contract.pdf", to: origin.id) else {
            Issue.record("document not added")
            return
        }
        #expect(document.name == "Contract.pdf" && document.size == 8)
        #expect(vault.read(id: document.id) == Data("contract".utf8))
        // A second store on the same backing reads it all back.
        let reloaded = OriginStore(backing: backing, documents: vault)
        let stored = try #require(reloaded.origin(withID: origin.id))
        #expect(stored.notes.map(\.text) == ["Customer no. 4711\nCall Maria"])
        #expect(stored.documents.map(\.id) == [document.id])
        store.updateNote(note.id, text: "  ", in: origin.id)   // emptied: deleted
        #expect(store.origin(withID: origin.id)?.notes.isEmpty == true)
        store.removeDocument(document.id, from: origin.id)
        #expect(!vault.contains(id: document.id))
        #expect(changes >= 5)
        // Saving the same content again changes nothing.
        let before = changes
        #expect(store.save(try #require(store.origin(withID: origin.id))))
        #expect(changes == before)
        store.delete(id: origin.id)
        #expect(store.origins.isEmpty)
    }

    @Test func documentLimits() throws {
        let (store, _, _) = makeStore()
        let origin = try #require(store.create(name: "Docs"))
        for index in 0..<OriginStore.maxDocuments {
            guard case .success = store.addDocument(Data([UInt8(index)]), name: "\(index).txt", to: origin.id) else {
                Issue.record("document \(index) refused")
                return
            }
        }
        guard case .failure(.tooMany) = store.addDocument(Data([1]), name: "one too many", to: origin.id) else {
            Issue.record("13th document accepted")
            return
        }
    }

    @Test func mergeMovesEverythingAndTheSourceGoes() throws {
        let (store, _, vault) = makeStore()
        let shared = AuthEntryKey.shared("space-1")
        let source = try #require(store.create(name: "Gmail", domains: ["mail.google.com"], icon: .emoji("✉️"), entries: [shared]))
        let target = try #require(store.create(name: "Google", domains: ["google.com"]))
        store.addNote("recovery codes in the safe", to: source.id)
        guard case .success(let document) = store.addDocument(Data("pdf".utf8), name: "Backup codes.pdf", to: source.id) else {
            Issue.record("document not added")
            return
        }
        let merged = try #require(store.merge(source.id, into: target.id))
        #expect(store.origin(withID: source.id) == nil)
        #expect(merged.domains == ["google.com", "mail.google.com"])
        #expect(merged.notes.map(\.text) == ["recovery codes in the safe"])
        #expect(merged.entries == [shared])
        #expect(merged.icon == .emoji("✉️"))
        // The document moved under a new id (so the target uploads it before the source's blobs go).
        let moved = try #require(merged.documents.first)
        #expect(moved.id != document.id && moved.name == "Backup codes.pdf")
        #expect(vault.read(id: moved.id) == Data("pdf".utf8))
        #expect(!vault.contains(id: document.id))
    }

    @Test func mergeRefusesMoreDocumentsThanAnItemHolds() throws {
        let (store, _, _) = makeStore()
        let a = try #require(store.create(name: "A")), b = try #require(store.create(name: "B"))
        for index in 0..<7 {
            _ = store.addDocument(Data([1]), name: "a\(index)", to: a.id)
            _ = store.addDocument(Data([2]), name: "b\(index)", to: b.id)
        }
        #expect(store.merge(a.id, into: b.id) == nil)
        #expect(store.origin(withID: a.id) != nil)
    }

    @Test func pinningFilesAnEntryInOneOriginOnly() throws {
        let (store, _, _) = makeStore()
        let a = try #require(store.create(name: "A")), b = try #require(store.create(name: "B"))
        let entry = AuthEntryKey.shared("abc")
        store.pin(entry, to: a.id)
        store.pin(entry, to: b.id)
        #expect(store.origin(withID: a.id)?.entries == [])
        #expect(store.origin(withID: b.id)?.entries == [entry])
        store.pin(entry, to: nil)
        #expect(store.origin(withID: b.id)?.entries == [])
    }

    @Test func syncUpsertDropsDocumentsNoLongerListed() throws {
        let (store, _, vault) = makeStore()
        let origin = try #require(store.create(name: "S"))
        guard case .success(let document) = store.addDocument(Data("x".utf8), name: "x", to: origin.id) else { return }
        var payload = try #require(store.origin(withID: origin.id)).payload
        payload.documents = nil
        store.syncUpsert(id: origin.id, payload: payload)
        store.syncDidChange()
        #expect(store.origin(withID: origin.id)?.documents.isEmpty == true)
        #expect(!vault.contains(id: document.id))
    }

    @Test func encryptedVaultNeverWritesPlaintext() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OriginVault-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKeyBox()
        let vault = EncryptedFileDocumentVault(directory: directory, keyProvider: { key.key })
        let id = SyncCrypto.newID()
        #expect(vault.write(Data("top secret contract".utf8), id: id))
        let file = try #require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let raw = try Data(contentsOf: file)
        #expect(raw.range(of: Data("top secret".utf8)) == nil)
        #expect(vault.read(id: id) == Data("top secret contract".utf8))
        // Another key can't read it; a path-like id is refused.
        let other = EncryptedFileDocumentVault(directory: directory, keyProvider: { SymmetricKeyBox().key })
        #expect(other.read(id: id) == nil)
        #expect(!vault.write(Data(), id: "../evil"))
    }
}

private final class SymmetricKeyBox: Sendable {
    let key = SymmetricKey(size: .bits256)
}

@MainActor
struct OriginPayloadTests {
    @Test func originPayloadRoundTripsAndOmitsEmptyFields() throws {
        let origin = AuthOrigin(name: "Bank", domains: ["bank.example"], icon: .symbol("banknote"),
                                createdAt: Date(syncMillis: 1_000))
        let json = try SyncPayload.origin(origin.payload).canonicalJSON()
        let text = String(decoding: json, as: UTF8.self)
        #expect(text == #"{"createdAt":1000,"domains":["bank.example"],"icon":"symbol:banknote","name":"Bank","type":"origin","updatedAt":1000,"v":1}"#)
        guard case .origin(let decoded) = try SyncPayload.decode(json) else {
            Issue.record("not an origin")
            return
        }
        #expect(AuthOrigin(id: origin.id, payload: decoded) == origin)
        #expect(SyncPayload.origin(decoded).category == .origin)
    }

    @Test func entriesCarryTheirOriginAndPlainOnesKeepTheirBytes() throws {
        let plain = SecretPayload(name: "n", value: "v", createdAt: 1)
        #expect(!String(decoding: try SyncPayload.secret(plain).canonicalJSON(), as: UTF8.self).contains("origin"))
        let filed = SecretPayload(name: "n", value: "v", createdAt: 1, origin: "ABC")
        let decoded = try SyncPayload.decode(try SyncPayload.secret(filed).canonicalJSON())
        guard case .secret(let secret) = decoded else { Issue.record("not a secret"); return }
        #expect(secret.origin == "abc")
        let otp = OTPPayload(issuer: "I", account: "a", secret: "JBSWY3DPEHPK3PXP", algorithm: "SHA1", digits: 6, period: 30,
                             createdAt: 1, updatedAt: 1, origin: "def")
        guard case .otp(let back) = try SyncPayload.decode(try SyncPayload.otp(otp).canonicalJSON()) else { return }
        #expect(Authenticator(id: "x", payload: back, spaceID: nil)?.originID == "def")
        // The Keychain description keeps it too.
        let extras = SecretExtras(origin: "def")
        #expect(SecretExtras(descriptionValue: extras.descriptionValue).origin == "def")
        #expect(SecretExtras().descriptionValue == SecretExtras.plainDescription)
    }
}

@MainActor
struct OriginSyncTests {
    @Test func originsAndTheirDocumentsSyncBetweenMacs() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)
        let origin = try #require(mac1.origins.create(name: "PJ Logistik", domains: ["pj-logistik.at"]))
        mac1.origins.addNote("Fleet account 12", to: origin.id)
        guard case .success(let document) = mac1.origins.addDocument(Data("contract bytes".utf8), name: "Contract.pdf",
                                                                     to: origin.id) else {
            Issue.record("document not added")
            return
        }
        let id = mac1.secrets.add(name: "Portal", value: "pw", username: "roham")
        mac1.secrets.refs[id]?.originID = origin.id
        try await mac1.engine.tick()

        let remote = try #require(await server.item(space: user.personal, id: origin.id))
        #expect(remote.category == "origin" && remote.blobIds == [document.id])
        try await mac2.engine.tick()
        let received = try #require(mac2.origins.origin(withID: origin.id))
        #expect(received.name == "PJ Logistik" && received.notes.map(\.text) == ["Fleet account 12"])
        #expect(mac2.origins.documentData(document.id) == Data("contract bytes".utf8))
        #expect(mac2.secrets.refs.values.first?.originID == origin.id)
        // Grouped under it on the other Mac, by reference.
        #expect(OriginDirectory(origins: mac2.origins.origins).key(of: try #require(mac2.secrets.refs.values.first)) == .origin(origin.id))

        // Nothing changed: nothing is pushed again.
        let puts = await server.putCount
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        #expect(await server.putCount == puts)

        // Removing the document and renaming travel; deleting the origin too.
        mac2.origins.removeDocument(document.id, from: origin.id)
        var renamed = try #require(mac2.origins.origin(withID: origin.id))
        renamed.name = "PJ"
        mac2.origins.save(renamed)
        try await mac2.engine.tick()
        try await mac1.engine.tick()
        #expect(mac1.origins.origin(withID: origin.id)?.name == "PJ")
        #expect(mac1.origins.origin(withID: origin.id)?.documents.isEmpty == true)
        #expect(!mac1.origins.documents.contains(id: document.id))
        mac1.origins.delete(id: origin.id)
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        #expect(mac2.origins.origin(withID: origin.id) == nil)
    }

    @Test func aMissingDocumentBlobDoesntHoldUpTheOrigin() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)
        let origin = try #require(mac1.origins.create(name: "Lost docs"))
        _ = mac1.origins.addDocument(Data("x".utf8), name: "x.txt", to: origin.id)
        try await mac1.engine.tick()
        await server.loseBlobs()
        try await mac2.engine.tick()
        let received = try #require(mac2.origins.origin(withID: origin.id))
        #expect(received.documents.isEmpty && received.name == "Lost docs")
    }
}

@MainActor
struct OriginPanelTests {
    private func cleanUp(_ env: AppEnvironment, refs: [SecretRef], origins: [String]) {
        for ref in refs { env.secrets.delete(ref) }
        for id in origins { env.origins.delete(id: id) }
    }

    @Test func movingAnEntryFilesItUnderTheOrigin() throws {
        let env = AppEnvironment.shared
        let model = PanelViewModel(env: env)
        model.filter = .auth
        let ref = try #require(env.secrets.add(name: "Move test", value: "pw", urls: ["move-test.example"]))
        let target = try #require(env.origins.create(name: "Move target"))
        defer { cleanUp(env, refs: [ref], origins: [target.id]) }
        let entry = PanelEntry.secret(ref)
        #expect(model.originKey(of: entry) == .source(.domain("move-test.example")))
        model.moveEntry(entry, to: .origin(target.id))
        let moved = try #require(env.secrets.secrets.first { $0.id == ref.id })
        #expect(moved.originID == target.id)
        #expect(model.originKey(of: .secret(moved)) == .origin(target.id))
        model.refresh()
        #expect(model.authSourceStarts.values.contains { $0.origin?.id == target.id })
        // Back to automatic grouping.
        model.moveEntry(.secret(moved), to: .none)
        #expect(env.secrets.secrets.first { $0.id == ref.id }?.originID == nil)
    }

    @Test func sharedAuthenticatorsAreListedOnTheOriginInstead() throws {
        let env = AppEnvironment.shared
        let model = PanelViewModel(env: env)
        let target = try #require(env.origins.create(name: "Shared target"))
        defer { cleanUp(env, refs: [], origins: [target.id]) }
        let shared = sharedAuthenticator("Shared Issuer Test")
        #expect(!model.canRefile(.authenticator(shared)))
        model.file(.authenticator(shared), under: target.id)
        #expect(env.origins.origin(withID: target.id)?.entries == [AuthEntryKey.of(shared)])
        #expect(model.originKey(of: .authenticator(shared)) == .origin(target.id))
    }

    @Test func editingAnAutomaticGroupMakesItAnOrigin() throws {
        let env = AppEnvironment.shared
        let model = PanelViewModel(env: env)
        model.filter = .auth
        let ref = try #require(env.secrets.add(name: "Auto test", value: "pw", urls: ["https://login.auto-group.example"]))
        defer { cleanUp(env, refs: [ref], origins: env.origins.origins.filter { $0.domains.contains("auto-group.example") }.map(\.id)) }
        model.refresh()
        model.openOriginPage(.source(.domain("auto-group.example")))
        let page = try #require(model.originPage)
        #expect(model.mode == .originPage && page.name == "auto-group.example")
        #expect(model.originPageEntries(page.key).secrets.map(\.id) == [ref.id])
        page.newNote = "Support PIN 1234"
        model.addOriginNote()
        let origin = try #require(env.origins.origins.first { $0.domains == ["auto-group.example"] })
        #expect(page.key == .origin(origin.id))
        #expect(origin.notes.map(\.text) == ["Support PIN 1234"])
        // The password is filed there by its domain, without a reference.
        #expect(model.originKey(of: .secret(ref)) == .origin(origin.id))
        #expect(env.secrets.secrets.first { $0.id == ref.id }?.originID == nil)
        page.name = "Auto Group"
        page.domains = ["auto-group.example", "auto-group-cdn.example"]
        model.saveOriginDetails()
        #expect(env.origins.origin(withID: origin.id)?.name == "Auto Group")
        #expect(!page.hasUnsavedDetails)
        model.closeOriginPage()
        #expect(model.mode == .browse && model.originPage == nil)
    }

    @Test func aDomainOfAnotherSiteIsRefusedInFavourOfMerging() throws {
        let env = AppEnvironment.shared
        let model = PanelViewModel(env: env)
        model.filter = .auth
        let first = try #require(env.origins.create(name: "First", domains: ["claimed.example"]))
        let second = try #require(env.origins.create(name: "Second"))
        defer { cleanUp(env, refs: [], origins: [first.id, second.id]) }
        model.openOriginPage(.origin(second.id))
        let page = try #require(model.originPage)
        page.domains = ["www.claimed.example"]
        model.saveOriginDetails()
        #expect(page.error?.contains("First") == true)
        #expect(env.origins.origin(withID: second.id)?.domains.isEmpty == true)
    }

    @Test func mergingMovesEntriesAndOpensTheTarget() throws {
        let env = AppEnvironment.shared
        let model = PanelViewModel(env: env)
        model.filter = .auth
        let source = try #require(env.origins.create(name: "Merge source"))
        let target = try #require(env.origins.create(name: "Merge target", domains: ["merge-target.example"]))
        let ref = try #require(env.secrets.add(name: "Merge test", value: "pw", origin: source.id))
        defer { cleanUp(env, refs: [ref], origins: [source.id, target.id]) }
        env.origins.addNote("moved along", to: source.id)
        model.openOriginPage(.origin(source.id))
        model.mergeOrigin(into: .origin(target.id))
        #expect(env.origins.origin(withID: source.id) == nil)
        #expect(env.origins.origin(withID: target.id)?.notes.map(\.text) == ["moved along"])
        #expect(env.secrets.secrets.first { $0.id == ref.id }?.originID == target.id)
        #expect(model.originPage?.key == .origin(target.id))
    }

    @Test func newLoginFromThePageComesBackFiledThere() throws {
        let env = AppEnvironment.shared
        let model = PanelViewModel(env: env)
        model.filter = .auth
        let origin = try #require(env.origins.create(name: "Named only"))
        defer {
            cleanUp(env, refs: env.secrets.secrets.filter { $0.username == "page-login-user" }, origins: [origin.id])
        }
        model.openOriginPage(.origin(origin.id))
        let page = try #require(model.originPage)
        model.beginNewEntry(.password, onPage: page)
        let form = try #require(model.editSecretForm)
        #expect(model.mode == .editSecret)
        form.username = "page-login-user"
        form.value = "pw-123"
        model.submitEditSecret()
        let saved = try #require(env.secrets.secrets.first { $0.username == "page-login-user" })
        #expect(saved.originID == origin.id)
        #expect(model.mode == .originPage && model.originPage?.key == .origin(origin.id))
        // Esc in a form opened from the page goes back to the page too.
        model.beginNewEntry(.secret, onPage: try #require(model.originPage))
        model.resetMode()
        #expect(model.mode == .originPage)
    }

    @Test func editSiteIsOfferedOnAuthEntries() throws {
        let env = AppEnvironment.shared
        let model = PanelViewModel(env: env)
        model.filter = .auth
        let ref = try #require(env.secrets.add(name: "Edit site test", value: "pw", urls: ["edit-site.example"]))
        defer { cleanUp(env, refs: [ref], origins: []) }
        model.refresh()
        model.selectedID = PanelEntry.secret(ref).id
        #expect(model.availableActions.contains(.editSite))
        model.perform(.editSite)
        #expect(model.mode == .originPage && model.originPage?.key == .source(.domain("edit-site.example")))
        // Picking a row goes back to the list.
        model.click(.secret(ref))
        #expect(model.mode == .browse && model.originPage == nil)
    }

    @Test func aPastedLinkFillsTheAuthenticatorForm() {
        let form = AuthenticatorFormState(purpose: .add(from: nil))
        form.useLink("otpauth://totp/Acme:me@acme.example?secret=JBSWY3DPEHPK3PXP&issuer=Acme&digits=8")
        #expect(form.issuer == "Acme" && form.account == "me@acme.example" && form.digits == 8)
        #expect(!form.asksForSecret)
        guard case .success(let account) = form.makeAccount() else {
            Issue.record("no account")
            return
        }
        #expect(account.secret == "JBSWY3DPEHPK3PXP")
    }
}
