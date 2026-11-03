using System.IO.Compression;
using System.Text;

namespace Clipboard2.Core.Sync;

/// <summary>A folder of a file item as sync sends it: one zip. <see cref="ZipPath"/> is null when the folder is too
/// large for a blob (<see cref="TotalBytes"/> may then stop short of the full size).</summary>
public sealed record FolderArchive(string Folder, long TotalBytes, string? ZipPath, long ZipSize);

/// <summary>What's in a folder: its regular files and subfolders (links and reparse points left out), relative to it
/// with '/' separators.</summary>
internal sealed record FolderScan(List<(string Relative, string Full, bool IsDirectory)> Entries, long TotalBytes, long LatestWriteTicks,
                                  bool Stopped)
{
    /// <summary>What the zip may take at most: the bytes of its files plus 1 KB per entry.</summary>
    public long Estimate => FolderZip.Estimate(TotalBytes, Entries.Count);
    /// <summary>Changes whenever an entry is added, removed, resized or written to.</summary>
    public string Signature => $"{Entries.Count}|{TotalBytes}|{LatestWriteTicks}";
}

/// <summary>Zipping folders for sync and unpacking received ones (docs/sync/PROTOCOL.md → fileBlobs, folder).</summary>
public static class FolderZip
{
    public const int MaxEntries = 20_000;
    public const long MaxUncompressedBytes = 2L << 30;
    public const long EntryOverhead = 1024;

    public static long Estimate(long totalBytes, int entries) => totalBytes + EntryOverhead * entries;

    /// <summary>"Photos" for "C:\Users\me\Photos\".</summary>
    public static string Name(string folder) => Path.GetFileName(Path.TrimEndingDirectorySeparator(folder));

    /// <summary>A folder blob's name without ".zip".</summary>
    public static string StripZip(string name) =>
        name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) && name.Length > 4 ? name[..^4] : name;

    /// <summary>The total bytes of a folder's files and the estimated zip size, or null when it isn't a folder.</summary>
    public static (long TotalBytes, long Estimate)? Measure(string folder) =>
        Scan(folder, null) is { } scan ? (scan.TotalBytes, scan.Estimate) : null;

    /// <summary>Walks a folder. With <paramref name="stopAbove"/>, stops (<see cref="FolderScan.Stopped"/>) as soon as
    /// the estimate exceeds it. Null when it isn't a folder.</summary>
    internal static FolderScan? Scan(string folder, long? stopAbove)
    {
        DirectoryInfo root;
        try
        {
            root = new DirectoryInfo(folder);
            if (!root.Exists) return null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
        var options = new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = 0, RecurseSubdirectories = false };
        var entries = new List<(string, string, bool)>();
        long total = 0, latest = root.LastWriteTimeUtc.Ticks;
        var pending = new Stack<(DirectoryInfo Dir, string Prefix)>();
        pending.Push((root, ""));
        while (pending.Count > 0)
        {
            var (dir, prefix) = pending.Pop();
            IEnumerable<FileSystemInfo> children;
            try { children = dir.EnumerateFileSystemInfos("*", options).ToList(); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { continue; }
            foreach (var info in children)
            {
                if (info.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;   // symlinks, junctions
                var relative = prefix + info.Name;
                switch (info)
                {
                    case DirectoryInfo sub:
                        entries.Add((relative, sub.FullName, true));
                        pending.Push((sub, relative + "/"));
                        break;
                    case FileInfo file:
                        entries.Add((relative, file.FullName, false));
                        total += file.Length;
                        break;
                    default:
                        continue;
                }
                latest = Math.Max(latest, info.LastWriteTimeUtc.Ticks);
                if (stopAbove is { } limit && Estimate(total, entries.Count) > limit) return new FolderScan(entries, total, latest, true);
            }
        }
        entries.Sort((a, b) => string.CompareOrdinal(a.Item1, b.Item1));
        return new FolderScan(entries, total, latest, false);
    }

    /// <summary>Zips a scanned folder: deflate, UTF-8 names, entries relative to the folder ("sub/" for folders).</summary>
    internal static void Write(FolderScan scan, Stream output)
    {
        using var zip = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true, Encoding.UTF8);
        foreach (var (relative, full, isDirectory) in scan.Entries)
        {
            if (isDirectory)
            {
                zip.CreateEntry(relative + "/");
                continue;
            }
            var entry = zip.CreateEntry(relative, CompressionLevel.Optimal);
            var written = File.GetLastWriteTime(full);
            if (written.Year is >= 1980 and <= 2107) entry.LastWriteTime = written;
            using var source = new FileStream(full, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var target = entry.Open();
            source.CopyTo(target);
        }
    }

    /// <summary>Unpacks a received folder zip into <paramref name="target"/> (replacing whatever is there) and returns
    /// the files written. Null, with nothing written, when it's not a valid zip, when an entry is absolute, has a ".."
    /// component or would land outside the target, or when it holds more than <see cref="MaxEntries"/> entries or
    /// <see cref="MaxUncompressedBytes"/>.</summary>
    public static List<string>? Extract(byte[] zipBytes, string target)
    {
        var parent = Path.GetDirectoryName(Path.GetFullPath(target))!;
        var staging = Path.Combine(parent, "." + Guid.NewGuid().ToString("N") + ".partial");
        try
        {
            using var zip = new ZipArchive(new MemoryStream(zipBytes, writable: false), ZipArchiveMode.Read, leaveOpen: false, Encoding.UTF8);
            if (zip.Entries.Count > MaxEntries) return null;
            var plan = new List<(ZipArchiveEntry Entry, string Relative, bool IsDirectory)>();
            long declared = 0;
            var stagingRoot = Path.GetFullPath(staging) + Path.DirectorySeparatorChar;
            foreach (var entry in zip.Entries)
            {
                if (SafeRelativePath(entry.FullName) is not { } relative) return null;
                declared += entry.Length;
                if (declared > MaxUncompressedBytes) return null;
                if (relative.Length == 0) continue;   // the root itself
                var full = Path.GetFullPath(Path.Combine(staging, relative));
                if (!full.StartsWith(stagingRoot, StringComparison.OrdinalIgnoreCase)) return null;
                plan.Add((entry, relative, entry.FullName.EndsWith('/') || entry.FullName.EndsWith('\\')));
            }
            Directory.CreateDirectory(staging);
            var files = new List<string>();
            long written = 0;
            var buffer = new byte[81920];
            foreach (var (entry, relative, isDirectory) in plan)
            {
                var path = Path.Combine(staging, relative);
                if (isDirectory)
                {
                    Directory.CreateDirectory(path);
                    continue;
                }
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                using (var source = entry.Open())
                using (var output = new FileStream(path, FileMode.Create, FileAccess.Write))
                {
                    long fileBytes = 0;
                    int read;
                    while ((read = source.Read(buffer)) > 0)
                    {
                        fileBytes += read;
                        written += read;
                        if (fileBytes > entry.Length || written > MaxUncompressedBytes) throw new InvalidDataException("Entry larger than declared");
                        output.Write(buffer, 0, read);
                    }
                }
                try { File.SetLastWriteTime(path, entry.LastWriteTime.DateTime); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { }
                files.Add(relative);
            }
            if (Directory.Exists(target)) Directory.Delete(target, recursive: true);
            else if (File.Exists(target)) File.Delete(target);
            Directory.Move(staging, target);
            return [.. files.Distinct(StringComparer.OrdinalIgnoreCase).Select(f => Path.Combine(target, f))];
        }
        catch (Exception ex) when (ex is InvalidDataException or IOException or UnauthorizedAccessException or NotSupportedException or ArgumentException)
        {
            return null;
        }
        finally
        {
            try { if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true); } catch { /* best effort */ }
        }
    }

    /// <summary>An entry name as a relative path with safe components, "" for the root, or null when it's absolute or
    /// climbs out ("..").</summary>
    private static string? SafeRelativePath(string name)
    {
        if (name.Contains('\0')) return null;
        var normalized = name.Replace('\\', '/');
        if (normalized.StartsWith('/') || Path.IsPathRooted(name) || (normalized.Length >= 2 && normalized[1] == ':')) return null;
        var parts = new List<string>();
        foreach (var part in normalized.Split('/'))
        {
            if (part is "" or ".") continue;
            if (part == "..") return null;
            parts.Add(SyncEngine.SafeFileName(part));
        }
        return Path.Combine([.. parts]);
    }
}

/// <summary>Zips of folders on disk, one per folder path and contents: an unchanged folder gives the same zip (so the
/// same size and blob map key), and nothing is uploaded again. Safe to use off the UI thread.</summary>
public sealed class FolderArchiveCache(string directory)
{
    public string Directory { get; } = directory;

    private static string FolderHash(string folder) =>
        SyncCrypto.Sha256Hex(Encoding.UTF8.GetBytes(Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder))))[..32];

    private string PathFor(string folder, string signature) =>
        Path.Combine(Directory, $"{FolderHash(folder)}-{SyncCrypto.Sha256Hex(Encoding.UTF8.GetBytes(signature))[..16]}.zip");

    /// <summary>The folder's zip, made now unless the cache has one for its current contents. Too large (estimated
    /// above <paramref name="limit"/>): an archive without a zip. Null when it isn't a folder or can't be zipped.</summary>
    public FolderArchive? Prepare(string folder, long limit)
    {
        try
        {
            if (FolderZip.Scan(folder, limit) is not { } scan) return null;
            if (scan.Stopped || scan.Estimate > limit) return new FolderArchive(folder, scan.TotalBytes, null, 0);
            var zip = PathFor(folder, scan.Signature);
            if (!File.Exists(zip))
            {
                System.IO.Directory.CreateDirectory(Directory);
                var temp = zip + "." + Guid.NewGuid().ToString("N") + ".tmp";
                try
                {
                    using (var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write)) FolderZip.Write(scan, output);
                    File.Move(temp, zip, overwrite: true);
                }
                finally { if (File.Exists(temp)) File.Delete(temp); }
            }
            DeleteOlder(folder, zip);
            return new FolderArchive(folder, scan.TotalBytes, zip, new FileInfo(zip).Length);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException or NotSupportedException)
        {
            return null;
        }
    }

    /// <summary>Keeps a received zip as the archive of the folder it was unpacked into, so pushing that folder finds
    /// the same zip (and size) and doesn't send it back.</summary>
    public FolderArchive? Store(string folder, byte[] zipBytes)
    {
        try
        {
            if (FolderZip.Scan(folder, null) is not { } scan) return null;
            var zip = PathFor(folder, scan.Signature);
            System.IO.Directory.CreateDirectory(Directory);
            var temp = zip + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllBytes(temp, zipBytes);
            File.Move(temp, zip, overwrite: true);
            DeleteOlder(folder, zip);
            return new FolderArchive(folder, scan.TotalBytes, zip, zipBytes.Length);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
    }

    private void DeleteOlder(string folder, string current)
    {
        foreach (var old in System.IO.Directory.EnumerateFiles(Directory, FolderHash(folder) + "-*.zip").Where(f => f != current).ToList())
            try { File.Delete(old); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>Deletes archives of folders no longer in <paramref name="folders"/>, left alone for
    /// <paramref name="grace"/> after they were written.</summary>
    public void Sweep(IEnumerable<string> folders, TimeSpan grace)
    {
        if (!System.IO.Directory.Exists(Directory)) return;
        var live = folders.Select(FolderHash).ToHashSet();
        var cutoff = DateTime.UtcNow - grace;
        foreach (var file in System.IO.Directory.EnumerateFiles(Directory).ToList())
        {
            var name = Path.GetFileName(file);
            var dash = name.IndexOf('-');
            if (dash > 0 && live.Contains(name[..dash]) && name.EndsWith(".zip", StringComparison.Ordinal)) continue;
            try { if (File.GetLastWriteTimeUtc(file) < cutoff) File.Delete(file); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
    }
}
