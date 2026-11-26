import Foundation

// What the app tells the AutoFill extension (docs/features/auth-autofill.md → Phase 3), through
// the shared Keychain. Compiled into both targets; Foundation and TOTP.swift only.

/// One thing the extension can offer: a password, an authenticator, a code shared with you, or an
/// email code. Names, usernames and domains only: values are read from the Keychain on use.
nonisolated struct AutoFillEntry: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case password
        /// One you own: the seed is in `KeychainServices.authenticators`.
        case authenticator
        /// Shared with you: pre-computed codes in `KeychainServices.sharedCodes`.
        case sharedCode
        /// Phase 4: in `KeychainServices.autofillEmailCodes`.
        case emailCode
    }

    var kind: Kind
    /// The Keychain account: secret id, authenticator id, share space id, email code id.
    var itemID: String
    /// The password's name, or the code's issuer or source.
    var title: String
    /// The username, or the authenticator's account.
    var user: String
    /// Registrable domains (`google.com`), the first one is its source. Empty: offered only in the
    /// list, never suggested.
    var domains: [String]

    /// The credential identity's record identifier.
    var id: String { kind.rawValue + ":" + itemID }
    var isCode: Bool { kind != .password }

    init(kind: Kind, itemID: String, title: String, user: String, domains: [String]) {
        self.kind = kind
        self.itemID = itemID
        self.title = title
        self.user = user
        self.domains = domains
    }

    /// The other way round: `kind:itemID`.
    init?(recordIdentifier: String?, in entries: [AutoFillEntry]) {
        guard let recordIdentifier, let match = entries.first(where: { $0.id == recordIdentifier }) else { return nil }
        self = match
    }

    /// `Google (me@gmail.com)`, the label of a one-time-code identity.
    var label: String {
        let user = user.trimmingCharacters(in: .whitespaces)
        return user.isEmpty || user == title ? title : "\(title) (\(user))"
    }
}

/// An email code (phase 4): `AutoFillIdentities.update(codes:)` hands these to the extension.
nonisolated struct AutoFillEmailCode: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var code: String
    /// The sender's registrable domain (`google.com`).
    var domain: String
    var receivedAt: Date

    static let lifetime: TimeInterval = 10 * 60

    init(id: String, code: String, domain: String, receivedAt: Date) {
        self.id = id
        self.code = code
        self.domain = domain
        self.receivedAt = receivedAt
    }

    func isFresh(at now: Date) -> Bool { now.timeIntervalSince(receivedAt) < Self.lifetime && receivedAt <= now.addingTimeInterval(60) }
}

// MARK: - Building the list

nonisolated enum AutoFillIndex {
    struct Password: Sendable {
        var id: String
        var name: String
        var username: String?
        var domains: [String]
    }

    struct Code: Sendable {
        var kind: AutoFillEntry.Kind
        var id: String
        var title: String
        var user: String
        var domains: [String]
    }

    /// Every password and code, by title; codes after passwords with the same title.
    static func build(passwords: [Password], codes: [Code]) -> [AutoFillEntry] {
        let entries = passwords.map {
            AutoFillEntry(kind: .password, itemID: $0.id, title: $0.name, user: $0.username ?? "", domains: unique($0.domains))
        } + codes.map {
            AutoFillEntry(kind: $0.kind, itemID: $0.id, title: $0.title, user: $0.user, domains: unique($0.domains))
        }
        return entries.sorted { a, b in
            let order = a.title.localizedStandardCompare(b.title)
            if order != .orderedSame { return order == .orderedAscending }
            if a.isCode != b.isCode { return !a.isCode }
            if a.user != b.user { return a.user.localizedStandardCompare(b.user) == .orderedAscending }
            return a.id < b.id
        }
    }

    /// A password identity per domain (site + username) and a one-time-code identity per domain.
    struct Identity: Hashable, Sendable {
        var domain: String
        /// The username (passwords) or the label (codes).
        var user: String
        var recordIdentifier: String
        var isCode: Bool
    }

    static func identities(for entries: [AutoFillEntry]) -> [Identity] {
        entries.flatMap { entry in
            entry.domains.map {
                Identity(domain: $0, user: entry.isCode ? entry.label : entry.user, recordIdentifier: entry.id, isCode: entry.isCode)
            }
        }
    }

    private static func unique(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        return domains.map { $0.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - Matching a site

nonisolated enum AutoFillMatch {
    /// The host of a service identifier: a URL (`https://accounts.google.com/login`) or a domain.
    static func host(of identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let host = URLComponents(string: withScheme)?.host, !host.isEmpty else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    /// Whether an entry is for one of the sites: its registrable domains are the site's host or
    /// a parent of it (`google.com` matches `accounts.google.com`).
    static func matches(_ entry: AutoFillEntry, hosts: [String]) -> Bool {
        entry.domains.contains { domain in hosts.contains { $0 == domain || $0.hasSuffix("." + domain) } }
    }

    /// The entries for the sites first, then the rest; each part keeps its order. A search
    /// matches title, username and domains (never values).
    static func ranked(_ entries: [AutoFillEntry], serviceIdentifiers: [String], search: String = "") -> [AutoFillEntry] {
        let hosts = serviceIdentifiers.compactMap(host(of:))
        let query = search.trimmingCharacters(in: .whitespaces)
        let found = query.isEmpty ? entries : entries.filter { entry in
            ([entry.title, entry.user] + entry.domains).contains { $0.localizedCaseInsensitiveContains(query) }
        }
        let matching = found.filter { matches($0, hosts: hosts) }
        return matching + found.filter { !matches($0, hosts: hosts) }
    }
}

// MARK: - The unlock window

/// The app's "no Touch ID for a while" window, shared so the extension fills without asking
/// again while it's open. Only an end time: nothing secret.
nonisolated enum AutoFillUnlock {
    /// Longer than any "Leave Unlocked For…" choice: a later end time is never trusted.
    static let longestWindow: TimeInterval = 7 * 86_400 + 60

    /// Until when the app won't ask: the later of the automatic window (last Touch ID plus the
    /// grace minutes) and an explicit "Leave Unlocked For…". Nil: it asks now.
    static func until(lastAuthentication: Date?, graceMinutes: Int, unlockedUntil: Date?, now: Date) -> Date? {
        var ends: [Date] = []
        if let unlockedUntil { ends.append(unlockedUntil) }
        if graceMinutes > 0, let lastAuthentication { ends.append(lastAuthentication.addingTimeInterval(TimeInterval(graceMinutes * 60))) }
        guard let end = ends.max(), end > now else { return nil }
        return end
    }

    static func isOpen(until: Date?, now: Date) -> Bool {
        guard let until else { return false }
        return until > now && until.timeIntervalSince(now) <= longestWindow
    }

    struct Stored: Codable, Equatable, Sendable {
        var until: Date
    }

    static func encode(_ until: Date) -> Data? { try? JSONEncoder().encode(Stored(until: until)) }
    static func decode(_ data: Data?) -> Date? { data.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }?.until }
}

// MARK: - Reading and writing it

/// The shared Keychain items both sides use.
nonisolated struct AutoFillVault: Sendable {
    let keychain: any KeychainBackend

    private static let indexAccount = "index"
    private static let unlockAccount = "until"
    private static let codesAccount = "codes"

    // Index

    @discardableResult
    func writeIndex(_ entries: [AutoFillEntry]) -> Bool {
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        return keychain.setData(data, service: KeychainServices.autofillIndex, account: Self.indexAccount, label: "Clipboard2 AutoFill")
    }

    func index() -> [AutoFillEntry] {
        guard let data = keychain.data(service: KeychainServices.autofillIndex, account: Self.indexAccount) else { return [] }
        return (try? JSONDecoder().decode([AutoFillEntry].self, from: data)) ?? []
    }

    // Unlock window

    func writeUnlock(until: Date?) {
        if let until, let data = AutoFillUnlock.encode(until) {
            keychain.setData(data, service: KeychainServices.autofillUnlock, account: Self.unlockAccount, label: "Clipboard2 unlock")
        } else {
            keychain.remove(service: KeychainServices.autofillUnlock, account: Self.unlockAccount)
        }
    }

    func unlockedUntil() -> Date? {
        AutoFillUnlock.decode(keychain.data(service: KeychainServices.autofillUnlock, account: Self.unlockAccount))
    }

    // Email codes

    func writeEmailCodes(_ codes: [AutoFillEmailCode]) {
        guard !codes.isEmpty, let data = try? JSONEncoder().encode(codes) else {
            keychain.remove(service: KeychainServices.autofillEmailCodes, account: Self.codesAccount)
            return
        }
        keychain.setData(data, service: KeychainServices.autofillEmailCodes, account: Self.codesAccount, label: "Clipboard2 email codes")
    }

    func emailCodes() -> [AutoFillEmailCode] {
        guard let data = keychain.data(service: KeychainServices.autofillEmailCodes, account: Self.codesAccount) else { return [] }
        return (try? JSONDecoder().decode([AutoFillEmailCode].self, from: data)) ?? []
    }

    // Values, only after Touch ID

    /// A password's value.
    func password(for entry: AutoFillEntry) -> String? {
        guard entry.kind == .password,
              let data = keychain.data(service: KeychainServices.secrets, account: entry.itemID) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A code's current value.
    func code(for entry: AutoFillEntry, at now: Date) -> String? {
        switch entry.kind {
        case .password:
            return nil
        case .authenticator:
            guard let data = keychain.data(service: KeychainServices.authenticators, account: entry.itemID),
                  let seed = try? JSONDecoder().decode(Seed.self, from: data), let key = Base32.decode(seed.secret)
            else { return nil }
            return TOTP.code(key: key, time: now, algorithm: OTPAlgorithm(parsing: seed.algorithm ?? "") ?? .sha1,
                             digits: seed.digits ?? 6, period: seed.period ?? 30)
        case .sharedCode:
            guard let data = keychain.data(service: KeychainServices.sharedCodes, account: entry.itemID),
                  let batch = try? JSONDecoder().decode(Shared.self, from: data).batch else { return nil }
            return batch.code(at: now)
        case .emailCode:
            return emailCodes().first { $0.id == entry.itemID && $0.isFresh(at: now) }?.code
        }
    }

    /// The fields of an `otp` payload (SyncPayload.swift) a code needs.
    private struct Seed: Decodable {
        var secret: String
        var algorithm: String?
        var digits: Int?
        var period: Int?
    }

    /// The fields of a `SharedAuthenticator` (Authenticators.swift) a code needs.
    private struct Shared: Decodable {
        struct Batch: Decodable {
            var period: Int
            var from: Int64
            var codes: [String]

            func code(at time: Date) -> String? {
                let seconds = Int64(floor(time.timeIntervalSince1970))
                guard period > 0, seconds >= from else { return nil }
                let index = Int((seconds - from) / Int64(period))
                return codes.indices.contains(index) ? codes[index] : nil
            }
        }
        var batch: Batch?
    }
}
