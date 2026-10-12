using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace Clipboard2.Core;

/// <summary>Image blobs and thumbnails live on disk next to the database, never inside it.</summary>
public sealed class BlobStore
{
    public string Directory { get; }

    public BlobStore(string directory)
    {
        Directory = directory;
        System.IO.Directory.CreateDirectory(directory);
    }

    public string PathFor(string name) => Path.Combine(Directory, name);

    public void Write(byte[] data, string name)
    {
        var target = PathFor(name);
        var temp = target + ".tmp";
        File.WriteAllBytes(temp, data);
        File.Move(temp, target, overwrite: true);
    }

    public void Delete(string? name)
    {
        if (string.IsNullOrEmpty(name) || name.Contains('/') || name.Contains('\\')) return;
        try { File.Delete(PathFor(name)); } catch { /* already gone */ }
    }

    public IEnumerable<string> AllFileNames() =>
        System.IO.Directory.Exists(Directory)
            ? System.IO.Directory.EnumerateFiles(Directory).Select(Path.GetFileName).OfType<string>()
            : [];
}

/// <summary>
/// History + snippets in one SQLite file. Every mutation goes through here so blobs and rows stay
/// consistent; <see cref="Changed"/> fires after each commit. Not thread-safe: use from the UI thread.
/// </summary>
public sealed class ClipStore : IDisposable
{
    private readonly SqliteConnection _db;
    public BlobStore Blobs { get; }
    public int Revision { get; private set; }
    public event Action? Changed;

    /// <param name="databasePath">File path, or ":memory:" for tests.</param>
    public ClipStore(string databasePath, BlobStore blobs)
    {
        Blobs = blobs;
        _db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = databasePath, Pooling = false }.ToString());
        _db.Open();
        Exec("PRAGMA journal_mode=WAL;");
        Exec("""
            CREATE TABLE IF NOT EXISTS clips (
                id TEXT PRIMARY KEY, created INTEGER NOT NULL, last_copied INTEGER NOT NULL, kind INTEGER NOT NULL,
                text TEXT NOT NULL, preview TEXT NOT NULL, rtf TEXT, html TEXT, hash TEXT NOT NULL, files TEXT NOT NULL,
                image_file TEXT, thumb_file TEXT, width INTEGER NOT NULL, height INTEGER NOT NULL, bytes INTEGER NOT NULL,
                source_id TEXT, source_name TEXT, pinned INTEGER NOT NULL, pinned_at INTEGER, label TEXT, copy_count INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS clips_hash ON clips(hash);
            CREATE INDEX IF NOT EXISTS clips_last ON clips(last_copied);
            CREATE TABLE IF NOT EXISTS snippets (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, keyword TEXT NOT NULL, body TEXT NOT NULL,
                created INTEGER NOT NULL, updated INTEGER NOT NULL);
            """);
    }

    public void Dispose() => _db.Dispose();

    // MARK: Reads

    public List<ClipItem> AllItems() => Query("SELECT * FROM clips ORDER BY last_copied DESC");

    public ClipItem? Find(Guid id) => Query("SELECT * FROM clips WHERE id = $id", ("$id", id.ToString())).FirstOrDefault();

    public ClipItem? ItemWithHash(string hash) =>
        Query("SELECT * FROM clips WHERE hash = $h ORDER BY pinned DESC, last_copied DESC LIMIT 1", ("$h", hash)).FirstOrDefault();

    public int Count() => Convert.ToInt32(Scalar("SELECT COUNT(*) FROM clips"));

    // MARK: Writes

    /// <summary>Inserts a capture, or — if identical content exists — moves that item to the top.</summary>
    public ClipItem Ingest(ProcessedCapture capture, DateTime? now = null)
    {
        var time = now ?? DateTime.UtcNow;
        if (ItemWithHash(capture.Hash) is { } existing)
        {
            existing.LastCopiedAt = time;
            existing.CopyCount += 1;
            if (capture.Source is { } source)
            {
                existing.SourceId = source.Id;
                existing.SourceName = source.Name;
            }
            if (capture.Rtf is not null || capture.Html is not null)
            {
                existing.Rtf = capture.Rtf ?? existing.Rtf;
                existing.Html = capture.Html ?? existing.Html;
                existing.Kind = ClipKind.RichText;
            }
            if (capture.ImageFile != existing.ImageFile) Blobs.Delete(capture.ImageFile);
            if (capture.ThumbnailFile != existing.ThumbnailFile) Blobs.Delete(capture.ThumbnailFile);
            Save(existing);
            Commit();
            return existing;
        }
        var item = ClipItem.From(capture, time);
        Save(item);
        Commit();
        return item;
    }

    public void Touch(ClipItem item, DateTime? now = null)
    {
        item.LastCopiedAt = now ?? DateTime.UtcNow;
        Save(item);
        Commit();
    }

    public void TogglePin(ClipItem item)
    {
        item.IsPinned = !item.IsPinned;
        item.PinnedAt = item.IsPinned ? DateTime.UtcNow : null;
        Save(item);
        Commit();
    }

    /// <summary>Sets (or clears, for empty text) a label. Labelled items are pinned so they never expire.</summary>
    public void SetLabel(string? label, ClipItem item)
    {
        var trimmed = label?.Trim() ?? "";
        item.Label = trimmed.Length == 0 ? null : trimmed;
        if (item.Label is not null && !item.IsPinned)
        {
            item.IsPinned = true;
            item.PinnedAt = DateTime.UtcNow;
        }
        Save(item);
        Commit();
    }

    public void Delete(ClipItem item)
    {
        Remove(item);
        Commit();
    }

    public void ClearHistory(bool includingPinned = false)
    {
        foreach (var item in AllItems().Where(i => includingPinned || !i.IsPinned)) Remove(item);
        Commit();
    }

    /// <summary>Replaces an item's content with new plain text (e.g. an AI result).</summary>
    public void ReplaceText(ClipItem item, string text)
    {
        var hash = ContentHasher.HashText(text);
        if (ItemWithHash(hash) is { } duplicate && duplicate.Id != item.Id) Remove(duplicate);
        Blobs.Delete(item.ImageFile);
        Blobs.Delete(item.ThumbnailFile);
        item.Kind = ClipKind.Text;
        item.Text = text;
        item.Preview = TextPreview.Make(text);
        item.Rtf = null;
        item.Html = null;
        item.Files = [];
        item.ImageFile = null;
        item.ThumbnailFile = null;
        item.ContentHash = hash;
        item.ByteCount = System.Text.Encoding.UTF8.GetByteCount(text);
        item.LastCopiedAt = DateTime.UtcNow;
        Save(item);
        Commit();
    }

    // MARK: Retention & cleanup

    /// <summary>Pinned items are exempt. <paramref name="maxAge"/> null keeps forever; maxItems 0 = no count limit.</summary>
    public int EnforceRetention(int maxItems, TimeSpan? maxAge, DateTime? now = null)
    {
        var time = now ?? DateTime.UtcNow;
        var removed = 0;
        var unpinned = AllItems().Where(i => !i.IsPinned).ToList();   // newest first
        foreach (var (item, index) in unpinned.Select((item, index) => (item, index)))
        {
            var expired = maxAge is { } age && item.LastCopiedAt < time - age;
            var overflow = maxItems > 0 && index >= maxItems;
            if (!expired && !overflow) continue;
            Remove(item);
            removed++;
        }
        if (removed > 0) Commit();
        return removed;
    }

    /// <summary>Collapses items with the same hash. Pinned items are never deleted.</summary>
    public int MergeDuplicates()
    {
        var removed = 0;
        foreach (var group in AllItems().GroupBy(i => i.ContentHash).Where(g => g.Count() > 1))
        {
            var items = group.ToList();
            var newest = items.MaxBy(i => i.LastCopiedAt)!;
            var keepers = items.Where(i => i.IsPinned).ToList();
            if (keepers.Count == 0) keepers.Add(newest);
            var survivor = keepers.MaxBy(i => i.LastCopiedAt)!;
            survivor.LastCopiedAt = newest.LastCopiedAt;
            survivor.CopyCount = items.Sum(i => i.CopyCount);
            Save(survivor);
            foreach (var item in items.Where(i => keepers.All(k => k.Id != i.Id)))
            {
                Remove(item);
                removed++;
            }
        }
        if (removed > 0) Commit();
        return removed;
    }

    /// <summary>Removes unpinned items whose content hash is in <paramref name="hashes"/> (e.g. saved secrets).</summary>
    public void RemoveUnpinned(IReadOnlySet<string> hashes)
    {
        if (hashes.Count == 0) return;
        var removed = 0;
        foreach (var item in AllItems().Where(i => !i.IsPinned && hashes.Contains(i.ContentHash)))
        {
            Remove(item);
            removed++;
        }
        if (removed > 0) Commit();
    }

    public void RemoveOrphanedBlobs()
    {
        var referenced = new HashSet<string>();
        foreach (var item in AllItems())
        {
            if (item.ImageFile is { } f) referenced.Add(f);
            if (item.ThumbnailFile is { } t) referenced.Add(t);
        }
        foreach (var name in Blobs.AllFileNames().Where(n => !referenced.Contains(n)).ToList()) Blobs.Delete(name);
    }

    // MARK: Snippets

    public List<Snippet> AllSnippets()
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT id, name, keyword, body, created, updated FROM snippets ORDER BY name COLLATE NOCASE";
        using var r = cmd.ExecuteReader();
        var list = new List<Snippet>();
        while (r.Read())
            list.Add(new Snippet
            {
                Id = Guid.Parse(r.GetString(0)), Name = r.GetString(1), Keyword = r.GetString(2), Body = r.GetString(3),
                CreatedAt = FromUnix(r.GetInt64(4)), UpdatedAt = FromUnix(r.GetInt64(5)),
            });
        return list;
    }

    public Snippet CreateSnippet(string name = "New Snippet", string keyword = "", string body = "")
    {
        var snippet = new Snippet { Name = name, Keyword = keyword, Body = body };
        SaveSnippet(snippet);
        return snippet;
    }

    public void SaveSnippet(Snippet snippet)
    {
        snippet.UpdatedAt = DateTime.UtcNow;
        Exec("""
            INSERT INTO snippets (id, name, keyword, body, created, updated) VALUES ($id, $n, $k, $b, $c, $u)
            ON CONFLICT(id) DO UPDATE SET name = $n, keyword = $k, body = $b, updated = $u
            """,
            ("$id", snippet.Id.ToString()), ("$n", snippet.Name), ("$k", snippet.Keyword), ("$b", snippet.Body),
            ("$c", ToUnix(snippet.CreatedAt)), ("$u", ToUnix(snippet.UpdatedAt)));
        Commit();
    }

    public void DeleteSnippet(Snippet snippet)
    {
        Exec("DELETE FROM snippets WHERE id = $id", ("$id", snippet.Id.ToString()));
        Commit();
    }

    // MARK: Private

    private void Remove(ClipItem item)
    {
        Blobs.Delete(item.ImageFile);
        Blobs.Delete(item.ThumbnailFile);
        Exec("DELETE FROM clips WHERE id = $id", ("$id", item.Id.ToString()));
    }

    private void Save(ClipItem i) => Exec("""
        INSERT INTO clips (id, created, last_copied, kind, text, preview, rtf, html, hash, files, image_file, thumb_file,
                           width, height, bytes, source_id, source_name, pinned, pinned_at, label, copy_count)
        VALUES ($id, $created, $last, $kind, $text, $preview, $rtf, $html, $hash, $files, $img, $thumb,
                $w, $h, $bytes, $sid, $sname, $pinned, $pinnedAt, $label, $count)
        ON CONFLICT(id) DO UPDATE SET last_copied = $last, kind = $kind, text = $text, preview = $preview, rtf = $rtf,
            html = $html, hash = $hash, files = $files, image_file = $img, thumb_file = $thumb, width = $w, height = $h,
            bytes = $bytes, source_id = $sid, source_name = $sname, pinned = $pinned, pinned_at = $pinnedAt,
            label = $label, copy_count = $count
        """,
        ("$id", i.Id.ToString()), ("$created", ToUnix(i.CreatedAt)), ("$last", ToUnix(i.LastCopiedAt)), ("$kind", (int)i.Kind),
        ("$text", i.Text), ("$preview", i.Preview), ("$rtf", i.Rtf), ("$html", i.Html), ("$hash", i.ContentHash),
        ("$files", JsonSerializer.Serialize(i.Files)), ("$img", i.ImageFile), ("$thumb", i.ThumbnailFile),
        ("$w", i.ImageWidth), ("$h", i.ImageHeight), ("$bytes", i.ByteCount), ("$sid", i.SourceId), ("$sname", i.SourceName),
        ("$pinned", i.IsPinned ? 1 : 0), ("$pinnedAt", i.PinnedAt is { } p ? ToUnix(p) : null), ("$label", i.Label),
        ("$count", i.CopyCount));

    private List<ClipItem> Query(string sql, params (string, object?)[] args)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        foreach (var (name, value) in args) cmd.Parameters.AddWithValue(name, value ?? DBNull.Value);
        using var r = cmd.ExecuteReader();
        var list = new List<ClipItem>();
        while (r.Read())
        {
            string? Str(string c) => r.IsDBNull(r.GetOrdinal(c)) ? null : r.GetString(r.GetOrdinal(c));
            long Num(string c) => r.GetInt64(r.GetOrdinal(c));
            list.Add(new ClipItem
            {
                Id = Guid.Parse(Str("id")!),
                CreatedAt = FromUnix(Num("created")),
                LastCopiedAt = FromUnix(Num("last_copied")),
                Kind = (ClipKind)Num("kind"),
                Text = Str("text") ?? "",
                Preview = Str("preview") ?? "",
                Rtf = Str("rtf"),
                Html = Str("html"),
                ContentHash = Str("hash") ?? "",
                Files = JsonSerializer.Deserialize<List<string>>(Str("files") ?? "[]") ?? [],
                ImageFile = Str("image_file"),
                ThumbnailFile = Str("thumb_file"),
                ImageWidth = (int)Num("width"),
                ImageHeight = (int)Num("height"),
                ByteCount = Num("bytes"),
                SourceId = Str("source_id"),
                SourceName = Str("source_name"),
                IsPinned = Num("pinned") != 0,
                PinnedAt = r.IsDBNull(r.GetOrdinal("pinned_at")) ? null : FromUnix(Num("pinned_at")),
                Label = Str("label"),
                CopyCount = (int)Num("copy_count"),
            });
        }
        return list;
    }

    private void Exec(string sql, params (string, object?)[] args)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        foreach (var (name, value) in args) cmd.Parameters.AddWithValue(name, value ?? DBNull.Value);
        cmd.ExecuteNonQuery();
    }

    private object? Scalar(string sql)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        return cmd.ExecuteScalar();
    }

    private void Commit()
    {
        Revision++;
        Changed?.Invoke();
    }

    private static long ToUnix(DateTime t) => new DateTimeOffset(DateTime.SpecifyKind(t, DateTimeKind.Utc)).ToUnixTimeMilliseconds();
    private static DateTime FromUnix(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime;
}
