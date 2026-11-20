using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Clipboard2.Core.Sync;

namespace Clipboard2.Core;

public enum OtpAlgorithm { SHA1, SHA256, SHA512 }

/// <summary>A TOTP account (docs/features/authenticator.md). <see cref="Secret"/> is base32 without padding and never
/// leaves the protected store except to compute codes, to sync to this user's own devices, for Show Secret (after
/// Windows Hello) and for backups with secrets.</summary>
/// <param name="Id">Lowercase hyphenated UUID: the sync item id.</param>
/// <param name="SpaceId">Its authenticator space on the server, or null until the first sync creates one (and always
/// while signed out).</param>
/// <param name="Shares">Who it's shared with, as the server last said (local only, never in the payload).</param>
public sealed record Authenticator(string Id, string Issuer, string Account, string Secret, OtpAlgorithm Algorithm, int Digits, int Period,
                                   DateTime CreatedAt, DateTime UpdatedAt, string? SpaceId = null, IReadOnlyList<OtpShare>? Shares = null)
{
    public IReadOnlyList<OtpShare> People => Shares ?? [];

    public const int DefaultDigits = 6, DefaultPeriod = 30;

    public string Title => Issuer.Length > 0 ? Issuer : Account.Length > 0 ? Account : "Authenticator";
    public string Subtitle => Issuer.Length > 0 ? Account : "";

    public string Code(DateTime now) => Totp.Code(Base32.Decode(Secret) ?? [], Algorithm, Digits, Period, now);

    /// <summary>Seconds until the code changes (1…<see cref="Period"/>), fractional.</summary>
    public double SecondsLeft(DateTime now) => Totp.SecondsLeft(Period, now);

    /// <summary>Same account and seed, whatever the id: an import or a re-sync of the same authenticator.</summary>
    public bool SameAs(Authenticator other) =>
        Issuer == other.Issuer && Account == other.Account && Base32.Normalize(Secret) == Base32.Normalize(other.Secret);
}

/// <summary>Someone an authenticator is shared with, and until when they have codes (UTC).</summary>
public sealed record OtpShare(string Uid, string Name, DateTime CodesUntil);

/// <summary>An authenticator someone shared with this user: pre-computed codes only, never the seed.</summary>
/// <param name="From">Unix seconds at the start of the first code's step.</param>
public sealed record SharedAuthenticator(string SpaceId, string OwnerUid, string OwnerName, string Issuer, string Account, int Digits, int Period,
                                         long From, IReadOnlyList<string> Codes, DateTime ReceivedAt)
{
    public const double LowHours = 2;

    public string Title => Issuer.Length > 0 ? Issuer : Account.Length > 0 ? Account : "Authenticator";

    /// <summary>When the last code expires (UTC); <see cref="From"/> when there are none.</summary>
    public DateTime CodesUntil => DateTimeOffset.FromUnixTimeSeconds(From + (long)Codes.Count * Math.Max(1, Period)).UtcDateTime;

    /// <summary>The code for <paramref name="now"/>, or null when the batch doesn't cover it.</summary>
    public string? Code(DateTime now)
    {
        if (Codes.Count == 0) return null;
        var seconds = new DateTimeOffset(DateTime.SpecifyKind(now, DateTimeKind.Utc)).ToUnixTimeSeconds();
        if (seconds < From) return null;
        var step = (seconds - From) / Math.Max(1, Period);
        return step < Codes.Count ? Codes[(int)step] : null;
    }

    public double SecondsLeft(DateTime now) => Totp.SecondsLeft(Period, now);
    public bool IsOut(DateTime now) => Code(now) is null;
    public bool IsLow(DateTime now) => !IsOut(now) && CodesUntil - now < TimeSpan.FromHours(LowHours);

    /// <summary>The row's subtitle: who shared it, how long its codes last, or that they ran out.</summary>
    public string Status(DateTime now) =>
        IsOut(now) ? $"No codes, {OwnerName}'s devices have been offline"
        : IsLow(now) ? $"Codes until {CodesUntil.ToLocalTime():t}"
        : $"Shared by {OwnerName}";
}

/// <summary>The sealed codes JSON of docs/sync/PROTOCOL.md → Authenticators.</summary>
public static class OtpCodeBatch
{
    public static readonly TimeSpan Length = TimeSpan.FromHours(24);
    public static readonly TimeSpan TopUpBelow = TimeSpan.FromHours(12);
    /// <summary>Keeps a batch under the server's 64 KiB for short periods.</summary>
    public const int MaxCodes = 4000;

    /// <summary>The codes from the current step for 24 hours, and when they end.</summary>
    public static (JsonObject Json, DateTime CodesUntil) Build(Authenticator a, DateTime now)
    {
        var key = Base32.Decode(a.Secret) ?? [];
        var period = Math.Max(1, a.Period);
        var seconds = new DateTimeOffset(DateTime.SpecifyKind(now, DateTimeKind.Utc)).ToUnixTimeSeconds();
        var from = seconds / period * period;
        var count = Math.Min(MaxCodes, (int)Math.Ceiling(Length.TotalSeconds / period));
        var codes = new JsonArray();
        for (var i = 0; i < count; i++) codes.Add(Totp.Code(key, a.Algorithm, a.Digits, period, from + (long)i * period));
        var json = new JsonObject
        {
            ["v"] = 1, ["issuer"] = a.Issuer, ["account"] = a.Account, ["digits"] = a.Digits, ["period"] = period, ["from"] = from, ["codes"] = codes,
        };
        return (json, DateTimeOffset.FromUnixTimeSeconds(from + (long)count * period).UtcDateTime);
    }

    /// <summary>Reads an opened batch; null when it isn't one.</summary>
    public static SharedAuthenticator? Parse(JsonObject json, string spaceId, string ownerUid, string ownerName, DateTime receivedAt)
    {
        if (json["codes"] is not JsonArray array) return null;
        var codes = array.Select(c => c is JsonValue v && v.TryGetValue<string>(out var s) ? s : null).ToList();
        if (codes.Any(c => c is null)) return null;
        int Int(string k, int fallback) => Num(json[k]) is { } d ? (int)d : fallback;
        string Str(string k) => json[k] is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";
        var from = Num(json["from"]) is { } fd ? (long)fd : 0;
        return new SharedAuthenticator(spaceId, ownerUid, ownerName, Str("issuer"), Str("account"), Int("digits", 6), Math.Max(1, Int("period", 30)),
            from, [.. codes.OfType<string>()], receivedAt);
    }

    /// <summary>A JSON number, whether parsed or built in memory (an in-memory int doesn't read as double).</summary>
    internal static double? Num(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() == System.Text.Json.JsonValueKind.Number
        && double.TryParse(v.ToJsonString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : null;

    /// <summary>A share with no codes yet (just transferred, or never topped up).</summary>
    public static SharedAuthenticator Empty(string spaceId, string ownerUid, string ownerName, DateTime receivedAt) =>
        new(spaceId, ownerUid, ownerName, "", "", 6, 30, 0, [], receivedAt);
}

/// <summary>RFC 4648 base32. Decoding is lenient: spaces, dashes, lower case and missing padding are fine.</summary>
public static class Base32
{
    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    /// <summary>Upper case without spaces, dashes or padding.</summary>
    public static string Normalize(string text) =>
        new([.. text.Where(c => !char.IsWhiteSpace(c) && c != '-' && c != '=').Select(char.ToUpperInvariant)]);

    /// <summary>The bytes, or null when it isn't base32 (or is empty).</summary>
    public static byte[]? Decode(string text)
    {
        var clean = Normalize(text);
        if (clean.Length == 0) return null;
        var bytes = new List<byte>(clean.Length * 5 / 8);
        int buffer = 0, bits = 0;
        foreach (var c in clean)
        {
            var value = Alphabet.IndexOf(c);
            if (value < 0) return null;
            buffer = (buffer << 5) | value;
            bits += 5;
            if (bits >= 8)
            {
                bits -= 8;
                bytes.Add((byte)(buffer >> bits));
                buffer &= (1 << bits) - 1;
            }
        }
        return bytes.Count == 0 ? null : [.. bytes];
    }

    /// <summary>Without padding.</summary>
    public static string Encode(byte[] data)
    {
        var sb = new StringBuilder((data.Length * 8 + 4) / 5);
        int buffer = 0, bits = 0;
        foreach (var b in data)
        {
            buffer = (buffer << 8) | b;
            bits += 8;
            while (bits >= 5)
            {
                bits -= 5;
                sb.Append(Alphabet[(buffer >> bits) & 31]);
            }
            buffer &= (1 << bits) - 1;
        }
        if (bits > 0) sb.Append(Alphabet[(buffer << (5 - bits)) & 31]);
        return sb.ToString();
    }
}

/// <summary>RFC 6238 TOTP (and the RFC 4226 truncation under it).</summary>
public static class Totp
{
    public static string Code(byte[] key, OtpAlgorithm algorithm, int digits, int period, DateTime now) =>
        Code(key, algorithm, digits, period, new DateTimeOffset(DateTime.SpecifyKind(now, DateTimeKind.Utc)).ToUnixTimeSeconds());

    public static string Code(byte[] key, OtpAlgorithm algorithm, int digits, int period, long unixSeconds)
    {
        var counter = unixSeconds / Math.Max(1, period);
        Span<byte> message = stackalloc byte[8];
        System.Buffers.Binary.BinaryPrimitives.WriteInt64BigEndian(message, counter);
        var hash = algorithm switch
        {
            OtpAlgorithm.SHA256 => HMACSHA256.HashData(key, message),
            OtpAlgorithm.SHA512 => HMACSHA512.HashData(key, message),
            _ => HMACSHA1.HashData(key, message),
        };
        var offset = hash[^1] & 0x0F;
        var binary = ((hash[offset] & 0x7F) << 24) | (hash[offset + 1] << 16) | (hash[offset + 2] << 8) | hash[offset + 3];
        var modulo = (int)Math.Pow(10, digits);
        return (binary % modulo).ToString(new string('0', digits));
    }

    public static double SecondsLeft(int period, DateTime now)
    {
        var ms = new DateTimeOffset(DateTime.SpecifyKind(now, DateTimeKind.Utc)).ToUnixTimeMilliseconds();
        var periodMs = Math.Max(1, period) * 1000L;
        return (periodMs - ms % periodMs) / 1000.0;
    }

    /// <summary>"123 456", "1234 5678": two groups, the first one shorter for 7 digits.</summary>
    public static string Grouped(string code) => code.Length < 6 ? code : code[..(code.Length / 2)] + " " + code[(code.Length / 2)..];
}

/// <summary>What an <c>otpauth://totp/…</c> link describes, before it becomes an <see cref="Authenticator"/>.</summary>
public sealed record OtpAuthDraft(string Issuer, string Account, string Secret, OtpAlgorithm Algorithm = OtpAlgorithm.SHA1,
                                  int Digits = Authenticator.DefaultDigits, int Period = Authenticator.DefaultPeriod);

/// <summary>Parses and writes Key URI Format links (otpauth://totp/Issuer:account?secret=…&amp;issuer=…).</summary>
public static class OtpAuthUri
{
    public const string HotpNotSupported = "Counter-based (HOTP) codes aren't supported. Only time-based (TOTP) authenticators can be added.";

    /// <summary>Any otpauth link (TOTP, HOTP or broken): a secret, never history.</summary>
    public static bool IsOtpAuth(string? text) =>
        text is not null && text.TrimStart().StartsWith("otpauth://", StringComparison.OrdinalIgnoreCase);

    /// <summary>The draft, or null with <paramref name="error"/> saying why (HOTP, missing or broken secret…).</summary>
    public static OtpAuthDraft? Parse(string text, out string? error)
    {
        error = null;
        text = text.Trim();
        if (!IsOtpAuth(text) || !Uri.TryCreate(text, UriKind.Absolute, out var uri))
        {
            error = "That isn't an authenticator link.";
            return null;
        }
        var type = uri.Host.ToLowerInvariant();
        if (type == "hotp")
        {
            error = HotpNotSupported;
            return null;
        }
        if (type != "totp")
        {
            error = "That isn't an authenticator link.";
            return null;
        }
        var query = Query(uri.Query);
        var label = Uri.UnescapeDataString(uri.AbsolutePath.TrimStart('/'));
        string labelIssuer = "", account = label;
        if (label.IndexOf(':') is var colon and >= 0)
        {
            labelIssuer = label[..colon].Trim();
            account = label[(colon + 1)..];
        }
        account = account.Trim();
        var issuer = query.GetValueOrDefault("issuer") is { Length: > 0 } i ? i.Trim() : labelIssuer;
        var secret = Base32.Normalize(query.GetValueOrDefault("secret") ?? "");
        if (Base32.Decode(secret) is null)
        {
            error = "The link's secret is missing or isn't base32.";
            return null;
        }
        var algorithm = OtpAlgorithm.SHA1;
        if (query.GetValueOrDefault("algorithm") is { Length: > 0 } alg && !TryAlgorithm(alg, out algorithm))
        {
            error = $"The algorithm “{alg}” isn't supported.";
            return null;
        }
        var digits = Authenticator.DefaultDigits;
        if (query.GetValueOrDefault("digits") is { Length: > 0 } d && (!int.TryParse(d, out digits) || digits is < 6 or > 8))
        {
            error = "Codes must have 6 to 8 digits.";
            return null;
        }
        var period = Authenticator.DefaultPeriod;
        if (query.GetValueOrDefault("period") is { Length: > 0 } p && (!int.TryParse(p, out period) || period is < 1 or > 3600))
        {
            error = "The link's period isn't valid.";
            return null;
        }
        return new OtpAuthDraft(issuer, account, secret, algorithm, digits, period);
    }

    public static bool TryAlgorithm(string text, out OtpAlgorithm algorithm)
    {
        switch (text.Trim().ToUpperInvariant().Replace("-", ""))
        {
            case "SHA1": algorithm = OtpAlgorithm.SHA1; return true;
            case "SHA256": algorithm = OtpAlgorithm.SHA256; return true;
            case "SHA512": algorithm = OtpAlgorithm.SHA512; return true;
            default: algorithm = OtpAlgorithm.SHA1; return false;
        }
    }

    /// <summary>The link for moving an authenticator to a phone app (Show Secret / QR).</summary>
    public static string Format(Authenticator a)
    {
        var label = a.Issuer.Length > 0 ? Uri.EscapeDataString(a.Issuer) + ":" + Uri.EscapeDataString(a.Account) : Uri.EscapeDataString(a.Account);
        var text = $"otpauth://totp/{label}?secret={Base32.Normalize(a.Secret)}";
        if (a.Issuer.Length > 0) text += "&issuer=" + Uri.EscapeDataString(a.Issuer);
        if (a.Algorithm != OtpAlgorithm.SHA1) text += "&algorithm=" + a.Algorithm;
        if (a.Digits != Authenticator.DefaultDigits) text += "&digits=" + a.Digits;
        if (a.Period != Authenticator.DefaultPeriod) text += "&period=" + a.Period;
        return text;
    }

    private static Dictionary<string, string> Query(string query)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var part in query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = part.IndexOf('=');
            var key = Uri.UnescapeDataString((eq < 0 ? part : part[..eq]).Replace('+', ' '));
            var value = eq < 0 ? "" : Uri.UnescapeDataString(part[(eq + 1)..].Replace('+', ' '));
            map.TryAdd(key, value);
        }
        return map;
    }
}

/// <summary>What clipboard capture does with a copied text before it could become history.</summary>
public static class CaptureFilter
{
    /// <summary>False for anything that must never be stored: an otpauth link (it holds a 2FA seed).</summary>
    public static bool ShouldStore(ProcessedCapture capture) => !(capture.Kind.IsTextual() && OtpAuthUri.IsOtpAuth(capture.Text));
}

/// <summary>Strings kept encrypted at rest: Credential Manager on Windows (DPAPI), memory in tests.</summary>
public interface IProtectedStore
{
    IEnumerable<KeyValuePair<string, string>> All();
    bool Write(string key, string value);
    void Delete(string key);
}

public sealed class MemoryProtectedStore : IProtectedStore
{
    private readonly Dictionary<string, string> _values = [];
    public IEnumerable<KeyValuePair<string, string>> All() => [.. _values];
    public bool Write(string key, string value) { _values[key] = value; return true; }
    public void Delete(string key) => _values.Remove(key);
}

/// <summary>The user's authenticators: the otp payload plus id and space, one protected entry each.</summary>
public sealed class AuthenticatorStore
{
    private readonly IProtectedStore _backing;
    private readonly Func<DateTime> _now;
    private Dictionary<string, Authenticator> _all = [];
    private Dictionary<string, SharedAuthenticator> _shared = [];
    private const string SharedPrefix = "shared-";

    public AuthenticatorStore(IProtectedStore backing, Func<DateTime>? clock = null)
    {
        _backing = backing;
        _now = clock ?? (() => DateTime.UtcNow);
        Reload();
    }

    public event Action? Changed;

    /// <summary>Newest first.</summary>
    public IReadOnlyList<Authenticator> All => [.. _all.Values.OrderByDescending(a => a.CreatedAt).ThenBy(a => a.Id, StringComparer.Ordinal)];

    public Authenticator? Find(string id) => _all.GetValueOrDefault(id);
    public Authenticator? InSpace(string spaceId) => _all.Values.FirstOrDefault(a => a.SpaceId == spaceId);

    /// <summary>Shared with this user (codes only), newest share first.</summary>
    public IReadOnlyList<SharedAuthenticator> Shared => [.. _shared.Values.OrderByDescending(s => s.ReceivedAt).ThenBy(s => s.SpaceId, StringComparer.Ordinal)];
    public SharedAuthenticator? FindShared(string spaceId) => _shared.GetValueOrDefault(spaceId);

    public void PutShared(SharedAuthenticator shared)
    {
        var json = new JsonObject
        {
            ["spaceId"] = shared.SpaceId, ["ownerUid"] = shared.OwnerUid, ["ownerName"] = shared.OwnerName, ["issuer"] = shared.Issuer,
            ["account"] = shared.Account, ["digits"] = shared.Digits, ["period"] = shared.Period, ["from"] = shared.From,
            ["codes"] = new JsonArray([.. shared.Codes.Select(c => (JsonNode?)c)]), ["receivedAt"] = SyncPayload.Millis(shared.ReceivedAt),
        };
        if (!_backing.Write(SharedPrefix + shared.SpaceId, json.ToJsonString())) return;
        _shared[shared.SpaceId] = shared;
        Changed?.Invoke();
    }

    public void DeleteShared(string spaceId)
    {
        _backing.Delete(SharedPrefix + spaceId);
        if (_shared.Remove(spaceId)) Changed?.Invoke();
    }

    public void Reload()
    {
        var all = new Dictionary<string, Authenticator>();
        var shared = new Dictionary<string, SharedAuthenticator>();
        foreach (var (key, value) in _backing.All())
        {
            try
            {
                if (JsonNode.Parse(value) is not JsonObject json) continue;
                if (key.StartsWith(SharedPrefix, StringComparison.Ordinal))
                {
                    string Str(string k) => json[k] is JsonValue v && v.TryGetValue<string>(out var x) ? x : "";
                    var received = OtpCodeBatch.Num(json["receivedAt"]) is { } ms ? SyncPayload.FromMillis((long)ms) : DateTime.UtcNow;
                    if (OtpCodeBatch.Parse(json, Str("spaceId"), Str("ownerUid"), Str("ownerName"), received) is { SpaceId.Length: > 0 } s)
                        shared[s.SpaceId] = s;
                    continue;
                }
                if (Guid.TryParse(key, out var id) && SyncPayload.Parse(json, id, null) is ItemPayload.Otp { Authenticator: var a })
                    all[a.Id] = a with
                    {
                        SpaceId = json["spaceId"] is JsonValue sp && sp.TryGetValue<string>(out var space) ? space : null,
                        Shares = json["shares"] is JsonArray people ? [.. people.OfType<JsonObject>().Select(p => new OtpShare(
                            p["uid"]?.GetValue<string>() ?? "", p["name"]?.GetValue<string>() ?? "",
                            SyncPayload.FromMillis((long)(OtpCodeBatch.Num(p["codesUntil"]) ?? 0))))] : null,
                    };
            }
            catch (Exception ex) when (ex is System.Text.Json.JsonException or InvalidOperationException or FormatException) { }
        }
        _all = all;
        _shared = shared;
    }

    /// <summary>A new authenticator of this user, or null when the secret isn't base32 or it couldn't be stored.</summary>
    public Authenticator? Add(string issuer, string account, string secret, OtpAlgorithm algorithm = OtpAlgorithm.SHA1,
                              int digits = Authenticator.DefaultDigits, int period = Authenticator.DefaultPeriod)
    {
        var normalized = Base32.Normalize(secret);
        if (Base32.Decode(normalized) is null || digits is < 6 or > 8 || period < 1) return null;
        var now = _now();
        var a = new Authenticator(Guid.NewGuid().ToString("D"), issuer.Trim(), account.Trim(), normalized, algorithm, digits, period, now, now);
        return Put(a) ? a : null;
    }

    public Authenticator? Rename(Authenticator a, string issuer, string account)
    {
        var renamed = a with { Issuer = issuer.Trim(), Account = account.Trim(), UpdatedAt = Max(_now(), a.UpdatedAt.AddMilliseconds(1)) };
        return Put(renamed) ? renamed : null;
    }

    /// <summary>Creates or replaces one (as is: sync and import keep its times).</summary>
    public bool Put(Authenticator a)
    {
        var json = SyncPayload.ForOtp(a);
        if (a.SpaceId is { } space) json["spaceId"] = space;
        if (a.Shares is { } shares)
            json["shares"] = new JsonArray([.. shares.Select(p => (JsonNode?)new JsonObject
                { ["uid"] = p.Uid, ["name"] = p.Name, ["codesUntil"] = SyncPayload.Millis(p.CodesUntil) })]);
        if (!_backing.Write(a.Id, json.ToJsonString())) return false;
        _all[a.Id] = a;
        Changed?.Invoke();
        return true;
    }

    public void Delete(string id)
    {
        _backing.Delete(id);
        if (_all.Remove(id)) Changed?.Invoke();
    }

    private static DateTime Max(DateTime a, DateTime b) => a > b ? a : b;
}
