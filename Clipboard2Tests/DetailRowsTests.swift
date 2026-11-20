import Testing
import Foundation
import AppKit
@testable import Clipboard2

// The preview details' Label and Folder rows, ⌘L, ⌘⇧M and Add Items in the Saved header.

@MainActor
struct DetailRowsTests {
    let env = AppEnvironment.shared
    let model: PanelViewModel

    init() {
        model = PanelViewModel(env: env)
    }

    private func key(_ code: UInt16, _ chars: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func commandLLabelsTheSelectionOrEveryClipInIt() {
        let tag = UUID().uuidString
        let a = env.store.ingest(.text("one \(tag)"))
        let b = env.store.ingest(.text("two \(tag)"))
        defer {
            env.store.delete(a)
            env.store.delete(b)
        }
        model.query = tag
        model.selectedID = PanelEntry.clip(a).id
        #expect(model.handleKeyDown(key(37, "l", flags: .command)))
        #expect(model.mode == .label)
        model.labelForm?.text = "First \(tag)"
        model.submitLabel()
        #expect(a.label == "First \(tag)" && a.isPinned)

        model.query = tag
        model.selectAll()
        #expect(model.isMultiSelecting)
        #expect(model.availableActions.contains(.setLabel))
        #expect(PanelAction.setLabel.shortcutHint == "⌘L")
        #expect(model.handleKeyDown(key(37, "l", flags: .command)))
        model.labelForm?.text = "Both \(tag)"
        model.submitLabel()
        #expect(a.label == "Both \(tag)" && b.label == "Both \(tag)")
        #expect(model.notice == "Labelled 2 items")
    }

    @Test func labellingIsHiddenWhereTheServerWouldRefuseIt() {
        let group = SyncGroup(id: "group-\(UUID())", name: "Team", isOwner: false, memberCount: 3)
        let theirs = env.store.ingest(.text("theirs \(UUID())"), spaceID: group.id)
        let mine = env.store.ingest(.text("mine \(UUID())"), spaceID: group.id)
        env.sync.setUpForTesting(groups: [group], uid: "me",
                                 authors: [theirs.id.uuidString.lowercased(): "sam", mine.id.uuidString.lowercased(): "me"])
        defer {
            env.sync.tearDownTesting()
            env.store.delete(theirs)
            env.store.delete(mine)
        }
        #expect(!model.canLabel(.clip(theirs)))
        #expect(model.canLabel(.clip(mine)))
        // Selected text from another app is never labelled.
        #expect(!model.canLabel(.clip(ClipItem(capture: .text("selection")))))
    }

    @Test func folderPickerMovesIntoAFolderOrSavesAtTheTopLevel() throws {
        let tag = UUID().uuidString
        let work = env.store.createFolder(named: "Work \(tag)", inSpace: nil)
        let clients = env.store.createFolder(named: "Clients \(tag)", inSpace: nil, parent: work)
        let item = env.store.ingest(.text("note \(tag)"))
        defer {
            env.store.delete(item)
            env.store.deleteFolder(clients)
            env.store.deleteFolder(work)
        }
        model.query = tag
        model.selectedID = PanelEntry.clip(item).id
        #expect(model.folderPath(of: .clip(item)) == nil)
        #expect(model.handleKeyDown(key(46, "m", flags: [.command, .shift])))
        #expect(model.mode == .folderPicker)
        let form = try #require(model.folderPicker)
        #expect(form.rows.first?.kind == .topLevel)
        let row = try #require(form.rows.first { $0.kind == .folder(clients) })
        #expect(row.level == 1)
        #expect(form.rows.last?.kind == .newFolder(parent: nil, personal: false))

        model.pick(row)
        #expect(item.isPinned && item.folderID == clients.id)
        #expect(model.folderPath(of: .clip(item)) == "Saved › Work \(tag) › Clients \(tag)")

        model.selectedID = PanelEntry.clip(item).id
        model.beginFolderPicker()
        model.pick(try #require(model.folderPicker?.rows.first))
        #expect(item.isPinned && item.folderID == nil)
    }

    @Test func addItemsSavesTickedHistoryIntoTheOpenFolder() throws {
        let tag = UUID().uuidString
        let folder = env.store.createFolder(named: "Inbox \(tag)", inSpace: nil)
        let a = env.store.ingest(.text("alpha \(tag)"))
        let b = env.store.ingest(.text("beta \(tag)"))
        let saved = env.store.ingest(.text("saved \(tag)"))
        env.store.addToSaved([saved])
        defer {
            for item in [a, b, saved] { env.store.delete(item) }
            env.store.deleteFolder(folder)
        }
        model.filter = .labelled
        model.openFolder(folder)
        model.beginAddItems()
        let form = try #require(model.addItemsForm)
        #expect(model.mode == .addItems)
        form.query = tag
        #expect(Set(form.shown.map(\.id)) == [a.id, b.id])   // already-saved items aren't offered
        form.selection = form.shown.firstIndex { $0.id == a.id } ?? 0
        #expect(model.handleKeyDown(key(KeyCode.space, " ")))
        form.selection = form.shown.firstIndex { $0.id == b.id } ?? 0
        #expect(model.handleKeyDown(key(KeyCode.space, " ")))
        #expect(form.checked == [a.id, b.id])
        #expect(model.handleKeyDown(key(KeyCode.returnKey, "\r")))
        #expect(a.isPinned && a.folderID == folder.id && b.folderID == folder.id)
        #expect(model.notice == "Added 2 items to Inbox \(tag)")
        #expect(model.mode == .browse)

        // Esc cancels without adding anything.
        model.beginAddItems()
        #expect(model.handleKeyDown(key(KeyCode.escape, "\u{1b}")))
        #expect(model.mode == .browse && model.addItemsForm == nil)
    }
}
