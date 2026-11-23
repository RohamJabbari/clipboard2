using Clipboard2.Core.Sync;

namespace Clipboard2.Core.Tests;

/// <summary>Per-member Send and Secrets in groups (docs/features/member-access.md), against <see cref="FakeCloud"/>.</summary>
public sealed partial class SyncEngineTests
{
    /// <summary>a owns "Team", b is a member.</summary>
    private async Task<(Device Owner, Device Member, string Group)> TeamWithMember()
    {
        var a = await SignedUp();
        var b = await SignedUp(Friend);
        Assert.True(await a.Account.CreateGroupAsync("Team"));
        var group = a.Account.Groups.Single().Id;
        await Invite(a, b, group);
        await a.Sync();
        await b.Sync();
        return (a, b, group);
    }

    [Fact]
    public async Task TheOwnerChangesAMembersAccessAndTheListShowsIt()
    {
        var (a, b, group) = await TeamWithMember();
        var members = await a.Account.MembersAsync(group);
        Assert.All(members, m => Assert.True(m.CanSend && m.CanSeeSecrets));
        var friend = members.Single(m => !m.IsOwner);

        var (changed, error) = await a.Account.SetMemberAccessAsync(group, friend.Uid, canSend: false);
        Assert.Null(error);
        Assert.Equal((friend.Uid, false, true), (changed!.Uid, changed.CanSend, changed.CanSeeSecrets));
        (changed, _) = await a.Account.SetMemberAccessAsync(group, friend.Uid, canSeeSecrets: false);
        Assert.Equal((false, false), (changed!.CanSend, changed.CanSeeSecrets));
        Assert.Equal((false, false), _cloud.AccessOf(group, friend.Uid));
        var listed = (await a.Account.MembersAsync(group)).Single(m => m.Uid == friend.Uid);
        Assert.Equal((false, false), (listed.CanSend, listed.CanSeeSecrets));

        // Only the owner changes access, and never their own.
        var (none, refused) = await b.Account.SetMemberAccessAsync(group, friend.Uid, canSend: true);
        Assert.Null(none);
        Assert.Equal("Only the group's owner can change what members may do.", refused);
        (none, refused) = await a.Account.SetMemberAccessAsync(group, a.Account.Uid!, canSend: false);
        Assert.Null(none);
        Assert.NotNull(refused);
        Assert.Equal((true, true), _cloud.AccessOf(group, a.Account.Uid!));
        Assert.Null(a.Account.Error);   // the sync status isn't touched
    }

    [Fact]
    public async Task WithoutSendNothingIsOfferedOrSentButTheGroupStillReads()
    {
        var (a, b, group) = await TeamWithMember();
        var onB = Listen(b);
        var mine = b.Copy("b's own");
        Assert.True((await a.Account.SetMemberAccessAsync(group, b.Account.Uid!, canSend: false)).Member is not null);
        a.Copy("from the owner", 0, group);
        var docs = a.Store.CreateFolder("Docs", group, null);
        await a.Sync();
        await b.Sync();

        var team = b.Account.Groups.Single();
        Assert.False(team.CanSend);
        Assert.True(team.CanSeeSecrets);
        Assert.Contains(b.Store.ItemsInSpace(group), i => i.Text == "from the owner");   // reading works
        Assert.Equal([("Team", "You can no longer send")], onB.Where(n => n.Kind == NotificationKind.GroupMembers).Select(n => (n.Title, n.Body)));

        var panel = Panel(b);
        Assert.False(panel.CanSendTo(group));
        panel.Select("c-" + mine.Id);
        Assert.DoesNotContain(panel.AvailableActions, x => x is PanelAction.ShareToGroup);
        var owners = b.Store.ItemsInSpace(group).Single();
        Assert.False(panel.CanChange(owners));
        panel.SetGroupFilter(group);
        panel.SetGroupShowsSaved(true);
        Assert.False(panel.CanAddItems);
        Assert.False(panel.CanCreateFolder);
        panel.CreateFolder();
        Assert.Equal([docs.Id], b.Store.FoldersInSpace(group).Select(f => f.Id));
        // Its folders are only opened (and its items saved as personal copies), never filled or changed.
        panel.Select("f-" + docs.Id);
        Assert.Equal([typeof(PanelAction.OpenFolder), typeof(PanelAction.DeleteFolder)],
            panel.AvailableActions.Where(x => x is not PanelAction.SendToContactPicker).Select(x => x.GetType()));
        Assert.All(panel.FolderChoices([new PanelEntry.Clip(owners)]), x => Assert.Equal("Mine", x.Section(panel.AIName)));
        Assert.Equal([("Mine", (string?)null, true)], panel.FolderMenuSections([new PanelEntry.Clip(owners)]));
        Assert.False(panel.CanDrop("c-" + owners.Id, docs.Id));

        // A drop (or anything else) that still gets an item in goes nowhere: no write is even tried.
        var puts = _cloud.Count("PUT api.fake");
        b.Copy("sneaked in", 0, group);
        await b.Sync();
        Assert.Equal(puts, _cloud.Count("PUT api.fake"));
        Assert.DoesNotContain(_cloud.LiveItems(group), i => i.Author == b.Account.Uid);
        Assert.Null(b.Account.Error);

        // Send comes back: what waited goes up, and b hears about it.
        Assert.Null((await a.Account.SetMemberAccessAsync(group, b.Account.Uid!, canSend: true)).Error);
        await b.Sync();
        Assert.True(b.Account.Groups.Single().CanSend);
        Assert.Contains(_cloud.LiveItems(group), i => i.Author == b.Account.Uid);
        Assert.Equal(("Team", "You can send again"), (onB[^1].Title, onB[^1].Body));
        panel.Refresh();
        Assert.True(panel.CanAddItems);
    }

    [Fact]
    public async Task ARefusedSendIsAWarningNotAFailure()
    {
        var (_, b, group) = await TeamWithMember();
        b.Copy("one", 1, group);
        b.Copy("two", 0, group);
        // The owner turns Send off while b's list of groups still says it's on.
        _cloud.SetAccess(group, b.Account.Uid!, send: false);
        _cloud.StaleAccessInSpaces = true;
        var puts = _cloud.Count("PUT api.fake");
        await b.Sync();
        Assert.Null(b.Account.Error);
        Assert.Equal(["You can't send to Team."], b.Account.Warnings);
        Assert.Equal(puts + 1, _cloud.Count("PUT api.fake"));   // the first refusal stops the rest
        Assert.Empty(_cloud.LiveItems(group));

        // The next look says Send is off: nothing is tried, nothing to warn about.
        _cloud.StaleAccessInSpaces = false;
        await b.Sync();
        Assert.Empty(b.Account.Warnings);
        Assert.Equal(puts + 1, _cloud.Count("PUT api.fake"));

        _cloud.SetAccess(group, b.Account.Uid!, send: true);
        await b.Sync();
        Assert.Equal(2, _cloud.LiveItems(group).Count);
    }

    [Fact]
    public async Task WithoutSecretsAGroupsSecretsLeaveThisDeviceAndComeBackLater()
    {
        var (a, b, group) = await TeamWithMember();
        var onB = Listen(b);
        a.Vault.Add("Wi-Fi", "hunter2", group);
        await a.Sync();
        await b.Sync();
        var shared = Assert.Single(b.Vault.Secrets, s => s.SpaceId == group);
        var personal = b.Vault.Add("Mine", "only mine")!;
        onB.Clear();

        Assert.Null((await a.Account.SetMemberAccessAsync(group, b.Account.Uid!, canSeeSecrets: false)).Error);
        a.Vault.Add("Door", "1234", group);
        await a.Sync();
        await b.Sync();
        Assert.False(b.Account.Groups.Single().CanSeeSecrets);
        Assert.DoesNotContain(b.Vault.Secrets, s => s.SpaceId == group);
        Assert.Contains(b.Vault.Secrets, s => s.Id == personal.Id);
        Assert.Equal(2, _cloud.LiveItems(group).Count(i => i.Category == "secret"));   // nothing deleted on the server
        Assert.Equal([("Team", "You can no longer see secrets")], onB.Select(n => (n.Title, n.Body)));
        await b.Sync();
        Assert.Equal(2, _cloud.LiveItems(group).Count(i => i.Category == "secret"));

        // Sending works, but not secrets: Share to Group isn't offered for a secret.
        var panel = Panel(b);
        panel.SetFilter(PanelFilter.Labelled);
        panel.Select("k-" + personal.Id);
        Assert.DoesNotContain(panel.AvailableActions, x => x is PanelAction.ShareToGroup);
        panel.SetGroupFilter(group);
        panel.SetGroupShowsSaved(true);
        Assert.DoesNotContain(panel.Entries, e => e is PanelEntry.SecretEntry);

        // Back on: the group is pulled again from the start and both secrets return, quietly.
        Assert.Null((await a.Account.SetMemberAccessAsync(group, b.Account.Uid!, canSeeSecrets: true)).Error);
        onB.Clear();
        await b.Sync();
        Assert.True(b.Account.Groups.Single().CanSeeSecrets);
        Assert.Equal(["Door", "Wi-Fi"], b.Vault.Secrets.Where(s => s.SpaceId == group).Select(s => s.Name).Order());
        Assert.Contains(b.Vault.Secrets, s => s.Id == shared.Id);
        Assert.Equal([("Team", "You can see secrets again")], onB.Select(n => (n.Title, n.Body)));
    }

    [Fact]
    public async Task AnOlderServerWithoutMemberAccessBehavesAsBefore()
    {
        _cloud.NoMemberAccess = true;
        var (a, b, group) = await TeamWithMember();
        var team = b.Account.Groups.Single();
        Assert.True(team.CanSend && team.CanSeeSecrets);
        var friend = (await a.Account.MembersAsync(group)).Single(m => !m.IsOwner);
        Assert.True(friend.CanSend && friend.CanSeeSecrets);
        var (member, error) = await a.Account.SetMemberAccessAsync(group, friend.Uid, canSend: false);
        Assert.Null(member);
        Assert.NotNull(error);
        b.Copy("still sent", 0, group);
        await b.Sync();
        Assert.Contains(_cloud.LiveItems(group), i => i.Author == b.Account.Uid);
    }

    [Fact]
    public void AccessIsStoredWithTheSpaceAndTriggersNotifications()
    {
        using var store = new ClipStore(":memory:", new BlobStore(Path.Combine(Path.GetTempPath(), "c2acc-" + Guid.NewGuid())));
        var open = new SpaceRecord("g1", SpaceKinds.Group, "member", "Team", "owner", 2);
        var closed = open with { CanSend = false, CanSeeSecrets = false };
        store.SaveSyncSpaces([closed]);
        Assert.Equal(closed, store.SyncSpaces().Single());
        Assert.NotEqual(open, closed);

        var detector = new ActivityDetector();
        detector.Observe(new SyncSnapshot("me", [open], null, [], []), []);
        var notes = detector.Observe(new SyncSnapshot("me", [closed], null, [], []), []);
        Assert.Equal(["You can no longer send", "You can no longer see secrets"], notes.Select(n => n.Body));
        Assert.All(notes, n => Assert.Equal((NotificationKind.GroupMembers, "Team", "g1"), (n.Kind, n.Title, n.GroupId)));
        notes = detector.Observe(new SyncSnapshot("me", [open with { CanSeeSecrets = false }], null, [], []), []);
        Assert.Equal(["You can send again"], notes.Select(n => n.Body));
    }
}
