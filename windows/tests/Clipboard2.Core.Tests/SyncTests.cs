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
    public void FilesSyncAsUrlsPlusTheirBlobs()
    {
        var path = OperatingSystem.IsWindows() ? @"C:\Users\me\report 1.pdf" : "/Users/me/report 1.pdf";
        var item = ClipItem.From(ProcessedCapture.ForFiles([path]), DateTime.UtcNow);
        var json = SyncPayload.ForClip(item);
        Assert.Equal("file", json["kind"]!.GetValue<string>());
        Assert.StartsWith("file:///", json["files"]![0]!.GetValue<string>());
        Assert.Null(json["fileBlobs"]);   // omitted when nothing was uploaded

        // Without fileBlobs (an older sender) it parses as text listing the paths.
        json["text"] = "";
        var old = Assert.IsType<ItemPayload.Clip>(SyncPayload.Parse(SyncPayload.Encode(json), item.Id, null));
        Assert.Equal(ClipKind.Text, old.Item.Kind);
        Assert.Equal(path, old.Item.Text);
        Assert.Equal(item.ContentHash, old.Item.ContentHash);
        Assert.Empty(old.FileBlobs);

        var blob = new FileBlob("report 1.pdf", "33333333-3333-4333-8333-333333333333", 1234);
        var withBlobs = SyncPayload.ForClip(item, fileBlobs: [blob]);
        Assert.Equal("""[{"name":"report 1.pdf","blob":"33333333-3333-4333-8333-333333333333","size":1234}]""", withBlobs["fileBlobs"]!.ToJsonString());
        var parsed = Assert.IsType<ItemPayload.Clip>(SyncPayload.Parse(SyncPayload.Encode(withBlobs), item.Id, null));
        Assert.Equal(blob, Assert.Single(parsed.FileBlobs));
    }

    [Theory]
    [InlineData("report.pdf", "report.pdf")]
    [InlineData("/Users/me/notes.txt", "notes.txt")]
    [InlineData(@"C:\Users\me\notes.txt", "notes.txt")]
    [InlineData("folder/", "folder")]
    [InlineData("a<b>c:d\"e|f?g*h", "abcdefgh")]
    [InlineData("tab\there", "tabhere")]
    [InlineData(".", "file")]
    [InlineData("..", "file")]
    [InlineData("../..", "file")]
    [InlineData("", "file")]
    [InlineData("trailing. ", "trailing")]
    [InlineData("CON", "_CON")]
    [InlineData("nul.txt", "_nul.txt")]
    public void ReceivedFileNamesAreSanitised(string name, string expected) => Assert.Equal(expected, SyncEngine.SafeFileName(name));

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

        public Device(FakeCloud cloud, Func<DateTime>? clock = null, int iterations = 1000)
        {
            Store = new ClipStore(":memory:", new BlobStore(Dir));
            Account = new SyncAccount(Store, Vault, Settings, Keys, new HttpClient(cloud), clock, kdfIterations: iterations, minKdfIterations: 1000);
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

    private Device NewDevice(Func<DateTime>? clock = null, int iterations = 1000)
    {
        var d = new Device(_cloud, clock, iterations);
        _devices.Add(d);
        return d;
    }

    private async Task<Device> SignedUp(string email = Email)
    {
        var d = NewDevice();
        Assert.True(await d.Account.CreateAccountAsync(email, email[..email.IndexOf('@')], Password, Password, _cloud.IssueSignupCode()), d.Account.Error);
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
        Assert.False(await d.Account.CreateAccountAsync(Email, "roham", Password, "different"));
        Assert.Equal("The passwords don't match.", d.Account.Error);
        Assert.True(await d.Account.CreateAccountAsync("  Roham@Example.com ", " roham ", Password, Password, _cloud.IssueSignupCode()), d.Account.Error);
        Assert.Equal(Email, d.Account.Email);
        Assert.True(_cloud.HasAccount(Email));
        Assert.DoesNotContain(Password, _cloud.LastAuthKey(Email)!);
        Assert.True(Guid.TryParse(d.Account.Uid, out _));

        // Same email again is refused; a wrong password is reported.
        var dup = NewDevice();
        Assert.False(await dup.Account.CreateAccountAsync(Email, "someone", Password, Password, _cloud.IssueSignupCode()));
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

    private static string WriteFile(Device d, string name, byte[] bytes)
    {
        var path = Path.Combine(d.Dir, "Documents", name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, bytes);
        return path;
    }

    [Fact]
    public async Task FilesSyncAsBlobsAndArriveAsFiles()
    {
        var a = await SignedUp();
        var pdf = WriteFile(a, "report.pdf", RandomNumberGenerator.GetBytes(5000));
        var png = WriteFile(a, "photo.png", RandomNumberGenerator.GetBytes(300));
        var folder = Path.Combine(a.Dir, "Documents", "Folder");
        Directory.CreateDirectory(folder);
        var big = Path.Combine(a.Dir, "Documents", "huge.iso");
        using (var f = File.Create(big)) f.SetLength(SyncEngine.MaxBlobBytes);   // + seal overhead: one byte too many
        var item = a.Store.Ingest(ProcessedCapture.ForFiles([pdf, folder, png, big]));
        await a.Sync();
        var remote = _cloud.ItemById(a.Personal, ClipStore.SyncId(item.Id));
        Assert.Equal(2, remote.BlobIds.Count);
        Assert.Equal(2, _cloud.BlobCount(a.Personal));

        var b = await SignedIn();
        var copy = Assert.Single(b.Store.AllItems());
        Assert.Equal(ClipKind.File, copy.Kind);
        var folderOnB = b.Store.SyncedFolder(item.Id);
        Assert.Equal([Path.Combine(folderOnB, "report.pdf"), Path.Combine(folderOnB, "photo.png")], copy.Files);
        Assert.Equal(File.ReadAllBytes(pdf), File.ReadAllBytes(copy.Files[0]));
        Assert.Equal(File.ReadAllBytes(png), File.ReadAllBytes(copy.Files[1]));
        Assert.Equal("2 files: report.pdf, photo.png", copy.Preview);
        Assert.Equal(string.Join("\n", copy.Files), copy.Text);
        Assert.Equal(item.ContentHash, copy.ContentHash);

        // Pinning on B reuses the uploaded blobs; A keeps its own files; nothing bounces back.
        b.Store.TogglePin(copy);
        await b.Sync();
        await a.Sync();
        Assert.Equal(remote.BlobIds, _cloud.ItemById(a.Personal, ClipStore.SyncId(item.Id)).BlobIds);
        var onA = a.Store.Find(item.Id)!;
        Assert.True(onA.IsPinned);
        Assert.Equal([pdf, png], onA.Files);
        Assert.False(Directory.Exists(a.Store.SyncedFolder(item.Id)));
        var puts = _cloud.Count("PUT api.fake");
        await b.Sync();
        await a.Sync();
        Assert.Equal(puts, _cloud.Count("PUT api.fake"));
        Assert.Equal(2, _cloud.BlobCount(a.Personal));

        // Deleting it removes the received files.
        a.Store.Delete(onA);
        await a.Sync();
        await b.Sync();
        Assert.Empty(b.Store.AllItems());
        Assert.False(Directory.Exists(folderOnB));
        Assert.True(File.Exists(pdf));
    }

    [Fact]
    public async Task FilesThatCantTravelArriveAsText()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        var folder = Path.Combine(a.Dir, "Documents", "Folder");
        Directory.CreateDirectory(folder);
        var missing = Path.Combine(a.Dir, "Documents", "gone.txt");
        var nothing = a.Store.Ingest(ProcessedCapture.ForFiles([folder, missing]));   // like an item from an older sender
        var lost = a.Store.Ingest(ProcessedCapture.ForFiles([WriteFile(a, "a.txt", [1]), WriteFile(a, "b.txt", [2])]));
        var half = a.Store.Ingest(ProcessedCapture.ForFiles([WriteFile(a, "c.txt", [3]), WriteFile(a, "d.txt", [4])]));
        await a.Sync();
        Assert.Empty(_cloud.ItemById(a.Personal, ClipStore.SyncId(nothing.Id)).BlobIds);
        foreach (var blob in _cloud.ItemById(a.Personal, ClipStore.SyncId(lost.Id)).BlobIds) _cloud.DropBlob(a.Personal, blob);
        _cloud.DropBlob(a.Personal, _cloud.ItemById(a.Personal, ClipStore.SyncId(half.Id)).BlobIds[0]);
        await b.Sync();

        foreach (var id in new[] { nothing.Id, lost.Id })
        {
            var text = b.Store.Find(id)!;
            Assert.Equal(ClipKind.Text, text.Kind);
            Assert.Equal(a.Store.Find(id)!.Text, text.Text);
            Assert.Empty(text.Files);
            Assert.False(Directory.Exists(b.Store.SyncedFolder(id)));
        }
        var partial = b.Store.Find(half.Id)!;
        Assert.Equal(ClipKind.File, partial.Kind);
        Assert.Equal([Path.Combine(b.Store.SyncedFolder(half.Id), "d.txt")], partial.Files);

        // A local delete removes the folder too.
        b.Store.Delete(partial);
        Assert.False(Directory.Exists(b.Store.SyncedFolder(half.Id)));
    }

    [Fact]
    public async Task FirstSyncUploadsNewest200HistoryPlusEverythingPinned()
    {
        var d = NewDevice();
        var oldest = d.Copy("history 0", 1000);
        for (var i = 1; i < 210; i++) d.Copy($"history {i}", 1000 - i);
        for (var i = 0; i < 3; i++) d.Store.TogglePin(d.Copy($"pinned {i}", 5000 + i));
        d.Store.CreateSnippet("S", "", "body");
        Assert.True(await d.Account.CreateAccountAsync(Email, "roham", Password, Password, _cloud.IssueSignupCode()));
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
        var later = NewDevice(() => DateTime.UtcNow.AddMinutes(5));   // its writes carry a later updatedAt
        Assert.True(await later.Account.SignInAsync(Email, Password), later.Account.Error);
        var item = a.Copy("v1");
        await a.Sync();
        await later.Sync();
        var id = ClipStore.SyncId(item.Id);
        later.Store.SetLabel("their label", later.Store.Find(item.Id)!);
        await later.Sync();
        _cloud.HiddenFromChanges.Add(id);                   // a newer write A hasn't pulled yet
        a.Store.SetLabel("local label", a.Store.Find(item.Id)!);
        await a.Sync();
        Assert.True(_cloud.Count("PUT api.fake") > 0);
        var local = a.Store.Find(item.Id)!;
        Assert.Equal("their label", local.Label);           // LWW: the server's version won
        _cloud.HiddenFromChanges.Clear();
        var puts = _cloud.Count("PUT api.fake");
        await a.Sync();
        await a.Sync();
        Assert.Equal(puts, _cloud.Count("PUT api.fake"));  // converged, no retry loop
        Assert.Equal("their label", a.Store.Find(item.Id)!.Label);
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
        Assert.True(await d.Account.CreateAccountAsync(Email, "roham", Password, Password, _cloud.IssueSignupCode()));
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

    [Fact]
    public async Task GroupItemsArriveWhileAFirstUploadIsRateLimited()
    {
        var a = await SignedUp();
        var b = await SignedUp("friend@example.com");
        Assert.True(await a.Account.CreateGroupAsync("Team"));
        var group = a.Account.Groups.Single();
        var preview = await b.Account.PreviewInviteAsync((await a.Account.CreateInviteAsync(group.Id))!);
        Assert.True(await b.Account.JoinAsync(preview!), b.Account.Error);
        a.Store.CopyToSpace(a.Copy("for the team"), group.Id);
        await a.Sync();

        // b's long first upload runs into the rate limit; the group download must happen before it.
        for (var i = 0; i < 30; i++) b.Copy($"backlog {i}", 100 - i);
        _cloud.RateLimitAfter = 6;
        await b.Sync();
        Assert.NotNull(b.Account.RetryAfter);
        Assert.Contains(b.Store.ItemsInSpace(group.Id), item => item.Text == "for the team");
    }

    // MARK: Usernames

    private static PanelModel Panel(Device d)
    {
        var panel = new PanelModel(d.Store, d.Settings, new QuickSlots(d.Settings), d.Vault, new FakeHost()) { Self = () => d.Account.Self };
        panel.PrepareForOpen(null);
        return panel;
    }

    private static string? Badge(Device d, string text) =>
        Panel(d).GroupBadge(new PanelEntry.Clip(d.Store.AllItems().Single(i => i.Text == text && i.SpaceId is not null)));

    [Fact]
    public async Task UsernameIsCheckedSentAtSignUpAndStored()
    {
        var d = NewDevice();
        foreach (var bad in new[] { "", "ab", "_roham", "roham!", "roham²", "Ⅻroham", new string('x', 25) })
        {
            Assert.False(await d.Account.CreateAccountAsync(Email, bad, Password, Password, _cloud.IssueSignupCode()));
            Assert.NotNull(d.Account.Error);
        }
        Assert.Equal(SyncAccount.UsernameRule, d.Account.Error);
        Assert.False(_cloud.HasAccount(Email));

        // Trimmed and NFC-normalized ("e" + combining diaeresis becomes "ë"), as the server keeps it.
        Assert.True(await d.Account.CreateAccountAsync(Email, "  Zoëy.b-1 ", Password, Password, _cloud.IssueSignupCode()), d.Account.Error);
        Assert.Equal("Zoëy.b-1", _cloud.Username(Email));
        Assert.Equal("Zoëy.b-1", d.Account.Username);
        var restored = new SyncAccount(d.Store, d.Vault, d.Settings, d.Keys, new HttpClient(_cloud), kdfIterations: 1000);
        restored.Restore();
        Assert.Equal("Zoëy.b-1", restored.Username);
        Assert.Equal("Zoëy.b-1", (await SignedIn()).Account.Username);
    }

    [Fact]
    public async Task ATakenUsernameGetsAFriendlyError()
    {
        await SignedUp();   // "roham"
        var d = NewDevice();
        Assert.False(await d.Account.CreateAccountAsync("friend@example.com", "ROHAM", Password, Password, _cloud.IssueSignupCode()));
        Assert.Equal("That username is taken. Try another one.", d.Account.Error);
        Assert.False(_cloud.HasAccount("friend@example.com"));
        Assert.Equal(SyncPhase.SignedOut, d.Account.Phase);
    }

    [Fact]
    public async Task UsernamesChangeAndOtherDevicesPickThemUp()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        await SignedUp("friend@example.com");

        Assert.True(await a.Account.ChangeUsernameAsync("  Roham_2 "), a.Account.Error);
        Assert.Equal("Roham_2", a.Account.Username);
        Assert.Equal("Roham_2", _cloud.Username(Email));
        Assert.False(await a.Account.ChangeUsernameAsync("FRIEND"));
        Assert.Equal("That username is taken. Try another one.", a.Account.Error);
        Assert.False(await a.Account.ChangeUsernameAsync("x"));
        Assert.Equal(SyncAccount.UsernameRule, a.Account.Error);
        Assert.Equal("Roham_2", a.Account.Username);

        // The other device learns it once after a restart.
        Assert.Equal("roham", b.Account.Username);
        var restarted = new SyncAccount(b.Store, b.Vault, b.Settings, b.Keys, new HttpClient(_cloud), kdfIterations: 1000);
        restarted.Restore();
        Assert.Equal("roham", restarted.Username);
        await restarted.SyncNowAsync();
        Assert.Equal("Roham_2", restarted.Username);
    }

    [Fact]
    public async Task GroupBadgesShowWhoCopiedEachItem()
    {
        var a = await SignedUp();
        var b = await SignedUp("friend@example.com");
        Assert.True(await a.Account.CreateGroupAsync("Team"));
        var group = a.Account.Groups.Single();
        await Invite(a, b, group.Id);
        a.Copy("from a", 0, group.Id);
        b.Copy("from b", 0, group.Id);
        await a.Sync();
        await b.Sync();
        await a.Sync();
        a.Copy("not sent yet", 0, group.Id);

        var members = a.Store.Groups().Single().Members!;
        Assert.Equal(new Dictionary<string, string> { [a.Account.Uid!] = "roham", [b.Account.Uid!] = "friend" }, members);
        Assert.Equal("roham", Badge(a, "from a"));
        Assert.Equal("friend", Badge(a, "from b"));
        Assert.Equal("roham", Badge(a, "not sent yet"));
        Assert.Equal("roham", Badge(b, "from a"));
        Assert.Equal("friend", Badge(b, "from b"));
        Assert.Equal("Team", Panel(a).GroupName(new PanelEntry.Clip(a.Store.AllItems().Single(i => i.Text == "from b"))));

        // Items synced before authors were kept learn theirs when the group is pulled again (the v2 migration).
        var fromB = ClipStore.SyncId(a.Store.AllItems().Single(i => i.Text == "from b").Id);
        a.Store.SaveSyncMeta(a.Store.SyncMetaFor(group.Id, fromB)! with { AuthorUid = null });
        Assert.Equal("Team", Badge(a, "from b"));
        a.Store.SetSyncCursor(group.Id, 0);
        await a.Sync();
        Assert.Equal("friend", Badge(a, "from b"));

        // Members' names follow username changes.
        Assert.True(await b.Account.ChangeUsernameAsync("Fritzi"));
        await a.Sync();
        Assert.Equal("Fritzi", Badge(a, "from b"));
    }

    [Fact]
    public async Task AnOldServerWithoutUsernamesStillWorksAndBadgesShowTheGroup()
    {
        _cloud.Legacy = true;
        var a = await SignedUp();
        var b = await SignedUp("friend@example.com");
        Assert.Null(a.Account.Username);
        Assert.Null((await SignedIn()).Account.Username);
        Assert.True(await a.Account.CreateGroupAsync("Team"));
        var group = a.Account.Groups.Single();
        await Invite(a, b, group.Id);
        a.Copy("from a", 0, group.Id);
        b.Copy("from b", 0, group.Id);
        await a.Sync();
        await b.Sync();
        await a.Sync();

        Assert.Null(a.Store.Groups().Single().Members);
        Assert.Equal("Team", Badge(a, "from a"));
        Assert.Equal("Team", Badge(a, "from b"));
        Assert.False(await a.Account.ChangeUsernameAsync("roham"));
        Assert.Equal("The sync server doesn't support usernames yet.", a.Account.Error);
    }

    // MARK: October 2026 hardening (docs/sync/HARDENING-2026-10.md)

    private int Puts(Device d, string id) => _cloud.Count($"PUT api.fake/v1/spaces/{d.Personal}/items/{id}");

    [Fact]
    public async Task AQuotaErrorDoesNotHoldBackDeletions()
    {
        _cloud.MaxLiveItems = 2;
        var a = await SignedUp();
        var x = a.Copy("x", 30);
        var y = a.Copy("y", 20);
        await a.Sync();
        Assert.Equal(2, _cloud.LiveItems(a.Personal).Count);

        a.Store.Delete(a.Store.Find(x.Id)!);
        var z = a.Copy("z", 10);
        var w = a.Copy("w", 5);
        await a.Sync();
        Assert.Equal("user", _cloud.ItemById(a.Personal, ClipStore.SyncId(x.Id)).Deleted);   // deletions go first
        Assert.Equal(new[] { ClipStore.SyncId(y.Id), ClipStore.SyncId(w.Id) }.Order(), _cloud.LiveItems(a.Personal).Select(i => i.Id).Order());
        Assert.Contains("quota_exceeded", a.Account.Warnings);
        Assert.Null(a.Account.Error);

        // Refused until a deletion frees space (or the next launch), not on every tick.
        var puts = Puts(a, ClipStore.SyncId(z.Id));
        await a.Sync();
        Assert.Equal(puts, Puts(a, ClipStore.SyncId(z.Id)));
        a.Store.Delete(a.Store.Find(y.Id)!);
        await a.Sync();
        Assert.Contains(_cloud.LiveItems(a.Personal), i => i.Id == ClipStore.SyncId(z.Id));
    }

    [Fact]
    public async Task APullDoesNotUndoAnUnpushedLocalDelete()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        var item = a.Copy("shared");
        await a.Sync();
        await b.Sync();
        b.Store.Delete(b.Store.Find(item.Id)!);   // not pushed yet
        a.Store.TogglePin(a.Store.Find(item.Id)!);
        await a.Sync();                            // a remote edit B hasn't seen
        await b.Sync();
        Assert.Null(b.Store.Find(item.Id));
        Assert.Equal("user", _cloud.ItemById(a.Personal, ClipStore.SyncId(item.Id)).Deleted);
        await a.Sync();
        Assert.Null(a.Store.Find(item.Id));
    }

    [Fact]
    public async Task ANewerUnpushedLocalEditWinsAndAnOlderOneLoses()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        a.Store.CreateSnippet("Sig", "", "v1");
        await a.Sync();
        await b.Sync();

        static void Edit(Device d, string body)
        {
            var snippet = d.Store.AllSnippets().Single();
            snippet.Body = body;
            d.Store.SaveSnippet(snippet);
        }

        Edit(a, "from A");
        await a.Sync();
        await Task.Delay(20);
        Edit(b, "from B, later");                  // newer than A's upload, not pushed yet
        await b.Sync();
        Assert.Equal("from B, later", b.Store.AllSnippets().Single().Body);
        await a.Sync();
        Assert.Equal("from B, later", a.Store.AllSnippets().Single().Body);

        Edit(b, "older on B");
        await Task.Delay(20);
        Edit(a, "newer on A");
        await a.Sync();
        await b.Sync();
        Assert.Equal("newer on A", b.Store.AllSnippets().Single().Body);
        var puts = _cloud.Count("PUT api.fake");
        await b.Sync();
        await a.Sync();
        Assert.Equal(puts, _cloud.Count("PUT api.fake"));
    }

    [Fact]
    public async Task AnInterruptedResyncCarriesOnAndReconciles()
    {
        _cloud.PageLimit = 2;
        var a = await SignedUp();
        var now = DateTime.UtcNow;
        var b = NewDevice(() => now);
        Assert.True(await b.Account.CreateAccountAsync("friend@example.com", "friend", Password, Password, _cloud.IssueSignupCode()), b.Account.Error);
        await b.Sync();
        Assert.True(await a.Account.CreateGroupAsync("Team"));
        var group = a.Account.Groups.Single();
        await Invite(a, b, group.Id);
        var gone = a.Copy("gone", 60, group.Id);
        a.Copy("kept", 50, group.Id);
        await a.Sync();
        await b.Sync();
        Assert.Equal(2, b.Store.ItemsInSpace(group.Id).Count);

        // While B is away: "gone" is deleted and its tombstone purged, and four items arrive.
        a.Store.Delete(a.Store.Find(gone.Id)!);
        await a.Sync();
        _cloud.Purge(group.Id, ClipStore.SyncId(gone.Id));
        for (var i = 0; i < 4; i++) a.Copy($"new {i}", 40 - i, group.Id);
        await a.Sync();

        _cloud.RateLimitAfter = 3;                           // spaces, the reset, the first page; then 429
        await b.Sync();
        Assert.NotNull(b.Account.RetryAfter);
        Assert.True(b.Store.IsResyncing(group.Id));
        Assert.NotNull(b.Store.Find(gone.Id));

        _cloud.RateLimitAfter = null;
        now = now.AddMinutes(1);
        await b.Sync();                                      // carries on from the cursor and reconciles
        Assert.False(b.Store.IsResyncing(group.Id));
        Assert.Null(b.Store.Find(gone.Id));
        Assert.Equal(5, b.Store.ItemsInSpace(group.Id).Count);
    }

    [Fact]
    public async Task RefusedItemsAreNotUploadedAgainAfterARestart()
    {
        _cloud.MaxItemBytes = 600;
        var d = await SignedUp();
        var big = d.Copy(new string('x', 2000));
        d.Copy("small");
        await d.Sync();
        var id = ClipStore.SyncId(big.Id);
        Assert.DoesNotContain(_cloud.LiveItems(d.Personal), i => i.Id == id);
        Assert.Single(_cloud.LiveItems(d.Personal));
        var puts = Puts(d, id);
        Assert.Equal(1, puts);

        var restarted = new SyncAccount(d.Store, d.Vault, d.Settings, d.Keys, new HttpClient(_cloud), kdfIterations: 1000);
        restarted.Restore();
        await restarted.SyncNowAsync();
        await restarted.SyncNowAsync();
        Assert.Equal(puts, Puts(d, id));

        d.Store.ReplaceText(d.Store.Find(big.Id)!, "short now");   // changed: tried again
        await restarted.SyncNowAsync();
        Assert.Contains(_cloud.LiveItems(d.Personal), i => i.Id == id);
    }

    [Fact]
    public async Task ReceivedFilesAreMarkedAsDownloaded()
    {
        Assert.Equal("[ZoneTransfer]\r\nZoneId=3\r\n", ZoneIdentifier.Content);
        var a = await SignedUp();
        var b = await SignedIn();
        var marked = new List<string>();
        b.Account.Engine!.MarkReceivedFile = path =>
        {
            marked.Add(path);
            ZoneIdentifier.Mark(path);
        };
        var item = a.Store.Ingest(ProcessedCapture.ForFiles([WriteFile(a, "report.pdf", RandomNumberGenerator.GetBytes(500)), WriteFile(a, "notes.txt", [1, 2])]));
        await a.Sync();
        await b.Sync();
        var copy = b.Store.Find(item.Id)!;
        Assert.Equal(2, copy.Files.Count);
        Assert.Equal(copy.Files, marked);
        if (OperatingSystem.IsWindows())
            foreach (var file in copy.Files) Assert.Contains("ZoneId=3", File.ReadAllText(file + ":Zone.Identifier"));
        Assert.All(Directory.GetFiles(b.Store.SyncedFolder(item.Id)), f => Assert.DoesNotContain("Zone.Identifier", f));
    }

    private static JsonObject OpenPayload(Device d, FakeCloud.Item remote)
    {
        var space = d.Account.Engine!.Space(d.Personal)!;
        var plaintext = SyncCrypto.Open(space.ItemKey, Convert.FromBase64String(remote.Ciphertext!), SyncCrypto.Aad.Item(space.Id, remote.Id, remote.Category));
        return JsonNode.Parse(plaintext)!.AsObject();
    }

    [Fact]
    public async Task PayloadsCarryRevAndReplaysAndRollbacksAreDropped()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        var item = a.Copy("v1");
        await a.Sync();
        var id = ClipStore.SyncId(item.Id);
        var remote = _cloud.ItemById(a.Personal, id);
        Assert.Equal(remote.UpdatedAt, OpenPayload(a, remote)["rev"]!.GetValue<long>());
        await b.Sync();
        a.Store.TogglePin(a.Store.Find(item.Id)!);
        await a.Sync();
        await b.Sync();
        Assert.True(b.Store.Find(item.Id)!.IsPinned);

        _cloud.ServePrevious(a.Personal, id, rollback: false);   // the old ciphertext under a new updatedAt
        await b.Sync();
        Assert.True(b.Store.Find(item.Id)!.IsPinned);
        _cloud.ServePrevious(a.Personal, id, rollback: true);    // the old ciphertext with its own old updatedAt
        await b.Sync();
        Assert.True(b.Store.Find(item.Id)!.IsPinned);

        // Payloads from older apps (no rev) are accepted; rev and toDevice never count as a change.
        var legacy = SyncPayload.ForClip(item);
        Assert.Null(SyncPayload.Parse(SyncPayload.Encode(legacy), item.Id, null)!.Rev);
        var written = (JsonObject)legacy.DeepClone();
        written["rev"] = 5;
        written["toDevice"] = "x";
        Assert.Equal(5, SyncPayload.Parse(SyncPayload.Encode(written), item.Id, null)!.Rev);
        Assert.Equal(SyncPayload.Fingerprint(legacy), SyncPayload.Fingerprint(written));
    }

    [Fact]
    public async Task ReceivedTimesAreClampedToArrival()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        var future = a.Store.Ingest(ProcessedCapture.ForText("from a fast clock"), DateTime.UtcNow.AddMinutes(5));
        await a.Sync();
        await b.Sync();
        var copy = b.Store.Find(future.Id)!;
        Assert.True(copy.LastCopiedAt <= DateTime.UtcNow);
        Assert.True(copy.CreatedAt <= DateTime.UtcNow);
        var puts = _cloud.Count("PUT api.fake");
        await b.Sync();
        Assert.Equal(puts, _cloud.Count("PUT api.fake"));   // the clamped copy doesn't bounce back
    }

    [Fact]
    public async Task KdfSettingsOutOfBoundsOrLoweredAreRefusedBeforeDeriving()
    {
        var d = NewDevice(iterations: 2000);
        Assert.True(await d.Account.CreateAccountAsync(Email, "roham", Password, Password, _cloud.IssueSignupCode()), d.Account.Error);
        Assert.True(await d.Account.SignOutAsync());
        var logins = _cloud.Count("POST api.fake/v1/auth/login");

        _cloud.SetIterations(Email, 1500);   // lower than this PC saw for this email
        Assert.False(await d.Account.SignInAsync(Email, Password));
        Assert.Contains("weaker password settings", d.Account.Error);
        foreach (var iterations in new[] { 999, SyncCrypto.MaxKdfIterations + 1 })
        {
            _cloud.SetIterations(Email, iterations);
            var fresh = NewDevice();
            Assert.False(await fresh.Account.SignInAsync(Email, Password));
            Assert.Contains("unusual password settings", fresh.Account.Error);
        }
        Assert.Equal(logins, _cloud.Count("POST api.fake/v1/auth/login"));   // the password was never used
        Assert.Equal(600_000, SyncCrypto.MinKdfIterations);
    }

    [Fact]
    public async Task AChangedGroupKeyIsNotAdoptedUntilLeaveAndRejoin()
    {
        var a = await SignedUp();
        var b = await SignedUp("friend@example.com");
        Assert.True(await a.Account.CreateGroupAsync("Team"));
        var group = a.Account.Groups.Single();
        await Invite(a, b, group.Id);
        a.Copy("before", 0, group.Id);
        await a.Sync();
        await b.Sync();

        var evil = SyncCrypto.WrapSpaceKey(SyncCrypto.RandomKey(), group.Id, b.Account.Uid!, _cloud.PublicKey("friend@example.com"));
        _cloud.ReplaceWrappedKey(group.Id, b.Account.Uid!, evil);
        a.Copy("after", 0, group.Id);
        await a.Sync();
        await b.Sync();
        Assert.Contains("This group's key changed unexpectedly", b.Account.Error);
        Assert.Equal(SyncStatus.Error, b.Account.CurrentStatus);
        Assert.DoesNotContain(b.Store.ItemsInSpace(group.Id), i => i.Text == "after");
        Assert.Contains(b.Store.ItemsInSpace(group.Id), i => i.Text == "before");
        Assert.Single(b.Store.Groups());   // still listed, so it can be left

        Assert.True(await b.Account.LeaveGroupAsync(group.Id), b.Account.Error);
        await Invite(a, b, group.Id);
        await b.Sync();
        Assert.Null(b.Account.Error);
        Assert.Contains(b.Store.ItemsInSpace(group.Id), i => i.Text == "after");
    }

    [Fact]
    public async Task SignUpNeedsAnInviteCodeAndAGroupCodeJoinsTheGroup()
    {
        var d = NewDevice();
        Assert.False(await d.Account.CreateAccountAsync(Email, "roham", Password, Password));
        Assert.Contains("invite-only", d.Account.Error);
        Assert.False(await d.Account.CreateAccountAsync(Email, "roham", Password, Password, "ABCD-EFGH"));
        Assert.Contains("doesn't look like an invite code", d.Account.Error);
        Assert.False(await d.Account.CreateAccountAsync(Email, "roham", Password, Password, "AAAA-AAAA-AAAA-AAAA"));
        Assert.Contains("unknown, already used or expired", d.Account.Error);
        Assert.False(_cloud.HasAccount(Email));

        var code = _cloud.IssueSignupCode();
        Assert.True(await d.Account.CreateAccountAsync(Email, "roham", Password, Password, code.ToLowerInvariant().Replace("-", " ")), d.Account.Error);
        Assert.Equal(0, _cloud.OpenSignupCodes);
        var reuse = NewDevice();
        Assert.False(await reuse.Account.CreateAccountAsync("other@example.com", "other", Password, Password, code));
        Assert.Contains("already used", reuse.Account.Error);

        // A group invite code signs up and joins that group.
        Assert.True(await d.Account.CreateGroupAsync("Family"));
        var group = d.Account.Groups.Single();
        var groupCode = (await d.Account.CreateInviteAsync(group.Id))!;
        var friend = NewDevice();
        Assert.True(await friend.Account.CreateAccountAsync("friend@example.com", "friend", Password, Password, groupCode), friend.Account.Error);
        Assert.Equal("Family", Assert.Single(friend.Account.Groups).Name);
        Assert.Contains("You joined Family", friend.Account.Status);
        Assert.Equal(0, _cloud.PendingInvites(group.Id));
    }

    [Fact]
    public async Task InviteSomeoneCreatesListsAndRevokesSignupCodes()
    {
        var d = await SignedUp();
        var code = await d.Account.CreateSignupCodeAsync();
        Assert.Matches("^[A-Z2-7]{4}(-[A-Z2-7]{4}){3}$", code);
        var open = Assert.Single(await d.Account.SignupCodesAsync());
        Assert.True(await d.Account.RevokeSignupCodeAsync(open.Id));
        Assert.Empty(await d.Account.SignupCodesAsync());

        var codes = new List<string>();
        for (var i = 0; i < 10; i++) codes.Add((await d.Account.CreateSignupCodeAsync())!);
        Assert.Null(await d.Account.CreateSignupCodeAsync());
        Assert.Contains("10 open invites", d.Account.Error);

        // A code works once for signing up, and then no longer counts as open.
        var invited = NewDevice();
        Assert.True(await invited.Account.CreateAccountAsync("invited@example.com", "invited", Password, Password, codes[3]), invited.Account.Error);
        Assert.Equal(9, (await d.Account.SignupCodesAsync()).Count);
        Assert.NotNull(await d.Account.CreateSignupCodeAsync());
    }

    [Fact]
    public async Task DevicesAreListedSignedOutAndSentTo()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        await a.Account.RefreshDevicesAsync();
        Assert.Equal(2, a.Account.Devices.Count);
        Assert.True(a.Account.Devices[0].IsCurrent);
        Assert.Equal(Environment.MachineName, a.Account.Devices[0].Name);
        var bId = b.Account.CurrentDeviceId!;
        Assert.NotEqual(a.Account.CurrentDeviceId, bId);

        var received = new List<(ClipItem Item, string From)>();
        b.Account.ReceivedFromDevice += (item, from) => received.Add((item, from));
        var old = a.Copy("send me", 600);
        await a.Sync();
        await b.Sync();
        b.Copy("something newer on B");
        Assert.Empty(received);

        Assert.False(await a.Account.SendToDeviceAsync(a.Store.Find(old.Id)!, a.Account.CurrentDeviceId!));
        Assert.True(await a.Account.SendToDeviceAsync(a.Store.Find(old.Id)!, bId), a.Account.Error);
        Assert.Equal(old.Id, a.Store.AllItems().First().Id);
        await b.Sync();
        var (sent, from) = Assert.Single(received);
        Assert.Equal(old.Id, sent.Id);
        Assert.Equal(Environment.MachineName, from);
        Assert.Equal(old.Id, b.Store.AllItems().First().Id);   // at the top on B
        var puts = _cloud.Count("PUT api.fake");
        await a.Sync();
        await b.Sync();
        Assert.Equal(puts, _cloud.Count("PUT api.fake"));
        Assert.Single(received);

        // Another device just gets the item.
        var c = await SignedIn();
        Assert.Contains(c.Store.AllItems(), i => i.Id == old.Id);

        Assert.True(await a.Account.SignOutDeviceAsync(bId), a.Account.Error);
        await b.Sync();
        Assert.Equal(SyncPhase.NeedsSignIn, b.Account.Phase);
        Assert.True(await a.Account.SignOutDeviceAsync(a.Account.CurrentDeviceId!), a.Account.Error);
        Assert.Equal(SyncPhase.SignedOut, a.Account.Phase);
        Assert.Equal(SyncStatus.SignedOut, a.Account.CurrentStatus);
    }

    [Fact]
    public async Task StatusAndPollingCadence()
    {
        var now = DateTime.UtcNow;
        var d = NewDevice(() => now);
        Assert.Equal(SyncStatus.SignedOut, d.Account.CurrentStatus);
        var seen = new List<SyncStatus>();
        d.Account.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(SyncAccount.CurrentStatus)) seen.Add(d.Account.CurrentStatus);
        };
        Assert.True(await d.Account.CreateAccountAsync(Email, "roham", Password, Password, _cloud.IssueSignupCode()));
        await d.Sync();
        Assert.Equal(SyncStatus.Idle, d.Account.CurrentStatus);
        Assert.Contains(SyncStatus.Syncing, seen);

        Assert.Equal(SyncAccount.IdlePollInterval, d.Account.PollInterval);
        d.Account.ReportActivity();
        Assert.Equal(TimeSpan.FromSeconds(15), d.Account.PollInterval);
        var changes = _cloud.Count("GET api.fake/v1/spaces");
        d.Account.SetPanelOpen(true);   // syncs once right away
        Assert.Equal(TimeSpan.FromSeconds(3), d.Account.PollInterval);
        await d.Sync();
        Assert.True(_cloud.Count("GET api.fake/v1/spaces") > changes);
        Assert.False(d.Account.PollIfDue());
        now = now.AddSeconds(4);
        Assert.True(d.Account.PollIfDue());
        await d.Sync();
        d.Account.SetPanelOpen(false);
        Assert.Equal(TimeSpan.FromSeconds(15), d.Account.PollInterval);
        now = now.AddSeconds(14);
        Assert.False(d.Account.PollIfDue());
        now = now.AddMinutes(5);
        Assert.Equal(TimeSpan.FromSeconds(60), d.Account.PollInterval);
        Assert.True(d.Account.PollIfDue());
        await d.Sync();

        _cloud.Offline = true;
        now = now.AddMinutes(2);
        await d.Sync();
        Assert.Equal(SyncStatus.Offline, d.Account.CurrentStatus);
        _cloud.Offline = false;
        await d.Sync();
        Assert.Equal(SyncStatus.Idle, d.Account.CurrentStatus);
        Assert.Null(d.Account.Error);
    }

    [Fact]
    public async Task AFastClockIsReportedAndItsItemsWaitForTheNextLaunch()
    {
        var d = NewDevice(() => DateTime.UtcNow.AddMinutes(30));
        Assert.True(await d.Account.CreateAccountAsync(Email, "roham", Password, Password, _cloud.IssueSignupCode()), d.Account.Error);
        var item = d.Copy("written with a fast clock");
        await d.Sync();
        Assert.Contains("Your clock is off", d.Account.Error);
        Assert.Equal(SyncStatus.Error, d.Account.CurrentStatus);
        Assert.Empty(_cloud.LiveItems(d.Personal));
        var puts = Puts(d, ClipStore.SyncId(item.Id));
        await d.Sync();
        Assert.Equal(puts, Puts(d, ClipStore.SyncId(item.Id)));
    }

    [Fact]
    public async Task OthersGroupItemsCantBeChangedButStayChangedHere()
    {
        var a = await SignedUp();
        var b = await SignedUp("friend@example.com");
        Assert.True(await a.Account.CreateGroupAsync("Team"));
        var group = a.Account.Groups.Single();
        await Invite(a, b, group.Id);
        var note = a.Copy("a's note", 0, group.Id);
        await a.Sync();
        await b.Sync();

        b.Store.SetLabel("b's label", b.Store.Find(note.Id)!);
        await b.Sync();
        Assert.Contains(b.Account.Warnings, w => w.Contains("Only its author or the group's owner"));
        Assert.Equal("b's label", b.Store.Find(note.Id)!.Label);   // kept here
        await a.Sync();
        Assert.Null(a.Store.Find(note.Id)!.Label);
        var writes = _cloud.Count("PUT api.fake") + _cloud.Count("DELETE api.fake");
        await b.Sync();
        Assert.Equal(writes, _cloud.Count("PUT api.fake") + _cloud.Count("DELETE api.fake"));

        b.Store.Delete(b.Store.Find(note.Id)!);
        await b.Sync();
        await b.Sync();
        Assert.Null(b.Store.Find(note.Id));
        Assert.Contains(_cloud.LiveItems(group.Id), i => i.Id == ClipStore.SyncId(note.Id));
        Assert.Equal(1, _cloud.Count($"DELETE api.fake/v1/spaces/{group.Id}/items/{ClipStore.SyncId(note.Id)}"));
    }

    [Fact]
    public void SignupInvitesAreParsedLikeInviteCodes()
    {
        Assert.Equal("ABCDEFGHIJKLMNOP", Assert.IsType<SignupInvite.Code>(SignupInvite.Parse(" abcd-efgh-ijkl-mnop ")).Value);
        Assert.Equal("OIBA2345OIBAQRST", Assert.IsType<SignupInvite.Code>(SignupInvite.Parse("018A-2345-018A-QRST")).Value);
        var bytes = InviteCode.Generate();
        Assert.Equal(bytes, Assert.IsType<SignupInvite.Group>(SignupInvite.Parse(InviteCode.Format(bytes))).CodeBytes);
        Assert.Null(SignupInvite.Parse("ABCD-EFGH-IJKL-MNO"));
        Assert.Null(SignupInvite.Parse("ABCD-EFGH-IJKL-MNO9"));
        Assert.Null(SignupInvite.Parse(""));
    }
}
