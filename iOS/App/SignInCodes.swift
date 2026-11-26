import Foundation
import Observation

/// A sign-in code from a text message (docs/features/ios.md → SMS codes). Like email codes on the
/// Mac: only the code, the site it's for, the sender and the time; never the message. Kept on this
/// device for 10 minutes, never synced.
nonisolated struct SignInCode: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var code: String
    var domain: String?
    var reason: SMSOriginMatcher.Reason?
    var sender: String?
    var receivedAt: Date

    static let lifetime: TimeInterval = 10 * 60

    var expiresAt: Date { receivedAt.addingTimeInterval(Self.lifetime) }
    func isLive(at now: Date) -> Bool { now < expiresAt && now >= receivedAt.addingTimeInterval(-60) }
}

/// When each site was last used in Auth (copied from), so a code with nothing else to go on can
/// be put under the site the user is signing in to. Domains and times only.
nonisolated enum RecentSites {
    static let window: TimeInterval = 10 * 60
    private static let key = "recentSites"

    static func record(_ domain: String?, at date: Date = .now, defaults: UserDefaults = SharedContainer.defaults) {
        guard let domain else { return }
        var all = lastUsed(defaults: defaults)
        all[domain] = date
        defaults.set(all.mapValues(\.timeIntervalSince1970), forKey: key)
    }

    static func lastUsed(defaults: UserDefaults = SharedContainer.defaults) -> [String: Date] {
        (defaults.dictionary(forKey: key) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// The site used last, if that was within the window.
    static func recent(now: Date = .now, defaults: UserDefaults = SharedContainer.defaults) -> String? {
        guard let (domain, date) = lastUsed(defaults: defaults).max(by: { $0.value < $1.value }),
              now.timeIntervalSince(date) <= window, date <= now.addingTimeInterval(60) else { return nil }
        return domain
    }
}

@Observable
final class SignInCodeStore {
    static let shared = SignInCodeStore()

    private(set) var codes: [SignInCode] = []
    private let keychain: KeychainJSON<[SignInCode]>?
    private let defaults: UserDefaults
    private static let sendersKey = "smsSenderOrigins"

    init(keychain: KeychainJSON<[SignInCode]>? = KeychainJSON(service: "at.softmaze.Clippy.ios.codes", account: "sms", shared: false),
         defaults: UserDefaults = SharedContainer.defaults) {
        self.keychain = keychain
        self.defaults = defaults
        reload()
    }

    /// Codes still valid; expired ones are deleted.
    func reload(now: Date = .now) {
        let stored = keychain?.read() ?? codes
        let live = stored.filter { $0.isLive(at: now) }
        codes = live.sorted { $0.receivedAt > $1.receivedAt }
        if live.count != stored.count { persist() }
    }

    /// Senders the user put under a site (`SMSOriginMatcher.senderKey` → domain).
    var learnedSenders: [String: String] {
        defaults.dictionary(forKey: Self.sendersKey) as? [String: String] ?? [:]
    }

    /// Reads a message; saves and returns its code, or nil when there's none.
    @discardableResult
    func save(message: String, sender: String?, now: Date = .now) -> SignInCode? {
        guard let result = SMSCodeExtractor.extract(message) else { return nil }
        let context = SMSOriginContext(learnedSenders: learnedSenders, recentDomain: RecentSites.recent(now: now, defaults: defaults))
        let match = SMSOriginMatcher.match(message: message, sender: sender, boundDomain: result.boundDomain, context: context)
        let trimmedSender = sender?.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = SignInCode(code: result.code, domain: match?.domain, reason: match?.reason,
                              sender: trimmedSender?.isEmpty == false ? trimmedSender : nil, receivedAt: now)
        reload(now: now)
        // The same code again (a resent message, or the automation running twice): one entry.
        codes.removeAll { $0.code == code.code && $0.domain == code.domain }
        codes.insert(code, at: 0)
        persist()
        return code
    }

    /// The user says which site a code is for; its sender is remembered for next time.
    func assign(_ id: SignInCode.ID, to domain: String) {
        guard let index = codes.firstIndex(where: { $0.id == id }),
              let normalized = AuthSource.domain(ofSite: domain) else { return }
        codes[index].domain = normalized
        codes[index].reason = .learnedSender
        if let sender = codes[index].sender {
            var senders = learnedSenders
            senders[SMSOriginMatcher.senderKey(sender)] = normalized
            defaults.set(senders, forKey: Self.sendersKey)
        }
        persist()
    }

    func remove(_ id: SignInCode.ID) {
        codes.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if codes.isEmpty { keychain?.delete() } else { keychain?.write(codes) }
    }
}
