using System.Text.Json.Nodes;
using Clipboard2.Core.Sync;

namespace Clipboard2.Core.Tests;

/// <summary>Folders in folders (docs/features/nested-folders.md).</summary>
public sealed class NestedFolderTests : IDisposable
{
    private readonly ClipStore _store = new(":memory:", new BlobStore(Path.Combine(Path.GetTempPath(), "c2nest-" + Guid.NewGuid())));
    private readonly Settings _settings = new();
    private readonly FakeVault _vault = new();
    private readonly FakeHost _host = new();
    private readonly PanelModel _model;

    public NestedFolderTests()
    {
        _model = new PanelModel(_store, _settings, new QuickSlots(_settings), _vault, _host);
    }

    public void Dispose() => _store.Dispose();

    private ClipItem Saved(string text, ClipFolder? folder = null)
    {
        var item = _store.Ingest(ProcessedCapture.ForText(text));
        _store.Pin(item);
        if (folder is not null) _store.MoveToFolder([item], folder);
        return item;
    }

    private static ClipFolder F(string name, ClipFolder? parent = null, string? space = null, Guid? id = null) =>
        new() { Id = id ?? Guid.NewGuid(), Name = name, ParentId = parent?.Id, SpaceId = space };

    [Fact]
    public void CyclesUnknownParentsAndTooDeepReadAsTopLevel()
    {
        var a = F("A");
        var b = F("B", a);
        var c = F("C", b);
        a.ParentId = c.Id;   // A → C → B → A
        var orphan = F("Orphan");
        orphan.ParentId = Guid.NewGuid();
        var other = F("Other", space: "group");
        var crossSpace = F("Cross", other);
        var chain = new List<ClipFolder> { F("L1") };
        for (var i = 2; i <= 10; i++) chain.Add(F("L" + i, chain[^1]));
        var tree = new FolderTree([a, b, c, orphan, other, crossSpace, .. chain]);

        Assert.All(new[] { a, b, c }, f => Assert.Null(tree.ParentOf(f.Id)));
        Assert.Null(tree.ParentOf(orphan.Id));
        Assert.Null(tree.ParentOf(crossSpace.Id));
        Assert.Equal(8, tree.Depth(chain[7].Id));
        Assert.Equal(chain[6].Id, tree.ParentOf(chain[7].Id));
        Assert.Null(tree.ParentOf(chain[8].Id));   // the 9th level reads as top level
        Assert.Equal("L1 › L2 › L3", tree.PathText(chain[2].Id));
        Assert.Equal("L2 › L3", tree.PathText(chain[2].Id, chain[0].Id));
    }

    [Fact]
    public void MovesNeverGoIntoThemselvesOrTooDeep()
    {
        var work = _store.CreateFolder("Work");
        var clients = _store.CreateFolder("Clients", null, work.Id);
        var acme = _store.CreateFolder("Acme", null, clients.Id);
        var home = _store.CreateFolder("Home");
        var tree = _store.FolderTree(null);
        Assert.False(tree.CanMove(work, work));
        Assert.False(tree.CanMove(work, acme));
        Assert.True(tree.CanMove(acme, home));
        Assert.False(_store.MoveFolder(work, clients));
        Assert.True(_store.MoveFolder(clients, home));
        Assert.Equal("Home › Clients › Acme", _store.FolderTree(null).PathText(acme.Id));

        // Depth: a chain of 6 under Home (depth 1) fits; under a folder at depth 3 it wouldn't.
        var chain = new List<ClipFolder> { _store.CreateFolder("C1") };
        for (var i = 2; i <= 6; i++) chain.Add(_store.CreateFolder("C" + i, null, chain[^1].Id));
        Assert.True(_store.FolderTree(null).CanMove(chain[0], home));
        Assert.False(_store.FolderTree(null).CanMove(chain[0], acme));

        _model.SetFilter(PanelFilter.Labelled);
        Assert.False(_model.CanDrop("f-" + home.Id, clients.Id));   // into its own child
        Assert.True(_model.CanDrop("f-" + work.Id, home.Id));
        Assert.False(_model.CanDrop("f-" + work.Id, null));   // already top level
    }

    [Fact]
    public void BrowsingShowsSubfoldersFirstAndEscGoesUpOneLevel()
    {
        var work = _store.CreateFolder("Work");
        var clients = _store.CreateFolder("Clients", null, work.Id);
        Saved("in work", work);
        var deep = Saved("in clients", clients);
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        var row = Assert.IsType<PanelEntry.FolderEntry>(Assert.Single(_model.Entries));
        Assert.Equal((1, 1), (row.Folders, row.Count));
        _model.OpenFolderById(work.Id);
        Assert.Equal("f-" + clients.Id, _model.Entries[0].Id);
        Assert.Equal(2, _model.Entries.Count);
        _model.OpenFolderById(clients.Id);
        Assert.Equal(["Work", "Clients"], _model.OpenFolderPath.Select(f => f.Name));
        _model.HandleKey(new KeyInput(PanelKey.Escape));
        Assert.Equal(work.Id, _model.OpenFolderId);
        Assert.Equal("f-" + clients.Id, _model.SelectedId);

        // A search inside Work covers Clients too, with the path relative to Work.
        _model.SetQuery("in clients");
        Assert.Equal("Clients", _model.FolderCaption(new PanelEntry.Clip(deep)));
        _model.SetQuery("");

        // New Folder inside an open folder makes a subfolder there.
        _model.CreateFolder();
        _model.SubmitFolderName();
        Assert.Equal(2, _store.FolderTree(null).Children(work.Id, null).Count);
        _model.HandleKey(new KeyInput(PanelKey.Backspace));
        Assert.Null(_model.OpenFolderId);
    }

    [Fact]
    public void DeletingAFolderMovesItsItemsAndSubfoldersToItsParent()
    {
        var work = _store.CreateFolder("Work");
        var clients = _store.CreateFolder("Clients", null, work.Id);
        var acme = _store.CreateFolder("Acme", null, clients.Id);
        var item = Saved("deal", clients);
        var secret = _vault.Add("pin", "1234")!;
        _store.SetSecretFolder(secret.Id, clients.Id);
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        _model.OpenFolderById(work.Id);
        _model.DeleteFolder(clients);
        Assert.Equal("Folder deleted · moved 3 items to Work", _model.Notice);
        Assert.Equal(work.Id, _store.Find(item.Id)!.FolderId);
        Assert.Equal(work.Id, _store.SecretFolderId(secret.Id));
        Assert.Equal(work.Id, _store.FolderTree(null).ParentOf(acme.Id));
        Assert.True(_store.Find(item.Id)!.IsPinned);
    }

    [Fact]
    public void FoldersMoveByActionAndToTopLevel()
    {
        var work = _store.CreateFolder("Work");
        var home = _store.CreateFolder("Home");
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        _model.Select("f-" + home.Id);
        Assert.Contains(new PanelAction.MoveToFolder(), _model.AvailableActions);
        Assert.DoesNotContain(new PanelAction.RemoveFromFolder(), _model.AvailableActions);
        _model.Perform(new PanelAction.MoveToFolder());
        Assert.Equal(["Work"], _model.FilteredActions.OfType<PanelAction.MoveTo>().Select(m => m.FolderName));
        _model.Perform(_model.FilteredActions.OfType<PanelAction.MoveTo>().Single());
        Assert.Equal(work.Id, _store.FolderTree(null).ParentOf(home.Id));
        _model.OpenFolderById(work.Id);
        _model.Select("f-" + home.Id);
        Assert.Equal("Move to Top Level", Assert.Single(_model.AvailableActions.OfType<PanelAction.RemoveFromFolder>()).Title);
        _model.Perform(new PanelAction.RemoveFromFolder());
        Assert.Null(_store.FolderTree(null).ParentOf(home.Id));
        // Work can't go into a folder of its own subtree: only Home is offered, and only while Home isn't under it.
        _model.GoToFolder(null);
        _model.DropOnFolder("f-" + home.Id, work.Id);
        Assert.Equal(work.Id, _store.FolderTree(null).ParentOf(home.Id));
    }

    [Fact]
    public void SharingAFolderCopiesItsSubtree()
    {
        var work = _store.CreateFolder("Work");
        var clients = _store.CreateFolder("Clients", null, work.Id);
        Saved("top", work);
        Saved("deep", clients);
        var secret = _vault.Add("pin", "1234")!;
        _store.SetSecretFolder(secret.Id, clients.Id);
        _store.SaveSyncSpaces([new SpaceRecord("g1", "group", "owner", "Team", "me", 2)]);
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        _model.Select("f-" + work.Id);
        _model.ShareSelection("g1", "Team", null);
        var tree = _store.FolderTree("g1");
        var groupWork = Assert.Single(tree.Children(null, "g1"));
        var groupClients = Assert.Single(tree.Children(groupWork.Id, "g1"));
        Assert.NotEqual(work.Id, groupWork.Id);
        Assert.Equal("Clients", groupClients.Name);
        Assert.Equal(["deep"], _store.ItemsInSpace("g1").Where(i => i.FolderId == groupClients.Id).Select(i => i.Text));
        Assert.Contains(_host.Log, l => l.StartsWith("copy-secrets:pin:g1:" + groupClients.Id));
    }

    [Fact]
    public void ParentTravelsInTheFolderPayload()
    {
        var parent = F("Work");
        var child = F("Clients", parent);
        var json = SyncPayload.ForFolder(child);
        Assert.Equal(ClipStore.SyncId(parent.Id), json["parent"]!.GetValue<string>());
        Assert.Null(SyncPayload.ForFolder(parent)["parent"]);
        var flat = new ClipFolder { Id = child.Id, Name = child.Name, CreatedAt = child.CreatedAt, UpdatedAt = child.UpdatedAt };
        Assert.NotEqual(SyncPayload.Fingerprint(json), SyncPayload.Fingerprint(SyncPayload.ForFolder(flat)));
        var parsed = Assert.IsType<ItemPayload.FolderPayload>(SyncPayload.Parse(System.Text.Encoding.UTF8.GetBytes(json.ToJsonString()), child.Id, null));
        Assert.Equal(parent.Id, parsed.Folder.ParentId);
    }

    [Fact]
    public void BackupKeepsTheTreeAndJoinsByNameWithinTheSameParent()
    {
        var work = _store.CreateFolder("Work");
        var clients = _store.CreateFolder("Clients", null, work.Id);
        var home = _store.CreateFolder("Home");
        _store.CreateFolder("Clients", null, home.Id);
        Saved("deal", clients);
        var root = Backup.Create(_store, null);
        var entries = ((JsonArray)root["folders"]!).Select(n => n!.AsObject()).ToList();
        Assert.Equal(ClipStore.SyncId(work.Id), entries.Single(e => e["id"]!.GetValue<string>() == ClipStore.SyncId(clients.Id))["parent"]!.GetValue<string>());

        using var target = new ClipStore(":memory:", new BlobStore(Path.Combine(Path.GetTempPath(), "c2nest-" + Guid.NewGuid())));
        var existingWork = target.CreateFolder("work");
        target.CreateFolder("Clients");   // top-level: must not absorb Work › Clients
        Backup.Merge(Backup.Parse(System.Text.Encoding.UTF8.GetBytes(root.ToJsonString())), target, null);
        var tree = target.FolderTree(null);
        var importedClients = Assert.Single(tree.Children(existingWork.Id, null));
        Assert.Equal("Clients", importedClients.Name);
        Assert.Equal(3, tree.Children(null, null).Count);   // work, Clients, Home
        Assert.Single(tree.Children(tree.Children(null, null).Single(f => f.Name == "Home").Id, null));
        Assert.Equal(importedClients.Id, target.ItemsInSpace(null).Single().FolderId);
    }
}
