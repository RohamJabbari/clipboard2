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

public sealed record SecretRef(string Id, string Name, DateTime? CreatedAt);
