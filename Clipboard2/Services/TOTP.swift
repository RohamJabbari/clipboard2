import Foundation
import CryptoKit

// Time-based one-time passwords (RFC 6238) and `otpauth://` links. Pure: no storage, no UI.

nonisolated enum OTPAlgorithm: String, Codable, CaseIterable, Sendable, Identifiable {
    case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sha1: "SHA-1"
        case .sha256: "SHA-256"
        case .sha512: "SHA-512"
        }
    }

    /// Accepts `SHA1`, `sha-256`, `SHA512`…
    init?(parsing raw: String) {
        let compact = raw.uppercased().replacingOccurrences(of: "-", with: "")
        guard let value = OTPAlgorithm(rawValue: compact) else { return nil }
        self = value
    }
}

/// RFC 4648 base32 (A–Z, 2–7). Decoding forgives spaces, hyphens, lower case and missing padding.
nonisolated enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    private static let values: [Character: UInt8] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, UInt8($0)) })

    /// Upper case, without spaces, hyphens or padding; nil if anything else isn't base32.
    static func normalize(_ text: String) -> String? {
        let cleaned = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        let unpadded = String(cleaned.reversed().drop { $0 == "=" }.reversed())
        guard !unpadded.isEmpty, unpadded.allSatisfy({ values[$0] != nil }) else { return nil }
        return unpadded
    }

    static func decode(_ text: String) -> Data? {
        guard let normalized = normalize(text) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(normalized.count * 5 / 8)
        var buffer: UInt32 = 0
        var bits = 0
        for character in normalized {
            guard let value = values[character] else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return Data(bytes)
    }

    /// No padding.
    static func encode(_ data: Data) -> String {
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
            }
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)]) }
        return out
    }
}

nonisolated enum TOTP {
    static let digitRange = 6...8

    /// The code for `time`; nil for an empty key, digits outside 6–8 or a period under 1 s.
    static func code(key: Data, time: Date, algorithm: OTPAlgorithm = .sha1, digits: Int = 6, period: Int = 30) -> String? {
        guard !key.isEmpty, digitRange.contains(digits), period > 0, time.timeIntervalSince1970 >= 0 else { return nil }
        let counter = UInt64(floor(time.timeIntervalSince1970 / Double(period)))
        return hotp(key: key, counter: counter, algorithm: algorithm, digits: digits)
    }

    /// RFC 4226 with dynamic truncation (TOTP feeds it the time step).
    static func hotp(key: Data, counter: UInt64, algorithm: OTPAlgorithm, digits: Int) -> String {
        var big = counter.bigEndian
        let message = withUnsafeBytes(of: &big) { Data($0) }
        let symmetric = SymmetricKey(data: key)
        let mac: [UInt8] = switch algorithm {
        case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetric))
        case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: symmetric))
        case .sha512: Array(HMAC<SHA512>.authenticationCode(for: message, using: symmetric))
        }
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let value = String(binary % modulus)
        return String(repeating: "0", count: digits - value.count) + value
    }

    /// Whole seconds until the code changes (1…period).
    static func secondsRemaining(at time: Date, period: Int) -> Int {
        guard period > 0 else { return 0 }
        let elapsed = Int(floor(time.timeIntervalSince1970)) % period
        return period - elapsed
    }

    /// Fraction of the current step still left, for the countdown ring (1 → 0).
    static func fractionRemaining(at time: Date, period: Int) -> Double {
        guard period > 0 else { return 0 }
        let elapsed = time.timeIntervalSince1970.truncatingRemainder(dividingBy: Double(period))
        return max(0, min(1, 1 - elapsed / Double(period)))
    }

    /// `123 456`, `1234 5678`, `123 4567`: easier to read and type.
    static func grouped(_ code: String) -> String {
        let split = code.count == 7 ? 3 : code.count / 2
        guard code.count >= 6 else { return code }
        return String(code.prefix(split)) + " " + String(code.dropFirst(split))
    }
}

/// What an authenticator needs, before it has an id: from a link, a QR code or the manual form.
nonisolated struct OTPAccount: Equatable, Hashable, Sendable {
    var issuer: String
    var account: String
    /// Normalised base32 (upper case, no padding).
    var secret: String
    var algorithm: OTPAlgorithm = .sha1
    var digits: Int = 6
    var period: Int = 30
}

nonisolated enum OTPAuthError: Error, Equatable, Sendable {
    case notALink
    /// `otpauth://hotp`: counter-based codes aren't supported.
    case hotpUnsupported
    /// `otpauth-migration://` (Google Authenticator's export): not supported.
    case migrationUnsupported
    case missingSecret
    case invalidSecret
    case unsupportedAlgorithm
    case unsupportedDigits
    case invalidPeriod

    /// One line for the HUD or the panel.
    var message: String {
        switch self {
        case .notALink: "That isn't an authenticator link."
        case .hotpUnsupported: "Counter-based (HOTP) codes aren't supported. Only time-based codes work in Clipboard2."
        case .migrationUnsupported: "Authenticator exports can't be imported. Add each account from its own QR code or setup key."
        case .missingSecret, .invalidSecret: "This authenticator link has no valid setup key."
        case .unsupportedAlgorithm: "This authenticator link uses an algorithm Clipboard2 doesn't support."
        case .unsupportedDigits: "Codes must have 6 to 8 digits."
        case .invalidPeriod: "This authenticator link has an invalid code period."
        }
    }
}

nonisolated enum OTPAuthURI {
    /// Anything that carries authenticator secrets: never kept as a history item.
    static func isSecretLink(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.contains(where: \.isNewline) else { return false }
        return value.hasPrefix("otpauth://") || value.hasPrefix("otpauth-migration://")
    }

    static func parse(_ text: String) -> Result<OTPAccount, OTPAuthError> {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        if lower.hasPrefix("otpauth-migration://") { return .failure(.migrationUnsupported) }
        guard lower.hasPrefix("otpauth://") else { return .failure(.notALink) }
        // Some sites put raw spaces in the label.
        guard let components = URLComponents(string: value.replacingOccurrences(of: " ", with: "%20")) else {
            return .failure(.notALink)
        }
        switch components.host?.lowercased() {
        case "totp": break
        case "hotp": return .failure(.hotpUnsupported)
        default: return .failure(.notALink)
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name.lowercased()] = item.value ?? ""
        }
        guard let rawSecret = query["secret"], !rawSecret.isEmpty else { return .failure(.missingSecret) }
        guard let secret = Base32.normalize(rawSecret), Base32.decode(secret)?.isEmpty == false else {
            return .failure(.invalidSecret)
        }
        var algorithm = OTPAlgorithm.sha1
        if let raw = query["algorithm"], !raw.isEmpty {
            guard let parsed = OTPAlgorithm(parsing: raw) else { return .failure(.unsupportedAlgorithm) }
            algorithm = parsed
        }
        var digits = 6
        if let raw = query["digits"], !raw.isEmpty {
            guard let parsed = Int(raw), TOTP.digitRange.contains(parsed) else { return .failure(.unsupportedDigits) }
            digits = parsed
        }
        var period = 30
        if let raw = query["period"], !raw.isEmpty {
            guard let parsed = Int(raw), parsed > 0, parsed <= 3600 else { return .failure(.invalidPeriod) }
            period = parsed
        }

        // The label is "Issuer:account", "Issuer: account" or just "account"; the issuer parameter wins.
        var label = components.path
        if label.hasPrefix("/") { label.removeFirst() }
        label = label.removingPercentEncoding ?? label
        var labelIssuer: String?
        var account = label
        if let colon = label.firstIndex(of: ":") {
            labelIssuer = String(label[..<colon]).trimmingCharacters(in: .whitespaces)
            account = String(label[label.index(after: colon)...])
        }
        account = account.trimmingCharacters(in: .whitespaces)
        let paramIssuer = query["issuer"]?.trimmingCharacters(in: .whitespaces)
        let issuer = (paramIssuer?.isEmpty == false ? paramIssuer : labelIssuer) ?? ""
        return .success(OTPAccount(issuer: issuer, account: account, secret: secret, algorithm: algorithm,
                                   digits: digits, period: period))
    }

    /// A standard link for phone apps (the Show QR code).
    static func make(_ account: OTPAccount) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~@+"))
        func escape(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        let label = account.issuer.isEmpty ? escape(account.account) : escape(account.issuer) + ":" + escape(account.account)
        var link = "otpauth://totp/\(label)?secret=\(account.secret)"
        if !account.issuer.isEmpty { link += "&issuer=\(escape(account.issuer))" }
        link += "&algorithm=\(account.algorithm.rawValue)&digits=\(account.digits)&period=\(account.period)"
        return link
    }
}
