using System.Security.Cryptography;
using System.Text;

namespace Clipboard2.Core.Sync;

/// <summary>The two keys derived from the password (docs/sync/PROTOCOL.md → Password-derived keys).</summary>
public sealed record PasswordKeys(byte[] AuthKey, byte[] WrapKey);

/// <summary>A P-256 key pair: raw 32-byte scalar and 65-byte X9.63 uncompressed public key.</summary>
public sealed record EcKeyPair(byte[] Private, byte[] Public);

/// <summary>The client crypto from docs/sync/PROTOCOL.md, BCL only. Pinned by docs/sync/test-vectors.json.</summary>
public static class SyncCrypto
{
    public const byte AeadVersion = 0x01;
    public const int NonceSize = 12, TagSize = 16, KeySize = 32;
    public const int KdfIterations = 600_000;
    /// <summary>A prelogin outside these bounds is refused before deriving (a hostile server could otherwise ask for
    /// a cheap KDF, or one that ties the PC up).</summary>
    public const int MinKdfIterations = 600_000, MaxKdfIterations = 10_000_000;
    public const int SaltSize = 16;

    // MARK: AEAD

    /// <summary>AES-256-GCM: <c>0x01 ‖ nonce(12) ‖ ciphertext ‖ tag(16)</c>.</summary>
    public static byte[] Seal(byte[] key, byte[] plaintext, string aad, byte[]? nonce = null)
    {
        nonce ??= RandomNumberGenerator.GetBytes(NonceSize);
        if (nonce.Length != NonceSize) throw new ArgumentException("Nonce must be 12 bytes", nameof(nonce));
        var output = new byte[1 + NonceSize + plaintext.Length + TagSize];
        output[0] = AeadVersion;
        nonce.CopyTo(output, 1);
        using var gcm = new AesGcm(key, TagSize);
        gcm.Encrypt(nonce, plaintext, output.AsSpan(1 + NonceSize, plaintext.Length),
            output.AsSpan(1 + NonceSize + plaintext.Length, TagSize), Encoding.UTF8.GetBytes(aad));
        return output;
    }

    /// <summary>Throws <see cref="CryptographicException"/> on a wrong key, AAD, version or a tampered value.</summary>
    public static byte[] Open(byte[] key, byte[] sealedValue, string aad)
    {
        if (sealedValue.Length < 1 + NonceSize + TagSize || sealedValue[0] != AeadVersion)
            throw new CryptographicException("Bad AEAD envelope");
        var cipherLength = sealedValue.Length - 1 - NonceSize - TagSize;
        var plaintext = new byte[cipherLength];
        using var gcm = new AesGcm(key, TagSize);
        gcm.Decrypt(sealedValue.AsSpan(1, NonceSize), sealedValue.AsSpan(1 + NonceSize, cipherLength),
            sealedValue.AsSpan(sealedValue.Length - TagSize), plaintext, Encoding.UTF8.GetBytes(aad));
        return plaintext;
    }

    // MARK: Key derivation

    public static byte[] Hkdf(byte[] ikm, byte[] salt, string info) =>
        HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, KeySize, salt, Encoding.UTF8.GetBytes(info));

    /// <summary>PBKDF2-HMAC-SHA256 over the NFC-normalised password: the master key.</summary>
    public static byte[] Pbkdf2(string password, byte[] salt, int iterations) =>
        Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password.Normalize(NormalizationForm.FormC)), salt, iterations,
            HashAlgorithmName.SHA256, KeySize);

    /// <summary>authKey (sent to log in) and wrapKey (never leaves the device) from the password.</summary>
    public static PasswordKeys DerivePasswordKeys(string password, byte[] salt, int iterations)
    {
        var master = Pbkdf2(password, salt, iterations);
        return new PasswordKeys(Hkdf(master, [], "clipboard2 auth"), Hkdf(master, [], "clipboard2 wrap"));
    }

    /// <summary>Emails are trimmed and lowercased before every use.</summary>
    public static string NormalizeEmail(string email) => email.Trim().ToLowerInvariant();

    public static byte[] RandomKey() => RandomNumberGenerator.GetBytes(KeySize);
    public static byte[] RandomSalt() => RandomNumberGenerator.GetBytes(SaltSize);

    // MARK: P-256

    public static EcKeyPair GenerateKeyPair()
    {
        using var ec = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        var p = ec.ExportParameters(includePrivateParameters: true);
        return new EcKeyPair(Pad(p.D!), Encode(p.Q));
    }

    /// <summary>Raw 32-byte X coordinate of own.priv · peerPublic. Both halves of <paramref name="own"/> are imported,
    /// so no platform has to derive the public point from the scalar.</summary>
    public static byte[] Ecdh(EcKeyPair own, byte[] peerPublic)
    {
        using var mine = ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            D = own.Private,
            Q = Decode(own.Public),
        });
        using var peer = ECDiffieHellman.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, Q = Decode(peerPublic) });
        return mine.DeriveRawSecretAgreement(peer.PublicKey);
    }

    /// <summary>True when <paramref name="pair"/> is a valid P-256 key pair whose halves belong together.</summary>
    public static bool IsValidPair(EcKeyPair pair)
    {
        try
        {
            var probe = GenerateKeyPair();
            return Ecdh(pair, probe.Public).AsSpan().SequenceEqual(Ecdh(probe, pair.Public));
        }
        catch (CryptographicException) { return false; }
    }

    private static ECPoint Decode(byte[] x963)
    {
        if (x963.Length != 65 || x963[0] != 0x04) throw new CryptographicException("Expected a 65-byte uncompressed P-256 key");
        return new ECPoint { X = x963[1..33], Y = x963[33..65] };
    }

    private static byte[] Encode(ECPoint q) => [0x04, .. Pad(q.X!), .. Pad(q.Y!)];

    private static byte[] Pad(byte[] value) => value.Length >= 32 ? value : [.. new byte[32 - value.Length], .. value];

    // MARK: Protocol constructions

    public static class Aad
    {
        public static string AccountKey(string uid) => $"c2/ak/v1/{uid}";
        public static string PrivateKey(string uid) => $"c2/priv/v1/{uid}";
        public static string SpaceKey(string spaceId, string memberUid) => $"c2/space/v1/{spaceId}/{memberUid}";
        public static string Item(string spaceId, string itemId, string category) => $"c2/item/v1/{spaceId}/{itemId}/{category}";
        public static string Blob(string spaceId, string blobId) => $"c2/blob/v1/{spaceId}/{blobId}";
        public static string Name(string spaceId) => $"c2/name/v1/{spaceId}";
        public static string Invite(string spaceId) => $"c2/invite/v1/{spaceId}";
    }

    public static byte[] ItemKey(byte[] spaceKey) => Hkdf(spaceKey, [], "c2/item/v1");
    public static byte[] NameKey(byte[] spaceKey) => Hkdf(spaceKey, [], "c2/name/v1");

    /// <summary><c>eph.pub ‖ AEAD(HKDF(ECDH(eph, memberPub), eph.pub ‖ memberPub), SK)</c>.</summary>
    public static byte[] WrapSpaceKey(byte[] spaceKey, string spaceId, string memberUid, byte[] memberPublic,
                                      EcKeyPair? ephemeral = null, byte[]? nonce = null)
    {
        var eph = ephemeral ?? GenerateKeyPair();
        var wk = Hkdf(Ecdh(eph, memberPublic), [.. eph.Public, .. memberPublic], $"c2/space/v1/{spaceId}");
        return [.. eph.Public, .. Seal(wk, spaceKey, Aad.SpaceKey(spaceId, memberUid), nonce)];
    }

    public static byte[] UnwrapSpaceKey(byte[] wrapped, string spaceId, string myUid, EcKeyPair identity)
    {
        if (wrapped.Length < 65 + 1 + NonceSize + TagSize) throw new CryptographicException("Wrapped space key is too short");
        var ephPublic = wrapped[..65];
        var wk = Hkdf(Ecdh(identity, ephPublic), [.. ephPublic, .. identity.Public], $"c2/space/v1/{spaceId}");
        return Open(wk, wrapped[65..], Aad.SpaceKey(spaceId, myUid));
    }

    // MARK: Invite codes

    /// <summary>The invite id the server sees: hex SHA-256 of the code bytes.</summary>
    public static string InviteId(byte[] codeBytes) => Sha256Hex(codeBytes);
    public static byte[] InviteKey(byte[] codeBytes) => Hkdf(codeBytes, [], "clipboard2 invite");
    public static byte[] SealInvite(byte[] codeBytes, byte[] spaceKey, string spaceId, byte[]? nonce = null) =>
        Seal(InviteKey(codeBytes), spaceKey, Aad.Invite(spaceId), nonce);
    public static byte[] OpenInvite(byte[] codeBytes, byte[] sealedKey, string spaceId) =>
        Open(InviteKey(codeBytes), sealedKey, Aad.Invite(spaceId));

    public static byte[] Sha256(byte[] data) => SHA256.HashData(data);
    public static string Sha256Hex(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));
}

/// <summary>Invite codes: 16 random bytes as unpadded RFC 4648 base32, shown in groups of four.</summary>
public static class InviteCode
{
    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    public const int ByteLength = 16, CharLength = 26;

    public static byte[] Generate() => RandomNumberGenerator.GetBytes(ByteLength);

    /// <summary>XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX</summary>
    public static string Format(byte[] codeBytes)
    {
        var plain = Base32(codeBytes);
        return string.Join("-", Enumerable.Range(0, (plain.Length + 3) / 4).Select(i => plain.Substring(i * 4, Math.Min(4, plain.Length - i * 4))));
    }

    public static string Base32(byte[] bytes)
    {
        var sb = new StringBuilder();
        int buffer = 0, bits = 0;
        foreach (var b in bytes)
        {
            buffer = (buffer << 8) | b;
            bits += 8;
            while (bits >= 5)
            {
                sb.Append(Alphabet[(buffer >> (bits - 5)) & 31]);
                bits -= 5;
            }
        }
        if (bits > 0) sb.Append(Alphabet[(buffer << (5 - bits)) & 31]);
        return sb.ToString();
    }

    /// <summary>Lenient: ignores spaces, dashes and case, reads 0/1/8 as O/I/B. Null if it isn't a valid code.</summary>
    public static byte[]? Parse(string? typed)
    {
        if (typed is null) return null;
        var chars = typed.Where(c => !char.IsWhiteSpace(c) && c != '-').Select(char.ToUpperInvariant)
            .Select(c => c switch { '0' => 'O', '1' => 'I', '8' => 'B', _ => c }).ToArray();
        if (chars.Length != CharLength) return null;
        var output = new List<byte>(ByteLength);
        int buffer = 0, bits = 0;
        foreach (var c in chars)
        {
            var value = Alphabet.IndexOf(c);
            if (value < 0) return null;
            buffer = ((buffer << 5) | value) & 0xFFFF;
            bits += 5;
            if (bits >= 8)
            {
                output.Add((byte)(buffer >> (bits - 8)));
                bits -= 8;
            }
        }
        if (bits != 2 || (buffer & 0b11) != 0 || output.Count != ByteLength) return null;   // the last 2 bits must be zero
        return [.. output];
    }
}
