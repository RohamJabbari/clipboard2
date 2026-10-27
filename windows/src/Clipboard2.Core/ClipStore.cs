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
    /// <summary>Files received through sync, one folder per item (<see cref="SyncedFolder"/>).</summary>
    public string SyncedFilesDirectory { get; }
    public int Revision { get; private set; }
    public event Action? Changed;

    /// <param name="databasePath">File path, or ":memory:" for tests.</param>
    /// <param name="syncedFilesDirectory">Where synced files go; defaults to a folder inside the blob directory.</param>
    public ClipStore(string databasePath, BlobStore blobs, string? syncedFilesDirectory = null)
    {
        Blobs = blobs;
        SyncedFilesDirectory = syncedFilesDirectory ?? Path.Combine(blobs.Directory, "Synced Files");
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
        Migrate();
    }

    /// <summary>Schema version stored in <c>PRAGMA user_version</c>. v0 is the original, unversioned schema.</summary>
    public const int SchemaVersion = 4;

    public int UserVersion => Convert.ToInt32(Scalar("PRAGMA user_version"));

    private void Migrate()
    {
        var version = UserVersion;
        if (version >= SchemaVersion) return;
        Exec("BEGIN");
        try
        {
            if (version < 1)
            {
                // v1: sync. space_id null = personal; sync_meta tracks what the server has; cursors per space.
                Exec("""
                    ALTER TABLE clips ADD COLUMN space_id TEXT;
                    ALTER TABLE snippets ADD COLUMN space_id TEXT;
                    CREATE INDEX IF NOT EXISTS clips_space ON clips(space_id);
                    CREATE TABLE IF NOT EXISTS sync_meta (
                        space_id TEXT NOT NULL, local_id TEXT NOT NULL, category TEXT NOT NULL, fingerprint TEXT NOT NULL,
                        remote_seq INTEGER NOT NULL, updated_at INTEGER NOT NULL, trimmed INTEGER NOT NULL DEFAULT 0, blobs TEXT,
                        PRIMARY KEY (space_id, local_id));
                    CREATE TABLE IF NOT EXISTS sync_cursor (space_id TEXT PRIMARY KEY, since INTEGER NOT NULL);
                    CREATE TABLE IF NOT EXISTS sync_spaces (
                        id TEXT PRIMARY KEY, kind TEXT NOT NULL, role TEXT NOT NULL, name TEXT, owner_uid TEXT NOT NULL,
                        member_count INTEGER NOT NULL);
                    """);
            }
            if (version < 2)
            {
                // v2: usernames. Who copied each synced item, and each space's members (uid → name). Groups pull
                // again from the start once, so items synced before this learn their author.
                Exec("""
                    ALTER TABLE sync_meta ADD COLUMN author_uid TEXT;
                    ALTER TABLE sync_spaces ADD COLUMN members TEXT;
                    UPDATE sync_cursor SET since = 0 WHERE space_id IN (SELECT id FROM sync_spaces WHERE kind = 'group');
                    """);
            }
            if (version < 3)
            {
                // v3: text recognised in images (local only), for search. Null = not read yet.
                Exec("ALTER TABLE clips ADD COLUMN ocr_text TEXT;");
            }
            if (version < 4)
            {
                // v4: a full re-sync survives an interruption (the flag and the ids seen so far), and items the server
                // refused for good are remembered by fingerprint, so they aren't uploaded again on every launch.
                Exec("""
                    ALTER TABLE sync_cursor ADD COLUMN resync INTEGER NOT NULL DEFAULT 0;
                    CREATE TABLE IF NOT EXISTS sync_resync_seen (space_id TEXT NOT NULL, local_id TEXT NOT NULL, PRIMARY KEY (space_id, local_id));
                    CREATE TABLE IF NOT EXISTS sync_rejected (
                        space_id TEXT NOT NULL, local_id TEXT NOT NULL, fingerprint TEXT NOT NULL, reason TEXT NOT NULL,
                        PRIMARY KEY (space_id, local_id));
                    """);
            }
            Exec($"PRAGMA user_version = {SchemaVersion}");
            Exec("COMMIT");
        }
        catch
        {
            Exec("ROLLBACK");
            throw;
        }
    }

    public void Dispose() => _db.Dispose();

    // MARK: Reads

    public List<ClipItem> AllItems() => Query("SELECT * FROM clips ORDER BY last_copied DESC");

    public ClipItem? Find(Guid id) => Query("SELECT * FROM clips WHERE id = $id", ("$id", id.ToString())).FirstOrDefault();

    /// <summary>Items of one space (null = personal), newest first.</summary>
    public List<ClipItem> ItemsInSpace(string? spaceId) =>
        Query("SELECT * FROM clips WHERE space_id IS $s ORDER BY last_copied DESC", ("$s", spaceId));

    /// <summary>Same content in the same space (dedupe never crosses spaces).</summary>
    public ClipItem? ItemWithHash(string hash, string? spaceId = null) =>
        Query("SELECT * FROM clips WHERE hash = $h AND space_id IS $s ORDER BY pinned DESC, last_copied DESC LIMIT 1",
            ("$h", hash), ("$s", spaceId)).FirstOrDefault();

    public int Count() => Convert.ToInt32(Scalar("SELECT COUNT(*) FROM clips"));

    // MARK: Writes

    /// <summary>Inserts a capture, or — if identical content exists — moves that item to the top.</summary>
    public ClipItem Ingest(ProcessedCapture capture, DateTime? now = null, string? spaceId = null)
    {
        var time = now ?? DateTime.UtcNow;
        if (ItemWithHash(capture.Hash, spaceId) is { } existing)
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
        item.SpaceId = spaceId;
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

    /// <summary>Clears the personal history; group items belong to the group and stay.</summary>
    public void ClearHistory(bool includingPinned = false)
    {
        foreach (var item in ItemsInSpace(null).Where(i => includingPinned || !i.IsPinned)) Remove(item);
        Commit();
    }

    /// <summary>Replaces an item's content with new plain text (e.g. an AI result).</summary>
    public void ReplaceText(ClipItem item, string text)
    {
        var hash = ContentHasher.HashText(text);
        if (ItemWithHash(hash, item.SpaceId) is { } duplicate && duplicate.Id != item.Id) Remove(duplicate);
        Blobs.Delete(item.ImageFile);
        Blobs.Delete(item.ThumbnailFile);
        DeleteSyncedFiles(item.Id);
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

    /// <summary>Unpinned history each group keeps locally, matching the server's limit.</summary>
    public const int GroupHistoryLimit = 200;

    /// <summary>Pinned items are exempt. <paramref name="maxAge"/> null keeps forever; maxItems 0 = no count limit.
    /// The user's limits apply to the personal space; each group keeps its newest <see cref="GroupHistoryLimit"/>.
    /// Items removed here stop being tracked by sync rather than being deleted on other devices.</summary>
    public int EnforceRetention(int maxItems, TimeSpan? maxAge, DateTime? now = null)
    {
        var time = now ?? DateTime.UtcNow;
        var removed = 0;
        foreach (var space in AllItems().Where(i => !i.IsPinned).GroupBy(i => i.SpaceId))   // newest first
        {
            foreach (var (item, index) in space.Select((item, index) => (item, index)))
            {
                var expire = space.Key is null
                    ? (maxAge is { } age && item.LastCopiedAt < time - age) || (maxItems > 0 && index >= maxItems)
                    : index >= GroupHistoryLimit;
                if (!expire) continue;
                Remove(item);
                Exec("DELETE FROM sync_meta WHERE local_id = $id", ("$id", SyncId(item.Id)));
                removed++;
            }
        }
        if (removed > 0) Commit();
        return removed;
    }

    /// <summary>Collapses items with the same hash. Pinned items are never deleted.</summary>
    public int MergeDuplicates()
    {
        var removed = 0;
        foreach (var group in AllItems().GroupBy(i => (i.SpaceId, i.ContentHash)).Where(g => g.Count() > 1))
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

    /// <summary>Removes unpinned items of one space whose content hash is in <paramref name="hashes"/> (e.g. that space's saved secrets).</summary>
    public void RemoveUnpinned(IReadOnlySet<string> hashes, string? spaceId = null)
    {
        if (hashes.Count == 0) return;
        var removed = 0;
        foreach (var item in ItemsInSpace(spaceId).Where(i => !i.IsPinned && hashes.Contains(i.ContentHash)))
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
        if (!System.IO.Directory.Exists(SyncedFilesDirectory)) return;
        // Recent folders may belong to an item sync is still downloading.
        var ids = AllItems().Select(i => SyncId(i.Id)).ToHashSet();
        foreach (var folder in System.IO.Directory.EnumerateDirectories(SyncedFilesDirectory).ToList())
            if (!ids.Contains(Path.GetFileName(folder)) && System.IO.Directory.GetLastWriteTimeUtc(folder) < DateTime.UtcNow.AddHours(-1))
                DeleteFolder(folder);
    }

    // MARK: Synced files

    /// <summary>The folder holding the files of a file item received through sync.</summary>
    public string SyncedFolder(Guid id) => Path.Combine(SyncedFilesDirectory, SyncId(id));

    public void DeleteSyncedFiles(Guid id) => DeleteFolder(SyncedFolder(id));

    /// <summary>Deletes the files in an item's synced folder that it no longer lists (all of them when it isn't a file item).</summary>
    public void PruneSyncedFiles(ClipItem item)
    {
        var folder = SyncedFolder(item.Id);
        if (!System.IO.Directory.Exists(folder)) return;
        var kept = item.Kind == ClipKind.File ? item.Files.ToHashSet(StringComparer.OrdinalIgnoreCase) : [];
        foreach (var file in System.IO.Directory.EnumerateFiles(folder).Where(f => !kept.Contains(f)).ToList())
            try { File.Delete(file); } catch { /* in use: removed with the folder later */ }
        if (!System.IO.Directory.EnumerateFileSystemEntries(folder).Any()) DeleteFolder(folder);
    }

    private static void DeleteFolder(string folder)
    {
        try { System.IO.Directory.Delete(folder, recursive: true); } catch { /* already gone or in use */ }
    }

    // MARK: Text in images

    /// <summary>Newest images whose text hasn't been read yet.</summary>
    public List<ClipItem> ImagesNeedingOcr(int limit) =>
        Query("SELECT * FROM clips WHERE kind = $k AND ocr_text IS NULL AND image_file IS NOT NULL ORDER BY last_copied DESC LIMIT $n",
            ("$k", (int)ClipKind.Image), ("$n", limit));

    /// <summary>Stores recognised text ("" = none). Local only: it isn't part of the sync payload, so no
    /// <see cref="Changed"/> (which would schedule a sync).</summary>
    public void SetOcrText(Guid id, string text)
    {
        Exec("UPDATE clips SET ocr_text = $t WHERE id = $id", ("$t", text), ("$id", id.ToString()));
        Revision++;
    }

    // MARK: Snippets

    public List<Snippet> AllSnippets()
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT id, name, keyword, body, created, updated, space_id FROM snippets ORDER BY name COLLATE NOCASE";
        using var r = cmd.ExecuteReader();
        var list = new List<Snippet>();
        while (r.Read())
            list.Add(new Snippet
            {
                Id = Guid.Parse(r.GetString(0)), Name = r.GetString(1), Keyword = r.GetString(2), Body = r.GetString(3),
                CreatedAt = FromUnix(r.GetInt64(4)), UpdatedAt = FromUnix(r.GetInt64(5)), SpaceId = r.IsDBNull(6) ? null : r.GetString(6),
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
        PutSnippet(snippet);
    }

    /// <summary>Inserts or replaces a snippet as given, keeping its timestamps (sync).</summary>
    public void PutSnippet(Snippet snippet)
    {
        Exec("""
            INSERT INTO snippets (id, name, keyword, body, created, updated, space_id) VALUES ($id, $n, $k, $b, $c, $u, $s)
            ON CONFLICT(id) DO UPDATE SET name = $n, keyword = $k, body = $b, updated = $u
            """,
            ("$id", snippet.Id.ToString()), ("$n", snippet.Name), ("$k", snippet.Keyword), ("$b", snippet.Body),
            ("$c", ToUnix(snippet.CreatedAt)), ("$u", ToUnix(snippet.UpdatedAt)), ("$s", snippet.SpaceId));
        Commit();
    }

    public void DeleteSnippet(Snippet snippet) => DeleteSnippet(snippet.Id);

    public void DeleteSnippet(Guid id)
    {
        Exec("DELETE FROM snippets WHERE id = $id", ("$id", id.ToString()));
        Commit();
    }

    // MARK: Spaces (sync)

    /// <summary>Inserts or replaces an item exactly as given (sync). Write its blobs first.</summary>
    public void Put(ClipItem item)
    {
        Save(item);
        Commit();
    }

    public void Delete(Guid id)
    {
        if (Find(id) is { } item) Delete(item);
    }

    /// <summary>Copies an item into another space with a new id and its own blob files.
    /// If that space already has the same content, it's moved to the top instead.</summary>
    public ClipItem CopyToSpace(ClipItem item, string? spaceId, DateTime? now = null)
    {
        var time = now ?? DateTime.UtcNow;
        if (ItemWithHash(item.ContentHash, spaceId) is { } existing)
        {
            existing.LastCopiedAt = time;
            Save(existing);
            Commit();
            return existing;
        }
        var copy = new ClipItem
        {
            CreatedAt = time, LastCopiedAt = time, Kind = item.Kind, Text = item.Text, Preview = item.Preview, Rtf = item.Rtf,
            Html = item.Html, ContentHash = item.ContentHash, Files = [.. item.Files], ImageWidth = item.ImageWidth,
            ImageHeight = item.ImageHeight, ByteCount = item.ByteCount, SourceId = item.SourceId, SourceName = item.SourceName,
            IsPinned = item.IsPinned, PinnedAt = item.PinnedAt, Label = item.Label, SpaceId = spaceId,
        };
        copy.ImageFile = CopyBlob(item.ImageFile, copy.Id.ToString("N") + ".png");
        copy.ThumbnailFile = CopyBlob(item.ThumbnailFile, copy.Id.ToString("N") + "-thumb.png");
        copy.Files = [.. item.Files.Select(f => CopySyncedFile(f, item.Id, copy.Id))];
        Save(copy);
        Commit();
        return copy;
    }

    public Snippet CopySnippetToSpace(Snippet snippet, string? spaceId)
    {
        var copy = new Snippet { Name = snippet.Name, Keyword = snippet.Keyword, Body = snippet.Body, SpaceId = spaceId };
        PutSnippet(copy);
        return copy;
    }

    private string? CopyBlob(string? name, string target)
    {
        if (name is null || !File.Exists(Blobs.PathFor(name))) return null;
        File.Copy(Blobs.PathFor(name), Blobs.PathFor(target), overwrite: true);
        return target;
    }

    /// <summary>A synced file belongs to its item's folder, which goes when the item does: the copy gets its own.</summary>
    private string CopySyncedFile(string path, Guid from, Guid to)
    {
        if (!string.Equals(Path.GetDirectoryName(path), SyncedFolder(from), StringComparison.OrdinalIgnoreCase) || !File.Exists(path)) return path;
        var target = Path.Combine(SyncedFolder(to), Path.GetFileName(path));
        System.IO.Directory.CreateDirectory(SyncedFolder(to));
        File.Copy(path, target, overwrite: true);
        return target;
    }

    /// <summary>Removes every item and snippet of a space (group left, deleted or signed out). Secrets live in the vault.</summary>
    public void DeleteSpaceData(string spaceId)
    {
        foreach (var item in ItemsInSpace(spaceId)) Remove(item);
        Exec("DELETE FROM snippets WHERE space_id = $s", ("$s", spaceId));
        Exec("DELETE FROM sync_meta WHERE space_id = $s", ("$s", spaceId));
        Exec("DELETE FROM sync_cursor WHERE space_id = $s", ("$s", spaceId));
        Exec("DELETE FROM sync_resync_seen WHERE space_id = $s", ("$s", spaceId));
        Exec("DELETE FROM sync_rejected WHERE space_id = $s", ("$s", spaceId));
        Exec("DELETE FROM sync_spaces WHERE id = $s", ("$s", spaceId));
        Commit();
    }

    /// <summary>Sign-out: drops group items and snippets and all sync state. Personal items stay.</summary>
    public void ResetSync()
    {
        foreach (var item in Query("SELECT * FROM clips WHERE space_id IS NOT NULL")) Remove(item);
        Exec("DELETE FROM snippets WHERE space_id IS NOT NULL");
        Exec("DELETE FROM sync_meta; DELETE FROM sync_cursor; DELETE FROM sync_spaces; DELETE FROM sync_resync_seen; DELETE FROM sync_rejected;");
        Commit();
    }

    /// <summary>When two items of one space share a content hash, the lexicographically smaller id wins: it takes
    /// the summed copy count, the later copy time and the label and pin of either; the others are deleted.</summary>
    public int ConvergeDuplicates(string? spaceId)
    {
        var removed = 0;
        foreach (var group in ItemsInSpace(spaceId).GroupBy(i => i.ContentHash).Where(g => g.Count() > 1))
        {
            var ordered = group.OrderBy(i => SyncId(i.Id), StringComparer.Ordinal).ToList();
            var winner = ordered[0];
            var losers = ordered.Skip(1).ToList();
            winner.CopyCount = group.Sum(i => i.CopyCount);
            winner.LastCopiedAt = group.Max(i => i.LastCopiedAt);
            winner.Label ??= losers.Select(l => l.Label).FirstOrDefault(l => l is not null);
            if (group.Any(i => i.IsPinned))
            {
                winner.IsPinned = true;
                winner.PinnedAt = group.Where(i => i.PinnedAt is not null).Select(i => i.PinnedAt).Min() ?? winner.LastCopiedAt;
            }
            Save(winner);
            foreach (var loser in losers)
            {
                Remove(loser);
                removed++;
            }
        }
        if (removed > 0) Commit();
        return removed;
    }

    /// <summary>The id used on the server: lowercase hyphenated.</summary>
    public static string SyncId(Guid id) => id.ToString("D");

    // MARK: Sync state

    public List<SyncMeta> SyncMetas(string spaceId) => QueryMeta(spaceId, null);

    public SyncMeta? SyncMetaFor(string spaceId, string localId) => QueryMeta(spaceId, localId).FirstOrDefault();

    private List<SyncMeta> QueryMeta(string spaceId, string? localId)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT space_id, local_id, category, fingerprint, remote_seq, updated_at, trimmed, blobs, author_uid FROM sync_meta WHERE space_id = $s"
            + (localId is null ? "" : " AND local_id = $id");
        cmd.Parameters.AddWithValue("$s", spaceId);
        if (localId is not null) cmd.Parameters.AddWithValue("$id", localId);
        using var r = cmd.ExecuteReader();
        var list = new List<SyncMeta>();
        while (r.Read())
            list.Add(new SyncMeta(r.GetString(0), r.GetString(1), r.GetString(2), r.GetString(3), r.GetInt64(4), r.GetInt64(5),
                r.GetInt64(6) != 0, r.IsDBNull(7) ? null : JsonSerializer.Deserialize<Dictionary<string, string>>(r.GetString(7)),
                r.IsDBNull(8) ? null : r.GetString(8)));
        return list;
    }

    /// <summary>The author of every group item the server knows about, by (space, item id); null where it isn't known.
    /// Group items missing here haven't been sent yet, so they're this user's own.</summary>
    public Dictionary<(string Space, string LocalId), string?> GroupAuthors()
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT space_id, local_id, author_uid FROM sync_meta WHERE space_id IN (SELECT id FROM sync_spaces WHERE kind = 'group')";
        using var r = cmd.ExecuteReader();
        var authors = new Dictionary<(string, string), string?>();
        while (r.Read()) authors[(r.GetString(0), r.GetString(1))] = r.IsDBNull(2) ? null : r.GetString(2);
        return authors;
    }

    public void SaveSyncMeta(SyncMeta meta) => Exec("""
        INSERT INTO sync_meta (space_id, local_id, category, fingerprint, remote_seq, updated_at, trimmed, blobs, author_uid)
        VALUES ($s, $id, $c, $f, $seq, $u, $t, $b, $a)
        ON CONFLICT(space_id, local_id) DO UPDATE SET category = $c, fingerprint = $f, remote_seq = $seq, updated_at = $u,
            trimmed = $t, blobs = $b, author_uid = $a
        """,
        ("$s", meta.SpaceId), ("$id", meta.LocalId), ("$c", meta.Category), ("$f", meta.Fingerprint), ("$seq", meta.RemoteSeq),
        ("$u", meta.UpdatedAt), ("$t", meta.Trimmed ? 1 : 0), ("$b", meta.Blobs is { Count: > 0 } b ? JsonSerializer.Serialize(b) : null),
        ("$a", meta.AuthorUid));

    public void DeleteSyncMeta(string spaceId, string localId) =>
        Exec("DELETE FROM sync_meta WHERE space_id = $s AND local_id = $id", ("$s", spaceId), ("$id", localId));

    public long SyncCursor(string spaceId) =>
        Scalar("SELECT since FROM sync_cursor WHERE space_id = $s", ("$s", spaceId)) is long since ? since : 0;

    public void SetSyncCursor(string spaceId, long since) => Exec(
        "INSERT INTO sync_cursor (space_id, since) VALUES ($s, $n) ON CONFLICT(space_id) DO UPDATE SET since = $n",
        ("$s", spaceId), ("$n", since));

    // A full re-sync (resetRequired) in progress: the flag and the ids pulled so far live next to the cursor, so an
    // interrupted one carries on where it stopped and still reconciles at the end.

    public bool IsResyncing(string spaceId) =>
        Scalar("SELECT resync FROM sync_cursor WHERE space_id = $s", ("$s", spaceId)) is long flag && flag != 0;

    /// <summary>Starts (or restarts) a re-sync from <c>since=0</c>.</summary>
    public void BeginResync(string spaceId)
    {
        Exec("INSERT INTO sync_cursor (space_id, since, resync) VALUES ($s, 0, 1) ON CONFLICT(space_id) DO UPDATE SET since = 0, resync = 1", ("$s", spaceId));
        Exec("DELETE FROM sync_resync_seen WHERE space_id = $s", ("$s", spaceId));
    }

    public void MarkResyncSeen(string spaceId, IEnumerable<string> ids)
    {
        foreach (var id in ids) Exec("INSERT OR IGNORE INTO sync_resync_seen (space_id, local_id) VALUES ($s, $id)", ("$s", spaceId), ("$id", id));
    }

    public HashSet<string> ResyncSeen(string spaceId)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT local_id FROM sync_resync_seen WHERE space_id = $s";
        cmd.Parameters.AddWithValue("$s", spaceId);
        using var r = cmd.ExecuteReader();
        var seen = new HashSet<string>();
        while (r.Read()) seen.Add(r.GetString(0));
        return seen;
    }

    public void EndResync(string spaceId)
    {
        Exec("UPDATE sync_cursor SET resync = 0 WHERE space_id = $s", ("$s", spaceId));
        Exec("DELETE FROM sync_resync_seen WHERE space_id = $s", ("$s", spaceId));
    }

    // Items the server refused for good (too large, invalid, not allowed), by the fingerprint that was refused:
    // they're tried again only once they change.

    /// <summary>Local id → refused fingerprint, for one space.</summary>
    public Dictionary<string, string> SyncRejections(string spaceId)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT local_id, fingerprint FROM sync_rejected WHERE space_id = $s";
        cmd.Parameters.AddWithValue("$s", spaceId);
        using var r = cmd.ExecuteReader();
        var map = new Dictionary<string, string>();
        while (r.Read()) map[r.GetString(0)] = r.GetString(1);
        return map;
    }

    public void SetSyncRejected(string spaceId, string localId, string fingerprint, string reason) => Exec("""
        INSERT INTO sync_rejected (space_id, local_id, fingerprint, reason) VALUES ($s, $id, $f, $r)
        ON CONFLICT(space_id, local_id) DO UPDATE SET fingerprint = $f, reason = $r
        """, ("$s", spaceId), ("$id", localId), ("$f", fingerprint), ("$r", reason));

    public void ClearSyncRejected(string spaceId, string localId) =>
        Exec("DELETE FROM sync_rejected WHERE space_id = $s AND local_id = $id", ("$s", spaceId), ("$id", localId));

    public List<SpaceRecord> SyncSpaces()
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT id, kind, role, name, owner_uid, member_count, members FROM sync_spaces";
        using var r = cmd.ExecuteReader();
        var list = new List<SpaceRecord>();
        while (r.Read())
            list.Add(new SpaceRecord(r.GetString(0), r.GetString(1), r.GetString(2), r.IsDBNull(3) ? null : r.GetString(3), r.GetString(4), r.GetInt32(5),
                r.IsDBNull(6) ? null : JsonSerializer.Deserialize<Dictionary<string, string>>(r.GetString(6))));
        return list.OrderBy(s => s.IsGroup).ThenBy(s => s.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    /// <summary>Groups the user belongs to, by name.</summary>
    public List<SpaceRecord> Groups() => SyncSpaces().Where(s => s.IsGroup).ToList();

    /// <summary>Replaces the cached spaces; a no-op (and no <see cref="Changed"/>) when nothing differs.</summary>
    public void SaveSyncSpaces(IEnumerable<SpaceRecord> spaces)
    {
        var list = spaces.ToList();
        var current = SyncSpaces();
        if (current.Count == list.Count && list.All(current.Contains)) return;
        Exec("DELETE FROM sync_spaces");
        foreach (var s in list)
            Exec("INSERT INTO sync_spaces (id, kind, role, name, owner_uid, member_count, members) VALUES ($id, $k, $r, $n, $o, $m, $mm)",
                ("$id", s.Id), ("$k", s.Kind), ("$r", s.Role), ("$n", s.Name), ("$o", s.OwnerUid), ("$m", s.MemberCount),
                ("$mm", s.Members is null ? null : JsonSerializer.Serialize(s.Members)));
        Commit();
    }

    // MARK: Batching

    private int _batchDepth;
    private bool _pendingCommit;

    /// <summary>Groups many writes into one transaction and one <see cref="Changed"/>.</summary>
    public IDisposable Batch()
    {
        if (_batchDepth++ == 0) Exec("BEGIN");
        return new BatchScope(this);
    }

    private void EndBatch()
    {
        if (--_batchDepth > 0) return;
        Exec("COMMIT");
        if (_pendingCommit)
        {
            _pendingCommit = false;
            Commit();
        }
    }

    private sealed class BatchScope(ClipStore store) : IDisposable
    {
        private bool _disposed;
        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            store.EndBatch();
        }
    }

    // MARK: Private

    private void Remove(ClipItem item)
    {
        Blobs.Delete(item.ImageFile);
        Blobs.Delete(item.ThumbnailFile);
        DeleteSyncedFiles(item.Id);
        Exec("DELETE FROM clips WHERE id = $id", ("$id", item.Id.ToString()));
    }

    private void Save(ClipItem i) => Exec("""
        INSERT INTO clips (id, created, last_copied, kind, text, preview, rtf, html, hash, files, image_file, thumb_file,
                           width, height, bytes, source_id, source_name, pinned, pinned_at, label, copy_count, space_id)
        VALUES ($id, $created, $last, $kind, $text, $preview, $rtf, $html, $hash, $files, $img, $thumb,
                $w, $h, $bytes, $sid, $sname, $pinned, $pinnedAt, $label, $count, $space)
        ON CONFLICT(id) DO UPDATE SET last_copied = $last, kind = $kind, text = $text, preview = $preview, rtf = $rtf,
            html = $html, hash = $hash, files = $files, image_file = $img, thumb_file = $thumb, width = $w, height = $h,
            bytes = $bytes, source_id = $sid, source_name = $sname, pinned = $pinned, pinned_at = $pinnedAt,
            label = $label, copy_count = $count, created = $created
        """,
        ("$id", i.Id.ToString()), ("$created", ToUnix(i.CreatedAt)), ("$last", ToUnix(i.LastCopiedAt)), ("$kind", (int)i.Kind),
        ("$text", i.Text), ("$preview", i.Preview), ("$rtf", i.Rtf), ("$html", i.Html), ("$hash", i.ContentHash),
        ("$files", JsonSerializer.Serialize(i.Files)), ("$img", i.ImageFile), ("$thumb", i.ThumbnailFile),
        ("$w", i.ImageWidth), ("$h", i.ImageHeight), ("$bytes", i.ByteCount), ("$sid", i.SourceId), ("$sname", i.SourceName),
        ("$pinned", i.IsPinned ? 1 : 0), ("$pinnedAt", i.PinnedAt is { } p ? ToUnix(p) : null), ("$label", i.Label),
        ("$count", i.CopyCount), ("$space", i.SpaceId));

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
                SpaceId = Str("space_id"),
                OcrText = Str("ocr_text"),
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

    private object? Scalar(string sql, params (string, object?)[] args)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        foreach (var (name, value) in args) cmd.Parameters.AddWithValue(name, value ?? DBNull.Value);
        return cmd.ExecuteScalar();
    }

    private void Commit()
    {
        if (_batchDepth > 0)
        {
            _pendingCommit = true;
            return;
        }
        Revision++;
        Changed?.Invoke();
    }

    private static long ToUnix(DateTime t) => new DateTimeOffset(DateTime.SpecifyKind(t, DateTimeKind.Utc)).ToUnixTimeMilliseconds();
    private static DateTime FromUnix(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime;
}
