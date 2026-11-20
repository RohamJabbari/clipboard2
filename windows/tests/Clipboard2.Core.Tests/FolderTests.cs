using System.Text;
using System.Text.Json.Nodes;
using Clipboard2.Core.Sync;

namespace Clipboard2.Core.Tests;

/// <summary>Saved, folders and group Saved (docs/features/folders.md): the store and the panel.</summary>
public sealed class FolderTests : IDisposable
{
    private readonly ClipStore _store = new(":memory:", new BlobStore(Path.Combine(Path.GetTempPath(), "c2folders-" + Guid.NewGuid())));
    private readonly Settings _settings = new();
    private readonly FakeVault _vault = new();
    private readonly FakeHost _host = new();
    private readonly PanelModel _model;

    /// <summary>The folder picker without its "New Folder in ‹folder›…" rows (nested-folders.md).</summary>
    private List<PanelAction> Picks() => [.. _model.FilteredActions.Where(a => a is not PanelAction.MoveToNewFolder { ParentId: not null })];

    public FolderTests()
    {
        _model = new PanelModel(_store, _settings, new QuickSlots(_settings), _vault, _host);
    }

    public void Dispose() => _store.Dispose();

    private ClipItem Add(string text, int ageSeconds = 0, string? space = null) =>
        _store.Ingest(ProcessedCapture.ForText(text), DateTime.UtcNow.AddSeconds(-ageSeconds), space);

    private static KeyInput K(PanelKey key, KeyMods mods = KeyMods.None) => new(key, mods);

    private ClipItem Fresh(ClipItem item) => _store.Find(item.Id)!;

    private List<string> Titles() => [.. _model.Entries.Select(e => e switch
    {
        PanelEntry.FolderEntry f => $"[{f.Folder.Name} {f.Count}]",
        _ => e.ClipItem!.DisplayTitle,
    })];

    private void SelectClips(params ClipItem[] items)
    {
        _model.Select(new PanelEntry.Clip(items[0]).Id);
        foreach (var item in items.Skip(1)) _model.ToggleSelection(new PanelEntry.Clip(item).Id);
    }

    [Fact]
    public void MovingInSavesAndMovingOutLeavesItSaved()
    {
        var item = Add("note");
        var folder = _store.CreateFolder("Work");
        _model.PrepareForOpen(null);
        _model.Select(new PanelEntry.Clip(item).Id);
        Assert.Contains(new PanelAction.AddToSaved(), _model.AvailableActions);
        Assert.DoesNotContain(new PanelAction.RemoveFromFolder(), _model.AvailableActions);

        _model.Perform(new PanelAction.MoveToFolder());
        Assert.True(_model.IsPickingFolder);
        Assert.Equal([new PanelAction.MoveTo(folder.Id, "Work"), new PanelAction.MoveToNewFolder()], Picks());
        _model.Perform(new PanelAction.MoveTo(folder.Id, "Work"));
        Assert.Equal((true, folder.Id), (Fresh(item).IsPinned, Fresh(item).FolderId));
        Assert.Equal("Moved to “Work”", _model.Notice);
        Assert.Equal("Work", _model.FolderCaption(_model.Entries.Single(e => e.ClipItem?.Id == item.Id)));

        _model.Select(new PanelEntry.Clip(Fresh(item)).Id);
        Assert.DoesNotContain(new PanelAction.AddToSaved(), _model.AvailableActions);
        _model.Perform(Assert.Single(_model.AvailableActions.OfType<PanelAction.RemoveFromFolder>()));
        Assert.Equal((true, (Guid?)null), (Fresh(item).IsPinned, Fresh(item).FolderId));
        Assert.Equal("Moved to Saved", _model.Notice);

        // Dragging onto a folder row moves in; onto the "Saved" breadcrumb moves out.
        _model.DropOnFolder(new PanelEntry.Clip(item).Id, folder.Id);
        Assert.Equal(folder.Id, Fresh(item).FolderId);
        _model.DropOnFolder(new PanelEntry.Clip(item).Id, null);
        Assert.Null(Fresh(item).FolderId);
        Assert.True(Fresh(item).IsPinned);
    }

    [Fact]
    public void AddToSavedPinsWithoutALabel()
    {
        var a = Add("a", 2);
        var b = Add("b", 1);
        _model.PrepareForOpen(null);
        SelectClips(a, b);
        _model.Perform(Assert.Single(_model.AvailableActions.OfType<PanelAction.AddToSaved>()));
        Assert.All(new[] { a, b }, i => Assert.Equal((true, (string?)null), (Fresh(i).IsPinned, Fresh(i).Label)));
        Assert.Equal("Added 2 items to Saved", _model.Notice);
    }

    [Fact]
    public void DeletingAFolderMovesItsClipsToSaved()
    {
        var folder = _store.CreateFolder("Trip");
        var a = Add("a", 2);
        var b = Add("b", 1);
        _store.MoveToFolder([a, b], folder);
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        Assert.Equal(["[Trip 2]"], Titles());
        _model.Select(_model.Entries[0].Id);
        Assert.Equal([new PanelAction.OpenFolder(), new PanelAction.RenameFolder(), new PanelAction.SetLabel(), new PanelAction.NewFolderInside(), new PanelAction.DeleteFolder()],
            _model.AvailableActions);
        _model.Perform(new PanelAction.DeleteFolder());

        Assert.Equal("Folder deleted · moved 2 items to Saved", _model.Notice);
        Assert.Empty(_store.AllFolders());
        Assert.All(new[] { a, b }, i => Assert.Equal((true, (Guid?)null), (Fresh(i).IsPinned, Fresh(i).FolderId)));
        Assert.Equal(["b", "a"], Titles());
    }

    [Fact]
    public void RemoveFromSavedClearsTheFolderAndALabelKeepsAFolderedItemSaved()
    {
        var folder = _store.CreateFolder("Keep");
        var plain = Add("plain", 1);
        var labelled = Add("labelled");
        _store.SetLabel("Name", labelled);
        _store.MoveToFolder([plain, Fresh(labelled)], folder);
        _model.PrepareForOpen(null);
        _model.Select(new PanelEntry.Clip(plain).Id);
        _model.Perform(new PanelAction.RemoveFromSaved());
        Assert.Equal((false, (Guid?)null), (Fresh(plain).IsPinned, Fresh(plain).FolderId));
        Assert.Equal("Removed from Saved", _model.Notice);

        // Removing the label of an item in a folder leaves it saved, in its folder.
        _store.SetLabel("", Fresh(labelled));
        Assert.Equal((true, (Guid?)folder.Id, (string?)null), (Fresh(labelled).IsPinned, Fresh(labelled).FolderId, Fresh(labelled).Label));
    }

    [Fact]
    public void SavedListsFoldersFirstAndOpensThem()
    {
        var zeta = _store.CreateFolder("zeta");
        var alpha = _store.CreateFolder("Alpha");
        var inAlpha = Add("in alpha", 3);
        var root = Add("at root", 2);
        Add("history only", 1);
        _store.MoveToFolder([inAlpha], alpha);
        _store.Pin(root);
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        Assert.Equal(["[Alpha 1]", "[zeta 0]", "at root"], Titles());
        Assert.Null(_model.ShortcutNumber(_model.Entries[0], 0));

        _model.Select(_model.Entries[0].Id);
        _model.HandleKey(K(PanelKey.Enter));                    // opens, doesn't paste
        Assert.Equal(alpha.Id, _model.OpenFolderId);
        Assert.Equal(["in alpha"], Titles());
        Assert.Null(_model.FolderCaption(_model.Entries[0]));   // no caption inside its own folder
        Assert.DoesNotContain(_host.Log, l => l.StartsWith("paste"));

        Assert.True(_model.HandleKey(K(PanelKey.Escape)));     // back to the root, not closed
        Assert.Null(_model.OpenFolderId);
        Assert.DoesNotContain("close", _host.Log);
        Assert.Equal("f-" + alpha.Id, _model.SelectedId);

        _model.OpenFolderById(zeta.Id);
        Assert.Empty(_model.Entries);
        Assert.True(_model.HandleKey(K(PanelKey.Backspace)));  // empty search: back
        Assert.Null(_model.OpenFolderId);
        Assert.False(_model.HandleKey(K(PanelKey.Backspace))); // at the root it edits the search box

        // Picking the Saved chip again from a folder returns to the root too.
        _model.OpenFolderById(alpha.Id);
        _model.SetFilter(PanelFilter.Labelled);
        Assert.Null(_model.OpenFolderId);

        // A search from the root finds clips in folders, with the folder as a caption.
        _model.SetQuery("alpha");
        var hit = _model.Entries.Single(e => e.ClipItem?.Id == inAlpha.Id);
        Assert.Equal("Alpha", _model.FolderCaption(hit));
        Assert.Contains(_model.Entries, e => e is PanelEntry.FolderEntry f && f.Folder.Id == alpha.Id);
        Assert.True(_model.HandleKey(K(PanelKey.Escape)));
        Assert.Contains("close", _host.Log);
    }

    [Fact]
    public void NewFolderButtonStartsAnInlineRename()
    {
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        _model.CreateFolder();
        Assert.Equal(PanelMode.FolderName, _model.Mode);
        var folder = Assert.Single(_store.AllFolders());
        Assert.Equal("New Folder", folder.Name);
        Assert.Equal("f-" + folder.Id, _model.SelectedId);
        _model.FolderForm!.Text = "  Recipes ";
        _model.HandleKey(K(PanelKey.Enter));
        Assert.Equal("Recipes", Assert.Single(_store.AllFolders()).Name);
        Assert.Equal(PanelMode.Browse, _model.Mode);

        // Rename from the folder's actions, and label it.
        _model.Select(_model.Entries[0].Id);
        _model.Perform(new PanelAction.RenameFolder());
        _model.FolderForm!.Text = "Cooking";
        _model.SubmitFolderName();
        _model.Select(_model.Entries[0].Id);
        _model.Perform(new PanelAction.SetLabel());
        Assert.True(_model.LabelForm!.IsFolder);
        _model.LabelForm.Text = "home";
        _model.SubmitLabel();
        Assert.Equal(("Cooking", "home"), (_store.AllFolders()[0].Name, _store.AllFolders()[0].Label));
    }

    [Fact]
    public void MoveToNewFolderFromHistory()
    {
        var items = Enumerable.Range(0, 5).Select(i => Add($"related {i}", 10 - i)).ToArray();
        _model.PrepareForOpen(null);
        SelectClips(items);
        _model.OpenActions();
        _model.Perform(Assert.Single(_model.AvailableActions.OfType<PanelAction.MoveToFolder>()));
        _model.Perform(Assert.Single(_model.FilteredActions.OfType<PanelAction.MoveToNewFolder>()));
        Assert.Equal(PanelMode.FolderName, _model.Mode);
        _model.FolderForm!.Text = "Project X";
        _model.HandleKey(K(PanelKey.Enter));
        var folder = Assert.Single(_store.AllFolders());
        Assert.Equal("Project X", folder.Name);
        Assert.All(items, i => Assert.Equal((true, (Guid?)folder.Id), (Fresh(i).IsPinned, Fresh(i).FolderId)));
        Assert.Equal("Moved 5 items to “Project X”", _model.Notice);
    }

    [Fact]
    public void AFolderIdThisDeviceDoesntHaveReadsAsTheRoot()
    {
        var item = Add("orphan");
        item.IsPinned = true;
        item.FolderId = Guid.NewGuid();
        _store.Put(item);
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        Assert.Equal(["orphan"], Titles());
        Assert.Null(_model.FolderCaption(_model.Entries[0]));
        _model.Select(_model.Entries[0].Id);
        Assert.DoesNotContain(new PanelAction.RemoveFromFolder(), _model.AvailableActions);

        // The folder arrives later: the clip moves into it.
        _store.PutFolder(new ClipFolder { Id = item.FolderId!.Value, Name = "Late" });
        _model.Refresh();
        Assert.Equal(["[Late 1]"], Titles());
    }

    [Fact]
    public void GroupsSwitchBetweenAllAndSavedAndKeepTheirFolders()
    {
        _store.SaveSyncSpaces([new SpaceRecord("g1", "group", "owner", "Team", "me", 2)]);
        var groupFolder = _store.CreateFolder("Shared", "g1");
        _store.CreateFolder("Mine");
        var groupItem = Add("group note", 2, "g1");
        Add("group history", 1, "g1");
        _store.MoveToFolder([groupItem], groupFolder);
        var groupRoot = Add("group saved", 0, "g1");
        _store.Pin(groupRoot);

        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        Assert.Equal(["[Mine 0]"], Titles());    // the personal Saved has no group folders or clips

        _model.SetGroupFilter("g1");
        Assert.False(_model.IsSavedView);
        Assert.Equal(3, _model.Entries.Count);
        _model.SetGroupShowsSaved(true);
        Assert.True(_model.IsSavedView);
        Assert.Equal(["g1"], _settings.GroupsShowingSaved);
        Assert.Equal(["[Shared 1]", "group saved"], Titles());

        // A new folder in a group's Saved belongs to the group; group clips move into its folders, and the personal
        // ones (under "Mine") take copies.
        _model.CreateFolder();
        _model.SubmitFolderName();
        Assert.Equal("g1", _store.AllFolders().Single(f => f.Name == "New Folder").SpaceId);
        _model.Select(new PanelEntry.Clip(groupRoot).Id);
        _model.Perform(new PanelAction.MoveToFolder());
        Assert.Equal(["New Folder", "Shared", "New Folder…", "Mine", "New Folder…"], Picks().Select(a => a.Title));
        Assert.Equal(["Team", "Team", "Team", "Mine", "Mine"], Picks().Select(a => a.Section("AI")));
        _model.ResetMode();

        // The choice is remembered per group.
        _model.SetFilter(PanelFilter.All);
        _model.SetGroupFilter("g1");
        Assert.True(_model.IsSavedView);
        _model.SetGroupShowsSaved(false);
        Assert.Empty(_settings.GroupsShowingSaved);
    }

    [Fact]
    public void GroupItemsAreRemovedFromTheGroup()
    {
        _store.SaveSyncSpaces([new SpaceRecord("g1", "group", "owner", "Team", "me", 2)]);
        var a = Add("one", 2, "g1");
        var b = Add("two", 1, "g1");
        var personal = Add("mine");
        _model.PrepareForOpen(null);
        _model.Select(new PanelEntry.Clip(personal).Id);
        Assert.Contains(new PanelAction.Delete(), _model.AvailableActions);
        Assert.DoesNotContain(new PanelAction.RemoveFromGroup(), _model.AvailableActions);

        _model.Select(new PanelEntry.Clip(a).Id);
        Assert.Equal("Remove from Group", _model.AvailableActions.Last().Title);
        Assert.DoesNotContain(new PanelAction.Delete(), _model.AvailableActions);
        _model.Perform(new PanelAction.RemoveFromGroup());
        Assert.Null(_store.Find(a.Id));

        var c = Add("three", 0, "g1");
        _model.Refresh();
        SelectClips(b, c);
        Assert.Equal(new PanelAction.RemoveFromGroup(), _model.AvailableActions.Last());
        _model.Perform(new PanelAction.RemoveFromGroup());
        Assert.Equal(["mine"], _store.AllItems().Select(i => i.Text));

        // A mixed selection reads Delete.
        var d = Add("four", 0, "g1");
        _model.Refresh();
        SelectClips(d, personal);
        Assert.Equal(new PanelAction.Delete(), _model.AvailableActions.Last());
    }

    [Fact]
    public void ContactItemsCantMoveIntoFolders()
    {
        _store.SaveSyncSpaces([new SpaceRecord("c1", SpaceKinds.Direct, "member", "Ana", "ana", 2)]);
        var received = Add("from Ana", 0, "c1");
        _store.SaveSyncMeta(new SyncMeta("c1", ClipStore.SyncId(received.Id), SyncCategory.History, "f", 1, 1, AuthorUid: "ana"));
        _store.CreateFolder("Mine");
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Inbox);
        _model.Select(new PanelEntry.Clip(received).Id);
        Assert.NotNull(_model.SelectedEntry);
        Assert.DoesNotContain(new PanelAction.MoveToFolder(), _model.AvailableActions);
        Assert.Contains(new PanelAction.AddToSaved(), _model.AvailableActions);
        Assert.Equal(0, _store.MoveToFolder([received], _store.AllFolders()[0]));   // other space: skipped
    }

    [Fact]
    public void SharingAFolderCopiesItAndItsClipsIntoTheGroup()
    {
        _store.SaveSyncSpaces([new SpaceRecord("g1", "group", "owner", "Team", "me", 2)]);
        var folder = _store.CreateFolder("Recipes");
        _store.SetFolderLabel(folder, "food");
        var a = Add("soup", 1);
        var b = Add("bread");
        _store.MoveToFolder([a, b], folder);
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        _model.Select("f-" + folder.Id);
        _model.Perform(Assert.Single(_model.AvailableActions.OfType<PanelAction.ShareToGroup>()));
        _model.Perform(new PanelAction.ShareTo("g1", "Team"));

        var copy = _store.FoldersInSpace("g1").Single();
        Assert.NotEqual(folder.Id, copy.Id);
        Assert.Equal(("Recipes", "food"), (copy.Name, copy.Label));
        var copies = _store.ItemsInSpace("g1");
        Assert.Equal(["bread", "soup"], copies.Select(i => i.Text).Order());
        Assert.All(copies, c => Assert.Equal((true, (Guid?)copy.Id), (c.IsPinned, c.FolderId)));
        Assert.DoesNotContain(copies, c => c.Id == a.Id || c.Id == b.Id);
        Assert.Equal(2, _store.ItemsInSpace(null).Count(i => i.FolderId == folder.Id));   // the personal folder stays

        // A group's folder isn't offered for sharing.
        _model.SetGroupFilter("g1");
        _model.SetGroupShowsSaved(true);
        _model.Select("f-" + copy.Id);
        Assert.DoesNotContain(new PanelAction.ShareToGroup(), _model.AvailableActions);
    }

    [Fact]
    public void PayloadCarriesTheFolderAndItCountsForTheFingerprint()
    {
        var folder = new ClipFolder { Name = "Work", Label = "job" };
        var folderJson = SyncPayload.ForFolder(folder);
        Assert.Equal("folder", folderJson["type"]!.GetValue<string>());
        var parsed = Assert.IsType<ItemPayload.FolderPayload>(SyncPayload.Parse(SyncPayload.Encode(folderJson), folder.Id, "g1"));
        Assert.Equal((folder.Id, "Work", "job", "g1"), (parsed.Folder.Id, parsed.Folder.Name, parsed.Folder.Label, parsed.Folder.SpaceId));

        var item = Add("text");
        var before = SyncPayload.Fingerprint(SyncPayload.ForClip(item));
        Assert.Null(SyncPayload.ForClip(item)["folder"]);
        _store.MoveToFolder([item], _store.CreateFolder("Work"));
        var json = SyncPayload.ForClip(Fresh(item));
        Assert.Equal(ClipStore.SyncId(Fresh(item).FolderId!.Value), json["folder"]!.GetValue<string>());
        Assert.NotEqual(before, SyncPayload.Fingerprint(json));
        var clip = Assert.IsType<ItemPayload.Clip>(SyncPayload.Parse(SyncPayload.Encode(json), item.Id, null));
        Assert.Equal(Fresh(item).FolderId, clip.Item.FolderId);

        // Clearing isPinned clears the folder, whatever the payload says.
        json["isPinned"] = false;
        Assert.Null(Assert.IsType<ItemPayload.Clip>(SyncPayload.Parse(SyncPayload.Encode(json), item.Id, null)).Item.FolderId);
    }

    [Fact]
    public void FoldersAreBackedUpAndRestored()
    {
        var folder = _store.CreateFolder("Archive");
        var item = Add("old note");
        _store.MoveToFolder([item], folder);
        var root = Backup.Parse(Backup.CreatePlaintext(_store, null));
        Assert.Single(root["folders"]!.AsArray());

        var dir = Path.Combine(Path.GetTempPath(), "c2folders-target-" + Guid.NewGuid());
        using var target = new ClipStore(":memory:", new BlobStore(dir));
        var existing = target.CreateFolder("archive");   // joins by name
        Backup.Merge(root, target, null);
        var restored = Assert.Single(target.AllItems());
        Assert.Equal(existing.Id, restored.FolderId);
        Assert.Single(target.AllFolders());

        // Without the folders list (an older writer), the clip lands at the root of Saved.
        root.Remove("folders");
        using var older = new ClipStore(":memory:", new BlobStore(dir));
        Backup.Merge(root, older, null);
        Assert.Equal((true, (Guid?)null), (older.AllItems()[0].IsPinned, older.AllItems()[0].FolderId));
    }

    [Fact]
    public void RetentionNeverTrimsFolderedClips()
    {
        var folder = _store.CreateFolder("Keep");
        var old = Add("ancient", 60 * 60 * 24 * 400);
        _store.MoveToFolder([old], folder);
        Add("recent");
        Assert.Equal(0, _store.EnforceRetention(1, TimeSpan.FromDays(1)));
        Assert.NotNull(_store.Find(old.Id));
    }
}

public sealed partial class SyncEngineTests
{
    private int ClipPuts(Device d, string space, Guid id) => _cloud.Count($"PUT api.fake/v1/spaces/{space}/items/{ClipStore.SyncId(id)}");

    [Fact]
    public async Task FoldersPushPullAndDelete()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        var folder = a.Store.CreateFolder("Work");
        var item = a.Copy("meeting notes");
        a.Store.MoveToFolder([item], folder);
        await a.Sync();
        var remote = _cloud.ItemById(a.Personal, ClipStore.SyncId(folder.Id));
        Assert.Equal((SyncCategory.Folder, SyncPayload.Millis(folder.CreatedAt)), (remote.Category, remote.SortAt));
        Assert.Equal(SyncCategory.Pinned, _cloud.ItemById(a.Personal, ClipStore.SyncId(item.Id)).Category);

        await b.Sync();
        var onB = Assert.Single(b.Store.AllFolders());
        Assert.Equal((folder.Id, "Work"), (onB.Id, onB.Name));
        Assert.Equal(folder.Id, b.Store.Find(item.Id)!.FolderId);

        // A rename on B reaches A.
        b.Store.RenameFolder(onB, "Office");
        await b.Sync();
        await a.Sync();
        Assert.Equal("Office", Assert.Single(a.Store.AllFolders()).Name);

        // A deletes it: the tombstone goes up and A re-pushes its clip without the folder.
        var puts = ClipPuts(a, a.Personal, item.Id);
        a.Store.DeleteFolder(a.Store.AllFolders()[0]);
        await a.Sync();
        Assert.NotNull(_cloud.ItemById(a.Personal, ClipStore.SyncId(folder.Id)).Deleted);
        Assert.Equal(puts + 1, ClipPuts(a, a.Personal, item.Id));
        Assert.Null(OpenPayload(a, _cloud.ItemById(a.Personal, ClipStore.SyncId(item.Id)))["folder"]);

        await b.Sync();
        Assert.Empty(b.Store.AllFolders());
        Assert.Equal((true, (Guid?)null), (b.Store.Find(item.Id)!.IsPinned, b.Store.Find(item.Id)!.FolderId));
    }

    [Fact]
    public async Task MovingAClipRePushesItAndAFolderPulledLateCollectsItsClips()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        var item = a.Copy("loose");
        await a.Sync();
        var puts = ClipPuts(a, a.Personal, item.Id);
        await a.Sync();
        Assert.Equal(puts, ClipPuts(a, a.Personal, item.Id));   // unchanged: not pushed again

        var folder = a.Store.CreateFolder("Later");
        a.Store.MoveToFolder([a.Store.Find(item.Id)!], folder);
        _cloud.HiddenFromChanges.Add(ClipStore.SyncId(folder.Id));   // the clip arrives before its folder
        await a.Sync();
        Assert.Equal(puts + 1, ClipPuts(a, a.Personal, item.Id));

        await b.Sync();
        Assert.Empty(b.Store.AllFolders());
        Assert.Equal(folder.Id, b.Store.Find(item.Id)!.FolderId);       // kept, reads as the root
        var panel = Panel(b);
        panel.SetFilter(PanelFilter.Labelled);
        Assert.Equal("loose", Assert.Single(panel.Entries).ClipItem!.Text);

        _cloud.HiddenFromChanges.Clear();
        b.Store.SetSyncCursor(b.Personal, 0);   // pull everything again, the folder included
        await b.Sync();
        Assert.Single(b.Store.AllFolders());
        panel.Refresh();
        Assert.Equal("Later", Assert.IsType<PanelEntry.FolderEntry>(Assert.Single(panel.Entries)).Folder.Name);
    }

    [Fact]
    public async Task AFolderDeletedElsewhereIsntPushedBackByItsClips()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        var folder = a.Store.CreateFolder("Gone");
        var item = a.Copy("inside");
        a.Store.MoveToFolder([item], folder);
        await a.Sync();
        await b.Sync();

        // Only the folder is deleted (as an older client, or one that hasn't re-pushed its clips yet, would leave it).
        _cloud.HiddenFromChanges.Add(ClipStore.SyncId(item.Id));
        a.Store.DeleteFolder(a.Store.AllFolders()[0]);
        await a.Sync();
        var before = _cloud.Count("PUT api.fake");
        await b.Sync();
        Assert.Empty(b.Store.AllFolders());
        Assert.Equal(folder.Id, b.Store.Find(item.Id)!.FolderId);   // lazily at the root
        Assert.Equal(before, _cloud.Count("PUT api.fake"));         // B pushes nothing for it
    }

    [Fact]
    public async Task GroupFoldersSyncToMembers()
    {
        var a = await SignedUp();
        var b = await SignedUp("friend@example.com");
        Assert.True(await a.Account.CreateGroupAsync("Team"));
        var group = a.Account.Groups.Single();
        await Invite(a, b, group.Id);
        var folder = a.Store.CreateFolder("Specs", group.Id);
        var item = a.Copy("api spec", 0, group.Id);
        a.Store.MoveToFolder([item], folder);
        await a.Sync();
        await b.Sync();
        Assert.Equal(("Specs", group.Id), (b.Store.AllFolders().Single().Name, b.Store.AllFolders().Single().SpaceId));
        Assert.Equal(folder.Id, b.Store.Find(item.Id)!.FolderId);
        Assert.Empty(b.Store.FoldersInSpace(null));

        // A member's own folder and clip sync back to the owner.
        var theirs = b.Store.CreateFolder("Notes", group.Id);
        var note = b.Copy("b's note", 0, group.Id);
        b.Store.MoveToFolder([note], theirs);
        await b.Sync();
        await a.Sync();
        Assert.Equal(theirs.Id, a.Store.Find(note.Id)!.FolderId);

        // The server lets only an item's author (or the owner) change it: B moving A's clip stays on B.
        b.Store.MoveToFolder([b.Store.Find(item.Id)!], b.Store.FindFolder(theirs.Id));
        await b.Sync();
        Assert.Contains(b.Account.Warnings, w => w.StartsWith("Only its author or the group's owner"));
        await a.Sync();
        Assert.Equal(folder.Id, a.Store.Find(item.Id)!.FolderId);
    }
}
