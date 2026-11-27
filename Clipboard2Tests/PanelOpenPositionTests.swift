import Testing
import Foundation
@testable import Clipboard2

// MARK: - ⇧⌘V opens at the newest copy, or where you left off (docs/features/panel-v3.md §4)

struct OpenPositionRuleTests {
    typealias Mark = PanelViewModel.CopyMark

    @Test func newCopiesJumpEverythingElseRestores() {
        let a = Mark(id: UUID(), copiedAt: Date(timeIntervalSince1970: 100))
        let b = Mark(id: UUID(), copiedAt: Date(timeIntervalSince1970: 200))
        // First open: always at the newest copy.
        #expect(PanelViewModel.opensAtNewestCopy(lastSeen: .none, newest: a))
        #expect(PanelViewModel.opensAtNewestCopy(lastSeen: .none, newest: nil))
        // Nothing copied since: where you were.
        #expect(!PanelViewModel.opensAtNewestCopy(lastSeen: .some(a), newest: a))
        #expect(!PanelViewModel.opensAtNewestCopy(lastSeen: .some(nil), newest: nil))
        // A new item, or the same one copied again.
        #expect(PanelViewModel.opensAtNewestCopy(lastSeen: .some(a), newest: b))
        #expect(PanelViewModel.opensAtNewestCopy(lastSeen: .some(a), newest: Mark(id: a.id, copiedAt: b.copiedAt)))
        #expect(PanelViewModel.opensAtNewestCopy(lastSeen: .some(nil), newest: a))
        // The newest one deleted (an older one is newest again): not a copy.
        #expect(!PanelViewModel.opensAtNewestCopy(lastSeen: .some(b), newest: a))
        #expect(!PanelViewModel.opensAtNewestCopy(lastSeen: .some(a), newest: nil))
    }
}

@MainActor
struct OpenPositionPanelTests {
    let env = AppEnvironment.shared
    let model: PanelViewModel

    init() {
        model = PanelViewModel(env: env)
    }

    @Test func reopeningWithoutANewCopyRestoresChipSearchFoldersAndSelection() throws {
        let tag = UUID().uuidString
        let folder = env.store.createFolder(named: "Open \(tag)", inSpace: nil)
        let a = env.store.ingest(.text("restore a \(tag)"))
        let b = env.store.ingest(.text("restore b \(tag)"))
        defer {
            [a, b].forEach(env.store.delete)
            env.store.deleteFolder(folder)
        }
        env.store.move([a, b], to: folder)

        model.prepareForOpen(target: nil)
        #expect(model.filter == .copies)
        model.filter = .labelled
        model.setExpanded(folder, true)
        model.click(.clip(a))                     // the folder's second row
        let selected = model.selectedID
        let token = model.openToken
        model.didClose()

        // Nothing new copied: the same chip, expansion and row; the list doesn't jump to the top.
        model.prepareForOpen(target: nil)
        #expect(model.filter == .labelled && model.isExpanded(folder) && model.selectedID == selected)
        #expect(model.openToken == token)

        // Search text survives too.
        model.query = "restore a \(tag)"
        model.didClose()
        model.prepareForOpen(target: nil)
        #expect(model.filter == .labelled && model.query == "restore a \(tag)")
        #expect(model.selectedID == PanelEntry.clip(a).id)

        // A new copy: Copies, no search, the new item selected and scrolled to.
        let copied = env.store.ingest(.text("restore new \(tag)"))
        defer { env.store.delete(copied) }
        model.didClose()
        model.prepareForOpen(target: nil)
        #expect(model.filter == .copies && model.groupFilter == nil && model.query.isEmpty)
        #expect(model.selectedID == PanelEntry.clip(copied).id && model.openToken == token &+ 1)
        // Folders stay expanded for when you go back.
        model.filter = .labelled
        #expect(model.isExpanded(folder))
    }

    @Test func reopeningKeepsTheGroupAndItsSavedTab() {
        let group = "group-\(UUID().uuidString)"
        model.prepareForOpen(target: nil)
        model.groupFilter = group
        model.groupShowsSaved = true
        defer { model.groupShowsSaved = false }
        model.didClose()
        model.prepareForOpen(target: nil)
        #expect(model.filter == .groups && model.groupFilter == group && model.isSavedView)
    }
}
