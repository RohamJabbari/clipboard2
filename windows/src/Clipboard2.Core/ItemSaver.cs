using System.Text;

namespace Clipboard2.Core;

/// <summary>What saving to a folder did: the paths written, and the first problem (null when everything was saved).</summary>
public sealed record SaveOutcome(IReadOnlyList<string> Written, int SavedItems, int TotalItems, string? Error)
{
    /// <summary>The panel notice, e.g. "Saved to Downloads" or "Couldn't save to Downloads: …".</summary>
    public string Notice(string folderName)
    {
        if (Error is null) return TotalItems == 1 ? $"Saved to {folderName}" : $"Saved {TotalItems} items to {folderName}";
        if (SavedItems == 0) return $"Couldn't save to {folderName}: {Error}";
        return $"Saved {SavedItems} of {TotalItems} items to {folderName}: {Error}";
    }
}

/// <summary>Writes history items into a folder as ordinary files: text as UTF-8 .txt, images as .png, file items
/// as copies of their files and folders. Never overwrites: a taken name becomes "Name (2).ext", like Explorer.</summary>
public static class ItemSaver
{
    public const int MaxNameLength = 40;
    private const int MaxWords = 8;

    private static readonly HashSet<string> ReservedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM0", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT0", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    /// <summary>A file name without extension: the label, else the first few words of <paramref name="text"/>, with
    /// characters Windows doesn't allow removed, at most <see cref="MaxNameLength"/> characters.</summary>
    public static string BaseName(string? label, string text, string fallback)
    {
        var source = !string.IsNullOrWhiteSpace(label) ? label! : text;
        var words = Sanitize(source).Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(MaxWords);
        var name = new StringBuilder();
        foreach (var word in words)
        {
            if (name.Length == 0) name.Append(word.Length > MaxNameLength ? word[..MaxNameLength] : word);
            else if (name.Length + 1 + word.Length <= MaxNameLength) name.Append(' ').Append(word);
            else break;
        }
        // Windows drops trailing dots and spaces, so "etc." would become "etc".
        var result = name.ToString();
        if (result.Length > 0 && char.IsHighSurrogate(result[^1])) result = result[..^1];   // cut inside an emoji
        result = result.TrimEnd('.', ' ');
        if (result.Length == 0) return fallback;
        // "CON", "nul.txt" and friends are devices, not files.
        var stem = result.Split('.')[0];
        if (ReservedNames.Contains(stem.TrimEnd())) result = stem + "_" + result[stem.Length..];
        return result;
    }

    /// <summary>Invalid characters (and control characters, incl. line breaks) become spaces; runs of spaces collapse.</summary>
    private static string Sanitize(string text)
    {
        var builder = new StringBuilder(Math.Min(text.Length, 400));
        foreach (var c in text.Length > 400 ? text[..400] : text)
            builder.Append(c < 32 || c is '<' or '>' or ':' or '"' or '/' or '\\' or '|' or '?' or '*' || char.IsWhiteSpace(c) ? ' ' : c);
        return builder.ToString().Trim();
    }

    public static string FileName(ClipItem item) => item.Kind switch
    {
        ClipKind.Image => BaseName(item.Label, "", "Image") + ".png",
        _ => BaseName(item.Label, item.Text, "Text") + ".txt",
    };

    /// <summary>A path in <paramref name="folder"/> that doesn't exist yet: "Name.ext", then "Name (2).ext", "Name (3).ext"…
    /// Folders have no extension, so "my.folder" becomes "my.folder (2)".</summary>
    public static string UniquePath(string folder, string name, bool isDirectory = false)
    {
        var stem = isDirectory ? name : Path.GetFileNameWithoutExtension(name);
        var extension = isDirectory ? "" : Path.GetExtension(name);
        var path = Path.Combine(folder, name);
        for (var n = 2; File.Exists(path) || Directory.Exists(path); n++)
            path = Path.Combine(folder, $"{stem} ({n}){extension}");
        return path;
    }

    /// <summary>Saves one item; returns the paths written. Throws (IOException, UnauthorizedAccessException…) with
    /// a message fit for the user when nothing could be saved.</summary>
    public static IReadOnlyList<string> Save(ClipItem item, string folder, BlobStore blobs)
    {
        Directory.CreateDirectory(folder);
        switch (item.Kind)
        {
            case ClipKind.Image:
                if (item.ImageFile is not { } image || !File.Exists(blobs.PathFor(image))) throw new IOException("The image is gone.");
                var png = UniquePath(folder, FileName(item));
                File.Copy(blobs.PathFor(image), png);
                return [png];
            case ClipKind.File:
                var written = new List<string>();
                foreach (var source in item.Files)
                {
                    var name = Path.GetFileName(source.TrimEnd('\\', '/'));
                    if (File.Exists(source))
                    {
                        var target = UniquePath(folder, name);
                        File.Copy(source, target);
                        written.Add(target);
                    }
                    else if (Directory.Exists(source))
                    {
                        var target = UniquePath(folder, name, isDirectory: true);
                        CopyDirectory(source, target);
                        written.Add(target);
                    }
                }
                if (written.Count == 0) throw new IOException(item.Files.Count == 1 ? "The file is gone." : "The files are gone.");
                return written;
            default:
                var txt = UniquePath(folder, FileName(item));
                using (var stream = new FileStream(txt, FileMode.CreateNew, FileAccess.Write))
                using (var writer = new StreamWriter(stream, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false)))
                    writer.Write(item.Text);
                return [txt];
        }
    }

    /// <summary>Saves each item, carrying on past failures; the outcome reports the first one.</summary>
    public static SaveOutcome Save(IReadOnlyList<ClipItem> items, string folder, BlobStore blobs)
    {
        var written = new List<string>();
        var saved = 0;
        string? error = null;
        foreach (var item in items)
        {
            try
            {
                written.AddRange(Save(item, folder, blobs));
                saved++;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
            {
                error ??= ex.Message;
            }
        }
        return new SaveOutcome(written, saved, items.Count, error);
    }

    private static void CopyDirectory(string source, string target)
    {
        Directory.CreateDirectory(target);
        foreach (var file in Directory.EnumerateFiles(source))
            File.Copy(file, Path.Combine(target, Path.GetFileName(file)));
        foreach (var directory in Directory.EnumerateDirectories(source))
            CopyDirectory(directory, Path.Combine(target, Path.GetFileName(directory)));
    }
}
