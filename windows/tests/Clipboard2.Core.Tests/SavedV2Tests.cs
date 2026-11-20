using System.Text;
using System.Text.Json.Nodes;
using Clipboard2.Core.Sync;

namespace Clipboard2.Core.Tests;

/// <summary>Saved v2 (docs/features/saved-v2.md): one Saved for clips, secrets and snippets, secrets in folders,
/// group items saved to personal folders, and the group chip's Copies | Saved segments.</summary>
public sealed class SavedV2Tests : IDisposable
{
    private readonly ClipStore _store = new(":memory:", new BlobStore(Path.Combine(Path.GetTempPath(), "c2saved-" + Guid.NewGuid())));
    private readonly Settings _settings = new();
    private readonly FakeVault _vault = new();
    private readonly FakeHost _host = new();
    private readonly PanelModel _model;

    /// <summary>The folder picker without its "New Folder in ‹folder›…" rows (nested-folders.md).</summary>
    private List<PanelAction> Picks() => [.. _model.FilteredActions.Where(a => a is not PanelAction.MoveToNewFolder { ParentId: not null })];

    public SavedV2Tests()
    {
        _model = new PanelModel(_store, _settings, new QuickSlots(_settings), _vault, _host) { Self = () => new SyncSelf("me", "me") };
    }

    public void Dispose() => _store.Dispose();

    private ClipItem Add(string text, int ageSeconds = 0, string? space = null) =>
        _store.Ingest(ProcessedCapture.ForText(text), DateTime.UtcNow.AddSeconds(-ageSeconds), space);

    private ClipItem Saved(string text, int ageSeconds, string? space = null)
    {
        var item = Add(text, ageSeconds, space);
        item.IsPinned = true;
        item.PinnedAt = DateTime.UtcNow.AddSeconds(-ageSeconds);
        _store.Put(item);
        return item;
    }

    /// <summary>A secret written <paramref name="ageSeconds"/> ago (FakeVault stamps "now"; Saved's order needs older ones).</summary>
    private SecretRef Secret(string name, int ageSeconds, string? space = null)
    {
        var secret = _vault.Add(name, "value of " + name, space)!;
        var field = typeof(FakeVault).GetField("_secrets", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!;
        var list = (List<SecretRef>)field.GetValue(_vault)!;
        var dated = secret with { CreatedAt = DateTime.UtcNow.AddSeconds(-ageSeconds) };
        list[list.FindIndex(s => s.Id == secret.Id)] = dated;
        return dated;
    }

    private Snippet Snippet(string name, int ageSeconds, string? space = null)
    {
        var snippet = new Snippet { Name = name, Body = name + " body", Keyword = ";" + name, SpaceId = space,
            UpdatedAt = DateTime.UtcNow.AddSeconds(-ageSeconds), CreatedAt = DateTime.UtcNow.AddSeconds(-ageSeconds) };
        _store.PutSnippet(snippet);
        return snippet;
    }

    private List<string> Titles() => [.. _model.Entries.Select(e => e switch
    {
        PanelEntry.FolderEntry f => $"[{f.Folder.Name} {f.Count}]",
        PanelEntry.SecretEntry k => "secret " + k.Secret.Name,
        PanelEntry.SnippetEntry s => "snippet " + s.Snippet.Name,
        _ => e.ClipItem!.DisplayTitle,
    })];

    private void Group(string role = "member") =>
        _store.SaveSyncSpaces([new SpaceRecord("g1", SpaceKinds.Group, role, "Team", "owner-uid", 3)]);

    private void AuthoredBy(ClipItem item, string uid) =>
        _store.SaveSyncMeta(new SyncMeta(item.SpaceId!, ClipStore.SyncId(item.Id), SyncCategory.History, "fp", 1, 1, AuthorUid: uid));

    // MARK: Saved mixes clips, secrets and snippets

    [Fact]
    public void SavedListsFoldersThenClipsSecretsAndSnippetsNewestFirst()
    {
        var work = _store.CreateFolder("Work");
        _store.CreateFolder("Archive");
        Saved("old clip", 50);
        Secret("bank", 40);
        Snippet("sig", 30);
        Saved("new clip", 10);
        Secret("wifi", 5);
        Add("history only", 1);
        var inFolder = Saved("filed clip", 2);
        _store.MoveToFolder([inFolder], work);
        var filedSecret = Secret("server", 3);
        _store.SetSecretFolder(filedSecret.Id, work.Id);
        // A group's and a contact's items stay out of the personal Saved.
        Group();
        Saved("group clip", 0, "g1");
        Secret("group pin", 0, "g1");

        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        Assert.Equal(["[Archive 0]", "[Work 2]", "secret wifi", "new clip", "snippet sig", "secret bank", "old clip"], Titles());

        // Inside a folder: its clips and secrets, mixed; snippets never go in folders.
        _model.Activate(_model.Entries[1]);
        Assert.Equal(["filed clip", "secret server"], Titles());
        _model.CloseFolder();

        // A search from the root finds what's in folders too, with the folder as a caption.
        _model.SetQuery("server");
        var found = Assert.Single(_model.Entries, e => e is PanelEntry.SecretEntry);
        Assert.Equal("Work", _model.FolderCaption(found));

        // Search from All still finds secrets and snippets; All without a search lists neither.
        _model.SetFilter(PanelFilter.All);
        _model.SetQuery("");
        Assert.DoesNotContain(_model.Entries, e => e is PanelEntry.SecretEntry or PanelEntry.SnippetEntry);
        _model.SetQuery("sig");
        Assert.Contains(_model.Entries, e => e is PanelEntry.SnippetEntry);
        _model.SetQuery("bank");
        Assert.Contains(_model.Entries, e => e is PanelEntry.SecretEntry);
    }

    [Fact]
    public void SnippetsInSavedPasteAndSecretsKeepTheirSafeguards()
    {
        Snippet("sig", 1);
        Secret("bank", 2);
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        _model.Select(_model.Entries.Single(e => e is PanelEntry.SecretEntry).Id);
        Assert.False(_model.CanPreview);
        Assert.Contains(new PanelAction.MoveToFolder(), _model.AvailableActions);
        Assert.Contains(new PanelAction.Delete(), _model.AvailableActions);
        _model.HandleKey(new KeyInput(PanelKey.Enter));
        Assert.Contains("paste-secret:bank", _host.Log);

        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        _model.Select(_model.Entries.Single(e => e is PanelEntry.SnippetEntry).Id);
        Assert.DoesNotContain(new PanelAction.MoveToFolder(), _model.AvailableActions);
        _model.HandleKey(new KeyInput(PanelKey.Enter));
        Assert.Contains("paste-text:sig body:0", _host.Log);
    }

    // MARK: Secrets in folders

    [Fact]
    public void SecretsMoveIntoFoldersByActionDragAndBackOut()
    {
        var folder = _store.CreateFolder("Keys");
        var secret = Secret("api key", 1);
        var clip = Saved("note", 2);
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        var secretId = new PanelEntry.SecretEntry(secret).Id;
        _model.Select(secretId);
        _model.Perform(new PanelAction.MoveToFolder());
        Assert.Equal([new PanelAction.MoveTo(folder.Id, "Keys"), new PanelAction.MoveToNewFolder()], Picks());
        _model.Perform(new PanelAction.MoveTo(folder.Id, "Keys"));
        Assert.Equal(folder.Id, _store.SecretFolderId(secret.Id));
        Assert.Equal("Moved to “Keys”", _model.Notice);
        Assert.Equal(["[Keys 1]", "note"], Titles());

        // Remove from Folder.
        _model.OpenFolderById(folder.Id);
        _model.Select(secretId);
        Assert.Contains(new PanelAction.RemoveFromFolder(), _model.AvailableActions);
        _model.Perform(new PanelAction.RemoveFromFolder());
        Assert.Null(_store.SecretFolderId(secret.Id));

        // Dragging a secret and a clip together onto the folder row.
        _model.CloseFolder();
        _model.Select(secretId);
        _model.ToggleSelection(new PanelEntry.Clip(clip).Id);
        Assert.Contains(new PanelAction.MoveToFolder(), _model.AvailableActions);
        _model.DropOnFolder(secretId, folder.Id);
        Assert.Equal(folder.Id, _store.SecretFolderId(secret.Id));
        Assert.Equal(folder.Id, _store.Find(clip.Id)!.FolderId);
        Assert.Equal("Moved 2 items to “Keys”", _model.Notice);

        // Deleting the folder moves both to the root.
        _model.DeleteFolder(folder);
        Assert.Equal("Folder deleted · moved 2 items to Saved", _model.Notice);
        Assert.Null(_store.SecretFolderId(secret.Id));
        Assert.Equal(["note", "secret api key"], Titles().OrderBy(t => t).ToList());
    }

    [Fact]
    public void NewFolderFromASecretAndAnUnknownFolderReadsAsTheRoot()
    {
        var secret = Secret("token", 1);
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);
        _model.Select(new PanelEntry.SecretEntry(secret).Id);
        _model.Perform(new PanelAction.MoveToNewFolder());
        Assert.Equal(PanelMode.FolderName, _model.Mode);
        _model.FolderForm!.Text = "Tokens";
        _model.SubmitFolderName();
        var created = Assert.Single(_store.AllFolders());
        Assert.Equal(created.Id, _store.SecretFolderId(secret.Id));

        _store.SetSecretFolder(secret.Id, Guid.NewGuid());   // a folder not pulled yet
        _model.Refresh();
        Assert.Equal(["[Tokens 0]", "secret token"], Titles());
    }

    [Fact]
    public void SecretPayloadCarriesTheFolderAndItCountsForTheFingerprint()
    {
        var folder = Guid.NewGuid();
        var created = DateTime.UtcNow;
        var plain = SyncPayload.ForSecret("PIN", "1234", created);
        Assert.Null(plain["folder"]);
        var filed = SyncPayload.ForSecret("PIN", "1234", created, folder);
        Assert.Equal(ClipStore.SyncId(folder), filed["folder"]!.GetValue<string>());
        Assert.NotEqual(SyncPayload.Fingerprint(plain), SyncPayload.Fingerprint(filed));
        // Only the folder matters, not when the vault last wrote it.
        Assert.Equal(SyncPayload.Fingerprint(filed), SyncPayload.Fingerprint(SyncPayload.ForSecret("PIN", "1234", created.AddHours(1), folder)));

        var parsed = Assert.IsType<ItemPayload.Secret>(SyncPayload.Parse(SyncPayload.Encode(filed), Guid.NewGuid(), null));
        Assert.Equal(("PIN", "1234", (Guid?)folder), (parsed.Name, parsed.Value, parsed.Folder));
        Assert.Null(Assert.IsType<ItemPayload.Secret>(SyncPayload.Parse(SyncPayload.Encode(plain), Guid.NewGuid(), null)).Folder);
        // Older payloads, and junk, read as the root.
        plain["folder"] = "not-an-id";
        Assert.Null(Assert.IsType<ItemPayload.Secret>(SyncPayload.Parse(SyncPayload.Encode(plain), Guid.NewGuid(), null)).Folder);
    }

    [Fact]
    public void SecretFoldersAreBackedUpAndRestored()
    {
        var folder = _store.CreateFolder("Keys");
        var root = Backup.Create(_store, [new BackupSecret("a", "Filed", "v1", null, folder.Id), new BackupSecret("b", "Loose", "v2", null)]);
        var entries = root["secrets"]!.AsArray();
        Assert.Equal(ClipStore.SyncId(folder.Id), entries[0]!["folder"]!.GetValue<string>());
        Assert.Null(entries[1]!["folder"]);

        using var target = new ClipStore(":memory:", new BlobStore(Path.Combine(Path.GetTempPath(), "c2saved-" + Guid.NewGuid())));
        var vault = new FakeVault();
        var result = Backup.Merge(Backup.Parse(Encoding.UTF8.GetBytes(root.ToJsonString())), target, vault);
        Assert.Equal(2, result.Secrets);
        var restored = Assert.Single(target.AllFolders());
        Assert.Equal(restored.Id, target.SecretFolderId(vault.Secrets.Single(s => s.Name == "Filed").Id));
        Assert.Null(target.SecretFolderId(vault.Secrets.Single(s => s.Name == "Loose").Id));
    }

    // MARK: Group items and personal folders

    [Fact]
    public void MovingAGroupItemToAPersonalFolderSavesACopy()
    {
        Group();
        var mine = _store.CreateFolder("Mine");
        var shared = _store.CreateFolder("Shared", "g1");
        var item = Add("team note", 1, "g1");
        _model.PrepareForOpen(null);
        _model.SetGroupFilter("g1");
        _model.Select(new PanelEntry.Clip(item).Id);
        _model.Perform(new PanelAction.MoveToFolder());
        var picks = Picks();
        Assert.Equal([new PanelAction.MoveTo(shared.Id, "Shared", "Team"), new PanelAction.MoveToNewFolder(false, "Team"),
                      new PanelAction.MoveTo(mine.Id, "Mine", "Mine"), new PanelAction.MoveToNewFolder(true, "Mine")], picks);

        _model.Perform(new PanelAction.MoveTo(mine.Id, "Mine", "Mine"));
        Assert.Equal("Saved a copy to “Mine”", _model.Notice);
        var copy = Assert.Single(_store.ItemsInSpace(null));
        Assert.NotEqual(item.Id, copy.Id);
        Assert.Equal(("team note", true, (Guid?)mine.Id), (copy.Text, copy.IsPinned, copy.FolderId));
        var group = _store.Find(item.Id)!;   // unchanged
        Assert.Equal(("g1", false, (Guid?)null), (group.SpaceId, group.IsPinned, group.FolderId));
    }

    [Fact]
    public void NewFolderUnderMineCopiesSeveralGroupItemsAndMixedSpacesOnlyListMine()
    {
        Group();
        var a = Add("one", 2, "g1");
        var b = Add("two", 1, "g1");
        var personal = Add("three", 0);
        _model.PrepareForOpen(null);
        _model.SetGroupFilter("g1");
        _model.Select(new PanelEntry.Clip(a).Id);
        _model.ToggleSelection(new PanelEntry.Clip(b).Id);
        _model.Perform(new PanelAction.MoveToNewFolder(true, "Mine"));
        Assert.Null(_model.FolderForm!.SpaceId);
        _model.FolderForm.Text = "Copied";
        _model.SubmitFolderName();
        var folder = _store.FoldersInSpace(null).Single();
        Assert.Equal(["one", "two"], _store.ItemsInSpace(null).Where(i => i.FolderId == folder.Id).Select(i => i.Text).Order());
        Assert.Equal(2, _store.ItemsInSpace("g1").Count(i => !i.IsPinned && i.FolderId is null));
        Assert.Equal("Saved 2 copies to “Copied”", _model.Notice);

        // Group and personal items together: only "Mine".
        _model.SetFilter(PanelFilter.All);
        _model.Select(new PanelEntry.Clip(a).Id);
        _model.ToggleSelection(new PanelEntry.Clip(personal).Id);
        _model.Perform(new PanelAction.MoveToFolder());
        Assert.All(_model.FilteredActions, x => Assert.Equal("Mine", x.Section("AI")));
        Assert.Contains(new PanelAction.MoveTo(folder.Id, "Copied", "Mine"), _model.FilteredActions);
    }

    [Fact]
    public void AGroupSecretGoesToAPersonalFolderAsACopy()
    {
        Group();
        var mine = _store.CreateFolder("Mine");
        var secret = Secret("team pin", 1, "g1");
        _model.PrepareForOpen(null);
        _model.SetGroupFilter("g1");
        _model.Select(new PanelEntry.SecretEntry(secret).Id);
        _model.Perform(new PanelAction.MoveTo(mine.Id, "Mine", "Mine"));
        Assert.Contains($"copy-secrets:team pin:personal:{mine.Id}", _host.Log);
        Assert.Null(_store.SecretFolderId(secret.Id));   // the group's secret doesn't move
    }

    [Fact]
    public void AnotherMembersGroupItemOffersSaveACopy()
    {
        Group(role: "member");
        var theirs = Add("their note", 2, "g1");
        AuthoredBy(theirs, "someone-else");
        var own = Add("my note", 1, "g1");
        AuthoredBy(own, "me");
        _model.PrepareForOpen(null);
        _model.SetGroupFilter("g1");

        _model.Select(new PanelEntry.Clip(own).Id);
        Assert.True(_model.CanChange(own));
        Assert.Contains(new PanelAction.AddToSaved(), _model.AvailableActions);

        _model.Select(new PanelEntry.Clip(theirs).Id);
        Assert.False(_model.CanChange(theirs));
        Assert.DoesNotContain(new PanelAction.AddToSaved(), _model.AvailableActions);
        Assert.Contains(new PanelAction.SaveCopy(), _model.AvailableActions);
        _model.Perform(new PanelAction.SaveCopy());
        Assert.Equal("Saved a copy to Saved", _model.Notice);
        Assert.False(_store.Find(theirs.Id)!.IsPinned);   // no local-only pin
        var copy = Assert.Single(_store.ItemsInSpace(null));
        Assert.Equal(("their note", true, (Guid?)null), (copy.Text, copy.IsPinned, copy.FolderId));

        // The group's owner may change anyone's item: a plain Add to Saved.
        Group(role: "owner");
        _model.Refresh();
        _model.Select(new PanelEntry.Clip(theirs).Id);
        Assert.Contains(new PanelAction.AddToSaved(), _model.AvailableActions);
    }

    [Fact]
    public void ShareToGroupCanPutCopiesIntoAGroupFolder()
    {
        Group(role: "owner");
        var specs = _store.CreateFolder("Specs", "g1");
        var item = Add("api spec", 1);
        var secret = Secret("deploy key", 2);
        _model.PrepareForOpen(null);
        _model.Select(new PanelEntry.Clip(item).Id);
        _model.Perform(new PanelAction.ShareToGroup());
        _model.Perform(new PanelAction.ShareTo("g1", "Team"));
        Assert.Equal(new PanelAction.ShareTo("g1", "Team"), _model.PickingShareFolder);
        Assert.Equal([new PanelAction.ShareInto("g1", "Team", null, "No Folder"), new PanelAction.ShareInto("g1", "Team", specs.Id, "Specs")],
            Picks());
        // Escape goes back to the groups.
        _model.HandleKey(new KeyInput(PanelKey.Escape));
        Assert.True(_model.IsPickingGroup);
        _model.Perform(new PanelAction.ShareTo("g1", "Team"));
        _model.Perform(new PanelAction.ShareInto("g1", "Team", specs.Id, "Specs"));
        var copy = Assert.Single(_store.ItemsInSpace("g1"));
        Assert.Equal(("api spec", true, (Guid?)specs.Id), (copy.Text, copy.IsPinned, copy.FolderId));
        Assert.Equal("Shared to “Team › Specs”", _model.Notice);
        Assert.Null(_store.Find(item.Id)!.FolderId);

        // A secret goes in through the host (Windows Hello), into the chosen folder.
        _model.SetFilter(PanelFilter.Labelled);
        _model.Select(new PanelEntry.SecretEntry(secret).Id);
        _model.Perform(new PanelAction.ShareTo("g1", "Team"));
        _model.Perform(new PanelAction.ShareInto("g1", "Team", specs.Id, "Specs"));
        Assert.Contains($"copy-secrets:deploy key:g1:{specs.Id}", _host.Log);

        // The root is the default, and a group without folders shares straight away.
        _store.DeleteFolder(specs);
        _model.SetFilter(PanelFilter.All);
        _model.Select(new PanelEntry.Clip(item).Id);
        _model.Perform(new PanelAction.ShareTo("g1", "Team"));
        Assert.Null(_model.PickingShareFolder);
    }

    // MARK: The group chip's segments

    [Fact]
    public void TabGoesFromCopiesToSavedToTheNextGroupAndBack()
    {
        _store.SaveSyncSpaces([new SpaceRecord("g2", SpaceKinds.Group, "owner", "Beta", "me", 2),
                               new SpaceRecord("g1", SpaceKinds.Group, "owner", "Alpha", "me", 2)]);
        _settings.GroupsShowingSaved.Add("g2");   // remembered as Saved; Tab still lands on Copies first
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.ThisApp);
        List<(string?, bool)> seen = [];
        for (var i = 0; i < 5; i++)
        {
            _model.HandleKey(new KeyInput(PanelKey.Tab));
            seen.Add((_model.GroupFilter, _model.IsSavedView));
        }
        Assert.Equal([("g1", false), ("g1", true), ("g2", false), ("g2", true), (null, false)], seen);
        Assert.Equal(PanelFilter.All, _model.Filter);

        _model.HandleKey(new KeyInput(PanelKey.Tab, KeyMods.Shift));
        Assert.Equal(("g2", true), (_model.GroupFilter, _model.IsSavedView));
        _model.HandleKey(new KeyInput(PanelKey.Tab, KeyMods.Shift));
        Assert.Equal(("g2", false), (_model.GroupFilter, _model.IsSavedView));
        _model.HandleKey(new KeyInput(PanelKey.Tab, KeyMods.Shift));
        Assert.Equal(("g1", true), (_model.GroupFilter, _model.IsSavedView));

        // Clicking a group chip shows the segment remembered for it.
        _model.SetFilter(PanelFilter.All);
        _model.SetGroupFilter("g1");
        Assert.True(_model.IsSavedView);
    }

    [Fact]
    public void AGroupsSavedListsItsSecretsAndSnippets()
    {
        Group();
        Saved("group clip", 3, "g1");
        Secret("group pin", 2, "g1");
        Snippet("group sig", 1, "g1");
        Secret("my pin", 0);
        _model.PrepareForOpen(null);
        _model.SetGroupFilter("g1");
        _model.SetGroupShowsSaved(true);
        Assert.Equal(["snippet group sig", "secret group pin", "group clip"], Titles());
    }
}

public sealed partial class SyncEngineTests
{
    [Fact]
    public async Task SecretFoldersSyncAndGroupSecretsReachMembers()
    {
        var a = await SignedUp();
        var b = await SignedIn();
        var folder = a.Store.CreateFolder("Keys");
        var secret = a.Vault.Add("api", "s3cret")!;
        await a.Sync();
        var remote = _cloud.ItemById(a.Personal, ClipStore.SyncId(Guid.Parse(secret.Id)));
        Assert.Null(OpenPayload(a, remote)["folder"]);

        // Moving it re-pushes it with the folder, and the other device files it.
        a.Store.SetSecretFolder(secret.Id, folder.Id);
        await a.Sync();
        remote = _cloud.ItemById(a.Personal, ClipStore.SyncId(Guid.Parse(secret.Id)));
        Assert.Equal(ClipStore.SyncId(folder.Id), OpenPayload(a, remote)["folder"]!.GetValue<string>());
        await b.Sync();
        var onB = b.Vault.Secrets.Single(s => s.Name == "api");
        Assert.Equal(folder.Id, b.Store.SecretFolderId(onB.Id));
        var panel = Panel(b);
        panel.SetFilter(PanelFilter.Labelled);
        Assert.Equal(1, Assert.IsType<PanelEntry.FolderEntry>(Assert.Single(panel.Entries)).Count);

        // Out again on B reaches A.
        b.Store.SetSecretFolder(onB.Id, null);
        await b.Sync();
        await a.Sync();
        Assert.Null(a.Store.SecretFolderId(secret.Id));

        // A group's secret, in a group folder, reaches a member and shows in the group's Saved.
        var c = await SignedUp("friend@example.com");
        Assert.True(await a.Account.CreateGroupAsync("Team"));
        var group = a.Account.Groups.Single();
        await Invite(a, c, group.Id);
        var groupFolder = a.Store.CreateFolder("Ops", group.Id);
        var groupSecret = a.Vault.Add("db", "pw", group.Id)!;
        a.Store.SetSecretFolder(groupSecret.Id, groupFolder.Id);
        await a.Sync();
        await c.Sync();
        var onC = c.Vault.Secrets.Single(s => s.Name == "db");
        Assert.Equal((group.Id, (Guid?)groupFolder.Id), (onC.SpaceId, c.Store.SecretFolderId(onC.Id)));
        var member = Panel(c);
        member.SetGroupFilter(group.Id);
        member.SetGroupShowsSaved(true);
        var ops = Assert.IsType<PanelEntry.FolderEntry>(Assert.Single(member.Entries));
        Assert.Equal(1, ops.Count);
        member.Activate(ops);
        Assert.Equal("db", Assert.IsType<PanelEntry.SecretEntry>(Assert.Single(member.Entries)).Secret.Name);
    }
}
