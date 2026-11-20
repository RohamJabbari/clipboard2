using Clipboard2.Core.Sync;

namespace Clipboard2.Core;

/// <summary>The panel's view of contacts in sync: pending requests and the account flows Settings uses too.</summary>
public interface IContactService
{
    IReadOnlyList<ContactRequest> IncomingRequests { get; }
    IReadOnlyList<ContactRequest> OutgoingRequests { get; }
    /// <summary>The last flow's error or status line ("Request sent to anna.").</summary>
    string? Error { get; }
    string? Status { get; }
    Task<bool> AcceptAsync(ContactRequest request);
    Task<bool> DeclineAsync(ContactRequest request);
    Task<bool> CancelAsync(ContactRequest request);
    Task<bool> RemoveAsync(string spaceId);
    /// <summary>A username sends a request; a contact code adds its maker right away.</summary>
    Task<bool> AddAsync(string usernameOrCode);
    /// <summary>A one-time contact code, formatted; null when it failed (<see cref="Error"/>).</summary>
    Task<string?> CreateCodeAsync();
}

/// <summary><see cref="IContactService"/> over the sync account, reusing Settings' flows.</summary>
public sealed class SyncContactService(SyncAccount sync) : IContactService
{
    public IReadOnlyList<ContactRequest> IncomingRequests => sync.IncomingRequests;
    public IReadOnlyList<ContactRequest> OutgoingRequests => sync.OutgoingRequests;
    public string? Error => sync.Error;
    public string? Status => sync.Status;
    public Task<bool> AcceptAsync(ContactRequest request) => sync.AcceptContactAsync(request);
    public Task<bool> DeclineAsync(ContactRequest request) => sync.DeclineContactAsync(request);
    public Task<bool> CancelAsync(ContactRequest request) => sync.CancelContactRequestAsync(request);
    public Task<bool> RemoveAsync(string spaceId) => sync.RemoveContactAsync(spaceId);
    public Task<string?> CreateCodeAsync() => sync.CreateContactCodeAsync();

    public async Task<bool> AddAsync(string usernameOrCode)
    {
        if (InviteCode.Parse(usernameOrCode) is null) return await sync.RequestContactAsync(usernameOrCode);
        if (await sync.PreviewInviteAsync(usernameOrCode) is not { } invite) return false;
        if (!invite.IsContact)
        {
            _groupCode = true;
            return false;
        }
        return await sync.JoinAsync(invite);
    }

    private bool _groupCode;
    /// <summary>True once (and reset by reading) when <see cref="AddAsync"/> was given a group's invite code.</summary>
    public bool TakeGroupCode()
    {
        var was = _groupCode;
        _groupCode = false;
        return was;
    }
}

/// <summary>A row of Contacts ▸ People.</summary>
public abstract record PersonRow
{
    public sealed record Incoming(ContactRequest Request) : PersonRow;
    public sealed record Outgoing(ContactRequest Request) : PersonRow;
    /// <param name="LastActivity">The newest item either of them sent, or null.</param>
    public sealed record Contact(SpaceRecord Space, DateTime? LastActivity) : PersonRow;

    public string Id => this switch
    {
        Incoming i => "in-" + i.Request.SpaceId,
        Outgoing o => "out-" + o.Request.SpaceId,
        Contact c => "ct-" + c.Space.Id,
        _ => "",
    };

    public string Name => this switch
    {
        Incoming i => i.Request.Name,
        Outgoing o => o.Request.Name,
        Contact c => c.Space.DisplayName,
        _ => "",
    };
}

/// <summary>Right-click → Send to Contact…: contacts to pick (recent first) for what was selected.</summary>
public sealed class ContactPickerForm(IReadOnlyList<PanelEntry> items)
{
    public IReadOnlyList<PanelEntry> Items { get; } = items;
    public string Query { get; set; } = "";
    public List<SpaceRecord> Candidates { get; set; } = [];
    public HashSet<string> Checked { get; } = [];
    public int Cursor { get; set; }
    public SpaceRecord? Current => Cursor >= 0 && Cursor < Candidates.Count ? Candidates[Cursor] : null;
}

public sealed partial class PanelModel
{
    /// <summary>The Ctrl+K list keeps this many recent contacts as direct "Send to ‹name›" rows.</summary>
    public const int RecentContactActions = 3;

    /// <summary>Contacts' requests and flows; null outside the app (and signed out).</summary>
    public IContactService? ContactService { get; set; }

    /// <summary>Signed in to sync: the Contacts chip shows, even before the first contact.</summary>
    public bool IsSyncSignedIn => Self?.Invoke() is not null;

    // MARK: Inbox | People

    /// <summary>The Contacts chip is selected and on its People segment.</summary>
    public bool ShowsPeople => Filter == PanelFilter.Inbox && GroupFilter is null && settings.ContactsShowPeople;

    /// <summary>The Contacts chip's Inbox | People switch (remembered).</summary>
    public void SetContactsShowPeople(bool people)
    {
        if (settings.ContactsShowPeople != people)
        {
            settings.ContactsShowPeople = people;
            settings.Save();
        }
        ConfirmingRemoval = null;
        if (Filter != PanelFilter.Inbox || GroupFilter is not null)
        {
            SetFilter(PanelFilter.Inbox);
            return;
        }
        Refresh(resetSelection: true);
    }

    /// <summary>People: requests first (incoming, then outgoing), then contacts by most recent activity, then name.
    /// The search field filters by name and username.</summary>
    public List<PersonRow> People { get; private set; } = [];
    public int PeopleCursor { get; private set; }
    public PersonRow? SelectedPerson => PeopleCursor >= 0 && PeopleCursor < People.Count ? People[PeopleCursor] : null;
    /// <summary>The contact whose Remove contact waits for its inline confirm.</summary>
    public string? ConfirmingRemoval { get; private set; }
    /// <summary>A contact code just made in People (shown once, inline).</summary>
    public string? CreatedContactCode { get; private set; }
    public bool IsContactBusy { get; private set; }

    /// <summary>When each contact last sent or received something: the newest item in their space.</summary>
    private Dictionary<string, DateTime> ContactActivity()
    {
        var activity = new Dictionary<string, DateTime>();
        foreach (var id in _contacts.Keys)
        {
            DateTime? newest = store.ItemsInSpace(id).Select(i => (DateTime?)i.LastCopiedAt).DefaultIfEmpty().Max();
            foreach (var s in secrets.Secrets.Where(s => s.SpaceId == id && s.CreatedAt is not null))
                if (newest is null || s.CreatedAt > newest) newest = s.CreatedAt;
            if (newest is { } n) activity[id] = n;
        }
        return activity;
    }

    /// <summary>Contacts, most recently sent to or received from first, then by name.</summary>
    public List<SpaceRecord> ContactsByRecency()
    {
        var activity = ContactActivity();
        return [.. _contacts.Values.OrderByDescending(c => activity.TryGetValue(c.Id, out var at) ? at : DateTime.MinValue)
            .ThenBy(c => c.DisplayName, StringComparer.CurrentCultureIgnoreCase)];
    }

    private void RefreshPeople(bool resetCursor)
    {
        var q = Query.Trim();
        var keep = SelectedPerson?.Id;
        var activity = ContactActivity();
        List<PersonRow> rows = [.. (ContactService?.IncomingRequests ?? []).Select(r => (PersonRow)new PersonRow.Incoming(r)),
                                .. (ContactService?.OutgoingRequests ?? []).Select(r => (PersonRow)new PersonRow.Outgoing(r)),
                                .. ContactsByRecency().Select(c => (PersonRow)new PersonRow.Contact(c, activity.TryGetValue(c.Id, out var at) ? at : null))];
        if (q.Length > 0)
        {
            string Searchable(PersonRow row) => row switch
            {
                PersonRow.Incoming i => $"{i.Request.Name} {i.Request.Username}",
                PersonRow.Outgoing o => $"{o.Request.Name} {o.Request.Username}",
                PersonRow.Contact c => string.Join(" ", new[] { c.Space.DisplayName }.Concat(c.Space.Members?.Values ?? [])),
                _ => "",
            };
            // Requests stay on top; within each part the best match first.
            rows = [.. rows.Select((r, i) => (Row: r, Index: i, Score: FuzzyMatcher.Score(q, Searchable(r))))
                .Where(x => x.Score is not null)
                .OrderBy(x => x.Row is PersonRow.Contact ? 1 : 0).ThenByDescending(x => x.Score).ThenBy(x => x.Index).Select(x => x.Row)];
        }
        People = rows;
        PeopleCursor = !resetCursor && keep is not null && rows.FindIndex(r => r.Id == keep) is var i and >= 0 ? i : 0;
        if (ConfirmingRemoval is { } removing && rows.All(r => r is not PersonRow.Contact c || c.Space.Id != removing)) ConfirmingRemoval = null;
    }

    public void SelectPerson(PersonRow row)
    {
        if (People.FindIndex(r => r.Id == row.Id) is var i and >= 0) PeopleCursor = i;
        Notify();
    }

    private bool HandlePeopleKey(KeyInput key)
    {
        switch (key.Key)
        {
            case PanelKey.Up:
                PeopleCursor = Math.Max(0, PeopleCursor - 1);
                Notify();
                return true;
            case PanelKey.Down:
                PeopleCursor = Math.Min(Math.Max(0, People.Count - 1), PeopleCursor + 1);
                Notify();
                return true;
            case PanelKey.Enter:
                switch (SelectedPerson)
                {
                    case PersonRow.Contact c when ConfirmingRemoval == c.Space.Id: _ = ConfirmRemoveContactAsync(); break;
                    case PersonRow.Contact c: BeginSendItems(c.Space); break;
                    case PersonRow.Incoming i: _ = AcceptRequestAsync(i.Request); break;
                }
                return true;
            case PanelKey.Escape when ConfirmingRemoval is not null:
                CancelRemoveContact();
                return true;
            default:
                return false;
        }
    }

    // MARK: Requests, removal, adding

    private async Task RunContactFlow(Func<IContactService, Task<bool>> flow, string? success = null)
    {
        if (ContactService is not { } service) return;
        IsContactBusy = true;
        Notify();
        var ok = await flow(service);
        IsContactBusy = false;
        Refresh();
        if (ok && (success ?? service.Status) is { } done) ShowNotice(done);
        else if (!ok && service.Error is { } error) ShowNotice(error);
        else Notify();
    }

    public Task AcceptRequestAsync(ContactRequest request) => RunContactFlow(s => s.AcceptAsync(request), $"{request.Name} is now your contact");
    public Task DeclineRequestAsync(ContactRequest request) => RunContactFlow(s => s.DeclineAsync(request), "Declined");
    public Task CancelRequestAsync(ContactRequest request) => RunContactFlow(s => s.CancelAsync(request), "Request cancelled");

    /// <summary>Remove contact: the row asks to confirm inline first.</summary>
    public void BeginRemoveContact(string spaceId)
    {
        ConfirmingRemoval = spaceId;
        if (People.FindIndex(r => r is PersonRow.Contact c && c.Space.Id == spaceId) is var i and >= 0) PeopleCursor = i;
        Notify();
    }

    public void CancelRemoveContact()
    {
        ConfirmingRemoval = null;
        Notify();
    }

    public Task ConfirmRemoveContactAsync()
    {
        if (ConfirmingRemoval is not { } id) return Task.CompletedTask;
        var name = _contacts.GetValueOrDefault(id)?.DisplayName ?? "the contact";
        ConfirmingRemoval = null;
        return RunContactFlow(s => s.RemoveAsync(id), $"Removed {name}");
    }

    /// <summary>Add Contact: a username sends a request, a contact code adds its maker.</summary>
    public Task AddContactAsync(string usernameOrCode)
    {
        if (usernameOrCode.Trim().Length == 0) return Task.CompletedTask;
        return RunContactFlow(async s =>
        {
            var ok = await s.AddAsync(usernameOrCode.Trim());
            if (!ok && s is SyncContactService sync && sync.TakeGroupCode())
            {
                ShowNotice("That's a group invite. Join groups in Settings → Sync.");
                return true;
            }
            return ok;
        });
    }

    public async Task CreateContactCodeAsync()
    {
        if (ContactService is not { } service) return;
        IsContactBusy = true;
        Notify();
        CreatedContactCode = await service.CreateCodeAsync();
        IsContactBusy = false;
        if (CreatedContactCode is null && service.Error is { } error) ShowNotice(error);
        else Notify();
    }

    /// <summary>Copies the code just made without recording it (like a secret).</summary>
    public void CopyContactCode()
    {
        if (CreatedContactCode is not { } code) return;
        host.CopyTransient(code);
        ShowNotice("Code copied");
    }

    public void DismissContactCode()
    {
        CreatedContactCode = null;
        Notify();
    }

    // MARK: Send… (items for one contact)

    /// <summary>People ▸ Send…: recent history to check and send to <paramref name="contact"/>, like Add Items.</summary>
    public void BeginSendItems(SpaceRecord contact)
    {
        ResetMode();
        AddItemsForm = new AddItemsForm { SendTo = contact };
        FillAddItems();
        Mode = PanelMode.AddItems;
        Notify();
    }

    // MARK: Send to Contact…

    public ContactPickerForm? ContactPicker { get; private set; }

    /// <summary>What Send to Contact can send from the selection: clips, secrets and folders, never what a contact
    /// sent (or anything in a contact's space but this user's own).</summary>
    private List<PanelEntry> SendableSelection()
    {
        var entries = IsMultiSelecting ? Entries.Where(e => SelectedIds.Contains(e.Id)).ToList() : SelectedEntry is { } e ? [e] : [];
        return [.. entries.Where(CanSendToContact)];
    }

    public bool CanSendToContact(PanelEntry entry) => entry switch
    {
        PanelEntry.Clip c => !IsReceived(c),
        PanelEntry.SecretEntry k => k.Secret.SpaceId is not { } space || !_contacts.ContainsKey(space) || !IsFromContact(space, k),
        PanelEntry.FolderEntry f => f.Folder.SpaceId is not { } space || !_contacts.ContainsKey(space),
        _ => false,
    };

    /// <summary>Whether Send to Contact… is offered for the selection.</summary>
    public bool CanSendSelectionToContact => _contacts.Count > 0 && SendableSelection().Count > 0;

    /// <summary>Right-click or Ctrl+K → Send to Contact…: the contact picker in the right pane, search focused.</summary>
    public void BeginSendToContact()
    {
        var items = SendableSelection();
        if (items.Count == 0 || _contacts.Count == 0) return;
        ResetMode();
        ContactPicker = new ContactPickerForm(items);
        FillContactPicker();
        Mode = PanelMode.SendToContact;
        Notify();
    }

    private void FillContactPicker()
    {
        if (ContactPicker is not { } form) return;
        // A single clip already in a contact's space isn't offered back to that contact.
        var own = form.Items is [PanelEntry.Clip { Item.SpaceId: { } s }] ? s : null;
        var all = ContactsByRecency().Where(c => c.Id != own).ToList();
        var q = form.Query.Trim();
        form.Candidates = q.Length == 0 ? all
            : [.. all.Select((c, i) => (Contact: c, Index: i, Score: FuzzyMatcher.Score(q, string.Join(" ", new[] { c.DisplayName }.Concat(c.Members?.Values ?? [])))))
                .Where(x => x.Score is not null).OrderByDescending(x => x.Score).ThenBy(x => x.Index).Select(x => x.Contact)];
        form.Cursor = Math.Clamp(form.Cursor, 0, Math.Max(0, form.Candidates.Count - 1));
    }

    public void SetContactPickerQuery(string query)
    {
        if (ContactPicker is not { } form || form.Query == query) return;
        form.Query = query;
        form.Cursor = 0;
        FillContactPicker();
        Notify();
    }

    public void ToggleContactPick(string spaceId)
    {
        if (ContactPicker is not { } form) return;
        if (!form.Checked.Remove(spaceId)) form.Checked.Add(spaceId);
        if (form.Candidates.FindIndex(c => c.Id == spaceId) is var i and >= 0) form.Cursor = i;
        Notify();
    }

    /// <summary>Return: to the ticked contacts, or the highlighted one when none is ticked. <paramref name="several"/>
    /// (Ctrl+Enter): the ticked ones and the highlighted one.</summary>
    public void SubmitContactPicker(bool several = false)
    {
        if (ContactPicker is not { } form) return;
        var ids = form.Checked.ToHashSet();
        if ((several || ids.Count == 0) && form.Current is { } current) ids.Add(current.Id);
        var contacts = ContactsByRecency().Where(c => ids.Contains(c.Id)).ToList();
        if (contacts.Count == 0) return;
        var items = form.Items;
        ResetMode();
        SendEntries(items, contacts);
    }

    private bool HandleContactPickerKey(KeyInput key)
    {
        if (ContactPicker is not { } form) return false;
        switch (key.Key)
        {
            case PanelKey.Escape:
                ResetMode();
                return true;
            case PanelKey.Up:
                form.Cursor = Math.Max(0, form.Cursor - 1);
                Notify();
                return true;
            case PanelKey.Down:
                form.Cursor = Math.Min(Math.Max(0, form.Candidates.Count - 1), form.Cursor + 1);
                Notify();
                return true;
            case PanelKey.Space when form.Current is { } current && form.Query.Length == 0:
                ToggleContactPick(current.Id);
                return true;
            case PanelKey.Enter:
                SubmitContactPicker(several: key.Ctrl);
                return true;
            default:
                return false;   // typing goes to the search field
        }
    }

    /// <summary>"anna", "anna and ben", "3 contacts".</summary>
    private static string ContactList(IReadOnlyList<SpaceRecord> contacts) => contacts.Count switch
    {
        1 => contacts[0].DisplayName,
        2 => $"{contacts[0].DisplayName} and {contacts[1].DisplayName}",
        _ => $"{contacts.Count} contacts",
    };

    /// <summary>Sends clips, secrets and folders (their whole subtree) to each contact: copies land in their Inbox.
    /// All or nothing per send, like sharing to a group: a file too large keeps everything back. Secrets are copied
    /// after one Windows Hello confirmation.</summary>
    public void SendEntries(IReadOnlyList<PanelEntry> entries, IReadOnlyList<SpaceRecord> contacts)
    {
        ResetMode();
        entries = [.. entries.Where(CanSendToContact)];
        if (entries.Count == 0 || contacts.Count == 0) return;
        var to = ContactList(contacts);
        var notice = $"Sent to {to}";
        // The selection from another app (Ctrl+Alt+K) is stored straight into each contact's space.
        if (entries is [PanelEntry.Clip { Item: var picked }] && picked == SelectionItem)
        {
            foreach (var c in contacts) store.Ingest(ProcessedCapture.ForText(picked.Text, source: picked.Source), spaceId: c.Id);
            host.ClosePanel();
            return;
        }
        var clips = entries.OfType<PanelEntry.Clip>().Select(c => c.Item).ToList();
        var folders = entries.OfType<PanelEntry.FolderEntry>().Select(f => f.Folder).ToList();
        var secretRefs = entries.OfType<PanelEntry.SecretEntry>().Select(k => k.Secret).ToList();
        var folderClips = folders.SelectMany(f =>
        {
            var subtree = _tree.Subtree(f.Id).Select(x => x.Id).ToHashSet();
            return store.ItemsInSpace(f.SpaceId).Where(i => i.IsPinned && i.FolderId is { } id && subtree.Contains(id));
        }).ToList();
        if (clips.Concat(folderClips).Select(SyncEngine.ContactSendProblem).FirstOrDefault(p => p is not null) is { } problem)
        {
            ShowNotice(problem);
            return;
        }
        var secretCopies = new List<(SecretRef Secret, string SpaceId, Guid? FolderId)>();
        foreach (var contact in contacts)
        {
            foreach (var clip in clips.Where(c => c.SpaceId != contact.Id)) store.CopyToSpace(clip, contact.Id, keepLabel: false);
            secretCopies.AddRange(secretRefs.Where(s => s.SpaceId != contact.Id).Select(s => (s, contact.Id, (Guid?)null)));
            foreach (var folder in folders)
            {
                var (_, map) = store.CopyFolderTreeToSpace(folder, contact.Id);
                secretCopies.AddRange(secrets.Secrets.Where(s => s.SpaceId == folder.SpaceId && FolderOf(s) is { } sf && map.ContainsKey(sf.Id))
                    .Select(s => (s, contact.Id, (Guid?)map[FolderOf(s)!.Id])));
            }
        }
        Refresh();
        if (secretCopies.Count > 0)
        {
            var reason = secretRefs.Count == 1 && folders.Count == 0 ? $"send “{secretRefs[0].Name}” to {to}" : $"send secrets to {to}";
            host.CopySecretsToSpaces(secretCopies, reason, notice);   // its notice once Windows Hello is through
            if (clips.Count + folders.Count == 0) return;
        }
        ShowNotice(notice);
    }

    // MARK: Opening at a notification's target

    /// <summary>A notification was clicked: show what it's about (the panel is already open).</summary>
    public void ShowTarget(NotificationTarget target)
    {
        ResetMode();
        Query = "";
        switch (target)
        {
            case NotificationTarget.Group g when GroupNames.ContainsKey(g.SpaceId) || store.Groups().Any(x => x.Id == g.SpaceId):
                RememberGroupSegment(g.SpaceId, false);
                GroupFilter = null;
                SetGroupFilter(g.SpaceId);
                SelectIfListed(g.EntryId);
                break;
            case NotificationTarget.Inbox i:
                if (settings.ContactsShowPeople) { settings.ContactsShowPeople = false; settings.Save(); }
                Filter = PanelFilter.All;
                SetFilter(PanelFilter.Inbox);
                SelectIfListed(i.EntryId);
                break;
            case NotificationTarget.People:
                if (!settings.ContactsShowPeople) { settings.ContactsShowPeople = true; settings.Save(); }
                Filter = PanelFilter.All;
                SetFilter(PanelFilter.Inbox);
                PeopleCursor = 0;   // requests are on top
                Notify();
                break;
            case NotificationTarget.Saved s:
                Filter = PanelFilter.All;
                GroupFilter = null;
                SetFilter(PanelFilter.Labelled);
                SelectIfListed(s.EntryId);
                break;
        }
    }

    private void SelectIfListed(string? entryId)
    {
        if (entryId is null || Entries.All(e => e.Id != entryId)) return;
        _userMovedSelection = true;
        Select(entryId);
    }

    /// <summary>Whether the panel shows a notification's view ("group:‹id›" on its Copies, or "inbox").</summary>
    public bool IsShowing(string view) =>
        view == "inbox" ? Filter == PanelFilter.Inbox && GroupFilter is null && !settings.ContactsShowPeople
        : view.StartsWith("group:", StringComparison.Ordinal) && GroupFilter == view[6..];

    // MARK: Mute

    public bool IsGroupMuted(string groupId) => settings.MutedGroups.Contains(groupId);

    public void SetGroupMuted(string groupId, bool muted)
    {
        if (IsGroupMuted(groupId) == muted) return;
        if (muted) settings.MutedGroups.Add(groupId); else settings.MutedGroups.Remove(groupId);
        settings.Save();
        Notify();
    }
}
