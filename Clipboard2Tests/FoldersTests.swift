import Testing
import Foundation
import SwiftData
import AppKit
@testable import Clipboard2

// MARK: - Store

@MainActor
struct FolderStoreTests {
    let stores: TestStores
    var store: ClipStore { stores.store }

    init() throws {
        stores = try TestStores()
    }

    @Test func movingInSavesAndMovingOutKeepsItSaved() {
        let folder = store.createFolder(named: "  Deploy  ", inSpace: nil)
        #expect(folder.name == "Deploy")
        let a = store.ingest(.text("host"))
        let b = store.ingest(.text("port"))
        let group = store.ingest(.text("theirs"), spaceID: "group-1")
        #expect(!a.isPinned)

        #expect(store.move([a, b, group], to: folder) == 2)
        #expect(a.isPinned && a.pinnedAt != nil && a.folderID == folder.id)
        #expect(store.folder(of: b)?.id == folder.id)
        #expect(group.folderID == nil && !group.isPinned)          // another space's clip stays put
        #expect(Set(store.items(inFolder: folder).map(\.id)) == [a.id, b.id])

        store.removeFromFolder([a])
        #expect(a.isPinned && a.folderID == nil)
        #expect(store.items(inFolder: folder).map(\.id) == [b.id])
    }

    @Test func deletingAFolderMovesItsClipsToTheRoot() {
        let folder = store.createFolder(named: "Old", inSpace: nil)
        let other = store.createFolder(named: "Other", inSpace: nil)
        let a = store.ingest(.text("one"))
        let b = store.ingest(.text("two"))
        let c = store.ingest(.text("three"))
        store.move([a, b], to: folder)
        store.move([c], to: other)

        #expect(store.deleteFolder(folder) == 2)
        #expect(store.folders(inSpace: nil).map(\.name) == ["Other"])
        #expect(a.isPinned && a.folderID == nil && b.isPinned && b.folderID == nil)
        #expect(c.folderID == other.id)
        #expect(store.count() == 3)
    }

    @Test func removeFromSavedClearsTheFolderButALabelDoesntUnsaveIt() {
        let folder = store.createFolder(inSpace: nil)
        let plain = store.ingest(.text("plain"))
        let labelled = store.ingest(.text("labelled"))
        store.setLabel("Prod", for: labelled)
        store.move([plain, labelled], to: folder)

        store.removeFromSaved([plain])
        #expect(!plain.isPinned && plain.folderID == nil && plain.pinnedAt == nil)

        // Removing the label of a clip in a folder keeps it saved, in the folder.
        store.setLabel(nil, for: labelled)
        #expect(labelled.label == nil && labelled.isPinned && labelled.folderID == folder.id)

        // Unpinning in any other way takes it out too.
        store.togglePin(labelled)
        #expect(!labelled.isPinned && labelled.folderID == nil)
    }

    @Test func addToSavedPinsWithoutALabel() {
        let a = store.ingest(.text("keep me"))
        store.addToSaved([a])
        #expect(a.isPinned && a.label == nil && a.folderID == nil)
    }

    @Test func foldersSortByNameWithinTheirSpaceAndRenameAndLabel() {
        let b = store.createFolder(named: "beta", inSpace: nil)
        store.createFolder(named: "Alpha", inSpace: nil)
        store.createFolder(named: "Team", inSpace: "group-1")
        #expect(store.folders(inSpace: nil).map(\.name) == ["Alpha", "beta"])
        #expect(store.folders(inSpace: "group-1").map(\.name) == ["Team"])

        let before = b.updatedAt
        store.rename(b, to: "   ", now: before.addingTimeInterval(5))
        #expect(b.name == "beta" && b.updatedAt == before)            // empty names are ignored
        store.rename(b, to: "Gamma", now: before.addingTimeInterval(5))
        #expect(b.name == "Gamma" && b.updatedAt > before)
        store.setLabel("work", for: b)
        #expect(b.label == "work")
        store.setLabel("", for: b)
        #expect(b.label == nil)
    }

    @Test func aClipWithAnUnknownFolderShowsAtTheRootUntilTheFolderArrives() {
        let id = UUID()
        let item = store.ingest(.text("early"))
        item.isPinned = true
        item.folderID = id
        #expect(store.folder(of: item) == nil)

        let folder = ClipFolder(syncID: id, spaceID: nil)
        folder.name = "Late"
        store.insertSynced(folder)
        store.commitSynced()
        #expect(store.folder(of: item)?.name == "Late")
        #expect(store.items(inFolder: folder).map(\.id) == [item.id])
    }

    @Test func retentionNeverTrimsClipsInFolders() {
        let old = Date(timeIntervalSince1970: 1_000)
        let folder = store.createFolder(inSpace: nil)
        let kept = store.ingest(.text("kept"), now: old)
        store.move([kept], to: folder)
        store.ingest(.text("gone"), now: old)
        store.ingest(.text("newer"))
        store.enforceRetention(maxItems: 1, maxAge: 60)
        #expect(store.item(withID: kept.id)?.folderID == folder.id)
        #expect(Set(store.allItems().map(\.text)) == ["kept", "newer"])
    }

    @Test func sharingAFolderCopiesItAndItsClipsIntoTheGroup() {
        let folder = store.createFolder(named: "Runbook", inSpace: nil)
        store.setLabel("ops", for: folder)
        let a = store.ingest(.text("step 1"))
        let b = store.ingest(.text("step 2"))
        store.move([a, b], to: folder)

        let copy = store.shareCopy(of: folder, toSpace: "group-1")
        #expect(copy.id != folder.id && copy.name == "Runbook" && copy.label == "ops" && copy.spaceID == "group-1")
        let shared = store.items(inFolder: copy)
        #expect(Set(shared.map(\.text)) == ["step 1", "step 2"])
        #expect(shared.allSatisfy { $0.isPinned && $0.spaceID == "group-1" && $0.id != a.id && $0.id != b.id })
        // The personal folder stays as it was.
        #expect(Set(store.items(inFolder: folder).map(\.id)) == [a.id, b.id])
    }

    @Test func leavingASpaceDropsItsFolders() {
        store.createFolder(named: "Team", inSpace: "group-1")
        store.createFolder(named: "Mine", inSpace: nil)
        store.removeAll(inSpace: "group-1")
        #expect(store.allFolders().map(\.name) == ["Mine"])
    }

    @Test func duplicatesConvergeIntoTheFolder() {
        let folder = store.createFolder(inSpace: "g")
        let a = ClipItem(syncID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, spaceID: "g")
        let b = ClipItem(syncID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, spaceID: "g")
        for item in [a, b] {
            item.text = "same"
            item.contentHash = "text:same"
            store.insertSynced(item)
        }
        b.isPinned = true
        b.folderID = folder.id
        store.commitSynced()
        store.convergeDuplicates(inSpace: "g")
        #expect(store.items(inSpace: "g").count == 1)
        #expect(a.isPinned && a.folderID == folder.id)
    }
}

// MARK: - Payloads and fingerprints

@MainActor
struct FolderPayloadTests {
    let stores: TestStores
    var store: ClipStore { stores.store }

    init() throws {
        stores = try TestStores()
    }

    @Test func aClipsFolderRoundTrips() throws {
        let folder = store.createFolder(named: "Keys", inSpace: nil)
        let item = store.ingest(.text("in a folder"))
        store.move([item], to: folder)
        let payload = SyncPayload.clip(ClipPayload(item: item))
        guard case .clip(let clip) = payload else { return }
        #expect(clip.folder == folder.id.uuidString.lowercased())
        #expect(String(decoding: try payload.canonicalJSON(), as: UTF8.self).contains("\"folder\":\"\(clip.folder ?? "")\""))

        let decoded = try SyncPayload.decode(payload.canonicalJSON())
        #expect(decoded == payload)
        guard case .clip(let received) = decoded else { return }
        let copy = ClipItem(syncID: item.id, spaceID: nil)
        received.apply(to: copy)
        #expect(copy.isPinned && copy.folderID == folder.id)

        // Not saved: no folder, either way.
        var unpinned = received
        unpinned.isPinned = false
        unpinned.apply(to: copy)
        #expect(copy.folderID == nil)
        #expect(ClipPayload(item: copy).folder == nil)
    }

    @Test func aClipWithoutAFolderKeepsItsOldBytes() throws {
        let item = store.ingest(.text("root"))
        store.addToSaved([item])
        let json = String(decoding: try SyncPayload.clip(ClipPayload(item: item)).canonicalJSON(), as: UTF8.self)
        #expect(!json.contains("folder"))
    }

    @Test func folderPayloadRoundTripsAndToleratesMissingFields() throws {
        let payload = SyncPayload.folder(FolderPayload(name: "Deploy", label: "ops", createdAt: 1, updatedAt: 2))
        #expect(payload.category == .folder)
        #expect(try SyncPayload.decode(payload.canonicalJSON()) == payload)
        #expect(try SyncPayload.decode(payload.withRev(9).canonicalJSON()).rev == 9)
        #expect(try payload.withRev(9).fingerprint() == payload.fingerprint())

        guard case .folder(let sparse) = try SyncPayload.decode(Data(#"{"type":"folder","createdAt":5,"x":1}"#.utf8)) else {
            Issue.record("not a folder")
            return
        }
        let folder = ClipFolder(syncID: UUID(), spaceID: nil)
        sparse.apply(to: folder, arrivedAt: Date(syncMillis: 100))
        #expect(folder.name == "Folder" && folder.label == nil && folder.updatedAt.syncMillis == 5)
        #expect(SyncCategory(rawValue: "folder") == .folder && !SyncCategory.folder.isClip)
    }

    @Test func fingerprintAndStampChangeWhenTheFolderDoes() throws {
        let one = store.createFolder(named: "One", inSpace: nil)
        let two = store.createFolder(named: "Two", inSpace: nil)
        let item = store.ingest(.text("moving"))
        store.addToSaved([item])
        let atRoot = try SyncPayload.clip(ClipPayload(item: item)).fingerprint()
        let rootStamp = SyncEngine.stamp(item)
        store.move([item], to: one)
        let inOne = try SyncPayload.clip(ClipPayload(item: item)).fingerprint()
        let oneStamp = SyncEngine.stamp(item)
        store.move([item], to: two)
        let inTwo = try SyncPayload.clip(ClipPayload(item: item)).fingerprint()
        #expect(Set([atRoot, inOne, inTwo]).count == 3)
        #expect(Set([rootStamp, oneStamp, SyncEngine.stamp(item)]).count == 3)
    }
}

// MARK: - Sync

@MainActor
struct FolderSyncTests {
    @Test func foldersPushPullRenameAndDelete() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)

        let folder = mac1.store.createFolder(named: "Deploy", inSpace: nil)
        let item = mac1.store.ingest(.text("prod host"))
        mac1.store.move([item], to: folder)
        try await mac1.engine.tick()

        let folderID = folder.id.uuidString.lowercased()
        let remote = try #require(await server.item(space: user.personal, id: folderID))
        #expect(remote.category == "folder" && remote.sortAt == folder.createdAt.syncMillis)
        #expect(await server.item(space: user.personal, id: item.id.uuidString.lowercased())?.category == "pinned")

        try await mac2.engine.tick()
        let received = try #require(mac2.store.folder(withID: folder.id))
        #expect(received.name == "Deploy" && received.spaceID == nil)
        let receivedItem = try #require(mac2.store.item(withID: item.id))
        #expect(mac2.store.folder(of: receivedItem)?.id == folder.id)

        // Nothing changed: nothing is pushed again.
        let puts = await server.putCount
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        #expect(await server.putCount == puts)

        // A rename on one Mac reaches the other.
        mac2.store.rename(received, to: "Deploy notes", now: .now.addingTimeInterval(1))
        try await mac2.engine.tick()
        try await mac1.engine.tick()
        #expect(mac1.store.folder(withID: folder.id)?.name == "Deploy notes")

        // Deleting: the folder's tombstone goes out and its clips re-push without it.
        mac1.store.deleteFolder(try #require(mac1.store.folder(withID: folder.id)))
        try await mac1.engine.tick()
        #expect(await server.item(space: user.personal, id: folderID)?.deleted == "user")
        try await mac2.engine.tick()
        #expect(mac2.store.folder(withID: folder.id) == nil)
        let after = try #require(mac2.store.item(withID: item.id))
        #expect(after.isPinned && after.folderID == nil)
    }

    @Test func movingAClipBetweenFoldersRePushesIt() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)
        let one = mac1.store.createFolder(named: "One", inSpace: nil)
        let two = mac1.store.createFolder(named: "Two", inSpace: nil)
        let item = mac1.store.ingest(.text("moving"))
        mac1.store.move([item], to: one)
        try await mac1.engine.tick()
        try await mac2.engine.tick()

        mac1.store.move([item], to: two)
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        #expect(mac2.store.item(withID: item.id)?.folderID == two.id)

        mac1.store.removeFromFolder([item])
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        let received = try #require(mac2.store.item(withID: item.id))
        #expect(received.isPinned && received.folderID == nil)
    }

    /// Group folders follow the server's write rule for every group item (PROTOCOL.md → Write
    /// checks): anyone creates, only the author or the group owner changes or deletes.
    @Test func groupFoldersReachEveryMemberAndFollowTheGroupWriteRule() async throws {
        let server = FakeSyncServer()
        let alice = try await FakeUser.make("alice", on: server)
        let bob = try await FakeUser.make("bob", on: server)
        let group = try await makeGroup("Team", owner: alice, members: [bob])
        let aliceMac = try FakeDevice(alice), bobMac = try FakeDevice(bob)
        try await aliceMac.engine.tick()

        // Bob (a member) creates a folder with a clip in it; Alice gets both.
        let folder = bobMac.store.createFolder(named: "Shared", inSpace: group)
        let item = bobMac.store.ingest(.text("team note"), spaceID: group)
        bobMac.store.move([item], to: folder)
        try await bobMac.engine.tick()
        try await aliceMac.engine.tick()

        let alicesFolder = try #require(aliceMac.store.folder(withID: folder.id))
        #expect(alicesFolder.spaceID == group && aliceMac.store.folders(inSpace: nil).isEmpty)
        #expect(aliceMac.store.folder(of: try #require(aliceMac.store.item(withID: item.id)))?.id == folder.id)

        // Alice (the owner) labels it; Bob follows.
        aliceMac.store.setLabel("wip", for: alicesFolder, now: .now.addingTimeInterval(1))
        try await aliceMac.engine.tick()
        try await bobMac.engine.tick()
        #expect(bobMac.store.folder(withID: folder.id)?.label == "wip")

        // Alice's own folder: Bob's rename is refused by the server and stays on his Mac.
        let alices = aliceMac.store.createFolder(named: "Owner's", inSpace: group)
        try await aliceMac.engine.tick()
        try await bobMac.engine.tick()
        bobMac.store.rename(try #require(bobMac.store.folder(withID: alices.id)), to: "Bob's now", now: .now.addingTimeInterval(2))
        try await bobMac.engine.tick()
        #expect(!bobMac.engine.warnings.isEmpty)
        try await aliceMac.engine.tick()
        #expect(aliceMac.store.folder(withID: alices.id)?.name == "Owner's")

        // The owner deletes Bob's folder: gone for Bob, his clip stays saved at the root.
        aliceMac.store.deleteFolder(alicesFolder)
        try await aliceMac.engine.tick()
        try await bobMac.engine.tick()
        #expect(bobMac.store.folder(withID: folder.id) == nil)
        let bobsItem = try #require(bobMac.store.item(withID: item.id))
        #expect(bobsItem.isPinned && bobMac.store.folder(of: bobsItem) == nil)
    }

    @Test func aClipArrivingBeforeItsFolderMovesInWhenTheFolderComes() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)
        let folder = mac1.store.createFolder(named: "Later", inSpace: nil)
        let item = mac1.store.ingest(.text("early bird"))
        mac1.store.move([item], to: folder)
        try await mac1.engine.tick()
        // Mac 2 sees the clip but not (yet) its folder: as if it hadn't been pulled.
        await server.dropItem(space: user.personal, id: folder.id.uuidString.lowercased())

        try await mac2.engine.tick()
        let received = try #require(mac2.store.item(withID: item.id))
        #expect(received.folderID == folder.id && mac2.store.folder(of: received) == nil)

        // The folder is pushed again (its server copy is gone) and arrives.
        mac1.store.rename(folder, to: "Later on", now: .now.addingTimeInterval(1))
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        #expect(mac2.store.folder(of: received)?.name == "Later on")
    }

    @Test func signingOutDropsGroupFolders() async throws {
        let server = FakeSyncServer()
        let alice = try await FakeUser.make("alice", on: server)
        let group = try await makeGroup("Team", owner: alice)
        let mac = try FakeDevice(alice)
        mac.store.createFolder(named: "Team", inSpace: group)
        mac.store.createFolder(named: "Mine", inSpace: nil)
        SyncEngine.wipeLocalState(context: mac.container.mainContext, store: mac.store, snippets: mac.snippets,
                                  secrets: mac.secrets)
        #expect(mac.store.allFolders().map(\.name) == ["Mine"])
    }
}

// MARK: - Panel

@MainActor
struct FolderPanelTests {
    let env = AppEnvironment.shared
    let model: PanelViewModel

    init() {
        model = PanelViewModel(env: env)
    }

    private func key(_ code: UInt16, _ chars: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func savedListsFoldersFirstAndExpandsAndCollapsesThem() {
        let tag = UUID().uuidString
        let folder = env.store.createFolder(named: "AAA \(tag)", inSpace: nil)
        let inside = env.store.ingest(.text("inside \(tag)"))
        let root = env.store.ingest(.text("root \(tag)"))
        let group = env.store.createFolder(named: "Group \(tag)", inSpace: "group-\(tag)")
        defer {
            [inside, root].forEach(env.store.delete)
            env.store.deleteFolder(folder)
            env.store.deleteFolder(group)
        }
        env.store.move([inside], to: folder)
        env.store.addToSaved([root])

        model.filter = .labelled
        #expect(PanelFilter.labelled.title == "Saved" && PanelFilter.labelled.symbol == "bookmark")
        let folderRow = PanelEntry.folder(folder).id
        #expect(model.entries.contains { $0.id == folderRow })
        #expect(!model.entries.contains { $0.folder?.id == group.id })        // group folders stay in their group
        #expect(!model.entries.contains { $0.clip?.id == inside.id })        // in a folder: not at the root
        #expect(model.entries.contains { $0.clip?.id == root.id })
        let firstClip = model.entries.firstIndex { $0.clip != nil } ?? 0
        #expect(model.entries.prefix(firstClip).allSatisfy { $0.folder != nil })
        #expect(model.folderCounts[folder.id] == 1)

        // Search from the root finds clips in folders, captioned.
        model.query = "inside \(tag)"
        #expect(model.entries.contains { $0.clip?.id == inside.id })
        #expect(model.folderCaptions[PanelEntry.clip(inside).id] == folder.name)
        model.query = ""

        // Return expands the selected folder in place: its clip follows it, one level in.
        model.selectedID = folderRow
        #expect(model.handleKeyDown(key(KeyCode.returnKey, "\r")))
        #expect(model.isExpanded(folder) && model.selectedID == folderRow)
        let row = try? #require(model.entries.firstIndex { $0.id == folderRow })
        #expect(row.map { model.entries[$0 + 1].clip?.id } == inside.id)
        #expect(model.entryDepths[PanelEntry.clip(inside).id] == 1)

        // ← collapses it again; Return toggles too.
        #expect(model.handleKeyDown(key(KeyCode.leftArrow)))
        #expect(!model.isExpanded(folder) && !model.entries.contains { $0.clip?.id == inside.id })
        #expect(model.handleKeyDown(key(KeyCode.returnKey, "\r")))
        #expect(model.isExpanded(folder))
        #expect(model.handleKeyDown(key(KeyCode.returnKey, "\r")))
        #expect(!model.isExpanded(folder))
    }

    @Test func saveIntoANewFolderAndDeleteFolderFromThePanel() {
        let tag = UUID().uuidString
        let a = env.store.ingest(.text("newfolder-a \(tag)"))
        let b = env.store.ingest(.text("newfolder-b \(tag)"))
        defer { [a, b].forEach(env.store.delete) }
        model.query = tag
        model.selectAll()
        #expect(model.availableActions.contains(.save))
        #expect(!model.availableActions.contains(.addToSaved) && !model.availableActions.contains(.moveToNewFolder))

        // Save… → New Folder under My folders: named inline, created and picked; Return saves.
        model.perform(.save)
        #expect(model.mode == .save)
        model.beginSaveFormFolder(.mine)
        model.saveForm?.newFolderName = "Batch \(tag)"
        #expect(model.handleKeyDown(key(KeyCode.returnKey, "\r")))
        let folder = try? #require(env.store.folders(inSpace: nil).first { $0.name == "Batch \(tag)" })
        #expect(model.mode == .save && model.saveForm?.destination == .mine(folder?.id))
        #expect(model.handleKeyDown(key(KeyCode.returnKey, "\r")))
        #expect(a.isPinned && a.folderID == folder?.id && b.folderID == folder?.id)

        model.query = ""
        model.filter = .labelled
        guard let folder else { return }
        model.selectedID = PanelEntry.folder(folder).id
        let actions = model.availableActions
        #expect(Array(actions.prefix(4)) == [.openFolder, .renameFolder, .setLabel, .newSubfolder])
        #expect(actions.last == .deleteFolder && !actions.contains(.moveFolderToTop))
        model.perform(.deleteFolder)
        #expect(model.notice == "Folder deleted · moved 2 items to Saved")
        #expect(a.isPinned && a.folderID == nil && env.store.folder(withID: folder.id) == nil)
    }

    @Test func groupSavedSwitchIsRememberedPerGroup() {
        let group = "group-\(UUID().uuidString)"
        model.groupFilter = group
        #expect(!model.isSavedView)
        model.groupShowsSaved = true
        #expect(model.isSavedView && model.savedSpaceID == group)
        model.groupFilter = nil
        #expect(!model.isSavedView)
        model.groupFilter = group
        #expect(model.groupShowsSaved)
        model.groupShowsSaved = false
    }
}

// MARK: - Backup and migration

@MainActor
struct FolderBackupTests {
    @Test func backupsCarryFoldersAndImportReusesOnesWithTheSameName() throws {
        let source = try TestStores()
        let folder = source.store.createFolder(named: "Deploy", inSpace: nil)
        source.store.setLabel("ops", for: folder)
        let a = source.store.ingest(.text("in folder"))
        source.store.move([a], to: folder)
        source.store.ingest(.text("history"))

        let contents = BackupExporter.contents(store: source.store, snippets: source.snippets, secrets: nil)
        #expect(contents.folders.map(\.name) == ["Deploy"])
        let sealed = try BackupExporter.seal(contents, passphrase: "a long passphrase")
        let document = try BackupImporter.open(sealed, passphrase: "a long passphrase")
        #expect(document.folders?.first?.label == "ops")

        let target = try TestStores()
        let existing = target.store.createFolder(named: "deploy", inSpace: nil)
        _ = BackupImporter.merge(document, store: target.store, snippets: target.snippets, secrets: nil, maxAge: nil)
        let imported = try #require(target.store.allItems().first { $0.text == "in folder" })
        #expect(imported.isPinned && imported.folderID == existing.id)
        #expect(target.store.folders(inSpace: nil).count == 1)

        // Into an empty store the folder is created.
        let fresh = try TestStores()
        _ = BackupImporter.merge(document, store: fresh.store, snippets: fresh.snippets, secrets: nil, maxAge: nil)
        let created = try #require(fresh.store.folders(inSpace: nil).first)
        #expect(created.name == "Deploy" && created.label == "ops" && created.id != folder.id)
        #expect(fresh.store.items(inFolder: created).map(\.text) == ["in folder"])
    }

    @Test func aBackupWithoutFoldersEncodesAsBefore() throws {
        let json = String(decoding: try BackupDocument(createdAt: 1, clips: [], snippets: [], secrets: nil).encoded(), as: UTF8.self)
        #expect(!json.contains("folders"))
    }

    @Test func aStoreFromTheLastReleaseMigratesToFolders() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "Store-\(UUID())").appending(path: "Clipboard2.store")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let v2 = Schema(versionedSchema: StoreSchemaV2.self)
            let old = try ModelContainer(for: v2, configurations: ModelConfiguration(schema: v2, url: url))
            let item = StoreSchemaV2.ClipItem()
            item.text = "saved before folders"
            item.isPinned = true
            old.mainContext.insert(item)
            try old.mainContext.save()
        }
        let opened = AppEnvironment.openContainer(url: url)
        #expect(opened.error == nil)
        let context = opened.container.mainContext
        let item = try #require(try context.fetch(FetchDescriptor<ClipItem>()).first)
        #expect(item.text == "saved before folders" && item.isPinned && item.folderID == nil)
        context.insert(ClipFolder(name: "New"))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<ClipFolder>()).map(\.name) == ["New"])
    }
}
