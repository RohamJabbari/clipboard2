import Foundation

// Notifications (docs/features/notifications-contacts.md): everything is found by comparing what
// each sync brings with what was known before. This file is the pure part: snapshots, the diff
// that turns two of them into events, and the rules that decide how an event is delivered.

/// The four switches in Settings → Sync → Notifications.
nonisolated enum NotificationKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case groupActivity, groupMembers, contacts, authenticators
    var id: String { rawValue }

    var title: String {
        switch self {
        case .groupActivity: "Group activity"
        case .groupMembers: "Group members"
        case .contacts: "Contacts"
        case .authenticators: "Authenticators"
        }
    }

    var summary: String {
        switch self {
        case .groupActivity: "New items in your groups, and renamed groups."
        case .groupMembers: "People joining or leaving your groups."
        case .contacts: "Contact requests, new contacts and what they send you."
        case .authenticators: "Authenticators shared with you or handed over to you."
        }
    }
}

/// Where clicking a notification takes you (always the quick panel).
nonisolated enum NotificationTarget: Codable, Equatable, Hashable, Sendable {
    /// A group's list.
    case group(String)
    /// A group item, selected: in Copies, or in Saved for secrets and snippets.
    case groupItem(spaceId: String, entryID: String, saved: Bool)
    /// Contacts → People, with this request (if any) on top and selected.
    case people(requestSpaceId: String?)
    /// Contacts → Inbox, with this entry (if any) selected.
    case inbox(entryID: String?)
    /// Saved, with this authenticator selected.
    case authenticator(spaceId: String)

    /// Round trip through a notification's `userInfo`.
    var encoded: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    init?(encoded: String) {
        guard let value = try? JSONDecoder().decode(NotificationTarget.self, from: Data(encoded.utf8)) else { return nil }
        self = value
    }
}

/// Where new items arrived, for "the panel is already showing it".
nonisolated enum ArrivalPlace: Equatable, Hashable, Sendable {
    case group(String)
    case inbox
}

/// One notification, before it's posted.
nonisolated struct AppNotification: Equatable, Sendable {
    var kind: NotificationKind
    var title: String
    var body: String
    var target: NotificationTarget?
    /// The group it's about (for per-group mute).
    var groupId: String? = nil
    /// New items there: no notification while the panel shows that place.
    var arrivalIn: ArrivalPlace? = nil
    /// The bubble shown instead when notifications are off or not allowed. Contacts only, as before.
    var hudText: String? = nil
    var hudSymbol = "tray.and.arrow.down.fill"
    /// Notifications of one thread are grouped by the system.
    var thread: String { groupId ?? kind.rawValue }
}

/// What notifications compare between syncs. Persisted, so changes while the Mac was off are noticed.
nonisolated struct NotificationSnapshot: Codable, Equatable, Sendable {
    nonisolated struct Group: Codable, Equatable, Sendable {
        var name: String
        var isOwner: Bool
        /// uid → name; empty when the server doesn't list members.
        var members: [String: String]
    }
    nonisolated struct Contact: Codable, Equatable, Sendable {
        var name: String
        /// You made the request or the code (they accepted or used it).
        var ownedByMe: Bool
    }
    nonisolated struct SharedCodes: Codable, Equatable, Sendable {
        var ownerName: String
        /// "" until the first batch could be opened.
        var issuer: String
    }

    var groups: [String: Group] = [:]
    var contacts: [String: Contact] = [:]
    /// Authenticators shared with you, by space id.
    var shared: [String: SharedCodes] = [:]
    /// Authenticator spaces you own, with their issuer.
    var owned: [String: String] = [:]
}

/// An item someone else put in a group or a contact's space, found by a pull.
nonisolated struct NotificationArrival: Equatable, Sendable {
    nonisolated enum What: Equatable, Sendable {
        case text(String)
        case labelled(String)
        case image
        case files([String])
        case secret
        case snippet(String)
    }
    /// The panel entry id ("c-…", "k-…", "s-…").
    var entryID: String
    var spaceId: String
    var authorUid: String
    var what: What
    /// Secrets and snippets live in a group's Saved, not its Copies.
    var isSaved: Bool { if case .secret = what { true } else if case .snippet = what { true } else { false } }
}

/// Changes this Mac made itself, so they're never announced back (other devices' are recognised
/// from who could have made them).
nonisolated struct OwnActions: Equatable, Sendable {
    /// Groups left or deleted here.
    var leftGroups: Set<String> = []
    /// "spaceId uid" of members removed here.
    var removedMembers: Set<String> = []
    /// Groups renamed here, with the new name.
    var renamedGroups: [String: String] = [:]

    static func member(_ uid: String, in spaceId: String) -> String { spaceId + " " + uid }

    /// What's still waiting for a sync to show it; the rest is done with.
    func pruned(by snapshot: NotificationSnapshot) -> OwnActions {
        var result = OwnActions()
        result.leftGroups = leftGroups.filter { snapshot.groups[$0] != nil }
        result.removedMembers = removedMembers.filter { key in
            let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return false }
            return snapshot.groups[parts[0]]?.members[parts[1]] != nil
        }
        result.renamedGroups = renamedGroups.filter { id, name in
            snapshot.groups[id].map { $0.name != name } ?? false
        }
        return result
    }
}

nonisolated enum NotificationDiff {
    /// Every event between two syncs. Nothing about your own actions: items you wrote (on any
    /// device), changes made here (`own`), and what only you could have done elsewhere (renaming
    /// or deleting a group you own).
    static func events(from old: NotificationSnapshot, to new: NotificationSnapshot, arrivals: [NotificationArrival],
                       me: String, own: OwnActions = OwnActions()) -> [AppNotification] {
        var events: [AppNotification] = []

        // Groups gone: you were removed, or it was deleted. Leaving here, or deleting one you own
        // (only the owner can), was you.
        for (id, group) in old.groups.sorted(by: { $0.key < $1.key }) where new.groups[id] == nil {
            guard !group.isOwner, !own.leftGroups.contains(id) else { continue }
            events.append(AppNotification(kind: .groupMembers, title: group.name, body: "You're no longer in this group",
                                          target: nil, groupId: id))
        }

        for (id, group) in new.groups.sorted(by: { $0.key < $1.key }) {
            guard let before = old.groups[id] else { continue }   // joined just now: that was you
            // Only the owner can rename.
            if before.name != group.name, !group.isOwner, own.renamedGroups[id] != group.name {
                events.append(AppNotification(kind: .groupActivity, title: group.name, body: "\(before.name) was renamed",
                                              target: .group(id), groupId: id))
            }
            // Servers that don't list members say nothing about who came or went.
            guard !before.members.isEmpty, !group.members.isEmpty else { continue }
            for (uid, name) in group.members.sorted(by: { $0.value < $1.value }) where before.members[uid] == nil && uid != me {
                events.append(AppNotification(kind: .groupMembers, title: group.name, body: "\(name) joined",
                                              target: .group(id), groupId: id))
            }
            for (uid, name) in before.members.sorted(by: { $0.value < $1.value }) where group.members[uid] == nil && uid != me {
                guard !own.removedMembers.contains(OwnActions.member(uid, in: id)) else { continue }
                events.append(AppNotification(kind: .groupMembers, title: group.name, body: "\(name) left",
                                              target: .group(id), groupId: id))
            }
        }

        // Items, batched per group and author, and per contact.
        let others = arrivals.filter { $0.authorUid != me }
        var groupBatches: [(key: String, items: [NotificationArrival])] = []
        var contactBatches: [(key: String, items: [NotificationArrival])] = []
        for arrival in others {
            if new.groups[arrival.spaceId] != nil {
                // Joining downloads what's already there: none of it is news.
                guard old.groups[arrival.spaceId] != nil else { continue }
                let key = arrival.spaceId + " " + arrival.authorUid
                if let index = groupBatches.firstIndex(where: { $0.key == key }) {
                    groupBatches[index].items.append(arrival)
                } else {
                    groupBatches.append((key, [arrival]))
                }
            } else if new.contacts[arrival.spaceId] != nil {
                if let index = contactBatches.firstIndex(where: { $0.key == arrival.spaceId }) {
                    contactBatches[index].items.append(arrival)
                } else {
                    contactBatches.append((arrival.spaceId, [arrival]))
                }
            }
        }
        for batch in groupBatches {
            let first = batch.items[0]
            guard let group = new.groups[first.spaceId] else { continue }
            let name = group.members[first.authorUid] ?? old.groups[first.spaceId]?.members[first.authorUid] ?? "Someone"
            let what = batch.items.count == 1 ? phrase(first.what) : "\(batch.items.count) items"
            events.append(AppNotification(kind: .groupActivity, title: group.name, body: "\(name) shared \(what)",
                                          target: .groupItem(spaceId: first.spaceId, entryID: first.entryID, saved: first.isSaved),
                                          groupId: first.spaceId, arrivalIn: .group(first.spaceId)))
        }

        // New contacts: a request you made was accepted, or someone used your code.
        for (id, contact) in new.contacts.sorted(by: { $0.value.name < $1.value.name })
        where old.contacts[id] == nil && contact.ownedByMe {
            events.append(AppNotification(kind: .contacts, title: contact.name, body: "is now your contact",
                                          target: .people(requestSpaceId: nil),
                                          hudText: "\(contact.name) is now your contact", hudSymbol: "person.crop.circle.badge.checkmark"))
        }
        for batch in contactBatches {
            let first = batch.items[0]
            guard let contact = new.contacts[first.spaceId] else { continue }
            let what = batch.items.count == 1 ? phrase(first.what) : "\(batch.items.count) items"
            events.append(AppNotification(kind: .contacts, title: contact.name, body: "sent \(what)",
                                          target: .inbox(entryID: first.entryID), arrivalIn: .inbox,
                                          hudText: "\(contact.name) sent you \(what)"))
        }

        // Authenticators: handed over to you, or shared with you (once its name is known).
        for (id, issuer) in new.owned.sorted(by: { $0.key < $1.key }) where old.owned[id] == nil {
            guard let before = old.shared[id] else { continue }   // made here or on your other devices
            let name = before.issuer.isEmpty ? (issuer.isEmpty ? "an authenticator" : issuer) : before.issuer
            events.append(AppNotification(kind: .authenticators, title: before.ownerName, body: "made you the owner of \(name)",
                                          target: .authenticator(spaceId: id)))
        }
        for (id, codes) in new.shared.sorted(by: { $0.key < $1.key }) where !codes.issuer.isEmpty {
            guard old.owned[id] == nil, old.shared[id]?.issuer.isEmpty ?? true else { continue }
            events.append(AppNotification(kind: .authenticators, title: codes.ownerName, body: "shared \(codes.issuer) codes with you",
                                          target: .authenticator(spaceId: id)))
        }
        return events
    }

    /// New incoming contact requests (already filtered to ones not seen before).
    static func requestEvents(_ requests: [ContactRequest]) -> [AppNotification] {
        requests.map {
            AppNotification(kind: .contacts, title: "Contact request", body: "\($0.name) wants to add you",
                            target: .people(requestSpaceId: $0.spaceId),
                            hudText: "\($0.name) wants to add you as a contact", hudSymbol: "person.crop.circle.badge.plus")
        }
    }

    /// The short preview in a body: never the content of a secret, and nothing that looks like a
    /// password or key.
    static func phrase(_ what: NotificationArrival.What) -> String {
        switch what {
        case .image: return "an image"
        case .secret: return "a secret"
        case .files(let names): return names.count == 1 ? "“\(names[0])”" : "\(names.count) files"
        case .labelled(let label): return "“\(shorten(label))”"
        case .snippet(let name): return "“\(shorten(name))”"
        case .text(let text):
            if SensitiveText.detect(text) != nil { return "some text" }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return line.isEmpty ? "some text" : "“\(shorten(line))”"
        }
    }

    private static func shorten(_ line: String) -> String {
        line.count > 40 ? line.prefix(39).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// What an item is, for the preview. Concealed items are only ever "an image".
    @MainActor static func what(of item: ClipItem) -> NotificationArrival.What {
        if item.isConcealed { return .image }
        if let label = item.label, !label.isEmpty { return .labelled(label) }
        switch item.kind {
        case .image: return .image
        case .file: return .files(item.fileURLs.map(\.lastPathComponent))
        case .text, .richText: return .text(item.preview.isEmpty ? item.text : item.preview)
        }
    }
}

/// How one event reaches the user.
nonisolated enum NotificationDelivery: Equatable, Sendable {
    case post
    case hud
    case drop
}

/// The user's choices (Settings → Sync → Notifications).
nonisolated struct NotificationSettings: Equatable, Sendable {
    var enabled = true
    var kinds: Set<NotificationKind> = Set(NotificationKind.allCases)
    var mutedGroups: Set<String> = []
}

nonisolated enum NotificationRules {
    /// `allowed`: the system permission (nil while not asked yet; asking happens on the first post).
    /// `showing`: what the open panel shows (nil when it's closed).
    static func delivery(of event: AppNotification, settings: NotificationSettings, allowed: Bool?,
                         showing: ArrivalPlace?) -> NotificationDelivery {
        if let place = event.arrivalIn, place == showing { return .drop }   // already in view
        if let group = event.groupId, settings.mutedGroups.contains(group) { return .drop }
        let fallback: NotificationDelivery = event.hudText != nil ? .hud : .drop
        guard settings.enabled else { return fallback }
        guard settings.kinds.contains(event.kind) else { return .drop }
        if allowed == false { return fallback }
        return .post
    }
}
