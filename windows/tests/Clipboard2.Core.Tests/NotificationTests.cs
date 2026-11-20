using Clipboard2.Core.Sync;

namespace Clipboard2.Core.Tests;

/// <summary>Notifications: what the detector finds between syncs, and what the dispatcher lets through
/// (docs/features/notifications-contacts.md).</summary>
public sealed class NotificationTests
{
    private const string Me = "me", Anna = "anna-uid", Ben = "ben-uid";
    private readonly ActivityDetector _detector = new();

    private static SpaceRecord Group(string id, string name, string owner = Anna, params (string Uid, string Name)[] members) =>
        new(id, SpaceKinds.Group, owner == Me ? "owner" : "member", name, owner, members.Length,
            members.ToDictionary(m => m.Uid, m => m.Name));

    private static SpaceRecord Contact(string id, string name, string uid, string owner) =>
        new(id, SpaceKinds.Direct, owner == Me ? "owner" : "member", name, owner, 2, new Dictionary<string, string> { [Me] = "me", [uid] = name });

    private static SyncSnapshot Snap(IEnumerable<SpaceRecord>? spaces = null, IEnumerable<ContactRequest>? requests = null,
                                     IEnumerable<SharedAuthenticator>? shared = null, IEnumerable<Authenticator>? owned = null) =>
        new(Me, [.. spaces ?? []], requests?.ToList(), [.. shared ?? []], [.. owned ?? []]);

    private static readonly (string, string)[] Team = [(Me, "me"), (Anna, "anna"), (Ben, "ben")];

    private static SyncArrival Text(string space, string author, string text) =>
        new(space, author, NotificationText.Describe(ClipItem.From(ProcessedCapture.ForText(text), DateTime.UtcNow)), "c-" + Guid.NewGuid());

    private static SharedAuthenticator Shared(string space, string owner, string issuer) =>
        new(space, Anna, owner, issuer, "me@example.com", 6, 30, 0, [], DateTime.UtcNow);

    private List<AppNotification> Observe(SyncSnapshot now, params SyncArrival[] arrivals) => _detector.Observe(now, arrivals);

    // MARK: Each event

    [Fact]
    public void GroupItemsSayWhoSharedWhatButNeverASecret()
    {
        var g = Group("g", "Team", Anna, Team);
        Observe(Snap([g]));
        var image = ClipItem.From(ProcessedCapture.ForText("x"), DateTime.UtcNow);
        image.Kind = ClipKind.Image;
        var file = ClipItem.From(ProcessedCapture.ForText("x"), DateTime.UtcNow);
        file.Kind = ClipKind.File;
        file.Files = [@"C:\Users\anna\report.pdf"];
        Assert.Equal("an image", NotificationText.Describe(image));
        Assert.Equal("report.pdf", NotificationText.Describe(file));

        var hello = Text("g", Anna, "hello\nsecond line");
        var n = Assert.Single(Observe(Snap([g]), hello));
        Assert.Equal((NotificationKind.GroupActivity, "Team", "anna shared “hello”"), (n.Kind, n.Title, n.Body));
        Assert.Equal(new NotificationTarget.Group("g", hello.EntryId), n.Target);
        Assert.Equal(("g", "group:g"), (n.GroupId, n.View));

        var secret = new SyncArrival("g", Ben, NotificationText.Secret, "k-1");
        Assert.Equal("ben shared a secret", Assert.Single(Observe(Snap([g]), secret)).Body);
    }

    [Fact]
    public void JoinsAndLeavesAreAnnounced()
    {
        Observe(Snap([Group("g", "Team", Anna, (Me, "me"), (Anna, "anna"))]));
        var joined = Assert.Single(Observe(Snap([Group("g", "Team", Anna, Team)])));
        Assert.Equal((NotificationKind.GroupMembers, "Team", "ben joined"), (joined.Kind, joined.Title, joined.Body));
        Assert.Equal(new NotificationTarget.Group("g"), joined.Target);

        var left = Assert.Single(Observe(Snap([Group("g", "Team", Anna, (Me, "me"), (Anna, "anna"))])));
        Assert.Equal("ben left", left.Body);
    }

    [Fact]
    public void BeingRemovedOrTheGroupDeletedSaysSoWithoutATarget()
    {
        Observe(Snap([Group("g", "Team", Anna, Team)]));
        var n = Assert.Single(Observe(Snap()));
        Assert.Equal(("Team", "You're no longer in this group"), (n.Title, n.Body));
        Assert.Null(n.Target);
    }

    [Fact]
    public void ARenameShowsTheNewNameAndTheOld()
    {
        Observe(Snap([Group("g", "Team", Anna, Team)]));
        var n = Assert.Single(Observe(Snap([Group("g", "Crew", Anna, Team)])));
        Assert.Equal((NotificationKind.GroupActivity, "Crew", "Team was renamed"), (n.Kind, n.Title, n.Body));
        Assert.Equal(new NotificationTarget.Group("g"), n.Target);
    }

    [Fact]
    public void ContactRequestsAcceptsAndItemsAreAnnounced()
    {
        Observe(Snap(requests: []));
        var request = new ContactRequest("d1", Anna, "anna", "anna", 0);
        var asked = Assert.Single(Observe(Snap(requests: [request])));
        Assert.Equal((NotificationKind.Contacts, "Contact request", "anna wants to add you"), (asked.Kind, asked.Title, asked.Body));
        Assert.IsType<NotificationTarget.People>(asked.Target);
        Assert.Empty(Observe(Snap(requests: [request])));   // once

        // Ben accepted this user's request (the space is this user's): announced.
        var accepted = Assert.Single(Observe(Snap([Contact("d2", "ben", Ben, Me)], requests: [request])));
        Assert.Equal(("ben", "is now your contact"), (accepted.Title, accepted.Body));

        var item = Text("d2", Ben, "hi there");
        var sent = Assert.Single(Observe(Snap([Contact("d2", "ben", Ben, Me)], requests: [request]), item));
        Assert.Equal((NotificationKind.Contacts, "ben", "sent “hi there”", "inbox"), (sent.Kind, sent.Title, sent.Body, sent.View));
        Assert.Equal(new NotificationTarget.Inbox(item.EntryId), sent.Target);
    }

    [Fact]
    public void AcceptingSomeonesRequestHereIsNotAnnounced()
    {
        Observe(Snap(requests: []));
        // Anna's request: the space is hers; this user (on any device) accepted it.
        Assert.Empty(Observe(Snap([Contact("d1", "anna", Anna, Anna)], requests: [])));
    }

    [Fact]
    public void SharedAuthenticatorsAndTransfersAreAnnounced()
    {
        Observe(Snap());
        var shared = Assert.Single(Observe(Snap(shared: [Shared("o1", "anna", "GitHub")])));
        Assert.Equal((NotificationKind.Authenticators, "anna", "shared GitHub codes with you"), (shared.Kind, shared.Title, shared.Body));
        Assert.Equal(new NotificationTarget.Saved("o-o1"), shared.Target);

        // Made the owner: the share goes, and (here a sync later) the authenticator is this user's.
        Assert.Empty(Observe(Snap()));
        var mine = new Authenticator("a1", "GitHub", "me@example.com", "JBSWY3DPEHPK3PXP", OtpAlgorithm.SHA1, 6, 30, DateTime.UtcNow, DateTime.UtcNow, "o1");
        var owner = Assert.Single(Observe(Snap(owned: [mine])));
        Assert.Equal(("anna", "made you the owner of GitHub"), (owner.Title, owner.Body));
        Assert.Equal(new NotificationTarget.Saved("a-a1"), owner.Target);

        // One this user made (here or on another device) isn't announced.
        var another = mine with { Id = "a2", SpaceId = "o2" };
        Assert.Empty(Observe(Snap(owned: [mine, another])));
    }

    // MARK: Batching

    [Fact]
    public void GroupItemsAreBatchedPerGroupAndAuthor()
    {
        var g = Group("g", "Team", Anna, Team);
        Observe(Snap([g]));
        var notes = Observe(Snap([g]), Text("g", Anna, "1"), Text("g", Anna, "2"), Text("g", Ben, "3"), Text("g", Anna, "4"), Text("g", Anna, "5"), Text("g", Anna, "6"));
        Assert.Equal(["anna shared 5 items", "ben shared “3”"], notes.Select(n => n.Body));
    }

    [Fact]
    public void ContactItemsAreBatchedPerContact()
    {
        var a = Contact("d1", "anna", Anna, Anna);
        var b = Contact("d2", "ben", Ben, Me);
        Observe(Snap([a, b]));
        var notes = Observe(Snap([a, b]), Text("d1", Anna, "1"), Text("d2", Ben, "2"), Text("d1", Anna, "3"));
        Assert.Equal([("anna", "sent 2 items"), ("ben", "sent “2”")], notes.Select(n => (n.Title, n.Body)));
    }

    // MARK: Suppression

    [Fact]
    public void TheFirstSyncAfterSignInOrResetOnlyRecords()
    {
        var g = Group("g", "Team", Anna, Team);
        Assert.Empty(Observe(Snap([g, Contact("d1", "anna", Anna, Me)], requests: [new("d9", Ben, "ben", "ben", 0)], shared: [Shared("o1", "anna", "X")]),
            Text("g", Anna, "old")));
        Assert.True(_detector.HasBaseline);
        _detector.Reset();
        Assert.Empty(Observe(Snap([Group("g", "Renamed", Anna, (Me, "me"))])));
    }

    [Fact]
    public void OwnActionsAreNeverAnnounced()
    {
        var mine = Group("g", "Team", Me, Team);
        Observe(Snap([mine, Group("h", "Other", Anna, Team)]));
        // Own items from another device; an owner's rename; a member removed here; a group left here.
        _detector.ExpectMemberRemoved("g", Ben);
        _detector.ExpectLeave("h");
        Assert.Empty(Observe(Snap([Group("g", "Renamed", Me, (Me, "me"), (Anna, "anna"))]), Text("g", Me, "from my laptop")));
        // The owner deleting the group (on any device).
        Assert.Empty(Observe(Snap()));
    }

    [Fact]
    public void ARestoredBaselineNoticesChangesWhileTheAppWasClosed()
    {
        _detector.Seed(Snap([Group("g", "Team", Anna, (Me, "me"))], requests: [new("d9", Ben, "ben", "ben", 0)]));
        var notes = Observe(Snap([Group("g", "Team", Anna, Team)], requests: [new("d9", Ben, "ben", "ben", 0)]));
        Assert.Equal(["anna and ben joined"], notes.Select(n => n.Body));   // the requests' first look only records
    }

    // MARK: Dispatching

    private sealed class FakeNotifier : ISystemNotifier
    {
        public bool IsAllowed { get; set; } = true;
        public List<AppNotification> Shown { get; } = [];
        public void Show(AppNotification notification) => Shown.Add(notification);
    }

    private static readonly AppNotification GroupItem = new(NotificationKind.GroupActivity, "Team", "anna shared “x”", new NotificationTarget.Group("g"), "g", "group:g");
    private static readonly AppNotification Joined = new(NotificationKind.GroupMembers, "Team", "ben joined", new NotificationTarget.Group("g"), "g");
    private static readonly AppNotification FromContact = new(NotificationKind.Contacts, "anna", "sent “x”", new NotificationTarget.Inbox(), View: "inbox");
    private static readonly AppNotification Codes = new(NotificationKind.Authenticators, "anna", "shared X codes with you", new NotificationTarget.Saved());

    [Fact]
    public void TheOpenPanelsViewMutesAndSwitchesAreApplied()
    {
        var settings = new Settings();
        var notifier = new FakeNotifier();
        var view = "";
        var hud = new List<AppNotification>();
        var dispatcher = new NotificationDispatcher(settings, notifier, v => v == view, hud.Add);

        dispatcher.Dispatch([GroupItem, Joined, FromContact, Codes]);
        Assert.Equal(4, notifier.Shown.Count);

        notifier.Shown.Clear();
        view = "group:g";
        dispatcher.Dispatch([GroupItem, Joined, FromContact]);
        Assert.Equal([Joined, FromContact], notifier.Shown);   // the item is in view; the join isn't an item

        notifier.Shown.Clear();
        view = "inbox";
        settings.MutedGroups.Add("g");
        dispatcher.Dispatch([GroupItem, Joined, FromContact]);
        Assert.Empty(notifier.Shown);

        settings.MutedGroups.Clear();
        view = "";
        settings.NotifyGroupMembers = false;
        settings.NotifyAuthenticators = false;
        dispatcher.Dispatch([GroupItem, Joined, Codes]);
        Assert.Equal([GroupItem], notifier.Shown);
        Assert.Empty(hud);
    }

    [Fact]
    public void WithNotificationsOffOrNotAllowedContactsFallBackToTheHud()
    {
        var settings = new Settings();
        var notifier = new FakeNotifier { IsAllowed = false };
        var hud = new List<AppNotification>();
        var dispatcher = new NotificationDispatcher(settings, notifier, _ => false, hud.Add);
        dispatcher.Dispatch([GroupItem, FromContact]);
        Assert.Empty(notifier.Shown);
        Assert.Equal([FromContact], hud);

        hud.Clear();
        notifier.IsAllowed = true;
        settings.NotificationsEnabled = false;
        dispatcher.Dispatch([GroupItem, FromContact, Codes]);
        Assert.Empty(notifier.Shown);
        Assert.Equal([FromContact], hud);

        hud.Clear();
        settings.NotifyContacts = false;   // switched off: not even the HUD
        dispatcher.Dispatch([FromContact]);
        Assert.Empty(hud);
    }

    [Fact]
    public void TargetsSurviveToastArguments()
    {
        NotificationTarget[] targets = [new NotificationTarget.Group("g", "c-1"), new NotificationTarget.Group("g"), new NotificationTarget.Inbox("c-2"),
            new NotificationTarget.Inbox(), new NotificationTarget.People(), new NotificationTarget.Saved("o-x")];
        foreach (var t in targets) Assert.Equal(t, NotificationTarget.Decode(t.Encode()));
        Assert.Null(NotificationTarget.Decode("zz"));
        Assert.Null(NotificationTarget.Decode(null));
    }
}
