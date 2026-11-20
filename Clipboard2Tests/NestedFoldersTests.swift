import Testing
import Foundation
import SwiftData
@testable import Clipboard2

// MARK: - The tree (docs/features/nested-folders.md)

struct FolderTreeTests {
    static func node(_ name: String, _ id: UUID = UUID(), parent: UUID? = nil) -> FolderTree.Node {
        FolderTree.Node(id: id, name: name, parentID: parent, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test func childrenPathsAndRelativeNames() {
        let work = Self.node("Work"), home = Self.node("Home")
        let clients = Self.node("Clients", parent: work.id), acme = Self.node("Acme", parent: clients.id)
        let tree = FolderTree(nodes: [acme, home, clients, work])
        #expect(tree.children(of: nil).map(\.name) == ["Home", "Work"])
        #expect(tree.children(of: work.id).map(\.name) == ["Clients"])
        #expect(tree.path(to: acme.id).map(\.name) == ["Work", "Clients", "Acme"])
        #expect(tree.pathName(of: acme.id) == "Work › Clients › Acme")
        #expect(tree.pathName(of: acme.id, relativeTo: work.id) == "Clients › Acme")
        #expect(tree.depth(of: acme.id) == 3 && tree.height(of: work.id) == 3)
        #expect(tree.descendants(of: work.id) == [clients.id, acme.id])
        #expect(tree.flattened().map(\.node.name) == ["Home", "Work", "Clients", "Acme"])
        #expect(tree.flattened().map(\.level) == [0, 0, 1, 2])
    }

    @Test func unknownParentsCyclesAndTooDeepChainsReadAsTopLevel() {
        let orphan = Self.node("Orphan", parent: UUID())
        let a = UUID(), b = UUID()
        let nodeA = Self.node("A", a, parent: b), nodeB = Self.node("B", b, parent: a)
        let selfParent = UUID()
        let me = Self.node("Me", selfParent, parent: selfParent)
        var chain: [FolderTree.Node] = [Self.node("L1")]
        for level in 2...9 { chain.append(Self.node("L\(level)", parent: chain.last!.id)) }
        let tree = FolderTree(nodes: [orphan, nodeA, nodeB, me] + chain)
        #expect(tree.parent(of: orphan.id) == nil)
        #expect(tree.parent(of: a) == nil && tree.parent(of: b) == nil)
        #expect(tree.parent(of: selfParent) == nil)
        // Eight levels are fine; the ninth is shown at the top.
        #expect(tree.depth(of: chain[7].id) == 8)
        #expect(tree.parent(of: chain[8].id) == nil)
        #expect(Set(tree.children(of: nil).map(\.name)) == ["Orphan", "A", "B", "Me", "L1", "L9"])
    }

    @Test func movesNeverMakeCyclesOrGoTooDeep() {
        let work = Self.node("Work"), clients = Self.node("Clients", parent: UUID())
        var nodes = [work, Self.node("Clients", clients.id, parent: work.id)]
        let acme = Self.node("Acme", parent: clients.id)
        nodes.append(acme)
        let home = Self.node("Home")
        nodes.append(home)
        let tree = FolderTree(nodes: nodes)
        #expect(!tree.canMove(work.id, under: work.id))          // into itself
        #expect(!tree.canMove(work.id, under: acme.id))          // into a descendant
        #expect(!tree.canMove(clients.id, under: work.id))       // already there
        #expect(tree.canMove(clients.id, under: home.id))
        #expect(tree.canMove(acme.id, under: nil))
        #expect(!tree.canMove(work.id, under: nil))               // already at the top
        #expect(tree.canMove(work.id, under: home.id))

        var deep: [FolderTree.Node] = [Self.node("D1")]
        for level in 2...7 { deep.append(Self.node("D\(level)", parent: deep.last!.id)) }
        let deepTree = FolderTree(nodes: deep + nodes)
        // Work has 3 levels; under D7 (depth 7) that would be 10.
        #expect(!deepTree.canMove(work.id, under: deep[6].id))
        #expect(deepTree.canMove(acme.id, under: deep[6].id))   // 7 + 1 = 8
        #expect(deepTree.canCreate(in: deep[6].id))
        let d8 = Self.node("D8", parent: deep[6].id)
        #expect(!FolderTree(nodes: deep + [d8]).canCreate(in: d8.id))   // a ninth level
    }
}

// MARK: - Store

@MainActor
struct NestedFolderStoreTests {
    let stores: TestStores
    var store: ClipStore { stores.store }

    init() throws {
        stores = try TestStores()
    }

    @Test func subfoldersAndMoving() {
        let work = store.createFolder(named: "Work", inSpace: nil)
        let clients = store.createFolder(named: "Clients", inSpace: nil, parent: work)
        let home = store.createFolder(named: "Home", inSpace: nil)
        #expect(clients.parentID == work.id)
        #expect(store.tree(inSpace: nil).children(of: work.id).map(\.id) == [clients.id])

        #expect(!store.moveFolder(work, under: clients))           // never into a descendant
        #expect(store.moveFolder(clients, under: home))
        #expect(clients.parentID == home.id)
        #expect(store.moveFolder(clients, under: nil))
        #expect(clients.parentID == nil)
        // Another space's folder can't be a parent.
        let team = store.createFolder(named: "Team", inSpace: "group-1")
        #expect(!store.moveFolder(work, under: team))
    }

    @Test func deletingMovesItemsAndSubfoldersToTheParent() {
        let work = store.createFolder(named: "Work", inSpace: nil)
        let clients = store.createFolder(named: "Clients", inSpace: nil, parent: work)
        let acme = store.createFolder(named: "Acme", inSpace: nil, parent: clients)
        let a = store.ingest(.text("in clients"))
        let b = store.ingest(.text("in acme"))
        store.move([a], to: clients)
        store.move([b], to: acme)

        #expect(store.deleteFolder(clients) == 1)
        #expect(a.isPinned && a.folderID == work.id)
        #expect(acme.parentID == work.id)
        #expect(b.folderID == acme.id)

        // A top-level folder's things go to the root.
        #expect(store.deleteFolder(work) == 1)
        #expect(a.folderID == nil && acme.parentID == nil)
    }

    @Test func sharingAFolderCopiesItsSubtree() {
        let work = store.createFolder(named: "Work", inSpace: nil)
        let clients = store.createFolder(named: "Clients", inSpace: nil, parent: work)
        let acme = store.createFolder(named: "Acme", inSpace: nil, parent: clients)
        store.move([store.ingest(.text("top"))], to: work)
        store.move([store.ingest(.text("deep"))], to: acme)

        let copy = store.shareCopy(of: work, toSpace: "group-1")
        let tree = store.tree(inSpace: "group-1")
        #expect(copy.id != work.id && copy.parentID == nil)
        #expect(tree.flattened().map(\.node.name) == ["Work", "Clients", "Acme"])
        let copiedAcme = tree.flattened()[2].node.id
        #expect(store.items(inSpace: "group-1").first { $0.text == "deep" }?.folderID == copiedAcme)
        #expect(store.items(inSpace: "group-1").first { $0.text == "top" }?.folderID == copy.id)
        // The originals stay as they were.
        #expect(acme.parentID == clients.id && store.items(inSpace: nil).count == 2)
    }

    @Test func parentTravelsInThePayloadAndFingerprint() throws {
        let work = store.createFolder(named: "Work", inSpace: nil)
        let clients = store.createFolder(named: "Clients", inSpace: nil, parent: work)
        let payload = FolderPayload(folder: clients)
        #expect(payload.parent == work.id.uuidString.lowercased())
        let top = FolderPayload(folder: work)
        #expect(top.parent == nil)
        var moved = payload
        moved.parent = nil
        #expect(try SyncPayload.folder(moved).fingerprint() != SyncPayload.folder(payload).fingerprint())
        // Older payloads (no parent) decode as top level.
        let old = try JSONDecoder().decode(FolderPayload.self, from: Data(#"{"v":1,"type":"folder","name":"X","createdAt":1,"updatedAt":1}"#.utf8))
        #expect(old.parent == nil)
        let received = ClipFolder(syncID: UUID(), spaceID: nil)
        payload.apply(to: received)
        #expect(received.parentID == work.id)
    }
}

// MARK: - Sync

@MainActor
struct NestedFolderSyncTests {
    @Test func subfoldersSyncWithTheirParentAndMoves() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac1 = try FakeDevice(user), mac2 = try FakeDevice(user)
        let work = mac1.store.createFolder(named: "Work", inSpace: nil)
        let clients = mac1.store.createFolder(named: "Clients", inSpace: nil, parent: work)
        try await mac1.engine.tick()
        try await mac2.engine.tick()
        let received = try #require(mac2.store.folder(withID: clients.id))
        #expect(received.parentID == work.id)

        #expect(mac2.store.moveFolder(received, under: nil))
        try await mac2.engine.tick()
        try await mac1.engine.tick()
        #expect(mac1.store.folder(withID: clients.id)?.parentID == nil)
    }

    @Test func parentsArePushedBeforeTheirSubfolders() async throws {
        let server = FakeSyncServer()
        let user = try await FakeUser.make("alice", on: server)
        let mac = try FakeDevice(user)
        // Created child first (by name "A…" it would sort first), parent after.
        let zed = mac.store.createFolder(named: "Zed", inSpace: nil)
        let aaa = mac.store.createFolder(named: "Aaa", inSpace: nil, parent: zed)
        try await mac.engine.tick()
        let seqs = await server.live(space: user.personal).reduce(into: [String: Int64]()) { $0[$1.id] = $1.seq }
        #expect(try #require(seqs[zed.id.uuidString.lowercased()]) < (try #require(seqs[aaa.id.uuidString.lowercased()])))
    }
}

// MARK: - Backups

@MainActor
struct NestedFolderBackupTests {
    @Test func parentsRoundTripAndJoinByNameWithinTheSameParent() throws {
        let source = try TestStores()
        let work = source.store.createFolder(named: "Work", inSpace: nil)
        let clients = source.store.createFolder(named: "Clients", inSpace: nil, parent: work)
        source.store.createFolder(named: "Clients", inSpace: nil)   // same name, top level
        let item = source.store.ingest(.text("deep"))
        source.store.move([item], to: clients)

        let contents = BackupExporter.contents(store: source.store, snippets: source.snippets, secrets: nil)
        #expect(contents.folders.first { $0.id == clients.id.uuidString.lowercased() }?.parent == work.id.uuidString.lowercased())
        let document = try BackupImporter.open(try BackupExporter.seal(contents, passphrase: "p"), passphrase: "p")

        let target = try TestStores()
        let existingWork = target.store.createFolder(named: "work", inSpace: nil)
        _ = BackupImporter.merge(document, store: target.store, snippets: target.snippets, secrets: nil, maxAge: nil)
        let tree = target.store.tree(inSpace: nil)
        // "Work" joins the existing one (ignoring case); its "Clients" is created under it, and
        // the top-level "Clients" stays separate.
        #expect(tree.children(of: nil).map(\.name).sorted() == ["Clients", "work"])
        let nested = try #require(tree.children(of: existingWork.id).first)
        #expect(nested.name == "Clients")
        #expect(target.store.items(inSpace: nil).first { $0.text == "deep" }?.folderID == nested.id)

        // Importing again creates nothing new.
        _ = BackupImporter.merge(document, store: target.store, snippets: target.snippets, secrets: nil, maxAge: nil)
        #expect(target.store.folders(inSpace: nil).count == 3)
    }
}
