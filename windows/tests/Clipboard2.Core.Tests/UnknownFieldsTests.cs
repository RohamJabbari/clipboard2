using System.Text.Json.Nodes;
using Clipboard2.Core.Sync;
using Microsoft.Data.Sqlite;

namespace Clipboard2.Core.Tests;

/// <summary>Payload fields Windows doesn't manage (a password's username, urls and notes, an authenticator's urls, and
/// whatever later versions add) survive every edit made on Windows (docs/sync/PROTOCOL.md → Unknown fields).</summary>
public sealed partial class SyncEngineTests
{
    private static readonly JsonObject Future = new() { ["kind"] = "passkey", ["n"] = 2 };

    [Fact]
    public async Task PasswordFieldsAndFutureFieldsSurviveARenameAndAFolderMoveOnWindows()
    {
        var a = await SignedUp();
        a.Vault.Add("GitHub", "hunter2");
        await a.Sync();
        var item = Assert.Single(_cloud.LiveItems(a.Personal), i => i.Category == SyncCategory.Secret);

        // The Mac turns it into a password, with a field no client knows yet.
        var mac = await MacWrite(a, a.Personal, item, json =>
        {
            json["username"] = "me@example.com";
            json["urls"] = new JsonArray("https://github.com", "gist.github.com");
            json["notes"] = "recovery: ab12-cd34 ✓ 🔑";
            json["future"] = Future.DeepClone();
        });
        await a.Sync();
        var secret = Assert.Single(a.Vault.Secrets);
        Assert.NotNull(a.Vault.ReadExtras(secret));

        // Unchanged: the meta's fingerprint is the Mac's, and nothing goes back up.
        Assert.Equal(SyncPayload.Fingerprint(mac), a.Store.SyncMetaFor(a.Personal, item.Id)!.Fingerprint);
        var puts = _cloud.Count("PUT api.fake");
        await a.Sync();
        await a.Sync();
        Assert.Equal(puts, _cloud.Count("PUT api.fake"));

        // Renamed and moved into a folder on Windows: pushed with every field the Mac wrote.
        a.Vault.Rename(secret, "GitHub (work)");
        var folder = a.Store.CreateFolder("Work");
        a.Store.SetSecretFolder(secret.Id, folder.Id);
        await a.Sync();
        var pushed = Plain(a, a.Personal, _cloud.ItemById(a.Personal, item.Id));
        Assert.Equal("GitHub (work)", pushed["name"]!.GetValue<string>());
        Assert.Equal(ClipStore.SyncId(folder.Id), pushed["folder"]!.GetValue<string>());
        Assert.Equal("hunter2", pushed["value"]!.GetValue<string>());
        foreach (var field in new[] { "username", "urls", "notes", "future" })
            Assert.True(JsonNode.DeepEquals(mac[field], pushed[field]), field);

        // Another Windows device gets them too, and pushing nothing back.
        var b = await SignedIn();
        Assert.Equal(a.Vault.ReadExtras(a.Vault.Secrets.Single()), b.Vault.ReadExtras(b.Vault.Secrets.Single()));
        puts = _cloud.Count("PUT api.fake");
        await b.Sync();
        await a.Sync();
        Assert.Equal(puts, _cloud.Count("PUT api.fake"));

        // The Mac clears them: they go here too.
        var cleared = await MacWrite(a, a.Personal, _cloud.ItemById(a.Personal, item.Id), json =>
        {
            foreach (var field in new[] { "username", "urls", "notes", "future" }) json.Remove(field);
        });
        await b.Sync();
        Assert.Null(b.Vault.ReadExtras(b.Vault.Secrets.Single()));
        Assert.Equal(SyncPayload.Fingerprint(cleared), b.Store.SyncMetaFor(a.Personal, item.Id)!.Fingerprint);
    }

    [Fact]
    public async Task AuthenticatorUrlsSurviveARenameOnWindows()
    {
        var a = await SignedUp();
        var added = a.Account.Authenticators.Add("GitHub", "me", Secret)!;
        await a.Sync();
        var space = a.Account.Authenticators.Find(added.Id)!.SpaceId!;
        var item = Assert.Single(_cloud.LiveItems(space));

        var mac = await MacWrite(a, space, item, json =>
        {
            json["urls"] = new JsonArray("github.com");
            json["future"] = Future.DeepClone();
        });
        await a.Sync();
        Assert.NotNull(a.Account.Authenticators.Find(added.Id)!.Extras);
        Assert.Equal(SyncPayload.Fingerprint(mac), a.Store.SyncMetaFor(space, item.Id)!.Fingerprint);
        var puts = _cloud.Count("PUT api.fake");
        await a.Sync();
        Assert.Equal(puts, _cloud.Count("PUT api.fake"));

        a.Account.Authenticators.Rename(a.Account.Authenticators.Find(added.Id)!, "GitHub (work)", "me");
        await a.Sync();
        var pushed = Plain(a, space, _cloud.ItemById(space, item.Id));
        Assert.Equal("GitHub (work)", pushed["issuer"]!.GetValue<string>());
        Assert.True(JsonNode.DeepEquals(mac["urls"], pushed["urls"]));
        Assert.True(JsonNode.DeepEquals(mac["future"], pushed["future"]));
        Assert.Null(pushed["spaceId"]);
        Assert.Null(pushed["shares"]);
    }

    [Fact]
    public async Task UnknownFieldsOfSnippetsFoldersAndClipsSurviveEditsOnWindows()
    {
        var a = await SignedUp();
        var snippet = a.Store.CreateSnippet("Sig", ";sig", "Kind regards");
        var folder = a.Store.CreateFolder("Work");
        var clip = a.Copy("hello");
        await a.Sync();
        var items = new[] { ClipStore.SyncId(snippet.Id), ClipStore.SyncId(folder.Id), ClipStore.SyncId(clip.Id) };
        foreach (var id in items) await MacWrite(a, a.Personal, _cloud.ItemById(a.Personal, id), json => json["future"] = Future.DeepClone());
        await a.Sync();
        var puts = _cloud.Count("PUT api.fake");
        await a.Sync();
        Assert.Equal(puts, _cloud.Count("PUT api.fake"));

        var mine = a.Store.AllSnippets().Single();
        mine.Body = "Best";
        a.Store.SaveSnippet(mine);
        a.Store.RenameFolder(a.Store.FindFolder(folder.Id)!, "Office");
        a.Store.TogglePin(a.Store.Find(clip.Id)!);
        await a.Sync();
        foreach (var id in items)
            Assert.True(JsonNode.DeepEquals(Future, Plain(a, a.Personal, _cloud.ItemById(a.Personal, id))["future"]), id);
        Assert.Equal("Best", Plain(a, a.Personal, _cloud.ItemById(a.Personal, items[0]))["body"]!.GetValue<string>());
    }

    [Fact]
    public async Task ASecretThatLostItsFieldsBeforeV9GetsThemBackWithoutAPush()
    {
        var a = await SignedUp();
        a.Vault.Add("GitHub", "hunter2");
        await a.Sync();
        var item = Assert.Single(_cloud.LiveItems(a.Personal), i => i.Category == SyncCategory.Secret);
        var mac = await MacWrite(a, a.Personal, item, json => json["username"] = "me@example.com");
        await a.Sync();

        // As a 1.10 Windows left it: the secret without the field, the meta of that rendering. Then what v9 does.
        var secret = a.Vault.Secrets.Single();
        a.Vault.Put(Guid.Parse(secret.Id), secret.Name, "hunter2", null, null);
        var meta = a.Store.SyncMetaFor(a.Personal, item.Id)!;
        var stripped = (JsonObject)mac.DeepClone();
        stripped.Remove("username");
        a.Store.SaveSyncMeta(meta with { Fingerprint = SyncPayload.Fingerprint(stripped), RemoteSeq = 0 });
        a.Store.SetSyncCursor(a.Personal, 0);

        var puts = _cloud.Count("PUT api.fake");
        await a.Sync();
        Assert.Equal(puts, _cloud.Count("PUT api.fake"));
        Assert.Contains("me@example.com", a.Vault.ReadExtras(a.Vault.Secrets.Single()));
        Assert.Equal(SyncPayload.Fingerprint(mac), a.Store.SyncMetaFor(a.Personal, item.Id)!.Fingerprint);
    }

    /// <summary>The plaintext of an item on the server.</summary>
    private static JsonObject Plain(Device d, string spaceId, FakeCloud.Item item)
    {
        var space = d.Account.Engine!.Space(spaceId)!;
        var plaintext = SyncCrypto.Open(space.ItemKey, Convert.FromBase64String(item.Ciphertext!), SyncCrypto.Aad.Item(spaceId, item.Id, item.Category));
        return JsonNode.Parse(plaintext)!.AsObject();
    }

    /// <summary>Another client (the Mac) rewrites an item: its plaintext, edited, under a new updatedAt. Returns the
    /// payload as written.</summary>
    private static async Task<JsonObject> MacWrite(Device d, string spaceId, FakeCloud.Item item, Action<JsonObject> edit)
    {
        var json = Plain(d, spaceId, item);
        edit(json);
        var updatedAt = Math.Max(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), item.UpdatedAt + 1);
        json["rev"] = updatedAt;
        var space = d.Account.Engine!.Space(spaceId)!;
        var ciphertext = SyncCrypto.Seal(space.ItemKey, SyncPayload.Encode(json), SyncCrypto.Aad.Item(spaceId, item.Id, item.Category));
        Assert.IsType<WriteOutcome.Saved>(await d.Account.Api.PutItemAsync(spaceId, item.Id, item.Category, item.SortAt, updatedAt, ciphertext, item.BlobIds));
        return json;
    }
}

public sealed class UnknownFieldsPayloadTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "c2extras-" + Guid.NewGuid());

    public void Dispose()
    {
        try { Directory.Delete(_dir, true); } catch { }
    }

    /// <summary>A password as the Mac writes it (PROTOCOL.md → Item payloads), keys in its own order.</summary>
    private static JsonObject MacSecret() => JsonNode.Parse("""
        {"v":1,"type":"secret","name":"Google","value":"p\"w","createdAt":1764000000000,
         "username":"me@example.com","urls":["https://accounts.google.com","youtube.com"],"notes":"line 1\nline 2 – café 🔑",
         "zFuture":{"b":[1,2.5,{"y":true,"x":null}],"a":"é"},"rev":1764000000123}
        """)!.AsObject();

    [Fact]
    public void ExtrasAreEverythingButTheManagedAndPerWriteFields()
    {
        var extras = JsonNode.Parse(SyncPayload.ExtrasOf(MacSecret())!)!.AsObject();
        Assert.Equal(["notes", "urls", "username", "zFuture"], extras.Select(p => p.Key).Order(StringComparer.Ordinal));
        Assert.Null(SyncPayload.ExtrasOf(SyncPayload.ForSecret("n", "v", null)));
        Assert.Null(SyncPayload.ExtrasOf(new JsonObject { ["type"] = "unknown", ["x"] = 1 }));
    }

    [Fact]
    public void AnUnchangedSecretRendersToTheMacsFingerprint()
    {
        var mac = MacSecret();
        var secret = Assert.IsType<ItemPayload.Secret>(SyncPayload.Parse(SyncPayload.Encode(mac), Guid.NewGuid(), null));
        // createdAt is Credential Manager's write time here, which the fingerprint leaves out.
        var rendered = SyncPayload.ForSecret(secret.Name, secret.Value, DateTime.UtcNow, secret.Folder, secret.Extras);
        Assert.Equal(SyncPayload.Fingerprint(mac), SyncPayload.Fingerprint(rendered));
        // A rename changes it, and keeps the fields.
        var renamed = SyncPayload.ForSecret("Google (work)", secret.Value, null, null, secret.Extras);
        Assert.NotEqual(SyncPayload.Fingerprint(mac), SyncPayload.Fingerprint(renamed));
        Assert.True(JsonNode.DeepEquals(mac["zFuture"], renamed["zFuture"]));
    }

    [Fact]
    public void AnUnchangedAuthenticatorRendersToTheMacsFingerprintAndKeepsItsUrlsInItsProtectedEntry()
    {
        var mac = JsonNode.Parse("""
            {"v":1,"type":"otp","issuer":"GitHub","account":"me","secret":"JBSWY3DPEHPK3PXP","algorithm":"SHA1","digits":6,
             "period":30,"createdAt":1764000000000,"updatedAt":1764000000000,"urls":["github.com"],"later":{"k":1}}
            """)!.AsObject();
        var id = Guid.NewGuid();
        var otp = Assert.IsType<ItemPayload.Otp>(SyncPayload.Parse(SyncPayload.Encode(mac), id, "space")).Authenticator;
        Assert.Equal(SyncPayload.Fingerprint(mac), SyncPayload.Fingerprint(SyncPayload.ForOtp(otp)));

        var backing = new MemoryProtectedStore();
        new AuthenticatorStore(backing).Put(otp with { Shares = [new OtpShare("u1", "Sam", DateTime.UtcNow)] });
        var reloaded = new AuthenticatorStore(backing).Find(otp.Id)!;
        Assert.Equal(otp.Extras, reloaded.Extras);   // spaceId and shares stay this device's own
        Assert.Equal("space", reloaded.SpaceId);
        Assert.Equal(SyncPayload.Fingerprint(mac), SyncPayload.Fingerprint(SyncPayload.ForOtp(reloaded)));
    }

    [Fact]
    public void ClipsSnippetsAndFoldersKeepTheirsInTheDatabase()
    {
        using var store = new ClipStore(":memory:", new BlobStore(_dir));
        var later = new JsonObject { ["later"] = new JsonArray(1, "two") };
        JsonObject With(JsonObject json) { json["later"] = later["later"]!.DeepClone(); return json; }

        var clipJson = With(SyncPayload.ForClip(new ClipItem { Text = "hi", Preview = "hi", ContentHash = "text:hi" }));
        var clip = Assert.IsType<ItemPayload.Clip>(SyncPayload.Parse(SyncPayload.Encode(clipJson), Guid.NewGuid(), null)).Item;
        store.Put(clip);
        Assert.Equal(SyncPayload.Fingerprint(clipJson), SyncPayload.Fingerprint(SyncPayload.ForClip(store.Find(clip.Id)!)));

        var snippetJson = With(SyncPayload.ForSnippet(new Snippet { Name = "s", Body = "b" }));
        var snippet = Assert.IsType<ItemPayload.SnippetPayload>(SyncPayload.Parse(SyncPayload.Encode(snippetJson), Guid.NewGuid(), null)).Snippet;
        store.PutSnippet(snippet);
        Assert.Equal(SyncPayload.Fingerprint(snippetJson), SyncPayload.Fingerprint(SyncPayload.ForSnippet(store.AllSnippets().Single())));

        var folderJson = With(SyncPayload.ForFolder(new ClipFolder { Name = "f" }));
        var folder = Assert.IsType<ItemPayload.FolderPayload>(SyncPayload.Parse(SyncPayload.Encode(folderJson), Guid.NewGuid(), null)).Folder;
        store.PutFolder(folder);
        Assert.Equal(SyncPayload.Fingerprint(folderJson), SyncPayload.Fingerprint(SyncPayload.ForFolder(store.FindFolder(folder.Id)!)));
    }

    [Fact]
    public void SchemaV8MigratesToV9AndAppliesSyncedSecretsAndAuthenticatorsOnceMore()
    {
        Directory.CreateDirectory(_dir);
        var path = Path.Combine(_dir, "v8.db");
        using (var fresh = new ClipStore(path, new BlobStore(Path.Combine(_dir, "B"))))
        {
            fresh.SaveSyncMeta(new SyncMeta("personal", "s1", SyncCategory.Secret, "f", 41, 1, false, null, null));
            fresh.SaveSyncMeta(new SyncMeta("personal", "c1", SyncCategory.History, "f", 42, 1, false, null, null));
            fresh.SaveSyncMeta(new SyncMeta("otp-space", "o1", SyncCategory.Otp, "f", 7, 1, false, null, null));
            fresh.SaveSyncMeta(new SyncMeta("group", "c2", SyncCategory.Pinned, "f", 9, 1, false, null, null));
            fresh.SetSyncCursor("personal", 42);
            fresh.SetSyncCursor("otp-space", 7);
            fresh.SetSyncCursor("group", 9);
        }
        using (var db = new SqliteConnection($"Data Source={path};Pooling=False"))
        {
            db.Open();
            using var cmd = db.CreateCommand();
            cmd.CommandText = "ALTER TABLE clips DROP COLUMN extras; ALTER TABLE snippets DROP COLUMN extras; "
                + "ALTER TABLE folders DROP COLUMN extras; INSERT INTO snippets (id, name, keyword, body, created, updated) "
                + $"VALUES ('{Guid.NewGuid()}', 'old', '', 'b', 0, 0); PRAGMA user_version = 8;";
            cmd.ExecuteNonQuery();
        }

        using var migrated = new ClipStore(path, new BlobStore(Path.Combine(_dir, "B")));
        Assert.Equal(9, migrated.UserVersion);
        Assert.Null(migrated.AllSnippets().Single().Extras);
        Assert.Equal(0, migrated.SyncMetaFor("personal", "s1")!.RemoteSeq);
        Assert.Equal(0, migrated.SyncMetaFor("otp-space", "o1")!.RemoteSeq);
        Assert.Equal(42, migrated.SyncMetaFor("personal", "c1")!.RemoteSeq);
        Assert.Equal(9, migrated.SyncMetaFor("group", "c2")!.RemoteSeq);
        Assert.Equal(0, migrated.SyncCursor("personal"));
        Assert.Equal(0, migrated.SyncCursor("otp-space"));
        Assert.Equal(9, migrated.SyncCursor("group"));

        var item = new ClipItem { Text = "x", Preview = "x", ContentHash = "text:x", Extras = """{"a":1}""" };
        migrated.Put(item);
        Assert.Equal("""{"a":1}""", migrated.Find(item.Id)!.Extras);
    }
}
