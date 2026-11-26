import Foundation

// Offering to save new logins (docs/features/auth-autofill.md → Saving logins): the pure parts —
// which site a login is for, whether to offer Save or Update, when a login counts as submitted,
// and a password value that is wiped once the offer is gone. The Accessibility, pasteboard and
// toast side lives in LoginSaveWatcher.swift.

// MARK: - Sites

/// Where a login belongs: a web page's source domain, or an app when there's no page.
nonisolated enum LoginSite: Hashable, Sendable {
    case web(domain: String)
    case app(bundleID: String, name: String)

    /// What "Never for this site" remembers.
    var key: String {
        switch self {
        case .web(let domain): domain
        case .app(let bundleID, _): "app:\(bundleID)"
        }
    }

    /// "github.com", or the app's name.
    var title: String {
        switch self {
        case .web(let domain): domain
        case .app(_, let name): name
        }
    }

    /// The sites a saved password gets (apps: none; the password is named after the app).
    var urls: [String] {
        if case .web(let domain) = self { return [domain] }
        return []
    }

    /// A saved password is for this site: one of its sites has the domain; for an app, it has no
    /// sites and is named after the app.
    func matches(_ ref: SecretRef, list: PublicSuffixList = .shared) -> Bool {
        switch self {
        case .web(let domain):
            return SiteMatch.matches(ref, domain: domain, list: list)
        case .app(_, let name):
            return ref.urls.isEmpty && ref.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }
}

/// A site the user picked "Never for this site" for.
nonisolated struct NeverSaveSite: Codable, Hashable, Identifiable, Sendable {
    var key: String
    var title: String
    var id: String { key }

    init(_ site: LoginSite) {
        key = site.key
        title = site.title
    }

    init(key: String, title: String) {
        self.key = key
        self.title = title
    }
}

// MARK: - The captured value

/// A password Clipboard2 saw being pasted or filled, kept only as bytes that are overwritten with
/// zeros as soon as the offer is answered, times out or is dropped. (Strings made from it for
/// comparing or saving are short-lived copies; this is the one long-lived copy.)
nonisolated final class SensitiveValue: @unchecked Sendable {
    private var bytes: [UInt8]
    /// Characters and UTF-16 units, for comparing with a password field's length.
    private(set) var characterCount: Int
    private(set) var utf16Count: Int

    init(_ value: String) {
        bytes = Array(value.utf8)
        characterCount = value.count
        utf16Count = value.utf16.count
    }

    var isZeroed: Bool { bytes.isEmpty }

    /// The value, for saving it. Nil once zeroed.
    var string: String? { bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }

    /// A field this long can hold the value (it wasn't typed into since).
    func fits(length: Int) -> Bool { length == characterCount || length == utf16Count }

    func equals(_ other: String) -> Bool {
        guard !bytes.isEmpty else { return false }
        let utf8 = Array(other.utf8)
        guard utf8.count == bytes.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(utf8, bytes) { difference |= a ^ b }
        return difference == 0
    }

    /// Overwrites the bytes, then lets them go.
    func zero() {
        for index in bytes.indices { bytes[index] = 0 }
        bytes.removeAll()
        characterCount = 0
        utf16Count = 0
    }

    deinit { zero() }
}

// MARK: - Save or update

/// A saved password for the login's site.
nonisolated struct SavedLoginRef: Equatable, Sendable {
    var id: String
    var username: String?
}

nonisolated enum SaveOfferDecision: Equatable, Sendable {
    /// "Save password for ‹site›?"
    case save
    /// "Update password for ‹site›?": that password has the same username and another value.
    case update(id: String)
    case skip(SkipReason)

    enum SkipReason: Equatable, Sendable {
        case disabled, neverForSite, sameAsSaved, alreadySaved
    }
}

nonisolated enum SaveOfferPolicy {
    /// - `saved`: the site's saved passwords; `sameValue` says whether one holds the captured value.
    /// - `alreadySaved`: the value came from Fill or Suggest Strong Password, which save it themselves.
    /// - `knownSecret`: the value is a saved secret's (pasted from Auth): nothing new to save.
    static func decide(site: LoginSite, username: String?, saved: [SavedLoginRef], sameValue: (String) -> Bool,
                       enabled: Bool, neverSites: Set<String>, alreadySaved: Bool = false,
                       knownSecret: Bool = false) -> SaveOfferDecision {
        guard enabled else { return .skip(.disabled) }
        if alreadySaved { return .skip(.alreadySaved) }
        if neverSites.contains(site.key) { return .skip(.neverForSite) }
        // Any of the site's passwords already holding it: nothing to do.
        if saved.contains(where: { sameValue($0.id) }) { return .skip(.sameAsSaved) }
        let user = normalized(username)
        if let match = saved.first(where: { normalized($0.username) == user }) { return .update(id: match.id) }
        // Username unknown (it was on an earlier page) and the site has one password: that one.
        if user.isEmpty, saved.count == 1 { return .update(id: saved[0].id) }
        if knownSecret { return .skip(.alreadySaved) }
        return .save
    }

    private static func normalized(_ username: String?) -> String {
        SecretExtras.cleanUsername(username)?.lowercased() ?? ""
    }
}

// MARK: - Submitting

/// Decides when a login was submitted: Return in the form, the password field losing focus to a
/// button or the page (not to another text field or another app), or the page or window title
/// changing within ten seconds of the password field being used.
nonisolated struct SubmitDetector: Sendable {
    static let pageChangeWindow: TimeInterval = 10

    /// Where focus went when it left the password field.
    enum FocusTarget: Equatable, Sendable {
        case textField, button, page, otherApp
    }

    enum Event: Equatable, Sendable {
        case returnKey
        case focusLeft(to: FocusTarget)
        /// The password field was focused or changed again.
        case secureActivity
        /// The page URL and window title, as one string (nil: unknown).
        case page(String?)
    }

    private(set) var lastSecureActivity: Date
    private(set) var baseline: String?

    init(page: String?, at now: Date) {
        baseline = page
        lastSecureActivity = now
    }

    /// True: the login was submitted.
    mutating func handle(_ event: Event, at now: Date) -> Bool {
        switch event {
        case .returnKey:
            return true
        case .focusLeft(let target):
            switch target {
            case .button, .page: return true
            case .textField:
                lastSecureActivity = now
                return false
            case .otherApp:
                return false
            }
        case .secureActivity:
            lastSecureActivity = now
            return false
        case .page(let page):
            guard let page else { return false }
            guard let baseline else {
                self.baseline = page
                return false
            }
            guard page != baseline else { return false }
            self.baseline = page
            return now.timeIntervalSince(lastSecureActivity) <= Self.pageChangeWindow
        }
    }
}

// MARK: - The offer

/// What the toast says.
nonisolated struct SaveOffer: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case save, update }
    var kind: Kind
    var site: LoginSite
    var username: String?

    var title: String {
        kind == .save ? "Save password for \(site.title)?" : "Update password for \(site.title)?"
    }

    var detail: String { username ?? "No username" }
}

nonisolated enum SaveOfferResponse: Equatable, Sendable {
    case save, notNow, never, timedOut
}

/// Reads and writes saved passwords for the offer (SecretStore in the app). Reading values needs
/// no Touch ID: they're compared, never shown.
@MainActor
protocol LoginSaveStore: AnyObject {
    func savedLogins(for site: LoginSite) -> [SavedLoginRef]
    func hasValue(_ value: SensitiveValue, id: String) -> Bool
    func isKnownSecret(_ value: SensitiveValue) -> Bool
    func saveLogin(site: LoginSite, username: String?, value: String) -> Bool
    func updateLogin(id: String, value: String) -> Bool
}

/// Shows the offer (a toast in the app); `respond` gets the button, or `.timedOut` after 20 s.
@MainActor
protocol SaveOfferPresenting: AnyObject {
    func present(_ offer: SaveOffer, respond: @escaping (SaveOfferResponse) -> Void)
    func dismiss()
}

/// Keeps one captured login until it's submitted, then offers to save it. The captured value is
/// zeroed when the offer is answered or times out, when it's replaced, and when nothing is
/// submitted within `pendingLifetime`.
@MainActor
final class LoginSaveCoordinator {
    static let pendingLifetime: TimeInterval = 120
    static let offerDuration: Duration = .seconds(20)

    struct Pending {
        let value: SensitiveValue
        var site: LoginSite
        var username: String?
        var alreadySaved: Bool
        var detector: SubmitDetector
        let capturedAt: Date
        /// The field it was pasted into (live side only).
        var fieldID: AnyHashable?
    }

    private let store: any LoginSaveStore
    private let presenter: any SaveOfferPresenting
    var isEnabled: () -> Bool
    var neverSites: () -> Set<String>
    var addNeverSite: (LoginSite) -> Void

    private(set) var pending: Pending?
    /// The value behind the offer on screen.
    private(set) var offered: SensitiveValue?
    /// The last decision (tests, logs).
    private(set) var lastDecision: SaveOfferDecision?
    /// What the last answer did ("Saved", "Updated"), for a HUD.
    var onResult: (String) -> Void = { _ in }

    init(store: any LoginSaveStore, presenter: any SaveOfferPresenting,
         isEnabled: @escaping () -> Bool = { true }, neverSites: @escaping () -> Set<String> = { [] },
         addNeverSite: @escaping (LoginSite) -> Void = { _ in }) {
        self.store = store
        self.presenter = presenter
        self.isEnabled = isEnabled
        self.neverSites = neverSites
        self.addNeverSite = addNeverSite
    }

    /// A password went into a password field (pasted, filled or generated).
    func captured(_ value: String, site: LoginSite, username: String?, alreadySaved: Bool = false,
                  page: String?, fieldID: AnyHashable? = nil, at now: Date = .now) {
        guard isEnabled(), !value.isEmpty else { return }
        drop()
        pending = Pending(value: SensitiveValue(value), site: site, username: SecretExtras.cleanUsername(username),
                          alreadySaved: alreadySaved, detector: SubmitDetector(page: page, at: now),
                          capturedAt: now, fieldID: fieldID)
    }

    /// The username above the field, read again (it may have been typed after the paste).
    func updateUsername(_ username: String?) {
        guard let username = SecretExtras.cleanUsername(username) else { return }
        pending?.username = username
    }

    /// Something happened around the login; offers to save it once it was submitted.
    func handle(_ event: SubmitDetector.Event, at now: Date = .now) {
        guard var current = pending else { return }
        if now.timeIntervalSince(current.capturedAt) > Self.pendingLifetime {
            drop()
            return
        }
        let submitted = current.detector.handle(event, at: now)
        pending = current
        if submitted { submit() }
    }

    /// The password field now holds something else (typed into after the paste): the value is no
    /// longer known.
    func invalidate() { drop() }

    /// Drops a capture nobody submitted.
    func expire(at now: Date = .now) {
        if let pending, now.timeIntervalSince(pending.capturedAt) > Self.pendingLifetime { drop() }
    }

    /// Zeroes and forgets the pending capture.
    func drop() {
        pending?.value.zero()
        pending = nil
    }

    private func submit() {
        guard let current = pending else { return }
        pending = nil
        let value = current.value
        let saved = store.savedLogins(for: current.site)
        let decision = SaveOfferPolicy.decide(
            site: current.site, username: current.username, saved: saved,
            sameValue: { [store] id in store.hasValue(value, id: id) },
            enabled: isEnabled(), neverSites: neverSites(), alreadySaved: current.alreadySaved,
            knownSecret: store.isKnownSecret(value))
        lastDecision = decision
        let kind: SaveOffer.Kind
        var updateID: String?
        switch decision {
        case .skip:
            value.zero()
            return
        case .save:
            kind = .save
        case .update(let id):
            kind = .update
            updateID = id
        }
        // One offer at a time: a newer one replaces it.
        if let offered { offered.zero() }
        presenter.dismiss()
        offered = value
        let offer = SaveOffer(kind: kind, site: current.site, username: current.username)
        presenter.present(offer) { [weak self] response in
            self?.respond(response, offer: offer, value: value, updateID: updateID)
        }
    }

    private func respond(_ response: SaveOfferResponse, offer: SaveOffer, value: SensitiveValue, updateID: String?) {
        defer {
            value.zero()
            if offered === value { offered = nil }
        }
        switch response {
        case .save:
            guard let string = value.string else { return }
            if let updateID {
                onResult(store.updateLogin(id: updateID, value: string) ? "Updated the password for \(offer.site.title)"
                                                                        : "Couldn't update the password")
            } else {
                onResult(store.saveLogin(site: offer.site, username: offer.username, value: string)
                         ? "Saved a password for \(offer.site.title)" : "Couldn't save the password")
            }
        case .never:
            addNeverSite(offer.site)
        case .notNow, .timedOut:
            break
        }
    }
}
