using Clipboard2.Core.AI;

namespace Clipboard2.Core;

public enum PanelFilter { All, Pinned, Text, Images, Files, Snippets, Secrets, ThisApp }

public static class PanelFilters
{
    public static readonly PanelFilter[] All = Enum.GetValues<PanelFilter>();
    public static string Title(this PanelFilter f) => f switch
    {
        PanelFilter.ThisApp => "This App",
        _ => f.ToString(),
    };
}

public abstract record PanelEntry
{
    public sealed record Clip(ClipItem Item) : PanelEntry;
    public sealed record SnippetEntry(Snippet Snippet) : PanelEntry;
    public sealed record SecretEntry(SecretRef Secret) : PanelEntry;

    public string Id => this switch
    {
        Clip c => "c-" + c.Item.Id,
        SnippetEntry s => "s-" + s.Snippet.Id,
        SecretEntry k => "k-" + k.Secret.Id,
        _ => "",
    };

    public ClipItem? ClipItem => (this as Clip)?.Item;

    public SlotTarget SlotTarget => this switch
    {
        Clip c => SlotTarget.ForClip(c.Item.Id),
        SnippetEntry s => SlotTarget.ForSnippet(s.Snippet.Id),
        SecretEntry k => SlotTarget.ForSecret(k.Secret.Id),
        _ => throw new InvalidOperationException(),
    };
}

public enum PanelMode { Browse, Actions, SnippetForm, SaveSecret, Label, EditSecret, AI }

public abstract record PanelAction
{
    public sealed record Paste : PanelAction;
    public sealed record PastePlain : PanelAction;
    public sealed record Copy : PanelAction;
    public sealed record ApplyTransform(Transform Transform) : PanelAction;
    public sealed record Ask(AIAction Action) : PanelAction;
    public sealed record SaveAsSecret : PanelAction;
    public sealed record SetLabel : PanelAction;
    public sealed record SetUpAI : PanelAction;
    public sealed record ClearSlot(int Slot) : PanelAction;
    public sealed record TogglePin : PanelAction;
    public sealed record ShareToGroup : PanelAction;
    public sealed record ShareTo(string GroupId, string GroupName) : PanelAction;
    public sealed record Delete : PanelAction;

    public string Section(string aiName) => this switch
    {
        Paste or PastePlain or Copy => "Paste",
        ApplyTransform => "Transform & Paste",
        Ask or SetUpAI => $"Ask {aiName}",
        ShareTo => "Share to Group",
        _ => "Item",
    };

    public string Title(bool isPinned) => this switch
    {
        Paste => "Paste",
        PastePlain => "Paste as Plain Text",
        Copy => "Copy to Clipboard",
        ApplyTransform t => t.Transform.Title(),
        Ask { Action: AIAction.Instruction i } => $"“{i.Text}”",
        Ask a => a.Action.Title,
        SaveAsSecret => "Save as Secret…",
        SetLabel => "Label…",
        SetUpAI => "Set Up AI…",
        ClearSlot c => $"Remove from Quick Slot Ctrl+{c.Slot}",
        TogglePin => isPinned ? "Unpin" : "Pin",
        ShareToGroup => "Share to Group…",
        ShareTo s => s.GroupName,
        _ => "Delete",
    };
}

/// <summary>Things the panel asks the app to do (paste into the previous app, open Settings…).</summary>
public interface IPanelHost
{
    void ClosePanel();
    void Paste(ClipItem item, Transform? transform);
    void Paste(IReadOnlyList<ClipItem> items, Transform? transform);
    void PasteText(string text, int cursorOffsetFromEnd = 0);
    void Copy(ClipItem item);
    void Copy(IReadOnlyList<ClipItem> items);
    void CopyText(string text);
    void PasteSecret(SecretRef secret);
    void CopySecret(SecretRef secret);
    /// <summary>Copies a secret into a sync group (after confirming with Windows Hello).</summary>
    void ShareSecret(SecretRef secret, string groupId, string groupName);
    string? CurrentClipboardText();
    void OpenSettings();
    IAIStreamingClient MakeAIClient();
    string AIProviderTitle { get; }
    bool IsAIReady { get; }
    string AIShortName { get; }
}

/// <summary>Secret values live outside the database (Credential Manager); this is the panel's view.</summary>
public interface ISecretVault
{
    IReadOnlyList<SecretRef> Secrets { get; }
    IReadOnlySet<string> ValueHashes { get; }
    SecretRef? Add(string name, string value, string? spaceId = null);
    void Rename(SecretRef secret, string name);
    void SetValue(SecretRef secret, string value);
    void Delete(SecretRef secret);
    /// <summary>The value without asking the user — for sync only, never for pasting.</summary>
    string? ReadValue(SecretRef secret);
    /// <summary>Creates or replaces a secret with a known id (a synced secret).</summary>
    void Put(Guid id, string name, string value, string? spaceId);
    event Action? Changed;
}

public sealed class SnippetForm(Snippet snippet, IReadOnlyList<string> fields)
{
    public Snippet Snippet { get; } = snippet;
    public IReadOnlyList<string> Fields { get; } = fields;
    public Dictionary<string, string> Values { get; } = fields.ToDictionary(f => f, _ => "");
}

public sealed class LabelForm(PanelEntry entry)
{
    public PanelEntry Entry { get; } = entry;
    public string Text { get; set; } = entry switch
    {
        PanelEntry.Clip c => c.Item.Label ?? "",
        PanelEntry.SecretEntry s => s.Secret.Name,
        _ => "",
    };
    public bool IsSecret => Entry is PanelEntry.SecretEntry;
}

/// <summary>Name and value of a secret, filled in after Windows Hello. The value lives only as long as the form.</summary>
public sealed class EditSecretForm(SecretRef secret, string value)
{
    public SecretRef Secret { get; } = secret;
    public string OriginalValue { get; } = value;
    public string Name { get; set; } = secret.Name;
    public string Value { get; set; } = value;
}

public sealed class SaveSecretForm(ClipItem item)
{
    public ClipItem Item { get; } = item;
    public string Name { get; set; } = item.SourceName is { } app ? $"Password from {app}" : "New Secret";
}

[Flags] public enum KeyMods { None = 0, Ctrl = 1, Shift = 2, Alt = 4 }
public enum PanelKey { Other, Escape, Up, Down, PageUp, PageDown, Enter, Tab, Delete, Digit, Letter }

/// <summary>A key press, mapped from the UI framework so the logic is testable anywhere.</summary>
public readonly record struct KeyInput(PanelKey Key, KeyMods Mods = KeyMods.None, int Digit = 0, char Letter = '\0')
{
    public bool Ctrl => Mods.HasFlag(KeyMods.Ctrl);
    public bool Shift => Mods.HasFlag(KeyMods.Shift);
    public bool Alt => Mods.HasFlag(KeyMods.Alt);
}

/// <summary>The quick panel: search, filters, selection (incl. multi-select), quick slots, the
/// Ctrl+K action menu, snippet/secret/label forms and AI runs. UI-free.</summary>
public sealed class PanelModel(ClipStore store, Settings settings, QuickSlots slots, ISecretVault secrets, IPanelHost host)
{
    public const int MaxEntries = 300;

    public event Action? Changed;
    /// <summary>A group was picked in the filter row; the host fetches what members sent since the last sync.</summary>
    public event Action? GroupFilterSelected;
    private void Notify() => Changed?.Invoke();

    public string Query { get; private set; } = "";
    public PanelFilter Filter { get; private set; } = PanelFilter.All;
    /// <summary>When set, the list shows only this sync group (and <see cref="Filter"/> is ignored).</summary>
    public string? GroupFilter { get; private set; }
    /// <summary>Sync groups the user belongs to, by id (badges, filters, sharing).</summary>
    public IReadOnlyDictionary<string, string> GroupNames { get; private set; } = new Dictionary<string, string>();
    /// <summary>The signed-in sync user (null when signed out), so own group items show the own username.</summary>
    public Func<SyncSelf?>? Self { get; set; }
    private Dictionary<string, SpaceRecord> _groups = [];
    private Dictionary<(string Space, string LocalId), string?> _authors = [];
    /// <summary>In the action menu: picking the group to share with.</summary>
    public bool IsPickingGroup { get; private set; }
    public List<PanelEntry> Entries { get; private set; } = [];
    public string? SelectedId { get; private set; }
    public HashSet<string> SelectedIds { get; private set; } = [];
    public PanelMode Mode { get; private set; } = PanelMode.Browse;
    public string ActionQuery { get; private set; } = "";
    public int ActionSelection { get; private set; }
    public SnippetForm? SnippetForm { get; private set; }
    public SaveSecretForm? SaveSecretForm { get; private set; }
    public LabelForm? LabelForm { get; private set; }
    public EditSecretForm? EditSecretForm { get; private set; }
    public AIRun? AIRun { get; private set; }
    public string? Notice { get; private set; }
    public AppRef? TargetApp { get; private set; }
    /// <summary>Text selected in another app (Ctrl+Alt+K): a transient item that's never stored.</summary>
    public ClipItem? SelectionItem { get; private set; }
    public bool IsSelectionMode => SelectionItem is not null;
    /// <summary>Bumped on every open so the view scrolls back to the top.</summary>
    public int OpenToken { get; private set; }

    private string? _anchorId;
    private bool _userMovedSelection;

    // MARK: Lifecycle

    public void PrepareForOpen(AppRef? target)
    {
        SelectionItem = null;
        ResetMode();
        Notice = null;
        TargetApp = target;
        Query = "";
        Filter = PanelFilter.All;
        GroupFilter = null;
        _userMovedSelection = false;
        Refresh(resetSelection: true);
        OpenToken++;
        Notify();
    }

    public void PrepareForSelection(string text, AppRef? target)
    {
        PrepareForOpen(target);
        SelectionItem = ClipItem.From(ProcessedCapture.ForText(text, source: target), DateTime.UtcNow);
        Entries = [new PanelEntry.Clip(SelectionItem)];
        Select(Entries[0].Id);
        Mode = PanelMode.Actions;
        Notify();
    }

    public void DidClose()
    {
        SelectionItem = null;
        ResetMode();
    }

    public void ResetMode()
    {
        AIRun?.Cancel();
        AIRun = null;
        SnippetForm = null;
        SaveSecretForm = null;
        LabelForm = null;
        EditSecretForm = null;
        ActionQuery = "";
        ActionSelection = 0;
        IsPickingGroup = false;
        Mode = PanelMode.Browse;
        Notify();
    }

    public void SetQuery(string query)
    {
        if (query == Query) return;
        Query = query;
        Refresh(resetSelection: true);
    }

    public void SetFilter(PanelFilter filter)
    {
        if (filter == Filter && GroupFilter is null) return;
        Filter = filter;
        GroupFilter = null;
        Refresh(resetSelection: true);
    }

    public void SetGroupFilter(string groupId)
    {
        if (GroupFilter == groupId) return;
        GroupFilter = groupId;
        Filter = PanelFilter.All;
        Refresh(resetSelection: true);
        GroupFilterSelected?.Invoke();
    }

    /// <summary>The badge for a group entry: the username of whoever copied it, or the group's name when that isn't
    /// known (older servers). Null for personal items.</summary>
    public string? GroupBadge(PanelEntry entry)
    {
        if (SpaceOf(entry) is not { } space) return null;
        if (!_groups.TryGetValue(space, out var group)) return GroupNames.GetValueOrDefault(space, "Group");
        var self = Self?.Invoke();
        // Not on the server yet (no sync meta): copied here, so it's ours.
        var author = _authors.TryGetValue((space, SyncIdOf(entry)), out var uid) ? uid : self?.Uid;
        return group.AuthorName(author, self);
    }

    /// <summary>The name of the group an entry belongs to, or null for personal items.</summary>
    public string? GroupName(PanelEntry entry) => SpaceOf(entry) is { } space ? GroupNames.GetValueOrDefault(space, "Group") : null;

    private static string SyncIdOf(PanelEntry entry) => entry switch
    {
        PanelEntry.Clip c => ClipStore.SyncId(c.Item.Id),
        PanelEntry.SnippetEntry s => ClipStore.SyncId(s.Snippet.Id),
        PanelEntry.SecretEntry k => Guid.TryParse(k.Secret.Id, out var g) ? ClipStore.SyncId(g) : k.Secret.Id,
        _ => "",
    };

    public void ShowNotice(string text)
    {
        Notice = text;
        Notify();
    }

    public void Refresh(bool resetSelection = false)
    {
        if (SelectionItem is not null)
        {
            Entries = [new PanelEntry.Clip(SelectionItem)];
            Select(Entries[0].Id);
            return;
        }
        var q = Query.Trim();
        var target = TargetApp?.Id;
        _groups = store.Groups().ToDictionary(g => g.Id);
        GroupNames = _groups.ToDictionary(g => g.Key, g => g.Value.DisplayName);
        _authors = _groups.Count == 0 ? [] : store.GroupAuthors();
        if (GroupFilter is not null && !GroupNames.ContainsKey(GroupFilter)) GroupFilter = null;
        var group = GroupFilter;
        var clips = group is not null ? store.ItemsInSpace(group)
            : Filter is PanelFilter.Snippets or PanelFilter.Secrets ? [] : store.AllItems().Where(item => Filter switch
        {
            PanelFilter.Pinned => item.IsPinned,
            PanelFilter.Text => item.Kind.IsTextual(),
            PanelFilter.Images => item.Kind == ClipKind.Image,
            PanelFilter.Files => item.Kind == ClipKind.File,
            PanelFilter.ThisApp => target is not null && string.Equals(item.SourceId, target, StringComparison.OrdinalIgnoreCase),
            _ => true,
        }).ToList();
        // Snippets and secrets join "All" only while searching, so history stays uncluttered.
        var searchingAll = Filter == PanelFilter.All && q.Length > 0;
        var snippets = group is not null ? store.AllSnippets().Where(s => s.SpaceId == group).ToList()
            : Filter == PanelFilter.Snippets || searchingAll ? store.AllSnippets() : [];
        var secretList = group is not null ? secrets.Secrets.Where(s => s.SpaceId == group).ToList()
            : Filter == PanelFilter.Secrets || searchingAll ? secrets.Secrets.ToList() : [];

        List<PanelEntry> result;
        if (q.Length == 0)
        {
            result = [.. clips.Select(c => new PanelEntry.Clip(c)), .. snippets.Select(s => new PanelEntry.SnippetEntry(s)),
                      .. secretList.Select(s => new PanelEntry.SecretEntry(s))];
        }
        else
        {
            var scored = new List<(PanelEntry Entry, int Score, DateTime Date)>();
            foreach (var item in clips)
                if (FuzzyMatcher.Score(q, item.SearchableText) is { } s) scored.Add((new PanelEntry.Clip(item), s, item.LastCopiedAt));
            var lowered = q.ToLowerInvariant();
            foreach (var snippet in snippets)
            {
                var keywordHit = snippet.Keyword.Length > 0 && snippet.Keyword.ToLowerInvariant() == lowered;
                if (FuzzyMatcher.Score(q, $"{snippet.Name} {snippet.Keyword} {snippet.Body}") is { } s)
                    scored.Add((new PanelEntry.SnippetEntry(snippet), s + (keywordHit ? 10_000 : 0), snippet.UpdatedAt));
                else if (keywordHit)
                    scored.Add((new PanelEntry.SnippetEntry(snippet), 10_000, snippet.UpdatedAt));
            }
            foreach (var secret in secretList)   // names only — values never leave the vault for search
                if (FuzzyMatcher.Score(q, secret.Name) is { } s)
                    scored.Add((new PanelEntry.SecretEntry(secret), s + 500, secret.CreatedAt ?? DateTime.MinValue));
            result = [.. scored.OrderByDescending(x => x.Score).ThenByDescending(x => x.Date).Select(x => x.Entry)];
        }
        Entries = result.Take(MaxEntries).ToList();

        if (resetSelection || !_userMovedSelection || Entries.All(e => e.Id != SelectedId))
        {
            Select(Entries.FirstOrDefault()?.Id);
        }
        else
        {
            var live = Entries.Select(e => e.Id).ToHashSet();
            SelectedIds.IntersectWith(live);
        }
        Notify();
    }

    // MARK: Selection

    public int? SelectedIndex => Entries.FindIndex(e => e.Id == SelectedId) is var i and >= 0 ? i : null;
    public PanelEntry? SelectedEntry => SelectedIndex is { } i ? Entries[i] : null;
    public bool IsMultiSelecting => SelectedIds.Count > 1;
    public List<ClipItem> SelectedClips => Entries.Where(e => SelectedIds.Contains(e.Id)).Select(e => e.ClipItem).OfType<ClipItem>().ToList();
    public bool IsSelected(PanelEntry entry) => SelectedIds.Contains(entry.Id);

    public void Select(string? id)
    {
        SelectedId = id;
        SelectedIds = id is null ? [] : [id];
        _anchorId = id;
        Notify();
    }

    public void MoveSelection(int delta, bool extending = false)
    {
        if (Entries.Count == 0) return;
        _userMovedSelection = true;
        var current = SelectedIndex ?? (delta > 0 ? -1 : Entries.Count);
        var next = Math.Clamp(current + delta, 0, Entries.Count - 1);
        if (extending) ExtendSelection(Entries[next].Id); else Select(Entries[next].Id);
    }

    /// <summary>Mouse selection following Windows conventions: Ctrl toggles, Shift selects a range.</summary>
    public void Click(PanelEntry entry, bool ctrl, bool shift)
    {
        _userMovedSelection = true;
        if (ctrl) ToggleSelection(entry.Id);
        else if (shift) ExtendSelection(entry.Id);
        else Select(entry.Id);
    }

    public void ToggleSelection(string id)
    {
        if (SelectedIds.Contains(id) && SelectedIds.Count > 1)
        {
            SelectedIds.Remove(id);
            if (SelectedId == id) SelectedId = Entries.FirstOrDefault(e => SelectedIds.Contains(e.Id))?.Id;
        }
        else
        {
            SelectedIds.Add(id);
            SelectedId = id;
        }
        _anchorId = id;
        Notify();
    }

    public void ExtendSelection(string id)
    {
        var from = Entries.FindIndex(e => e.Id == (_anchorId ?? SelectedId));
        var to = Entries.FindIndex(e => e.Id == id);
        if (from < 0 || to < 0) { Select(id); return; }
        SelectedIds = Entries.Skip(Math.Min(from, to)).Take(Math.Abs(to - from) + 1).Select(e => e.Id).ToHashSet();
        SelectedId = id;
        Notify();
    }

    public void SelectAll()
    {
        if (Entries.Count == 0) return;
        _anchorId = Entries[0].Id;
        SelectedIds = Entries.Select(e => e.Id).ToHashSet();
        SelectedId ??= Entries[0].Id;
        Notify();
    }

    /// <summary>Tab: the built-in filters, then one per sync group.</summary>
    public void CycleFilter(bool forward)
    {
        List<(PanelFilter Filter, string? Group)> all = [.. PanelFilters.All.Select(f => (f, (string?)null)),
            .. store.Groups().Select(g => (PanelFilter.All, (string?)g.Id))];
        var index = all.FindIndex(x => GroupFilter is not null ? x.Group == GroupFilter : x.Group is null && x.Filter == Filter);
        var next = all[(Math.Max(index, 0) + (forward ? 1 : all.Count - 1)) % all.Count];
        if (next.Group is { } g) SetGroupFilter(g); else SetFilter(next.Filter);
    }

    // MARK: Quick slots

    /// <summary>The Ctrl+number shown on a row: its slot, or its position if that number is free.</summary>
    public (int Number, bool IsSlot)? ShortcutNumber(PanelEntry entry, int index)
    {
        if (slots.SlotFor(entry.SlotTarget) is { } slot) return (slot, true);
        var position = index + 1;
        return position <= 9 && slots.Target(position) is null ? (position, false) : null;
    }

    public PanelEntry? EntryForSlot(int slot)
    {
        if (slots.Target(slot) is not { } target) return null;
        PanelEntry? entry = target.Kind switch
        {
            SlotKind.Clip when Guid.TryParse(target.Id, out var id) && store.Find(id) is { } item => new PanelEntry.Clip(item),
            SlotKind.Snippet when Guid.TryParse(target.Id, out var id) && store.AllSnippets().FirstOrDefault(s => s.Id == id) is { } s => new PanelEntry.SnippetEntry(s),
            SlotKind.Secret when secrets.Secrets.FirstOrDefault(s => s.Id == target.Id) is { } k => new PanelEntry.SecretEntry(k),
            _ => null,
        };
        if (entry is null) slots.Clear(slot);
        return entry;
    }

    public void ActivateShortcut(int number, Transform? transform = null)
    {
        if (EntryForSlot(number) is { } entry) Activate(entry, transform);
        else if (number - 1 < Entries.Count) Activate(Entries[number - 1], transform);
    }

    public void AssignSelection(int slot)
    {
        if (SelectedEntry is not { } entry) return;
        if (entry is PanelEntry.Clip { Item.IsPinned: false } clip) store.TogglePin(clip.Item);
        slots.Assign(entry.SlotTarget, slot);
        Refresh();
        ShowNotice($"Assigned to Ctrl+{slot}");
    }

    // MARK: Activation

    public void Activate(PanelEntry? entry, Transform? transform = null)
    {
        switch (entry)
        {
            case PanelEntry.Clip c when c.Item == SelectionItem:
                host.ClosePanel();
                host.PasteText(transform?.Apply(c.Item.Text) ?? c.Item.Text);
                break;
            case PanelEntry.Clip c:
                host.ClosePanel();
                host.Paste(c.Item, transform);
                break;
            case PanelEntry.SnippetEntry s:
                var fields = SnippetExpander.CustomFields(s.Snippet.Body);
                if (fields.Count == 0)
                {
                    host.ClosePanel();
                    PasteSnippet(s.Snippet, new Dictionary<string, string>());
                }
                else
                {
                    SnippetForm = new SnippetForm(s.Snippet, fields);
                    Mode = PanelMode.SnippetForm;
                    Notify();
                }
                break;
            case PanelEntry.SecretEntry k:
                host.ClosePanel();
                host.PasteSecret(k.Secret);
                break;
        }
    }

    public void PasteSelection(Transform? transform = null)
    {
        var clips = SelectedClips;
        if (clips.Count == 0) return;
        if (clips.Count == 1) { Activate(new PanelEntry.Clip(clips[0]), transform); return; }
        host.ClosePanel();
        host.Paste(clips, transform);
    }

    public void SubmitSnippetForm()
    {
        if (SnippetForm is not { } form) return;
        host.ClosePanel();
        PasteSnippet(form.Snippet, form.Values);
    }

    private void PasteSnippet(Snippet snippet, IReadOnlyDictionary<string, string> values)
    {
        var expansion = SnippetExpander.Expand(snippet.Body, values, host.CurrentClipboardText());
        host.PasteText(expansion.Text, expansion.CursorOffsetFromEnd);
    }

    public void BeginLabel(PanelEntry entry)
    {
        if (entry is PanelEntry.SnippetEntry) return;
        Select(entry.Id);
        LabelForm = new LabelForm(entry);
        Mode = PanelMode.Label;
        Notify();
    }

    public void SubmitLabel()
    {
        if (LabelForm is not { } form) return;
        switch (form.Entry)
        {
            case PanelEntry.Clip c:
                store.SetLabel(form.Text, c.Item);
                ShowNotice(c.Item.Label is null ? "Label removed" : "Labelled and pinned");
                break;
            case PanelEntry.SecretEntry s when form.Text.Trim().Length > 0:
                secrets.Rename(s.Secret, form.Text.Trim());
                break;
            default:
                return;
        }
        var id = SelectedId;
        ResetMode();
        Refresh();
        if (id is not null) Select(id);
    }

    /// <summary>Opens the edit form once the value has been unlocked.</summary>
    public void ShowEditSecret(SecretRef secret, string value)
    {
        Select(new PanelEntry.SecretEntry(secret).Id);
        EditSecretForm = new EditSecretForm(secret, value);
        Mode = PanelMode.EditSecret;
        Notify();
    }

    public void SubmitEditSecret()
    {
        if (EditSecretForm is not { } form) return;
        var name = form.Name.Trim();
        if (name.Length == 0 || form.Value.Length == 0) return;
        if (name != form.Secret.Name) secrets.Rename(form.Secret, name);
        if (form.Value != form.OriginalValue) secrets.SetValue(form.Secret, form.Value);
        var id = SelectedId;
        ResetMode();
        Refresh();
        if (id is not null) Select(id);
        ShowNotice($"Saved “{name}”");
    }

    public void BeginSaveSecret(ClipItem item)
    {
        Select(new PanelEntry.Clip(item).Id);
        SaveSecretForm = new SaveSecretForm(item);
        Mode = PanelMode.SaveSecret;
        Notify();
    }

    public void SubmitSaveSecret()
    {
        if (SaveSecretForm is not { } form) return;
        var name = form.Name.Trim();
        if (name.Length == 0 || secrets.Add(name, form.Item.Text) is null)
        {
            ShowNotice("Couldn't save to Credential Manager");
            return;
        }
        if (form.Item != SelectionItem) store.Delete(form.Item);
        ResetMode();
        Refresh();
        ShowNotice($"Saved “{name}” to Secrets and removed it from history");
    }

    // MARK: Action menu

    public void OpenActions()
    {
        if (SelectedEntry is null && !IsMultiSelecting) return;
        ActionQuery = "";
        ActionSelection = 0;
        IsPickingGroup = false;
        Mode = PanelMode.Actions;
        Notify();
    }

    /// <summary>Switches the action list to the sync groups to share with.</summary>
    public void BeginShareToGroup()
    {
        if (SelectedEntry is null && !IsMultiSelecting) return;
        ActionQuery = "";
        ActionSelection = 0;
        IsPickingGroup = true;
        Mode = PanelMode.Actions;
        Notify();
    }

    private List<PanelAction> ShareActions(string? exceptGroup) =>
        [.. store.Groups().Where(g => g.Id != exceptGroup).Select(g => new PanelAction.ShareTo(g.Id, g.DisplayName))];

    private bool CanShare => store.Groups().Count > 0;

    public void SetActionQuery(string query)
    {
        if (query == ActionQuery) return;
        ActionQuery = query;
        ActionSelection = 0;
        Notify();
    }

    public string AIName => host.IsAIReady ? host.AIShortName : "AI";

    private List<PanelAction> AIActions =>
        host.IsAIReady
            ? [.. AIAction.BuiltIn.Select(a => new PanelAction.Ask(a)), .. settings.CustomPrompts.Select(p => new PanelAction.Ask(new AIAction.Custom(p)))]
            : [new PanelAction.SetUpAI()];

    private static IEnumerable<PanelAction> TransformActions =>
        Transforms.All.Where(t => t != Transform.PlainText).Select(t => new PanelAction.ApplyTransform(t));

    public List<PanelAction> AvailableActions
    {
        get
        {
            if (IsMultiSelecting)
            {
                var clips = SelectedClips;
                if (clips.Count == 0) return [];
                List<PanelAction> multi = [new PanelAction.Paste()];
                if (clips.All(c => c.Kind.IsTextual())) multi.AddRange([new PanelAction.PastePlain(), new PanelAction.Copy(), .. TransformActions]);
                else multi.Add(new PanelAction.Copy());
                if (CanShare) multi.Add(new PanelAction.ShareToGroup());
                return [.. multi, new PanelAction.TogglePin(), new PanelAction.Delete()];
            }
            if (SelectedEntry is not { } entry) return [];
            List<PanelAction> actions = [new PanelAction.Paste()];
            switch (entry)
            {
                case PanelEntry.Clip c when c.Item == SelectionItem:
                    return [new PanelAction.Copy(), .. AIActions, .. TransformActions, new PanelAction.SaveAsSecret(),
                            .. CanShare ? [new PanelAction.ShareToGroup()] : Array.Empty<PanelAction>()];
                case PanelEntry.Clip c:
                    if (c.Item.Kind.IsTextual()) actions.Add(new PanelAction.PastePlain());
                    actions.Add(new PanelAction.Copy());
                    if (c.Item.Kind.IsTextual())
                    {
                        actions.AddRange(TransformActions);
                        actions.AddRange(AIActions);
                        actions.Add(new PanelAction.SaveAsSecret());
                    }
                    actions.Add(new PanelAction.SetLabel());
                    actions.Add(new PanelAction.TogglePin());
                    break;
                case PanelEntry.SecretEntry:
                    actions.Add(new PanelAction.Copy());
                    actions.Add(new PanelAction.SetLabel());
                    break;
            }
            if (CanShare) actions.Add(new PanelAction.ShareToGroup());
            if (slots.SlotFor(entry.SlotTarget) is { } slot) actions.Add(new PanelAction.ClearSlot(slot));
            if (entry is PanelEntry.Clip or PanelEntry.SecretEntry) actions.Add(new PanelAction.Delete());
            return actions;
        }
    }

    public List<PanelAction> FilteredActions
    {
        get
        {
            var q = ActionQuery.Trim();
            if (IsPickingGroup)
            {
                var groups = ShareActions(!IsMultiSelecting && SelectedEntry is { } e ? SpaceOf(e) : null);
                return q.Length == 0 ? groups
                    : [.. groups.Select(a => (Action: a, Score: FuzzyMatcher.Score(q, a.Title(false)))).Where(x => x.Score is not null)
                        .OrderByDescending(x => x.Score).Select(x => x.Action)];
            }
            if (q.Length == 0) return AvailableActions;
            var pinned = SelectedEntry?.ClipItem?.IsPinned ?? false;
            var matches = AvailableActions
                .Select(a => (Action: a, Score: FuzzyMatcher.Score(q, a.Title(pinned) + " " + a.Section(AIName))))
                .Where(x => x.Score is not null).OrderByDescending(x => x.Score).Select(x => x.Action).ToList();
            // Anything typed can also be sent as a one-off instruction for the selected text.
            if (!IsMultiSelecting && SelectedEntry?.ClipItem?.Kind.IsTextual() == true)
            {
                if (host.IsAIReady) matches.Add(new PanelAction.Ask(new AIAction.Instruction(q)));
                else if (!matches.Contains(new PanelAction.SetUpAI())) matches.Add(new PanelAction.SetUpAI());
            }
            return matches;
        }
    }

    public void Perform(PanelAction action)
    {
        if (IsMultiSelecting) { PerformOnSelection(action); return; }
        if (SelectedEntry is not { } entry) return;
        var item = entry.ClipItem;
        switch (action)
        {
            case PanelAction.Paste: Activate(entry); break;
            case PanelAction.PastePlain: Activate(entry, Transform.PlainText); break;
            case PanelAction.Copy:
                if (item is not null && item == SelectionItem) host.CopyText(item.Text);
                else if (item is not null) host.Copy(item);
                else if (entry is PanelEntry.SecretEntry k) host.CopySecret(k.Secret);
                host.ClosePanel();
                break;
            case PanelAction.ApplyTransform t when item is not null:
                if (t.Transform.Apply(item.Text) is not { } result)
                {
                    ShowNotice($"Can't apply “{t.Transform.Title()}” to this item");
                    return;
                }
                if (item != SelectionItem) store.Touch(item);
                host.ClosePanel();
                host.PasteText(result);
                break;
            case PanelAction.Ask ask when item is not null:
                var run = new AIRun(ask.Action, item, host.AIProviderTitle);
                AIRun = run;
                Mode = PanelMode.AI;
                run.Changed += Notify;
                run.Start(host.MakeAIClient);
                Notify();
                break;
            case PanelAction.SaveAsSecret when item is not null: BeginSaveSecret(item); break;
            case PanelAction.SetLabel: BeginLabel(entry); break;
            case PanelAction.SetUpAI:
                host.ClosePanel();
                host.OpenSettings();
                break;
            case PanelAction.ClearSlot c:
                slots.Clear(c.Slot);
                Mode = PanelMode.Browse;
                Refresh();
                break;
            case PanelAction.TogglePin:
                TogglePinOnSelection();
                Mode = PanelMode.Browse;
                Notify();
                break;
            case PanelAction.ShareToGroup:
                BeginShareToGroup();
                break;
            case PanelAction.ShareTo share:
                Share(entry, share);
                break;
            case PanelAction.Delete:
                Mode = PanelMode.Browse;
                DeleteSelection(includingSecrets: true);
                break;
        }
    }

    private void PerformOnSelection(PanelAction action)
    {
        var clips = SelectedClips;
        switch (action)
        {
            case PanelAction.Paste: PasteSelection(); break;
            case PanelAction.PastePlain: PasteSelection(Transform.PlainText); break;
            case PanelAction.Copy:
                host.Copy(clips);
                host.ClosePanel();
                break;
            case PanelAction.ApplyTransform t:
                var parts = clips.Select(c => t.Transform.Apply(c.Text)).ToList();
                if (parts.Any(p => p is null))
                {
                    ShowNotice($"Can't apply “{t.Transform.Title()}” to every selected item");
                    return;
                }
                host.ClosePanel();
                host.PasteText(string.Join("\n", parts));
                break;
            case PanelAction.TogglePin:
                TogglePinOnSelectedClips();
                Mode = PanelMode.Browse;
                break;
            case PanelAction.ShareToGroup:
                BeginShareToGroup();
                break;
            case PanelAction.ShareTo share:
                foreach (var c in clips.Where(c => c.SpaceId != share.GroupId)) store.CopyToSpace(c, share.GroupId);
                ResetMode();
                Refresh();
                ShowNotice($"Shared {clips.Count} items to “{share.GroupName}”");
                break;
            case PanelAction.Delete:
                Mode = PanelMode.Browse;
                DeleteSelectedClips();
                break;
        }
    }

    private static string? SpaceOf(PanelEntry entry) => entry switch
    {
        PanelEntry.Clip c => c.Item.SpaceId,
        PanelEntry.SnippetEntry s => s.Snippet.SpaceId,
        PanelEntry.SecretEntry k => k.Secret.SpaceId,
        _ => null,
    };

    /// <summary>Copies the entry into the group with a new id; the original stays where it is.</summary>
    private void Share(PanelEntry entry, PanelAction.ShareTo share)
    {
        switch (entry)
        {
            case PanelEntry.Clip c when c.Item == SelectionItem:
                store.Ingest(ProcessedCapture.ForText(c.Item.Text, source: c.Item.Source), spaceId: share.GroupId);
                host.ClosePanel();
                return;
            case PanelEntry.Clip c:
                store.CopyToSpace(c.Item, share.GroupId);
                break;
            case PanelEntry.SnippetEntry s:
                store.CopySnippetToSpace(s.Snippet, share.GroupId);
                break;
            case PanelEntry.SecretEntry k:
                host.ShareSecret(k.Secret, share.GroupId, share.GroupName);
                ResetMode();
                return;
        }
        ResetMode();
        Refresh();
        ShowNotice($"Shared to “{share.GroupName}”");
    }

    // MARK: AI result

    public void PasteAIOutput()
    {
        if (AIRun is not { Output.Length: > 0 } run) return;
        var text = run.Output;
        host.ClosePanel();
        host.PasteText(text);
    }

    public void CopyAIOutput()
    {
        if (AIRun is not { Output.Length: > 0 } run) return;
        host.CopyText(run.Output);
        ShowNotice("Copied");
    }

    public void ReplaceItemWithAIOutput()
    {
        if (AIRun is not { IsFinished: true } run || run.Item == SelectionItem) return;
        store.ReplaceText(run.Item, run.Output);
        ResetMode();
        Refresh();
        Select(new PanelEntry.Clip(run.Item).Id);
        ShowNotice("Item replaced");
    }

    public void RerunAI()
    {
        if (AIRun is not { } old) return;
        old.Cancel();
        var run = new AIRun(old.Action, old.Item, host.AIProviderTitle);
        AIRun = run;
        run.Changed += Notify;
        run.Start(host.MakeAIClient);
        Notify();
    }

    // MARK: Item actions

    public void TogglePinOnSelection()
    {
        if (SelectedEntry?.ClipItem is not { } item) return;
        store.TogglePin(item);
        Refresh();
    }

    public void TogglePinOnSelectedClips()
    {
        var clips = SelectedClips;
        var pin = clips.Any(c => !c.IsPinned);
        foreach (var c in clips.Where(c => c.IsPinned != pin)) store.TogglePin(c);
        Refresh();
        ShowNotice(pin ? $"Pinned {clips.Count} items" : $"Unpinned {clips.Count} items");
    }

    /// <summary>Delete never removes secrets by accident; Ctrl+K → Delete does.</summary>
    public void DeleteSelection(bool includingSecrets = false)
    {
        if (SelectedEntry is not { } entry || SelectedIndex is not { } index) return;
        switch (entry)
        {
            case PanelEntry.Clip c when c.Item != SelectionItem:
                slots.Remove(entry.SlotTarget);
                store.Delete(c.Item);
                break;
            case PanelEntry.SecretEntry k when includingSecrets:
                slots.Remove(entry.SlotTarget);
                secrets.Delete(k.Secret);
                break;
            default:
                return;
        }
        Refresh();
        if (Entries.Count > 0) Select(Entries[Math.Min(index, Entries.Count - 1)].Id);
    }

    public void DeleteSelectedClips()
    {
        var clips = SelectedClips;
        if (clips.Count == 0) return;
        var first = Entries.FindIndex(e => SelectedIds.Contains(e.Id));
        foreach (var c in clips)
        {
            slots.Remove(SlotTarget.ForClip(c.Id));
            store.Delete(c);
        }
        Refresh();
        if (Entries.Count > 0) Select(Entries[Math.Min(Math.Max(first, 0), Entries.Count - 1)].Id);
        ShowNotice($"Deleted {clips.Count} items");
    }

    // MARK: Keyboard

    /// <summary>True when handled (the search box must not see it).</summary>
    public bool HandleKey(KeyInput key) => Mode switch
    {
        PanelMode.Browse => HandleBrowseKey(key),
        PanelMode.Actions => HandleActionKey(key),
        PanelMode.SnippetForm or PanelMode.SaveSecret or PanelMode.Label or PanelMode.EditSecret => HandleFormKey(key),
        _ => HandleAIKey(key),
    };

    private bool HandleBrowseKey(KeyInput key)
    {
        switch (key.Key)
        {
            case PanelKey.Escape: host.ClosePanel(); return true;
            case PanelKey.Up: MoveSelection(-1, key.Shift); return true;
            case PanelKey.Down: MoveSelection(1, key.Shift); return true;
            case PanelKey.PageUp: MoveSelection(-8, key.Shift); return true;
            case PanelKey.PageDown: MoveSelection(8, key.Shift); return true;
            case PanelKey.Enter:
                var plain = key.Shift ? Transform.PlainText : (Transform?)null;
                if (IsMultiSelecting) PasteSelection(plain); else Activate(SelectedEntry, plain);
                return true;
            case PanelKey.Tab: CycleFilter(!key.Shift); return true;
            case PanelKey.Delete:
                // With text in the search box, Delete/Ctrl+Backspace edit the text.
                if (Query.Length > 0) return false;
                if (IsMultiSelecting) DeleteSelectedClips(); else DeleteSelection();
                return true;
            case PanelKey.Digit when key.Ctrl:
                if (key.Shift) AssignSelection(key.Digit); else ActivateShortcut(key.Digit);
                return true;
            case PanelKey.Letter when key.Ctrl:
                switch (char.ToLowerInvariant(key.Letter))
                {
                    case 'p':
                        if (IsMultiSelecting) TogglePinOnSelectedClips(); else TogglePinOnSelection();
                        return true;
                    case 'k': OpenActions(); return true;
                    case 'a' when Query.Length == 0: SelectAll(); return true;
                    case ',':
                        host.ClosePanel();
                        host.OpenSettings();
                        return true;
                }
                return false;
            default:
                return false;
        }
    }

    private bool HandleActionKey(KeyInput key)
    {
        var actions = FilteredActions;
        switch (key.Key)
        {
            case PanelKey.Escape:
                if (IsPickingGroup) { IsPickingGroup = false; ActionQuery = ""; ActionSelection = 0; Notify(); }
                else if (IsSelectionMode) host.ClosePanel();
                else { Mode = PanelMode.Browse; Notify(); }
                return true;
            case PanelKey.Up: ActionSelection = Math.Max(0, ActionSelection - 1); Notify(); return true;
            case PanelKey.Down: ActionSelection = Math.Min(Math.Max(0, actions.Count - 1), ActionSelection + 1); Notify(); return true;
            case PanelKey.Enter:
                if (ActionSelection < actions.Count) Perform(actions[ActionSelection]);
                return true;
            case PanelKey.Letter when key.Ctrl && char.ToLowerInvariant(key.Letter) == 'k':
                Mode = PanelMode.Browse;
                Notify();
                return true;
            default:
                return false;   // typing and text editing go to the filter box
        }
    }

    private bool HandleFormKey(KeyInput key)
    {
        switch (key.Key)
        {
            case PanelKey.Escape: ResetMode(); return true;
            case PanelKey.Enter:
                switch (Mode)
                {
                    case PanelMode.SaveSecret: SubmitSaveSecret(); break;
                    case PanelMode.Label: SubmitLabel(); break;
                    case PanelMode.EditSecret: SubmitEditSecret(); break;
                    default: SubmitSnippetForm(); break;
                }
                return true;
            default: return false;
        }
    }

    private bool HandleAIKey(KeyInput key)
    {
        switch (key.Key)
        {
            case PanelKey.Escape:
                if (IsSelectionMode)
                {
                    AIRun?.Cancel();
                    AIRun = null;
                    Mode = PanelMode.Actions;
                    Notify();
                }
                else ResetMode();
                return true;
            case PanelKey.Enter:
                if (AIRun?.IsFinished == true) PasteAIOutput();
                return true;
            case PanelKey.Letter when key.Ctrl:
                if (char.ToLowerInvariant(key.Letter) == 'c') CopyAIOutput();
                if (char.ToLowerInvariant(key.Letter) == 'r') ReplaceItemWithAIOutput();
                return true;
            default:
                return true;
        }
    }
}
