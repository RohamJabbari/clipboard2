import Foundation
import CryptoKit

/// The client cryptography of passwordless accounts (docs/features/passwordless.md → Cryptography,
/// PROTOCOL.md → Passwordless), byte-compatible with `server/src/clientCrypto.ts` (pinned by the
/// `passwordless` section of docs/sync/test-vectors.json).
nonisolated enum PasswordlessCrypto {
    // MARK: Wrapping to a public key

    /// `eph.pub ‖ AEAD(HKDF(ECDH(eph, pub), eph.pub ‖ pub, info), secret, aad)`: the shape of
    /// `wrapSpaceKey`, with the caller's info and AAD. `ephemeralPrivateKey` and `nonce` are for vectors.
    static func wrap(_ secret: Data, to publicKey: Data, info: String, aad: String,
                     ephemeralPrivateKey: Data? = nil, nonce: Data? = nil) throws -> Data {
        let ephPriv = ephemeralPrivateKey ?? SyncCrypto.newPrivateKey()
        let ephPub = try SyncCrypto.publicKey(of: ephPriv)
        let key = SyncCrypto.hkdf(try SyncCrypto.ecdh(privateKey: ephPriv, publicKey: publicKey), salt: ephPub + publicKey, info: info)
        return ephPub + (try SyncCrypto.seal(secret, key: key, aad: aad, nonce: nonce))
    }

    static func unwrap(_ wrapped: Data, privateKey: Data, info: String, aad: String) throws -> Data {
        guard wrapped.count > SyncCrypto.publicKeyLength else { throw SyncCryptoError.badEnvelope }
        let ephPub = Data(wrapped.prefix(SyncCrypto.publicKeyLength))
        let myPub = try SyncCrypto.publicKey(of: privateKey)
        let key = SyncCrypto.hkdf(try SyncCrypto.ecdh(privateKey: privateKey, publicKey: ephPub), salt: ephPub + myPub, info: info)
        return try SyncCrypto.open(Data(wrapped.dropFirst(SyncCrypto.publicKeyLength)), key: key, aad: aad)
    }

    // MARK: The account key to a new device

    static func deviceInfo(requestId: String) -> String { "c2/device/v1/\(requestId)" }
    static func deviceAAD(uid: String, requestId: String) -> String { "c2/device/v1/\(uid)/\(requestId)" }

    static func wrapAccountKey(_ accountKey: Data, uid: String, requestId: String, devicePublicKey: Data,
                               ephemeralPrivateKey: Data? = nil, nonce: Data? = nil) throws -> Data {
        try wrap(accountKey, to: devicePublicKey, info: deviceInfo(requestId: requestId),
                 aad: deviceAAD(uid: uid, requestId: requestId), ephemeralPrivateKey: ephemeralPrivateKey, nonce: nonce)
    }

    static func unwrapAccountKey(_ wrapped: Data, uid: String, requestId: String, devicePrivateKey: Data) throws -> Data {
        try unwrap(wrapped, privateKey: devicePrivateKey, info: deviceInfo(requestId: requestId),
                   aad: deviceAAD(uid: uid, requestId: requestId))
    }

    // MARK: Number matching

    /// 10…99 from the new device's key, so a server that swapped the key can't make the numbers agree.
    static func matchNumber(requestId: String, devicePublicKey: Data) -> Int {
        var hasher = SHA256()
        hasher.update(data: Data("c2/number/v1".utf8))
        hasher.update(data: Data(requestId.utf8))
        hasher.update(data: devicePublicKey)
        let digest = Array(hasher.finalize())
        let value = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])
        return 10 + Int(value % 90)
    }

    /// The right number and two different decoys (10…99), shuffled: what the approver picks from.
    static func choices<R: RandomNumberGenerator>(correct: Int, using generator: inout R) -> [Int] {
        var numbers: Set<Int> = [correct]
        while numbers.count < 3 { numbers.insert(Int.random(in: 10...99, using: &generator)) }
        return Array(numbers).shuffled(using: &generator)
    }

    static func choices(correct: Int) -> [Int] {
        var generator = SystemRandomNumberGenerator()
        return choices(correct: correct, using: &generator)
    }

    // MARK: Recovery shares

    /// XOR n-of-n: `n - 1` random shares and one that makes them all add up to `secret`.
    static func split(_ secret: Data, into count: Int, random: (Int) -> Data = SyncCrypto.randomBytes) -> [Data] {
        precondition(count >= 2, "at least two shares")
        let shares = (1..<count).map { _ in random(secret.count) }
        return shares + [combine([secret] + shares)]
    }

    static func combine(_ shares: [Data]) -> Data {
        guard let first = shares.first else { return Data() }
        var out = [UInt8](repeating: 0, count: first.count)
        for share in shares {
            for (i, byte) in share.enumerated() where i < out.count { out[i] ^= byte }
        }
        return Data(out)
    }

    static func shareInfo(setupId: String) -> String { "c2/recshare/v1/\(setupId)" }
    static func shareAAD(setupId: String, contactUid: String) -> String { "c2/recshare/v1/\(setupId)/\(contactUid)" }
    static func recoveredInfo(recoveryId: String) -> String { "c2/recdev/v1/\(recoveryId)" }
    /// `holder` is the contact's uid, or "server" for the server's share.
    static func recoveredAAD(recoveryId: String, holder: String) -> String { "c2/recdev/v1/\(recoveryId)/\(holder)" }

    static func recoveryCodeKey(_ code: Data) -> Data { SyncCrypto.hkdf(code, info: "c2/reccode/v1") }
    static func recoveryCodeAAD(setupId: String) -> String { "c2/reccode/v1/\(setupId)" }
}

// MARK: - Session windows

/// How long a passwordless device stays signed in, chosen on that device (docs/features/passwordless.md
/// → Session windows). The server ends the session at the same moment the Mac wipes itself.
nonisolated enum SessionWindow: Hashable, Sendable {
    case hour
    case day
    case week
    /// Seconds, between `customRange` bounds.
    case custom(TimeInterval)
    case indefinitely

    /// What the user must type, exactly, to keep a device signed in indefinitely (server checks it too).
    static let acknowledgement = "I understand the risks and I wish to proceed"
    static let customRange: ClosedRange<TimeInterval> = (15 * 60)...(365 * 24 * 60 * 60)
    static let presets: [SessionWindow] = [.hour, .day, .week, .indefinitely]

    var seconds: TimeInterval? {
        switch self {
        case .hour: 60 * 60
        case .day: 24 * 60 * 60
        case .week: 7 * 24 * 60 * 60
        case .custom(let seconds): seconds
        case .indefinitely: nil
        }
    }

    /// The wire value (`windowMs`); nil is indefinitely.
    var milliseconds: Int64? { seconds.map { Int64(($0 * 1000).rounded()) } }

    init(milliseconds: Int64?) {
        guard let milliseconds else {
            self = .indefinitely
            return
        }
        switch milliseconds {
        case 3_600_000: self = .hour
        case 86_400_000: self = .day
        case 604_800_000: self = .week
        default: self = .custom(TimeInterval(milliseconds) / 1000)
        }
    }

    var isValid: Bool {
        guard case .custom(let seconds) = self else { return true }
        return Self.customRange.contains(seconds)
    }

    /// When a session started at `start` ends; nil for indefinitely.
    func expiry(from start: Date) -> Date? { seconds.map { start.addingTimeInterval($0) } }

    var title: String {
        switch self {
        case .hour: "1 hour"
        case .day: "1 day"
        case .week: "1 week"
        case .custom(let seconds): Self.describe(seconds)
        case .indefinitely: "Indefinitely"
        }
    }

    /// "3 days", "90 minutes", "2 weeks".
    static func describe(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes % (7 * 24 * 60) == 0 { return plural(minutes / (7 * 24 * 60), "week") }
        if minutes % (24 * 60) == 0 { return plural(minutes / (24 * 60), "day") }
        if minutes % 60 == 0 { return plural(minutes / 60, "hour") }
        return plural(minutes, "minute")
    }

    private static func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }

    /// Exactly the phrase; only leading and trailing whitespace is forgiven.
    static func isAcknowledged(_ typed: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == acknowledgement
    }

    /// Indefinitely needs the typed acknowledgement; every other valid window doesn't.
    func canStart(acknowledgement typed: String) -> Bool {
        guard isValid else { return false }
        return self != .indefinitely || Self.isAcknowledged(typed)
    }
}

/// The expiry rules a device session follows on this Mac.
nonisolated enum SessionExpiry {
    /// A session with an expiry is over once it's reached (nil never expires).
    static func isExpired(_ expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    /// How long until the wipe, never negative; nil for indefinitely.
    static func remaining(_ expiresAt: Date?, now: Date) -> TimeInterval? {
        expiresAt.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// Another device may only shorten a window; this device may set any.
    static func canChange(current: Date?, to proposed: Date?, isThisDevice: Bool) -> Bool {
        if isThisDevice { return true }
        guard let proposed else { return false }       // indefinitely is never shorter
        guard let current else { return true }         // anything is shorter than indefinitely
        return proposed <= current
    }

    /// "Signed in for 23 more minutes", "until 3 Dec, 14:00", "until you sign it out".
    static func describe(_ expiresAt: Date?, now: Date) -> String {
        guard let expiresAt else { return "Signed in until you sign it out" }
        let left = expiresAt.timeIntervalSince(now)
        if left <= 0 { return "Signed out" }
        if left < 60 * 60 { return "Signs out in \(max(1, Int(left / 60))) min" }
        return "Signs out \(expiresAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
