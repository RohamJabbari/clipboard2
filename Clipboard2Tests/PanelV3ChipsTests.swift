import Testing
import Foundation
import AppKit
@testable import Clipboard2

// Quick panel v3 (docs/features/panel-v3.md): the Copies · Saved · Auth · Contacts · Groups
// chips (§4) and Save… (§6).

// MARK: - Chips

@MainActor
struct PanelV3ChipTests {
    let env = AppEnvironment.shared
    let model: PanelViewModel

    init() {
        model = PanelViewModel(env: env)
    }

    @Test func copiesIsOnlyYourOwnHistory() {
        let tag = UUID().uuidString
        let group = SyncGroup(id: "group-\(tag)", name: "Team", isOwner: true, memberCount: 2)
        let contact = SyncContact(id: "contact-\(tag)", name: "sam", uid: "u-sam")
        env.sync.setUpForTesting(groups: [group], uid: "me", authors: [:], contacts: [contact])
        let mine = env.store.ingest(.text("mine \(tag)"))
        let groups = env.store.ingest(.text("group \(tag)"), spaceID: group.id)
        let contacts = env.store.ingest(.text("contact \(tag)"), spaceID: contact.id)
        defer {
            env.sync.tearDownTesting()
            [mine, groups, contacts].forEach(env.store.delete)
        }
        model.filter = .copies
        model.refresh(resetSelection: true)
        #expect(PanelFilter(storedValue: nil) == .copies)
        let ids = Set(model.entries.map(\.id))
        #expect(ids.contains(PanelEntry.clip(mine).id))
        #expect(!ids.contains(PanelEntry.clip(groups).id) && !ids.contains(PanelEntry.clip(contacts).id))
        // Search covers only Copies.
        model.query = tag
        #expect(model.entries.map(\.id) == [PanelEntry.clip(mine).id])
        model.query = ""
    }

    @Test func onlyFromThisAppFiltersCopies() throws {
        let tag = UUID().uuidString
        let app = NSRunningApplication.current
        let bundle = try #require(app.bundleIdentifier)
        let fromApp = env.store.ingest(.text("from app \(tag)", source: AppRef(bundleID: bundle, name: "Here")))
        let elsewhere = env.store.ingest(.text("elsewhere \(tag)", source: AppRef(bundleID: "com.example.other", name: "Other")))
        defer { [fromApp, elsewhere].forEach(env.store.delete) }
        model.prepareForOpen(target: app)
        defer { model.didClose() }
        model.query = tag
        #expect(model.filter == .copies && !model.onlyThisApp)
        #expect(Set(model.entries.compactMap(\.clip?.id)) == [fromApp.id, elsewhere.id])
        model.onlyThisApp = true
        #expect(model.entries.compactMap(\.clip?.id) == [fromApp.id])
        // Reopening with nothing new copied keeps it; after a new copy, Copies starts without it.
        model.prepareForOpen(target: app)
        #expect(model.onlyThisApp && model.query == tag)
        let copied = env.store.ingest(.text("copied \(tag)"))
        defer { env.store.delete(copied) }
        model.prepareForOpen(target: app)
        #expect(!model.onlyThisApp && model.query.isEmpty)
    }

    @Test func savedHoldsClipsSnippetsAndFoldersButNoSecretsOrAuthenticators() throws {
        let tag = UUID().uuidString
        let kept = env.store.ingest(.text("kept \(tag)"))
        env.store.addToSaved([kept])
        let loose = env.store.ingest(.text("loose \(tag)"))
        let snippet = env.snippets.create(name: "Snip \(tag)", keyword: ";\(tag.prefix(6))", body: "b")
        let secret = try #require(env.secrets.add(name: "Secret \(tag)", value: "v-\(tag)"))
        defer {
            [kept, loose].forEach(env.store.delete)
            env.snippets.delete(snippet)
            env.secrets.delete(secret)
        }
        model.filter = .labelled
        let ids = Set(model.entries.map(\.id))
        #expect(ids.contains(PanelEntry.clip(kept).id) && ids.contains(PanelEntry.snippet(snippet).id))
        #expect(!ids.contains(PanelEntry.clip(loose).id) && !ids.contains(PanelEntry.secret(secret).id))
        #expect(!model.entries.contains { $0.authenticator != nil })
        model.query = "Secret \(tag)"
        #expect(model.entries.isEmpty)
        model.query = ""
    }

    @Test func authListsYourAndYourGroupsSecretsNeverAContactsOrClips() throws {
        let tag = UUID().uuidString
        let group = SyncGroup(id: "group-\(tag)", name: "Team", isOwner: true, memberCount: 2)
        let contact = SyncContact(id: "contact-\(tag)", name: "sam", uid: "u-sam")
        env.sync.setUpForTesting(groups: [group], uid: "me", authors: [:], contacts: [contact])
        let mine = try #require(env.secrets.add(name: "B mine \(tag)", value: "1-\(tag)"))
        let groups = try #require(env.secrets.add(name: "A group \(tag)", value: "2-\(tag)", spaceID: group.id))
        let contacts = try #require(env.secrets.add(name: "C contact \(tag)", value: "3-\(tag)", spaceID: contact.id))
        let clip = env.store.ingest(.text("clip \(tag)"))
        defer {
            env.sync.tearDownTesting()
            [mine, groups, contacts].forEach(env.secrets.delete)
            env.store.delete(clip)
        }
        model.filter = .auth
        #expect(model.isAuthView && !model.isSavedView)
        let listed = model.authList().secrets.map(\.id)
        #expect(listed.contains(mine.id) && listed.contains(groups.id) && !listed.contains(contacts.id))
        #expect(!model.entries.contains { $0.clip != nil || $0.snippet != nil || $0.folder != nil })
        #expect(model.sectionStarts.isEmpty)
        // By name, and search covers only Auth.
        model.query = tag
        #expect(Set(model.entries.map(\.id)) == [PanelEntry.secret(mine).id, PanelEntry.secret(groups).id])
        model.query = ""
        let order = model.entries.compactMap(\.secret?.id).filter { [mine.id, groups.id].contains($0) }
        #expect(order == [groups.id, mine.id])
    }

    @Test func groupsShowsOneGroupAndRemembersTheLast() {
        let a = SyncGroup(id: "group-a-\(UUID())", name: "Alpha", isOwner: true, memberCount: 2)
        let b = SyncGroup(id: "group-b-\(UUID())", name: "Beta", isOwner: true, memberCount: 2)

        // Without groups: the chip, nothing listed (the view shows join or create).
        env.sync.setUpForTesting(groups: [], uid: "me", authors: [:], signedIn: true)
        model.filter = .groups
        #expect(model.filter == .groups && model.groupFilter == nil && model.entries.isEmpty)
        #expect(model.filterStops.last == .chip(.groups))
        model.filter = .copies

        env.sync.setUpForTesting(groups: [a, b], uid: "me", authors: [:], signedIn: true)
        defer { env.sync.tearDownTesting() }
        model.groupFilter = b.id
        #expect(model.filter == .groups)
        model.filter = .labelled
        #expect(model.groupFilter == nil && model.isSavedView)
        model.filter = .groups
        #expect(model.groupFilter == b.id)

        // Notifications land in the right chip.
        model.reveal(.group(a.id))
        #expect(model.filter == .groups && model.groupFilter == a.id)
        model.reveal(.inbox(entryID: nil))
        #expect(model.filter == .inbox && model.groupFilter == nil)
        model.reveal(.authenticator(spaceId: "nothing-\(UUID())"))
        #expect(model.filter == .auth)
        model.filter = .copies
    }
}

// MARK: - Save…

@MainActor
struct SaveFormTests {
    let env = AppEnvironment.shared
    let model: PanelViewModel

    init() {
        model = PanelViewModel(env: env)
    }

    @Test func labelPrefill() {
        let labelled = ClipItem(capture: .text("value"))
        labelled.label = "Existing"
        #expect(SaveFormState.suggestedLabel(for: labelled) == "Existing")

        let long = String(repeating: "word ", count: 30)
        let text = ClipItem(capture: .text("\n  \(long)\nsecond line"))
        let suggested = SaveFormState.suggestedLabel(for: text)
        #expect(suggested.count <= 60 && suggested.hasPrefix("word word") && !suggested.contains("second"))
        #expect(SaveFormState.suggestedLabel(for: ClipItem(capture: .text("Short note\nmore"))) == "Short note")

        let image = ClipItem(capture: .text(""))
        image.kind = .image
        #expect(SaveFormState.suggestedLabel(for: image) == "Image")
        let file = ClipItem(capture: .text(""))
        file.kind = .file
        file.fileURLStrings = [URL(fileURLWithPath: "/tmp/Report.pdf").absoluteString]
        #expect(SaveFormState.suggestedLabel(for: file) == "Report.pdf")

        // Never the text of something that looks like a password.
        let key = ClipItem(capture: .text("sk-proj-\(UUID().uuidString)\(UUID().uuidString)"))
        if SensitiveText.detect(key.text) != nil { #expect(SaveFormState.suggestedLabel(for: key) == "") }
    }

    @Test func saveIntoYourFolderPinsLabelsAndMoves() throws {
        let tag = UUID().uuidString
        let folder = env.store.createFolder(named: "Work \(tag)", inSpace: nil)
        let item = env.store.ingest(.text("first line \(tag)\nmore"))
        defer {
            env.store.delete(item)
            env.store.deleteFolder(folder)
        }
        model.query = tag
        model.selectedID = PanelEntry.clip(item).id
        #expect(model.title(for: .save) == "Save…")
        model.perform(.save)
        let form = try #require(model.saveForm)
        #expect(!form.isEditing && form.label == "first line \(tag)" && form.destination == .mine(nil))
        #expect(form.myRows.first?.title == "Saved (no folder)")
        form.destination = .mine(folder.id)
        form.label = "Mine \(tag)"
        model.submitSave()
        #expect(item.isPinned && item.label == "Mine \(tag)" && item.folderID == folder.id)
        #expect(model.notice == "Saved to “\(folder.name)”")

        // Edit Saved… starts where it is; an empty label is allowed.
        model.selectedID = PanelEntry.clip(item).id
        #expect(model.title(for: .save) == "Edit Saved…")
        model.beginSaveSelection()
        let edit = try #require(model.saveForm)
        #expect(edit.isEditing && edit.label == "Mine \(tag)" && edit.destination == .mine(folder.id))
        edit.label = ""
        edit.destination = .mine(nil)
        model.submitSave()
        #expect(item.isPinned && item.label == nil && item.folderID == nil)
        #expect(model.availableActions.contains(.removeFromLabelled))
    }

    @Test func saveIntoAGroupFolderSharesALabelledCopy() throws {
        let tag = UUID().uuidString
        let group = SyncGroup(id: "group-\(tag)", name: "Team", isOwner: false, memberCount: 3)
        env.sync.setUpForTesting(groups: [group], uid: "me", authors: [:], signedIn: true)
        let groupFolder = env.store.createFolder(named: "Shared \(tag)", inSpace: group.id)
        let item = env.store.ingest(.text("share me \(tag)"))
        defer {
            env.sync.tearDownTesting()
            for clip in env.store.allItems() where clip.text == "share me \(tag)" { env.store.delete(clip) }
            env.store.deleteFolder(groupFolder)
        }
        model.beginSave(clips: [item])
        let form = try #require(model.saveForm)
        #expect(form.groups.map(\.id) == [group.id])
        #expect(form.groupRows.map(\.destination) == [.group(group.id, nil), .group(group.id, groupFolder.id)])
        form.destination = .group(group.id, groupFolder.id)
        form.label = "Team copy \(tag)"
        model.submitSave()
        let copy = try #require(env.store.items(inSpace: group.id).first { $0.text == "share me \(tag)" })
        #expect(copy.id != item.id && copy.isPinned && copy.label == "Team copy \(tag)" && copy.folderID == groupFolder.id)
        // Yours doesn't change.
        #expect(item.spaceID == nil && !item.isPinned && item.label == nil)
        #expect(model.notice == "Saved a copy to “\(groupFolder.name)” in Team")
    }

    @Test func aGroupItemSavedToYourSavedIsAPersonalCopy() throws {
        let tag = UUID().uuidString
        let group = SyncGroup(id: "group-\(tag)", name: "Team", isOwner: false, memberCount: 3)
        let theirs = env.store.ingest(.text("their note \(tag)"), spaceID: group.id)
        env.sync.setUpForTesting(groups: [group], uid: "me", authors: [theirs.id.uuidString: "someone-else"], signedIn: true)
        let mine = env.store.createFolder(named: "Mine \(tag)", inSpace: nil)
        defer {
            env.sync.tearDownTesting()
            for clip in env.store.allItems() where clip.text == "their note \(tag)" { env.store.delete(clip) }
            env.store.deleteFolder(mine)
        }
        model.save([theirs], label: "Kept \(tag)", to: .mine(mine.id))
        let copy = try #require(env.store.items(inSpace: nil).first { $0.text == "their note \(tag)" })
        #expect(copy.id != theirs.id && copy.isPinned && copy.label == "Kept \(tag)" && copy.folderID == mine.id)
        #expect(theirs.spaceID == group.id && !theirs.isPinned && theirs.label == nil)
        #expect(model.notice == "Saved a copy to “\(mine.name)”")
    }

    @Test func groupsYouCantSendToAreNotListed() throws {
        let tag = UUID().uuidString
        let readOnly = SyncGroup(id: "group-ro-\(tag)", name: "Read Only", isOwner: false, memberCount: 3, canSend: false)
        let team = SyncGroup(id: "group-team-\(tag)", name: "Team", isOwner: false, memberCount: 3)
        let mine = env.store.ingest(.text("mine \(tag)"), spaceID: readOnly.id)
        env.store.addToSaved([mine])
        env.sync.setUpForTesting(groups: [readOnly, team], uid: "me", authors: [mine.id.uuidString.lowercased(): "me"],
                                 signedIn: true)
        let personal = env.store.ingest(.text("personal \(tag)"))
        defer {
            env.sync.tearDownTesting()
            env.store.delete(mine)
            for clip in env.store.allItems() where clip.text == "personal \(tag)" { env.store.delete(clip) }
        }
        model.beginSave(clips: [personal])
        let form = try #require(model.saveForm)
        #expect(form.groups.map(\.id) == [team.id])
        #expect(!form.groupRows.contains { $0.destination.groupID == readOnly.id })

        // A destination in a group without Send falls back to your Saved.
        let fallback = SaveFormState(clips: [personal], destination: .group(readOnly.id, nil), personalFolders: [],
                                     groups: [team], groupFolders: [:])
        #expect(fallback.destination == .mine(nil))

        // Saving there anyway is refused.
        model.resetMode()
        model.save([personal], label: nil, to: .group(readOnly.id, nil))
        #expect(model.notice == "You can't send to Read Only")
        #expect(!env.store.items(inSpace: readOnly.id).contains { $0.text == "personal \(tag)" })
    }

    @Test func searchFiltersBothListsAndPillsPickAGroup() {
        let tag = UUID().uuidString
        let a = SyncGroup(id: "a-\(tag)", name: "Alpha", isOwner: true, memberCount: 2)
        let b = SyncGroup(id: "b-\(tag)", name: "Beta", isOwner: true, memberCount: 2)
        let work = ClipFolder(name: "Work", spaceID: nil)
        let clients = ClipFolder(name: "Clients", spaceID: nil)
        clients.parentID = work.id
        let design = ClipFolder(name: "Design", spaceID: a.id)
        let item = ClipItem(capture: .text("x"))
        let form = SaveFormState(clips: [item], personalFolders: [work, clients], groups: [a, b],
                                 groupFolders: [a.id: [design], b.id: []])
        #expect(form.myRows.map(\.title) == ["Saved (no folder)", "Work", "Clients"])
        #expect(form.myRows.map(\.level) == [0, 0, 1])
        #expect(form.groupRows.map(\.title) == ["Alpha", "Design", "Beta"])

        form.query = "cli"
        #expect(form.myRows.map(\.title) == ["Clients"] && form.groupRows.isEmpty)
        #expect(form.destination == .mine(clients.id))       // the pick stays visible
        form.query = "beta"
        #expect(form.myRows.isEmpty && form.groupRows.map(\.title) == ["Beta"])
        form.query = ""

        form.groupPill = a.id
        #expect(form.groupRows.map(\.title) == ["Alpha", "Design"])
        // ↑↓ walk My folders, then Group folders.
        form.destination = .mine(clients.id)
        form.moveDestination(by: 1)
        #expect(form.destination == .group(a.id, nil))
        // New Folder in Group folders goes in the picked group; without one, the pill's.
        #expect(form.newFolderPlace(.groups)?.spaceID == a.id)
        form.destination = .mine(nil)
        form.groupPill = nil
        #expect(form.newFolderPlace(.groups) == nil && form.newFolderPlace(.mine)?.spaceID == nil)
    }
}
