using Clipboard2.Core;
using Clipboard2.Core.AI;

namespace Clipboard2.Core.Tests;

internal sealed class FakeVault : ISecretVault
{
    private readonly List<SecretRef> _secrets = [];
    private readonly Dictionary<string, string> _values = [];
    public IReadOnlyList<SecretRef> Secrets => _secrets;
    public IReadOnlySet<string> ValueHashes => _values.Values.Select(ContentHasher.HashText).ToHashSet();
    public event Action? Changed;
    public SecretRef? Add(string name, string value)
    {
        var s = new SecretRef(Guid.NewGuid().ToString(), name, DateTime.UtcNow);
        _secrets.Add(s);
        _values[s.Id] = value;
        Changed?.Invoke();
        return s;
    }
    public void Rename(SecretRef secret, string name) { _secrets[_secrets.FindIndex(s => s.Id == secret.Id)] = secret with { Name = name }; }
    public void SetValue(SecretRef secret, string value) => _values[secret.Id] = value;
    public void Delete(SecretRef secret) { _secrets.RemoveAll(s => s.Id == secret.Id); _values.Remove(secret.Id); }
    public string? Value(string id) => _values.GetValueOrDefault(id);
}

internal sealed class FakeHost : IPanelHost
{
    public List<string> Log { get; } = [];
    public bool AIReady { get; set; }
    public void ClosePanel() => Log.Add("close");
    public void Paste(ClipItem item, Transform? transform) => Log.Add($"paste:{item.Text}:{transform}");
    public void Paste(IReadOnlyList<ClipItem> items, Transform? transform) => Log.Add($"paste-many:{items.Count}");
    public void PasteText(string text, int cursorOffsetFromEnd = 0) => Log.Add($"paste-text:{text}:{cursorOffsetFromEnd}");
    public void Copy(ClipItem item) => Log.Add($"copy:{item.Text}");
    public void Copy(IReadOnlyList<ClipItem> items) => Log.Add($"copy-many:{items.Count}");
    public void CopyText(string text) => Log.Add($"copy-text:{text}");
    public void PasteSecret(SecretRef secret) => Log.Add($"paste-secret:{secret.Name}");
    public void CopySecret(SecretRef secret) => Log.Add($"copy-secret:{secret.Name}");
    public string? CurrentClipboardText() => "CLIP";
    public void OpenSettings() => Log.Add("settings");
    public IAIStreamingClient MakeAIClient() => throw new AIException(AIErrorKind.NotSignedIn, "not signed in");
    public string AIProviderTitle => "Test";
    public bool IsAIReady => AIReady;
    public string AIShortName => "Claude";
}

public sealed class PanelTests : IDisposable
{
    private readonly ClipStore _store = new(":memory:", new BlobStore(Path.Combine(Path.GetTempPath(), "c2panel-" + Guid.NewGuid())));
    private readonly Settings _settings = new();
    private readonly FakeVault _vault = new();
    private readonly FakeHost _host = new();
    private readonly PanelModel _model;

    public PanelTests()
    {
        _model = new PanelModel(_store, _settings, new QuickSlots(_settings), _vault, _host);
    }

    public void Dispose() => _store.Dispose();

    private ClipItem Add(string text, int ageSeconds = 0) =>
        _store.Ingest(ProcessedCapture.ForText(text), DateTime.UtcNow.AddSeconds(-ageSeconds));

    private static KeyInput K(PanelKey key, KeyMods mods = KeyMods.None, int digit = 0, char letter = '\0') => new(key, mods, digit, letter);

    [Fact]
    public void OpeningSelectsNewestEvenAfterMovingAndLateCopies()
    {
        Add("older", 10);
        Add("newer");
        _model.PrepareForOpen(null);
        _model.MoveSelection(1);
        _model.PrepareForOpen(null);
        Assert.Equal(_model.Entries[0].Id, _model.SelectedId);
        var late = Add("late");
        _model.Refresh();
        Assert.Equal(new PanelEntry.Clip(late).Id, _model.SelectedId);
    }

    [Fact]
    public void EnterPastesShiftEnterPastesPlain()
    {
        Add("hello");
        _model.PrepareForOpen(null);
        _model.HandleKey(K(PanelKey.Enter));
        _model.HandleKey(K(PanelKey.Enter, KeyMods.Shift));
        Assert.Contains("paste:hello:", _host.Log);
        Assert.Contains("paste:hello:PlainText", _host.Log);
    }

    [Fact]
    public void TabCyclesFilters()
    {
        _model.PrepareForOpen(null);
        _model.HandleKey(K(PanelKey.Tab));
        Assert.Equal(PanelFilter.Pinned, _model.Filter);
        _model.HandleKey(K(PanelKey.Tab, KeyMods.Shift));
        _model.HandleKey(K(PanelKey.Tab, KeyMods.Shift));
        Assert.Equal(PanelFilter.ThisApp, _model.Filter);
    }

    [Fact]
    public void DeleteEditsTextWhileSearching()
    {
        Add("keep me");
        _model.PrepareForOpen(null);
        _model.SetQuery("keep");
        Assert.False(_model.HandleKey(K(PanelKey.Delete, KeyMods.Ctrl)));
        Assert.Equal(1, _store.Count());
        _model.SetQuery("");
        Assert.True(_model.HandleKey(K(PanelKey.Delete)));
        Assert.Equal(0, _store.Count());
    }

    [Fact]
    public void MultiSelectWithShiftArrowsAndCtrlClick()
    {
        Add("a", 3); Add("b", 2); Add("c", 1); Add("d");
        _model.PrepareForOpen(null);
        _model.HandleKey(K(PanelKey.Down, KeyMods.Shift));
        _model.HandleKey(K(PanelKey.Down, KeyMods.Shift));
        Assert.Equal(3, _model.SelectedIds.Count);
        _model.HandleKey(K(PanelKey.Up));
        Assert.Single(_model.SelectedIds);
        _model.Click(_model.Entries[0], ctrl: false, shift: false);
        _model.Click(_model.Entries[2], ctrl: true, shift: false);
        Assert.Equal(2, _model.SelectedClips.Count);
        _model.HandleKey(K(PanelKey.Enter));
        Assert.Contains("paste-many:2", _host.Log);
    }

    [Fact]
    public void QuickSlotsBindAndPinAndFallBackToRows()
    {
        Add("first", 1);
        Add("second");
        _model.PrepareForOpen(null);
        _model.MoveSelection(1);                                   // "first"
        _model.HandleKey(K(PanelKey.Digit, KeyMods.Ctrl | KeyMods.Shift, digit: 3));
        Assert.True(_store.AllItems().Single(i => i.Text == "first").IsPinned);
        _model.HandleKey(K(PanelKey.Digit, KeyMods.Ctrl, digit: 3));
        Assert.Contains("paste:first:", _host.Log);
        _host.Log.Clear();
        _model.HandleKey(K(PanelKey.Digit, KeyMods.Ctrl, digit: 1));   // empty slot → row 1
        Assert.Single(_host.Log, l => l.StartsWith("paste:"));
    }

    [Fact]
    public void ActionsOfferSetUpAIWhenNotConfigured()
    {
        Add("text item");
        _model.PrepareForOpen(null);
        _model.OpenActions();
        Assert.Contains(new PanelAction.SetUpAI(), _model.AvailableActions);
        Assert.DoesNotContain(new PanelAction.Ask(new AIAction.Summarize()), _model.AvailableActions);
        _model.SetActionQuery("make it a haiku");
        Assert.Equal([new PanelAction.SetUpAI()], _model.FilteredActions);
        Assert.Equal("AI", _model.AIName);
    }

    [Fact]
    public void TypedTextBecomesAnInstructionWhenAIReady()
    {
        _host.AIReady = true;
        Add("text item");
        _model.PrepareForOpen(null);
        _model.OpenActions();
        _model.SetActionQuery("zzqxj");
        Assert.Equal([new PanelAction.Ask(new AIAction.Instruction("zzqxj"))], _model.FilteredActions);
    }

    [Fact]
    public void TransformPastesResultAndReportsInvalid()
    {
        Add("{\"a\":1}");
        _model.PrepareForOpen(null);
        _model.Perform(new PanelAction.ApplyTransform(Transform.JsonPrettify));
        Assert.Contains("paste-text:{\n  \"a\": 1\n}:0", _host.Log);
        Add("not json");
        _model.PrepareForOpen(null);
        _model.Perform(new PanelAction.ApplyTransform(Transform.JsonMinify));
        Assert.StartsWith("Can't apply", _model.Notice);
    }

    [Fact]
    public void SnippetWithFieldsOpensFormThenPastesExpansion()
    {
        _store.CreateSnippet("greet", ";hi", "Hi {name}, clip={clipboard}{cursor}!");
        _model.PrepareForOpen(null);
        _model.SetQuery(";hi");
        _model.Activate(_model.SelectedEntry);
        Assert.Equal(PanelMode.SnippetForm, _model.Mode);
        _model.SnippetForm!.Values["name"] = "Ana";
        _model.HandleKey(K(PanelKey.Enter));
        Assert.Contains("paste-text:Hi Ana, clip=CLIP!:1", _host.Log);
    }

    [Fact]
    public void SaveAsSecretMovesItemOutOfHistory()
    {
        var item = Add("hunter2");
        _model.PrepareForOpen(null);
        _model.BeginSaveSecret(item);
        _model.SaveSecretForm!.Name = "DB";
        _model.HandleKey(K(PanelKey.Enter));
        Assert.Equal(0, _store.Count());
        Assert.Equal("DB", Assert.Single(_vault.Secrets).Name);
    }

    [Fact]
    public void SecretsSearchByNameAndNeverDeleteOnPlainDelete()
    {
        _vault.Add("Prod DB password", "x");
        _model.PrepareForOpen(null);
        _model.SetQuery("prod db");
        Assert.IsType<PanelEntry.SecretEntry>(_model.SelectedEntry);
        _model.DeleteSelection();
        Assert.Single(_vault.Secrets);
        _model.Activate(_model.SelectedEntry);
        Assert.Contains("paste-secret:Prod DB password", _host.Log);
    }

    [Fact]
    public void SelectionModeIsTransient()
    {
        _model.PrepareForSelection("selected words", null);
        Assert.Equal(PanelMode.Actions, _model.Mode);
        Assert.DoesNotContain(new PanelAction.Delete(), _model.AvailableActions);
        Assert.Equal(0, _store.Count());
        _model.HandleKey(K(PanelKey.Escape));
        Assert.Contains("close", _host.Log);
    }
}
