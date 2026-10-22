using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Clipboard2.Core.Sync;
using Microsoft.Data.Sqlite;

namespace Clipboard2.Core.Tests;

/// <summary>Every vector in docs/sync/test-vectors.json: reproduce outputs (sealing with the given nonce) and open sealed values.</summary>
public sealed class SyncCryptoVectorTests
{
    private static readonly JsonObject V = Load();

    private static JsonObject Load()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var path = Path.Combine(dir.FullName, "docs", "sync", "test-vectors.json");
            if (File.Exists(path)) return JsonNode.Parse(File.ReadAllText(path))!.AsObject();
        }
        throw new FileNotFoundException("docs/sync/test-vectors.json not found above " + AppContext.BaseDirectory);
    }

    private static byte[] B(JsonNode? node) => Convert.FromBase64String(node!.GetValue<string>());
    private static string S(JsonNode? node) => node!.GetValue<string>();

    [Fact]
    public void AesGcmIsSupported() => Assert.True(AesGcm.IsSupported);

    [Fact]
    public void Pbkdf2Vectors()
    {
        foreach (var v in V["pbkdf2"]!.AsArray())
            Assert.Equal(B(v!["kek"]), SyncCrypto.Pbkdf2(S(v["password"]), B(v["salt"]), v["iterations"]!.GetValue<int>()));
    }

    [Fact]
    public void PasswordsAreNfcNormalised()
    {
        var salt = new byte[16];
        Assert.Equal(SyncCrypto.Pbkdf2("caf\u00e9", salt, 1000), SyncCrypto.Pbkdf2("cafe\u0301", salt, 1000));
    }

    [Fact]
    public void AeadVectors()
    {
        foreach (var v in V["aead"]!.AsArray())
        {
            var key = B(v!["key"]);
            Assert.Equal(B(v["sealed"]), SyncCrypto.Seal(key, B(v["plaintext"]), S(v["aad"]), B(v["nonce"])));
            Assert.Equal(B(v["plaintext"]), SyncCrypto.Open(key, B(v["sealed"]), S(v["aad"])));
        }
    }

    [Fact]
    public void AeadRejectsWrongAadVersionAndTampering()
    {
        var v = V["aead"]![0]!;
        var key = B(v["key"]);
        var sealedValue = B(v["sealed"]);
        Assert.ThrowsAny<CryptographicException>(() => SyncCrypto.Open(key, sealedValue, "c2/other"));
        var badVersion = (byte[])sealedValue.Clone();
        badVersion[0] = 0x02;
        Assert.ThrowsAny<CryptographicException>(() => SyncCrypto.Open(key, badVersion, S(v["aad"])));
        var tampered = (byte[])sealedValue.Clone();
        tampered[^1] ^= 1;
        Assert.ThrowsAny<CryptographicException>(() => SyncCrypto.Open(key, tampered, S(v["aad"])));
    }

    [Fact]
    public void HkdfVectors()
    {
        foreach (var v in V["hkdf"]!.AsArray())
            Assert.Equal(B(v!["okm"]), SyncCrypto.Hkdf(B(v["ikm"]), B(v["salt"]), S(v["info"])));
    }

    [Fact]
    public void EcdhVector()
    {
        var e = V["ecdh"]!;
        var a = new EcKeyPair(B(e["privA"]), B(e["pubA"]));
        var b = new EcKeyPair(B(e["privB"]), B(e["pubB"]));
        Assert.Equal(B(e["shared"]), SyncCrypto.Ecdh(a, b.Public));
        Assert.Equal(B(e["shared"]), SyncCrypto.Ecdh(b, a.Public));
        Assert.True(SyncCrypto.IsValidPair(a));
        Assert.False(SyncCrypto.IsValidPair(new EcKeyPair(a.Private, b.Public)));
    }

    [Fact]
    public void GeneratedKeyPairsAreRawAndAgree()
    {
        var a = SyncCrypto.GenerateKeyPair();
        var b = SyncCrypto.GenerateKeyPair();
        Assert.Equal(32, a.Private.Length);
        Assert.Equal(65, a.Public.Length);
        Assert.Equal(0x04, a.Public[0]);
        Assert.Equal(SyncCrypto.Ecdh(a, b.Public), SyncCrypto.Ecdh(b, a.Public));
    }

    [Fact]
    public void AccountVector()
    {
        var v = V["account"]!;
        var uid = S(v["uid"]);
        Assert.Equal(B(v["master"]), SyncCrypto.Pbkdf2(S(v["password"]), B(v["salt"]), v["iterations"]!.GetValue<int>()));
        var keys = SyncCrypto.DerivePasswordKeys(S(v["password"]), B(v["salt"]), v["iterations"]!.GetValue<int>());
        Assert.Equal(B(v["authKey"]), keys.AuthKey);
        Assert.Equal(B(v["wrapKey"]), keys.WrapKey);
        Assert.Equal(B(v["wrappedAccountKey"]), SyncCrypto.Seal(keys.WrapKey, B(v["accountKey"]), SyncCrypto.Aad.AccountKey(uid), B(v["akNonce"])));
        Assert.Equal(B(v["accountKey"]), SyncCrypto.Open(keys.WrapKey, B(v["wrappedAccountKey"]), SyncCrypto.Aad.AccountKey(uid)));
        Assert.Equal(B(v["wrappedPrivateKey"]), SyncCrypto.Seal(B(v["accountKey"]), B(v["idPriv"]), SyncCrypto.Aad.PrivateKey(uid), B(v["privNonce"])));
        Assert.Equal(B(v["idPriv"]), SyncCrypto.Open(B(v["accountKey"]), B(v["wrappedPrivateKey"]), SyncCrypto.Aad.PrivateKey(uid)));
        Assert.True(SyncCrypto.IsValidPair(new EcKeyPair(B(v["idPriv"]), B(v["idPub"]))));
    }

    [Fact]
    public void InviteVector()
    {
        var v = V["invite"]!;
        var bytes = B(v["codeBytes"]);
        Assert.Equal(S(v["code"]), InviteCode.Format(bytes));
        Assert.Equal(bytes, InviteCode.Parse(S(v["code"])));
        foreach (var typed in v["typedVariants"]!.AsArray()) Assert.Equal(bytes, InviteCode.Parse(S(typed)));
        foreach (var invalid in v["invalidCodes"]!.AsArray()) Assert.Null(InviteCode.Parse(S(invalid)));
        Assert.Equal(S(v["inviteId"]), SyncCrypto.InviteId(bytes));
        Assert.Equal(B(v["inviteKey"]), SyncCrypto.InviteKey(bytes));
        var spaceId = S(v["spaceId"]);
        Assert.Equal(B(v["sealedKey"]), SyncCrypto.SealInvite(bytes, B(v["spaceKey"]), spaceId, B(v["nonce"])));
        Assert.Equal(B(v["spaceKey"]), SyncCrypto.OpenInvite(bytes, B(v["sealedKey"]), spaceId));
    }

    [Fact]
    public void InviteCodesForgiveMisreadingsAndRejectNonZeroPadding()
    {
        var bytes = InviteCode.Generate();
        var code = InviteCode.Format(bytes);
        Assert.Matches("^([A-Z2-7]{4}-){6}[A-Z2-7]{2}$", code);
        Assert.Equal(bytes, InviteCode.Parse(code.ToLowerInvariant().Replace("-", " ")));
        Assert.Equal(bytes, InviteCode.Parse(code.Replace('O', '0').Replace('I', '1').Replace('B', '8')));
        const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
        var padded = code[..^1] + alphabet[alphabet.IndexOf(code[^1]) | 1];   // sets one of the two must-be-zero bits
        Assert.Null(InviteCode.Parse(padded));
    }

    [Fact]
    public void SpaceWrapVector()
    {
        var v = V["spaceWrap"]!;
        var spaceId = S(v["spaceId"]);
        var uid = S(v["memberUid"]);
        var eph = new EcKeyPair(B(v["ephPriv"]), B(v["ephPub"]));
        Assert.Equal(B(v["wrappedKey"]), SyncCrypto.WrapSpaceKey(B(v["spaceKey"]), spaceId, uid, B(v["memberPub"]), eph, B(v["nonce"])));
        var member = new EcKeyPair(B(v["memberPriv"]), B(v["memberPub"]));
        Assert.Equal(B(v["spaceKey"]), SyncCrypto.UnwrapSpaceKey(B(v["wrappedKey"]), spaceId, uid, member));
        // A fresh ephemeral key round-trips too, and the wrong member can't open it.
        var fresh = SyncCrypto.WrapSpaceKey(B(v["spaceKey"]), spaceId, uid, member.Public);
        Assert.Equal(B(v["spaceKey"]), SyncCrypto.UnwrapSpaceKey(fresh, spaceId, uid, member));
        Assert.ThrowsAny<CryptographicException>(() => SyncCrypto.UnwrapSpaceKey(fresh, spaceId, "someone-else", member));
    }

    [Fact]
    public void ItemVector()
    {
        var v = V["item"]!;
        var itemKey = SyncCrypto.ItemKey(B(v["spaceKey"]));
        Assert.Equal(B(v["itemKey"]), itemKey);
        var aad = SyncCrypto.Aad.Item(S(v["spaceId"]), S(v["itemId"]), S(v["category"]));
        var payload = Encoding.UTF8.GetBytes(S(v["payload"]));
        Assert.Equal(B(v["ciphertext"]), SyncCrypto.Seal(itemKey, payload, aad, B(v["nonce"])));
        var opened = SyncCrypto.Open(itemKey, B(v["ciphertext"]), aad);
        Assert.Equal(payload, opened);

        // Parsing and writing the payload again gives the same bytes.
        var parsed = Assert.IsType<ItemPayload.Clip>(SyncPayload.Parse(opened, Guid.Parse(S(v["itemId"])), null));
        Assert.Equal("Grüße aus Wien 👋", parsed.Item.Text);
        Assert.Equal(2, parsed.Item.CopyCount);
        Assert.Equal(ContentHasher.HashText("Grüße aus Wien 👋"), parsed.Item.ContentHash);
        Assert.Equal(S(v["payload"]), Encoding.UTF8.GetString(SyncPayload.Encode(SyncPayload.ForClip(parsed.Item))));
    }

    [Fact]
    public void BlobVector()
    {
        var v = V["blob"]!;
        var itemKey = SyncCrypto.ItemKey(B(V["item"]!["spaceKey"]));
        var aad = SyncCrypto.Aad.Blob(S(v["spaceId"]), S(v["blobId"]));
        Assert.Equal(B(v["ciphertext"]), SyncCrypto.Seal(itemKey, B(v["plaintext"]), aad, B(v["nonce"])));
        Assert.Equal(B(v["plaintext"]), SyncCrypto.Open(itemKey, B(v["ciphertext"]), aad));
    }

    [Fact]
    public void GroupNameVector()
    {
        var v = V["groupName"]!;
        Assert.Equal(B(v["nameKey"]), SyncCrypto.NameKey(B(V["item"]!["spaceKey"])));
        var aad = SyncCrypto.Aad.Name(S(v["spaceId"]));
        Assert.Equal(B(v["encryptedName"]), SyncCrypto.Seal(B(v["nameKey"]), Encoding.UTF8.GetBytes(S(v["name"])), aad, B(v["nonce"])));
        Assert.Equal(S(v["name"]), Encoding.UTF8.GetString(SyncCrypto.Open(B(v["nameKey"]), B(v["encryptedName"]), aad)));
    }
}

public sealed class SyncPayloadTests
{
    private static ClipItem RoundTrip(ClipItem item, string? image = null, string? thumb = null)
    {
        var bytes = SyncPayload.Encode(SyncPayload.ForClip(item, image, thumb));
        return Assert.IsType<ItemPayload.Clip>(SyncPayload.Parse(bytes, item.Id, "g")).Item;
    }

    [Fact]
    public void RichTextRoundTripsAndHtmlLosesOnlyTheClipboardHeader()
    {
        var html = CfHtml.Wrap("<html><body><!--StartFragment--><b>Grüß</b><!--EndFragment--></body></html>");
        var item = ClipItem.From(ProcessedCapture.ForText("Grüß", rtf: @"{\rtf1 Gr\'fc\'df}", html: html), new DateTime(2026, 5, 1, 0, 0, 0, DateTimeKind.Utc));
        item.IsPinned = true;
        item.PinnedAt = item.CreatedAt;
        item.Label = "Greeting";
        var json = SyncPayload.ForClip(item);
        Assert.Equal("richText", json["kind"]!.GetValue<string>());
        Assert.Equal("<html><body><!--StartFragment--><b>Grüß</b><!--EndFragment--></body></html>",
            Encoding.UTF8.GetString(Convert.FromBase64String(json["html"]!.GetValue<string>())));
        var back = RoundTrip(item);
        Assert.Equal(ClipKind.RichText, back.Kind);
        Assert.Equal(item.Rtf, back.Rtf);
        Assert.Equal(html, back.Html);
        Assert.Equal("Greeting", back.Label);
        Assert.True(back.IsPinned);
        Assert.Equal(item.PinnedAt, back.PinnedAt);
        Assert.Equal("g", back.SpaceId);
        Assert.Equal(SyncPayload.Fingerprint(json), SyncPayload.Fingerprint(SyncPayload.ForClip(back)));
    }

    [Fact]
    public void CfHtmlOffsetsPointAtTheHtml()
    {
        var wrapped = CfHtml.Wrap("<p>é</p>");
        var bytes = Encoding.UTF8.GetBytes(wrapped);
        var start = int.Parse(wrapped.Split("StartHTML:")[1][..10]);
        var end = int.Parse(wrapped.Split("EndHTML:")[1][..10]);
        Assert.Equal("<p>é</p>", Encoding.UTF8.GetString(bytes, start, end - start));
        Assert.Equal("<p>plain</p>", CfHtml.Extract("<p>plain</p>"));
    }

    [Fact]
    public void ImagesCarryBlobIdsAndOmitNulls()
    {
        var item = new ClipItem { Kind = ClipKind.Image, Preview = "Image 3×2", ContentHash = "image:px:3x2:abc", ImageWidth = 3, ImageHeight = 2, ByteCount = 99, ImageFile = "a.png" };
        var json = SyncPayload.ForClip(item, "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222");
        Assert.Null(json["label"]);
        Assert.Null(json["pinnedAt"]);
        Assert.Null(json["rtf"]);
        var parsed = Assert.IsType<ItemPayload.Clip>(SyncPayload.Parse(SyncPayload.Encode(json), item.Id, null));
        Assert.Equal("11111111-1111-4111-8111-111111111111", parsed.ImageBlob);
        Assert.Equal("22222222-2222-4222-8222-222222222222", parsed.ThumbBlob);
        Assert.Equal(ClipKind.Image, parsed.Item.Kind);
        Assert.Equal(3, parsed.Item.ImageWidth);
    }

    [Fact]
    public void FilesSyncAsUrlsAndArriveAsText()
    {
        var path = OperatingSystem.IsWindows() ? @"C:\Users\me\report 1.pdf" : "/Users/me/report 1.pdf";
        var item = ClipItem.From(ProcessedCapture.ForFiles([path]), DateTime.UtcNow);
        var json = SyncPayload.ForClip(item);
        Assert.Equal("file", json["kind"]!.GetValue<string>());
        Assert.StartsWith("file:///", json["files"]![0]!.GetValue<string>());
        json["text"] = "";
        var parsed = Assert.IsType<ItemPayload.Clip>(SyncPayload.Parse(SyncPayload.Encode(json), item.Id, null)).Item;
        Assert.Equal(ClipKind.Text, parsed.Kind);
        Assert.Equal(path, parsed.Text);
        Assert.Equal(item.ContentHash, parsed.ContentHash);
    }

    [Fact]
    public void SnippetsAndSecretsRoundTripAndUnknownFieldsAreIgnored()
    {
        var snippet = new Snippet { Name = "Sig", Keyword = ";sig", Body = "Regards", CreatedAt = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc), UpdatedAt = new DateTime(2026, 2, 1, 0, 0, 0, DateTimeKind.Utc) };
        var json = SyncPayload.ForSnippet(snippet);
        json["future"] = "ignored";
        var back = Assert.IsType<ItemPayload.SnippetPayload>(SyncPayload.Parse(SyncPayload.Encode(json), snippet.Id, null)).Snippet;
        Assert.Equal((";sig", "Regards", snippet.UpdatedAt), (back.Keyword, back.Body, back.UpdatedAt));

        var secret = Assert.IsType<ItemPayload.Secret>(SyncPayload.Parse(SyncPayload.Encode(SyncPayload.ForSecret("PIN", "1234", DateTime.UtcNow)), Guid.NewGuid(), null));
        Assert.Equal(("PIN", "1234"), (secret.Name, secret.Value));
        Assert.Null(SyncPayload.Parse(Encoding.UTF8.GetBytes("""{"v":1,"type":"hologram"}"""), Guid.NewGuid(), null));
    }

    [Fact]
    public void FingerprintIgnoresKeyOrderAndSecretTimestamps()
    {
        var a = JsonNode.Parse("""{"v":1,"type":"snippet","name":"a","body":"b"}""")!.AsObject();
        var b = JsonNode.Parse("""{"body":"b","name":"a","type":"snippet","v":1}""")!.AsObject();
        Assert.Equal(SyncPayload.Fingerprint(a), SyncPayload.Fingerprint(b));
        Assert.Equal(SyncPayload.Fingerprint(SyncPayload.ForSecret("n", "v", DateTime.UtcNow)),
            SyncPayload.Fingerprint(SyncPayload.ForSecret("n", "v", DateTime.UtcNow.AddDays(-3))));
        Assert.NotEqual(SyncPayload.Fingerprint(SyncPayload.ForSecret("n", "v", null)), SyncPayload.Fingerprint(SyncPayload.ForSecret("n", "w", null)));
    }

    [Fact]
    public void ApiRequestsCarryTheSessionToken()
    {
        var api = new SyncApi(() => "tok", () => "https://api.example/");
        var put = api.MakeRequest(HttpMethod.Put, "/v1/account/password", new JsonObject(), "tok");
        Assert.Equal("https://api.example/v1/account/password", put.RequestUri!.ToString());
        Assert.Equal("Bearer tok", put.Headers.Authorization!.ToString());
        Assert.Null(api.MakeRequest(HttpMethod.Post, "/v1/auth/prelogin", null, null).Headers.Authorization);
        Assert.Equal("roham@example.com", SyncCrypto.NormalizeEmail("  Roham@Example.COM "));
    }
}

public sealed class SyncStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "c2sync-" + Guid.NewGuid());

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        try { Directory.Delete(_dir, true); } catch { }
    }

    [Fact]
    public void MigratesAVersion0Database()
    {
        Directory.CreateDirectory(_dir);
        var path = Path.Combine(_dir, "history.db");
        using (var db = new SqliteConnection($"Data Source={path};Pooling=False"))
        {
            db.Open();
            using var cmd = db.CreateCommand();
            cmd.CommandText = """
                CREATE TABLE clips (
                    id TEXT PRIMARY KEY, created INTEGER NOT NULL, last_copied INTEGER NOT NULL, kind INTEGER NOT NULL,
                    text TEXT NOT NULL, preview TEXT NOT NULL, rtf TEXT, html TEXT, hash TEXT NOT NULL, files TEXT NOT NULL,
                    image_file TEXT, thumb_file TEXT, width INTEGER NOT NULL, height INTEGER NOT NULL, bytes INTEGER NOT NULL,
                    source_id TEXT, source_name TEXT, pinned INTEGER NOT NULL, pinned_at INTEGER, label TEXT, copy_count INTEGER NOT NULL);
                CREATE TABLE snippets (id TEXT PRIMARY KEY, name TEXT NOT NULL, keyword TEXT NOT NULL, body TEXT NOT NULL,
                    created INTEGER NOT NULL, updated INTEGER NOT NULL);
                INSERT INTO clips VALUES ('6f1c2b1e-0000-4000-8000-000000000001', 1, 2, 0, 'old', 'old', NULL, NULL, 'text:x', '[]',
                    NULL, NULL, 0, 0, 3, NULL, NULL, 1, 2, 'kept', 4);
                INSERT INTO snippets VALUES ('6f1c2b1e-0000-4000-8000-000000000002', 'S', ';s', 'body', 1, 2);
                """;
            cmd.ExecuteNonQuery();
        }
        using (var store = new ClipStore(path, new BlobStore(Path.Combine(_dir, "Blobs"))))
        {
            Assert.Equal(ClipStore.SchemaVersion, store.UserVersion);
            var item = Assert.Single(store.AllItems());
            Assert.Equal(("old", "kept", 4, true), (item.Text, item.Label, item.CopyCount, item.IsPinned));
            Assert.Null(item.SpaceId);
            Assert.Null(Assert.Single(store.AllSnippets()).SpaceId);
            store.SetSyncCursor("space", 42);
            store.SaveSyncMeta(new SyncMeta("space", "id", "history", "fp", 7, 8));
        }
        // Reopening doesn't migrate twice and keeps the sync state.
        using var again = new ClipStore(path, new BlobStore(Path.Combine(_dir, "Blobs")));
        Assert.Equal(42, again.SyncCursor("space"));
        Assert.Equal("fp", again.SyncMetaFor("space", "id")!.Fingerprint);
    }

    [Fact]
    public void DedupeMergeAndRetentionStayInsideOneSpace()
    {
        using var store = new ClipStore(":memory:", new BlobStore(_dir));
        var now = DateTime.UtcNow;
        store.Ingest(ProcessedCapture.ForText("same"), now);
        store.Ingest(ProcessedCapture.ForText("same"), now, spaceId: "g1");
        store.Ingest(ProcessedCapture.ForText("same"), now, spaceId: "g1");
        Assert.Equal(2, store.Count());
        Assert.Equal(2, store.ItemsInSpace("g1").Single().CopyCount);

        for (var i = 0; i < ClipStore.GroupHistoryLimit + 5; i++) store.Ingest(ProcessedCapture.ForText($"g{i}"), now.AddSeconds(i), spaceId: "g2");
        store.Ingest(ProcessedCapture.ForText("personal old"), now.AddDays(-60));
        store.SaveSyncMeta(new SyncMeta("g2-remote", ClipStore.SyncId(store.ItemsInSpace("g2").Last().Id), "history", "fp", 1, 1));
        store.EnforceRetention(1, TimeSpan.FromDays(30), now.AddMinutes(1));
        Assert.Equal(ClipStore.GroupHistoryLimit, store.ItemsInSpace("g2").Count);
        Assert.Single(store.ItemsInSpace(null));                // user's limit (1 item) applies to personal only
        Assert.Single(store.ItemsInSpace("g1"));
        Assert.Empty(store.SyncMetas("g2-remote"));               // trimmed locally = untracked, not deleted remotely

        store.RemoveUnpinned(new HashSet<string> { ContentHasher.HashText("same") }, "g1");
        Assert.Empty(store.ItemsInSpace("g1"));
        Assert.Single(store.ItemsInSpace(null));
    }

    [Fact]
    public void DuplicateConvergenceKeepsTheSmallerIdAndMergesState()
    {
        using var store = new ClipStore(":memory:", new BlobStore(_dir));
        var t = new DateTime(2026, 3, 1, 0, 0, 0, DateTimeKind.Utc);
        var big = new ClipItem { Id = Guid.Parse("ffffffff-0000-4000-8000-000000000000"), Kind = ClipKind.Text, Text = "x", Preview = "x", ContentHash = "text:x",
            CopyCount = 3, LastCopiedAt = t.AddHours(1), IsPinned = true, PinnedAt = t, Label = "L" };
        var small = new ClipItem { Id = Guid.Parse("00000000-0000-4000-8000-000000000001"), Kind = ClipKind.Text, Text = "x", Preview = "x", ContentHash = "text:x",
            CopyCount = 2, LastCopiedAt = t };
        store.Put(big);
        store.Put(small);
        Assert.Equal(1, store.ConvergeDuplicates(null));
        var winner = Assert.Single(store.AllItems());
        Assert.Equal(small.Id, winner.Id);
        Assert.Equal((5, t.AddHours(1), "L", true), (winner.CopyCount, winner.LastCopiedAt, winner.Label, winner.IsPinned));
    }
}

/// <summary>Accounts and the engine against <see cref="FakeCloud"/>.</summary>
public sealed class SyncEngineTests : IDisposable
{
    private const string Email = "roham@example.com", Password = "correct horse battery";
    private readonly FakeCloud _cloud = new();
    private readonly List<Device> _devices = [];

    private sealed class Device : IDisposable
    {
        public string Dir { get; } = Path.Combine(Path.GetTempPath(), "c2dev-" + Guid.NewGuid());
        public ClipStore Store { get; }
        public FakeVault Vault { get; } = new();
        public MemoryKeys Keys { get; } = new();
        public Settings Settings { get; } = new() { SyncApiBaseUrl = FakeCloud.ApiBase };
        public SyncAccount Account { get; }

        public Device(FakeCloud cloud, Func<DateTime>? clock = null)
        {
            Store = new ClipStore(":memory:", new BlobStore(Dir));
            Account = new SyncAccount(Store, Vault, Settings, Keys, new HttpClient(cloud), clock, kdfIterations: 1000);
        }

        public string Personal => Account.Engine!.Identity.PersonalSpaceId;
        public Task Sync() => Account.SyncNowAsync();
        public ClipItem Copy(string text, int secondsAgo = 0, string? space = null) =>
            Store.Ingest(ProcessedCapture.ForText(text), DateTime.UtcNow.AddSeconds(-secondsAgo), space);

        public void Dispose()
        {
            Store.Dispose();
            try { Directory.Delete(Dir, true); } catch { }
        }
    }

    public void Dispose()
    {
        foreach (var d in _devices) d.Dispose();
    }

    private Device NewDevice(Func<DateTime>? clock = null)
    {
        var d = new Device(_cloud, clock);
        _devices.Add(d);
        return d;
    }

    private async Task<Device> SignedUp(string email = Email)
    {
        var d = NewDevice();
        Assert.True(await d.Account.CreateAccountAsync(email, Password, Password), d.Account.Error);
        Assert.Equal(SyncPhase.SignedIn, d.Account.Phase);
        await d.Sync();
        return d;
    }

    private async Task<Device> SignedIn(string email = Email, string password = Password)
    {
        var d = NewDevice();
        Assert.True(await d.Account.SignInAsync(email, password), d.Account.Error);
        Assert.Equal(SyncPhase.SignedIn, d.Account.Phase);
        await d.Sync();
        return d;
    }

    [Fact]
    public async Task SignUpAndSignInNeverSendThePassword()
    {
        var d = NewDevice();
        Assert.False(await d.Account.CreateAccountAsync(Email, Password, "different"));
        Assert.Equal("The passwords don't match.", d.Account.Error);
        Assert.True(await d.Account.CreateAccountAsync("  Roham@Example.com ", Password, Password), d.Account.Error);
        Assert.Equal(Email, d.Account.Email);
        Assert.True(_cloud.HasAccount(Email));
        Assert.DoesNotContain(Password, _cloud.LastAuthKey(Email)!);
        Assert.True(Guid.TryParse(d.Account.Uid, out _));

        // Same email again is refused; a wrong password is reported.
        var dup = NewDevice();
        Assert.False(await dup.Account.CreateAccountAsync(Email, Password, Password));
        Assert.Contains("already exists", dup.Account.Error);
        Assert.False(await dup.Account.SignInAsync(Email, "wrong password"));
        Assert.Equal("The email or password is wrong.", dup.Account.Error);

        // A second device signs in with the password and gets the same identity.
        var other = await SignedIn();
        Assert.Equal(d.Personal, other.Personal);
        Assert.Equal(d.Account.Engine!.Identity.Keys.Public, other.Account.Engine!.Identity.Keys.Public);

        // Restarting restores the session from the key store.
        var again = new SyncAccount(other.Store, other.Vault, other.Settings, other.Keys, new HttpClient(_cloud), kdfIterations: 1000);
        again.Restore();
        Assert.Equal(SyncPhase.SignedIn, again.Phase);
        Assert.NotNull(other.Keys.Read("sync/session-token"));

        // Logging out ends the session on the server too.
        var sessions = _cloud.SessionCount(Email);
        Assert.True(await other.Account.SignOutAsync());
        Assert.Equal(sessions - 1, _cloud.SessionCount(Email));
        Assert.Null(other.Keys.Read("sync/session-token"));
    }

    [Fact]
    public async Task ItemsPinsAndDeletesSyncBetweenDevices()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        var item = a.Copy("hello from A");
        await a.Sync();
        await b.Sync();
        var onB = Assert.Single(b.Store.AllItems());
        Assert.Equal(("hello from A", item.Id, (string?)null), (onB.Text, onB.Id, onB.SpaceId));

        // Pinning moves it to the pinned category (re-encrypted with the new AAD).
        b.Store.TogglePin(onB);
        await b.Sync();
        Assert.Equal("pinned", _cloud.ItemById(a.Personal, ClipStore.SyncId(item.Id)).Category);
        await a.Sync();
        Assert.True(a.Store.Find(item.Id)!.IsPinned);

        // Nothing changed: no writes, and no store change that would schedule yet another tick.
        var puts = _cloud.Count("PUT api.fake");
        var changes = 0;
        a.Store.Changed += () => changes++;
        await a.Sync();
        await b.Sync();
        await a.Sync();
        Assert.Equal(puts, _cloud.Count("PUT api.fake"));
        Assert.Equal(0, changes);

        a.Store.Delete(a.Store.Find(item.Id)!);
        await a.Sync();
        Assert.Equal("user", _cloud.ItemById(a.Personal, ClipStore.SyncId(item.Id)).Deleted);
        await b.Sync();
        Assert.Empty(b.Store.AllItems());
    }

    [Fact]
    public async Task ImagesSnippetsAndSecretsSync()
    {
        var a = await SignedUp();
        var png = RandomNumberGenerator.GetBytes(2048);
        a.Store.Blobs.Write(png, "img.png");
        a.Store.Blobs.Write([1, 2, 3], "img-thumb.png");
        var image = a.Store.Ingest(new ProcessedCapture { Kind = ClipKind.Image, Preview = "Image 4×4", Hash = "image:px:4x4:z", ImageFile = "img.png",
            ThumbnailFile = "img-thumb.png", ImageWidth = 4, ImageHeight = 4, ByteCount = png.Length });
        a.Store.CreateSnippet("Sig", ";sig", "Kind regards");
        a.Vault.Add("Wi-Fi", "hunter2");
        await a.Sync();
        Assert.Equal(2, _cloud.BlobCount(a.Personal));

        var b = await SignedIn();
        var copy = Assert.Single(b.Store.AllItems());
        Assert.Equal(ClipKind.Image, copy.Kind);
        Assert.Equal(png, File.ReadAllBytes(b.Store.Blobs.PathFor(copy.ImageFile!)));
        Assert.Equal(new byte[] { 1, 2, 3 }, File.ReadAllBytes(b.Store.Blobs.PathFor(copy.ThumbnailFile!)));
        Assert.Equal("Kind regards", Assert.Single(b.Store.AllSnippets()).Body);
        var secret = Assert.Single(b.Vault.Secrets);
        Assert.Equal(("Wi-Fi", "hunter2"), (secret.Name, b.Vault.ReadValue(secret)));

        // Pinning on B reuses the uploaded blobs; nothing bounces back on the next ticks.
        b.Store.TogglePin(copy);
        await b.Sync();
        await a.Sync();
        var puts = _cloud.Count("PUT api.fake");
        await b.Sync();
        await a.Sync();
        Assert.Equal(puts, _cloud.Count("PUT api.fake"));
        Assert.Equal(2, _cloud.BlobCount(a.Personal));
        Assert.True(a.Store.Find(image.Id)!.IsPinned);
        Assert.Equal(png, File.ReadAllBytes(a.Store.Blobs.PathFor(a.Store.Find(image.Id)!.ImageFile!)));
    }

    [Fact]
    public async Task FirstSyncUploadsNewest200HistoryPlusEverythingPinned()
    {
        var d = NewDevice();
        var oldest = d.Copy("history 0", 1000);
        for (var i = 1; i < 210; i++) d.Copy($"history {i}", 1000 - i);
        for (var i = 0; i < 3; i++) d.Store.TogglePin(d.Copy($"pinned {i}", 5000 + i));
        d.Store.CreateSnippet("S", "", "body");
        Assert.True(await d.Account.CreateAccountAsync(Email, Password, Password));
        await d.Sync();

        var live = _cloud.LiveItems(d.Personal);
        Assert.Equal(200, live.Count(i => i.Category == "history"));
        Assert.Equal(3, live.Count(i => i.Category == "pinned"));
        Assert.Equal(1, live.Count(i => i.Category == "snippet"));
        Assert.DoesNotContain(live, i => i.Id == ClipStore.SyncId(oldest.Id));
        Assert.DoesNotContain(_cloud.Items(d.Personal), i => i.Deleted == "trimmed");   // nothing pushed only to be trimmed
        Assert.Equal(213, d.Store.Count());                                           // the local history stays whole
    }

    [Fact]
    public async Task TrimmedHistoryStaysInPersonalButLeavesGroups()
    {
        _cloud.HistoryLimit = 3;
        var a = await SignedUp();
        for (var i = 0; i < 5; i++) a.Copy($"p{i}", 100 - i);
        await a.Sync();
        Assert.Equal(3, _cloud.LiveItems(a.Personal).Count);
        await a.Sync();
        Assert.Equal(5, a.Store.ItemsInSpace(null).Count);   // personal: trimmed items stay local
        var puts = _cloud.Count("PUT api.fake");
        await a.Sync();
        Assert.Equal(puts, _cloud.Count("PUT api.fake"));   // and aren't pushed again

        var b = await SignedUp("friend@example.com");
        Assert.True(await a.Account.CreateGroupAsync("Team Wien"), a.Account.Error);
        var group = Assert.Single(a.Account.Groups);
        Assert.Equal("Team Wien", group.Name);
        await Invite(a, b, group.Id);
        for (var i = 0; i < 3; i++) a.Copy($"g{i}", 50 - i, group.Id);
        await a.Sync();
        await b.Sync();
        Assert.Equal(3, b.Store.ItemsInSpace(group.Id).Count);
        Assert.Equal("Team Wien", Assert.Single(b.Store.Groups()).Name);

        b.Copy("newest from B", 0, group.Id);   // pushes the group past 3: the oldest is trimmed
        await b.Sync();
        await b.Sync();
        await a.Sync();
        Assert.Equal(3, b.Store.ItemsInSpace(group.Id).Count);
        Assert.Equal(3, a.Store.ItemsInSpace(group.Id).Count);
        Assert.DoesNotContain(a.Store.ItemsInSpace(group.Id), i => i.Text == "g0");
    }

    [Fact]
    public async Task ConflictAppliesTheServerVersion()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        var item = a.Copy("v1");
        await a.Sync();
        await b.Sync();
        var id = ClipStore.SyncId(item.Id);
        _cloud.BumpUpdatedAt(a.Personal, id, 10_000_000);   // a newer write A hasn't pulled yet
        a.Store.SetLabel("local label", a.Store.Find(item.Id)!);
        await a.Sync();
        Assert.True(_cloud.Count("PUT api.fake") > 0);
        var local = a.Store.Find(item.Id)!;
        Assert.Null(local.Label);                           // LWW: the server's version won
        Assert.False(local.IsPinned);
        var puts = _cloud.Count("PUT api.fake");
        await a.Sync();
        Assert.Equal(puts, _cloud.Count("PUT api.fake"));  // converged, no retry loop
    }

    [Fact]
    public async Task DuplicatesConvergeOnTheSmallerId()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        var onA = a.Copy("same text", 10);
        var onB = b.Copy("same text", 5);
        onB.CopyCount = 2;
        b.Store.Put(onB);
        await a.Sync();
        await b.Sync();
        await a.Sync();
        await b.Sync();
        var winner = string.CompareOrdinal(ClipStore.SyncId(onA.Id), ClipStore.SyncId(onB.Id)) < 0 ? onA.Id : onB.Id;
        foreach (var d in new[] { a, b })
        {
            var only = Assert.Single(d.Store.AllItems());
            Assert.Equal(winner, only.Id);
            Assert.Equal(3, only.CopyCount);
        }
        Assert.Single(_cloud.LiveItems(a.Personal));
    }

    [Fact]
    public async Task GroupsShareLeaveAndSignOut()
    {
        var a = await SignedUp();
        var b = await SignedUp("friend@example.com");
        Assert.True(await a.Account.CreateGroupAsync("Family"));
        var group = a.Account.Groups.Single();
        Assert.Equal(group.Id, a.Account.DefaultGroup!.Id);
        Assert.Null(await b.Account.PreviewInviteAsync("not-a-code"));
        Assert.Contains("doesn't look like an invite code", b.Account.Error);
        Assert.Null(await b.Account.PreviewInviteAsync(InviteCode.Format(InviteCode.Generate())));
        Assert.Contains("unknown, already used or expired", b.Account.Error);
        var code = (await a.Account.CreateInviteAsync(group.Id))!;
        Assert.Equal(1, _cloud.PendingInvites(group.Id));
        var pending = Assert.Single(await a.Account.InvitesAsync(group.Id));
        Assert.Equal(SyncCrypto.InviteId(InviteCode.Parse(code)!), pending.InviteId);
        var preview = await b.Account.PreviewInviteAsync(code.ToLowerInvariant().Replace("-", " "));
        Assert.Equal(("Family", 1), (preview!.Name, preview.MemberCount));
        Assert.True(await b.Account.JoinAsync(preview), b.Account.Error);
        Assert.Equal(0, _cloud.PendingInvites(group.Id));
        Assert.Null(await b.Account.PreviewInviteAsync(code));   // single use

        // Revoked invites can't be used.
        var revoked = (await a.Account.CreateInviteAsync(group.Id))!;
        Assert.True(await a.Account.RevokeInviteAsync(group.Id, SyncCrypto.InviteId(InviteCode.Parse(revoked)!)));
        Assert.Null(await b.Account.PreviewInviteAsync(revoked));

        var shared = a.Store.CopyToSpace(a.Copy("for the family"), group.Id);
        a.Store.CopySnippetToSpace(a.Store.CreateSnippet("Address", "", "Hauptstraße 1"), group.Id);
        a.Vault.Add("Router", "admin", group.Id);
        await a.Sync();
        Assert.Single(a.Store.ItemsInSpace(null));   // the personal copy stays personal

        await b.Sync();
        Assert.Equal("for the family", Assert.Single(b.Store.ItemsInSpace(group.Id)).Text);
        Assert.NotEqual(shared.Id, a.Store.ItemsInSpace(null).Single().Id);
        Assert.Equal("Hauptstraße 1", b.Store.AllSnippets().Single(s => s.SpaceId == group.Id).Body);
        Assert.Equal("admin", b.Vault.ReadValue(b.Vault.Secrets.Single(s => s.SpaceId == group.Id)));
        var members = await a.Account.MembersAsync(group.Id);
        Assert.Equal(2, members.Count);

        Assert.False(await b.Account.RenameGroupAsync(group.Id, "Nope"));   // only the owner can rename
        Assert.True(await a.Account.RenameGroupAsync(group.Id, "Family 🏠"));
        await b.Sync();
        Assert.Equal("Family 🏠", b.Store.Groups().Single().Name);
        Assert.True(await b.Account.LeaveGroupAsync(group.Id), b.Account.Error);
        Assert.Empty(b.Store.ItemsInSpace(group.Id));
        Assert.DoesNotContain(b.Vault.Secrets, s => s.SpaceId == group.Id);
        Assert.Empty(b.Store.Groups());

        b.Copy("personal on B");
        await b.Sync();
        Assert.True(await a.Account.SignOutAsync());
        Assert.Equal(SyncPhase.SignedOut, a.Account.Phase);
        Assert.Empty(a.Store.ItemsInSpace(group.Id));
        Assert.Empty(a.Store.SyncSpaces());
        Assert.Single(a.Store.ItemsInSpace(null));
        Assert.Null(a.Keys.Read("sync/account-key"));
    }

    [Fact]
    public async Task RemovedMembersLoseTheGroupOnTheirNextSync()
    {
        var a = await SignedUp();
        var b = await SignedUp("friend@example.com");
        await a.Account.CreateGroupAsync("Team");
        var group = a.Account.Groups.Single();
        await Invite(a, b, group.Id);
        a.Copy("team note", 0, group.Id);
        await a.Sync();
        await b.Sync();
        Assert.Single(b.Store.ItemsInSpace(group.Id));
        Assert.True(await a.Account.RemoveMemberAsync(group.Id, b.Account.Uid!));
        await b.Sync();
        Assert.Empty(b.Store.ItemsInSpace(group.Id));
        Assert.Empty(b.Store.Groups());
    }

    [Fact]
    public async Task ResetRequiredResyncsFromScratch()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        var kept = a.Copy("kept");
        await a.Sync();
        await b.Sync();
        _cloud.ForceReset(a.Personal);
        await b.Sync();
        Assert.Equal(kept.Id, Assert.Single(b.Store.AllItems()).Id);
        Assert.Null(b.Account.Error);
    }

    private static async Task Invite(Device owner, Device member, string groupId)
    {
        var code = await owner.Account.CreateInviteAsync(groupId);
        Assert.NotNull(code);
        var preview = await member.Account.PreviewInviteAsync(code);
        Assert.NotNull(preview);
        Assert.True(await member.Account.JoinAsync(preview), member.Account.Error);
    }

    [Fact]
    public async Task AnEndedSessionAsksForThePasswordAndKeepsData()
    {
        var a = await SignedUp();
        a.Copy("precious");
        await a.Sync();
        _cloud.RevokeSessions(Email);
        a.Copy("written while signed out");
        await a.Sync();
        Assert.Equal(SyncPhase.NeedsSignIn, a.Account.Phase);
        Assert.Contains("session ended", a.Account.Error);
        Assert.Equal(2, a.Store.Count());
        Assert.True(await a.Account.SignInAsync(Email, Password), a.Account.Error);
        Assert.Equal(SyncPhase.SignedIn, a.Account.Phase);
        await a.Sync();
        Assert.Equal(2, _cloud.LiveItems(a.Personal).Count);
    }

    [Fact]
    public async Task ChangePasswordKeepsDataAndEndsOtherSessions()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        a.Copy("old data");
        await a.Sync();
        Assert.False(await a.Account.ChangePasswordAsync("wrong", "second password", "second password"));
        Assert.Equal("The current password is wrong.", a.Account.Error);
        Assert.True(await a.Account.ChangePasswordAsync(Password, "second password", "second password"), a.Account.Error);
        await a.Sync();
        Assert.Equal(SyncPhase.SignedIn, a.Account.Phase);
        await b.Sync();
        Assert.Equal(SyncPhase.NeedsSignIn, b.Account.Phase);
        Assert.False(await b.Account.SignInAsync(Email, Password));
        Assert.True(await b.Account.SignInAsync(Email, "second password"), b.Account.Error);
        await b.Sync();
        Assert.Single(b.Store.AllItems());

        var c = await SignedIn(Email, "second password");
        Assert.Equal("old data", Assert.Single(c.Store.AllItems()).Text);
        Assert.False(await c.Account.DeleteAccountAsync("wrong"));
        Assert.True(await c.Account.DeleteAccountAsync("second password"), c.Account.Error);
        Assert.Equal(SyncPhase.SignedOut, c.Account.Phase);
        Assert.False(_cloud.HasAccount(Email));
        Assert.Single(c.Store.AllItems());   // local personal history stays
    }

    [Fact]
    public async Task RateLimitingPausesAndKeepsProgress()
    {
        var now = DateTime.UtcNow;
        var d = NewDevice(() => now);
        for (var i = 0; i < 20; i++) d.Copy($"item {i}", 100 - i);
        _cloud.RateLimitAfter = 12;
        Assert.True(await d.Account.CreateAccountAsync(Email, Password, Password));
        await d.Sync();
        Assert.NotNull(d.Account.RetryAfter);
        Assert.Null(d.Account.Error);
        var uploaded = _cloud.LiveItems(d.Personal).Count;
        Assert.InRange(uploaded, 1, 19);

        _cloud.RateLimitAfter = null;
        await d.Sync();                                    // still paused
        Assert.Equal(uploaded, _cloud.LiveItems(d.Personal).Count);
        now = now.AddMinutes(1);
        await d.Sync();
        Assert.Equal(20, _cloud.LiveItems(d.Personal).Count);
        Assert.Null(d.Account.RetryAfter);
    }
}
