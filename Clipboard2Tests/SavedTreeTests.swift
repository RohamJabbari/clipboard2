import Testing
import Foundation
import AppKit
@testable import Clipboard2

// MARK: - Flattening (docs/features/panel-v3.md §4 → Saved)

struct SavedTreeLayoutTests {
    static func node(_ name: String, parent: UUID? = nil) -> FolderTree.Node {
        FolderTree.Node(id: UUID(), name: name, parentID: parent, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test func expandedFoldersListTheirLevelUnderThemOneStepDeeper() {
        let work = Self.node("Work"), home = Self.node("Home")
        let clients = Self.node("Clients", parent: work.id), acme = Self.node("Acme", parent: clients.id)
        let tree = FolderTree(nodes: [acme, home, clients, work])
        let names = Dictionary(uniqueKeysWithValues: [work, home, clients, acme].map { ($0.id, $0.name) })
        let items: [UUID?: [String]] = [nil: ["root1", "root2"], work.id: ["w1"], clients.id: ["c1"], acme.id: ["a1"]]
        func layout(_ expanded: Set<UUID>) -> [SavedTreeRow<String>] {
            SavedTreeLayout.rows(tree: tree, folder: { names[$0] }, items: items, expanded: expanded)
        }

        // Collapsed: folders by name, then the top level's items.
        #expect(layout([]).map(\.item) == ["Home", "Work", "root1", "root2"])
        #expect(layout([]).allSatisfy { $0.depth == 0 && $0.parent == nil })

        // Work open: its subfolders, then its items, right under it and indented.
        let open = layout([work.id])
        #expect(open.map(\.item) == ["Home", "Work", "Clients", "w1", "root1", "root2"])
        #expect(open.map(\.depth) == [0, 0, 1, 1, 0, 0])
        #expect(open[2].parent == work.id && open[3].parent == work.id)

        // A collapsed folder hides everything below it, even what's expanded further down.
        #expect(layout([clients.id]).map(\.item) == ["Home", "Work", "root1", "root2"])
        let deep = layout([work.id, clients.id, acme.id])
        #expect(deep.map(\.item) == ["Home", "Work", "Clients", "Acme", "a1", "c1", "w1", "root1", "root2"])
        #expect(deep.map(\.depth) == [0, 0, 1, 2, 3, 2, 1, 0, 0])
        #expect(deep[4].parent == acme.id)
    }

    @Test func aFolderWithoutARowIsSkippedWithItsSubtree() {
        let a = Self.node("A"), b = Self.node("B", parent: a.id)
        let tree = FolderTree(nodes: [a, b])
        let rows = SavedTreeLayout.rows(tree: tree, folder: { $0 == a.id ? nil : "B" }, items: [b.id: ["x"]],
                                        expanded: [a.id, b.id])
        #expect(rows.isEmpty)
    }
}

// MARK: - The panel

@MainActor
struct SavedTreePanelTests {
    let env = AppEnvironment.shared
    let model: PanelViewModel

    init() {
        model = PanelViewModel(env: env)
    }

    private func key(_ code: UInt16, _ chars: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    private func index(of id: String) -> Int? { model.entries.firstIndex { $0.id == id } }

    @Test func foldersExpandInPlaceAndTheArrowsWalkTheTree() throws {
        let tag = UUID().uuidString
        let work = env.store.createFolder(named: "AAA Work \(tag)", inSpace: nil)
        let clients = env.store.createFolder(named: "Clients \(tag)", inSpace: nil, parent: work)
        let inWork = env.store.ingest(.text("in work \(tag)"))
        let inClients = env.store.ingest(.text("in clients \(tag)"))
        defer {
            [inWork, inClients].forEach(env.store.delete)
            env.store.deleteFolder(clients)
            env.store.deleteFolder(work)
        }
        env.store.move([inWork], to: work)
        env.store.move([inClients], to: clients)

        model.filter = .labelled
        let workRow = PanelEntry.folder(work).id, clientsRow = PanelEntry.folder(clients).id
        let workItem = PanelEntry.clip(inWork).id, clientsItem = PanelEntry.clip(inClients).id
        #expect(index(of: workRow) != nil && index(of: clientsRow) == nil && index(of: workItem) == nil)

        // → expands; the subfolder then the item follow, one level in.
        model.selectedID = workRow
        #expect(model.handleKeyDown(key(KeyCode.rightArrow)))
        let w = try #require(index(of: workRow))
        #expect(model.entries[w + 1].id == clientsRow && model.entries[w + 2].id == workItem)
        #expect(model.entryDepths[clientsRow] == 1 && model.entryDepths[workItem] == 1)
        #expect(model.selectedID == workRow)

        // → again steps in; ↓ walks the visible rows.
        #expect(model.handleKeyDown(key(KeyCode.rightArrow)))
        #expect(model.selectedID == clientsRow)
        #expect(model.handleKeyDown(key(KeyCode.rightArrow)))       // expands Clients
        #expect(model.entries[w + 2].id == clientsItem && model.entryDepths[clientsItem] == 2)
        #expect(model.handleKeyDown(key(KeyCode.downArrow)))
        #expect(model.selectedID == clientsItem)

        // ← on an item selects its folder; ← on an expanded folder collapses it.
        #expect(model.handleKeyDown(key(KeyCode.leftArrow)))
        #expect(model.selectedID == clientsRow)
        #expect(model.handleKeyDown(key(KeyCode.leftArrow)))
        #expect(!model.isExpanded(clients) && index(of: clientsItem) == nil)

        // Collapsing the folder above the selection selects that folder.
        model.setExpanded(clients, true)
        model.selectedID = clientsItem
        model.setExpanded(work, false)
        #expect(model.selectedID == workRow && index(of: clientsRow) == nil)

        // Expansion is remembered across chips, per space.
        model.filter = .copies
        model.filter = .labelled
        #expect(model.isExpanded(clients) && !model.isExpanded(work))
        model.groupFilter = "group-\(tag)"
        model.groupShowsSaved = true
        #expect(model.expandedHere.isEmpty)
        model.groupShowsSaved = false
        model.groupFilter = nil
    }

    @Test func searchFlattensAndPicksAFolderToReveal() throws {
        let tag = UUID().uuidString
        let work = env.store.createFolder(named: "Work \(tag)", inSpace: nil)
        let clients = env.store.createFolder(named: "Clients \(tag)", inSpace: nil, parent: work)
        let item = env.store.ingest(.text("deep \(tag)"))
        defer {
            env.store.delete(item)
            env.store.deleteFolder(clients)
            env.store.deleteFolder(work)
        }
        env.store.move([item], to: clients)

        model.filter = .labelled
        model.query = "deep \(tag)"
        let hit = PanelEntry.clip(item).id
        #expect(index(of: hit) != nil && model.entryDepths[hit] == nil)
        #expect(model.folderCaptions[hit] == "Work \(tag) › Clients \(tag)")

        // Picking a folder from the results clears the search and opens it where it lives.
        model.query = "Clients \(tag)"
        model.toggleFolder(clients)
        #expect(model.query.isEmpty && model.isExpanded(work) && model.isExpanded(clients))
        #expect(model.selectedID == PanelEntry.folder(clients).id)
        #expect(model.entryDepths[hit] == 2)
    }

    @Test func newFolderGoesInsideTheSelectedFolderAndShows() throws {
        let tag = UUID().uuidString
        let parent = env.store.createFolder(named: "Parent \(tag)", inSpace: nil)
        defer {
            for folder in env.store.folders(inSpace: nil) where folder.name.hasSuffix(tag) { env.store.deleteFolder(folder) }
        }
        model.filter = .labelled
        model.selectedID = PanelEntry.folder(parent).id
        model.beginNewFolder()
        #expect(model.folderNameForm?.parent?.id == parent.id)
        model.folderNameForm?.name = "Child \(tag)"
        model.submitFolderName()
        let child = try #require(env.store.folders(inSpace: nil).first { $0.name == "Child \(tag)" })
        #expect(child.parentID == parent.id && model.isExpanded(parent))
        #expect(model.selectedID == PanelEntry.folder(child).id && model.entryDepths[PanelEntry.folder(child).id] == 1)

        // Without a folder selected it goes at the top level.
        model.selectedID = nil
        model.beginNewFolder()
        #expect(model.folderNameForm?.parent == nil)
        model.resetMode()
    }
}
