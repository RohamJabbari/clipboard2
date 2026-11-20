using Clipboard2.Core.Sync;

namespace Clipboard2.Core;

/// <summary>The four switches in Settings → Notifications (docs/features/notifications-contacts.md).</summary>
public enum NotificationKind { GroupActivity, GroupMembers, Contacts, Authenticators }

/// <summary>Where a click on a notification leads in the panel.</summary>
public abstract record NotificationTarget
{
    /// <param name="EntryId">A <see cref="PanelEntry.Id"/> to select, or null.</param>
    public sealed record Group(string SpaceId, string? EntryId = null) : NotificationTarget;
    public sealed record Inbox(string? EntryId = null) : NotificationTarget;
    /// <summary>Contacts ▸ People (pending requests are on top).</summary>
    public sealed record People : NotificationTarget;
    public sealed record Saved(string? EntryId = null) : NotificationTarget;

    /// <summary>A compact string for toast arguments: "g|space|entry", "i|entry", "p", "s|entry".</summary>
    public string Encode() => this switch
    {
        Group g => $"g|{g.SpaceId}|{g.EntryId}",
        Inbox i => $"i|{i.EntryId}",
        Saved s => $"s|{s.EntryId}",
        _ => "p",
    };

    public static NotificationTarget? Decode(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        var parts = text.Split('|');
        string? At(int i) => parts.Length > i && parts[i].Length > 0 ? parts[i] : null;
        return parts[0] switch
        {
            "g" when At(1) is { } space => new Group(space, At(2)),
            "i" => new Inbox(At(1)),
            "s" => new Saved(At(1)),
            "p" => new People(),
            _ => null,
        };
    }
}

/// <summary>One system notification. <paramref name="View"/>: the panel view that already shows what it's about
/// ("group:‹id›" or "inbox"); none is shown while the panel shows it. <paramref name="GroupId"/>: the group whose
/// mute switch silences it.</summary>
public sealed record AppNotification(NotificationKind Kind, string Title, string Body, NotificationTarget? Target,
                                     string? GroupId = null, string? View = null);

/// <summary>What a pull brought that someone else wrote: one per new item in a group or a contact's space.</summary>
/// <param name="Preview">How the item is described: "“hello”", "an image", "report.pdf", "a secret".</param>
public sealed record SyncArrival(string SpaceId, string? AuthorUid, string Preview, string EntryId);

/// <summary>What the detector compares between syncs: the spaces (with members and names), pending incoming requests
/// (null while not fetched yet), and the authenticators shared with this user or owned.</summary>
public sealed record SyncSnapshot(
    string SelfUid,
    IReadOnlyList<SpaceRecord> Spaces,
    IReadOnlyList<ContactRequest>? IncomingRequests,
    IReadOnlyList<SharedAuthenticator> Shared,
    IReadOnlyList<Authenticator> Owned);

/// <summary>Short descriptions for notifications. Never the content of a secret.</summary>
public static class NotificationText
{
    public static string Describe(ClipItem item) => item.Kind switch
    {
        ClipKind.Image => "an image",
        ClipKind.File when item.Files.Count == 0 => "a file",
        ClipKind.File => FileName(item.Files[0]) + (item.Files.Count > 1 ? $" and {item.Files.Count - 1} more" : ""),
        _ => $"“{ContactNotice.Short(item.Text.Length > 0 ? item.Text : item.Preview)}”",
    };

    /// <summary>The last component of a Windows or Unix path (a received item may name either).</summary>
    private static string FileName(string path)
    {
        var trimmed = path.TrimEnd('/', '\\');
        return trimmed[(trimmed.LastIndexOfAny(['/', '\\']) + 1)..];
    }

    public const string Secret = "a secret";
    public const string Snippet = "a snippet";

    /// <summary>"anna", "anna and ben", "anna and 3 others".</summary>
    public static string Names(IReadOnlyList<string> names) => names.Count switch
    {
        0 => "Someone",
        1 => names[0],
        2 => $"{names[0]} and {names[1]}",
        _ => $"{names[0]} and {names.Count - 1} others",
    };
}

/// <summary>
/// Finds what to notify about by comparing each sync's <see cref="SyncSnapshot"/> with the last one, plus the items a
/// sync pulled (docs/features/notifications-contacts.md). Pure: no clock, no UI. Never notifies about this user's own
/// actions: own items (any device) are left out by author; renames and deletions are owner-only, so an owner's are
/// their own; a contact whose space this user made was accepted by the other person. Leaving a group or removing a
/// member on this device is announced to the detector (<see cref="ExpectLeave"/>, <see cref="ExpectMemberRemoved"/>);
/// on another device of this user it can't be told apart from being removed, or from someone leaving.
/// </summary>
public sealed class ActivityDetector
{
    private SyncSnapshot? _last;
    private HashSet<string>? _knownRequests;
    private readonly HashSet<string> _expectedGone = [];
    private readonly HashSet<(string Space, string Uid)> _expectedRemoved = [];
    /// <summary>Authenticators shared with this user that went away: a transfer makes one this user's own, possibly a
    /// sync later. Space id → who shared it.</summary>
    private readonly Dictionary<string, string> _formerlyShared = [];

    /// <summary>Whether a sync was seen since <see cref="Reset"/>.</summary>
    public bool HasBaseline => _last is not null;

    /// <summary>Signed in or reset: the next sync only records.</summary>
    public void Reset()
    {
        _last = null;
        _knownRequests = null;
        _expectedGone.Clear();
        _expectedRemoved.Clear();
        _formerlyShared.Clear();
    }

    /// <summary>The state known from before this launch (the store's spaces, the stored authenticators), so changes
    /// while the app wasn't running are noticed. Requests aren't stored: their first look only records.</summary>
    public void Seed(SyncSnapshot snapshot)
    {
        _last = snapshot with { IncomingRequests = null };
        _knownRequests = null;
    }

    /// <summary>This user leaves or deletes the group on this device.</summary>
    public void ExpectLeave(string spaceId) => _expectedGone.Add(spaceId);

    /// <summary>This user removes a member on this device.</summary>
    public void ExpectMemberRemoved(string spaceId, string uid) => _expectedRemoved.Add((spaceId, uid));

    public List<AppNotification> Observe(SyncSnapshot now, IReadOnlyList<SyncArrival> arrivals)
    {
        var last = _last;
        _last = now;
        var notes = new List<AppNotification>();
        var requestsBefore = _knownRequests;
        if (now.IncomingRequests is { } incoming) _knownRequests = [.. incoming.Select(r => r.SpaceId)];
        if (last is null)
        {
            _expectedGone.Clear();
            _expectedRemoved.Clear();
            return notes;
        }
        var self = now.SelfUid;
        var before = last.Spaces.Where(s => s.IsGroup || s.IsDirect).ToDictionary(s => s.Id);
        var after = now.Spaces.Where(s => s.IsGroup || s.IsDirect).ToDictionary(s => s.Id);

        // Items, batched per group and author, and per contact.
        foreach (var batch in arrivals.Where(a => a.AuthorUid is { } author && author != self).GroupBy(a => (a.SpaceId, a.AuthorUid)))
        {
            if (!after.TryGetValue(batch.Key.SpaceId, out var space)) continue;
            var list = batch.ToList();
            if (space.IsDirect)
            {
                var what = list.Count == 1 ? list[0].Preview : $"{list.Count} items";
                notes.Add(new(NotificationKind.Contacts, space.DisplayName, $"sent {what}", new NotificationTarget.Inbox(list[0].EntryId),
                    View: "inbox"));
            }
            else
            {
                var name = space.Members?.GetValueOrDefault(batch.Key.AuthorUid!) is { Length: > 0 } n ? n : "Someone";
                var what = list.Count == 1 ? list[0].Preview : $"{list.Count} items";
                notes.Add(new(NotificationKind.GroupActivity, space.DisplayName, $"{name} shared {what}",
                    new NotificationTarget.Group(space.Id, list[0].EntryId), space.Id, "group:" + space.Id));
            }
        }

        foreach (var (id, was) in before)
        {
            if (!was.IsGroup) continue;
            if (!after.TryGetValue(id, out var group))
            {
                // Gone: deleted by its owner (this user, if it's theirs), left here, or this user was removed.
                if (!was.IsOwner && !_expectedGone.Contains(id))
                    notes.Add(new(NotificationKind.GroupMembers, was.DisplayName, "You're no longer in this group", null, id));
                continue;
            }
            // Renaming is owner-only: an owner's rename is their own.
            if (!group.IsOwner && was.Name is { Length: > 0 } oldName && group.Name is { Length: > 0 } newName && oldName != newName)
                notes.Add(new(NotificationKind.GroupActivity, newName, $"{oldName} was renamed", new NotificationTarget.Group(id), id));
            if (was.Members is not { } oldMembers || group.Members is not { } newMembers) continue;
            var joined = newMembers.Where(m => m.Key != self && !oldMembers.ContainsKey(m.Key)).Select(m => m.Value).ToList();
            var left = oldMembers.Where(m => m.Key != self && !newMembers.ContainsKey(m.Key) && !_expectedRemoved.Contains((id, m.Key)))
                .Select(m => m.Value).ToList();
            if (joined.Count > 0)
                notes.Add(new(NotificationKind.GroupMembers, group.DisplayName, $"{NotificationText.Names(joined)} joined", new NotificationTarget.Group(id), id));
            if (left.Count > 0)
                notes.Add(new(NotificationKind.GroupMembers, group.DisplayName, $"{NotificationText.Names(left)} left", new NotificationTarget.Group(id), id));
        }

        // A new contact this user made the space of (a request or a code) was accepted by the other person; one made by
        // the other person was accepted (or their code entered) by this user.
        foreach (var (id, contact) in after)
            if (contact.IsDirect && !before.ContainsKey(id) && contact.OwnerUid == self)
                notes.Add(new(NotificationKind.Contacts, contact.DisplayName, "is now your contact", new NotificationTarget.People()));

        if (requestsBefore is not null && now.IncomingRequests is { } requests)
            foreach (var request in requests.Where(r => !requestsBefore.Contains(r.SpaceId)))
                notes.Add(new(NotificationKind.Contacts, "Contact request", $"{request.Name} wants to add you", new NotificationTarget.People()));

        // Authenticators: shared with this user, or made theirs.
        var sharedBefore = last.Shared.ToDictionary(s => s.SpaceId);
        var ownedBefore = last.Owned.Where(a => a.SpaceId is not null).Select(a => a.SpaceId!).ToHashSet();
        foreach (var gone in sharedBefore.Values.Where(s => now.Shared.All(n => n.SpaceId != s.SpaceId))) _formerlyShared[gone.SpaceId] = gone.OwnerName;
        foreach (var shared in now.Shared)
        {
            _formerlyShared.Remove(shared.SpaceId);
            if (sharedBefore.ContainsKey(shared.SpaceId) || ownedBefore.Contains(shared.SpaceId)) continue;
            notes.Add(new(NotificationKind.Authenticators, shared.OwnerName, $"shared {shared.Title} codes with you",
                new NotificationTarget.Saved("o-" + shared.SpaceId)));
        }
        foreach (var owned in now.Owned)
        {
            if (owned.SpaceId is not { } space || ownedBefore.Contains(space)) continue;
            if (!_formerlyShared.Remove(space, out var from)) continue;   // made by this user (here or elsewhere)
            notes.Add(new(NotificationKind.Authenticators, from, $"made you the owner of {owned.Title}", new NotificationTarget.Saved("a-" + owned.Id)));
        }

        _expectedGone.Clear();
        _expectedRemoved.Clear();
        return notes;
    }
}

/// <summary>The system's notifications (Windows toasts in the app, a fake in tests).</summary>
public interface ISystemNotifier
{
    /// <summary>Whether Windows lets this app show notifications (Settings → System → Notifications).</summary>
    bool IsAllowed { get; }
    void Show(AppNotification notification);
}

/// <summary>
/// Decides what reaches the user: drops what the open panel already shows and muted groups, applies the per-kind
/// switches, and sends the rest to the system. With the master switch off or Windows not allowing notifications, the
/// notices the HUD showed before (contacts' items and requests) go to <paramref name="hud"/> instead.
/// </summary>
public sealed class NotificationDispatcher(Settings settings, ISystemNotifier notifier, Func<string, bool> isInView, Action<AppNotification>? hud = null)
{
    public void Dispatch(IEnumerable<AppNotification> notifications)
    {
        foreach (var n in notifications)
        {
            if (n.View is { } view && isInView(view)) continue;
            if (n.GroupId is { } group && settings.MutedGroups.Contains(group)) continue;
            var system = settings.NotificationsEnabled && notifier.IsAllowed;
            if (system && settings.IsNotificationKindOn(n.Kind)) notifier.Show(n);
            else if (!system && n.Kind == NotificationKind.Contacts && settings.IsNotificationKindOn(n.Kind)) hud?.Invoke(n);
        }
    }
}
