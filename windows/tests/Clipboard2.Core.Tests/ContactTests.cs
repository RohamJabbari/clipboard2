using System.Security.Cryptography;
using Clipboard2.Core.Sync;

namespace Clipboard2.Core.Tests;

/// <summary>Contacts and the Inbox (docs/sync/PROTOCOL.md → Contacts) against <see cref="FakeCloud"/>.</summary>
public sealed partial class SyncEngineTests
{
    private const string Friend = "friend@example.com";

    /// <summary>a (roham) asks b (friend), b accepts, and both have synced since.</summary>
    private async Task<(Device A, Device B, string Space)> Contacts()
    {
        var a = await SignedUp();
        var b = await SignedUp(Friend);
        Assert.True(await a.Account.RequestContactAsync("friend"), a.Account.Error);
        await b.Account.RefreshContactsAsync();
        Assert.True(await b.Account.AcceptContactAsync(Assert.Single(b.Account.IncomingRequests)), b.Account.Error);
        await b.Sync();
        await a.Sync();
        var space = Assert.Single(a.Account.Contacts).Id;
        return (a, b, space);
    }

    private static List<PanelEntry> Inbox(Device d)
    {
        var panel = Panel(d);
        panel.SetFilter(PanelFilter.Inbox);
        return panel.Entries;
    }

    private static void Send(Device d, ClipItem item, string space)
    {
        var panel = Panel(d);
        panel.Select(new PanelEntry.Clip(item).Id);
        var send = Assert.Single(panel.AvailableActions.OfType<PanelAction.SendToContact>(), s => s.SpaceId == space);
        panel.Perform(send);
    }

    [Fact]
    public async Task SpacesAreListedWithDirectOnes()
    {
        var a = await SignedUp();
        Assert.NotEmpty(_cloud.SpacesQueries);
        Assert.All(_cloud.SpacesQueries, q => Assert.Equal("?include=direct", q));
        Assert.Empty(a.Account.Contacts);
    }

    [Fact]
    public async Task ARequestWrapsTheKeyToTheRecipientAndWaitsForAccept()
    {
        var a = await SignedUp();
        var b = await SignedUp(Friend);
        Assert.True(await a.Account.RequestContactAsync(" @Friend "), a.Account.Error);
        Assert.Equal("Request sent to friend.", a.Account.Status);
        var outgoing = Assert.Single(a.Account.OutgoingRequests);
        Assert.Equal(("friend", b.Account.Uid), (outgoing.Name, outgoing.Uid));

        // SK is wrapped to b's public key with b's uid in the AAD; it opens for b only.
        var wrapped = _cloud.RecipientWrappedKey(outgoing.SpaceId);
        var key = SyncCrypto.UnwrapSpaceKey(wrapped, outgoing.SpaceId, b.Account.Uid!, b.Account.Engine!.Identity.Keys);
        Assert.Equal(32, key.Length);
        Assert.ThrowsAny<CryptographicException>(() => SyncCrypto.UnwrapSpaceKey(wrapped, outgoing.SpaceId, a.Account.Uid!, b.Account.Engine!.Identity.Keys));
        Assert.ThrowsAny<CryptographicException>(() => SyncCrypto.UnwrapSpaceKey(wrapped, Guid.NewGuid().ToString("D"), b.Account.Uid!, b.Account.Engine!.Identity.Keys));

        // Pending: not a contact on either side, and nothing can be sent yet.
        await a.Sync();
        await b.Account.RefreshContactsAsync();
        Assert.Empty(a.Account.Contacts);
        Assert.Empty(b.Account.Contacts);
        var incoming = Assert.Single(b.Account.IncomingRequests);
        Assert.Equal(("roham", a.Account.Uid), (incoming.Name, incoming.Uid));
        var early = a.Copy("too early");
        var panel = Panel(a);
        panel.Select(new PanelEntry.Clip(early).Id);
        Assert.DoesNotContain(panel.AvailableActions, x => x is PanelAction.SendToContact);

        Assert.True(await b.Account.AcceptContactAsync(incoming), b.Account.Error);
        Assert.Equal("roham is now a contact.", b.Account.Status);
        Assert.Empty(b.Account.IncomingRequests);
        Assert.Equal("roham", Assert.Single(b.Account.Contacts).DisplayName);
        await a.Sync();
        await a.Account.RefreshContactsAsync();
        Assert.Equal("friend", Assert.Single(a.Account.Contacts).DisplayName);
        Assert.Empty(a.Account.OutgoingRequests);
        // The requester's key was pinned when asking, and the space's key matches it.
        Assert.Equal(SpaceKeyPins.Hash(key), a.Keys.Read("sync/space-pin/" + outgoing.SpaceId));
        Assert.Equal(key, a.Account.Engine!.Space(outgoing.SpaceId)!.Key);
    }

    [Fact]
    public async Task RequestsExplainWhatWentWrong()
    {
        var a = await SignedUp();
        var b = await SignedUp(Friend);
        Assert.False(await a.Account.RequestContactAsync("nobody"));
        Assert.Contains("Nobody has the username “nobody”", a.Account.Error);
        Assert.False(await a.Account.RequestContactAsync("ROHAM"));
        Assert.Contains("your own username", a.Account.Error);
        Assert.False(await a.Account.RequestContactAsync("no spaces"));
        Assert.Contains("isn't a username", a.Account.Error);
        Assert.True(await a.Account.RequestContactAsync("friend"));
        Assert.False(await a.Account.RequestContactAsync("friend"));
        Assert.Contains("already contacts, or one of you has asked already", a.Account.Error);
        Assert.False(await b.Account.RequestContactAsync("roham"));   // the other way round counts too
        Assert.Contains("already contacts, or one of you has asked already", b.Account.Error);

        _cloud.MaxContacts = 1;
        var c = await SignedUp("third@example.com");
        Assert.False(await c.Account.RequestContactAsync("friend"));
        Assert.Equal("friend can't take more contacts right now.", c.Account.Error);
        Assert.False(await a.Account.RequestContactAsync("third"));
        Assert.Contains("contact limit", a.Account.Error);
        Assert.Equal(1, _cloud.PendingContactRequests);
    }

    [Fact]
    public async Task RequestsCanBeDeclinedAndCancelled()
    {
        var a = await SignedUp();
        var b = await SignedUp(Friend);
        Assert.True(await a.Account.RequestContactAsync("friend"));
        var spaceId = Assert.Single(a.Account.OutgoingRequests).SpaceId;
        await b.Account.RefreshContactsAsync();
        Assert.True(await b.Account.DeclineContactAsync(Assert.Single(b.Account.IncomingRequests)), b.Account.Error);
        Assert.False(_cloud.SpaceExists(spaceId));
        await a.Account.RefreshContactsAsync();
        Assert.Empty(a.Account.OutgoingRequests);

        Assert.True(await a.Account.RequestContactAsync("friend"));
        var again = Assert.Single(a.Account.OutgoingRequests);
        Assert.NotNull(a.Keys.Read("sync/space-pin/" + again.SpaceId));
        Assert.True(await a.Account.CancelContactRequestAsync(again), a.Account.Error);
        Assert.Null(a.Keys.Read("sync/space-pin/" + again.SpaceId));
        Assert.Empty(a.Account.OutgoingRequests);
        await b.Account.RefreshContactsAsync();
        Assert.Empty(b.Account.IncomingRequests);
    }

    [Fact]
    public async Task NewIncomingRequestsAreAnnouncedOnce()
    {
        var a = await SignedUp();
        var b = await SignedUp(Friend);   // its first look (in its first sync) found nothing
        var c = await SignedUp("third@example.com");
        var announced = new List<string>();
        b.Account.ContactRequested += r => announced.Add(r.Name);
        Assert.True(await a.Account.RequestContactAsync("friend"));
        await b.Account.RefreshContactsAsync();
        await b.Account.RefreshContactsAsync();
        Assert.Equal(["roham"], announced);

        // Another device signing in finds both pending: nothing is announced there.
        Assert.True(await c.Account.RequestContactAsync("friend"));
        var b2 = NewDevice();
        var onB2 = new List<string>();
        b2.Account.ContactRequested += r => onB2.Add(r.Name);
        Assert.True(await b2.Account.SignInAsync(Friend, Password));
        await b2.Sync();
        await b2.Account.RefreshContactsAsync();
        Assert.Empty(onB2);
        Assert.Equal(2, b2.Account.IncomingRequests.Count);
        await b.Account.RefreshContactsAsync();
        Assert.Equal(["roham", "third"], announced);
    }

    [Fact]
    public async Task ACodeAddsWhoeverEntersIt()
    {
        var a = await SignedUp();
        var b = await SignedUp(Friend);
        var code = await a.Account.CreateContactCodeAsync();
        Assert.NotNull(code);
        var open = Assert.Single(a.Account.ContactCodes);
        Assert.Equal(SyncCrypto.InviteId(InviteCode.Parse(code)!), open.InviteId);

        Assert.Null(await a.Account.PreviewInviteAsync("garbage"));
        var own = await a.Account.PreviewInviteAsync(code);
        Assert.True(own!.IsContact);
        Assert.False(await a.Account.JoinAsync(own));
        Assert.Contains("your own contact code", a.Account.Error);

        var preview = await b.Account.PreviewInviteAsync(code.ToLowerInvariant());
        Assert.True(preview!.IsContact);
        Assert.Equal("roham", preview.Name);
        Assert.True(await b.Account.JoinAsync(preview), b.Account.Error);
        Assert.Equal("roham is now a contact.", b.Account.Status);
        Assert.Equal("roham", Assert.Single(b.Account.Contacts).DisplayName);
        Assert.Null(b.Settings.DefaultGroupId);   // a contact is never the default group
        Assert.Null(await b.Account.PreviewInviteAsync(code));   // single use

        await a.Sync();
        await a.Account.RefreshContactsAsync();
        Assert.Equal("friend", Assert.Single(a.Account.Contacts).DisplayName);
        Assert.Empty(a.Account.ContactCodes);
        Assert.Empty(a.Account.Groups);

        // A second code to the same person: the pair is taken.
        var second = await a.Account.CreateContactCodeAsync();
        var again = await b.Account.PreviewInviteAsync(second!);
        Assert.False(await b.Account.JoinAsync(again!));
        Assert.Contains("already contacts", b.Account.Error);

        // Revoking deletes the code and its empty space.
        await a.Account.RefreshContactsAsync();
        var pending = Assert.Single(a.Account.ContactCodes);
        Assert.True(await a.Account.RevokeContactCodeAsync(pending), a.Account.Error);
        Assert.Empty(a.Account.ContactCodes);
        Assert.False(_cloud.SpaceExists(pending.SpaceId));
        Assert.Null(a.Keys.Read("sync/space-pin/" + pending.SpaceId));
    }

    [Fact]
    public async Task SentItemsArriveInTheInboxWithTheirSender()
    {
        var (a, b, space) = await Contacts();
        var arrived = new List<(string Text, string From)>();
        b.Account.ReceivedFromContact += (item, from) => arrived.Add((item.Text, from));

        var item = a.Copy("for you");
        a.Store.SetLabel("mine", a.Store.Find(item.Id)!);
        Send(a, a.Store.Find(item.Id)!, space);
        await a.Sync();
        var sent = Assert.Single(_cloud.LiveItems(space));
        Assert.Equal(a.Account.Uid, sent.Author);

        await b.Sync();
        Assert.Equal([("for you", "roham")], arrived);
        var entry = Assert.Single(Inbox(b));
        Assert.Equal("for you", entry.ClipItem!.Text);
        Assert.Null(entry.ClipItem.Label);   // the sender's label stays theirs
        Assert.False(entry.ClipItem.IsPinned);
        var panel = Panel(b);
        Assert.Equal("roham", panel.SenderName(entry));
        Assert.Null(panel.GroupBadge(entry));
        Assert.Null(panel.GroupName(entry));
        Assert.DoesNotContain(panel.Entries, e => e.ClipItem?.SpaceId == space);   // All: only the Inbox lists it
        Assert.Contains(PanelFilter.Inbox, panel.ChipFilters);

        // The sender's copy isn't in their own Inbox, nor listed twice in All.
        Assert.Empty(Inbox(a));
        Assert.Single(Panel(a).Entries, e => e.ClipItem?.Text == "for you");
        Assert.Null(Panel(a).SenderName(new PanelEntry.Clip(a.Store.ItemsInSpace(space).Single())));

        // Newest first; replies go the other way.
        Send(b, b.Copy("thanks"), space);
        await b.Sync();
        Send(a, a.Copy("second"), space);
        await a.Sync();
        await b.Sync();
        Assert.Equal(["second", "for you"], Inbox(b).Select(e => e.ClipItem!.Text));
        Assert.Equal(["thanks"], Inbox(a).Select(e => e.ClipItem!.Text));
        Assert.Equal(["for you", "second"], arrived.Select(x => x.Text));
    }

    [Fact]
    public async Task FilesSentToAContactArriveAsFiles()
    {
        var (a, b, space) = await Contacts();
        var path = Path.Combine(a.Dir, "report.pdf");
        Directory.CreateDirectory(a.Dir);
        File.WriteAllBytes(path, [1, 2, 3, 4]);
        var item = a.Store.Ingest(ProcessedCapture.ForFiles([path]));
        Send(a, item, space);
        await a.Sync();
        await b.Sync();
        var received = Assert.Single(Inbox(b)).ClipItem!;
        Assert.Equal(ClipKind.File, received.Kind);
        Assert.Equal(new byte[] { 1, 2, 3, 4 }, File.ReadAllBytes(Assert.Single(received.Files)));
    }

    [Fact]
    public async Task SendingRefusesFilesTooLargeLikeGroups()
    {
        var (a, _, space) = await Contacts();
        var folder = Path.Combine(a.Dir, "many");
        Directory.CreateDirectory(folder);
        var files = Enumerable.Range(0, SyncEngine.MaxFilesPerItem + 1).Select(n =>
        {
            var file = Path.Combine(folder, $"f{n}.txt");
            File.WriteAllText(file, "x");
            return file;
        }).ToList();
        var item = a.Store.Ingest(ProcessedCapture.ForFiles(files));
        var panel = Panel(a);
        panel.Select(new PanelEntry.Clip(item).Id);
        panel.Perform(new PanelAction.SendToContact(space, "friend"));
        Assert.Equal($"Sync takes at most {SyncEngine.MaxFilesPerItem} files at a time.", panel.Notice);
        Assert.Empty(a.Store.ItemsInSpace(space));
    }

    [Fact]
    public async Task MultipleSelectedItemsAreSentTogether()
    {
        var (a, b, space) = await Contacts();
        a.Copy("one", 2);
        a.Copy("two", 1);
        var panel = Panel(a);
        panel.SelectAll();
        var send = Assert.Single(panel.AvailableActions.OfType<PanelAction.SendToContact>());
        Assert.Equal("Send to friend", send.Title);
        panel.Perform(send);
        Assert.Equal("Sent 2 items to friend", panel.Notice);
        await a.Sync();
        await b.Sync();
        Assert.Equal(["one", "two"], Inbox(b).Select(e => e.ClipItem!.Text).Order());
    }

    [Fact]
    public async Task EitherPersonCanDeleteAnItemAndEditsStayLocal()
    {
        var (a, b, space) = await Contacts();
        Send(a, a.Copy("delete me"), space);
        Send(a, a.Copy("label me"), space);
        await a.Sync();
        await b.Sync();

        // A label on something received stays here: it would make the item b's on the server.
        var labelled = Inbox(b).Single(e => e.ClipItem!.Text == "label me").ClipItem!;
        b.Store.SetLabel("keep", labelled);
        var puts = _cloud.Count($"PUT api.fake/v1/spaces/{space}/items");
        await b.Sync();
        Assert.Equal(puts, _cloud.Count($"PUT api.fake/v1/spaces/{space}/items"));
        Assert.All(_cloud.LiveItems(space), i => Assert.Equal(a.Account.Uid, i.Author));
        Assert.Contains(Inbox(b), e => e.ClipItem!.Text == "label me");
        Assert.Empty(b.Account.Warnings);

        // Deleting from the Inbox deletes it for both.
        var doomed = Inbox(b).Single(e => e.ClipItem!.Text == "delete me");
        var panel = Panel(b);
        panel.SetFilter(PanelFilter.Inbox);
        panel.Select(doomed.Id);
        panel.Perform(new PanelAction.Delete());
        await b.Sync();
        Assert.DoesNotContain(_cloud.LiveItems(space), i => i.Id == ClipStore.SyncId(doomed.ClipItem!.Id));
        await a.Sync();
        Assert.DoesNotContain(a.Store.ItemsInSpace(space), i => i.Text == "delete me");
    }

    [Fact]
    public async Task RemovingAContactDeletesEverythingForBoth()
    {
        var (a, b, space) = await Contacts();
        Send(a, a.Copy("from a"), space);
        await a.Sync();
        Send(b, b.Copy("from b"), space);
        await b.Sync();
        await a.Sync();
        Assert.Equal(2, a.Store.ItemsInSpace(space).Count);

        Assert.True(await b.Account.RemoveContactAsync(space), b.Account.Error);
        Assert.Empty(b.Account.Contacts);
        Assert.Empty(b.Store.ItemsInSpace(space));
        Assert.Null(b.Keys.Read("sync/space-pin/" + space));
        Assert.False(_cloud.SpaceExists(space));
        Assert.DoesNotContain(PanelFilter.Inbox, Panel(b).ChipFilters);

        await a.Sync();
        Assert.Empty(a.Account.Contacts);
        Assert.Empty(a.Store.ItemsInSpace(space));
        Assert.Single(a.Store.ItemsInSpace(null));   // the personal original stays

        // They can be added again.
        Assert.True(await a.Account.RequestContactAsync("friend"), a.Account.Error);
    }

    [Fact]
    public async Task AChangedContactKeySaysToRemoveAndAddThemAgain()
    {
        var (a, b, space) = await Contacts();
        var evil = SyncCrypto.WrapSpaceKey(SyncCrypto.RandomKey(), space, b.Account.Uid!, _cloud.PublicKey(Friend));
        _cloud.ReplaceWrappedKey(space, b.Account.Uid!, evil);
        Send(a, a.Copy("after"), space);
        await a.Sync();
        await b.Sync();
        Assert.Equal("The key you share with roham changed unexpectedly, so what you send each other isn't syncing. Remove the contact and add them again.",
            b.Account.Error);
        Assert.Empty(b.Store.ItemsInSpace(space));
    }

    [Fact]
    public async Task OldItemsAreNotAnnouncedAfterSigningIn()
    {
        var (a, b, space) = await Contacts();
        Send(a, a.Copy("old news"), space);
        await a.Sync();
        await b.Sync();

        var b2 = NewDevice();
        var arrived = new List<string>();
        b2.Account.ReceivedFromContact += (item, _) => arrived.Add(item.Text);
        Assert.True(await b2.Account.SignInAsync(Friend, Password), b2.Account.Error);
        await b2.Sync();
        Assert.Equal("old news", Assert.Single(Inbox(b2)).ClipItem!.Text);
        Assert.Empty(arrived);

        Send(a, a.Copy("fresh"), space);
        await a.Sync();
        await b2.Sync();
        Assert.Equal(["fresh"], arrived);
    }

    [Fact]
    public async Task ItemsSentFromAnotherOwnDeviceAreNotInTheInbox()
    {
        var (a, b, space) = await Contacts();
        var a2 = await SignedIn();
        var arrived = 0;
        a.Account.ReceivedFromContact += (_, _) => arrived++;
        Send(a2, a2.Copy("from my laptop"), space);
        await a2.Sync();
        await a.Sync();
        Assert.Single(a.Store.ItemsInSpace(space));
        Assert.Empty(Inbox(a));
        Assert.Equal(0, arrived);
        await b.Sync();
        Assert.Single(Inbox(b));
    }

    [Fact]
    public async Task AServerWithoutContactsIsToldApart()
    {
        _cloud.NoContacts = true;
        var a = await SignedUp();
        await SignedUp(Friend);
        await a.Account.RefreshContactsAsync();
        Assert.False(a.Account.ContactsSupported);
        Assert.False(await a.Account.RequestContactAsync("friend"));
        Assert.Equal("The sync server doesn't support contacts yet.", a.Account.Error);
    }

    [Fact]
    public void ContactNoticesAreShortAndCoalesced()
    {
        Assert.Equal("anna sent you “hello”", ContactNotice.Title([("anna", "hello")]));
        Assert.Equal("anna sent you 3 items", ContactNotice.Title([("anna", "a"), ("anna", "b"), ("anna", "c")]));
        Assert.Equal("2 contacts sent you 3 items", ContactNotice.Title([("anna", "a"), ("ben", "b"), ("anna", "c")]));
        Assert.Equal($"anna sent you “{new string('x', 39)}…”", ContactNotice.Title([("anna", new string('x', 80))]));
        Assert.Equal("anna sent you “first line”", ContactNotice.Title([("anna", "first line\nsecond")]));
    }
}
