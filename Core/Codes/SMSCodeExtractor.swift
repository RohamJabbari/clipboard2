import Foundation

// Sign-in codes from text messages (docs/features/ios.md → SMS codes). iOS apps can't read SMS:
// a Shortcuts automation hands the message text and sender to the "Save Sign-in Code" intent,
// which runs these. Pure and on device; the message itself is never kept.

nonisolated enum SMSCodeExtractor {
    /// Text messages are short; anything longer is cut before reading.
    static let messageLimit = 1000

    nonisolated struct Result: Equatable, Sendable {
        var code: String
        /// The site an origin-bound code names (`@example.com #123456`), the only fully reliable origin.
        var boundDomain: String?
    }

    /// The sign-in code in a message, or nil.
    static func extract(_ message: String) -> Result? {
        let text = String(message.prefix(messageLimit))
        if let bound = originBound(text) { return bound }
        // "G-123456 is your Google verification code": the prefix isn't part of what's typed.
        if let google = firstMatch(#"(?<![A-Za-z0-9])G-(\d{4,8})(?![0-9])"#, in: text) {
            return Result(code: google)
        }
        if let code = EmailCodeExtractor.code(subject: "", body: text) { return Result(code: code) }
        // "Ihr Freigabe-TAN", "SMS-Passcode": keywords glued to another word with a hyphen.
        let split = text.replacingOccurrences(of: #"(?<=\p{L})-(?=\p{L})"#, with: " ", options: .regularExpression)
        if split != text, let code = EmailCodeExtractor.code(subject: "", body: split) { return Result(code: code) }
        if let code = smsKeywordCode(text) { return Result(code: code) }
        return nil
    }

    // MARK: Origin-bound codes

    /// The last line of an origin-bound message: `@example.com #123456` (optionally followed by
    /// `@embedding.example`). Safari reads the same format.
    static func originBound(_ text: String) -> Result? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = lines.last(where: { !$0.isEmpty }) else { return nil }
        let pattern = #"^@([A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,})\s+#([A-Za-z0-9-]{3,12})(?:\s+@\S+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: last, range: NSRange(last.startIndex..., in: last)),
              let domainRange = Range(match.range(at: 1), in: last),
              let codeRange = Range(match.range(at: 2), in: last)
        else { return nil }
        return Result(code: String(last[codeRange]), boundDomain: String(last[domainRange]).lowercased())
    }

    // MARK: Words texts use for codes that mails don't

    /// Near one of these, a 4–8 digit number in a short message is a sign-in code too:
    /// "Use 482913 to log in", "Your login: 4821", "Anmeldung: 123456".
    private static let smsKeywordPrefixes = ["login", "logon", "anmeld", "einlog", "signin", "password", "passwort",
                                             "kennwort", "zugang", "access", "sicherheit", "security", "auth", "token",
                                             "freigabe", "2fa", "mfa"]
    static let smsMaxDistance = 60

    static func smsKeywordCode(_ text: String) -> String? {
        guard text.count <= 400 else { return nil }
        let chars = Array(EmailCodeExtractor.clean(text))
        let words = EmailCodeExtractor.letterWords(chars)
        // "sign in" and "log in" as two words.
        var keywords: [EmailCodeExtractor.Keyword] = []
        for (index, word) in words.enumerated() {
            let next = index + 1 < words.count ? words[index + 1].text : ""
            let joined = (word.text == "sign" || word.text == "log") && next == "in" ? word.text + "in" : word.text
            if smsKeywordPrefixes.contains(where: { joined.hasPrefix($0) }) {
                keywords.append(.init(start: word.start, end: word.end, negative: false))
            }
        }
        guard !keywords.isEmpty else { return nil }
        var best: (code: String, distance: Double)?
        for candidate in EmailCodeExtractor.findCandidates(chars)
        where candidate.isDigits && !candidate.needsOwnLine && !EmailCodeExtractor.isExcluded(candidate, in: chars)
            && !EmailCodeExtractor.inPromotion(candidate, chars) {
            guard let (_, distance) = EmailCodeExtractor.nearest(keywords, to: candidate),
                  distance <= Double(smsMaxDistance) else { continue }
            if best == nil || distance < best!.distance { best = (candidate.code, distance) }
        }
        return best?.code
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

// MARK: - Which site a code is for

/// What the matcher knows besides the message: senders the user assigned to a site, and the site
/// they used last (only passed when it was recent).
nonisolated struct SMSOriginContext: Sendable, Equatable {
    /// `SMSOriginMatcher.senderKey(_:)` → registrable domain.
    var learnedSenders: [String: String] = [:]
    var recentDomain: String?

    init(learnedSenders: [String: String] = [:], recentDomain: String? = nil) {
        self.learnedSenders = learnedSenders
        self.recentDomain = recentDomain
    }
}

nonisolated enum SMSOriginMatcher {
    nonisolated enum Reason: String, Sendable, Equatable, Codable {
        /// `@example.com #123456`.
        case originBound
        /// The user assigned this sender to a site before.
        case learnedSender
        /// The sender is an email address (iMessage) or a known sender name or short code.
        case sender
        /// "G-123456": Google's prefix.
        case messagePrefix
        /// A domain written in the message ("amazon.de").
        case domainInText
        /// A known service named in the message ("Your PayPal code").
        case nameInText
        /// Nothing in the message: the site used last in Clipboard2, within the last minutes.
        case recentlyUsed

        /// Whether the match is a guess the user should be able to correct at a glance.
        var isGuess: Bool { self == .recentlyUsed || self == .nameInText }
    }

    nonisolated struct Match: Sendable, Equatable {
        var domain: String
        var reason: Reason
    }

    static func match(message: String, sender: String?, boundDomain: String? = nil,
                      context: SMSOriginContext = SMSOriginContext(), list: PublicSuffixList = .shared) -> Match? {
        if let boundDomain, let domain = AuthSource.domain(ofSite: boundDomain, list: list) {
            return Match(domain: domain, reason: .originBound)
        }
        if let sender, !sender.trimmingCharacters(in: .whitespaces).isEmpty {
            if let learned = context.learnedSenders[senderKey(sender)] { return Match(domain: learned, reason: .learnedSender) }
            if let domain = domain(ofSender: sender, list: list) { return Match(domain: domain, reason: .sender) }
        }
        if message.range(of: #"(?<![A-Za-z0-9])G-\d{4,8}(?![0-9])"#, options: .regularExpression) != nil {
            return Match(domain: "google.com", reason: .messagePrefix)
        }
        if let domain = domainInText(message, list: list) { return Match(domain: domain, reason: .domainInText) }
        if let domain = nameInText(message, list: list) { return Match(domain: domain, reason: .nameInText) }
        if let recent = context.recentDomain { return Match(domain: recent, reason: .recentlyUsed) }
        return nil
    }

    /// A sender as a dictionary key: lowercased, spaces and punctuation removed (phone numbers
    /// keep their digits and a leading +).
    static func senderKey(_ sender: String) -> String {
        let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.contains("@") { return trimmed }
        let plus = trimmed.hasPrefix("+") ? "+" : ""
        return plus + String(trimmed.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Short codes and sender names that aren't in the issuer table, or mean something else there.
    static let knownSenders: [String: String] = [
        // US short codes
        "22000": "google.com", "32665": "facebook.com", "40404": "x.com", "227898": "amazon.com",
        "729725": "paypal.com", "89203": "uber.com", "827438": "uber.com", "77857": "instagram.com",
        "79680": "microsoft.com", "44398": "apple.com",
        // Sender names
        "google": "google.com", "googleverify": "google.com", "microsoft": "microsoft.com", "msverify": "microsoft.com",
        "amazon": "amazon.com", "paypal": "paypal.com", "apple": "apple.com", "whatsapp": "whatsapp.com",
        "facebook": "facebook.com", "instagram": "instagram.com", "twitter": "x.com", "signal": "signal.org",
        "telegram": "telegram.org", "bolt": "bolt.eu", "uber": "uber.com", "lyft": "lyft.com", "steam": "steampowered.com",
        "revolut": "revolut.com", "n26": "n26.com", "wise": "wise.com", "coinbase": "coinbase.com",
        "airbnb": "airbnb.com", "booking": "booking.com", "ebay": "ebay.com", "linkedin": "linkedin.com",
        "tiktok": "tiktok.com", "snapchat": "snapchat.com", "discord": "discord.com", "netflix": "netflix.com",
        "verify": "", "info": "", "sms": "",
        // Austria and Germany
        "george": "sparkasse.at", "erstebank": "sparkasse.at", "sparkasse": "sparkasse.at", "raiffeisen": "raiffeisen.at",
        "elba": "raiffeisen.at", "bawag": "bawag.at", "bawagpsk": "bawag.at", "easybank": "easybank.at",
        "bankaustria": "bankaustria.at", "unicredit": "bankaustria.at", "volksbank": "volksbank.at", "dadat": "dad.at",
        "hellobank": "hellobank.at", "oebb": "oebb.at", "post": "post.at", "drei": "drei.at", "magenta": "magenta.at",
        "a1": "a1.net", "idaustria": "oesterreich.gv.at", "handysignatur": "oesterreich.gv.at",
        "finanzonline": "bmf.gv.at", "willhaben": "willhaben.at", "dkb": "dkb.de", "comdirect": "comdirect.de",
        "ing": "ing.de", "commerzbank": "commerzbank.de", "deutschebank": "deutsche-bank.de", "postbank": "postbank.de",
        "consorsbank": "consorsbank.de", "traderepublic": "traderepublic.com", "scalable": "scalable.capital",
        "c24": "c24.de", "vivid": "vivid.money", "bunq": "bunq.com", "klarna": "klarna.com",
    ]

    /// The site of a sender: an email address's domain, a known sender, or an issuer name.
    /// Phone numbers (other than known short codes) say nothing.
    static func domain(ofSender sender: String, list: PublicSuffixList = .shared) -> String? {
        let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = trimmed.lastIndex(of: "@") {
            return AuthSource.domain(ofSite: String(trimmed[trimmed.index(after: at)...]), list: list)
        }
        let key = senderKey(trimmed)
        if let known = knownSenders[key] { return known.isEmpty ? nil : known }
        // A phone number: only its owner knows.
        if key.allSatisfy({ $0.isNumber || $0 == "+" }) { return nil }
        if trimmed.contains("."), !trimmed.contains(" "), let domain = AuthSource.domain(ofSite: trimmed, list: list),
           domain.contains(".") {
            return domain
        }
        return IssuerDomains.domain(for: trimmed, list: list)
    }

    /// TLDs a domain written in a text message is likely to have; anything else ("Nr.5", "z.B")
    /// is more likely an abbreviation than a site.
    private static let textTLDs: Set<String> = ["com", "net", "org", "io", "de", "at", "ch", "eu", "uk", "fr", "it",
                                                "es", "nl", "be", "pl", "se", "dk", "no", "fi", "us", "ca", "me", "app",
                                                "co", "dev", "ai", "tv", "gov", "edu", "info", "biz", "cz", "hu", "sk"]

    static func domainInText(_ message: String, list: PublicSuffixList = .shared) -> String? {
        let pattern = #"(?i)(?<![A-Za-z0-9@.-])((?:https?://)?(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+([a-z]{2,6}))(?![A-Za-z0-9-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in regex.matches(in: message, range: NSRange(message.startIndex..., in: message)) {
            guard let range = Range(match.range(at: 1), in: message), let tldRange = Range(match.range(at: 2), in: message),
                  textTLDs.contains(message[tldRange].lowercased()),
                  let domain = AuthSource.domain(ofSite: String(message[range]), list: list), domain.contains(".")
            else { continue }
            return domain
        }
        return nil
    }

    /// Issuer names that are also everyday words; a message saying them doesn't name the service.
    static let ambiguousNames: Set<String> = [
        "target", "line", "max", "discover", "square", "wise", "hover", "render", "linear", "monday", "medium",
        "keeper", "gemini", "mega", "box", "x", "ea", "epic", "unity", "segment", "elastic", "expo", "duo", "chase",
        "meta", "notion", "slack", "zoom", "loom", "kraken", "oracle", "riot", "valve", "booking", "proton", "railway",
        "replicate", "wasabi", "claude", "citi", "amplitude", "intercom", "post", "sap", "drei", "info", "apple",
    ]

    /// A known service named in the message, written with a capital ("PayPal", "eBay", "N26").
    static func nameInText(_ message: String, list: PublicSuffixList = .shared) -> String? {
        let words = message.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        for word in words where word.count >= 2 && word.contains(where: { $0.isUppercase }) {
            let key = IssuerDomains.normalized(String(word))
            guard !ambiguousNames.contains(key) else { continue }
            if let known = knownSenders[key], !known.isEmpty, !key.allSatisfy(\.isNumber) { return known }
            if let domain = IssuerDomains.table[key] { return domain }
        }
        return nil
    }
}
