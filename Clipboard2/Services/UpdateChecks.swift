import Foundation

/// Quiet update checks: when they may run, what the quick panel footer shows, and which appcast
/// URL is fresh. Kept free of Sparkle so it's testable.

/// At most one quiet check per `interval` (panel opens come in bursts).
nonisolated struct UpdateCheckThrottle: Sendable {
    var interval: TimeInterval = 120
    private(set) var last: Date?

    func isDue(now: Date = .now) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    mutating func record(now: Date = .now) {
        last = now
    }
}

/// The quick panel footer's one update indicator: none → available → downloading → ready.
nonisolated enum UpdateIndicator: Equatable, Sendable {
    case none
    case available(version: String)
    case downloading
    case ready(version: String)

    init(_ phase: UpdateController.Phase) {
        switch phase {
        case .available(let version, _): self = .available(version: version)
        case .downloading, .preparing, .installing: self = .downloading
        case .ready(let version): self = .ready(version: version)
        case .idle, .checking, .upToDate, .failed: self = .none
        }
    }
}

extension UpdateController.Phase {
    /// The phase after a quiet probe: a found version (nil: none newer) is announced, but never over
    /// a download or a waiting restart, and a probe never reports anything while a check runs.
    nonisolated func afterProbe(found: (version: String, infoOnly: Bool)?) -> Self {
        switch self {
        case .idle, .upToDate, .failed, .available:
            guard let found else { return .upToDate }
            return .available(version: found.version, infoOnly: found.infoOnly)
        case .checking, .downloading, .preparing, .ready, .installing:
            return self
        }
    }
}

/// The appcast at a fresh address.
///
/// raw.githubusercontent.com sits behind Fastly with `max-age=300`, and Fastly ignores the query
/// string (checked with curl: `?t=<anything new>` is still an `x-cache: HIT` with the same
/// `source-age`), so a cache-busting query does nothing. A path pinned to a commit is a different
/// object that nobody has cached before, and it can never go stale. So: look up the branch's head
/// commit (GitHub API, conditional on the last ETag), then read `raw/<owner>/<repo>/<sha>/<path>`.
/// Sparkle already loads feeds with `NSURLRequestReloadIgnoringLocalCacheData`, so URLSession's
/// own cache isn't in the way.
nonisolated struct PinnedFeed: Equatable, Sendable {
    let owner: String
    let repo: String
    let branch: String
    let path: String

    /// Nil for anything that isn't `https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>`.
    init?(_ feed: URL) {
        guard feed.scheme == "https", feed.host() == "raw.githubusercontent.com" else { return nil }
        let parts = feed.path().split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return nil }
        owner = parts[0]
        repo = parts[1]
        branch = parts[2]
        path = parts[3...].joined(separator: "/")
    }

    /// Answers with just the commit's SHA (`application/vnd.github.sha`).
    var headCommitURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/commits/\(branch)")!
    }

    func url(at sha: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(sha)/\(path)")!
    }

    static func isSHA(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy(\.isHexDigit)
    }
}

/// Resolves the appcast's current commit just before a check, so the check reads a fresh copy.
/// Falls back to the plain feed (at most five minutes stale) when GitHub can't be asked.
final class FeedResolver {
    /// A pinned URL older than this is no better than the plain feed: use that instead.
    static let freshFor: TimeInterval = 120

    private let feed: PinnedFeed?
    private var apiURL: URL?
    private var etag: String?
    private var sha: String?
    private var resolvedAt: Date?

    init(feedURL: URL?) {
        feed = feedURL.flatMap(PinnedFeed.init)
        apiURL = feed?.headCommitURL
    }

    /// The feed for the check about to start, or nil for Sparkle's default (Info.plist).
    func feedURLString(now: Date = .now) -> String? {
        guard let feed, let sha, let resolvedAt, now.timeIntervalSince(resolvedAt) < Self.freshFor else { return nil }
        return feed.url(at: sha).absoluteString
    }

    func resolve() async {
        guard let apiURL else { return }
        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github.sha", forHTTPHeaderField: "Accept")
        // A 304 doesn't count against GitHub's hourly limit for anonymous requests.
        if let etag, sha != nil { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            // The repo was renamed once; remember where GitHub sent us to skip the redirect.
            if let final = http.url, final != apiURL { self.apiURL = final }
            switch http.statusCode {
            case 200:
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard PinnedFeed.isSHA(text) else { return }
                sha = text
                etag = http.value(forHTTPHeaderField: "ETag")
                resolvedAt = .now
            case 304:
                resolvedAt = .now
            default:
                Log.updates.notice("Feed commit lookup: HTTP \(http.statusCode)")
            }
        } catch {
            Log.updates.notice("Feed commit lookup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
