import Testing
import Foundation
import AppKit
import SwiftUI
@testable import Clipboard2

// Saved v2 (docs/features/saved-v2.md): one Saved for clips, secrets and snippets, secrets in
// folders, personal copies of group items, and the group pill's Copies | Saved.

// MARK: - Filter row

@MainActor
struct FilterRowTests {
    let env = AppEnvironment.shared
    let model: PanelViewModel

    init() {
        model = PanelViewModel(env: env)
    }

    private func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func removedChipsFallBackToAll() {
        #expect(PanelFilter.chips == [.all, .labelled, .thisApp])
        #expect(PanelFilter.chips(showsContacts: true) == [.all, .labelled, .thisApp, .inbox])
        for gone in ["text", "images", "files", "snippets", "secrets", "nonsense", ""] {
            #expect(PanelFilter(storedValue: gone) == .all)
        }
        #expect(PanelFilter(storedValue: nil) == .all)
        #expect(PanelFilter(storedValue: "labelled") == .labelled)
        #expect(PanelFilter(storedValue: "thisApp") == .thisApp)
        #expect(PanelFilter(storedValue: "inbox") == .inbox)
    }

    @Test func tabWalksEachGroupsCopiesThenSaved() {
        let a = SyncGroup(id: "group-a-\(UUID())", name: "Alpha", isOwner: true, memberCount: 2)
        let b = SyncGroup(id: "group-b-\(UUID())", name: "Beta", isOwner: true, memberCount: 2)
        env.sync.setUpForTesting(groups: [a, b], uid: "me", authors: [:])
        defer {
            for group in [a, b] {
                model.groupFilter = group.id
                model.groupShowsSaved = false
            }
            env.sync.tearDownTesting()
        }
        model.groupFilter = nil
        model.filter = .thisApp
        let tab = key(KeyCode.tab, "\t"), backTab = key(KeyCode.tab, "\t", flags: .shift)

        #expect(model.handleKeyDown(tab))
        #expect(model.currentStop == .group(a.id, saved: false) && !model.isSavedView)
        #expect(model.handleKeyDown(tab))
        #expect(model.currentStop == .group(a.id, saved: true) && model.isSavedView && model.savedSpaceID == a.id)
        #expect(model.handleKeyDown(tab))
        #expect(model.currentStop == .group(b.id, saved: false))
        #expect(model.handleKeyDown(backTab))
        #expect(model.currentStop == .group(a.id, saved: true))

        // The segment is remembered per group.
        model.select(.chip(.all))
        model.groupFilter = a.id
        #expect(model.groupShowsSaved)
        model.groupFilter = b.id
        #expect(!model.groupShowsSaved)
    }
}

// MARK: - One Saved

@MainActor
struct SavedMixingTests {
    let env = AppEnvironment.shared
    let model: PanelViewModel

    init() {
        model = PanelViewModel(env: env)
    }

    @Test func savedMixesClipsSecretsAndSnippetsNewestFirstAfterFolders() throws {
        let tag = UUID().uuidString
        let folder = env.store.createFolder(named: "AAA \(tag)", inSpace: nil)
        let old = env.store.ingest(.text("old \(tag)"), now: .now.addingTimeInterval(-86_400))
        env.store.addToSaved([old], now: .now.addingTimeInterval(-86_400))
        let inFolder = env.store.ingest(.text("in folder \(tag)"))
        env.store.move([inFolder], to: folder)
        let snippet = env.snippets.create(name: "Snippet \(tag)", keyword: ";\(tag.prefix(6))", body: "body")
        snippet.updatedAt = .now.addingTimeInterval(3_600)
        let rootSecret = try #require(env.secrets.add(name: "Root secret \(tag)", value: "v1-\(tag)"))
        let folderSecret = try #require(env.secrets.add(name: "Folder secret \(tag)", value: "v2-\(tag)",
                                                        folderID: folder.id))
        defer {
            [old, inFolder].forEach(env.store.delete)
            env.snippets.delete(snippet)
            env.secrets.delete(rootSecret)
            env.secrets.delete(folderSecret)
            env.store.deleteFolder(folder)
        }

        model.filter = .labelled
        let ids = model.entries.map(\.id)
        let folderRow = try #require(ids.firstIndex(of: PanelEntry.folder(folder).id))
        let snippetRow = try #require(ids.firstIndex(of: PanelEntry.snippet(snippet).id))
        let secretRow = try #require(ids.firstIndex(of: PanelEntry.secret(rootSecret).id))
        let clipRow = try #require(ids.firstIndex(of: PanelEntry.clip(old).id))
        // Folders first, then newest first: the snippet (edited later), the secret (now), the clip (yesterday).
        let firstItem = model.entries.firstIndex { $0.folder == nil } ?? 0
        #expect(folderRow < firstItem)
        #expect(snippetRow < secretRow && secretRow < clipRow)
        // What's in the folder isn't at the root.
        #expect(!ids.contains(PanelEntry.secret(folderSecret).id) && !ids.contains(PanelEntry.clip(inFolder).id))
        #expect(model.folderCounts[folder.id] == 2)

        // The folder holds its clips and secrets, but never snippets.
        model.openFolder(folder)
        #expect(Set(model.entries.map(\.id)) == [PanelEntry.clip(inFolder).id, PanelEntry.secret(folderSecret).id])

        // Searching from the root finds the secret in the folder, captioned.
        model.closeFolder()
        model.query = "Folder secret \(tag)"
        let hit = PanelEntry.secret(folderSecret).id
        #expect(model.entries.contains { $0.id == hit })
        #expect(model.folderCaptions[hit] == folder.name)

        // All still finds secrets and snippets only when searching.
        model.query = ""
        model.filter = .all
        #expect(!model.entries.contains { $0.id == PanelEntry.secret(rootSecret).id })
        model.query = "Root secret \(tag)"
        #expect(model.entries.contains { $0.id == PanelEntry.secret(rootSecret).id })
    }

    @Test func saveAsSecretUsesTheLabelAndKeepsTheFolder() throws {
        let tag = UUID().uuidString
        let folder = env.store.createFolder(named: "Werkstatt \(tag)", inSpace: nil)
        let item = env.store.ingest(.text("GOCSPX-\(tag)"))
        env.store.move([item], to: folder)
        env.store.setLabel("Client secret \(tag)", for: item)
        defer { if env.store.folder(withID: folder.id) != nil { env.store.deleteFolder(folder) } }

        model.beginSaveSecret(item)
        #expect(model.saveSecretForm == nil)                       // labelled: saved without asking
        let ref = try #require(env.secrets.secrets.first { $0.name == "Client secret \(tag)" })
        defer { env.secrets.delete(ref) }
        #expect(ref.folderID == folder.id)
        #expect(env.store.item(withID: item.id) == nil)
    }

    @Test func secretsMoveIntoFoldersAndOutAndADeletedFolderReleasesThem() throws {
        let tag = UUID().uuidString
        let folder = env.store.createFolder(named: "Keys \(tag)", inSpace: nil)
        let ref = try #require(env.secrets.add(name: "Move me \(tag)", value: "v-\(tag)"))
        defer {
            env.secrets.delete(ref)
            if env.store.folder(withID: folder.id) != nil { env.store.deleteFolder(folder) }
        }
        model.filter = .labelled
        model.selectedID = PanelEntry.secret(ref).id
        #expect(model.availableActions.contains(.moveToFolder(folder)))
        #expect(!model.availableActions.contains(.removeFromFolder))

        model.perform(.moveToFolder(folder))
        let moved = try #require(env.secrets.secrets.first { $0.id == ref.id })
        #expect(moved.folderID == folder.id && model.folder(of: moved)?.id == folder.id)
        #expect(model.notice == "Moved to “\(folder.name)”")

        model.removeFromFolder([], secrets: [moved])
        #expect(env.secrets.secrets.first { $0.id == ref.id }?.folderID == nil)

        env.secrets.setFolder(folder.id, for: env.secrets.secrets.filter { $0.id == ref.id })
        model.deleteFolder(folder)
        #expect(env.secrets.secrets.first { $0.id == ref.id }?.folderID == nil)
        #expect(model.notice == "Folder deleted · moved 1 item to Saved")
    }

    @Test func aDraggedSecretDropsIntoAFolder() throws {
        let tag = UUID().uuidString
        let folder = env.store.createFolder(named: "Drop \(tag)", inSpace: nil)
        let ref = try #require(env.secrets.add(name: "Drag me \(tag)", value: "v-\(tag)"))
        defer {
            env.secrets.delete(ref)
            env.store.deleteFolder(folder)
        }
        let reference = try #require(PanelDrag.Reference(data: PanelDrag.Reference.secret(ref.id).data))
        #expect(reference == .secret(ref.id))
        #expect(PanelDrag.Reference(data: Data(UUID().uuidString.utf8)) != nil)
        #expect(model.drop(reference, onFolder: folder.id))
        #expect(env.secrets.secrets.first { $0.id == ref.id }?.folderID == folder.id)
        #expect(model.dropOnSavedRoot(.secret(ref.id)))
        #expect(env.secrets.secrets.first { $0.id == ref.id }?.folderID == nil)
    }
}

// MARK: - Group items and your folders

@MainActor
struct GroupCopyTests {
    let env = AppEnvironment.shared
    let model: PanelViewModel

    init() {
        model = PanelViewModel(env: env)
    }

    private func setUpGroup(owner: Bool, authors: [String: String] = [:]) -> SyncGroup {
        let group = SyncGroup(id: "group-\(UUID())", name: "Softmaze", isOwner: owner, memberCount: 3)
        env.sync.setUpForTesting(groups: [group], uid: "me", authors: authors)
        return group
    }

    /// A group item someone else wrote.
    private func theirItem(_ text: String, owner: Bool = false) -> (SyncGroup, ClipItem) {
        let group = setUpGroup(owner: owner)
        let item = env.store.ingest(.text(text), spaceID: group.id)
        env.sync.setUpForTesting(groups: [group], uid: "me", authors: [item.id.uuidString: "someone-else"])
        return (group, item)
    }

    @Test func movingAnotherMembersGroupItemToYourFolderSavesACopy() throws {
        let tag = UUID().uuidString
        let (group, theirs) = theirItem("group note \(tag)")
        let groupFolder = env.store.createFolder(named: "Team \(tag)", inSpace: group.id)
        let mine = env.store.createFolder(named: "Mine \(tag)", inSpace: nil)
        defer {
            env.sync.tearDownTesting()
            for item in env.store.allItems() where item.text == "group note \(tag)" { env.store.delete(item) }
            env.store.deleteFolder(groupFolder)
            env.store.deleteFolder(mine)
        }

        // Someone else's item: only "Mine" is offered (the server would refuse a move in the group).
        let menu = try #require(model.folderMenu(for: [theirs]))
        #expect(menu.group == nil && menu.copiesToPersonal && menu.personal.contains { $0.id == mine.id })

        model.place([theirs], secrets: [], in: mine)
        #expect(model.notice == "Saved a copy to “\(mine.name)”")
        let copy = try #require(env.store.items(inSpace: nil).first { $0.text == "group note \(tag)" })
        #expect(copy.id != theirs.id && copy.isPinned && copy.folderID == mine.id)
        // The group's item doesn't change.
        #expect(theirs.spaceID == group.id && !theirs.isPinned && theirs.folderID == nil)
    }

    @Test func authorsAndOwnersGetTheGroupsFoldersToo() throws {
        let tag = UUID().uuidString
        let group = setUpGroup(owner: true)
        let item = env.store.ingest(.text("owned \(tag)"), spaceID: group.id)
        let groupFolder = env.store.createFolder(named: "Team \(tag)", inSpace: group.id)
        defer {
            env.sync.tearDownTesting()
            env.store.delete(item)
            env.store.deleteFolder(groupFolder)
        }
        let menu = try #require(model.folderMenu(for: [item]))
        #expect(menu.group?.name == "Softmaze" && menu.group?.folders.map(\.id) == [groupFolder.id])
        #expect(menu.copiesToPersonal)

        model.place([item], secrets: [], in: groupFolder)
        #expect(item.isPinned && item.folderID == groupFolder.id && item.spaceID == group.id)

        // Mixed spaces: only "Mine".
        let personal = env.store.ingest(.text("personal \(tag)"))
        defer { env.store.delete(personal) }
        let mixed = try #require(model.folderMenu(for: [item, personal]))
        #expect(mixed.group == nil && mixed.copiesToPersonal)
    }

    @Test func saveACopyReplacesAddToSavedForAnotherMembersItem() throws {
        let tag = UUID().uuidString
        let (group, theirs) = theirItem("their note \(tag)")
        defer {
            env.sync.tearDownTesting()
            for item in env.store.allItems() where item.text == "their note \(tag)" { env.store.delete(item) }
        }
        model.groupFilter = group.id
        model.selectedID = PanelEntry.clip(theirs).id
        #expect(model.availableActions.contains(.saveCopy))
        #expect(!model.availableActions.contains(.addToSaved))

        model.perform(.saveCopy)
        #expect(model.notice == "Saved a copy to Saved")
        let copy = try #require(env.store.items(inSpace: nil).first { $0.text == "their note \(tag)" })
        #expect(copy.isPinned && copy.folderID == nil)
        #expect(!theirs.isPinned && theirs.spaceID == group.id)
        model.groupFilter = nil
    }

    @Test func yourOwnGroupItemsAreStillAddedToSaved() {
        let tag = UUID().uuidString
        let group = setUpGroup(owner: false)
        let mine = env.store.ingest(.text("my group note \(tag)"), spaceID: group.id)   // never synced: yours
        defer {
            env.sync.tearDownTesting()
            env.store.delete(mine)
        }
        model.groupFilter = group.id
        model.selectedID = PanelEntry.clip(mine).id
        #expect(model.availableActions.contains(.addToSaved))
        #expect(!model.availableActions.contains(.saveCopy))
        model.groupFilter = nil
    }

    @Test func shareToGroupCanDropTheCopiesIntoAGroupFolder() throws {
        let tag = UUID().uuidString
        let group = setUpGroup(owner: false)
        let groupFolder = env.store.createFolder(named: "Inbox \(tag)", inSpace: group.id)
        let personal = env.store.ingest(.text("share me \(tag)"))
        defer {
            env.sync.tearDownTesting()
            for item in env.store.allItems() where item.text == "share me \(tag)" { env.store.delete(item) }
            env.store.deleteFolder(groupFolder)
        }

        // The form offers the chosen group's folders; changing group goes back to the root.
        let other = SyncGroup(id: "other-\(tag)", name: "Other", isOwner: true, memberCount: 2)
        let form = ShareGroupState(items: [personal], groups: [group, other], defaultGroupID: group.id,
                                   foldersByGroup: [group.id: [groupFolder], other.id: []])
        #expect(form.destinations.map(\.id) == [groupFolder.id] && form.destination == nil)
        form.moveDestination(by: 1)
        #expect(form.destination?.id == groupFolder.id)
        form.selection = 1
        #expect(form.destination == nil && form.destinations.isEmpty)
        form.selection = 0
        form.moveDestination(by: 1)

        model.share([personal], to: group, folder: form.destination)
        let copy = try #require(env.store.items(inSpace: group.id).first { $0.text == "share me \(tag)" })
        #expect(copy.isPinned && copy.folderID == groupFolder.id)
        #expect(personal.spaceID == nil && !personal.isPinned && personal.folderID == nil)
    }
}

// MARK: - Sync and backup

@MainActor
struct SecretFolderSyncTests {
    @Test func aSecretsFolderRoundTripsAndIsPartOfTheFingerprint() throws {
        let folder = UUID().uuidString.lowercased()
        let payload = SyncPayload.secret(SecretPayload(name: "DB", value: "hunter2", createdAt: 1_000, folder: folder))
        let json = String(decoding: try payload.canonicalJSON(), as: UTF8.self)
        #expect(json.contains("\"folder\":\"\(folder)\""))
        #expect(try SyncPayload.decode(try payload.canonicalJSON()) == payload)

        // Without a folder the bytes are what 1.6 wrote, so nothing re-syncs.
        let plain = SyncPayload.secret(SecretPayload(name: "DB", value: "hunter2", createdAt: 1_000))
        #expect(String(decoding: try plain.canonicalJSON(), as: UTF8.self)
                == #"{"createdAt":1000,"name":"DB","type":"secret","v":1,"value":"hunter2"}"#)
        #expect(try plain.fingerprint() != payload.fingerprint())
        #expect(try payload.withRev(5).fingerprint() == payload.fingerprint())

        // A ref carries its folder into the payload.
        let ref = SecretRef(id: "x", name: "DB", createdAt: Date(timeIntervalSince1970: 1), folderID: UUID(uuidString: folder))
        #expect(SecretPayload(ref: ref, value: "hunter2").folder == folder)
    }

    @Test func movingASecretBetweenFoldersSyncs() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)
        let folder = mac1.store.createFolder(named: "Keys", inSpace: nil)
        let id = mac1.secrets.add(name: "API key", value: "sk-1")
        let received = id.lowercased()   // the item id on the wire
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        #expect(mac2.secrets.refs[received] != nil && mac2.secrets.refs[received]?.folderID == nil)

        mac1.secrets.setFolder(folder.id, id: id)
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        #expect(mac2.secrets.refs[received]?.folderID == folder.id)
        #expect(mac2.store.folder(withID: folder.id) != nil)

        mac1.secrets.setFolder(nil, id: id)
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        #expect(mac2.secrets.refs[received]?.folderID == nil && mac2.secrets.values[received] == "sk-1")

        // Nothing changed: nothing is pushed again.
        let puts = await server.putCount
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        #expect(await server.putCount == puts)
    }

    /// Secrets reach a group through Share to Group (a copy in the group's space) and list in the
    /// group's Saved for every member, in the group's folder if they're in one.
    @Test func groupSecretsInGroupFoldersReachEveryMember() async throws {
        let server = FakeSyncServer()
        let alice = try await FakeUser.make("alice", on: server)
        let bob = try await FakeUser.make("bob", on: server)
        let group = try await makeGroup("Team", owner: alice, members: [bob])
        let aliceMac = try FakeDevice(alice), bobMac = try FakeDevice(bob)
        try await aliceMac.engine.tick()
        let folder = aliceMac.store.createFolder(named: "Prod", inSpace: group)
        let id = aliceMac.secrets.add(name: "Prod DB", value: "s3cret", spaceID: group, folderID: folder.id)
        try await aliceMac.engine.tick()
        try await bobMac.engine.tick()

        let received = try #require(bobMac.secrets.syncSecrets.first { $0.name == "Prod DB" })
        #expect(received.spaceID == group && received.folderID == folder.id)
        #expect(bobMac.store.folder(withID: folder.id)?.spaceID == group)
        #expect(bobMac.secrets.values[received.id] == "s3cret")

        // Bob isn't its author or the owner: his move is refused by the server and stays local.
        bobMac.secrets.setFolder(nil, id: received.id)
        try await bobMac.engine.tick()
        #expect(!bobMac.engine.warnings.isEmpty)
        try await aliceMac.engine.tick()
        #expect(aliceMac.secrets.refs[id]?.folderID == folder.id)
    }

    @Test func backupsKeepASecretsFolder() throws {
        let source = try TestStores()
        let folder = source.store.createFolder(named: "Keys", inSpace: nil)
        let ref = SecretRef(id: UUID().uuidString, name: "API", createdAt: .now, folderID: folder.id)
        let stray = SecretRef(id: UUID().uuidString, name: "Stray", createdAt: .now, folderID: UUID())
        let contents = BackupExporter.contents(store: source.store, snippets: source.snippets,
                                               secrets: [(ref, "sk-1"), (stray, "sk-2")])
        #expect(contents.secrets?.first { $0.name == "API" }?.folder == folder.id.uuidString.lowercased())
        #expect(contents.secrets?.first { $0.name == "Stray" }?.folder == nil)   // unknown folder: the root
        let sealed = try BackupExporter.seal(contents, passphrase: "a long passphrase")
        let document = try BackupImporter.open(sealed, passphrase: "a long passphrase")

        let target = try TestStores()
        let sink = FakeSecretSink()
        _ = BackupImporter.merge(document, store: target.store, snippets: target.snippets, secrets: sink, maxAge: nil)
        let imported = try #require(target.store.folders(inSpace: nil).first)
        #expect(sink.folders["API"] == imported.id)
        #expect(sink.folders["Stray"] == nil)
    }
}

// MARK: - Clicks inside the panel

@MainActor
struct PanelClickTests {
    @Test func onlyClicksOutsideThePanelShapeClose() throws {
        let root = PanelRootView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var closed = 0
        root.onClickOutside = { closed += 1 }
        root.panelShape = { CGPath(roundedRect: CGRect(x: 40, y: 40, width: 320, height: 220), cornerWidth: 22,
                                   cornerHeight: 22, transform: nil) }
        func click(_ x: CGFloat, _ y: CGFloat) throws {
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: y), modifierFlags: [],
                                                        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            root.mouseDown(with: event)
        }
        try click(200, 150)   // an empty part of the panel, passed up by SwiftUI
        try click(45, 45)     // just outside a rounded corner: the halo
        #expect(closed == 1)
        try click(10, 10)     // the shadow halo
        #expect(closed == 2)
    }
}

// MARK: - The group pill

@MainActor
struct GroupPillTests {
    /// The pill grows sideways only: the filter row never changes height as it opens.
    @Test func openingThePillKeepsTheRowHeight() {
        let group = SyncGroup(id: "g", name: "Softmaze", isOwner: true, memberCount: 3)
        func size(selected: Bool, saved: Bool = false) -> CGSize {
            NSHostingView(rootView: GroupChip(group: group, selected: selected, showsSaved: .constant(saved)) {}).fittingSize
        }
        let compact = size(selected: false)
        let copies = size(selected: true)
        let saved = size(selected: true, saved: true)
        #expect(copies.height == compact.height && saved.height == compact.height)
        #expect(copies.width > compact.width + 60)
        // Switching segments doesn't change the pill's width either.
        #expect(copies.width == saved.width)
    }
}
