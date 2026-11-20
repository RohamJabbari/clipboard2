namespace Clipboard2.Core.Tests;

/// <summary>Notifications from real syncs against <see cref="FakeCloud"/>.</summary>
public sealed partial class SyncEngineTests
{
    private static List<AppNotification> Listen(Device d)
    {
        var found = new List<AppNotification>();
        d.Account.Notifications += found.AddRange;
        return found;
    }

    [Fact]
    public async Task GroupActivityIsNotifiedToOthersButNeverToTheAuthorsDevices()
    {
        var a = await SignedUp();
        var a2 = await SignedIn();
        var b = await SignedUp(Friend);
        Assert.True(await a.Account.CreateGroupAsync("Team"));
        var group = a.Account.Groups.Single();
        await a2.Sync();
        var onA2 = Listen(a2);
        var onB = Listen(b);

        // b joins: a2 (the same person as the owner) hears it, after the join's own sync.
        var preview = await b.Account.PreviewInviteAsync((await a.Account.CreateInviteAsync(group.Id))!);
        Assert.True(await b.Account.JoinAsync(preview!), b.Account.Error);
        await b.Sync();
        Assert.Empty(onB);   // joining pulls what was there: nothing announced
        await a2.Sync();
        Assert.Equal([("Team", "friend joined")], onA2.Select(n => (n.Title, n.Body)));

        // a shares two items: b hears "roham shared 2 items" once; a's other device hears nothing.
        onA2.Clear();
        a.Store.CopyToSpace(a.Copy("one", 2), group.Id);
        a.Store.CopyToSpace(a.Copy("two", 1), group.Id);
        await a.Sync();
        await b.Sync();
        await a2.Sync();
        var shared = Assert.Single(onB);
        Assert.Equal((NotificationKind.GroupActivity, "Team", "roham shared 2 items"), (shared.Kind, shared.Title, shared.Body));
        Assert.Equal(group.Id, ((NotificationTarget.Group)shared.Target!).SpaceId);
        Assert.Empty(onA2);

        // The owner renames it (no one hears their own rename), then deletes it.
        Assert.True(await a.Account.RenameGroupAsync(group.Id, "Crew"));
        await a2.Sync();
        await b.Sync();
        Assert.Empty(onA2);
        Assert.Equal(("Crew", "Team was renamed"), (onB[^1].Title, onB[^1].Body));
        Assert.True(await a.Account.DeleteGroupAsync(group.Id));
        await b.Sync();
        await a2.Sync();
        Assert.Equal(("Crew", "You're no longer in this group"), (onB[^1].Title, onB[^1].Body));
        Assert.Empty(onA2);
    }

    [Fact]
    public async Task ContactActivityIsNotifiedButNotTheFirstSyncAfterSigningIn()
    {
        var a = await SignedUp();
        var b = await SignedUp(Friend);
        var onA = Listen(a);
        var onB = Listen(b);
        Assert.True(await a.Account.RequestContactAsync("friend"));
        await b.Account.RefreshContactsAsync();   // a tick looks once a minute
        await b.Sync();
        Assert.Equal([("Contact request", "roham wants to add you")], onB.Select(n => (n.Title, n.Body)));

        Assert.True(await b.Account.AcceptContactAsync(Assert.Single(b.Account.IncomingRequests)));
        await b.Sync();
        await a.Sync();
        Assert.Equal([("friend", "is now your contact")], onA.Select(n => (n.Title, n.Body)));
        Assert.Single(onB);   // accepting isn't announced to the one who accepted

        var space = Assert.Single(a.Account.Contacts).Id;
        Send(a, a.Copy("hello"), space);
        await a.Sync();
        await b.Sync();
        Assert.Equal(("roham", "sent “hello”"), (onB[^1].Title, onB[^1].Body));

        // Another device signing in records what's there.
        var b2 = NewDevice();
        var onB2 = Listen(b2);
        Assert.True(await b2.Account.SignInAsync(Friend, Password));
        await b2.Sync();
        await b2.Sync();
        Assert.Empty(onB2);
    }
}
