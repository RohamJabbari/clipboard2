import Foundation
import SwiftData
import Testing
@testable import Clipboard2

// MARK: - Contacts and the Inbox (PROTOCOL.md → Contacts)

struct ContactsAPITests {
    @Test func spacesAskForContactsAndContactRoutesMatchTheProtocol() async throws {
        let transport = StubTransport(body: #"{"spaces":[]}"#)
        let api = SyncAPI(base: URL(string: "https://api.example")!, transport: transport) { "T" }
        _ = try await api.spaces()
        #expect(transport.requests.last?.url?.absoluteString == "https://api.example/v1/spaces?include=direct")

        _ = try? await api.user(named: "Größe_2.0")
        #expect(transport.requests.last?.url?.absoluteString == "https://api.example/v1/users/Gr%C3%B6%C3%9Fe_2.0")

        _ = try? await api.requestContact(username: "sam", spaceId: "s1", wrappedKey: Data([1]), recipientWrappedKey: Data([2]))
        let request = try #require(transport.requests.last)
        #expect(request.httpMethod == "POST" && request.url?.path() == "/v1/contacts/requests")
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body == ["username": "sam", "spaceId": "s1", "wrappedKey": "AQ==", "recipientWrappedKey": "Ag=="])

        try await api.deleteContact(spaceId: "s1")
        #expect(transport.requests.last?.httpMethod == "DELETE")
        #expect(transport.requests.last?.url?.path() == "/v1/contacts/s1")
    }

    @Test func contactCodesAreTold() throws {
        let json = #"{"spaceId":"s","sealedKey":"AQ==","encryptedName":null,"memberCount":1,"expiresAt":5,"kind":"direct","ownerName":"sam"}"#
        let details = try JSONDecoder().decode(InviteDetails.self, from: Data(json.utf8))
        #expect(details.isContactCode && details.ownerName == "sam")
        // Servers from before contacts send no kind: a group.
        let old = try JSONDecoder().decode(InviteDetails.self, from: Data(#"{"spaceId":"s","sealedKey":"AQ==","memberCount":2,"expiresAt":5}"#.utf8))
        #expect(!old.isContactCode)
    }
}

/// Two accounts on one fake server, signed up and synced.
@MainActor
private func pair(_ server: FakeSyncServer, aliceName: String = "useralice", bobName: String = "userbob")
async throws -> (alice: AccountHarness, bob: AccountHarness) {
    let alice = try AccountHarness(server), bob = try AccountHarness(server)
    await alice.account.signUp(email: "alice@x.at", password: "alice password", username: aliceName)
    await bob.account.signUp(email: "bob@x.at", password: "bob password", username: bobName)
    await alice.settle()
    await bob.settle()
    return (alice, bob)
}

/// Makes them contacts the username way: alice asks, bob accepts.
@MainActor
private func befriend(_ alice: AccountHarness, _ bob: AccountHarness, as username: String = "userbob") async throws -> String {
    let request = try await alice.account.requestContact(username: username)
    await bob.account.refreshContacts()
    let incoming = try #require(bob.account.contactRequests.incoming.first)
    try await bob.account.accept(incoming)
    await bob.settle()
    await alice.settle()
    return request.spaceId
}

@MainActor
struct ContactsTests {
    @Test func aRequestWrapsTheKeyToBothPeopleAndNothingFlowsUntilAccepted() async throws {
        let server = FakeSyncServer()
        let (alice, bob) = try await pair(server)
        let aliceUid = try #require(alice.credentials.saved?.uid), bobUid = try #require(bob.credentials.saved?.uid)

        let request = try await alice.account.requestContact(username: " @UserBob ")
        #expect(request.uid == bobUid && request.name == "userbob")
        #expect(alice.account.contactRequests.outgoing.map(\.spaceId) == [request.spaceId])

        // SK is wrapped to each of them, bound to their own uid.
        let space = request.spaceId
        let mine = try #require(await server.spaces[space]?.members[aliceUid]?.wrappedKey)
        let theirs = try #require(await server.contactRequests[space]?.recipientWrappedKey)
        let alicePriv = try #require(alice.credentials.saved?.privateKey), bobPriv = try #require(bob.credentials.saved?.privateKey)
        let key = try SyncCrypto.unwrapSpaceKey(mine, spaceId: space, uid: aliceUid, privateKey: alicePriv)
        #expect(try SyncCrypto.unwrapSpaceKey(theirs, spaceId: space, uid: bobUid, privateKey: bobPriv) == key)
        #expect(throws: (any Error).self) { try SyncCrypto.unwrapSpaceKey(theirs, spaceId: space, uid: aliceUid, privateKey: bobPriv) }
        #expect(throws: (any Error).self) { try SyncCrypto.unwrapSpaceKey(theirs, spaceId: "other", uid: bobUid, privateKey: bobPriv) }

        // Pending: neither lists a contact, and the server refuses writes into the space.
        await alice.settle()
        #expect(alice.account.contacts.isEmpty)
        let ciphertext = try SyncCrypto.seal(Data("{}".utf8), key: key, aad: "x")
        await #expect(throws: SyncAPIError.self) {
            _ = try await alice.account.makeAPI().putItem(spaceId: space, itemId: SyncCrypto.newID(),
                ItemUpload(category: "history", sortAt: 1, updatedAt: 1, ciphertext: ciphertext, blobIds: []))
        }

        await bob.account.refreshContacts()
        let incoming = try #require(bob.account.contactRequests.incoming.first)
        #expect(incoming.name == "useralice" && incoming.spaceId == space)
        try await bob.account.accept(incoming)
        #expect(bob.account.contactRequests.incoming.isEmpty)
        await bob.settle()
        await alice.settle()
        #expect(bob.account.contacts.map(\.name) == ["useralice"])
        #expect(alice.account.contacts.map(\.name) == ["userbob"])
        #expect(alice.account.contacts.first?.id == space && alice.account.contacts.first?.uid == bobUid)
        #expect(alice.account.contactRequests.outgoing.isEmpty)
        // Contacts aren't groups.
        #expect(alice.account.groups.isEmpty && bob.account.groups.isEmpty)
    }

    @Test func requestsAreRefusedWithClearReasons() async throws {
        let server = FakeSyncServer()
        let (alice, bob) = try await pair(server)
        await #expect(throws: SyncAccountError.unknownUsername("nobody")) { try await alice.account.requestContact(username: "nobody") }
        await #expect(throws: SyncAccountError.unknownUsername("x")) { try await alice.account.requestContact(username: "x") }
        await #expect(throws: SyncAccountError.cantAddYourself) { try await alice.account.requestContact(username: "UserAlice") }

        try await alice.account.requestContact(username: "userbob")
        await #expect(throws: SyncAccountError.alreadyContacts("userbob")) { try await alice.account.requestContact(username: "userbob") }
        // Either way round.
        await #expect(throws: SyncAccountError.alreadyContacts("useralice")) { try await bob.account.requestContact(username: "useralice") }

        // Declined: the space is gone and they can try again.
        await bob.account.refreshContacts()
        try await bob.account.dismiss(try #require(bob.account.contactRequests.incoming.first))
        await alice.account.refreshContacts()
        #expect(alice.account.contactRequests.outgoing.isEmpty)
        #expect(await server.spaces.values.allSatisfy { $0.kind != "direct" })
        try await alice.account.requestContact(username: "userbob")

        #expect(SyncAccountError.contactLimit("You can have at most 200 contacts").errorDescription == "You can have at most 200 contacts.")
    }

    @Test func aContactCodeAddsWhoeverEntersItOnce() async throws {
        let server = FakeSyncServer()
        let (alice, bob) = try await pair(server)
        let carol = try AccountHarness(server)
        await carol.account.signUp(email: "carol@x.at", password: "carol password", username: "usercarol")

        let code = try await alice.account.createContactCode()
        #expect(SyncCrypto.Invite.parse(code) != nil)
        #expect(alice.account.contactCodes.count == 1)

        // The usual invite entry tells a contact code apart from a group's.
        let preview = try await bob.account.previewInvite(code: code.lowercased())
        #expect(preview.isContact && preview.name == "useralice")
        let contact = try await bob.account.addContact(preview)
        #expect(contact.name == "useralice" && bob.account.contacts.map(\.id) == [contact.id])
        await #expect(throws: SyncAccountError.invalidInviteCode) { try await bob.account.join(preview) }

        // Single use.
        await #expect(throws: SyncAccountError.inviteNotFound) { try await carol.account.previewInvite(code: code) }
        await alice.settle()
        #expect(alice.account.contacts.map(\.name) == ["userbob"])
        #expect(alice.account.contactCodes.isEmpty)

        // Your own code, and someone you're already in touch with.
        let own = try await alice.account.createContactCode()
        await #expect(throws: SyncAccountError.ownContactCode) {
            try await alice.account.addContact(try await alice.account.previewInvite(code: own))
        }
        let again = try await alice.account.createContactCode()
        let bobAgain = try await bob.account.previewInvite(code: again)
        await #expect(throws: SyncAccountError.alreadyContacts("useralice")) { try await bob.account.addContact(bobAgain) }

        // Revoked codes stop working.
        await alice.account.refreshContacts()
        #expect(alice.account.contactCodes.count == 2)
        try await alice.account.revoke(try #require(alice.account.contactCodes.first))
        #expect(alice.account.contactCodes.count == 1)
    }

    @Test func sentItemsLandInTheirInboxAndNotInYours() async throws {
        let server = FakeSyncServer()
        let (alice, bob) = try await pair(server)
        let space = try await befriend(alice, bob)
        let aliceUid = try #require(alice.credentials.saved?.uid)

        // Sending is a copy into the direct space, pushed like any group item.
        let original = alice.store.ingest(.text("the report is ready"))
        let sent = alice.store.shareCopy(of: original, toSpace: space)
        await alice.settle()
        let live = await server.live(space: space)
        #expect(live.count == 1 && live.first?.id == sent.id.uuidString.lowercased() && live.first?.authorUid == aliceUid)

        await bob.settle()
        let received = try #require(bob.store.items(inSpace: space).first)
        #expect(received.text == "the report is ready")
        #expect(bob.account.isFromContact(received))
        #expect(!alice.account.isFromContact(sent))
        #expect(!alice.account.isFromContact(original))
        #expect(bob.account.badge(for: received) == SyncBadge(text: "useralice", symbol: "tray.and.arrow.down.fill",
                                                               help: "useralice sent you this"))
        #expect(alice.account.badge(for: sent)?.symbol == "paperplane.fill")

        // Bob replies; each Inbox holds only what the other one wrote.
        bob.store.ingest(.text("thanks!"), spaceID: space)
        await bob.settle()
        await alice.settle()
        let aliceInbox = alice.store.items(inSpace: space).filter(alice.account.isFromContact)
        let bobInbox = bob.store.items(inSpace: space).filter(bob.account.isFromContact)
        #expect(aliceInbox.map(\.text) == ["thanks!"])
        #expect(bobInbox.map(\.text) == ["the report is ready"])

        // Either of them may delete anything in the space: bob clears his Inbox for both.
        bob.store.delete(received)
        await bob.settle()
        await alice.settle()
        #expect(await server.item(space: space, id: received.id.uuidString.lowercased())?.deleted == "user")
        #expect(await server.live(space: space).count == 1)
        #expect(alice.store.items(inSpace: space).map(\.text) == ["thanks!"])
    }

    @Test func labelsStayWithTheSenderAndEditsOfReceivedItemsStayLocal() async throws {
        let server = FakeSyncServer()
        let (alice, bob) = try await pair(server)
        let space = try await befriend(alice, bob)
        let aliceUid = try #require(alice.credentials.saved?.uid)

        // Alice's label is hers: the copy she sends carries none.
        let original = alice.store.ingest(.text("label me"))
        alice.store.setLabel("Mine", for: original)
        let sent = alice.store.shareCopy(of: original, toSpace: space, keepLabel: false)
        #expect(sent.label == nil && !sent.isPinned)
        await alice.settle()
        await bob.settle()
        let received = try #require(bob.store.items(inSpace: space).first)
        #expect(received.label == nil && !received.isPinned)

        // Bob labels it: that stays on his Mac, so it never shows up in Alice's Inbox as his.
        let puts = await server.putCount
        bob.store.setLabel("Kept", for: received)
        await bob.settle()
        #expect(await server.putCount == puts)
        #expect(await server.live(space: space).map(\.authorUid) == [aliceUid])
        #expect(bob.store.item(withID: received.id)?.label == "Kept")
        #expect(bob.account.isFromContact(received))
        await alice.settle()
        #expect(alice.store.items(inSpace: space).filter(alice.account.isFromContact).isEmpty)
        #expect(alice.store.item(withID: sent.id)?.label == nil)

        // Deleting still syncs: it's gone for both.
        bob.store.delete(received)
        await bob.settle()
        await alice.settle()
        #expect(await server.live(space: space).isEmpty)
        #expect(alice.store.items(inSpace: space).isEmpty)
    }

    @Test func contactItemsAreListedInTheInboxOnly() async throws {
        let server = FakeSyncServer()
        let (alice, bob) = try await pair(server)
        let space = try await befriend(alice, bob)
        let original = alice.store.ingest(.text("for bob"))
        let sent = alice.store.shareCopy(of: original, toSpace: space, keepLabel: false)
        await alice.settle()
        await bob.settle()
        let received = try #require(bob.store.items(inSpace: space).first)

        // Bob: only in his Inbox.
        #expect(bob.account.isListed(received, inInbox: true))
        #expect(!bob.account.isListed(received, inInbox: false))
        // Alice: her original stays in history; what she sent isn't listed again, nor in her Inbox.
        #expect(alice.account.isListed(original, inInbox: false) && !alice.account.isListed(original, inInbox: true))
        #expect(!alice.account.isListed(sent, inInbox: false) && !alice.account.isListed(sent, inInbox: true))
    }

    @Test func endingAContactRemovesItsItemsOnBothSides() async throws {
        let server = FakeSyncServer()
        let (alice, bob) = try await pair(server)
        let space = try await befriend(alice, bob)
        alice.store.ingest(.text("for bob"), spaceID: space)
        await alice.settle()
        await bob.settle()
        #expect(bob.store.items(inSpace: space).count == 1)

        try await bob.account.remove(try #require(bob.account.contacts.first))
        #expect(bob.account.contacts.isEmpty)
        #expect(await server.spaces[space] == nil)
        await bob.settle()
        await alice.settle()
        #expect(bob.store.items(inSpace: space).isEmpty && alice.store.items(inSpace: space).isEmpty)
        #expect(alice.account.contacts.isEmpty)
        #expect(alice.store.allItems().isEmpty)
    }

    @Test func newItemsAndRequestsAreAnnouncedButNotTheFirstSyncAfterSignIn() async throws {
        let server = FakeSyncServer()
        let (alice, bob) = try await pair(server)
        var heard: [String] = []
        bob.account.onContactArrivals = { heard.append($0) }
        let space = try await befriend(alice, bob)

        alice.store.ingest(.text("hello there"), spaceID: space)
        await alice.settle()
        await bob.settle()
        #expect(heard == ["useralice sent you “hello there”"])
        await bob.settle()
        #expect(heard.count == 1)   // once

        // Bob's second Mac signs in: what's already there isn't news.
        let bob2 = try AccountHarness(server)
        var heard2: [String] = []
        bob2.account.onContactArrivals = { heard2.append($0) }
        await bob2.account.signIn(email: "bob@x.at", password: "bob password")
        await bob2.settle()
        #expect(bob2.store.items(inSpace: space).map(\.text) == ["hello there"])
        #expect(heard2.isEmpty)
        alice.store.ingest(.text("second"), spaceID: space)
        alice.store.ingest(.text("third"), spaceID: space)
        await alice.settle()
        await bob2.settle()
        #expect(heard2 == ["useralice sent you 2 items"])

        // A new request is mentioned once, after the first look of the session.
        var requests: [String] = []
        bob.account.onContactRequest = { requests.append($0) }
        await bob.account.refreshContacts()
        let carol = try AccountHarness(server)
        await carol.account.signUp(email: "carol@x.at", password: "carol password", username: "usercarol")
        try await carol.account.requestContact(username: "userbob")
        await bob.account.refreshContacts()
        await bob.account.refreshContacts()
        #expect(requests == ["usercarol wants to add you as a contact"])
        #expect(bob.account.contactRequests.incoming.map(\.name) == ["usercarol"])
    }

    @Test func arrivalTextsNameWhatCame() throws {
        let container = try ModelContainer(for: AppEnvironment.schema,
                                           configurations: ModelConfiguration(schema: AppEnvironment.schema, isStoredInMemoryOnly: true))
        let store = ClipStore(context: container.mainContext,
                              blobs: BlobStore(directory: FileManager.default.temporaryDirectory.appending(path: "Arrivals-\(UUID())")))
        let long = store.ingest(.text("A rather long first line that keeps going and going\nsecond line"))
        #expect(SyncAccount.arrivalText([long], from: "sam") == "sam sent you “A rather long first line that keeps goi…”")
        var capture = ProcessedCapture.text("a b")
        capture.kind = .file
        capture.fileURLs = [URL(filePath: "/tmp/a.pdf"), URL(filePath: "/tmp/b.pdf")]
        capture.hash = UUID().uuidString
        let files = store.ingest(capture)
        #expect(SyncAccount.arrivalText([files], from: "sam") == "sam sent you 2 files")
        #expect(SyncAccount.arrivalText([long, files], from: "sam") == "sam sent you 2 items")
        #expect(SyncAccount.arrivalText([long, files], from: nil) == "2 new items in your Inbox")
    }

    @Test func contactActionsAndTheInboxChip() {
        let contact = SyncContact(id: "s1", name: "sam", uid: "u")
        #expect(PanelAction.sendToContact(contact).title(folderName: "Downloads") == "Send to sam")
        #expect(PanelAction.sendToContact(contact).section(aiName: "AI") == "Send")
        #expect(!PanelFilter.chips.contains(.inbox))
        #expect(PanelFilter.chips(hasContacts: true).last == .inbox)
    }
}
