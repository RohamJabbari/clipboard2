import Foundation

// The Mac keeps its own versions of these (Clipboard2/Services/AuthSources.swift): there a group can
// also be an origin edited by hand, which the iOS app doesn't have yet.

/// One source and its items, in list order.
nonisolated struct AuthSourceGroup<Item> {
    /// Nil is "No website".
    var source: AuthSource?
    var items: [Item]

    var title: String { source?.name ?? "No website" }
}

/// A source row above its items in Auth.
nonisolated struct AuthSourceHeading: Hashable, Sendable {
    /// Nil is "No website".
    var source: AuthSource?
    /// "For ‹site›": the page the panel opened over (phase 2).
    var isSuggestion = false
    var title: String {
        if isSuggestion, let source { return "For \(source.name)" }
        return source?.name ?? "No website"
    }
}

nonisolated enum AuthSourceGrouping {
    /// Items grouped by source: the most recently used source first, then the others by name;
    /// "No website" last. Items within a source by title.
    static func group<Item>(_ items: [Item], source: (Item) -> AuthSource?, title: (Item) -> String,
                                      lastUsed: [String: Date]) -> [AuthSourceGroup<Item>] {
        var bySource: [AuthSource: [Item]] = [:]
        var none: [Item] = []
        for item in items {
            if let source = source(item) { bySource[source, default: []].append(item) } else { none.append(item) }
        }
        func byTitle(_ a: Item, _ b: Item) -> Bool { title(a).localizedStandardCompare(title(b)) == .orderedAscending }
        var groups = bySource.keys.sorted { a, b in
            let ua = lastUsed[a.key], ub = lastUsed[b.key]
            switch (ua, ub) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a < b
            }
        }.map { AuthSourceGroup(source: $0, items: bySource[$0, default: []].sorted(by: byTitle)) }
        if !none.isEmpty { groups.append(AuthSourceGroup(source: nil, items: none.sorted(by: byTitle))) }
        return groups
    }
}
