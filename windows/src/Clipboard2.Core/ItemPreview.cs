using System.Text;

namespace Clipboard2.Core;

/// <summary>What one page of the large preview (Ctrl+Y) shows.</summary>
public enum PreviewKind { Image, Text, RichText, File }

/// <summary>One page of the large preview: an item, or one file of a file item.</summary>
/// <param name="FilePath">For <see cref="PreviewKind.File"/>: the file shown.</param>
/// <param name="FileIndex">Which of the item's (possibly picked) files this is, from 0.</param>
public sealed record PreviewPage(ClipItem Item, PreviewKind Kind, string? FilePath = null, int FileIndex = 0, int FileCount = 1)
{
    /// <summary>Identifies what's shown, so the view rebuilds only when it changes. A file by its path: the item
    /// holding only the picked files is made anew on every read.</summary>
    public string Key => FilePath is { } path ? "file:" + path : "item:" + Item.Id;

    public string Title => FilePath is { } path ? Path.GetFileName(path.TrimEnd('\\', '/')) is { Length: > 0 } name ? name : path : Item.DisplayTitle;
}

/// <summary>Which pages the large preview shows for the selection. Secrets and snippets are never previewed.</summary>
public static class ItemPreview
{
    /// <summary>Text beyond this many characters isn't shown (a TextBox with megabytes of wrapped text crawls).</summary>
    public const int MaxTextLength = 2_000_000;

    public static PreviewKind KindOf(ClipItem item) => item.Kind switch
    {
        ClipKind.Image => PreviewKind.Image,
        ClipKind.File => PreviewKind.File,
        // HTML-only rich text has no RTF to render: shown as its plain text.
        ClipKind.RichText when !string.IsNullOrEmpty(item.Rtf) => PreviewKind.RichText,
        _ => PreviewKind.Text,
    };

    /// <summary>One page per item, except file items: one page per file. Items are used as given (pass the picked
    /// subset of a file item, see <see cref="PanelModel.ItemForUse"/>).</summary>
    public static List<PreviewPage> Pages(IEnumerable<ClipItem> items)
    {
        var pages = new List<PreviewPage>();
        foreach (var item in items)
        {
            var kind = KindOf(item);
            if (kind != PreviewKind.File)
            {
                if (kind == PreviewKind.Image && item.ImageFile is null) continue;
                pages.Add(new PreviewPage(item, kind));
                continue;
            }
            for (var i = 0; i < item.Files.Count; i++)
                pages.Add(new PreviewPage(item, kind, item.Files[i], i, item.Files.Count));
        }
        return pages;
    }

    /// <summary>The text to show, cut at <paramref name="max"/> characters (never inside a surrogate pair).</summary>
    public static (string Text, bool Truncated) Truncate(string text, int max = MaxTextLength)
    {
        if (text.Length <= max) return (text, false);
        var end = char.IsHighSurrogate(text[max - 1]) ? max - 1 : max;
        return (text[..end], true);
    }
}

/// <summary>How a file in a file item is previewed.</summary>
public enum FilePreviewKind { Missing, Folder, Image, Text, Pdf, Other }

/// <summary>Sorts files into what the preview can render inline, and reads text files (capped).</summary>
public static class FilePreview
{
    /// <summary>Text files are read up to this many bytes; the rest is left out.</summary>
    public const int MaxTextBytes = 2 * 1024 * 1024;

    /// <summary>Formats WPF decodes out of the box (HEIC/WebP need the Store codecs; a failed load shows the file card).</summary>
    public static readonly IReadOnlySet<string> ImageExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tif", ".tiff", ".webp", ".heic", ".ico",
    };

    public static readonly IReadOnlySet<string> TextExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        ".txt", ".text", ".md", ".markdown", ".log", ".csv", ".tsv", ".json", ".jsonc", ".xml", ".yaml", ".yml", ".toml",
        ".ini", ".cfg", ".conf", ".config", ".env", ".properties", ".gitignore", ".gitattributes", ".editorconfig",
        ".cs", ".csx", ".vb", ".fs", ".java", ".kt", ".kts", ".swift", ".m", ".h", ".c", ".cpp", ".cc", ".hpp", ".rs", ".go",
        ".py", ".rb", ".php", ".pl", ".lua", ".r", ".dart", ".scala", ".groovy", ".gradle", ".js", ".mjs", ".cjs", ".jsx",
        ".ts", ".tsx", ".vue", ".svelte", ".css", ".scss", ".sass", ".less", ".html", ".htm", ".svg", ".sql", ".graphql",
        ".sh", ".bash", ".zsh", ".fish", ".ps1", ".psm1", ".bat", ".cmd", ".csproj", ".sln", ".props", ".targets",
        ".xaml", ".resx", ".manifest", ".tex", ".rst", ".adoc", ".srt", ".vtt", ".diff", ".patch", ".lock",
    };

    /// <summary>Extension-less files that are text by convention.</summary>
    private static readonly IReadOnlySet<string> TextNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "README", "LICENSE", "LICENCE", "CHANGELOG", "AUTHORS", "NOTICE", "Makefile", "Dockerfile", "Procfile", "Gemfile", "Rakefile",
    };

    /// <summary>By name only (no file access): what <see cref="Classify"/> says for an existing file.</summary>
    public static FilePreviewKind KindByName(string path)
    {
        var ext = Path.GetExtension(path);
        if (ImageExtensions.Contains(ext)) return FilePreviewKind.Image;
        if (ext.Equals(".pdf", StringComparison.OrdinalIgnoreCase)) return FilePreviewKind.Pdf;
        if (TextExtensions.Contains(ext) || (ext.Length == 0 && TextNames.Contains(Path.GetFileName(path)))) return FilePreviewKind.Text;
        return FilePreviewKind.Other;
    }

    public static FilePreviewKind Classify(string path)
    {
        try
        {
            if (Directory.Exists(path)) return FilePreviewKind.Folder;
            if (!File.Exists(path)) return FilePreviewKind.Missing;
        }
        catch { return FilePreviewKind.Missing; }
        return KindByName(path);
    }

    /// <summary>Reads up to <paramref name="maxBytes"/> as text (BOM-aware, UTF-8 otherwise). Null when it can't be
    /// read or looks binary (NUL bytes in a file without a UTF-16 BOM).</summary>
    public static (string Text, bool Truncated)? ReadText(string path, int maxBytes = MaxTextBytes)
    {
        byte[] bytes;
        bool truncated;
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            truncated = stream.Length > maxBytes;
            bytes = new byte[Math.Min(stream.Length, maxBytes)];
            stream.ReadExactly(bytes);
        }
        catch { return null; }
        var utf16 = bytes.Length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF));
        if (!utf16 && Array.IndexOf(bytes, (byte)0) >= 0) return null;
        using var reader = new StreamReader(new MemoryStream(bytes), Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        var text = reader.ReadToEnd();
        // A cut in the middle of a multi-byte character decodes to U+FFFD at the very end.
        if (truncated && text.EndsWith('�')) text = text[..^1];
        return (text, truncated);
    }

    /// <summary>"12.4 MB", or "Folder" / "" when there's no size.</summary>
    public static string SizeText(string path)
    {
        try
        {
            if (Directory.Exists(path)) return "Folder";
            return File.Exists(path) ? Sync.IncomingDownload.FormatSize(new FileInfo(path).Length) : "";
        }
        catch { return ""; }
    }
}
