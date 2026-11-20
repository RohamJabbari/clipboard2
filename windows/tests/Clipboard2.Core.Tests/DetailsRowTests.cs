namespace Clipboard2.Core.Tests;

/// <summary>The details' Label and Folder rows, Ctrl+L / Ctrl+Shift+M and Saved's Add Items picker.</summary>
public sealed class DetailsRowTests : IDisposable
{
    private readonly ClipStore _store = new(":memory:", new BlobStore(Path.Combine(Path.GetTempPath(), "c2details-" + Guid.NewGuid())));
    private readonly Settings _settings = new();
    private readonly FakeVault _vault = new();
    private readonly FakeHost _host = new();
    private readonly PanelModel _model;

    public DetailsRowTests()
    {
        _model = new PanelModel(_store, _settings, new QuickSlots(_settings), _vault, _host) { Self = () => new SyncSelf("me", "me") };
    }

    public void Dispose() => _store.Dispose();

    private ClipItem Add(string text, int age = 0, string? space = null) =>
        _store.Ingest(ProcessedCapture.ForText(text), DateTime.UtcNow.AddSeconds(-age), space);

    private static KeyInput Ctrl(char letter, bool shift = false) =>
        new(PanelKey.Letter, KeyMods.Ctrl | (shift ? KeyMods.Shift : KeyMods.None), Letter: letter);

    [Fact]
    public void CtrlLLabelsOneOrSeveralItems()
    {
        var a = Add("alpha", 2);
        var b = Add("beta", 1);
        _model.PrepareForOpen(null);
        Assert.True(_model.CanLabel(_model.Entries[0]));
        Assert.Null(PanelModel.LabelText(_model.Entries[0]));
        _model.HandleKey(Ctrl('l'));
        Assert.Equal(PanelMode.Label, _model.Mode);
        _model.LabelForm!.Text = "Greek";
        _model.HandleKey(new KeyInput(PanelKey.Enter));
        Assert.Equal("Greek", _store.Find(b.Id)!.Label);

        _model.SelectAll();
        _model.HandleKey(Ctrl('l'));
        Assert.Equal(2, _model.LabelForm!.Count);
        _model.LabelForm.Text = "Both";
        _model.SubmitLabel();
        Assert.Equal("Both", _store.Find(a.Id)!.Label);
        Assert.Equal("Both", _store.Find(b.Id)!.Label);
        Assert.Equal("Labelled 2 items", _model.Notice);
        Assert.Equal("Ctrl+L", new PanelAction.SetLabel().Shortcut);
    }

    [Fact]
    public void LabelAndFolderRowsAreHiddenWhereChangesArentAllowed()
    {
        _store.SaveSyncSpaces([new SpaceRecord("g1", "group", "member", "Team", "owner", 2), new SpaceRecord("d1", "direct", "member", "Sam", "sam", 2)]);
        var theirs = Add("their note", 0, "g1");
        _store.SaveSyncMeta(new SyncMeta("g1", ClipStore.SyncId(theirs.Id), "history", "x", 1, 1, AuthorUid: "someone"));
        var received = Add("from sam", 0, "d1");
        _store.SaveSyncMeta(new SyncMeta("d1", ClipStore.SyncId(received.Id), "history", "x", 1, 1, AuthorUid: "sam"));
        var mine = Add("my note", 0, "g1");
        _model.PrepareForOpen(null);
        _model.SetGroupFilter("g1");
        Assert.False(_model.CanLabel(new PanelEntry.Clip(theirs)));
        Assert.True(_model.CanLabel(new PanelEntry.Clip(mine)));
        _model.Select(new PanelEntry.Clip(theirs).Id);
        _model.HandleKey(Ctrl('l'));
        Assert.Equal(PanelMode.Browse, _model.Mode);

        _model.SetFilter(PanelFilter.Inbox);
        var inbox = Assert.Single(_model.Entries);
        Assert.False(_model.CanLabel(inbox));
        _model.Select(inbox.Id);
        Assert.False(_model.CanMoveSelection);
    }

    [Fact]
    public void FolderRowShowsThePathAndCtrlShiftMOpensThePicker()
    {
        var work = _store.CreateFolder("Work");
        var clients = _store.CreateFolder("Clients", null, work.Id);
        var item = Add("deal");
        _store.MoveToFolder([item], clients);
        var loose = Add("loose");
        _model.PrepareForOpen(null);
        _model.Select(new PanelEntry.Clip(_store.Find(item.Id)!).Id);
        Assert.Equal("Saved › Work › Clients", _model.FolderLocation(_model.SelectedEntry!));
        _model.Select(new PanelEntry.Clip(loose).Id);
        Assert.Null(_model.FolderLocation(_model.SelectedEntry!));
        Assert.True(_model.CanMoveSelection);

        _model.HandleKey(Ctrl('m', shift: true));
        Assert.True(_model.IsPickingFolder);
        var titles = _model.FilteredActions.Select(a => a.Title).ToList();
        Assert.Contains("Work › Clients", titles);
        Assert.Contains("New Folder in Work › Clients…", titles);
        // New Folder… at a chosen level: created there, and the item moves in.
        _model.Perform(_model.FilteredActions.OfType<PanelAction.MoveToNewFolder>().Single(n => n.ParentId == work.Id));
        _model.FolderForm!.Text = "Leads";
        _model.SubmitFolderName();
        var leads = _store.FolderTree(null).Children(work.Id, null).Single(f => f.Name == "Leads");
        Assert.Equal(leads.Id, _store.Find(loose.Id)!.FolderId);
        Assert.True(_store.Find(loose.Id)!.IsPinned);

        // In a folder: the picker starts with Top Level.
        _model.Select(new PanelEntry.Clip(_store.Find(loose.Id)!).Id);
        _model.BeginMoveSelection();
        Assert.IsType<PanelAction.RemoveFromFolder>(_model.FilteredActions[0]);
    }

    [Fact]
    public void AddItemsSavesCheckedClipsIntoTheOpenFolder()
    {
        var work = _store.CreateFolder("Work");
        var a = Add("alpha", 3);
        var b = Add("beta", 2);
        var saved = Add("kept", 1);
        _store.Pin(saved);
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        _model.OpenFolderById(work.Id);
        _model.BeginAddItems();
        Assert.Equal(PanelMode.AddItems, _model.Mode);
        Assert.Equal(["beta", "alpha"], _model.AddItemsForm!.Candidates.Select(c => c.Text));   // unsaved, newest first
        _model.HandleKey(new KeyInput(PanelKey.Space));
        _model.HandleKey(new KeyInput(PanelKey.Down));
        _model.HandleKey(new KeyInput(PanelKey.Space));
        _model.HandleKey(new KeyInput(PanelKey.Enter));
        Assert.Equal("Added 2 items to Work", _model.Notice);
        Assert.All(new[] { a, b }, i => Assert.Equal((true, (Guid?)work.Id), (_store.Find(i.Id)!.IsPinned, _store.Find(i.Id)!.FolderId)));

        // Search, Esc cancels without adding.
        var c = Add("gamma");
        _model.GoToFolder(null);
        _model.BeginAddItems();
        _model.SetAddItemsQuery("gam");
        Assert.Equal(["gamma"], _model.AddItemsForm!.Candidates.Select(x => x.Text));
        _model.HandleKey(new KeyInput(PanelKey.Escape));
        Assert.Equal(PanelMode.Browse, _model.Mode);
        Assert.False(_store.Find(c.Id)!.IsPinned);
        // At Saved's root, Enter with nothing checked adds the highlighted one.
        _model.BeginAddItems();
        _model.HandleKey(new KeyInput(PanelKey.Enter));
        Assert.Equal("Added 1 item to Saved", _model.Notice);
        Assert.Null(_store.Find(c.Id)!.FolderId);
    }

    [Fact]
    public void AddItemsLeavesOutOtherMembersGroupItems()
    {
        _store.SaveSyncSpaces([new SpaceRecord("g1", "group", "member", "Team", "owner", 2)]);
        var theirs = Add("theirs", 1, "g1");
        _store.SaveSyncMeta(new SyncMeta("g1", ClipStore.SyncId(theirs.Id), "history", "x", 1, 1, AuthorUid: "someone"));
        Add("mine", 0, "g1");
        _model.PrepareForOpen(null);
        _model.SetGroupFilter("g1");
        _model.SetGroupShowsSaved(true);
        _model.BeginAddItems();
        Assert.Equal(["mine"], _model.AddItemsForm!.Candidates.Select(c => c.Text));
    }
}
