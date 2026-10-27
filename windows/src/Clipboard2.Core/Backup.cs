using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Clipboard2.Core.Sync;

namespace Clipboard2.Core;

/// <summary>A backup that can't be read; the message is shown as is.</summary>
public sealed class BackupException(string message, bool wrongPassphrase = false) : Exception(message)
{
    /// <summary>The GCM check failed: a wrong passphrase (or a damaged file; the two can't be told apart).</summary>
    public bool WrongPassphrase { get; } = wrongPassphrase;
}

/// <summary>
/// The <c>.clipboard2backup</c> envelope (docs/BACKUP-FORMAT.md): "C2BK", version 1, a 16-byte salt, PBKDF2-SHA256
/// iterations (uint32 big-endian), a 12-byte nonce, then AES-256-GCM ciphertext and tag with the 37-byte header as AAD.
/// </summary>
public static class BackupCrypto
{
    public static ReadOnlySpan<byte> Magic => "C2BK"u8;
    public const byte Version = 1;
    public const int SaltSize = 16, NonceSize = 12, TagSize = 16, KeySize = 32;
    public const int HeaderSize = 4 + 1 + SaltSize + 4 + NonceSize;   // 37
    public const int DefaultIterations = 600_000, MinIterations = 600_000, MaxIterations = 10_000_000;

    public static byte[] DeriveKey(string passphrase, byte[] salt, int iterations) =>
        Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(passphrase.Normalize(NormalizationForm.FormC)), salt, iterations,
            HashAlgorithmName.SHA256, KeySize);

    /// <param name="salt">Random when null; fixed only for test vectors.</param>
    public static byte[] Encrypt(byte[] plaintext, string passphrase, int iterations = DefaultIterations, byte[]? salt = null, byte[]? nonce = null)
    {
        salt ??= RandomNumberGenerator.GetBytes(SaltSize);
        nonce ??= RandomNumberGenerator.GetBytes(NonceSize);
        if (salt.Length != SaltSize || nonce.Length != NonceSize) throw new ArgumentException("Wrong salt or nonce size.");
        var file = new byte[HeaderSize + plaintext.Length + TagSize];
        Magic.CopyTo(file);
        file[4] = Version;
        salt.CopyTo(file, 5);
        BinaryPrimitives.WriteUInt32BigEndian(file.AsSpan(21, 4), (uint)iterations);
        nonce.CopyTo(file, 25);
        var key = DeriveKey(passphrase, salt, iterations);
        try
        {
            using var aes = new AesGcm(key, TagSize);
            aes.Encrypt(nonce, plaintext, file.AsSpan(HeaderSize, plaintext.Length), file.AsSpan(HeaderSize + plaintext.Length), file.AsSpan(0, HeaderSize));
        }
        finally { CryptographicOperations.ZeroMemory(key); }
        return file;
    }

    /// <summary>The plaintext, or a <see cref="BackupException"/> explaining why not.</summary>
    public static byte[] Decrypt(byte[] file, string passphrase)
    {
        if (file.Length < HeaderSize + TagSize || !file.AsSpan(0, 4).SequenceEqual(Magic))
            throw new BackupException("This isn't a Clipboard2 backup.");
        if (file[4] != Version)
            throw new BackupException("This backup was made by a newer version of Clipboard2. Update the app to open it.");
        var iterations = BinaryPrimitives.ReadUInt32BigEndian(file.AsSpan(21, 4));
        if (iterations < MinIterations || iterations > MaxIterations)
            throw new BackupException("This backup uses unsupported encryption settings.");
        var salt = file.AsSpan(5, SaltSize).ToArray();
        var nonce = file.AsSpan(25, NonceSize);
        var cipherLength = file.Length - HeaderSize - TagSize;
        var plaintext = new byte[cipherLength];
        var key = DeriveKey(passphrase, salt, (int)iterations);
        try
        {
            using var aes = new AesGcm(key, TagSize);
            aes.Decrypt(nonce, file.AsSpan(HeaderSize, cipherLength), file.AsSpan(HeaderSize + cipherLength, TagSize), plaintext, file.AsSpan(0, HeaderSize));
        }
        catch (AuthenticationTagMismatchException)
        {
            throw new BackupException("The passphrase is wrong, or the backup file is damaged.", wrongPassphrase: true);
        }
        finally { CryptographicOperations.ZeroMemory(key); }
        return plaintext;
    }
}

/// <summary>A secret to export, read after Windows Hello.</summary>
public sealed record BackupSecret(string Id, string Name, string Value, DateTime? CreatedAt);

/// <summary>Personal items and snippets to back up, and where their images are.</summary>
public sealed record BackupSource(IReadOnlyList<ClipItem> Items, IReadOnlyList<Snippet> Snippets, BlobStore Blobs);

public sealed record BackupSummary(int Clips, int Snippets, int Secrets);

/// <param name="Duplicates">Entries skipped because the same content was already here.</param>
/// <param name="Unreadable">Entries skipped because they were incomplete (e.g. an image without its picture).</param>
public sealed record BackupImportResult(int Clips, int Snippets, int Secrets, int Duplicates, int Unreadable)
{
    public string Describe()
    {
        var parts = new List<string>();
        if (Clips > 0) parts.Add(Clips == 1 ? "1 item" : $"{Clips} items");
        if (Snippets > 0) parts.Add(Snippets == 1 ? "1 snippet" : $"{Snippets} snippets");
        if (Secrets > 0) parts.Add(Secrets == 1 ? "1 secret" : $"{Secrets} secrets");
        var text = parts.Count == 0 ? "Nothing new to import." : "Imported " + string.Join(", ", parts) + ".";
        if (Duplicates > 0) text += Duplicates == 1 ? " Skipped 1 duplicate." : $" Skipped {Duplicates} duplicates.";
        if (Unreadable > 0) text += Unreadable == 1 ? " 1 entry couldn't be read." : $" {Unreadable} entries couldn't be read.";
        return text;
    }
}

/// <summary>Builds and merges the backup's JSON (docs/BACKUP-FORMAT.md). Personal space only. Use the store from
/// its own thread; only <see cref="BackupCrypto"/> belongs on a worker thread.</summary>
public static class Backup
{
    public const string Extension = ".clipboard2backup";
    public const string Format = "clipboard2-backup";
    public const int Version = 1;

    /// <summary>The plaintext JSON: personal history and pinned items (with their images), personal snippets and,
    /// when given, secrets.</summary>
    public static byte[] CreatePlaintext(ClipStore store, IReadOnlyList<BackupSecret>? secrets, string app = "windows", DateTime? now = null) =>
        CreatePlaintext(Snapshot(store), secrets, app, now);

    /// <summary>Safe on a worker thread: reads only the snapshot and the image files.</summary>
    public static byte[] CreatePlaintext(BackupSource source, IReadOnlyList<BackupSecret>? secrets, string app = "windows", DateTime? now = null) =>
        Encoding.UTF8.GetBytes(Create(source, secrets, app, now).ToJsonString());

    /// <summary>What goes into a backup, read from the store on its own thread.</summary>
    public static BackupSource Snapshot(ClipStore store) =>
        new(store.ItemsInSpace(null), [.. store.AllSnippets().Where(s => s.SpaceId is null)], store.Blobs);

    public static JsonObject Create(ClipStore store, IReadOnlyList<BackupSecret>? secrets, string app = "windows", DateTime? now = null) =>
        Create(Snapshot(store), secrets, app, now);

    public static JsonObject Create(BackupSource source, IReadOnlyList<BackupSecret>? secrets, string app = "windows", DateTime? now = null)
    {
        var clips = new JsonArray();
        foreach (var item in source.Items)
        {
            var payload = SyncPayload.ForClip(item);
            payload.Remove("rev");   // sync-only
            payload["id"] = ClipStore.SyncId(item.Id);
            if (item.Kind == ClipKind.Image)
            {
                if (ReadBlob(source.Blobs, item.ImageFile) is not { } image) continue;   // its picture is gone: nothing to restore
                payload["image"] = Convert.ToBase64String(image);
                if (ReadBlob(source.Blobs, item.ThumbnailFile) is { } thumb) payload["thumb"] = Convert.ToBase64String(thumb);
            }
            clips.Add(payload);
        }
        var snippets = new JsonArray();
        foreach (var snippet in source.Snippets)
        {
            var payload = SyncPayload.ForSnippet(snippet);
            payload.Remove("rev");
            payload["id"] = ClipStore.SyncId(snippet.Id);
            snippets.Add(payload);
        }
        var root = new JsonObject
        {
            ["format"] = Format,
            ["version"] = Version,
            ["createdAt"] = SyncPayload.Millis(now ?? DateTime.UtcNow),
            ["app"] = app,
            ["clips"] = clips,
            ["snippets"] = snippets,
        };
        if (secrets is not null)
        {
            var list = new JsonArray();
            foreach (var secret in secrets)
            {
                var payload = SyncPayload.ForSecret(secret.Name, secret.Value, secret.CreatedAt);
                payload.Remove("rev");
                payload["id"] = secret.Id;
                list.Add(payload);
            }
            root["secrets"] = list;
        }
        return root;
    }

    private static byte[]? ReadBlob(BlobStore blobs, string? name)
    {
        if (name is null) return null;
        try { return File.ReadAllBytes(blobs.PathFor(name)); }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    /// <summary>Parses decrypted plaintext; throws <see cref="BackupException"/> when it isn't a v1 backup.</summary>
    public static JsonObject Parse(byte[] plaintext)
    {
        JsonObject? root;
        try { root = JsonNode.Parse(plaintext) as JsonObject; }
        catch (System.Text.Json.JsonException) { root = null; }
        if (root is null || Str(root, "format") != Format) throw new BackupException("The backup's contents couldn't be read.");
        if (root["version"] is not JsonValue v || !v.TryGetValue<double>(out var version) || version != Version)
            throw new BackupException("This backup was made by a newer version of Clipboard2. Update the app to open it.");
        return root;
    }

    public static BackupSummary Summarize(JsonObject root) =>
        new(Entries(root, "clips").Count, Entries(root, "snippets").Count, Entries(root, "secrets").Count);

    /// <summary>Adds what isn't here yet to the personal space: clips by content hash, snippets by (name, body),
    /// secrets by (name, value) when a vault is given. Nothing is overwritten or deleted.</summary>
    public static BackupImportResult Merge(JsonObject root, ClipStore store, ISecretVault? vault)
    {
        int clips = 0, snippets = 0, secrets = 0, duplicates = 0, unreadable = 0;
        using (store.Batch())
        {
            var hashes = store.ItemsInSpace(null).Select(i => i.ContentHash).ToHashSet();
            foreach (var entry in Entries(root, "clips").OfType<JsonObject>())
            {
                if (ClipFrom(entry) is not { } item) { unreadable++; continue; }
                if (!hashes.Add(item.ContentHash)) { duplicates++; continue; }
                if (item.Kind == ClipKind.Image)
                {
                    var image = Bytes(entry, "image");
                    if (image is null) { unreadable++; hashes.Remove(item.ContentHash); continue; }
                    var name = item.Id.ToString("N");
                    item.ImageFile = $"{name}.png";
                    item.ThumbnailFile = $"{name}-thumb.png";
                    store.Blobs.Write(image, item.ImageFile);
                    store.Blobs.Write(Bytes(entry, "thumb") ?? image, item.ThumbnailFile);
                }
                store.Put(item);
                clips++;
            }

            var existingSnippets = store.AllSnippets().Where(s => s.SpaceId is null).Select(s => (s.Name, s.Body)).ToHashSet();
            foreach (var entry in Entries(root, "snippets").OfType<JsonObject>())
            {
                if (SyncPayload.Parse(Encoding.UTF8.GetBytes(entry.ToJsonString()), Guid.NewGuid(), null) is not ItemPayload.SnippetPayload { Snippet: var snippet })
                {
                    unreadable++;
                    continue;
                }
                if (!existingSnippets.Add((snippet.Name, snippet.Body))) { duplicates++; continue; }
                store.PutSnippet(snippet);
                snippets++;
            }
        }

        var secretEntries = Entries(root, "secrets");
        if (vault is not null && secretEntries.Count > 0)
        {
            var existing = vault.Secrets.Where(s => s.SpaceId is null).Select(s => (s.Name, Value: vault.ReadValue(s) ?? "")).ToHashSet();
            foreach (var entry in secretEntries.OfType<JsonObject>())
            {
                if (Str(entry, "type") != "secret" || Str(entry, "name") is not { } name || Str(entry, "value") is not { Length: > 0 } value)
                {
                    unreadable++;
                    continue;
                }
                if (!existing.Add((name, value))) { duplicates++; continue; }
                if (vault.Add(name, value) is null) { unreadable++; continue; }
                secrets++;
            }
        }
        return new BackupImportResult(clips, snippets, secrets, duplicates, unreadable);
    }

    /// <summary>A clip entry as a new personal item (new id), or null when it isn't a readable clip.</summary>
    private static ClipItem? ClipFrom(JsonObject entry)
    {
        var copy = entry.DeepClone().AsObject();
        foreach (var key in new[] { "image", "thumb", "imageBlob", "thumbBlob", "fileBlobs", "id" }) copy.Remove(key);
        ItemPayload? parsed;
        try { parsed = SyncPayload.Parse(Encoding.UTF8.GetBytes(copy.ToJsonString()), Guid.NewGuid(), null); }
        catch (Exception ex) when (ex is System.Text.Json.JsonException or InvalidOperationException or FormatException) { return null; }
        if (parsed is not ItemPayload.Clip { Item: var item }) return null;
        if (Str(entry, "kind") == "file")
        {
            // Names only: the files themselves aren't in a backup.
            var files = (entry["files"] as JsonArray ?? []).Select(f => f is JsonValue v && v.TryGetValue<string>(out var s) ? LocalPath(s) : null)
                .OfType<string>().Where(f => f.Length > 0).ToList();
            if (files.Count == 0) return item.Text.Length == 0 ? null : item;
            item.Kind = ClipKind.File;
            item.Files = files;
            item.Text = string.Join("\n", files);
            if (Str(entry, "contentHash") is null) item.ContentHash = ContentHasher.HashFiles(files);
        }
        else if (Str(entry, "kind") == "image")
        {
            item.Kind = ClipKind.Image;
            item.Text = "";
            if (Str(entry, "contentHash") is null) return null;   // nothing to dedupe by
        }
        else if (item.Text.Length == 0)
        {
            return null;
        }
        return item;
    }

    private static string LocalPath(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.IsFile ? uri.LocalPath : url;

    private static JsonArray Entries(JsonObject root, string key) => root[key] as JsonArray ?? [];

    private static string? Str(JsonObject json, string key) =>
        json[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    private static byte[]? Bytes(JsonObject json, string key)
    {
        if (Str(json, key) is not { Length: > 0 } b64) return null;
        try { return Convert.FromBase64String(b64); } catch (FormatException) { return null; }
    }
}
