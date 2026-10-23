import Foundation

/// Recognises text that looks like a credential, so it can be hidden in lists and kept out of
/// sync groups unless the user says otherwise. Pure and cheap: it runs for visible rows, so
/// anything with spaces (other than a private key or card number) or longer than 512 characters
/// is skipped.
nonisolated enum SensitiveText {
    enum Kind: Sendable, Equatable {
        case privateKey, cardNumber, apiKey, token, code, password

        /// Completes "This looks like …".
        var description: String {
            switch self {
            case .privateKey: "a private key"
            case .cardNumber: "a card number"
            case .apiKey: "an API key"
            case .token: "an access token"
            case .code: "a license or recovery code"
            case .password: "a password"
            }
        }

        /// Short name for list rows ("Hidden · API key").
        var shortName: String {
            switch self {
            case .privateKey: "Private key"
            case .cardNumber: "Card number"
            case .apiKey: "API key"
            case .token: "Token"
            case .code: "Code"
            case .password: "Password"
            }
        }

        /// Every kind has a recognisable format except passwords, which are a guess. Only
        /// confident matches are masked in lists; all of them are kept out of groups.
        var isConfident: Bool { self != .password }
    }

    /// Prefixes of well-known API keys and tokens (OpenAI, Anthropic, Stripe, GitHub, GitLab,
    /// Slack, AWS, Google, SendGrid, Hugging Face, npm, PyPI, DigitalOcean, Shopify, Square, Meta).
    private static let keyPrefixes = [
        "sk-", "sk_live_", "sk_test_", "rk_live_", "rk_test_",
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
        "glpat-", "xoxb-", "xoxp-", "xoxa-", "xoxs-", "xapp-",
        "AKIA", "ASIA", "AIza", "ya29.", "SG.", "hf_", "npm_", "pypi-",
        "dop_v1_", "shpat_", "shpss_", "sq0atp-", "sq0csp-", "EAAC",
    ]

    static func detect(_ text: String) -> Kind? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 8 else { return nil }
        if value.contains("-----BEGIN"), value.contains("PRIVATE KEY-----") { return .privateKey }
        if isCardNumber(value) { return .cardNumber }
        guard value.count <= 512, !value.contains(where: \.isWhitespace) else { return nil }
        if isPrefixedKey(value) { return .apiKey }
        if isJWT(value) { return .token }
        if isGroupedCode(value) { return .code }
        if isRandomToken(value) { return .token }
        if isPasswordLike(value) { return .password }
        return nil
    }

    // MARK: Rules

    private static let tokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))

    private static func isPrefixedKey(_ value: String) -> Bool {
        guard let prefix = keyPrefixes.first(where: value.hasPrefix) else { return false }
        let rest = value.dropFirst(prefix.count)
        return rest.count >= 16
            && rest.unicodeScalars.allSatisfy(tokenCharacters.contains)
            && rest.contains(where: \.isNumber)
    }

    /// header.payload.signature, each base64url; the header always starts with `{"`, i.e. `eyJ`.
    private static func isJWT(_ value: String) -> Bool {
        guard value.hasPrefix("eyJ"), value.count >= 30 else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let base64URL = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(base64URL.contains) }
    }

    /// License keys and recovery codes: at least four equal-length groups of capitals and digits,
    /// like `ABCD-EF12-GH34-IJKL`. UUIDs have unequal groups and are left alone.
    private static func isGroupedCode(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count >= 4, let length = groups.first?.count, (4...6).contains(length) else { return false }
        let capitalsAndDigits = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return groups.allSatisfy { $0.count == length && $0.unicodeScalars.allSatisfy(capitalsAndDigits.contains) }
            && value.contains(where: \.isLetter)
    }

    /// Long random-looking strings: mixed case and digits with high entropy. Lower-case hex
    /// (commit hashes, checksums) and readable identifiers fall below the bar.
    private static func isRandomToken(_ value: String) -> Bool {
        let base64 = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=_-."))
        guard value.count >= 32, value.unicodeScalars.allSatisfy(base64.contains), !isPathOrFileName(value) else { return false }
        return value.contains(where: \.isUppercase) && value.contains(where: \.isLowercase)
            && value.contains(where: \.isNumber) && entropy(value) >= 4.0
    }

    /// A single short word mixing capitals, small letters and digits, with a symbol or some length.
    private static func isPasswordLike(_ value: String) -> Bool {
        guard (10...64).contains(value.count),
              value.contains(where: \.isUppercase), value.contains(where: \.isLowercase), value.contains(where: \.isNumber)
        else { return false }
        if isPathOrFileName(value) || value.contains("(") { return false }
        if let at = value.firstIndex(of: "@"), value[at...].contains(".") { return false }   // an email address
        let hasSymbol = value.contains { !$0.isLetter && !$0.isNumber }
        return (hasSymbol || value.count >= 14) && entropy(value) >= 3.0
    }

    /// Links, paths and file names (`Report2026Final.pdf`) are random-looking but not secret.
    private static func isPathOrFileName(_ value: String) -> Bool {
        if value.contains("://") || value.hasPrefix("/") || value.hasPrefix("~") { return true }
        guard let dot = value.lastIndex(of: ".") else { return false }
        let fileExtension = value[value.index(after: dot)...]
        return (2...5).contains(fileExtension.count) && fileExtension.allSatisfy(\.isLetter)
    }

    /// 13–19 digits (spaces or hyphens allowed between them) that pass the Luhn check.
    private static func isCardNumber(_ value: String) -> Bool {
        guard value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == " " || $0 == "-") }) else { return false }
        let digits = value.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset.isMultiple(of: 2) {
                sum += digit
            } else {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return sum.isMultiple(of: 10)
    }

    /// Shannon entropy in bits per character.
    private static func entropy(_ value: String) -> Double {
        var counts: [Character: Int] = [:]
        for character in value { counts[character, default: 0] += 1 }
        let total = Double(value.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }
}
