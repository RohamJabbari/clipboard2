namespace Clipboard2.Core;

public enum ClipKind { Text = 0, RichText = 1, Image = 2, File = 3 }

public static class ClipKindExtensions
{
    public static bool IsTextual(this ClipKind kind) => kind is ClipKind.Text or ClipKind.RichText;

    public static string DisplayName(this ClipKind kind) => kind switch
    {
        ClipKind.Text => "Text",
        ClipKind.RichText => "Rich Text",
        ClipKind.Image => "Image",
        _ => "File",
    };
}

/// <summary>An app on this PC. <see cref="Id"/> is the lower-case executable name ("chrome.exe").</summary>
public sealed record AppRef(string Id, string Name)
{
    public static readonly IReadOnlyList<AppRef> DefaultIgnored =
    [
        new("1password.exe", "1Password"),
        new("bitwarden.exe", "Bitwarden"),
        new("keepass.exe", "KeePass"),
        new("keepassxc.exe", "KeePassXC"),
        new("dashlane.exe", "Dashlane"),
        new("enpass.exe", "Enpass"),
        new("credentialuibroker.exe", "Windows Security"),
    ];
}

public sealed class ClipItem
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    /// <summary>Sort key: bumped when the same content is copied again or pasted from Clipboard2.</summary>
    public DateTime LastCopiedAt { get; set; } = DateTime.UtcNow;
    public ClipKind Kind { get; set; }
    /// <summary>Plain text. Files: newline-separated paths. Images: empty.</summary>
    public string Text { get; set; } = "";
    public string Preview { get; set; } = "";
    public string? Rtf { get; set; }
    public string? Html { get; set; }
    public string ContentHash { get; set; } = "";
    public List<string> Files { get; set; } = [];
    /// <summary>File names inside the blob folder (never absolute paths).</summary>
    public string? ImageFile { get; set; }
    public string? ThumbnailFile { get; set; }
    public int ImageWidth { get; set; }
    public int ImageHeight { get; set; }
    public long ByteCount { get; set; }
    public string? SourceId { get; set; }
    public string? SourceName { get; set; }
    public bool IsPinned { get; set; }
    public DateTime? PinnedAt { get; set; }
    /// <summary>User-chosen name for pinned items; the content stays in <see cref="Text"/>.</summary>
    public string? Label { get; set; }
    public int CopyCount { get; set; } = 1;
    /// <summary>The sync group this item belongs to; null is the personal space (and every item when signed out).</summary>
    public string? SpaceId { get; set; }

    public AppRef? Source => SourceId is null ? null : new AppRef(SourceId, SourceName ?? SourceId);

    public string DisplayTitle =>
        !string.IsNullOrEmpty(Label) ? Label! : (Preview.Length == 0 ? Kind.DisplayName() : Preview);

    public string SearchableText => (Label is null ? "" : Label + " ") + Kind switch
    {
        ClipKind.Image => $"Image {ImageWidth}×{ImageHeight}",
        ClipKind.File => string.Join(" ", Files.Select(Path.GetFileName)) + " " + Text,
        _ => Text,
    };

    /// <summary>When the age limit removes this item, or null if it never expires.</summary>
    public DateTime? ExpiryDate(TimeSpan? maxAge) =>
        IsPinned || maxAge is null ? null : LastCopiedAt + maxAge.Value;

    public static ClipItem From(ProcessedCapture capture, DateTime now) => new()
    {
        CreatedAt = now,
        LastCopiedAt = now,
        Kind = capture.Kind,
        Text = capture.Text,
        Preview = capture.Preview,
        Rtf = capture.Rtf,
        Html = capture.Html,
        ContentHash = capture.Hash,
        Files = [.. capture.Files],
        ImageFile = capture.ImageFile,
        ThumbnailFile = capture.ThumbnailFile,
        ImageWidth = capture.ImageWidth,
        ImageHeight = capture.ImageHeight,
        ByteCount = capture.ByteCount,
        SourceId = capture.Source?.Id,
        SourceName = capture.Source?.Name,
    };
}

public sealed class Snippet
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "New Snippet";
    public string Keyword { get; set; } = "";
    public string Body { get; set; } = "";
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;
    /// <summary>Sync group id, or null for the personal space.</summary>
    public string? SpaceId { get; set; }
}

/// <summary>A clipboard capture after hashing / image encoding, ready to store.</summary>
public sealed record ProcessedCapture
{
    public ClipKind Kind { get; init; }
    public string Text { get; init; } = "";
    public string Preview { get; init; } = "";
    public string? Rtf { get; init; }
    public string? Html { get; init; }
    public IReadOnlyList<string> Files { get; init; } = [];
    public AppRef? Source { get; init; }
    public string Hash { get; init; } = "";
    public string? ImageFile { get; init; }
    public string? ThumbnailFile { get; init; }
    public int ImageWidth { get; init; }
    public int ImageHeight { get; init; }
    public long ByteCount { get; init; }

    public static ProcessedCapture ForText(string text, string? rtf = null, string? html = null, AppRef? source = null) => new()
    {
        Kind = rtf is null && html is null ? ClipKind.Text : ClipKind.RichText,
        Text = text,
        Preview = TextPreview.Make(text),
        Rtf = rtf,
        Html = html,
        Source = source,
        Hash = ContentHasher.HashText(text),
        ByteCount = System.Text.Encoding.UTF8.GetByteCount(text),
    };

    public static ProcessedCapture ForFiles(IReadOnlyList<string> files, AppRef? source = null)
    {
        var names = files.Select(Path.GetFileName).ToList();
        return new()
        {
            Kind = ClipKind.File,
            Text = string.Join("\n", files),
            Preview = names.Count == 1 ? names[0]! : $"{names.Count} files: {string.Join(", ", names)}",
            Files = files,
            Source = source,
            Hash = ContentHasher.HashFiles(files),
        };
    }
}

/// <param name="SpaceId">Sync group id, or null for the personal space.</param>
public sealed record SecretRef(string Id, string Name, DateTime? CreatedAt, string? SpaceId = null);

/// <summary>Sync bookkeeping for one local item (docs/sync/PROTOCOL.md → Client sync rules 1).</summary>
/// <param name="LocalId">Lowercase hyphenated UUID, the same as the remote item id.</param>
/// <param name="Fingerprint">SHA-256 of the canonical payload last sent or applied.</param>
/// <param name="Trimmed">The server trimmed it from personal history: keep the local copy and push it again only if it changes.</param>
/// <param name="Blobs">Local blob file name → remote blob id, for blobs already on the server.</param>
/// <param name="AuthorUid">Who copied it, as the server reports (null: unknown, e.g. synced before this was kept).</param>
public sealed record SyncMeta(string SpaceId, string LocalId, string Category, string Fingerprint, long RemoteSeq, long UpdatedAt,
                              bool Trimmed = false, IReadOnlyDictionary<string, string>? Blobs = null, string? AuthorUid = null)
{
    public IReadOnlyDictionary<string, string> BlobMap => Blobs ?? new Dictionary<string, string>();
}

/// <summary>A sync space as last seen on the server, cached so group names and badges work offline.</summary>
/// <param name="Members">Member uid → display name (username, or the email's part before @); null when the server
/// doesn't send members.</param>
public sealed record SpaceRecord(string Id, string Kind, string Role, string? Name, string OwnerUid, int MemberCount,
                                 IReadOnlyDictionary<string, string>? Members = null)
{
    public bool IsGroup => Kind == "group";
    public bool IsOwner => Role == "owner";
    public string DisplayName => string.IsNullOrWhiteSpace(Name) ? "Untitled group" : Name!;

    /// <summary>The badge for an item of this group: who copied it, or the group's name when that isn't known
    /// (no author, a server without members, or no username of our own).</summary>
    public string AuthorName(string? authorUid, SyncSelf? self)
    {
        if (authorUid is null) return DisplayName;
        if (self is not null && authorUid == self.Uid) return string.IsNullOrWhiteSpace(self.Username) ? DisplayName : self.Username!;
        return Members?.GetValueOrDefault(authorUid) is { Length: > 0 } name ? name : DisplayName;
    }

    public bool Equals(SpaceRecord? other) =>
        other is not null && Id == other.Id && Kind == other.Kind && Role == other.Role && Name == other.Name && OwnerUid == other.OwnerUid
        && MemberCount == other.MemberCount && SameMembers(Members, other.Members);

    public override int GetHashCode() => HashCode.Combine(Id, Kind, Role, Name, OwnerUid, MemberCount, Members?.Count);

    private static bool SameMembers(IReadOnlyDictionary<string, string>? a, IReadOnlyDictionary<string, string>? b) =>
        a is null || b is null ? a is null && b is null
            : a.Count == b.Count && a.All(p => b.TryGetValue(p.Key, out var name) && name == p.Value);
}

/// <summary>The signed-in sync user, for telling own items apart in groups.</summary>
public sealed record SyncSelf(string Uid, string? Username);
