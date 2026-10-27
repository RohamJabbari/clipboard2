using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Clipboard2.Core.Sync;

public static class SyncCategory
{
    public const string History = "history", Pinned = "pinned", Snippet = "snippet", Secret = "secret";
    public static string ForClip(ClipItem item) => item.IsPinned ? Pinned : History;
}

/// <summary>A decrypted item payload (docs/sync/PROTOCOL.md → Item payloads).</summary>
public abstract record ItemPayload
{
    /// <summary>The <c>updatedAt</c> the writer sent with this payload; null from apps before October 2026.</summary>
    public long? Rev { get; init; }

    /// <param name="FileBlobs">A file item's uploaded files, in order; empty when none were sent.</param>
    public sealed record Clip(ClipItem Item, string? ImageBlob, string? ThumbBlob, IReadOnlyList<FileBlob> FileBlobs) : ItemPayload
    {
        /// <summary>The session id of the one device this was sent to, if any.</summary>
        public string? ToDevice { get; init; }
        /// <summary>The sending device's name, for the "Sent from …" notice.</summary>
        public string? FromDevice { get; init; }
    }
    public sealed record SnippetPayload(Snippet Snippet) : ItemPayload;
    public sealed record Secret(string Name, string Value, DateTime? CreatedAt) : ItemPayload;
}

/// <summary>One file of a file item, uploaded as an encrypted blob. <see cref="Size"/> is the plaintext byte count.</summary>
public sealed record FileBlob(string Name, string Blob, long Size);

/// <summary>Builds and parses the plaintext JSON inside an item, and its fingerprint.</summary>
public static partial class SyncPayload
{
    public const int Version = 1;

    private static readonly JsonSerializerOptions Compact = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    // MARK: Writing

    /// <summary>Writers omit nulls (and zero sizes / empty file lists). File items list their paths, plus the files
    /// that were uploaded as blobs.</summary>
    public static JsonObject ForClip(ClipItem item, string? imageBlob = null, string? thumbBlob = null, bool includeRichText = true,
                                     IReadOnlyList<FileBlob>? fileBlobs = null)
    {
        var rich = includeRichText && item.Kind == ClipKind.RichText && (item.Rtf is not null || item.Html is not null);
        var kind = item.Kind switch
        {
            ClipKind.RichText => rich ? "richText" : "text",
            ClipKind.Image => "image",
            ClipKind.File => "file",
            _ => "text",
        };
        var json = new JsonObject
        {
            ["v"] = Version,
            ["type"] = "clip",
            ["kind"] = kind,
            ["text"] = item.Text,
            ["preview"] = item.Preview,
        };
        if (rich && item.Rtf is { } rtf) json["rtf"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(rtf));
        if (rich && item.Html is { } html) json["html"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(CfHtml.Extract(html)));
        if (item.Files.Count > 0) json["files"] = new JsonArray([.. item.Files.Select(f => (JsonNode?)FileUrl(f))]);
        if (fileBlobs is { Count: > 0 })
            json["fileBlobs"] = new JsonArray([.. fileBlobs.Select(f => (JsonNode?)new JsonObject { ["name"] = f.Name, ["blob"] = f.Blob, ["size"] = f.Size })]);
        if (imageBlob is not null) json["imageBlob"] = imageBlob;
        if (thumbBlob is not null) json["thumbBlob"] = thumbBlob;
        if (item.ImageWidth > 0) json["imageWidth"] = item.ImageWidth;
        if (item.ImageHeight > 0) json["imageHeight"] = item.ImageHeight;
        if (item.ByteCount > 0) json["byteCount"] = item.ByteCount;
        if (item.SourceId is { } sid) json["sourceId"] = sid;
        if (item.SourceName is { } sname) json["sourceName"] = sname;
        json["isPinned"] = item.IsPinned;
        if (item.PinnedAt is { } pinnedAt) json["pinnedAt"] = Millis(pinnedAt);
        if (item.Label is { } label) json["label"] = label;
        json["copyCount"] = item.CopyCount;
        json["createdAt"] = Millis(item.CreatedAt);
        json["lastCopiedAt"] = Millis(item.LastCopiedAt);
        json["contentHash"] = item.ContentHash;
        return json;
    }

    public static JsonObject ForSnippet(Snippet snippet) => new()
    {
        ["v"] = Version,
        ["type"] = "snippet",
        ["name"] = snippet.Name,
        ["keyword"] = snippet.Keyword,
        ["body"] = snippet.Body,
        ["createdAt"] = Millis(snippet.CreatedAt),
        ["updatedAt"] = Millis(snippet.UpdatedAt),
    };

    public static JsonObject ForSecret(string name, string value, DateTime? createdAt)
    {
        var json = new JsonObject { ["v"] = Version, ["type"] = "secret", ["name"] = name, ["value"] = value };
        json["createdAt"] = Millis(createdAt ?? DateTime.UtcNow);
        return json;
    }

    public static byte[] Encode(JsonObject payload) => Encoding.UTF8.GetBytes(Json(payload));

    /// <summary>Compact JSON with non-ASCII written as UTF-8, emoji included (the BCL encoders escape surrogate pairs).</summary>
    private static string Json(JsonNode node) => SurrogateEscape().Replace(node.ToJsonString(Compact), m =>
        m.Groups[1].Value + char.ConvertFromUtf32(char.ConvertToUtf32((char)Convert.ToInt32(m.Groups[2].Value, 16), (char)Convert.ToInt32(m.Groups[3].Value, 16))));

    [System.Text.RegularExpressions.GeneratedRegex(@"(?<!\\)((?:\\\\)*)\\u(D[89AB][0-9A-F]{2})\\u(D[C-F][0-9A-F]{2})", System.Text.RegularExpressions.RegexOptions.IgnoreCase)]
    private static partial System.Text.RegularExpressions.Regex SurrogateEscape();

    /// <summary>Fields that describe one write rather than the item: they never count as a change.</summary>
    public static readonly string[] WriteFields = ["rev", "toDevice", "fromDevice"];

    /// <summary>SHA-256 of the payload with keys sorted. A secret's createdAt is left out: Credential Manager only
    /// knows the last write time, which every apply bumps. So are <see cref="WriteFields"/>.</summary>
    public static string Fingerprint(JsonObject payload)
    {
        var canonical = Canonical(payload)!.AsObject();
        if (canonical["type"]?.GetValue<string>() == "secret") canonical.Remove("createdAt");
        foreach (var field in WriteFields) canonical.Remove(field);
        return SyncCrypto.Sha256Hex(Encoding.UTF8.GetBytes(Json(canonical)));
    }

    private static JsonNode? Canonical(JsonNode? node) => node switch
    {
        JsonObject o => new JsonObject(o.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => KeyValuePair.Create(p.Key, Canonical(p.Value)))),
        JsonArray a => new JsonArray([.. a.Select(Canonical)]),
        null => null,
        _ => node.DeepClone(),
    };

    // MARK: Reading

    /// <summary>Parses a decrypted payload. Unknown fields are ignored; unknown types return null.</summary>
    public static ItemPayload? Parse(byte[] plaintext, Guid id, string? spaceId) =>
        JsonNode.Parse(plaintext) is JsonObject json ? Parse(json, id, spaceId) : null;

    public static ItemPayload? Parse(JsonObject json, Guid id, string? spaceId)
    {
        var payload = ParseBody(json, id, spaceId);
        return payload is null ? null : payload with { Rev = json["rev"] is JsonValue r && r.TryGetValue<double>(out var rev) ? (long)rev : null };
    }

    private static ItemPayload? ParseBody(JsonObject json, Guid id, string? spaceId)
    {
        switch (Str(json, "type"))
        {
            case "clip":
                var kind = Str(json, "kind") switch
                {
                    "richText" => ClipKind.RichText,
                    "image" => ClipKind.Image,
                    _ => ClipKind.Text,   // "file": text, until the sync engine has written its fileBlobs to disk
                };
                var text = Str(json, "text") ?? "";
                if (Str(json, "kind") == "file" && text.Length == 0)
                    text = string.Join("\n", (json["files"] as JsonArray ?? []).Select(f => LocalPath(f?.GetValue<string>() ?? "")));
                var rtf = Bytes(json, "rtf") is { } r ? Encoding.UTF8.GetString(r) : null;
                var html = Bytes(json, "html") is { } h ? CfHtml.Wrap(Encoding.UTF8.GetString(h)) : null;
                if (kind == ClipKind.RichText && rtf is null && html is null) kind = ClipKind.Text;
                var created = Time(json, "createdAt") ?? DateTime.UtcNow;
                var item = new ClipItem
                {
                    Id = id,
                    SpaceId = spaceId,
                    Kind = kind,
                    Text = text,
                    Preview = Str(json, "preview") ?? TextPreview.Make(text),
                    Rtf = kind == ClipKind.RichText ? rtf : null,
                    Html = kind == ClipKind.RichText ? html : null,
                    ContentHash = Str(json, "contentHash") ?? ContentHasher.HashText(text),
                    ImageWidth = Int(json, "imageWidth"),
                    ImageHeight = Int(json, "imageHeight"),
                    ByteCount = json["byteCount"] is JsonValue bc ? bc.GetValue<long>() : 0,
                    SourceId = Str(json, "sourceId"),
                    SourceName = Str(json, "sourceName"),
                    IsPinned = json["isPinned"] is JsonValue p && p.GetValue<bool>(),
                    PinnedAt = Time(json, "pinnedAt"),
                    Label = Str(json, "label"),
                    CopyCount = Math.Max(1, Int(json, "copyCount")),
                    CreatedAt = created,
                    LastCopiedAt = Time(json, "lastCopiedAt") ?? created,
                };
                return new ItemPayload.Clip(item, Str(json, "imageBlob"), Str(json, "thumbBlob"), FileBlobs(json))
                {
                    ToDevice = Str(json, "toDevice"),
                    FromDevice = Str(json, "fromDevice"),
                };
            case "snippet":
                return new ItemPayload.SnippetPayload(new Snippet
                {
                    Id = id,
                    SpaceId = spaceId,
                    Name = Str(json, "name") ?? "Untitled Snippet",
                    Keyword = Str(json, "keyword") ?? "",
                    Body = Str(json, "body") ?? "",
                    CreatedAt = Time(json, "createdAt") ?? DateTime.UtcNow,
                    UpdatedAt = Time(json, "updatedAt") ?? Time(json, "createdAt") ?? DateTime.UtcNow,
                });
            case "secret":
                return new ItemPayload.Secret(Str(json, "name") ?? "Untitled", Str(json, "value") ?? "", Time(json, "createdAt"));
            default:
                return null;
        }
    }

    // MARK: Helpers

    public static long Millis(DateTime t) => new DateTimeOffset(DateTime.SpecifyKind(t, DateTimeKind.Utc)).ToUnixTimeMilliseconds();
    public static DateTime FromMillis(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime;

    private static string? Str(JsonObject json, string key) =>
        json[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    private static int Int(JsonObject json, string key) =>
        json[key] is JsonValue v && v.TryGetValue<double>(out var d) ? (int)d : 0;

    private static DateTime? Time(JsonObject json, string key) =>
        json[key] is JsonValue v && v.TryGetValue<double>(out var d) ? FromMillis((long)d) : null;

    private static byte[]? Bytes(JsonObject json, string key)
    {
        if (Str(json, key) is not { } b64) return null;
        try { return Convert.FromBase64String(b64); } catch (FormatException) { return null; }
    }

    private static List<FileBlob> FileBlobs(JsonObject json)
    {
        if (Str(json, "kind") != "file" || json["fileBlobs"] is not JsonArray array) return [];
        var list = new List<FileBlob>();
        foreach (var entry in array.OfType<JsonObject>())
        {
            if (Str(entry, "name") is not { } name || Str(entry, "blob") is not { } blob) continue;
            list.Add(new FileBlob(name, blob, entry["size"] is JsonValue v && v.TryGetValue<double>(out var d) ? (long)d : 0));
        }
        return list;
    }

    private static string FileUrl(string path)
    {
        if (path.StartsWith("file:", StringComparison.OrdinalIgnoreCase)) return path;
        return Uri.TryCreate(path, UriKind.Absolute, out var uri) && uri.IsFile ? uri.AbsoluteUri : path;
    }

    private static string LocalPath(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.IsFile ? uri.LocalPath : url;
}

/// <summary>Windows' CF_HTML clipboard format wraps HTML in a header with byte offsets; other platforms sync plain HTML.</summary>
public static class CfHtml
{
    private const string HeaderTemplate = "Version:0.9\r\nStartHTML:{0:D10}\r\nEndHTML:{1:D10}\r\nStartFragment:{2:D10}\r\nEndFragment:{3:D10}\r\n";

    /// <summary>The HTML inside a CF_HTML string (StartHTML…EndHTML), or the input when it has no header.</summary>
    public static string Extract(string value)
    {
        if (!value.StartsWith("Version:", StringComparison.Ordinal)) return value;
        var start = Offset(value, "StartHTML:");
        var end = Offset(value, "EndHTML:");
        if (start < 0) { start = Offset(value, "StartFragment:"); end = Offset(value, "EndFragment:"); }
        var bytes = Encoding.UTF8.GetBytes(value);
        if (start < 0 || end < start || end > bytes.Length) return value;
        return Encoding.UTF8.GetString(bytes, start, end - start);
    }

    /// <summary>Wraps plain HTML for the Windows clipboard. <see cref="Extract"/> returns it unchanged.</summary>
    public static string Wrap(string html)
    {
        var headerLength = Encoding.UTF8.GetByteCount(string.Format(HeaderTemplate, 0, 0, 0, 0));
        var htmlBytes = Encoding.UTF8.GetByteCount(html);
        var fragmentStart = headerLength;
        var fragmentEnd = headerLength + htmlBytes;
        const string startMarker = "<!--StartFragment-->", endMarker = "<!--EndFragment-->";
        var s = html.IndexOf(startMarker, StringComparison.Ordinal);
        var e = html.IndexOf(endMarker, StringComparison.Ordinal);
        if (s >= 0 && e > s)
        {
            fragmentStart = headerLength + Encoding.UTF8.GetByteCount(html[..(s + startMarker.Length)]);
            fragmentEnd = headerLength + Encoding.UTF8.GetByteCount(html[..e]);
        }
        return string.Format(HeaderTemplate, headerLength, headerLength + htmlBytes, fragmentStart, fragmentEnd) + html;
    }

    private static int Offset(string value, string key)
    {
        var i = value.IndexOf(key, StringComparison.Ordinal);
        if (i < 0) return -1;
        var j = i + key.Length;
        var k = j;
        while (k < value.Length && char.IsDigit(value[k])) k++;
        return int.TryParse(value.AsSpan(j, k - j), out var n) ? n : -1;
    }
}
