using System.Text;
using System.Text.Json.Nodes;
using Clipboard2.Core.Sync;

namespace Clipboard2.Core.Tests;

/// <summary>TOTP, base32, otpauth links, QR codes, code batches, the store, the panel and backups (docs/features/authenticator.md).</summary>
public sealed class AuthenticatorTests : IDisposable
{
    private static readonly byte[] Sha1Key = Encoding.ASCII.GetBytes("12345678901234567890");
    private static readonly byte[] Sha256Key = Encoding.ASCII.GetBytes("12345678901234567890123456789012");
    private static readonly byte[] Sha512Key = Encoding.ASCII.GetBytes("1234567890123456789012345678901234567890123456789012345678901234");

    private readonly ClipStore _store = new(":memory:", new BlobStore(Path.Combine(Path.GetTempPath(), "c2otp-" + Guid.NewGuid())));
    private readonly Settings _settings = new();
    private readonly FakeHost _host = new();
    private DateTime _now = new(2026, 11, 20, 12, 0, 10, DateTimeKind.Utc);

    public void Dispose() => _store.Dispose();

    [Theory]
    [InlineData(59L, "94287082", "46119246", "90693936")]
    [InlineData(1111111109L, "07081804", "68084774", "25091201")]
    [InlineData(1111111111L, "14050471", "67062674", "99943326")]
    [InlineData(1234567890L, "89005924", "91819424", "93441116")]
    [InlineData(2000000000L, "69279037", "90698825", "38618901")]
    [InlineData(20000000000L, "65353130", "77737706", "47863826")]
    public void Rfc6238Vectors(long time, string sha1, string sha256, string sha512)
    {
        Assert.Equal(sha1, Totp.Code(Sha1Key, OtpAlgorithm.SHA1, 8, 30, time));
        Assert.Equal(sha256, Totp.Code(Sha256Key, OtpAlgorithm.SHA256, 8, 30, time));
        Assert.Equal(sha512, Totp.Code(Sha512Key, OtpAlgorithm.SHA512, 8, 30, time));
        // Six digits are the last six of the same number.
        Assert.Equal(sha1[2..], Totp.Code(Sha1Key, OtpAlgorithm.SHA1, 6, 30, time));
    }

    [Fact]
    public void Base32IsLenient()
    {
        var expected = Base32.Decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ");
        Assert.Equal(Sha1Key, expected);
        Assert.Equal(expected, Base32.Decode("gezd gnbv gy3t qojq gezd gnbv gy3t qojq"));
        Assert.Equal(expected, Base32.Decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ===="));
        Assert.Equal(Encoding.ASCII.GetBytes("foobar"), Base32.Decode("mzxw6ytboi"));   // no padding
        Assert.Null(Base32.Decode("NOT*BASE32"));
        Assert.Null(Base32.Decode("01"));
        Assert.Null(Base32.Decode("  "));
        Assert.Equal("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", Base32.Encode(Sha1Key));
        Assert.Equal("MZXW6YTBOI", Base32.Encode(Encoding.ASCII.GetBytes("foobar")));
    }

    [Fact]
    public void ParsesTotpLinks()
    {
        var draft = OtpAuthUri.Parse("otpauth://totp/GitHub:me%40example.com?secret=jbsw y3dp ehpk 3pxp&issuer=GitHub&algorithm=SHA256&digits=8&period=60", out var error);
        Assert.Null(error);
        Assert.Equal(new OtpAuthDraft("GitHub", "me@example.com", "JBSWY3DPEHPK3PXP", OtpAlgorithm.SHA256, 8, 60), draft);

        // The issuer parameter wins over the label's; defaults apply.
        var plain = OtpAuthUri.Parse("otpauth://totp/Old:alice?secret=JBSWY3DPEHPK3PXP&issuer=New", out _)!;
        Assert.Equal(("New", "alice", OtpAlgorithm.SHA1, 6, 30), (plain.Issuer, plain.Account, plain.Algorithm, plain.Digits, plain.Period));
        var noIssuer = OtpAuthUri.Parse("otpauth://totp/bob?secret=JBSWY3DPEHPK3PXP", out _)!;
        Assert.Equal(("", "bob"), (noIssuer.Issuer, noIssuer.Account));
    }

    [Fact]
    public void RefusesHotpAndBrokenLinks()
    {
        Assert.Null(OtpAuthUri.Parse("otpauth://hotp/Bank:me?secret=JBSWY3DPEHPK3PXP&counter=1", out var hotp));
        Assert.Equal(OtpAuthUri.HotpNotSupported, hotp);
        Assert.Null(OtpAuthUri.Parse("otpauth://totp/x?secret=!!!", out var bad));
        Assert.Contains("secret", bad);
        Assert.Null(OtpAuthUri.Parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=5", out _));
        Assert.Null(OtpAuthUri.Parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=MD5", out _));
        Assert.Null(OtpAuthUri.Parse("https://example.com", out _));
    }

    [Fact]
    public void FormatRoundTrips()
    {
        var a = new Authenticator("x", "Acme Corp", "me@x.com", "JBSWY3DPEHPK3PXP", OtpAlgorithm.SHA512, 7, 45, _now, _now);
        var draft = OtpAuthUri.Parse(OtpAuthUri.Format(a), out _)!;
        Assert.Equal(new OtpAuthDraft("Acme Corp", "me@x.com", "JBSWY3DPEHPK3PXP", OtpAlgorithm.SHA512, 7, 45), draft);
    }

    [Fact]
    public void CaptureNeverStoresOtpauthText()
    {
        foreach (var text in new[] { "otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP", "  OTPAUTH://hotp/x?secret=JBSWY3DPEHPK3PXP", "otpauth://totp/broken" })
        {
            Assert.False(CaptureFilter.ShouldStore(ProcessedCapture.ForText(text)));
            Assert.False(CaptureFilter.ShouldStore(ProcessedCapture.ForText(text, rtf: "{\\rtf1 x}")));
        }
        Assert.True(CaptureFilter.ShouldStore(ProcessedCapture.ForText("see otpauth://totp/x in the docs")));
        Assert.True(CaptureFilter.ShouldStore(ProcessedCapture.ForFiles(["/tmp/otpauth.txt"])));
    }

    [Fact]
    public void DecodesAGeneratedQrCode()
    {
        var link = "otpauth://totp/GitHub:me%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub";
        var (pixels, width, height) = QrCodes.Render(link, scale: 4);
        Assert.Equal(link, QrCodes.FindOtpAuth(pixels, width, height));
        // On a larger, off-centre canvas too (a screenshot).
        int w = width + 100, h = height + 60;
        var canvas = Enumerable.Repeat((byte)255, w * h * 4).ToArray();
        for (var y = 0; y < height; y++) Array.Copy(pixels, y * width * 4, canvas, ((y + 30) * w + 70) * 4, width * 4);
        Assert.Equal(link, QrCodes.FindOtpAuth(canvas, w, h));
        // Something else, or nothing.
        var (other, ow, oh) = QrCodes.Render("https://example.com");
        Assert.Null(QrCodes.FindOtpAuth(other, ow, oh));
        Assert.Null(QrCodes.Decode(Enumerable.Repeat((byte)255, 40 * 40 * 4).ToArray(), 40, 40));
    }

    [Fact]
    public void BatchesCoverTheNext24Hours()
    {
        var a = new Authenticator("x", "A", "b", Base32.Encode(Sha1Key), OtpAlgorithm.SHA1, 6, 30, _now, _now);
        var (json, until) = OtpCodeBatch.Build(a, _now);
        var codes = (JsonArray)json["codes"]!;
        Assert.Equal(2880, codes.Count);
        var from = json["from"]!.GetValue<long>();
        Assert.Equal(new DateTimeOffset(_now).ToUnixTimeSeconds() / 30 * 30, from);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(from + 2880 * 30).UtcDateTime, until);
        var shared = OtpCodeBatch.Parse(json, "s", "o", "Owner", _now)!;
        foreach (var offset in new[] { 0, 29, 31, 3600, 86_000 })
            Assert.Equal(a.Code(_now.AddSeconds(offset)), shared.Code(_now.AddSeconds(offset)));
        Assert.Null(shared.Code(until.AddSeconds(1)));
        Assert.True(Encoding.UTF8.GetByteCount(json.ToJsonString()) < 64 * 1024);
    }

    [Fact]
    public void SealedCodesOpenOnlyForTheirRecipient()
    {
        var bob = SyncCrypto.GenerateKeyPair();
        var eve = SyncCrypto.GenerateKeyPair();
        var plaintext = Encoding.UTF8.GetBytes("{\"codes\":[\"123456\"]}");
        var sealedCodes = SyncCrypto.SealCodes(plaintext, "space-1", "bob", bob.Public);
        Assert.Equal(plaintext, SyncCrypto.OpenCodes(sealedCodes, "space-1", "bob", bob));
        Assert.ThrowsAny<System.Security.Cryptography.CryptographicException>(() => SyncCrypto.OpenCodes(sealedCodes, "space-1", "bob", eve));
        Assert.ThrowsAny<System.Security.Cryptography.CryptographicException>(() => SyncCrypto.OpenCodes(sealedCodes, "space-2", "bob", bob));
        Assert.ThrowsAny<System.Security.Cryptography.CryptographicException>(() => SyncCrypto.OpenCodes(sealedCodes, "space-1", "eve", bob));
    }

    [Fact]
    public void SharedRowsSayHowLongTheirCodesLast()
    {
        var from = new DateTimeOffset(_now).ToUnixTimeSeconds() / 30 * 30;
        var full = new SharedAuthenticator("s", "o", "Sam", "GitHub", "me", 6, 30, from, [.. Enumerable.Repeat("123456", 2880)], _now);
        Assert.Equal("Shared by Sam", full.Status(_now));
        Assert.Equal("123456", full.Code(_now));
        var low = full with { Codes = [.. Enumerable.Repeat("123456", 200)] };   // 100 minutes
        Assert.True(low.IsLow(_now));
        Assert.StartsWith("Codes until ", low.Status(_now));
        var empty = OtpCodeBatch.Empty("s", "o", "Sam", _now);
        Assert.True(empty.IsOut(_now));
        Assert.Equal("No codes, Sam's devices have been offline", empty.Status(_now));
        Assert.Equal("No codes, Sam's devices have been offline", full.Status(_now.AddDays(2)));
    }

    [Fact]
    public void StoreKeepsAuthenticatorsAndSharesProtected()
    {
        var backing = new MemoryProtectedStore();
        var store = new AuthenticatorStore(backing, () => _now);
        Assert.Null(store.Add("X", "y", "not base32!"));
        var a = store.Add(" GitHub ", "me", "jbsw y3dp ehpk 3pxp")!;
        Assert.Equal(("GitHub", "JBSWY3DPEHPK3PXP"), (a.Issuer, a.Secret));
        store.Put(a with { SpaceId = "space", Shares = [new OtpShare("u", "Sam", _now.AddHours(20))] });
        store.PutShared(OtpCodeBatch.Empty("other", "o", "Olga", _now));
        var reloaded = new AuthenticatorStore(backing);
        var back = Assert.Single(reloaded.All);
        Assert.Equal(("space", "Sam"), (back.SpaceId, back.People.Single().Name));
        Assert.Equal(a.Code(_now), back.Code(_now));
        Assert.Equal("Olga", Assert.Single(reloaded.Shared).OwnerName);
    }

    // MARK: Panel

    private sealed class FakeOtpSync : IAuthenticatorSync
    {
        public bool IsSignedIn { get; set; } = true;
        public string? Error => null;
        public List<string> Log { get; } = [];
        public List<(string Uid, string Name)> ShareCandidates(Authenticator a) => [("u2", "Zoe")];
        public Task<bool> ShareAsync(Authenticator a, string uid, string name) { Log.Add("share:" + uid); return Task.FromResult(true); }
        public Task<DateTime?> RemoveAsync(Authenticator a, string uid) { Log.Add("remove:" + uid); return Task.FromResult<DateTime?>(DateTime.UtcNow); }
        public Task<bool> TransferAsync(Authenticator a, string uid, string name) { Log.Add("transfer:" + uid); return Task.FromResult(true); }
        public Task<bool> LeaveAsync(SharedAuthenticator shared) { Log.Add("leave:" + shared.SpaceId); return Task.FromResult(true); }
        public Task<bool> DeleteAsync(Authenticator a) { Log.Add("delete:" + a.Id); return Task.FromResult(true); }
    }

    private (PanelModel Panel, AuthenticatorStore Store, FakeOtpSync Sync) Panel()
    {
        var otps = new AuthenticatorStore(new MemoryProtectedStore(), () => _now);
        var sync = new FakeOtpSync();
        var panel = new PanelModel(_store, _settings, new QuickSlots(_settings), new FakeVault(), _host)
        {
            Authenticators = otps, AuthenticatorSync = sync, Clock = () => _now, Delay = d => { _now += d; return Task.CompletedTask; },
        };
        panel.PrepareForOpen(null);
        return (panel, otps, sync);
    }

    private static List<string> Titles(List<PanelAction> actions) => [.. actions.Select(a => a.Title)];

    [Fact]
    public void SavedListsAuthenticatorsAndSearchFindsThem()
    {
        var (panel, otps, _) = Panel();
        var older = _store.Ingest(ProcessedCapture.ForText("older clip"), _now.AddMinutes(-5));
        _store.Pin(older);
        older.PinnedAt = _now.AddMinutes(-5);   // Pin stamps the real clock; this test runs on its own
        _store.Put(older);
        var a = otps.Add("GitHub", "me@example.com", "JBSWY3DPEHPK3PXP")!;
        panel.SetFilter(PanelFilter.Labelled);
        Assert.Equal(new PanelEntry.AuthenticatorEntry(a).Id, panel.Entries[0].Id);   // newest first
        panel.SetFilter(PanelFilter.All);
        Assert.DoesNotContain(panel.Entries, e => e is PanelEntry.AuthenticatorEntry);   // not in history
        panel.SetQuery("github");
        Assert.Contains(panel.Entries, e => e is PanelEntry.AuthenticatorEntry);
        panel.SetQuery("JBSW");   // never by secret
        Assert.DoesNotContain(panel.Entries, e => e is PanelEntry.AuthenticatorEntry);
    }

    [Fact]
    public async Task EnterPastesTheCodeAndWaitsForTheNextOneWhenItsAlmostOver()
    {
        var (panel, otps, _) = Panel();
        var a = otps.Add("GitHub", "me", "JBSWY3DPEHPK3PXP")!;
        panel.SetFilter(PanelFilter.Labelled);
        _now = new DateTime(2026, 11, 20, 12, 0, 10, DateTimeKind.Utc);
        await panel.PasteCodeAsync(panel.Entries[0]);
        Assert.Equal($"paste-text:{a.Code(_now)}:0", _host.Log[^1]);
        _now = new DateTime(2026, 11, 20, 12, 0, 28, 500, DateTimeKind.Utc);   // 1.5 s left
        var before = a.Code(_now);
        await panel.PasteCodeAsync(panel.Entries[0]);
        Assert.Equal($"paste-text:{a.Code(new DateTime(2026, 11, 20, 12, 0, 30, DateTimeKind.Utc))}:0", _host.Log[^1]);
        Assert.NotEqual($"paste-text:{before}:0", _host.Log[^1]);
    }

    [Fact]
    public void OwnerAndRecipientSeeOnlyWhatTheServerAllows()
    {
        var (panel, otps, sync) = Panel();
        var a = otps.Add("GitHub", "me", "JBSWY3DPEHPK3PXP")!;
        panel.SetFilter(PanelFilter.Labelled);
        panel.Select(new PanelEntry.AuthenticatorEntry(a).Id);
        // Not synced yet: no sharing.
        Assert.Equal(["Paste Code", "Copy Code", "Rename…", "Show Secret / QR", "Delete"], Titles(panel.AvailableActions));
        otps.Put(a with { SpaceId = "s1", Shares = [new OtpShare("u1", "Sam", _now.AddHours(20))] });
        panel.Refresh();
        Assert.Equal(["Paste Code", "Copy Code", "Rename…", "Share…", "People…", "Transfer Ownership…", "Show Secret / QR", "Delete"],
            Titles(panel.AvailableActions));
        sync.IsSignedIn = false;
        Assert.DoesNotContain("Share…", Titles(panel.AvailableActions));

        sync.IsSignedIn = true;
        var from = new DateTimeOffset(_now).ToUnixTimeSeconds() / 30 * 30;
        otps.PutShared(new SharedAuthenticator("s2", "o", "Olga", "Bank", "me", 6, 30, from, [.. Enumerable.Repeat("654321", 10)], _now.AddSeconds(1)));
        panel.Refresh();
        panel.Select("o-s2");
        Assert.Equal(["Paste Code", "Copy Code", "Leave"], Titles(panel.AvailableActions));
        Assert.Equal("654321", panel.CurrentCode(panel.SelectedEntry!));
        _now = _now.AddHours(1);   // ran out
        Assert.Equal(["Leave"], Titles(panel.AvailableActions));
        Assert.Contains("Olga's devices have been offline", panel.AuthenticatorSubtitle(panel.SelectedEntry!));
    }

    [Fact]
    public void SharePickerListsCandidatesAndDeleteNeedsAnInlineConfirm()
    {
        var (panel, otps, sync) = Panel();
        var a = otps.Add("GitHub", "me", "JBSWY3DPEHPK3PXP")!;
        otps.Put(a = a with { SpaceId = "s1" });
        panel.SetFilter(PanelFilter.Labelled);
        panel.Select(new PanelEntry.AuthenticatorEntry(a).Id);
        panel.Perform(new PanelAction.ShareAuthenticator());
        Assert.Equal(PanelModel.ShareNote, panel.OtpPickerNote);
        Assert.Equal(["Zoe"], Titles(panel.FilteredActions));
        panel.HandleKey(new KeyInput(PanelKey.Enter));
        Assert.Equal(["share:u2"], sync.Log);

        panel.HandleKey(new KeyInput(PanelKey.Delete));
        Assert.Equal(PanelMode.ConfirmDelete, panel.Mode);
        panel.HandleKey(new KeyInput(PanelKey.Escape));
        Assert.Equal(PanelMode.Browse, panel.Mode);
        Assert.Single(otps.All);
        panel.Perform(new PanelAction.DeleteAuthenticator());
        panel.HandleKey(new KeyInput(PanelKey.Enter));
        Assert.Equal("delete:" + a.Id, sync.Log[^1]);
    }

    [Fact]
    public void CopiedLinkIsOfferedAtTheTopOfAllUntilAddedOrDismissed()
    {
        var (panel, otps, _) = Panel();
        _store.Ingest(ProcessedCapture.ForText("a clip"));
        var draft = OtpAuthUri.Parse("otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP", out _)!;
        panel.OfferAuthenticator(draft);
        Assert.IsType<PanelEntry.OtpSuggestion>(panel.Entries[0]);
        panel.HandleKey(new KeyInput(PanelKey.Escape));
        Assert.DoesNotContain(panel.Entries, e => e is PanelEntry.OtpSuggestion);
        Assert.DoesNotContain("close", _host.Log);

        panel.OfferAuthenticator(draft);
        panel.HandleKey(new KeyInput(PanelKey.Enter));   // the suggestion is selected first
        Assert.Equal(PanelMode.AuthenticatorForm, panel.Mode);
        Assert.True(panel.AuthenticatorForm!.SecretFromLink);
        Assert.True(panel.AuthenticatorForm.ShowTip);
        panel.HandleKey(new KeyInput(PanelKey.Enter));
        Assert.Equal("GitHub", Assert.Single(otps.All).Issuer);
        Assert.Null(panel.PendingOtp);
        Assert.True(_settings.AuthenticatorTipShown);
    }

    [Fact]
    public void ManualAddRejectsABadSecret()
    {
        var (panel, otps, _) = Panel();
        panel.BeginAddAuthenticator();
        panel.AuthenticatorForm!.Issuer = "Site";
        panel.AuthenticatorForm.Secret = "hello world!";
        panel.SubmitAuthenticatorForm();
        Assert.NotNull(panel.AuthenticatorForm?.Error);
        Assert.Empty(otps.All);
        panel.AuthenticatorForm!.Secret = "jbsw y3dp ehpk 3pxp";
        panel.SubmitAuthenticatorForm();
        Assert.Single(otps.All);
    }

    // MARK: Backup

    [Fact]
    public void BackupCarriesOwnAuthenticatorsOnlyWithSecrets()
    {
        var otps = new AuthenticatorStore(new MemoryProtectedStore(), () => _now);
        var a = otps.Add("GitHub", "me", "JBSWY3DPEHPK3PXP", OtpAlgorithm.SHA256, 8, 60)!;
        otps.PutShared(OtpCodeBatch.Empty("s", "o", "Olga", _now));
        var source = Backup.Snapshot(_store) with { Authenticators = otps.All };
        var without = Backup.Create(source, secrets: null);
        Assert.Null(without["authenticators"]);
        var root = Backup.Create(source, secrets: []);
        var entry = Assert.Single((JsonArray)root["authenticators"]!)!.AsObject();
        Assert.Equal(("otp", a.Id, "JBSWY3DPEHPK3PXP"), (entry["type"]!.GetValue<string>(), entry["id"]!.GetValue<string>(), entry["secret"]!.GetValue<string>()));
        Assert.Equal(1, Backup.Summarize(root).Authenticators);

        var target = new AuthenticatorStore(new MemoryProtectedStore());
        var result = Backup.Merge(root, _store, new FakeVault(), target);
        Assert.Equal(1, result.Authenticators);
        var imported = Assert.Single(target.All);
        Assert.Equal((OtpAlgorithm.SHA256, 8, 60, (string?)null), (imported.Algorithm, imported.Digits, imported.Period, imported.SpaceId));
        Assert.Equal(a.Code(_now), imported.Code(_now));
        // Again: identical (issuer, account, secret) is skipped.
        var again = Backup.Merge(root, _store, new FakeVault(), target);
        Assert.Equal(0, again.Authenticators);
        Assert.Single(target.All);
        // Without secrets, nothing.
        Backup.Merge(root, _store, null, new AuthenticatorStore(new MemoryProtectedStore()));
    }
}
