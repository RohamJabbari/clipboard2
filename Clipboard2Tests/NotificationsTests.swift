import AppKit
import Foundation
import SwiftData
import Testing
@testable import Clipboard2

// MARK: - The diff (docs/features/notifications-contacts.md → Events)

private let me = "me-uid"

private func group(_ name: String, owner: Bool = false, members: [String: String] = [me: "me", "sam": "sam"])
-> NotificationSnapshot.Group {
    .init(name: name, isOwner: owner, members: members)
}

private func arrival(_ text: String, in space: String = "g1", by author: String = "sam", id: String = UUID().uuidString)
-> NotificationArrival {
    NotificationArrival(entryID: "c-" + id, spaceId: space, authorUid: author, what: .text(text))
}

struct NotificationDiffTests {
    let base = NotificationSnapshot(groups: ["g1": group("Team")], contacts: ["c1": .init(name: "alex", ownedByMe: false)])

    @Test func someoneSharingInAGroup() {
        let events = NotificationDiff.events(from: base, to: base, arrivals: [arrival("hello there", id: "A")], me: me)
        #expect(events == [AppNotification(kind: .groupActivity, title: "Team", body: "sam shared “hello there”",
                                           target: .groupItem(spaceId: "g1", entryID: "c-A", saved: false),
                                           groupId: "g1", arrivalIn: .group("g1"))])
    }

    @Test func previewsNeverShowSecretsOrConcealedContent() {
        #expect(NotificationDiff.phrase(.image) == "an image")
        #expect(NotificationDiff.phrase(.secret) == "a secret")
        #expect(NotificationDiff.phrase(.files(["report.pdf"])) == "“report.pdf”")
        #expect(NotificationDiff.phrase(.files(["a", "b"])) == "2 files")
        #expect(NotificationDiff.phrase(.text("first line\nsecond")) == "“first line”")
        #expect(NotificationDiff.phrase(.text("A rather long first line that keeps going and going")) == "“A rather long first line that keeps goi…”")
        #expect(NotificationDiff.phrase(.text("   ")) == "some text")
        // Something that looks like a key or password isn't shown either.
        #expect(NotificationDiff.phrase(.text("sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789")) == "some text")
        let secret = NotificationArrival(entryID: "k-1", spaceId: "g1", authorUid: "sam", what: .secret)
        let events = NotificationDiff.events(from: base, to: base, arrivals: [secret], me: me)
        #expect(events.first?.body == "sam shared a secret")
        #expect(events.first?.target == .groupItem(spaceId: "g1", entryID: "k-1", saved: true))
    }

    @MainActor @Test func concealedImagesAreJustImages() throws {
        let container = try ModelContainer(for: AppEnvironment.schema,
                                           configurations: ModelConfiguration(schema: AppEnvironment.schema, isStoredInMemoryOnly: true))
        let store = ClipStore(context: container.mainContext,
                              blobs: BlobStore(directory: FileManager.default.temporaryDirectory.appending(path: "Notify-\(UUID())")))
        let item = store.ingest(.text("otpauth secret looking text"))
        item.label = "Bank QR"
        item.isConcealed = true
        #expect(NotificationDiff.what(of: item) == .image)
        item.isConcealed = false
        #expect(NotificationDiff.what(of: item) == .labelled("Bank QR"))
    }

    @Test func groupItemsAreBatchedPerGroupAndAuthor() {
        var new = base
        new.groups["g1"]?.members["kim"] = "kim"
        var old = base
        old.groups["g1"]?.members["kim"] = "kim"
        let arrivals = (0..<5).map { arrival("item \($0)") } + [arrival("from kim", by: "kim")]
        let events = NotificationDiff.events(from: old, to: new, arrivals: arrivals, me: me)
        #expect(events.map(\.body) == ["sam shared 5 items", "kim shared “from kim”"])
    }

    @Test func nothingAboutYourOwnItemsFromAnyDevice() {
        let events = NotificationDiff.events(from: base, to: base, arrivals: [arrival("mine", by: me)], me: me)
        #expect(events.isEmpty)
    }

    @Test func joiningAGroupDoesNotAnnounceWhatWasAlreadyThere() {
        var new = base
        new.groups["g2"] = group("New")
        let events = NotificationDiff.events(from: base, to: new, arrivals: [arrival("old", in: "g2")], me: me)
        #expect(events.isEmpty)
    }

    @Test func someoneJoinsAndSomeoneLeaves() {
        var new = base
        new.groups["g1"]?.members = [me: "me", "kim": "kim"]
        let events = NotificationDiff.events(from: base, to: new, arrivals: [], me: me)
        #expect(events == [
            AppNotification(kind: .groupMembers, title: "Team", body: "kim joined", target: .group("g1"), groupId: "g1"),
            AppNotification(kind: .groupMembers, title: "Team", body: "sam left", target: .group("g1"), groupId: "g1"),
        ])
        // Removed here by you: not news.
        let own = OwnActions(removedMembers: [OwnActions.member("sam", in: "g1")])
        #expect(NotificationDiff.events(from: base, to: new, arrivals: [], me: me, own: own).map(\.body) == ["kim joined"])
        // A server that doesn't list members says nothing either way.
        var unlisted = base
        unlisted.groups["g1"]?.members = [:]
        #expect(NotificationDiff.events(from: base, to: unlisted, arrivals: [], me: me).isEmpty)
    }

    @Test func removedOrDeletedGroups() {
        var new = base
        new.groups["g1"] = nil
        #expect(NotificationDiff.events(from: base, to: new, arrivals: [], me: me) == [
            AppNotification(kind: .groupMembers, title: "Team", body: "You're no longer in this group", target: nil, groupId: "g1"),
        ])
        // Left here, or a group you own deleted (only you can): nothing.
        #expect(NotificationDiff.events(from: base, to: new, arrivals: [], me: me, own: OwnActions(leftGroups: ["g1"])).isEmpty)
        var owned = base
        owned.groups["g1"]?.isOwner = true
        #expect(NotificationDiff.events(from: owned, to: new, arrivals: [], me: me).isEmpty)
    }

    @Test func renamedGroups() {
        var new = base
        new.groups["g1"]?.name = "Crew"
        #expect(NotificationDiff.events(from: base, to: new, arrivals: [], me: me) == [
            AppNotification(kind: .groupActivity, title: "Crew", body: "Team was renamed", target: .group("g1"), groupId: "g1"),
        ])
        // Only the owner renames: as owner it was you (here or on another device).
        var owned = new
        owned.groups["g1"]?.isOwner = true
        #expect(NotificationDiff.events(from: base, to: owned, arrivals: [], me: me).isEmpty)
        #expect(NotificationDiff.events(from: base, to: new, arrivals: [], me: me, own: OwnActions(renamedGroups: ["g1": "Crew"])).isEmpty)
    }

    @Test func contactRequestsAndNewContacts() {
        let request = ContactRequest(spaceId: "s9", uid: "u9", username: "pat", name: "pat", createdAt: 1)
        #expect(NotificationDiff.requestEvents([request]) == [
            AppNotification(kind: .contacts, title: "Contact request", body: "pat wants to add you",
                            target: .people(requestSpaceId: "s9"), hudText: "pat wants to add you as a contact",
                            hudSymbol: "person.crop.circle.badge.plus"),
        ])
        var new = base
        new.contacts["c2"] = .init(name: "pat", ownedByMe: true)    // your request accepted, or your code used
        new.contacts["c3"] = .init(name: "lee", ownedByMe: false)   // you accepted theirs: you did that
        let events = NotificationDiff.events(from: base, to: new, arrivals: [], me: me)
        #expect(events.map { "\($0.title) \($0.body)" } == ["pat is now your contact"])
        #expect(events.first?.target == .people(requestSpaceId: nil))
    }

    @Test func contactItemsAreBatchedPerContact() {
        var old = base
        old.contacts["c2"] = .init(name: "pat", ownedByMe: true)
        let arrivals = [arrival("one", in: "c1", by: "alex", id: "1"), arrival("two", in: "c1", by: "alex"),
                        arrival("hi", in: "c2", by: "pat", id: "3")]
        let events = NotificationDiff.events(from: old, to: old, arrivals: arrivals, me: me)
        #expect(events.map { "\($0.title): \($0.body)" } == ["alex: sent 2 items", "pat: sent “hi”"])
        #expect(events[0].target == .inbox(entryID: "c-1") && events[0].arrivalIn == .inbox)
        #expect(events[1].hudText == "pat sent you “hi”")
    }

    @Test func authenticatorsSharedOrHandedOver() {
        var named = base
        named.shared["a1"] = .init(ownerName: "sam", issuer: "")
        // Not named yet (no codes): wait for them.
        #expect(NotificationDiff.events(from: base, to: named, arrivals: [], me: me).isEmpty)
        var withCodes = named
        withCodes.shared["a1"]?.issuer = "GitHub"
        let shared = NotificationDiff.events(from: named, to: withCodes, arrivals: [], me: me)
        #expect(shared == [AppNotification(kind: .authenticators, title: "sam", body: "shared GitHub codes with you",
                                           target: .authenticator(spaceId: "a1"))])
        #expect(NotificationDiff.events(from: withCodes, to: withCodes, arrivals: [], me: me).isEmpty)   // once

        var owner = base
        owner.owned["a1"] = "GitHub"
        #expect(NotificationDiff.events(from: withCodes, to: owner, arrivals: [], me: me).map(\.body) == ["made you the owner of GitHub"])
        // One you made (here or on another device): nothing.
        #expect(NotificationDiff.events(from: base, to: owner, arrivals: [], me: me).isEmpty)
    }

    @Test func ownActionsStayUntilASyncShowsThem() {
        let own = OwnActions(leftGroups: ["g1"], removedMembers: [OwnActions.member("sam", in: "g1")], renamedGroups: ["g1": "Crew"])
        #expect(own.pruned(by: base) == own)
        var done = base
        done.groups["g1"] = group("Crew", members: [me: "me"])
        #expect(own.pruned(by: done) == OwnActions(leftGroups: ["g1"]))
        #expect(own.pruned(by: NotificationSnapshot()) == OwnActions())
    }

    @Test func targetsSurviveTheNotification() {
        for target in [NotificationTarget.group("g"), .groupItem(spaceId: "g", entryID: "c-1", saved: true),
                       .people(requestSpaceId: nil), .inbox(entryID: "k-2"), .authenticator(spaceId: "a")] {
            #expect(NotificationTarget(encoded: target.encoded) == target)
        }
    }
}

// MARK: - Delivery rules

struct NotificationRulesTests {
    let groupEvent = AppNotification(kind: .groupActivity, title: "Team", body: "sam shared 2 items", target: .group("g1"),
                                     groupId: "g1", arrivalIn: .group("g1"))
    let contactEvent = AppNotification(kind: .contacts, title: "alex", body: "sent “x”", target: .inbox(entryID: nil),
                                       arrivalIn: .inbox, hudText: "alex sent you “x”")

    @Test func postsByDefaultAndAsksFirst() {
        #expect(NotificationRules.delivery(of: groupEvent, settings: .init(), allowed: nil, showing: nil) == .post)
        #expect(NotificationRules.delivery(of: groupEvent, settings: .init(), allowed: true, showing: .inbox) == .post)
    }

    @Test func nothingWhileThePanelShowsIt() {
        #expect(NotificationRules.delivery(of: groupEvent, settings: .init(), allowed: true, showing: .group("g1")) == .drop)
        #expect(NotificationRules.delivery(of: contactEvent, settings: .init(), allowed: true, showing: .inbox) == .drop)
        #expect(NotificationRules.delivery(of: contactEvent, settings: .init(), allowed: false, showing: .inbox) == .drop)
    }

    @Test func mutedGroupsAndKindsSwitchedOff() {
        #expect(NotificationRules.delivery(of: groupEvent, settings: .init(mutedGroups: ["g1"]), allowed: true, showing: nil) == .drop)
        #expect(NotificationRules.delivery(of: groupEvent, settings: .init(kinds: [.contacts]), allowed: true, showing: nil) == .drop)
        #expect(NotificationRules.delivery(of: contactEvent, settings: .init(kinds: [.groupActivity]), allowed: true, showing: nil) == .drop)
    }

    @Test func theHUDOnlyWhenNotificationsAreOffOrNotAllowed() {
        #expect(NotificationRules.delivery(of: contactEvent, settings: .init(enabled: false), allowed: true, showing: nil) == .hud)
        #expect(NotificationRules.delivery(of: contactEvent, settings: .init(), allowed: false, showing: nil) == .hud)
        #expect(NotificationRules.delivery(of: groupEvent, settings: .init(enabled: false), allowed: true, showing: nil) == .drop)
        #expect(NotificationRules.delivery(of: groupEvent, settings: .init(), allowed: false, showing: nil) == .drop)
    }
}

// MARK: - The hub

final class FakePoster: NotificationPosting {
    var state: NotificationPermission
    var grants: Bool
    private(set) var asked = 0
    private(set) var posted: [AppNotification] = []

    init(state: NotificationPermission = .notDetermined, grants: Bool = true) {
        self.state = state
        self.grants = grants
    }

    func permission() async -> NotificationPermission { state }
    func requestPermission() async -> Bool {
        asked += 1
        state = grants ? .allowed : .denied
        return grants
    }
    func post(_ notification: AppNotification) { posted.append(notification) }
}

@MainActor
struct NotificationHubTests {
    let defaults = UserDefaults(suiteName: "NotificationHubTests-\(UUID())")!
    var prefs: Preferences { Preferences(defaults: defaults) }

    private var withItem: NotificationSnapshot { NotificationSnapshot(groups: ["g1": group("Team")]) }

    @Test func theFirstSyncOnlyRecordsAndPermissionIsAskedOnceWhenNeeded() async {
        let poster = FakePoster()
        let hub = NotificationHub(prefs: prefs, defaults: defaults, poster: poster)
        // After signing in: what's there isn't news, and nothing is asked yet.
        hub.observe(withItem, arrivals: [arrival("old")], me: me, own: OwnActions(), recordOnly: true)
        await hub.settle()
        #expect(poster.posted.isEmpty && poster.asked == 0)

        hub.observe(withItem, arrivals: [arrival("new")], me: me, own: OwnActions(), recordOnly: false)
        hub.observe(withItem, arrivals: [arrival("newer")], me: me, own: OwnActions(), recordOnly: false)
        await hub.settle()
        #expect(poster.asked == 1)
        #expect(poster.posted.map(\.body) == ["sam shared “new”", "sam shared “newer”"])
        #expect(hub.permission == .allowed)
    }

    @Test func noBaselineMeansRecordOnly() async {
        let poster = FakePoster(state: .allowed)
        let hub = NotificationHub(prefs: prefs, defaults: defaults, poster: poster)
        hub.observe(withItem, arrivals: [arrival("new")], me: me, own: OwnActions(), recordOnly: false)
        await hub.settle()
        #expect(poster.posted.isEmpty)
        // The baseline outlives a relaunch, so what changed while the Mac was off is noticed.
        let again = NotificationHub(prefs: prefs, defaults: defaults, poster: poster)
        again.observe(withItem, arrivals: [arrival("while off")], me: me, own: OwnActions(), recordOnly: false)
        await again.settle()
        #expect(poster.posted.map(\.body) == ["sam shared “while off”"])
        // Signing out forgets it.
        again.forget()
        let fresh = NotificationHub(prefs: prefs, defaults: defaults, poster: poster)
        fresh.observe(withItem, arrivals: [arrival("x")], me: me, own: OwnActions(), recordOnly: false)
        await fresh.settle()
        #expect(poster.posted.count == 1)
    }

    @Test func deniedFallsBackToTheHUDForContactsOnly() async {
        let poster = FakePoster(grants: false)
        let hub = NotificationHub(prefs: prefs, defaults: defaults, poster: poster)
        var bubbles: [String] = []
        hub.showHUD = { text, _ in bubbles.append(text) }
        let snapshot = NotificationSnapshot(groups: ["g1": group("Team")], contacts: ["c1": .init(name: "alex", ownedByMe: false)])
        hub.observe(snapshot, arrivals: [], me: me, own: OwnActions(), recordOnly: true)
        hub.observe(snapshot, arrivals: [arrival("hi", in: "c1", by: "alex"), arrival("group thing")], me: me,
                    own: OwnActions(), recordOnly: false)
        await hub.settle()
        #expect(poster.asked == 1 && poster.posted.isEmpty)
        #expect(bubbles == ["alex sent you “hi”"])
        #expect(hub.permission == .denied)
    }

    @Test func mutedGroupsAndThePanelShowingIt() async {
        let poster = FakePoster(state: .allowed)
        let prefs = self.prefs
        let hub = NotificationHub(prefs: prefs, defaults: defaults, poster: poster)
        await hub.refreshPermission()
        hub.observe(withItem, arrivals: [], me: me, own: OwnActions(), recordOnly: true)
        hub.showing = { .group("g1") }
        hub.observe(withItem, arrivals: [arrival("seen")], me: me, own: OwnActions(), recordOnly: false)
        hub.showing = { nil }
        prefs.setMuted(true, group: "g1")
        hub.observe(withItem, arrivals: [arrival("muted")], me: me, own: OwnActions(), recordOnly: false)
        prefs.setMuted(false, group: "g1")
        prefs.setNotifies(.groupActivity, false)
        hub.observe(withItem, arrivals: [arrival("kind off")], me: me, own: OwnActions(), recordOnly: false)
        prefs.setNotifies(.groupActivity, true)
        hub.observe(withItem, arrivals: [arrival("shown")], me: me, own: OwnActions(), recordOnly: false)
        await hub.settle()
        #expect(poster.posted.map(\.body) == ["sam shared “shown”"])
        #expect(Preferences(defaults: defaults).notificationSettings == NotificationSettings())
    }
}

// MARK: - From a real sync to a notification

@MainActor
private func notified(_ harness: AccountHarness) -> FakePoster {
    let poster = FakePoster(state: .allowed)
    let defaults = UserDefaults(suiteName: "NotifyIntegration-\(UUID())")!
    harness.account.notifications = NotificationHub(prefs: harness.prefs, defaults: defaults, poster: poster)
    return poster
}

@MainActor
struct NotificationSyncTests {
    @Test func groupsAndContactsEndToEnd() async throws {
        let server = FakeSyncServer()
        let alice = try AccountHarness(server), bob = try AccountHarness(server)
        let aliceHeard = notified(alice), bobHeard = notified(bob)
        await alice.account.signUp(email: "alice@x.at", password: "alice password", username: "useralice")
        await bob.account.signUp(email: "bob@x.at", password: "bob password", username: "userbob")
        await alice.settle()
        await bob.settle()

        // A group: bob joins with alice's code. Joining tells nobody but alice.
        let team = try await alice.account.createGroup(named: "Team")
        await alice.settle()
        let code = try await alice.account.createInviteCode(for: team)
        try await bob.account.join(try await bob.account.previewInvite(code: code))
        await bob.settle()
        await alice.settle()
        await bob.account.notifications?.settle()
        await alice.account.notifications?.settle()
        #expect(bobHeard.posted.isEmpty)
        #expect(aliceHeard.posted.map { "\($0.title): \($0.body)" } == ["Team: userbob joined"])

        // Alice shares; bob hears, alice (the author) doesn't.
        alice.store.ingest(.text("hello group"), spaceID: team.id)
        await alice.settle()
        await bob.settle()
        await bob.account.notifications?.settle()
        #expect(bobHeard.posted.last?.body == "useralice shared “hello group”")
        #expect(bobHeard.posted.last?.target.map {
            if case .groupItem(let space, _, false) = $0 { space == team.id } else { false }
        } == true)

        // Renamed by its owner: the members hear; alice did it.
        try await alice.account.renameGroup(team, to: "Crew")
        await alice.settle()
        await bob.settle()
        await bob.account.notifications?.settle()
        #expect(bobHeard.posted.last.map { "\($0.title): \($0.body)" } == "Crew: Team was renamed")

        // Bob leaves: alice hears, bob doesn't.
        let bobCount = bobHeard.posted.count
        try await bob.account.leave(try #require(bob.account.groups.first))
        await bob.settle()
        await alice.settle()
        await alice.account.notifications?.settle()
        await bob.account.notifications?.settle()
        #expect(aliceHeard.posted.last?.body == "userbob left")
        #expect(bobHeard.posted.count == bobCount)

        // Contacts: a request, accepted; then an item.
        let request = try await alice.account.requestContact(username: "userbob")
        await bob.account.refreshContacts()   // the first look of the session only records
        let carol = try AccountHarness(server)
        await carol.account.signUp(email: "carol@x.at", password: "carol password", username: "usercarol")
        try await carol.account.requestContact(username: "userbob")
        await bob.account.refreshContacts()
        await bob.account.notifications?.settle()
        #expect(bobHeard.posted.last.map { "\($0.title): \($0.body)" } == "Contact request: usercarol wants to add you")

        try await bob.account.accept(try #require(bob.account.contactRequests.incoming.first { $0.spaceId == request.spaceId }))
        await bob.settle()
        await alice.settle()
        await alice.account.notifications?.settle()
        #expect(aliceHeard.posted.last.map { "\($0.title) \($0.body)" } == "userbob is now your contact")

        alice.store.ingest(.text("for bob"), spaceID: request.spaceId)
        alice.store.ingest(.text("also for bob"), spaceID: request.spaceId)
        await alice.settle()
        await bob.settle()
        await bob.account.notifications?.settle()
        #expect(bobHeard.posted.last.map { "\($0.title): \($0.body)" } == "useralice: sent 2 items")
    }
}

// MARK: - Contacts → People and Send to Contact…

struct PeopleListTests {
    let sam = SyncContact(id: "s-sam", name: "sam", uid: "u1")
    let alex = SyncContact(id: "s-alex", name: "alex", uid: "u2")
    let zoe = SyncContact(id: "s-zoe", name: "Zoe", uid: "u3")

    @Test func requestsFirstThenMostRecentThenByName() {
        let requests = ContactRequests(incoming: [ContactRequest(spaceId: "r1", uid: "u9", username: "pat", name: "pat", createdAt: 1)],
                                       outgoing: [ContactRequest(spaceId: "r2", uid: "u8", username: "lee", name: "lee", createdAt: 1)])
        let rows = PeopleList.rows(contacts: [sam, alex, zoe], requests: requests,
                                   lastExchange: ["s-zoe": Date(timeIntervalSince1970: 10)], query: "")
        #expect(rows.map(\.id) == ["in-r1", "out-r2", "p-s-zoe", "p-s-alex", "p-s-sam"])
    }

    @Test func searchMatchesNameAndUsername() {
        let requests = ContactRequests(incoming: [ContactRequest(spaceId: "r1", uid: "u9", username: "pat.k", name: "Patrick", createdAt: 1)])
        #expect(PeopleList.rows(contacts: [sam, alex], requests: requests, lastExchange: [:], query: "sm").map(\.name) == ["sam"])
        #expect(PeopleList.rows(contacts: [sam, alex], requests: requests, lastExchange: [:], query: "pat.k").map(\.name) == ["Patrick"])
    }

    @Test func pickerSendsToTheTickedOrTheHighlighted() {
        let form = ContactPickerState(clips: [], secrets: [], contacts: [sam, alex, zoe])
        #expect(form.recipients(adding: false) == [sam])
        form.query = "zo"
        #expect(form.shown == [zoe] && form.recipients(adding: false) == [zoe])
        form.query = ""
        form.toggle(alex)
        form.toggle(zoe)
        #expect(form.recipients(adding: false) == [alex, zoe])
        #expect(form.recipients(adding: true) == [sam, alex, zoe])
        #expect(PanelViewModel.sentText(to: ["sam"]) == "Sent to sam")
        #expect(PanelViewModel.sentText(to: ["sam", "alex"]) == "Sent to sam and alex")
        #expect(PanelViewModel.sentText(to: ["a", "b", "c"]) == "Sent to 3 contacts")
    }

    @Test func codesAndUsernamesAreToldApart() {
        #expect(AddContactState.isCode(SyncCrypto.Invite.format(SyncCrypto.Invite.newCode())))
        #expect(!AddContactState.isCode("userbob"))
    }
}

@MainActor
struct ContactsPanelTests {
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

    private func contacts() -> (SyncContact, SyncContact) {
        (SyncContact(id: "contact-sam-\(UUID())", name: "sam", uid: "u-sam"),
         SyncContact(id: "contact-alex-\(UUID())", name: "alex", uid: "u-alex"))
    }

    @Test func inboxAndPeopleSwitchLikeTheGroupPill() {
        let (sam, alex) = contacts()
        let request = ContactRequest(spaceId: "req-\(UUID())", uid: "u-pat", username: "pat", name: "pat", createdAt: 1)
        env.sync.setUpForTesting(groups: [], uid: "me", authors: [:], contacts: [sam, alex],
                                 requests: ContactRequests(incoming: [request]))
        defer { env.sync.tearDownTesting() }
        model.groupFilter = nil
        model.contactsShowPeople = false
        model.filter = .all

        // Contacts shows while signed in; ⇥ walks Inbox, then People.
        #expect(model.filterStops.prefix(5) == [.chip(.all), .chip(.labelled), .chip(.thisApp), .chip(.inbox), .people])
        model.select(.chip(.inbox))
        #expect(!model.showsPeople && model.arrivalPlaceShown == .inbox)
        #expect(model.handleKeyDown(key(KeyCode.tab, "\t")))
        #expect(model.currentStop == .people && model.showsPeople && model.arrivalPlaceShown == nil)
        #expect(model.entries.isEmpty)
        #expect(model.people.first?.id == "in-" + request.spaceId)
        #expect(model.peopleSelectionID == "in-" + request.spaceId)

        // ↓ moves through People; the search filters it.
        #expect(model.handleKeyDown(key(KeyCode.downArrow)))
        #expect(model.selectedPerson?.contact != nil)
        model.query = "alx"
        #expect(model.people.map(\.name) == ["alex"])
        model.query = ""

        // Remove asks inline first; esc takes it back.
        model.peopleSelectionID = "p-" + sam.id
        #expect(model.handleKeyDown(key(KeyCode.delete, "\u{7f}")))
        #expect(model.pendingRemoveContactID == sam.id)
        #expect(model.handleKeyDown(key(KeyCode.escape, "\u{1b}")))
        #expect(model.pendingRemoveContactID == nil)

        // Return on a contact: Send…, as in Add Items.
        #expect(model.handleKeyDown(key(KeyCode.returnKey, "\r")))
        #expect(model.mode == .addItems && model.addItemsForm?.contact == sam)
        model.resetMode()

        // A notification click opens People with the request selected, or the Inbox.
        model.select(.chip(.all))
        model.reveal(.people(requestSpaceId: request.spaceId))
        #expect(model.showsPeople && model.peopleSelectionID == "in-" + request.spaceId)
        model.reveal(.inbox(entryID: nil))
        #expect(model.filter == .inbox && !model.showsPeople)
        model.select(.chip(.all))
    }

    @Test func sendToOneContactAndToSeveral() {
        let (sam, alex) = contacts()
        env.sync.setUpForTesting(groups: [], uid: "me", authors: [:], contacts: [sam, alex])
        let item = env.store.ingest(.text("send me \(UUID())"))
        defer {
            env.sync.tearDownTesting()
            for space in [sam.id, alex.id] { env.store.items(inSpace: space).forEach(env.store.delete) }
            env.store.delete(item)
        }
        // ⌘K offers Send to Contact… and the recent ones directly.
        model.query = item.text
        model.refresh(resetSelection: true)
        #expect(model.availableActions.contains(.chooseContact))
        #expect(model.availableActions.contains(.sendToContact(sam)) && model.availableActions.contains(.sendToContact(alex)))

        model.beginContactPicker(entries: [.clip(item)])
        let form = try? #require(model.contactPicker)
        #expect(model.mode == .contactPicker && form?.contacts.count == 2)
        form?.query = "sam"
        #expect(model.handleKeyDown(key(KeyCode.returnKey, "\r")))
        #expect(model.mode == .browse)
        #expect(env.store.items(inSpace: sam.id).map(\.text) == [item.text])
        #expect(model.notice == "Sent to sam")

        // Several: tick, then ⌘↩ adds the highlighted one too.
        let other = env.store.ingest(.text("for both \(UUID())"))
        defer { env.store.delete(other) }
        model.beginContactPicker(entries: [.clip(other)])
        let both = try? #require(model.contactPicker)
        both?.selection = both?.contacts.firstIndex(of: alex) ?? 0
        #expect(model.handleKeyDown(key(KeyCode.space, " ")))
        both?.selection = both?.contacts.firstIndex(of: sam) ?? 0
        #expect(model.handleKeyDown(key(KeyCode.returnKey, "\r", flags: .command)))
        #expect(env.store.items(inSpace: sam.id).contains { $0.text == other.text })
        #expect(env.store.items(inSpace: alex.id).contains { $0.text == other.text })
        #expect(model.notice?.hasPrefix("Sent to ") == true && model.notice?.contains(" and ") == true)
    }

    @Test func whatCantBeSent() {
        let (sam, _) = contacts()
        env.sync.setUpForTesting(groups: [], uid: "me", authors: [:], contacts: [sam])
        // Something sam sent: it goes no further.
        let received = env.store.ingest(.text("from sam \(UUID())"), spaceID: sam.id)
        env.sync.setUpForTesting(groups: [], uid: "me", authors: [received.id.uuidString: "u-sam"], contacts: [sam])
        defer {
            env.sync.tearDownTesting()
            env.store.delete(received)
        }
        #expect(!model.canSendToContact(received))
        #expect(model.contactItems(for: [.clip(received)]).clips.isEmpty)
        model.beginContactPicker(entries: [.clip(received)])
        #expect(model.mode != .contactPicker)
    }

    @Test func aFolderSendsItsWholeSubtree() {
        let (sam, _) = contacts()
        env.sync.setUpForTesting(groups: [], uid: "me", authors: [:], contacts: [sam])
        let top = env.store.createFolder(named: "Top \(UUID())", inSpace: nil)
        let inner = env.store.createFolder(named: "Inner", inSpace: nil, parent: top)
        let a = env.store.ingest(.text("in top \(UUID())")), b = env.store.ingest(.text("in inner \(UUID())"))
        let outside = env.store.ingest(.text("not in it \(UUID())"))
        env.store.addToSaved([a, b, outside])
        env.store.move([a], to: top)
        env.store.move([b], to: inner)
        defer {
            env.sync.tearDownTesting()
            [a, b, outside].forEach(env.store.delete)
            env.store.deleteFolder(inner)
            env.store.deleteFolder(top)
        }
        let items = model.contactItems(for: [.folder(top)])
        #expect(Set(items.clips.map(\.id)) == [a.id, b.id])
        model.beginContactPicker(entries: [.folder(top)])
        #expect(model.contactPicker?.count == 2)
        model.resetMode()
    }

    @Test func aSecretNeedsTouchIDFirst() async throws {
        let (sam, _) = contacts()
        let ref = try #require(SecretVault.add(name: "Clipboard2 contact test", value: "hunter2"))
        defer { SecretVault.delete(id: ref.id) }
        env.sync.setUpForTesting(groups: [], uid: "me", authors: [:], contacts: [sam])
        defer { env.sync.tearDownTesting() }

        var asked: [String] = []
        model.authenticateSecrets = { reason in asked.append(reason); return false }
        model.beginContactPicker(entries: [.secret(ref)])
        for _ in 0..<50 where asked.isEmpty { await Task.yield() }
        #expect(asked == ["send “Clipboard2 contact test” to a contact"])
        #expect(model.mode != .contactPicker)

        model.authenticateSecrets = { _ in true }
        model.beginContactPicker(entries: [.secret(ref)])
        for _ in 0..<50 where model.mode != .contactPicker { await Task.yield() }
        #expect(model.mode == .contactPicker)
        #expect(model.contactPicker?.secrets.map(\.value) == ["hunter2"])
        model.resetMode()
    }
}
