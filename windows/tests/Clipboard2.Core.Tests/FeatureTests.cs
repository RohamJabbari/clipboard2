using System.Text;
using System.Text.Json.Nodes;
using Clipboard2.Core.Sync;
using Microsoft.Data.Sqlite;

namespace Clipboard2.Core.Tests;

public sealed class BackupTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "c2backup-" + Guid.NewGuid());
    private readonly List<ClipStore> _stores = [];

    public void Dispose()
    {
        foreach (var s in _stores) s.Dispose();
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }

    private ClipStore NewStore(string name)
    {
        var store = new ClipStore(":memory:", new BlobStore(Path.Combine(_dir, name)));
        _stores.Add(store);
        return store;
    }

    private static ClipItem AddImage(ClipStore store, byte[] png, byte[] thumb, string hash)
    {
        var id = Guid.NewGuid().ToString("N");
        store.Blobs.Write(png, id + ".png");
        store.Blobs.Write(thumb, id + "-thumb.png");
        return store.Ingest(new ProcessedCapture
        {
            Kind = ClipKind.Image, Preview = "Image 2×1", Hash = hash, ImageFile = id + ".png", ThumbnailFile = id + "-thumb.png",
            ImageWidth = 2, ImageHeight = 1, ByteCount = png.Length,
        });
    }

    private static readonly byte[] Png = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4, 5];
    private static readonly byte[] Thumb = [0x89, 0x50, 0x4E, 0x47, 9, 9];

    [Fact]
    public void RoundTripRestoresHistoryPinsImagesSnippetsAndSecrets()
    {
        var source = NewStore("a");
        var text = source.Ingest(ProcessedCapture.ForText("hello world"), DateTime.UtcNow.AddMinutes(-5));
        var rich = source.Ingest(ProcessedCapture.ForText("bold", rtf: @"{\rtf1 \b bold}", html: "<b>bold</b>"));
        var labelled = source.Ingest(ProcessedCapture.ForText("token-123"));
        source.SetLabel("API token", labelled);
        AddImage(source, Png, Thumb, "image:px:2x1:abc");
        source.Ingest(ProcessedCapture.ForFiles([@"C:\Users\me\Report.pdf"]));
        source.Ingest(ProcessedCapture.ForText("group only"), spaceId: "5a0c1e2b-0000-4000-8000-00000000aaaa");
        source.Touch(text, DateTime.UtcNow.AddMinutes(-3));
        var snippet = source.CreateSnippet("Sig", ";sig", "Best, R.");
        var secrets = new List<BackupSecret> { new("k1", "Wi-Fi", "hunter2", DateTime.UtcNow) };

        var file = BackupCrypto.Encrypt(Backup.CreatePlaintext(source, secrets), "pass phrase");
        var root = Backup.Parse(BackupCrypto.Decrypt(file, "pass phrase"));
        Assert.Equal(new BackupSummary(5, 1, 1), Backup.Summarize(root));

        var target = NewStore("b");
        var vault = new FakeVault();
        var result = Backup.Merge(root, target, vault);
        Assert.Equal(new BackupImportResult(5, 1, 1, 0, 0), result);

        var items = target.AllItems();
        Assert.All(items, i => Assert.Null(i.SpaceId));
        Assert.DoesNotContain(items, i => i.Text == "group only");
        var restoredText = Assert.Single(items, i => i.Text == "hello world");
        Assert.NotEqual(text.Id, restoredText.Id);
        Assert.Equal(SyncPayload.Millis(text.CreatedAt), SyncPayload.Millis(restoredText.CreatedAt));
        Assert.Equal(text.ContentHash, restoredText.ContentHash);
        var restoredRich = Assert.Single(items, i => i.Text == "bold");
        Assert.Equal((ClipKind.RichText, rich.Rtf), (restoredRich.Kind, restoredRich.Rtf));
        var restoredLabel = Assert.Single(items, i => i.Text == "token-123");
        Assert.Equal(("API token", true), (restoredLabel.Label, restoredLabel.IsPinned));
        var image = Assert.Single(items, i => i.Kind == ClipKind.Image);
        Assert.Equal(Png, File.ReadAllBytes(target.Blobs.PathFor(image.ImageFile!)));
        Assert.Equal(Thumb, File.ReadAllBytes(target.Blobs.PathFor(image.ThumbnailFile!)));
        Assert.Equal((2, 1, "image:px:2x1:abc"), (image.ImageWidth, image.ImageHeight, image.ContentHash));
        var files = Assert.Single(items, i => i.Kind == ClipKind.File);
        Assert.Equal("Report.pdf", Path.GetFileName(Assert.Single(files.Files).Replace('\\', '/')));

        var restoredSnippet = Assert.Single(target.AllSnippets());
        Assert.Equal((snippet.Name, snippet.Keyword, snippet.Body), (restoredSnippet.Name, restoredSnippet.Keyword, restoredSnippet.Body));
        var secret = Assert.Single(vault.Secrets);
        Assert.Equal(("Wi-Fi", "hunter2", (string?)null), (secret.Name, vault.ReadValue(secret), secret.SpaceId));
    }

    [Fact]
    public void ImportingTwiceAddsNothingTheSecondTime()
    {
        var store = NewStore("a");
        store.Ingest(ProcessedCapture.ForText("one"));
        store.Ingest(ProcessedCapture.ForText("two"));
        AddImage(store, Png, Thumb, "image:px:2x1:abc");
        store.CreateSnippet("S", "", "body");
        var vault = new FakeVault();
        vault.Add("Name", "value");
        var root = Backup.Create(store, [new BackupSecret("x", "Name", "value", null)]);

        var again = Backup.Merge(root, store, vault);
        Assert.Equal(new BackupImportResult(0, 0, 0, 5, 0), again);
        Assert.Equal(3, store.Count());
        Assert.Single(store.AllSnippets());
        Assert.Single(vault.Secrets);
        Assert.Equal("Nothing new to import. Skipped 5 duplicates.", again.Describe());
    }

    [Fact]
    public void DuplicatesInsideOneFileAreImportedOnceAndBadEntriesSkipped()
    {
        var root = Backup.Parse(Encoding.UTF8.GetBytes("""
            {"format":"clipboard2-backup","version":1,"createdAt":0,"app":"mac","clips":[
              {"v":1,"type":"clip","kind":"text","text":"same","preview":"same","contentHash":"text:h","createdAt":1,"lastCopiedAt":2,"copyCount":1,"isPinned":false,"id":"a"},
              {"v":1,"type":"clip","kind":"text","text":"same","preview":"same","contentHash":"text:h","createdAt":1,"lastCopiedAt":2,"copyCount":1,"isPinned":false,"id":"b"},
              {"v":1,"type":"clip","kind":"image","text":"","preview":"Image","contentHash":"image:x","createdAt":1,"lastCopiedAt":2,"id":"c"},
              {"v":1,"type":"snippet","name":"not a clip"}],
             "snippets":[{"v":1,"type":"snippet","name":"S","keyword":"","body":"b","createdAt":1,"updatedAt":1,"id":"d"},
                         {"v":1,"type":"snippet","name":"S","keyword":"other","body":"b","createdAt":1,"updatedAt":1,"id":"e"}],
             "unknownField":true}
            """));
        var store = NewStore("a");
        var result = Backup.Merge(root, store, vault: null);
        Assert.Equal(new BackupImportResult(1, 1, 0, 2, 2), result);
        Assert.Equal("same", Assert.Single(store.AllItems()).Text);
    }

    [Fact]
    public void ExportWithoutSecretsHasNoSecretsArray()
    {
        var store = NewStore("a");
        store.Ingest(ProcessedCapture.ForText("x"));
        var root = Backup.Create(store, secrets: null, app: "windows", now: SyncPayload.FromMillis(1_793_000_000_000));
        Assert.Null(root["secrets"]);
        Assert.Equal(("clipboard2-backup", 1, "windows", 1_793_000_000_000L),
            (root["format"]!.GetValue<string>(), root["version"]!.GetValue<int>(), root["app"]!.GetValue<string>(), root["createdAt"]!.GetValue<long>()));
        var clip = (JsonObject)root["clips"]![0]!;
        Assert.Equal(("clip", "text", "x"), (clip["type"]!.GetValue<string>(), clip["kind"]!.GetValue<string>(), clip["text"]!.GetValue<string>()));
        Assert.NotNull(clip["id"]);
    }

    [Fact]
    public void HeaderLayoutMatchesTheFormat()
    {
        var plaintext = "{}"u8.ToArray();
        var file = BackupCrypto.Encrypt(plaintext, "pw");
        Assert.Equal(37 + plaintext.Length + 16, file.Length);
        Assert.Equal("C2BK"u8.ToArray(), file[..4]);
        Assert.Equal(1, file[4]);
        Assert.Equal(new byte[] { 0x00, 0x09, 0x27, 0xC0 }, file[21..25]);   // 600 000 big-endian
        Assert.NotEqual(file[5..21], BackupCrypto.Encrypt(plaintext, "pw")[5..21]);   // fresh salt each time
    }

    [Fact]
    public void KnownVectorMatchesAnIndependentPbkdf2AndRoundTrips()
    {
        // Key cross-checked with Python's hashlib.pbkdf2_hmac. The passphrase is decomposed ("e" + U+0301) and must
        // be NFC-normalised first. docs/BACKUP-FORMAT.md lists this vector.
        var salt = Enumerable.Range(0, 16).Select(i => (byte)i).ToArray();
        var nonce = Enumerable.Range(100, 12).Select(i => (byte)i).ToArray();
        var key = BackupCrypto.DeriveKey("Cafe\u0301 au lait", salt, 600_000);
        Assert.Equal("52af8dbc9bc46ea3202e6d4bb4bbc39e03dba6ea450508f2a6ae2c9384f869e7", Convert.ToHexStringLower(key));
        var plaintext = """{"format":"clipboard2-backup","version":1,"createdAt":1793000000000,"app":"windows","clips":[],"snippets":[]}"""u8.ToArray();
        var file = BackupCrypto.Encrypt(plaintext, "Cafe\u0301 au lait", 600_000, salt, nonce);
        Assert.Equal(KnownVectorFile, Convert.ToHexStringLower(file));
        Assert.Equal(plaintext, BackupCrypto.Decrypt(file, "Caf\u00e9 au lait"));   // composed spelling opens it too
    }

    internal const string KnownVectorFile = "4332424b01000102030405060708090a0b0c0d0e0f000927c06465666768696a6b6c6d6e6f4575ea611c9565db9a2d81ac903b4a6d006ef7eb18f72d336234d8b490f47cbeb6efce54b328ce2dfef844f1cb7c9630db80fb98b2d549bf9badd65eedcfd4b5da33604c5113e1c34a31b8b85d887790471d2560145cecec18e8259cfbd24e501d4db673457d60367dc74e47098ec46650d735ff39451841825200f278";

    [Fact]
    public void WrongPassphraseTamperingAndForeignFilesAreRefused()
    {
        var file = BackupCrypto.Encrypt("{}"u8.ToArray(), "right");
        Assert.Contains("passphrase is wrong", Assert.Throws<BackupException>(() => BackupCrypto.Decrypt(file, "wrong")).Message);

        var tampered = (byte[])file.Clone();
        tampered[10] ^= 1;   // salt is authenticated as AAD
        Assert.Throws<BackupException>(() => BackupCrypto.Decrypt(tampered, "right"));
        var body = (byte[])file.Clone();
        body[^1] ^= 1;
        Assert.Throws<BackupException>(() => BackupCrypto.Decrypt(body, "right"));

        var newer = (byte[])file.Clone();
        newer[4] = 2;
        Assert.Contains("newer version", Assert.Throws<BackupException>(() => BackupCrypto.Decrypt(newer, "right")).Message);
        var weak = (byte[])file.Clone();
        weak[21] = 0; weak[22] = 0; weak[23] = 0x03; weak[24] = 0xE8;   // 1000 iterations
        Assert.Contains("unsupported", Assert.Throws<BackupException>(() => BackupCrypto.Decrypt(weak, "right")).Message);
        Assert.Contains("isn't a Clipboard2 backup", Assert.Throws<BackupException>(() => BackupCrypto.Decrypt("PK\u0003\u0004 a zip file, not a backup at all......"u8.ToArray(), "x")).Message);
        Assert.Throws<BackupException>(() => BackupCrypto.Decrypt(file[..40], "right"));
    }

    [Fact]
    public void ParseRejectsOtherJson()
    {
        Assert.Throws<BackupException>(() => Backup.Parse("""{"format":"something-else","version":1}"""u8.ToArray()));
        Assert.Throws<BackupException>(() => Backup.Parse("""{"format":"clipboard2-backup","version":2}"""u8.ToArray()));
        Assert.Throws<BackupException>(() => Backup.Parse("not json"u8.ToArray()));
    }
}

public sealed class ImageTextTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "c2ocr-" + Guid.NewGuid());
    private readonly ClipStore _store;

    public ImageTextTests() => _store = new ClipStore(":memory:", new BlobStore(Path.Combine(_dir, "Blobs")));

    public void Dispose()
    {
        _store.Dispose();
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }

    private ClipItem Image(string name, int ageSeconds, bool writeFile = true)
    {
        if (writeFile) _store.Blobs.Write(Encoding.UTF8.GetBytes(name), name + ".png");
        return _store.Ingest(new ProcessedCapture { Kind = ClipKind.Image, Preview = "Image", Hash = "image:" + name, ImageFile = name + ".png", ImageWidth = 4, ImageHeight = 3 },
            DateTime.UtcNow.AddSeconds(-ageSeconds));
    }

    private static Func<TimeSpan, CancellationToken, Task> NoDelay => (_, _) => Task.CompletedTask;

    [Fact]
    public async Task ReadsNewestFirstStoresTextAndMakesItSearchable()
    {
        Image("old", 60);
        Image("new", 0);
        _store.Ingest(ProcessedCapture.ForText("plain text is never read"));
        var order = new List<string>();
        var indexer = new ImageTextIndexer(_store, (path, _) =>
        {
            var name = Path.GetFileNameWithoutExtension(path);
            order.Add(name);
            return Task.FromResult<string?>(name == "new" ? "  Invoice 4711 \r\n\r\n  Total  " : "");
        }, delay: NoDelay);
        var indexed = 0;
        indexer.Indexed += _ => indexed++;
        await indexer.Kick();

        Assert.Equal(new[] { "new", "old" }, order);
        Assert.Equal(2, indexed);
        Assert.Empty(_store.ImagesNeedingOcr(10));
        var item = _store.AllItems().Single(i => i.ContentHash == "image:new");
        Assert.Equal("Invoice 4711\nTotal", item.OcrText);
        Assert.Equal("", _store.AllItems().Single(i => i.ContentHash == "image:old").OcrText);
        Assert.NotNull(FuzzyMatcher.Score("invoice", item.SearchableText));

        var model = new PanelModel(_store, new Settings(), new QuickSlots(new Settings()), new FakeVault(), new FakeHost());
        model.PrepareForOpen(null);
        model.SetQuery("4711");
        Assert.Equal(item.Id, Assert.Single(model.Entries).ClipItem!.Id);
    }

    [Fact]
    public async Task UnavailableOcrStopsWithoutMarkingAndFailuresAreNotRetried()
    {
        Image("a", 10);
        var stopped = new ImageTextIndexer(_store, (_, _) => Task.FromResult<string?>(null), delay: NoDelay);
        await stopped.Kick();
        Assert.False(stopped.IsAvailable);
        Assert.Single(_store.ImagesNeedingOcr(10));

        Image("missing", 0, writeFile: false);
        var calls = 0;
        var failing = new ImageTextIndexer(_store, (_, _) => { calls++; throw new InvalidOperationException("bad png"); }, delay: NoDelay);
        await failing.Kick();
        Assert.Equal(1, calls);   // the missing file isn't even handed to the recognizer
        Assert.Empty(_store.ImagesNeedingOcr(10));
        Assert.All(_store.AllItems(), i => Assert.Equal("", i.OcrText));
    }

    [Fact]
    public async Task WaitsBetweenImagesAndPicksUpImagesAddedMeanwhile()
    {
        Image("first", 5);
        var waits = new List<TimeSpan>();
        ImageTextIndexer? indexer = null;
        var added = false;
        indexer = new ImageTextIndexer(_store, (_, _) =>
        {
            if (!added) { added = true; Image("second", 0); _ = indexer!.Kick(); }
            return Task.FromResult<string?>("t");
        }, spacing: TimeSpan.FromSeconds(2), delay: (span, _) => { waits.Add(span); return Task.CompletedTask; });
        await indexer.Kick();
        Assert.Empty(_store.ImagesNeedingOcr(10));
        Assert.Equal(new[] { TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2) }, waits);
    }

    [Fact]
    public void SyncedOverwritesKeepTheTextAndOldDatabasesMigrate()
    {
        var image = Image("x", 0);
        _store.SetOcrText(image.Id, "kept");
        _store.Put(_store.Find(image.Id)!);   // sync writes rows without the local OCR text
        Assert.Equal("kept", _store.Find(image.Id)!.OcrText);

        Directory.CreateDirectory(_dir);
        var path = Path.Combine(_dir, "v2.db");
        new ClipStore(path, new BlobStore(Path.Combine(_dir, "B"))).Dispose();
        using (var db = new SqliteConnection($"Data Source={path};Pooling=False"))
        {
            db.Open();
            using var cmd = db.CreateCommand();
            cmd.CommandText = "ALTER TABLE clips DROP COLUMN ocr_text; PRAGMA user_version = 2;";
            cmd.ExecuteNonQuery();
        }
        using var migrated = new ClipStore(path, new BlobStore(Path.Combine(_dir, "B")));
        Assert.Equal(ClipStore.SchemaVersion, migrated.UserVersion);
        var item = migrated.Ingest(new ProcessedCapture { Kind = ClipKind.Image, Hash = "image:y", ImageFile = "y.png" });
        Assert.Single(migrated.ImagesNeedingOcr(5));
        migrated.SetOcrText(item.Id, "hi");
        Assert.Equal("hi", migrated.Find(item.Id)!.OcrText);
    }
}

public sealed class SyncStatusTextTests
{
    private static readonly DateTime Now = new(2026, 10, 27, 12, 0, 0, DateTimeKind.Utc);

    [Theory]
    [InlineData(SyncStatus.Idle, -2, null, "Synced · 2 min ago", true)]
    [InlineData(SyncStatus.Idle, 0, null, "Synced · just now", true)]
    [InlineData(SyncStatus.Idle, null, null, "Not synced yet", true)]
    [InlineData(SyncStatus.Syncing, -2, null, "Syncing…", false)]
    [InlineData(SyncStatus.Offline, -90, null, "Offline · synced 1 hr ago", true)]
    [InlineData(SyncStatus.Offline, null, null, "Offline", true)]
    [InlineData(SyncStatus.Error, -1, "Your clock is off. Fix the time and try again.", "Your clock is off", true)]
    [InlineData(SyncStatus.SignedOut, null, null, "", false)]
    public void Describes(SyncStatus status, int? minutesAgo, string? error, string text, bool canSync)
    {
        var last = minutesAgo is { } m ? Now.AddMinutes(m) : (DateTime?)null;
        var result = SyncStatusText.Describe(status, last, error, Now);
        Assert.Equal((text, canSync), (result.Text, result.CanSyncNow));
        Assert.Equal(status != SyncStatus.SignedOut, result.IsVisible);
    }

    [Fact]
    public void LongErrorsAreShortened()
    {
        var text = SyncStatusText.Shorten(new string('x', 100));
        Assert.Equal(60, text.Length);
        Assert.EndsWith("…", text);
    }

    [Fact]
    public void SignedOutAccountReportsSignedOut()
    {
        using var store = new ClipStore(":memory:", new BlobStore(Path.Combine(Path.GetTempPath(), "c2s-" + Guid.NewGuid())));
        var account = new SyncAccount(store, new FakeVault(), new Settings(), new MemoryKeys());
        account.Restore();
        Assert.Equal(SyncStatus.SignedOut, SyncStatusText.From(account).Status);
        account.SetPanelOpen(true);
        account.ReportActivity();
    }
}

public sealed class SendToDeviceTests : IDisposable
{
    private readonly ClipStore _store = new(":memory:", new BlobStore(Path.Combine(Path.GetTempPath(), "c2dev-" + Guid.NewGuid())));
    private readonly PanelModel _model;
    private readonly FakeVault _vault = new();
    private readonly List<(string Text, string Device)> _sent = [];
    private List<DeviceTarget> _devices = [new("d2", "Work Mac"), new("d1", "Laptop")];

    public SendToDeviceTests()
    {
        var settings = new Settings();
        _model = new PanelModel(_store, settings, new QuickSlots(settings), _vault, new FakeHost())
        {
            Devices = () => _devices,
            SendToDevice = (item, device) => _sent.Add((item.Text, device.Id)),
        };
    }

    public void Dispose() => _store.Dispose();

    [Fact]
    public void ClipsOfferEachOtherDeviceAndSendTheItem()
    {
        _store.Ingest(ProcessedCapture.ForText("hello"));
        _model.PrepareForOpen(null);
        _model.OpenActions();
        var sends = _model.AvailableActions.OfType<PanelAction.SendTo>().ToList();
        Assert.Equal(new[] { "Send to Laptop", "Send to Work Mac" }, sends.Select(a => a.Title(false)));
        Assert.All(sends, a => Assert.Equal("Send to Device", a.Section("AI")));

        _model.SetActionQuery("laptop");
        Assert.IsType<PanelAction.SendTo>(_model.FilteredActions[0]);
        _model.Perform(_model.FilteredActions[0]);
        Assert.Equal(new[] { ("hello", "d1") }, _sent);
        Assert.Equal(PanelMode.Browse, _model.Mode);
        Assert.Equal("Sending to Laptop…", _model.Notice);
    }

    [Fact]
    public void NoDevicesOrNonClipsOfferNothing()
    {
        _store.CreateSnippet("S", "", "body");
        _vault.Add("Secret", "v");
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Snippets);
        Assert.DoesNotContain(_model.AvailableActions, a => a is PanelAction.SendTo);
        _model.SetFilter(PanelFilter.Secrets);
        Assert.DoesNotContain(_model.AvailableActions, a => a is PanelAction.SendTo);

        _devices = [];
        _store.Ingest(ProcessedCapture.ForText("x"));
        _model.SetFilter(PanelFilter.All);
        Assert.NotNull(_model.SelectedEntry?.ClipItem);
        Assert.DoesNotContain(_model.AvailableActions, a => a is PanelAction.SendTo);
    }
}

public sealed class LegalTests
{
    [Fact]
    public void NoticeNamesTheOperatorRegionAndRights()
    {
        var privacy = Legal.PlainText(Legal.PrivacyNotice);
        foreach (var expected in new[] { "Roham Jabbari", "[ADDRESS]", "[CONTACT EMAIL]", "europe-west1", "Art. 6(1)(b)", "Art. 15",
                     "Datenschutzbehörde", "Delete Account", "can't read", "Anthropic", "90 days" })
            Assert.Contains(expected, privacy);
        var impressum = Legal.PlainText(Legal.Impressum);
        Assert.Contains("Roham Jabbari", impressum);
        Assert.Contains("[ADDRESS]", impressum);
        Assert.Contains("[CONTACT EMAIL]", impressum);
    }
}
