import AppKit
import Observation

// Auth's sources (docs/features/auth-autofill.md → Sources): passwords, secrets and authenticators
// grouped by the site they're for, its registrable domain.

// The public suffix list, `AuthSource` and `IssuerDomains` are in Core/Auth/AuthSourcesCore.swift.

nonisolated extension AuthSource {
    /// A password's or secret's source: its first site's domain. Nil: "No website".
    static func of(_ ref: SecretRef, list: PublicSuffixList = .shared) -> AuthSource? {
        domains(ofSites: ref.urls, list: list).first.map(AuthSource.domain)
    }

    /// An authenticator's source: the site set with Edit → Website, else the issuer mapped to a
    /// domain, else the issuer itself. Nil (no issuer either): "No website".
    static func of(_ item: AuthenticatorItem, list: PublicSuffixList = .shared) -> AuthSource? {
        if let domain = domains(ofSites: item.urls, list: list).first { return .domain(domain) }
        let issuer = item.issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !issuer.isEmpty else { return nil }
        if let domain = IssuerDomains.domain(for: issuer, list: list) { return .domain(domain) }
        return .issuer(issuer)
    }
}

/// One source and its items, in list order.
nonisolated struct AuthSourceGroup<Item> {
    /// Nil is "No website" (unless it's an origin's group).
    var source: AuthSource?
    var items: [Item]
    /// The origin these are filed under (an origin edited by hand); its domain is `source`.
    var origin: AuthOrigin? = nil

    var title: String { origin?.title ?? source?.name ?? "No website" }

    var key: AuthGroupKey { origin.map { .origin($0.id) } ?? AuthGroupKey(source) }
}

/// A source row above its items in Auth.
nonisolated struct AuthSourceHeading: Hashable, Sendable {
    /// Nil is "No website".
    var source: AuthSource?
    /// "For ‹site›": the page the panel opened over (phase 2).
    var isSuggestion = false
    /// The origin edited by hand these items are filed under.
    var origin: AuthOrigin? = nil

    var title: String {
        if isSuggestion, let source { return "For \(source.name)" }
        return origin?.title ?? source?.name ?? "No website"
    }

    /// What selecting the heading opens (nil for "For ‹site›").
    var key: AuthGroupKey? {
        if isSuggestion { return nil }
        return origin.map { .origin($0.id) } ?? AuthGroupKey(source)
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

/// When each source was last used (pasted or copied from), so Auth lists it first. Source keys
/// and times only.
@MainActor
final class AuthSourceUsage {
    static let shared = AuthSourceUsage()
    private let defaults: UserDefaults
    private let key = "authSourceLastUsed"
    private(set) var lastUsed: [String: Date]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        lastUsed = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func record(_ source: AuthSource?, at date: Date = .now) {
        guard let source else { return }
        record(key: source.key, at: date)
    }

    /// A group's usage key (`AuthGroupKey.usageKey`): a source's key or `origin:<id>`.
    func record(key groupKey: String, at date: Date = .now) {
        guard !groupKey.isEmpty else { return }
        lastUsed[groupKey] = date
        defaults.set(lastUsed.mapValues(\.timeIntervalSince1970), forKey: key)
    }
}

// MARK: - Favicons

/// Each source's favicon, fetched once (`https://<domain>/favicon.ico`, else DuckDuckGo's icon
/// service) and cached on disk. Never blocks: until it's there, or when there's none, the row
/// shows the source's first letter.
@MainActor
@Observable
final class FaviconCache {
    static let shared = FaviconCache()

    private var images: [String: NSImage] = [:]
    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private let directory: URL
    /// A failed fetch is retried after this long.
    nonisolated static let retryAfter: TimeInterval = 7 * 24 * 3600

    init(directory: URL = AppPaths.supportDirectory.appending(path: "Favicons", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func image(for domain: String) -> NSImage? {
        if let image = images[domain] { return image }
        load(domain)
        return nil
    }

    private func load(_ domain: String) {
        guard attempted.insert(domain).inserted, Self.isFetchable(domain) else { return }
        let file = directory.appending(path: domain + ".ico")
        let miss = directory.appending(path: domain + ".miss")
        let directory = self.directory
        Task { [weak self] in
            let data = await Self.cachedOrFetched(domain: domain, file: file, miss: miss, directory: directory)
            guard let data, let image = NSImage(data: data), image.isValid else { return }
            self?.images[domain] = image
        }
    }

    /// A plain domain name only, so nothing odd ends up in a URL or a file name.
    nonisolated static func isFetchable(_ domain: String) -> Bool {
        domain.contains(".") && domain.count <= 253
            && domain.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
            && !domain.allSatisfy { $0.isNumber || $0 == "." }
    }

    @concurrent
    nonisolated private static func cachedOrFetched(domain: String, file: URL, miss: URL, directory: URL) async -> Data? {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: file) { return data }
        if let attributes = try? fm.attributesOfItem(atPath: miss.path), let date = attributes[.modificationDate] as? Date,
           Date.now.timeIntervalSince(date) < retryAfter { return nil }
        let sources = ["https://\(domain)/favicon.ico", "https://icons.duckduckgo.com/ip3/\(domain).ico"]
        let session = URLSession(configuration: .ephemeral)
        for source in sources {
            guard let url = URL(string: source) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count > 0, data.count < 512 * 1024,
                  NSImage(data: data)?.isValid == true else { continue }
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return data
        }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data().write(to: miss, options: .atomic)
        return nil
    }
}
