using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace Clipboard2.Core.Sync;

/// <summary>Who is syncing: the unwrapped identity key pair and the personal space.</summary>
public sealed record SyncIdentity(string Uid, string Email, EcKeyPair Keys, string PersonalSpaceId);

/// <summary>A space whose key this device has unwrapped.</summary>
public sealed class SyncSpace(SpaceInfo info, byte[] key, string? name)
{
    public SpaceInfo Info { get; internal set; } = info;
    public byte[] Key { get; } = key;
    public byte[] ItemKey { get; } = SyncCrypto.ItemKey(key);
    public byte[] NameKey { get; } = SyncCrypto.NameKey(key);
    public string? Name { get; internal set; } = name;
    public string Id => Info.Id;
    public bool IsPersonal => Info.IsPersonal;
    /// <summary>The <c>space_id</c> used locally: null for the personal space.</summary>
    public string? LocalId => IsPersonal ? null : Id;
    public SpaceRecord Record => new(Id, Info.Kind, Info.Role, Name, Info.OwnerUid, Info.MemberCount, Info.Members);
}

/// <summary>What one tick did.</summary>
public sealed class SyncReport
{
    public int Pulled { get; set; }
    public int Pushed { get; set; }
    public int Deleted { get; set; }
    public List<string> Warnings { get; } = [];
}

/// <summary>The personal space is gone from the server: the account was deleted elsewhere.</summary>
public sealed class SyncAccountGoneException() : Exception("Your sync account no longer exists.");

/// <summary>
/// One sync tick (docs/sync/PROTOCOL.md → Client sync rules): refresh spaces, then per space pull before push.
/// Change detection compares payload fingerprints with the sync_meta table. Drive it from the store's thread
/// (the UI thread in the app): network calls are awaited and every store access happens between them.
/// </summary>
public sealed partial class SyncEngine(ClipStore store, ISecretVault vault, SyncApi api, SyncIdentity identity, Func<DateTime>? clock = null)
{
    public const int HistoryLimit = 200;
    public const int PageSize = 500;
    public const int MaxItemBytes = 2 * 1024 * 1024;
    public const int MaxBlobBytes = 25 * 1024 * 1024;
    public const int MaxFilesPerItem = 10;

    private readonly Func<DateTime> _now = clock ?? (() => DateTime.UtcNow);
    private readonly Dictionary<string, SyncSpace> _spaces = [];
    /// <summary>Items refused for good (too large, invalid), id → fingerprint, so they aren't retried until they change.</summary>
    private readonly Dictionary<string, string> _rejected = [];

    public SyncIdentity Identity { get; } = identity;
    public Action<string>? Logger { get; set; }
    public IReadOnlyCollection<SyncSpace> Spaces => _spaces.Values;
    public SyncSpace? Space(string id) => _spaces.GetValueOrDefault(id);

    private long NowMs => SyncPayload.Millis(_now());

    // MARK: Tick

    public async Task<SyncReport> TickAsync(CancellationToken ct = default)
    {
        var report = new SyncReport();
        await RefreshSpacesAsync(ct);
        // Groups first, and every download before any upload: a long first upload (or a rate limit
        // while sending it) must never keep new group items from arriving.
        var spaces = _spaces.Values.OrderBy(s => s.IsPersonal).ToList();
        foreach (var space in spaces)
        {
            ct.ThrowIfCancellationRequested();
            await PullAsync(space, report, ct);
        }
        foreach (var space in spaces)
        {
            ct.ThrowIfCancellationRequested();
            await PushAsync(space, report, ct);
        }
        return report;
    }

    /// <summary>GET /v1/spaces, unwrapping new keys. Spaces the user left or lost lose their local data.</summary>
    public async Task RefreshSpacesAsync(CancellationToken ct = default)
    {
        var infos = await api.GetSpacesAsync(ct);
        if (!infos.Any(s => s.IsPersonal && s.Id == Identity.PersonalSpaceId)) throw new SyncAccountGoneException();
        var live = infos.Select(s => s.Id).ToHashSet();
        foreach (var info in infos)
        {
            if (_spaces.TryGetValue(info.Id, out var known) && known.Info.WrappedKey.AsSpan().SequenceEqual(info.WrappedKey))
            {
                known.Info = info;
                known.Name = DecryptName(known, info);
                continue;
            }
            try
            {
                var key = SyncCrypto.UnwrapSpaceKey(info.WrappedKey, info.Id, Identity.Uid, Identity.Keys);
                var space = new SyncSpace(info, key, null);
                space.Name = DecryptName(space, info);
                _spaces[info.Id] = space;
            }
            catch (CryptographicException ex)
            {
                Logger?.Invoke($"Couldn't unwrap the key of space {info.Id}: {ex.Message}");
            }
        }
        foreach (var gone in _spaces.Keys.Where(id => !live.Contains(id)).ToList()) _spaces.Remove(gone);
        foreach (var record in store.SyncSpaces().Where(r => r.IsGroup && !live.Contains(r.Id))) RemoveGroupLocally(record.Id);
        store.SaveSyncSpaces(_spaces.Values.Select(s => s.Record));
    }

    /// <summary>Deletes a group's items, snippets, secrets and sync state on this device.</summary>
    public void RemoveGroupLocally(string spaceId)
    {
        _spaces.Remove(spaceId);
        foreach (var secret in vault.Secrets.Where(s => s.SpaceId == spaceId).ToList()) vault.Delete(secret);
        store.DeleteSpaceData(spaceId);
    }

    /// <summary>Registers a group created on this device so it can be used before the next tick.</summary>
    public void AddSpace(SpaceInfo info, byte[] key, string name)
    {
        _spaces[info.Id] = new SyncSpace(info, key, name);
        store.SaveSyncSpaces(_spaces.Values.Select(s => s.Record));
    }

    private static string? DecryptName(SyncSpace space, SpaceInfo info)
    {
        if (info.EncryptedName is not { Length: > 0 } sealedName) return null;
        try { return Encoding.UTF8.GetString(SyncCrypto.Open(space.NameKey, sealedName, SyncCrypto.Aad.Name(info.Id))); }
        catch (CryptographicException) { return null; }
    }

    // MARK: Pull

    private sealed record Prepared(RemoteItem Item, ItemPayload? Payload, Dictionary<string, string> Blobs);

    private async Task PullAsync(SyncSpace space, SyncReport report, CancellationToken ct)
    {
        var since = store.SyncCursor(space.Id);
        var reset = false;
        var seen = new HashSet<string>();
        while (true)
        {
            var page = await api.ChangesAsync(space.Id, since, PageSize, ct);
            if (page.ResetRequired)
            {
                if (reset) break;   // the server keeps asking: give up for this tick
                reset = true;
                since = 0;
                seen.Clear();
                store.SetSyncCursor(space.Id, 0);
                continue;
            }
            var prepared = new List<Prepared>();
            foreach (var item in page.Items)
            {
                seen.Add(item.Id);
                if (await PrepareAsync(space, item, ct) is { } p) prepared.Add(p);
            }
            using (store.Batch())
            {
                foreach (var p in prepared)
                {
                    Apply(space, p);
                    report.Pulled++;
                }
                since = Math.Max(since, page.NextSince);
                store.SetSyncCursor(space.Id, since);
            }
            if (!page.HasMore || page.Items.Count == 0) break;
        }
        if (reset) Reconcile(space, seen);
    }

    /// <summary>After a full re-sync: whatever the server no longer knows was deleted or trimmed long ago.</summary>
    private void Reconcile(SyncSpace space, HashSet<string> seen)
    {
        using var _ = store.Batch();
        foreach (var meta in store.SyncMetas(space.Id).Where(m => !seen.Contains(m.LocalId)))
        {
            if (!space.IsPersonal) DeleteLocal(space, meta.LocalId, meta.Category);
            store.DeleteSyncMeta(space.Id, meta.LocalId);
        }
    }

    /// <summary>Decrypts and downloads blobs (writing them to disk) — everything async, before the item is applied.</summary>
    private async Task<Prepared?> PrepareAsync(SyncSpace space, RemoteItem item, CancellationToken ct)
    {
        var meta = store.SyncMetaFor(space.Id, item.Id);
        if (meta is not null && item.Seq <= meta.RemoteSeq)   // already applied (often our own write)
        {
            // Synced before authors were kept: learn it now (schema v2 pulls groups again once for this).
            if (meta.AuthorUid is null && item.AuthorUid is not null) store.SaveSyncMeta(meta with { AuthorUid = item.AuthorUid });
            return null;
        }
        if (!Guid.TryParse(item.Id, out var id)) return null;
        if (item.Deleted is not null || item.Ciphertext is null) return new Prepared(item, null, []);
        ItemPayload? payload;
        try
        {
            var plaintext = SyncCrypto.Open(space.ItemKey, item.Ciphertext, SyncCrypto.Aad.Item(space.Id, item.Id, item.Category));
            payload = SyncPayload.Parse(plaintext, id, space.LocalId);
        }
        catch (Exception ex) when (ex is CryptographicException or System.Text.Json.JsonException or FormatException or InvalidOperationException)
        {
            Logger?.Invoke($"Skipping item {item.Id} in {space.Id}: {ex.Message}");
            return null;
        }
        if (payload is null) return null;
        var blobs = new Dictionary<string, string>();
        if (payload is ItemPayload.Clip clip)
        {
            var known = (meta?.BlobMap ?? new Dictionary<string, string>()).ToDictionary(p => p.Value, p => p.Key);   // blob id → file
            try
            {
                clip.Item.ImageFile = await LocalBlobAsync(space, clip.ImageBlob, known, blobs, ct);
                clip.Item.ThumbnailFile = await LocalBlobAsync(space, clip.ThumbBlob, known, blobs, ct);
            }
            catch (Exception ex) when (ex is SyncApiException { Code: not "network" } or CryptographicException or IOException)
            {
                Logger?.Invoke($"Skipping image item {item.Id}: {ex.Message}");
                foreach (var file in blobs.Keys.Where(f => !known.ContainsValue(f))) store.Blobs.Delete(file);
                return null;
            }
            if (clip.Item.Kind == ClipKind.Image && clip.Item.ImageFile is null) return null;
            if (clip.FileBlobs.Count > 0) await ReceiveFilesAsync(space, clip, known, blobs, ct);
        }
        return new Prepared(item, payload, blobs);
    }

    /// <summary>Writes a file item's blobs to its synced folder, keeping local copies that are still intact, and makes
    /// it a file item. A file that can't be fetched is left out; with none at all it stays text listing the paths.</summary>
    private async Task ReceiveFilesAsync(SyncSpace space, ItemPayload.Clip clip, Dictionary<string, string> known,
                                         Dictionary<string, string> blobs, CancellationToken ct)
    {
        var item = clip.Item;
        var entries = clip.FileBlobs.Where(f => Guid.TryParse(f.Blob, out _)).Take(MaxFilesPerItem).ToList();
        var files = new string?[entries.Count];
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        // Kept files first, so a new file with the same name can't overwrite one of them.
        for (var i = 0; i < entries.Count; i++)
        {
            if (!known.TryGetValue(entries[i].Blob, out var key) || ParseFileKey(key) is not { } kept || FileSize(kept.Path) != kept.Size) continue;
            files[i] = kept.Path;
            blobs[key] = entries[i].Blob;
            names.Add(Path.GetFileName(kept.Path));
        }
        var folder = store.SyncedFolder(item.Id);
        for (var i = 0; i < entries.Count; i++)
        {
            if (files[i] is not null) continue;
            var entry = entries[i];
            try
            {
                var url = await api.BlobUrlAsync(space.Id, entry.Blob, ct);
                var bytes = SyncCrypto.Open(space.ItemKey, await api.DownloadAsync(url, ct), SyncCrypto.Aad.Blob(space.Id, entry.Blob));
                var name = UniqueName(SafeFileName(entry.Name), names);
                var path = Path.Combine(folder, name);
                Directory.CreateDirectory(folder);
                await File.WriteAllBytesAsync(path + ".tmp", bytes, ct);
                File.Move(path + ".tmp", path, overwrite: true);
                names.Add(name);
                files[i] = path;
                blobs[FileKey(path, bytes.Length)] = entry.Blob;
            }
            catch (Exception ex) when (ex is SyncApiException { Code: not "network" } or CryptographicException or IOException or UnauthorizedAccessException)
            {
                Logger?.Invoke($"Skipping a file of item {ClipStore.SyncId(item.Id)}: {ex.Message}");
            }
        }
        var received = files.OfType<string>().ToList();
        if (received.Count == 0) return;
        var shown = ProcessedCapture.ForFiles(received);
        item.Kind = ClipKind.File;
        item.Files = received;
        item.Text = shown.Text;
        item.Preview = shown.Preview;
    }

    /// <summary>A received file name made safe for a folder: its last path component without the characters Windows
    /// forbids, and never empty, "." or "..".</summary>
    public static string SafeFileName(string name)
    {
        var last = name.TrimEnd('/', '\\');
        last = last[(last.LastIndexOfAny(['/', '\\']) + 1)..];
        var invalid = Path.GetInvalidFileNameChars().Concat("<>:\"/\\|?*").ToHashSet();
        var safe = new string([.. last.Where(c => c >= ' ' && !invalid.Contains(c))]).TrimEnd('.', ' ');   // Windows drops trailing dots
        if (safe.Length == 0) return "file";
        return ReservedName().IsMatch(safe) ? "_" + safe : safe;
    }

    [System.Text.RegularExpressions.GeneratedRegex(@"^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$", System.Text.RegularExpressions.RegexOptions.IgnoreCase)]
    private static partial System.Text.RegularExpressions.Regex ReservedName();

    /// <summary>"name.ext", or "name (2).ext" and so on when an earlier file of the item took it.</summary>
    private static string UniqueName(string name, HashSet<string> taken)
    {
        var stem = Path.GetFileNameWithoutExtension(name);
        var ext = Path.GetExtension(name);
        var candidate = name;
        for (var n = 2; taken.Contains(candidate); n++) candidate = $"{stem} ({n}){ext}";
        return candidate;
    }

    private async Task<string?> LocalBlobAsync(SyncSpace space, string? blobId, Dictionary<string, string> known,
                                               Dictionary<string, string> blobs, CancellationToken ct)
    {
        if (blobId is null || !Guid.TryParse(blobId, out _)) return null;
        if (known.TryGetValue(blobId, out var existing) && File.Exists(store.Blobs.PathFor(existing)))
        {
            blobs[existing] = blobId;
            return existing;
        }
        var url = await api.BlobUrlAsync(space.Id, blobId, ct);
        var ciphertext = await api.DownloadAsync(url, ct);
        var bytes = SyncCrypto.Open(space.ItemKey, ciphertext, SyncCrypto.Aad.Blob(space.Id, blobId));
        var file = blobId + ".png";
        store.Blobs.Write(bytes, file);
        blobs[file] = blobId;
        return file;
    }

    private void Apply(SyncSpace space, Prepared p)
    {
        var item = p.Item;
        switch (item.Deleted)
        {
            case "trimmed" when space.IsPersonal:
                // The server keeps 200; this device keeps its own longer history.
                if (store.SyncMetaFor(space.Id, item.Id) is { } meta)
                    store.SaveSyncMeta(meta with { Trimmed = true, RemoteSeq = item.Seq });
                return;
            case not null:
                DeleteLocal(space, item.Id, item.Category);
                store.DeleteSyncMeta(space.Id, item.Id);
                return;
        }
        var id = Guid.Parse(item.Id);
        switch (p.Payload)
        {
            case ItemPayload.Clip clip:
                if (store.Find(id) is { } old)
                {
                    if (old.ImageFile is { } f && f != clip.Item.ImageFile) store.Blobs.Delete(f);
                    if (old.ThumbnailFile is { } t && t != clip.Item.ThumbnailFile) store.Blobs.Delete(t);
                }
                store.Put(clip.Item);
                store.PruneSyncedFiles(clip.Item);   // files the previous version had
                break;
            case ItemPayload.SnippetPayload s:
                store.PutSnippet(s.Snippet);
                break;
            case ItemPayload.Secret secret:
                vault.Put(id, secret.Name, secret.Value, space.LocalId);
                break;
        }
        // Remember the local rendering, so a payload written by another platform doesn't bounce back.
        // Without a local copy (e.g. Credential Manager refused the write) there's no meta, so nothing is deleted remotely.
        if (Local(space, item.Id, item.Category) is not { } local) return;
        var fingerprint = SyncPayload.Fingerprint(Render(local, p.Blobs).Payload);
        var author = item.AuthorUid ?? store.SyncMetaFor(space.Id, item.Id)?.AuthorUid;
        store.SaveSyncMeta(new SyncMeta(space.Id, item.Id, item.Category, fingerprint, item.Seq, item.UpdatedAt, false, p.Blobs, author));
    }

    private void DeleteLocal(SyncSpace space, string itemId, string category)
    {
        if (!Guid.TryParse(itemId, out var id)) return;
        if (store.Find(id) is { } clip && clip.SpaceId == space.LocalId) store.Delete(clip);
        if (category is SyncCategory.History or SyncCategory.Pinned) return;
        if (store.AllSnippets().FirstOrDefault(s => s.Id == id && s.SpaceId == space.LocalId) is { } snippet) store.DeleteSnippet(snippet);
        if (vault.Secrets.FirstOrDefault(s => SecretGuid(s) == id && s.SpaceId == space.LocalId) is { } secret) vault.Delete(secret);
    }

    // MARK: Local items

    private abstract record LocalItem(string Id)
    {
        public sealed record Clip(string Id, ClipItem Item) : LocalItem(Id);
        public sealed record SnippetItem(string Id, Snippet Snippet) : LocalItem(Id);
        public sealed record Secret(string Id, SecretRef Ref, string Value) : LocalItem(Id);
    }

    private sealed record Rendered(JsonObject Payload, string Category, long SortAt);

    private Rendered Render(LocalItem local, IReadOnlyDictionary<string, string> blobs, bool includeRichText = true) => local switch
    {
        LocalItem.Clip c => new(
            SyncPayload.ForClip(c.Item, Lookup(blobs, c.Item.ImageFile), Lookup(blobs, c.Item.ThumbnailFile), includeRichText, FileBlobs(c.Item, blobs)),
            SyncCategory.ForClip(c.Item), SyncPayload.Millis(c.Item.LastCopiedAt)),
        LocalItem.SnippetItem s => new(SyncPayload.ForSnippet(s.Snippet), SyncCategory.Snippet, SyncPayload.Millis(s.Snippet.UpdatedAt)),
        LocalItem.Secret k => new(SyncPayload.ForSecret(k.Ref.Name, k.Value, k.Ref.CreatedAt), SyncCategory.Secret,
            SyncPayload.Millis(k.Ref.CreatedAt ?? _now())),
        _ => throw new InvalidOperationException(),
    };

    private static string? Lookup(IReadOnlyDictionary<string, string> blobs, string? file) =>
        file is not null && blobs.TryGetValue(file, out var id) ? id : null;

    // A file's blob map key is "path|size": a file whose size changed on disk no longer matches, so it's uploaded again.
    private static string FileKey(string path, long size) => $"{path}|{size}";

    private static (string Path, long Size)? ParseFileKey(string key)
    {
        var bar = key.LastIndexOf('|');
        return bar > 0 && long.TryParse(key.AsSpan(bar + 1), out var size) ? (key[..bar], size) : null;
    }

    /// <summary>The length of a regular file, or null for a folder or a missing file.</summary>
    private static long? FileSize(string path)
    {
        try { return new FileInfo(path) is { Exists: true } info ? info.Length : null; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
    }

    /// <summary>The files of a file item that are on the server (in <paramref name="blobs"/>), in the item's order.</summary>
    private static List<FileBlob> FileBlobs(ClipItem item, IReadOnlyDictionary<string, string> blobs)
    {
        if (item.Kind != ClipKind.File || blobs.Count == 0) return [];
        var uploaded = new Dictionary<string, (long Size, string Blob)>();
        foreach (var (key, blob) in blobs)
            if (ParseFileKey(key) is { } k) uploaded[k.Path] = (k.Size, blob);
        var list = new List<FileBlob>();
        foreach (var path in item.Files.Distinct())
            if (uploaded.TryGetValue(path, out var u) && FileSize(path) == u.Size) list.Add(new FileBlob(Path.GetFileName(path), u.Blob, u.Size));
        return list;
    }

    private LocalItem? Local(SyncSpace space, string itemId, string category)
    {
        if (!Guid.TryParse(itemId, out var id)) return null;
        if (store.Find(id) is { } clip && clip.SpaceId == space.LocalId) return new LocalItem.Clip(itemId, clip);
        if (store.AllSnippets().FirstOrDefault(s => s.Id == id && s.SpaceId == space.LocalId) is { } snippet)
            return new LocalItem.SnippetItem(itemId, snippet);
        if (vault.Secrets.FirstOrDefault(s => SecretGuid(s) == id && s.SpaceId == space.LocalId) is { } secret
            && vault.ReadValue(secret) is { } value)
            return new LocalItem.Secret(itemId, secret, value);
        return null;
    }

    private static Guid? SecretGuid(SecretRef secret) => Guid.TryParse(secret.Id, out var g) ? g : null;

    /// <summary>Everything in a space that should be on the server. Personal history: only the newest 200.</summary>
    private (List<LocalItem> Push, HashSet<string> Live) LocalItems(SyncSpace space)
    {
        var push = new List<LocalItem>();
        var live = new HashSet<string>();
        var history = 0;
        foreach (var clip in store.ItemsInSpace(space.LocalId))   // newest first
        {
            var id = ClipStore.SyncId(clip.Id);
            live.Add(id);
            if (!clip.IsPinned && history++ >= HistoryLimit) continue;
            push.Add(new LocalItem.Clip(id, clip));
        }
        foreach (var snippet in store.AllSnippets().Where(s => s.SpaceId == space.LocalId))
        {
            var id = ClipStore.SyncId(snippet.Id);
            live.Add(id);
            push.Add(new LocalItem.SnippetItem(id, snippet));
        }
        foreach (var secret in vault.Secrets.Where(s => s.SpaceId == space.LocalId))
        {
            if (SecretGuid(secret) is not { } guid) continue;
            var id = ClipStore.SyncId(guid);
            live.Add(id);
            if (vault.ReadValue(secret) is { } value) push.Add(new LocalItem.Secret(id, secret, value));
        }
        return (push, live);
    }

    // MARK: Push

    private async Task PushAsync(SyncSpace space, SyncReport report, CancellationToken ct)
    {
        store.ConvergeDuplicates(space.LocalId);
        var metas = store.SyncMetas(space.Id).ToDictionary(m => m.LocalId);
        var (push, live) = LocalItems(space);
        try
        {
            foreach (var local in push)
            {
                ct.ThrowIfCancellationRequested();
                var meta = metas.GetValueOrDefault(local.Id);
                var rendered = Render(local, meta?.BlobMap ?? new Dictionary<string, string>());
                var fingerprint = SyncPayload.Fingerprint(rendered.Payload);
                if (meta is not null && meta.Category == rendered.Category && meta.Fingerprint == fingerprint) continue;
                if (_rejected.GetValueOrDefault(local.Id) == fingerprint) continue;
                try
                {
                    if (await PushItemAsync(space, local, meta, ct)) report.Pushed++;
                }
                catch (SyncApiException ex) when (ex.Code is "too_large" or "invalid")
                {
                    Logger?.Invoke($"Server refused item {local.Id}: {ex.Message}");
                    report.Warnings.Add(ex.Message);
                    _rejected[local.Id] = fingerprint;
                }
            }
            foreach (var meta in metas.Values.Where(m => !live.Contains(m.LocalId)))
            {
                ct.ThrowIfCancellationRequested();
                if (meta.Trimmed)
                {
                    store.DeleteSyncMeta(space.Id, meta.LocalId);
                    continue;
                }
                var outcome = await api.DeleteItemAsync(space.Id, meta.LocalId, Math.Max(NowMs, meta.UpdatedAt + 1), ct);
                switch (outcome)
                {
                    case WriteOutcome.Conflict { Current.Deleted: null } conflict:
                        await ApplyCurrentAsync(space, conflict.Current, ct);   // changed elsewhere after we deleted it: keep it
                        break;
                    default:
                        store.DeleteSyncMeta(space.Id, meta.LocalId);
                        report.Deleted++;
                        break;
                }
            }
        }
        catch (SyncApiException ex) when (ex.Code == "quota_exceeded")
        {
            Logger?.Invoke($"Sync quota reached in {space.Id}: {ex.Message}");
            report.Warnings.Add(ex.Message);
        }
    }

    /// <summary>Uploads new blobs, encrypts and PUTs one item. False when it was skipped.</summary>
    private async Task<bool> PushItemAsync(SyncSpace space, LocalItem local, SyncMeta? meta, CancellationToken ct)
    {
        var blobs = new Dictionary<string, string>();
        if (local is LocalItem.Clip { Item: var clip })
        {
            foreach (var file in new[] { clip.ImageFile, clip.ThumbnailFile }.OfType<string>())
            {
                // A trimmed item's blobs were deleted on the server; its map only keeps the fingerprint stable.
                if (meta is { Trimmed: false } && meta.BlobMap.TryGetValue(file, out var known)) { blobs[file] = known; continue; }
                var path = store.Blobs.PathFor(file);
                if (!File.Exists(path)) continue;
                var bytes = await File.ReadAllBytesAsync(path, ct);
                if (bytes.Length + 29 > MaxBlobBytes)
                {
                    Logger?.Invoke($"Image of {local.Id} is too large to sync");
                    _rejected[local.Id] = SyncPayload.Fingerprint(Render(local, meta?.BlobMap ?? new Dictionary<string, string>()).Payload);
                    return false;
                }
                var blobId = Guid.NewGuid().ToString("D");
                var ciphertext = SyncCrypto.Seal(space.ItemKey, bytes, SyncCrypto.Aad.Blob(space.Id, blobId));
                var upload = await api.RegisterBlobAsync(space.Id, blobId, ciphertext.Length, ct);
                await api.UploadBlobAsync(upload, ciphertext, ct);
                blobs[file] = blobId;
            }
            if (clip.Kind == ClipKind.File) await UploadFilesAsync(space, clip, meta, blobs, ct);
        }
        var full = Render(local, blobs);
        var category = full.Category;
        var sealedItem = Seal(space, local.Id, category, full.Payload);
        if (sealedItem.Length > MaxItemBytes && local is LocalItem.Clip { Item.Kind: ClipKind.RichText })
            sealedItem = Seal(space, local.Id, category, Render(local, blobs, includeRichText: false).Payload);   // drop rtf/html
        if (sealedItem.Length > MaxItemBytes)
        {
            Logger?.Invoke($"Item {local.Id} is too large to sync");
            _rejected[local.Id] = SyncPayload.Fingerprint(Render(local, meta?.BlobMap ?? new Dictionary<string, string>()).Payload);
            return false;
        }
        var updatedAt = Math.Max(NowMs, (meta?.UpdatedAt ?? 0) + 1);
        var outcome = await api.PutItemAsync(space.Id, local.Id, category, full.SortAt, updatedAt, sealedItem, BlobIds(full.Payload), ct);
        switch (outcome)
        {
            case WriteOutcome.Saved saved:
                // An edit (a pin, a label) keeps the original author; a first upload is ours.
                store.SaveSyncMeta(new SyncMeta(space.Id, local.Id, category, SyncPayload.Fingerprint(full.Payload), saved.Seq, updatedAt, false, blobs,
                    meta?.AuthorUid ?? Identity.Uid));
                foreach (var trimmed in saved.Trimmed) Trim(space, trimmed);
                return true;
            case WriteOutcome.Conflict conflict:
                await ApplyCurrentAsync(space, conflict.Current, ct);
                return false;
        }
        return false;
    }

    /// <summary>Uploads a file item's regular files that fit in a blob, at most <see cref="MaxFilesPerItem"/>, reusing
    /// blobs already on the server. The others stay listed by path only.</summary>
    private async Task UploadFilesAsync(SyncSpace space, ClipItem clip, SyncMeta? meta, Dictionary<string, string> blobs, CancellationToken ct)
    {
        var uploaded = 0;
        foreach (var path in clip.Files.Distinct())
        {
            if (uploaded == MaxFilesPerItem) break;
            if (FileSize(path) is not { } size || size + 29 > MaxBlobBytes) continue;   // gone, a folder, or too large
            if (meta is { Trimmed: false } && meta.BlobMap.TryGetValue(FileKey(path, size), out var known))
            {
                blobs[FileKey(path, size)] = known;
                uploaded++;
                continue;
            }
            byte[] bytes;
            try { bytes = await File.ReadAllBytesAsync(path, ct); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                Logger?.Invoke($"Couldn't read a file of {ClipStore.SyncId(clip.Id)}: {ex.Message}");
                continue;
            }
            if (bytes.Length + 29 > MaxBlobBytes) continue;   // grew since
            var blobId = Guid.NewGuid().ToString("D");
            var ciphertext = SyncCrypto.Seal(space.ItemKey, bytes, SyncCrypto.Aad.Blob(space.Id, blobId));
            var upload = await api.RegisterBlobAsync(space.Id, blobId, ciphertext.Length, ct);
            await api.UploadBlobAsync(upload, ciphertext, ct);
            blobs[FileKey(path, bytes.Length)] = blobId;
            uploaded++;
        }
    }

    /// <summary>The item's <c>blobIds</c>: image, thumbnail, then the files in payload order.</summary>
    private static List<string> BlobIds(JsonObject payload) =>
    [
        .. new[] { payload["imageBlob"], payload["thumbBlob"] }
            .Concat((payload["fileBlobs"] as JsonArray ?? []).Select(f => f?["blob"]))
            .OfType<JsonValue>().Select(v => v.GetValue<string>()).Distinct(),
    ];

    private static byte[] Seal(SyncSpace space, string id, string category, JsonObject payload) =>
        SyncCrypto.Seal(space.ItemKey, SyncPayload.Encode(payload), SyncCrypto.Aad.Item(space.Id, id, category));

    /// <summary>A 409's <c>current</c> is applied exactly like a pulled change.</summary>
    private async Task ApplyCurrentAsync(SyncSpace space, RemoteItem current, CancellationToken ct)
    {
        // Force it through even if the meta's seq is newer than what we know.
        if (store.SyncMetaFor(space.Id, current.Id) is { } meta && meta.RemoteSeq >= current.Seq)
            store.SaveSyncMeta(meta with { RemoteSeq = current.Seq - 1 });
        if (await PrepareAsync(space, current, ct) is { } prepared)
        {
            using var _ = store.Batch();
            Apply(space, prepared);
        }
    }

    /// <summary>Personal: stop tracking but keep the local copy. Group: the server is the source, so delete it.</summary>
    private void Trim(SyncSpace space, string itemId)
    {
        if (space.IsPersonal)
        {
            if (store.SyncMetaFor(space.Id, itemId) is { } meta) store.SaveSyncMeta(meta with { Trimmed = true });
            return;
        }
        DeleteLocal(space, itemId, SyncCategory.History);
        store.DeleteSyncMeta(space.Id, itemId);
    }
}
