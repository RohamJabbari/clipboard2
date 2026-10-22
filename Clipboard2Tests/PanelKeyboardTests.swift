import Testing
import AppKit
@testable import Clipboard2

@MainActor
struct PanelKeyboardTests {
    let env = AppEnvironment.shared
    let model: PanelViewModel

    init() {
        model = PanelViewModel(env: env)
    }

    private func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func tabCyclesFiltersBothWays() {
        model.filter = .all
        #expect(model.handleKeyDown(key(KeyCode.tab, "\t")))
        #expect(model.filter == .pinned)
        #expect(model.handleKeyDown(key(KeyCode.tab, "\t", flags: .shift)))
        #expect(model.filter == .all)
        #expect(model.handleKeyDown(key(KeyCode.tab, "\t", flags: .shift)))
        #expect(model.filter == .thisApp)
    }

    @Test func escapeCloses() {
        var closed = false
        model.onClose = { closed = true }
        #expect(model.handleKeyDown(key(KeyCode.escape, "\u{1b}")))
        #expect(closed)
    }

    @Test func plainTypingIsNotIntercepted() {
        #expect(model.handleKeyDown(key(0, "a")) == false)
    }

    @Test func deleteOnlyInterceptedWhenSearchIsEmpty() {
        model.query = "abc"
        #expect(model.handleKeyDown(key(KeyCode.delete, "\u{7f}")) == false)
    }

    @Test func shiftArrowsExtendAndPlainArrowCollapses() {
        let store = env.store
        let a = store.ingest(.text("multi-a \(UUID())"))
        let b = store.ingest(.text("multi-b \(UUID())"))
        let c = store.ingest(.text("multi-c \(UUID())"))
        defer { [a, b, c].forEach(store.delete) }
        model.query = "multi-"
        model.refresh(resetSelection: true)
        #expect(model.entries.count >= 3)

        #expect(model.handleKeyDown(key(KeyCode.downArrow, "", flags: .shift)))
        #expect(model.handleKeyDown(key(KeyCode.downArrow, "", flags: .shift)))
        #expect(model.selectedIDs.count == 3)
        #expect(model.isMultiSelecting)

        #expect(model.handleKeyDown(key(KeyCode.upArrow, "")))
        #expect(model.selectedIDs.count == 1)
    }

    @Test func toggleAndRangeSelection() {
        let store = env.store
        let items = (0..<4).map { store.ingest(.text("range-\($0) \(UUID())")) }
        defer { items.forEach(store.delete) }
        model.query = "range-"
        model.refresh(resetSelection: true)
        let ids = model.entries.prefix(4).map(\.id)

        model.selectedID = ids[0]
        model.toggleSelection(ids[2])
        #expect(model.selectedIDs == [ids[0], ids[2]])
        model.toggleSelection(ids[0])
        #expect(model.selectedIDs == [ids[2]])

        model.selectedID = ids[1]
        model.extendSelection(to: ids[3])
        #expect(model.selectedIDs == Set(ids[1...3]))
        #expect(model.selectedClips.count == 3)
    }

    @Test func textEditingDeletesPassThroughWhenSearching() {
        model.query = "abc def"
        #expect(model.handleKeyDown(key(KeyCode.delete, "\u{7f}", flags: .command)) == false)
        #expect(model.handleKeyDown(key(KeyCode.delete, "\u{7f}", flags: .option)) == false)
    }

    @Test func actionModeLetsTypingReachTheFilterField() {
        let item = env.store.ingest(.text("action-test \(UUID())"))
        defer { env.store.delete(item) }
        model.query = "action-test"
        model.refresh(resetSelection: true)
        model.openActions()
        #expect(model.mode == .actions)
        #expect(model.handleKeyDown(key(0, "a")) == false)
        #expect(model.handleKeyDown(key(KeyCode.delete, "\u{7f}", flags: .option)) == false)
        #expect(model.handleKeyDown(key(KeyCode.downArrow, "")))
        #expect(model.handleKeyDown(key(KeyCode.escape, "\u{1b}")))
        #expect(model.mode == .browse)
    }

    @Test func unknownActionTextBecomesAnAIInstruction() {
        let previous = env.prefs.aiProvider
        env.prefs.aiProvider = .custom          // needs no key, so AI counts as set up
        defer { env.prefs.aiProvider = previous }
        let item = env.store.ingest(.text("instr-test \(UUID())"))
        defer { env.store.delete(item) }
        model.query = "instr-test"
        model.refresh(resetSelection: true)
        model.openActions()
        model.actionQuery = "make it sound like a pirate"
        #expect(model.filteredActions.last == .ai(.instruction("make it sound like a pirate")))
        model.actionQuery = "zzqxj"
        #expect(model.filteredActions == [.ai(.instruction("zzqxj"))])
    }

    @Test func withoutAIConfiguredOnlySetUpIsOffered() {
        let previous = env.prefs.aiProvider
        env.prefs.aiProvider = .chatGPT         // signed-out account in the test host
        defer { env.prefs.aiProvider = previous }
        guard !env.isAIReady else { return }
        let item = env.store.ingest(.text("setup-test \(UUID())"))
        defer { env.store.delete(item) }
        model.query = "setup-test"
        model.refresh(resetSelection: true)
        model.openActions()
        #expect(model.availableActions.contains(.setUpAI))
        #expect(!model.availableActions.contains(.ai(.summarize)))
        model.actionQuery = "make it a haiku"
        #expect(model.filteredActions == [.setUpAI])
        #expect(model.aiName == "AI")
    }

    @Test func selectionModeOffersOnlyTransientActions() {
        let previous = env.prefs.aiProvider
        env.prefs.aiProvider = .custom
        defer { env.prefs.aiProvider = previous }
        let before = env.store.count()
        model.prepareForSelection("selected words", target: nil)
        #expect(model.mode == .actions)
        #expect(model.entries.count == 1)
        #expect(model.selectedEntry?.clip?.isTransient == true)
        let actions = model.availableActions
        #expect(actions.contains(.ai(.fixGrammar)))
        #expect(actions.contains(.transform(.uppercase)))
        #expect(!actions.contains(.delete) && !actions.contains(.togglePin) && !actions.contains(.setLabel))
        #expect(env.store.count() == before)       // never written to history

        var closed = false
        model.onClose = { closed = true }
        #expect(model.handleKeyDown(key(KeyCode.escape, "\u{1b}")))
        #expect(closed)
    }

    @Test func openingAlwaysSelectsTheNewestItem() {
        let older = env.store.ingest(.text("open-older \(UUID())"), now: .now.addingTimeInterval(-10))
        let newer = env.store.ingest(.text("open-newer \(UUID())"))
        defer { [older, newer].forEach(env.store.delete) }
        model.prepareForOpen(target: nil)
        model.moveSelection(by: 1)                       // user picks something lower down
        model.prepareForOpen(target: nil)                // reopen
        #expect(model.selectedID == model.entries.first?.id)

        // A copy that lands just after opening becomes the selection too.
        let late = env.store.ingest(.text("open-late \(UUID())"))
        defer { env.store.delete(late) }
        model.refresh()
        #expect(model.selectedID == PanelEntry.clip(late).id)
    }
}

@MainActor
struct EditSecretTests {
    let env = AppEnvironment.shared
    let model: PanelViewModel

    init() {
        model = PanelViewModel(env: env)
    }

    private func key(_ code: UInt16, _ chars: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func returnSavesNameAndValue() throws {
        let ref = try #require(env.secrets.add(name: "Clipboard2 edit test", value: "hunter2"))
        defer { env.secrets.delete(ref) }

        model.showEditSecret(ref, value: "hunter2")
        #expect(model.mode == .editSecret)
        let form = try #require(model.editSecretForm)
        form.name = "Clipboard2 edit test renamed"
        form.value = "correct horse"

        #expect(model.handleKeyDown(key(KeyCode.returnKey, "\r")))
        #expect(model.mode == .browse)
        #expect(model.editSecretForm == nil)
        #expect(SecretVault.value(id: ref.id) == "correct horse")
        #expect(SecretVault.list().first { $0.id == ref.id }?.name == "Clipboard2 edit test renamed")
    }

    @Test func emptyValueIsNotSaved() throws {
        let ref = try #require(env.secrets.add(name: "Clipboard2 edit test", value: "hunter2"))
        defer { env.secrets.delete(ref) }

        model.showEditSecret(ref, value: "hunter2")
        model.editSecretForm?.value = ""
        #expect(model.handleKeyDown(key(KeyCode.returnKey, "\r")))
        #expect(model.mode == .editSecret)
        #expect(SecretVault.value(id: ref.id) == "hunter2")
    }

    @Test func escapeDiscardsChanges() throws {
        let ref = try #require(env.secrets.add(name: "Clipboard2 edit test", value: "hunter2"))
        defer { env.secrets.delete(ref) }

        model.showEditSecret(ref, value: "hunter2")
        model.editSecretForm?.value = "changed"
        #expect(model.handleKeyDown(key(KeyCode.escape, "\u{1b}")))
        #expect(model.mode == .browse)
        #expect(SecretVault.value(id: ref.id) == "hunter2")
    }
}
