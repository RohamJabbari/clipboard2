import Foundation
import SwiftData
import Testing
@testable import Clipboard2

// Per-member Send and Secrets access in groups (docs/features/member-access.md).

private func lowered(_ id: UUID) -> String { id.uuidString.lowercased() }

@MainActor
private func space(_ id: String, on device: FakeDevice) -> SyncSpace? {
    device.engine.allSpaces().first { $0.id == id }
}

// MARK: - Engine, end to end against the fake server

@MainActor
struct MemberAccessSyncTests {
    @Test func withoutSendAMemberReadsAndDeletesButAddsNothing() async throws {
        let server = FakeSyncServer()
        let alice = try await FakeUser.make("alice", on: server)
        let bob = try await FakeUser.make("bob", on: server)
        let group = try await makeGroup("Team", owner: alice, members: [bob])
        let aliceMac = try FakeDevice(alice), bobMac = try FakeDevice(bob)

        let early = bobMac.store.ingest(.text("bob early"), spaceID: group)
        try await bobMac.engine.tick()
        #expect(await server.live(space: group).count == 1)

        _ = try await server.setAccess(caller: "alice", space: group, uid: "bob", canSend: false, canSeeSecrets: nil)
        aliceMac.store.ingest(.text("from alice"), spaceID: group)
        try await aliceMac.engine.tick()
        let late = bobMac.store.ingest(.text("bob late"), spaceID: group)
        try await bobMac.engine.tick()

        #expect(space(group, on: bobMac)?.canSend == false)
        #expect(space(group, on: bobMac)?.canSeeSecrets == true)
        #expect(bobMac.texts(inSpace: group).contains("from alice"))
        // Never even tried: the item waits on this Mac.
        #expect(await server.putAttempts[lowered(late.id)] == nil)
        #expect(await server.live(space: group).count == 2)
        #expect(bobMac.engine.warnings.isEmpty)

        // Your own earlier items can still go.
        bobMac.store.delete(early)
        try await bobMac.engine.tick()
        #expect(await server.live(space: group).count == 1)

        // Send back on: what waited goes out.
        _ = try await server.setAccess(caller: "alice", space: group, uid: "bob", canSend: true, canSeeSecrets: nil)
        try await bobMac.engine.tick()
        #expect(space(group, on: bobMac)?.canSend == true)
        #expect(await server.item(space: group, id: lowered(late.id))?.deleted == nil)
        #expect(await server.live(space: group).count == 2)
    }

    @Test func withoutSecretsTheGroupsSecretsLeaveThisMacAndComeBackLater() async throws {
        let server = FakeSyncServer()
        let alice = try await FakeUser.make("alice", on: server)
        let bob = try await FakeUser.make("bob", on: server)
        let group = try await makeGroup("Team", owner: alice, members: [bob])
        let aliceMac = try FakeDevice(alice), bobMac = try FakeDevice(bob)

        aliceMac.secrets.add(name: "Prod DB", value: "s3cret", spaceID: group)
        aliceMac.store.ingest(.text("shared note"), spaceID: group)
        try await aliceMac.engine.tick()
        try await bobMac.engine.tick()
        #expect(bobMac.secrets.syncSecrets.filter { $0.spaceID == group }.count == 1)

        _ = try await server.setAccess(caller: "alice", space: group, uid: "bob", canSend: nil, canSeeSecrets: false)
        try await bobMac.engine.tick()
        #expect(space(group, on: bobMac)?.canSeeSecrets == false)
        #expect(bobMac.secrets.syncSecrets.filter { $0.spaceID == group }.isEmpty)
        #expect(bobMac.engine.metas(inSpace: group).allSatisfy { $0.category != SyncCategory.secret.rawValue })
        #expect(bobMac.texts(inSpace: group) == ["shared note"])
        // Dropped here only: nothing was deleted on the server.
        #expect(await server.deleteRequests.isEmpty)
        #expect(await server.live(space: group).contains { $0.category == "secret" })

        // New secrets don't arrive either.
        aliceMac.secrets.add(name: "Staging DB", value: "other", spaceID: group)
        try await aliceMac.engine.tick()
        try await bobMac.engine.tick()
        try await bobMac.engine.tick()
        #expect(bobMac.secrets.syncSecrets.filter { $0.spaceID == group }.isEmpty)

        // Back on: the group is pulled from the start, secrets included.
        _ = try await server.setAccess(caller: "alice", space: group, uid: "bob", canSend: nil, canSeeSecrets: true)
        try await bobMac.engine.tick()
        #expect(Set(bobMac.secrets.syncSecrets.filter { $0.spaceID == group }.map(\.name)) == ["Prod DB", "Staging DB"])
        #expect(await server.deleteRequests.isEmpty)
    }

    @Test func anOlderServerLeavesEverythingAllowedAndARefusedSendIsAWarning() async throws {
        let server = FakeSyncServer()
        let alice = try await FakeUser.make("alice", on: server)
        let bob = try await FakeUser.make("bob", on: server)
        let group = try await makeGroup("Team", owner: alice, members: [bob])
        let bobMac = try FakeDevice(bob)
        await server.setReportsAccess(false)
        #expect(await server.spaces(for: "bob").first { $0.id == group }?.canSend == nil)

        try await bobMac.engine.tick()
        #expect(space(group, on: bobMac)?.canSend == true)
        #expect(space(group, on: bobMac)?.canSeeSecrets == true)

        // The server refuses anyway: the usual sync warning, and no retry until the item changes.
        _ = try await server.setAccess(caller: "alice", space: group, uid: "bob", canSend: false, canSeeSecrets: nil)
        let item = bobMac.store.ingest(.text("refused"), spaceID: group)
        try await bobMac.engine.tick()
        #expect(bobMac.engine.warnings.contains { $0.contains("can't send to this group") })
        try await bobMac.engine.tick()
        #expect(await server.putAttempts[lowered(item.id)] == 1)
    }

    @Test func blobsAreRefusedWithoutSend() async throws {
        let server = FakeSyncServer()
        let alice = try await FakeUser.make("alice", on: server)
        let bob = try await FakeUser.make("bob", on: server)
        let group = try await makeGroup("Team", owner: alice, members: [bob])
        _ = try await server.setAccess(caller: "alice", space: group, uid: "bob", canSend: false, canSeeSecrets: nil)
        let client = FakeClient(server: server, token: { bob.token })
        await #expect(throws: SyncAPIError.server(status: 403, code: "send_not_allowed", message: "", retryAfter: nil)) {
            _ = try await client.registerBlob(spaceId: group, blobId: "b1", size: 10)
        }
    }

    @Test func onlyTheOwnerChangesAccessAndNeverTheirOwn() async throws {
        let server = FakeSyncServer()
        let alice = try await FakeUser.make("alice", on: server)
        let bob = try await FakeUser.make("bob", on: server)
        let carol = try await FakeUser.make("carol", on: server)
        let group = try await makeGroup("Team", owner: alice, members: [bob, carol])
        let owner = FakeClient(server: server, token: { alice.token })
        let member = FakeClient(server: server, token: { bob.token })

        let changed = try await owner.setMemberAccess(groupId: group, uid: "bob", canSend: false, canSeeSecrets: nil)
        #expect(changed.uid == "bob" && changed.canSend == false && changed.canSeeSecrets == true)
        let listed = try await member.members(groupId: group)
        #expect(listed.first { $0.uid == "bob" }?.sendAllowed == false)
        #expect(listed.first { $0.uid == "alice" }.map { $0.sendAllowed && $0.secretsAllowed } == true)

        await #expect(throws: SyncAPIError.server(status: 403, code: "forbidden", message: "", retryAfter: nil)) {
            _ = try await member.setMemberAccess(groupId: group, uid: "carol", canSend: false, canSeeSecrets: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try await owner.setMemberAccess(groupId: group, uid: "alice", canSend: false, canSeeSecrets: nil)
        }
        #expect(await server.accessChanges == 1)
    }
}

// MARK: - Wire format

struct MemberAccessAPITests {
    @Test func patchSendsOnlyTheChangedSwitch() async throws {
        let transport = StubTransport(body: #"{"uid":"u2","role":"member","name":"sam","canSend":false,"canSeeSecrets":true}"#)
        let api = SyncAPI(base: URL(string: "https://api.example")!, transport: transport) { "T" }
        let member = try await api.setMemberAccess(groupId: "g1", uid: "u2", canSend: false, canSeeSecrets: nil)
        #expect(member.canSend == false && member.secretsAllowed)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path() == "/v1/groups/g1/members/u2")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Bool]
        #expect(body == ["canSend": false])
    }

    @Test func missingFieldsReadAsAllowed() throws {
        let json = #"{"id":"g1","kind":"group","role":"member","ownerUid":"o","wrappedKey":"AA==","memberCount":2,"createdAt":1}"#
        let space = try JSONDecoder().decode(RemoteSpace.self, from: Data(json.utf8))
        #expect(space.canSend == nil && space.canSeeSecrets == nil)
        let member = try JSONDecoder().decode(RemoteMember.self, from: Data(#"{"uid":"u","role":"member"}"#.utf8))
        #expect(member.sendAllowed && member.secretsAllowed)
    }

    @Test func sendNotAllowedIsPermanentForTheItem() {
        let error = SyncAPIError.server(status: 403, code: "send_not_allowed", message: "", retryAfter: nil)
        #expect(error.isPermanentForItem)
        #expect(error.errorDescription?.contains("can't send to this group") == true)
    }
}

// MARK: - Notifications

struct MemberAccessNotificationTests {
    private func snapshot(send: Bool?, secrets: Bool?, owner: Bool = false) -> NotificationSnapshot {
        NotificationSnapshot(groups: ["g1": .init(name: "Team", isOwner: owner, members: ["me": "me", "sam": "sam"],
                                                  canSend: send, canSeeSecrets: secrets)])
    }

    @Test func accessChangesAreToldUnderGroupMembers() {
        let events = NotificationDiff.events(from: snapshot(send: true, secrets: true), to: snapshot(send: false, secrets: false),
                                             arrivals: [], me: "me")
        #expect(events.map(\.body) == ["You can no longer send", "You can no longer see secrets"])
        #expect(events.allSatisfy { $0.kind == .groupMembers && $0.title == "Team" && $0.groupId == "g1" })

        let back = NotificationDiff.events(from: snapshot(send: false, secrets: false), to: snapshot(send: true, secrets: true),
                                           arrivals: [], me: "me")
        #expect(back.map(\.body) == ["You can send again", "You can see secrets again"])
    }

    @Test func snapshotsFromBeforeAccessAndOwnersSayNothing() throws {
        #expect(NotificationDiff.events(from: snapshot(send: nil, secrets: nil), to: snapshot(send: true, secrets: true),
                                        arrivals: [], me: "me").isEmpty)
        #expect(NotificationDiff.events(from: snapshot(send: true, secrets: true, owner: true),
                                        to: snapshot(send: false, secrets: true, owner: true), arrivals: [], me: "me").isEmpty)
        // A snapshot persisted by 1.9 (no access fields) still decodes.
        let old = #"{"groups":{"g1":{"name":"Team","isOwner":false,"members":{}}},"contacts":{},"shared":{},"owned":{}}"#
        let decoded = try JSONDecoder().decode(NotificationSnapshot.self, from: Data(old.utf8))
        #expect(decoded.groups["g1"]?.canSend == nil)
    }
}

// MARK: - The panel and the account

@MainActor
struct MemberAccessPanelTests {
    let env = AppEnvironment.shared
    let model: PanelViewModel

    init() {
        model = PanelViewModel(env: env)
    }

    @Test func aGroupWithoutSendIsNoTargetAndTakesNothingNew() {
        let readOnly = SyncGroup(id: "group-\(UUID())", name: "Read Only", isOwner: false, memberCount: 3, canSend: false)
        let mine = env.store.ingest(.text("mine \(UUID())"), spaceID: readOnly.id)
        let personal = env.store.ingest(.text("personal \(UUID())"))
        env.sync.setUpForTesting(groups: [readOnly], uid: "me", authors: [lowered(mine.id): "me"], signedIn: true)
        defer {
            env.sync.tearDownTesting()
            env.store.delete(mine)
            env.store.delete(personal)
            model.groupFilter = nil
        }
        #expect(env.sync.sendableGroups.isEmpty)
        #expect(!model.canShareToGroup)
        // Even your own items there can't be changed (labelled, moved) any more.
        #expect(!env.sync.canChange(mine))
        #expect(!model.canLabel(.clip(mine)))

        model.selectedID = PanelEntry.clip(personal).id
        #expect(!model.availableActions.contains(.shareToGroup))
        model.share([personal], to: readOnly)
        #expect(model.notice == "You can't send to Read Only")
        #expect(env.store.items(inSpace: readOnly.id).count == 1)

        model.groupFilter = readOnly.id
        model.groupShowsSaved = true
        #expect(!model.canAddHere)
        model.beginAddItems()
        #expect(model.mode != .addItems)
    }

    @Test func secretsGoOnlyWhereTheyCanBeSeen() {
        let noSecrets = SyncGroup(id: "group-\(UUID())", name: "No Secrets", isOwner: false, memberCount: 2, canSeeSecrets: false)
        let team = SyncGroup(id: "group-\(UUID())", name: "Team", isOwner: false, memberCount: 2)
        env.sync.setUpForTesting(groups: [noSecrets, team], uid: "me", authors: [:], signedIn: true)
        defer { env.sync.tearDownTesting() }
        let ref = SecretRef(id: UUID().uuidString, name: "Key", createdAt: .now, spaceID: nil, updatedAt: .now, folderID: nil)
        #expect(model.canShareToGroup)
        #expect(model.shareGroups(for: ref).map(\.id) == [team.id])
        #expect(model.shareGroups.map(\.id) == [noSecrets.id, team.id])
    }
}

// MARK: - Store

@MainActor
struct MemberAccessStoreTests {
    @Test func aStoreFrom19MigratesWithAccessOn() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "Store-\(UUID())").appending(path: "Clipboard2.store")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let v4 = Schema(versionedSchema: StoreSchemaV4.self)
            let old = try ModelContainer(for: v4, configurations: ModelConfiguration(schema: v4, url: url))
            let space = StoreSchemaV4.SyncSpace()
            space.id = "g1"
            space.since = 42
            old.mainContext.insert(space)
            let item = StoreSchemaV4.ClipItem()
            item.text = "kept"
            item.isConcealed = true
            old.mainContext.insert(item)
            try old.mainContext.save()
        }
        let opened = AppEnvironment.openContainer(url: url)
        #expect(opened.error == nil)
        let context = opened.container.mainContext
        let space = try #require(try context.fetch(FetchDescriptor<SyncSpace>()).first)
        #expect(space.id == "g1" && space.since == 42 && space.canSend && space.canSeeSecrets)
        let item = try #require(try context.fetch(FetchDescriptor<ClipItem>()).first)
        #expect(item.text == "kept" && item.isConcealed)
    }
}
