import Foundation
import Security

// Email accounts and the codes found in them (docs/features/auth-autofill.md → Phase 4): what's
// stored, where, and the IMAP server presets.

// MARK: - Models

nonisolated struct IMAPSettings: Codable, Equatable, Sendable {
    var host: String
    var port: UInt16 = 993
    var useTLS = true
}

nonisolated struct EmailAccount: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var provider: EmailProvider
    var address: String
    /// IMAP accounts only.
    var imap: IMAPSettings?
}

/// What signs an account in: OAuth tokens, or an IMAP app password.
nonisolated enum EmailCredential: Codable, Equatable, Sendable {
    case oauth(OAuthTokens)
    case password(String)
}

/// A code found in a mail. Only these four things are kept: never the subject, body or sender.
nonisolated struct EmailCode: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var code: String
    /// The sender's registrable domain ("google.com").
    var source: String
    var accountID: String
    var receivedAt: Date

    /// Codes are shown, kept and offered for 10 minutes.
    static let lifetime: TimeInterval = 10 * 60

    var expiresAt: Date { receivedAt.addingTimeInterval(Self.lifetime) }
    func isLive(at now: Date) -> Bool { now < expiresAt }

    /// "just now", "1 min ago", "4 min ago".
    func age(at now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(receivedAt)) / 60)
        return minutes == 0 ? "just now" : "\(minutes) min ago"
    }

    var authSource: AuthSource { .domain(source) }
}

// MARK: - Storage

/// Where accounts, their credentials and live codes are kept. One small type of its own, so it can
/// move (to the shared Keychain, with phase 3) without touching anything else.
protocol EmailVault: AnyObject {
    func data(for key: String) -> Data?
    func set(_ data: Data?, for key: String)
}

nonisolated enum EmailVaultKey {
    static let accounts = "accounts"
    static let codes = "codes"
    static func credential(_ accountID: String) -> String { "credential." + accountID }
}

/// Login Keychain items under one service: `<bundle id>.email`.
final class KeychainEmailVault: EmailVault {
    nonisolated static let service = (Bundle.main.bundleIdentifier ?? "at.softmaze.Clippy") + ".email"

    func data(for key: String) -> Data? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service,
                                      kSecAttrAccount: key, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func set(_ data: Data?, for key: String) {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: key]
        guard let data else {
            SecItemDelete(base as CFDictionary)
            return
        }
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData: data] as CFDictionary)
        guard status == errSecItemNotFound else {
            if status != errSecSuccess { Log.app.error("Email vault write failed: \(status, privacy: .public)") }
            return
        }
        var item = base
        item[kSecValueData] = data
        item[kSecAttrLabel] = "Clipboard2 email codes"
        item[kSecAttrDescription] = "Clipboard2 email account"
        SecItemAdd(item as CFDictionary, nil)
    }
}

final class MemoryEmailVault: EmailVault {
    var items: [String: Data] = [:]
    func data(for key: String) -> Data? { items[key] }
    func set(_ data: Data?, for key: String) { items[key] = data }
}

extension EmailVault {
    func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        data(for: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    func encode<T: Encodable>(_ value: T?, _ key: String) {
        set(value.flatMap { try? JSONEncoder().encode($0) }, for: key)
    }
}

// MARK: - Senders

nonisolated enum EmailCodeSender {
    /// Mail domains that stand for another site.
    /// Mail domains that send for another site. (Personal mailbox domains like gmail.com are
    /// people, not sites, and stay as they are.)
    static let aliases: [String: String] = [
        "microsoftonline.com": "microsoft.com", "facebookmail.com": "facebook.com",
    ]

    /// The source a code is listed under: the sender's registrable domain
    /// ("Google <no-reply@accounts.google.com>" → "google.com").
    static func source(ofFrom from: String, list: PublicSuffixList = .shared) -> String? {
        guard let address = MIME.address(inFrom: from), let host = MIME.domain(ofAddress: address),
              let domain = AuthSource.domain(ofSite: host, list: list) else { return nil }
        return aliases[domain] ?? domain
    }
}

// MARK: - IMAP presets

nonisolated struct IMAPPreset: Equatable, Sendable {
    var name: String
    var host: String
    var port: UInt16 = 993
    /// How to get a password this app can use.
    var help: String
    var helpURL: URL?

    var settings: IMAPSettings { IMAPSettings(host: host, port: port, useTLS: true) }
}

nonisolated enum IMAPGuess: Equatable, Sendable {
    case preset(IMAPPreset)
    /// Outlook.com and Hotmail don't take passwords over IMAP any more: Microsoft sign-in.
    case useMicrosoft
    /// Unknown: `imap.<domain>`, to check under Advanced.
    case guessed(IMAPSettings)
    case invalid
}

nonisolated enum IMAPPresets {
    static let gmail = IMAPPreset(name: "Gmail", host: "imap.gmail.com",
                                  help: "Turn on 2-Step Verification, then make an app password in your Google Account.",
                                  helpURL: URL(string: "https://myaccount.google.com/apppasswords"))
    static let yahoo = IMAPPreset(name: "Yahoo", host: "imap.mail.yahoo.com",
                                  help: "Make an app password in Yahoo Account Security.",
                                  helpURL: URL(string: "https://help.yahoo.com/kb/SLN15241.html"))
    static let icloud = IMAPPreset(name: "iCloud", host: "imap.mail.me.com",
                                   help: "Make an app-specific password at account.apple.com → Sign-In and Security.",
                                   helpURL: URL(string: "https://support.apple.com/102654"))
    static let gmx = IMAPPreset(name: "GMX", host: "imap.gmx.net",
                                help: "Turn on POP3/IMAP access in GMX settings, then use your GMX password (or an app password with 2-factor).",
                                helpURL: URL(string: "https://hilfe.gmx.net/pop-imap/einschalten.html"))
    static let webde = IMAPPreset(name: "WEB.DE", host: "imap.web.de",
                                  help: "Turn on POP3/IMAP access in WEB.DE settings, then use your WEB.DE password (or an app password with 2-factor).",
                                  helpURL: URL(string: "https://hilfe.web.de/pop-imap/einschalten.html"))
    static let aol = IMAPPreset(name: "AOL", host: "imap.aol.com",
                                help: "Make an app password in AOL Account Security.",
                                helpURL: URL(string: "https://help.aol.com/articles/Create-and-manage-app-password"))

    static let byDomain: [String: IMAPPreset] = [
        "gmail.com": gmail, "googlemail.com": gmail,
        "yahoo.com": yahoo, "yahoo.de": yahoo, "yahoo.co.uk": yahoo, "yahoo.fr": yahoo, "ymail.com": yahoo,
        "rocketmail.com": yahoo,
        "icloud.com": icloud, "me.com": icloud, "mac.com": icloud,
        "gmx.net": gmx, "gmx.de": gmx, "gmx.at": gmx, "gmx.ch": gmx,
        "web.de": webde,
        "aol.com": aol, "aol.de": aol, "aim.com": aol,
    ]

    static let microsoftDomains: Set<String> = ["outlook.com", "outlook.de", "outlook.at", "hotmail.com", "hotmail.de",
                                                "hotmail.co.uk", "live.com", "live.de", "live.at", "msn.com"]

    static func guess(for email: String) -> IMAPGuess {
        let trimmed = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard let at = trimmed.lastIndex(of: "@"), at != trimmed.startIndex else { return .invalid }
        let domain = String(trimmed[trimmed.index(after: at)...])
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains(" ") else { return .invalid }
        if microsoftDomains.contains(domain) { return .useMicrosoft }
        if let preset = byDomain[domain] { return .preset(preset) }
        return .guessed(IMAPSettings(host: "imap." + domain))
    }
}
