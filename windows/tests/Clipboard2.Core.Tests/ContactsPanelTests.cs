using Clipboard2.Core.Sync;

namespace Clipboard2.Core.Tests;

/// <summary>The Contacts chip: Inbox | People, the People list and Send to Contact… (docs/features/notifications-contacts.md).</summary>
public sealed class ContactsPanelTests : IDisposable
{
    private readonly ClipStore _store = new(":memory:", new BlobStore(Path.Combine(Path.GetTempPath(), "c2people-" + Guid.NewGuid())));
    private readonly Settings _settings = new();
    private readonly FakeVault _vault = new();
    private readonly FakeHost _host = new();
    private readonly FakeContacts _contacts = new();
    private readonly PanelModel _model;

    private sealed class FakeContacts : IContactService
    {
        public List<string> Log { get; } = [];
        public IReadOnlyList<ContactRequest> IncomingRequests { get; set; } = [];
        public IReadOnlyList<ContactRequest> OutgoingRequests { get; set; } = [];
        public string? Error { get; set; }
        public string? Status { get; set; }
        public Task<bool> AcceptAsync(ContactRequest request) { Log.Add("accept:" + request.Name); return Task.FromResult(true); }
        public Task<bool> DeclineAsync(ContactRequest request) { Log.Add("decline:" + request.Name); return Task.FromResult(true); }
        public Task<bool> CancelAsync(ContactRequest request) { Log.Add("cancel:" + request.Name); return Task.FromResult(true); }
        public Task<bool> RemoveAsync(string spaceId) { Log.Add("remove:" + spaceId); return Task.FromResult(true); }
        public Task<bool> AddAsync(string usernameOrCode) { Log.Add("add:" + usernameOrCode); Status = "Request sent."; return Task.FromResult(true); }
        public Task<string?> CreateCodeAsync() { Log.Add("code"); return Task.FromResult<string?>("ABCD-EFGH"); }
    }

    public ContactsPanelTests()
    {
        _model = new PanelModel(_store, _settings, new QuickSlots(_settings), _vault, _host)
        {
            Self = () => new SyncSelf("me", "me"), ContactService = _contacts,
        };
        _store.SaveSyncSpaces([Contact("d-anna", "anna"), Contact("d-ben", "ben"), Contact("d-cleo", "cleo"), Contact("d-dan", "dan"),
            new SpaceRecord("g", SpaceKinds.Group, "owner", "Team", "me", 2)]);
        _model.PrepareForOpen(null);
    }

    public void Dispose() => _store.Dispose();

    private static SpaceRecord Contact(string id, string name) =>
        new(id, SpaceKinds.Direct, "owner", name, "me", 2, new Dictionary<string, string> { ["me"] = "me", [name + "-uid"] = name });

    private ClipItem Add(string text, int ageSeconds = 0, string? space = null) =>
        _store.Ingest(ProcessedCapture.ForText(text), DateTime.UtcNow.AddSeconds(-ageSeconds), space);

    private static KeyInput K(PanelKey key, KeyMods mods = KeyMods.None) => new(key, mods);

    // MARK: Inbox | People

    [Fact]
    public void TheContactsChipShowsWhileSignedInAndSwitchesBetweenInboxAndPeople()
    {
        Assert.Contains(PanelFilter.Inbox, _model.ChipFilters);
        Assert.Equal("Contacts", PanelFilter.Inbox.Title());
        var signedOut = new PanelModel(_store, new Settings(), new QuickSlots(new Settings()), _vault, _host);
        _store.SaveSyncSpaces([]);
        signedOut.PrepareForOpen(null);
        Assert.DoesNotContain(PanelFilter.Inbox, signedOut.ChipFilters);
        _store.SaveSyncSpaces([Contact("d-anna", "anna")]);

        _model.SetFilter(PanelFilter.Inbox);
        Assert.False(_model.ShowsPeople);
        Assert.True(_model.IsShowing("inbox"));
        _model.SetContactsShowPeople(true);
        Assert.True(_model.ShowsPeople);
        Assert.False(_model.IsShowing("inbox"));
        Assert.Empty(_model.Entries);   // People lists people, not items
        Assert.Equal(["anna"], _model.People.Select(p => p.Name));
        Assert.True(_settings.ContactsShowPeople);   // remembered

        // From another chip, choosing People goes to Contacts.
        _model.SetFilter(PanelFilter.All);
        Assert.False(_model.ShowsPeople);
        _model.SetContactsShowPeople(false);
        Assert.Equal(PanelFilter.Inbox, _model.Filter);
        Assert.False(_model.ShowsPeople);
    }

    // MARK: People

    [Fact]
    public void PeopleListsRequestsFirstThenContactsByRecencyThenName()
    {
        _contacts.IncomingRequests = [new ContactRequest("r1", "eve-uid", "eve", "eve", 0)];
        _contacts.OutgoingRequests = [new ContactRequest("r2", "fay-uid", "fay", "fay", 0)];
        Add("to cleo", 50, "d-cleo");
        Add("from ben", 10, "d-ben");
        _model.SetContactsShowPeople(true);
        Assert.Equal(["eve", "fay", "ben", "cleo", "anna", "dan"], _model.People.Select(p => p.Name));
        Assert.IsType<PersonRow.Incoming>(_model.People[0]);
        Assert.IsType<PersonRow.Outgoing>(_model.People[1]);
    }

    [Fact]
    public void TheSearchFieldFiltersPeopleByNameAndUsername()
    {
        _contacts.IncomingRequests = [new ContactRequest("r1", "x", "danny", "Daniel", 0)];
        _model.SetContactsShowPeople(true);
        _model.SetQuery("dan");
        Assert.Equal(["Daniel", "dan"], _model.People.Select(p => p.Name));   // the request stays on top
        _model.SetQuery("cl");
        Assert.Equal(["cleo"], _model.People.Select(p => p.Name));
        _model.SetQuery("zzz");
        Assert.Empty(_model.People);
    }

    [Fact]
    public async Task RequestsAreAnsweredAndRemovalIsConfirmedInline()
    {
        var request = new ContactRequest("r1", "eve-uid", "eve", "eve", 0);
        _contacts.IncomingRequests = [request];
        _model.SetContactsShowPeople(true);
        Assert.True(_model.HandleKey(K(PanelKey.Enter)));   // Enter on an incoming request accepts it
        await Task.Yield();
        Assert.Contains("accept:eve", _contacts.Log);
        await _model.DeclineRequestAsync(request);
        Assert.Contains("decline:eve", _contacts.Log);

        _model.BeginRemoveContact("d-ben");
        Assert.Equal("d-ben", _model.ConfirmingRemoval);
        Assert.Empty(_contacts.Log.Where(l => l.StartsWith("remove")));
        _model.HandleKey(K(PanelKey.Escape));
        Assert.Null(_model.ConfirmingRemoval);
        _model.BeginRemoveContact("d-ben");
        await _model.ConfirmRemoveContactAsync();
        Assert.Contains("remove:d-ben", _contacts.Log);
        Assert.Equal("Removed ben", _model.Notice);

        await _model.AddContactAsync("  zoe ");
        Assert.Contains("add:zoe", _contacts.Log);
        await _model.CreateContactCodeAsync();
        Assert.Equal("ABCD-EFGH", _model.CreatedContactCode);
    }

    [Fact]
    public void SendFromPeoplePicksItemsLikeAddItems()
    {
        var one = Add("one", 2);
        Add("two", 1);
        _model.SetContactsShowPeople(true);
        var ben = _model.People.OfType<PersonRow.Contact>().Single(c => c.Name == "ben");
        _model.BeginSendItems(ben.Space);
        Assert.Equal(PanelMode.AddItems, _model.Mode);
        Assert.Equal(["two", "one"], _model.AddItemsForm!.Candidates.Select(i => i.Text));
        _model.ToggleAddItem(one.Id);
        _model.HandleKey(K(PanelKey.Enter));
        Assert.Equal(["one"], _store.ItemsInSpace("d-ben").Select(i => i.Text));
        Assert.Equal("Sent to ben", _model.Notice);
    }

    // MARK: Send to Contact…

    [Fact]
    public void TheActionMenuOffersThePickerAndTheThreeMostRecentContacts()
    {
        Add("to dan", 30, "d-dan");
        Add("to anna", 20, "d-anna");
        var item = Add("hello");
        _model.Refresh();
        _model.Select(new PanelEntry.Clip(item).Id);
        var titles = _model.AvailableActions.Where(a => a.Section("AI") == "Send to Contact").Select(a => a.Title).ToList();
        Assert.Equal(["Send to Contact…", "Send to anna", "Send to dan", "Send to ben"], titles);
    }

    [Fact]
    public void ThePickerSendsToOneContact()
    {
        Add("to dan", 30, "d-dan");
        var item = Add("hello");
        _model.Refresh();
        _model.Select(new PanelEntry.Clip(item).Id);
        _model.BeginSendToContact();
        Assert.Equal(PanelMode.SendToContact, _model.Mode);
        Assert.Equal("dan", _model.ContactPicker!.Candidates[0].DisplayName);   // recent first
        _model.SetContactPickerQuery("cle");
        Assert.Equal(["cleo"], _model.ContactPicker.Candidates.Select(c => c.DisplayName));
        _model.HandleKey(K(PanelKey.Enter));
        Assert.Equal(PanelMode.Browse, _model.Mode);
        Assert.Equal(["hello"], _store.ItemsInSpace("d-cleo").Select(i => i.Text));
        Assert.Equal("Sent to cleo", _model.Notice);
    }

    [Fact]
    public void TickingOrCtrlEnterSendsToSeveralContacts()
    {
        var one = Add("one", 2);
        var two = Add("two", 1);
        _model.Refresh();
        _model.SelectAll();
        _model.BeginSendToContact();
        Assert.Equal(2, _model.ContactPicker!.Items.Count);
        _model.ToggleContactPick("d-anna");
        _model.HandleKey(K(PanelKey.Down));
        _model.HandleKey(K(PanelKey.Enter, KeyMods.Ctrl));   // ticked + highlighted
        var highlighted = _model.Notice!;
        Assert.StartsWith("Sent to ", highlighted);
        Assert.Equal(["one", "two"], _store.ItemsInSpace("d-anna").Select(i => i.Text).Order());
        Assert.Equal(2, _store.Contacts().Count(c => _store.ItemsInSpace(c.Id).Count == 2));
        _ = (one, two);
    }

    [Fact]
    public void AFolderIsSentWithItsWholeSubtree()
    {
        var outer = new ClipFolder { Name = "Work" };
        var inner = new ClipFolder { Name = "Clients", ParentId = outer.Id };
        _store.PutFolder(outer);
        _store.PutFolder(inner);
        var a = Add("top");
        _store.Pin(a);
        _store.MoveToFolder([a], outer);
        var b = Add("deep");
        _store.Pin(b);
        _store.MoveToFolder([b], inner);
        _model.SetFilter(PanelFilter.Labelled);
        _model.Select("f-" + outer.Id);
        _model.BeginSendToContact();
        _model.SetContactPickerQuery("anna");
        _model.HandleKey(K(PanelKey.Enter));
        Assert.Equal(["Clients", "Work"], _store.FoldersInSpace("d-anna").Select(f => f.Name).Order());
        Assert.Equal(["deep", "top"], _store.ItemsInSpace("d-anna").Select(i => i.Text).Order());
    }

    [Fact]
    public void ASecretIsSentOnlyThroughWindowsHello()
    {
        var secret = _vault.Add("Wi-Fi", "hunter2")!;
        _model.SetFilter(PanelFilter.Labelled);
        _model.Select("k-" + secret.Id);
        Assert.Contains(_model.AvailableActions, a => a is PanelAction.SendToContactPicker);
        _model.BeginSendToContact();
        _model.SetContactPickerQuery("ben");
        _model.HandleKey(K(PanelKey.Enter));
        // The host asks for Windows Hello before it copies (CopySecrets); the vault isn't touched here.
        Assert.Contains("copy-secrets:Wi-Fi:d-ben:root", _host.Log);
        Assert.Single(_vault.Secrets);
    }

    [Fact]
    public void WhatAContactSentCantBeSentOn()
    {
        var received = Add("from anna", 0, "d-anna");
        _store.SaveSyncMeta(new SyncMeta("d-anna", ClipStore.SyncId(received.Id), SyncCategory.History, "f", 1, 1, false,
            new Dictionary<string, string>(), "anna-uid"));
        _model.SetFilter(PanelFilter.Inbox);
        var entry = Assert.Single(_model.Entries);
        Assert.False(_model.CanSendToContact(entry));
        _model.Select(entry.Id);
        _model.BeginSendToContact();
        Assert.Equal(PanelMode.Browse, _model.Mode);
    }

    // MARK: Notification targets

    [Fact]
    public void ANotificationsTargetOpensTheRightView()
    {
        var item = Add("in team", 0, "g");
        _model.ShowTarget(new NotificationTarget.Group("g", "c-" + item.Id));
        Assert.Equal("g", _model.GroupFilter);
        Assert.Equal("c-" + item.Id, _model.SelectedId);
        Assert.True(_model.IsShowing("group:g"));

        _model.ShowTarget(new NotificationTarget.People());
        Assert.True(_model.ShowsPeople);
        _model.ShowTarget(new NotificationTarget.Inbox());
        Assert.Equal(PanelFilter.Inbox, _model.Filter);
        Assert.False(_model.ShowsPeople);
        _model.ShowTarget(new NotificationTarget.Saved());
        Assert.Equal(PanelFilter.Labelled, _model.Filter);
    }

    [Fact]
    public void GroupsAreMutedOneByOne()
    {
        _model.SetGroupMuted("g", true);
        Assert.True(_model.IsGroupMuted("g"));
        Assert.Equal(["g"], _settings.MutedGroups);
        _model.SetGroupMuted("g", false);
        Assert.Empty(_settings.MutedGroups);
    }
}
