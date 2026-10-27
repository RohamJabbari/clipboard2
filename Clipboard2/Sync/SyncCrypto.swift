import Foundation
import CryptoKit
import CommonCrypto

nonisolated enum SyncCryptoError: Error, Equatable {
    case badEnvelope
    case badKey
    case kdfFailed
}

/// The client cryptography of docs/sync/PROTOCOL.md, byte-compatible with the Windows client and
/// `server/src/clientCrypto.ts` (pinned by docs/sync/test-vectors.json).
nonisolated enum SyncCrypto {
    static let aeadVersion: UInt8 = 0x01
    static let publicKeyLength = 65
    /// Bytes `seal` adds: version, nonce and tag.
    static let sealOverhead = 29

    // MARK: AEAD

    /// AES-256-GCM as `0x01 ‖ nonce(12) ‖ ciphertext ‖ tag(16)`. `nonce` is only for test vectors.
    static func seal(_ plaintext: Data, key: Data, aad: String, nonce: Data? = nil) throws -> Data {
        guard key.count == 32 else { throw SyncCryptoError.badKey }
        let gcmNonce = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: gcmNonce,
                                   authenticating: Data(aad.utf8))
        guard let combined = box.combined else { throw SyncCryptoError.badEnvelope }
        return Data([aeadVersion]) + combined
    }

    static func open(_ sealed: Data, key: Data, aad: String) throws -> Data {
        guard key.count == 32 else { throw SyncCryptoError.badKey }
        guard sealed.count >= 29, sealed.first == aeadVersion else { throw SyncCryptoError.badEnvelope }
        let box = try AES.GCM.SealedBox(combined: Data(sealed.dropFirst()))
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(aad.utf8))
    }

    // MARK: Key derivation

    /// HKDF-SHA256 with 32 bytes of output; an empty salt is a zero-length salt.
    static func hkdf(_ ikm: Data, salt: Data = Data(), info: String) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
                               info: Data(info.utf8), outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }

    /// PBKDF2-HMAC-SHA256 over the NFC-normalised password.
    static func kek(password: String, salt: Data, iterations: Int) throws -> Data {
        let passwordBytes = Data(password.precomposedStringWithCanonicalMapping.utf8)
        var output = Data(count: 32)
        let status = output.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                passwordBytes.withUnsafeBytes { pw in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw.baseAddress?.assumingMemoryBound(to: CChar.self), passwordBytes.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), 32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw SyncCryptoError.kdfFailed }
        return output
    }

    /// `master = PBKDF2(password)`, then `authKey` (sent to log in) and `wrapKey` (never leaves the
    /// device, wraps the account key) split from it with HKDF.
    nonisolated struct PasswordKeys: Sendable, Equatable {
        var master: Data
        var authKey: Data
        var wrapKey: Data
    }

    static func passwordKeys(password: String, salt: Data, iterations: Int) throws -> PasswordKeys {
        let master = try kek(password: password, salt: salt, iterations: iterations)
        return PasswordKeys(master: master,
                            authKey: hkdf(master, info: "clipboard2 auth"),
                            wrapKey: hkdf(master, info: "clipboard2 wrap"))
    }

    /// 600 000 iterations take a noticeable fraction of a second, so never on the main actor.
    @concurrent
    static func derivePasswordKeys(password: String, salt: Data, iterations: Int) async throws -> PasswordKeys {
        try passwordKeys(password: password, salt: salt, iterations: iterations)
    }

    // MARK: P-256

    static func newPrivateKey() -> Data {
        P256.KeyAgreement.PrivateKey().rawRepresentation
    }

    /// X9.63 uncompressed public key (65 bytes) for a raw 32-byte private scalar.
    static func publicKey(of privateKey: Data) throws -> Data {
        do {
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.x963Representation
        } catch {
            throw SyncCryptoError.badKey
        }
    }

    /// The raw X coordinate of the shared point.
    static func ecdh(privateKey: Data, publicKey: Data) throws -> Data {
        do {
            let priv = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
            let pub = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
            return try priv.sharedSecretFromKeyAgreement(with: pub).withUnsafeBytes { Data($0) }
        } catch {
            throw SyncCryptoError.badKey
        }
    }

    // MARK: Protocol constructions

    nonisolated enum AAD {
        static func accountKey(uid: String) -> String { "c2/ak/v1/\(uid)" }
        static func privateKey(uid: String) -> String { "c2/priv/v1/\(uid)" }
        static func spaceKey(spaceId: String, memberUid: String) -> String { "c2/space/v1/\(spaceId)/\(memberUid)" }
        static func item(spaceId: String, itemId: String, category: String) -> String {
            "c2/item/v1/\(spaceId)/\(itemId)/\(category)"
        }
        static func blob(spaceId: String, blobId: String) -> String { "c2/blob/v1/\(spaceId)/\(blobId)" }
        static func name(spaceId: String) -> String { "c2/name/v1/\(spaceId)" }
        static func invite(spaceId: String) -> String { "c2/invite/v1/\(spaceId)" }
    }

    /// `ephPub ‖ AEAD(wk, SK)` where wk comes from ECDH between a fresh key and the member's key.
    static func wrapSpaceKey(_ spaceKey: Data, spaceId: String, memberUid: String, memberPublicKey: Data,
                             ephemeralPrivateKey: Data? = nil, nonce: Data? = nil) throws -> Data {
        let ephPriv = ephemeralPrivateKey ?? newPrivateKey()
        let ephPub = try publicKey(of: ephPriv)
        let wk = hkdf(try ecdh(privateKey: ephPriv, publicKey: memberPublicKey),
                      salt: ephPub + memberPublicKey, info: "c2/space/v1/\(spaceId)")
        return ephPub + (try seal(spaceKey, key: wk, aad: AAD.spaceKey(spaceId: spaceId, memberUid: memberUid), nonce: nonce))
    }

    static func unwrapSpaceKey(_ wrapped: Data, spaceId: String, uid: String, privateKey: Data) throws -> Data {
        guard wrapped.count > publicKeyLength else { throw SyncCryptoError.badEnvelope }
        let ephPub = Data(wrapped.prefix(publicKeyLength))
        let myPub = try publicKey(of: privateKey)
        let wk = hkdf(try ecdh(privateKey: privateKey, publicKey: ephPub),
                      salt: ephPub + myPub, info: "c2/space/v1/\(spaceId)")
        return try open(Data(wrapped.dropFirst(publicKeyLength)), key: wk,
                        aad: AAD.spaceKey(spaceId: spaceId, memberUid: uid))
    }

    static func itemKey(spaceKey: Data) -> Data { hkdf(spaceKey, info: "c2/item/v1") }
    static func nameKey(spaceKey: Data) -> Data { hkdf(spaceKey, info: "c2/name/v1") }

    static func encryptGroupName(_ name: String, spaceKey: Data, spaceId: String, nonce: Data? = nil) throws -> Data {
        try seal(Data(name.utf8), key: nameKey(spaceKey: spaceKey), aad: AAD.name(spaceId: spaceId), nonce: nonce)
    }

    static func decryptGroupName(_ sealed: Data, spaceKey: Data, spaceId: String) throws -> String {
        let data = try open(sealed, key: nameKey(spaceKey: spaceKey), aad: AAD.name(spaceId: spaceId))
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Invite codes

    /// 16 random bytes shown as base32 in groups of four (`XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX`). The
    /// server only sees `inviteId`; the code itself opens the sealed space key.
    nonisolated enum Invite {
        static let codeLength = 16
        private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

        static func newCode() -> Data { randomBytes(codeLength) }

        static func format(_ code: Data) -> String {
            var bits = 0, value = 0
            var chars: [Character] = []
            for byte in code {
                value = (value << 8) | Int(byte)
                bits += 8
                while bits >= 5 {
                    chars.append(alphabet[(value >> (bits - 5)) & 31])
                    bits -= 5
                }
            }
            if bits > 0 { chars.append(alphabet[(value << (5 - bits)) & 31]) }
            return stride(from: 0, to: chars.count, by: 4)
                .map { String(chars[$0..<min($0 + 4, chars.count)]) }
                .joined(separator: "-")
        }

        /// Spaces and dashes removed, uppercased, 0/1/8 read as O/I/B.
        static func clean(_ typed: String) -> [Character] {
            typed.uppercased().filter { !$0.isWhitespace && $0 != "-" }.map { (c: Character) -> Character in
                switch c {
                case "0": "O"
                case "1": "I"
                case "8": "B"
                default: c
                }
            }
        }

        /// A sign-up code (80 server-made bits, `XXXX-XXXX-XXXX-XXXX`) normalised the same way
        /// as group codes: 16 characters of the alphabet, no dashes. nil if it isn't one.
        static func normalizeSignupCode(_ typed: String) -> String? {
            let cleaned = clean(typed)
            guard cleaned.count == 16, cleaned.allSatisfy(alphabet.contains) else { return nil }
            return String(cleaned)
        }

        /// Lenient: ignores spaces, dashes and case, and reads 0/1/8 as O/I/B. nil if it isn't a code.
        static func parse(_ typed: String) -> Data? {
            let cleaned = clean(typed)
            guard cleaned.count == 26 else { return nil }
            var bits = 0, value = 0
            var bytes = Data()
            for char in cleaned {
                guard let index = alphabet.firstIndex(of: char) else { return nil }
                value = (value << 5) | index
                bits += 5
                if bits >= 8 {
                    bytes.append(UInt8((value >> (bits - 8)) & 0xFF))
                    bits -= 8
                }
                value &= (1 << bits) - 1
            }
            guard bytes.count == codeLength, value == 0 else { return nil }   // the 2 spare bits must be zero
            return bytes
        }

        static func id(_ code: Data) -> String { sha256Hex(code) }
        static func key(_ code: Data) -> Data { hkdf(code, info: "clipboard2 invite") }

        static func sealSpaceKey(_ spaceKey: Data, code: Data, spaceId: String, nonce: Data? = nil) throws -> Data {
            try seal(spaceKey, key: key(code), aad: AAD.invite(spaceId: spaceId), nonce: nonce)
        }

        static func openSpaceKey(_ sealed: Data, code: Data, spaceId: String) throws -> Data {
            try open(sealed, key: key(code), aad: AAD.invite(spaceId: spaceId))
        }
    }

    // MARK: Helpers

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase hyphenated UUID, the protocol's id format.
    static func newID() -> String { UUID().uuidString.lowercased() }
}
