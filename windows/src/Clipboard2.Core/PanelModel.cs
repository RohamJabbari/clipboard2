using Clipboard2.Core.AI;
using Clipboard2.Core.Sync;

namespace Clipboard2.Core;

/// <summary><see cref="Labelled"/> is the Saved chip: the raw name stays so stored values keep working. Text, Images,
/// Files, Snippets and Secrets were filters before 1.7 (Saved holds secrets and snippets now); they stay so old values
/// still parse, and read as All (<see cref="PanelFilters.Normalized"/>).</summary>
public enum PanelFilter { All, Labelled, Text, Images, Files, Snippets, Secrets, ThisApp, Inbox }

public static class PanelFilters
{
    public static readonly PanelFilter[] All = Enum.GetValues<PanelFilter>();
    /// <summary>Filters that are no longer offered.</summary>
    public static bool IsRemoved(this PanelFilter f) =>
        f is PanelFilter.Text or PanelFilter.Images or PanelFilter.Files or PanelFilter.Snippets or PanelFilter.Secrets;
    /// <summary>A removed filter falls back to All.</summary>
    public static PanelFilter Normalized(this PanelFilter f) => f.IsRemoved() ? PanelFilter.All : f;
    /// <summary>The chips always shown: All · Saved · This App. Inbox joins them once there are contacts
    /// (<see cref="PanelModel.ChipFilters"/>), and the groups follow.</summary>
    public static readonly PanelFilter[] Chips = [PanelFilter.All, PanelFilter.Labelled, PanelFilter.ThisApp];
    public static string Title(this PanelFilter f) => f switch
    {
        PanelFilter.ThisApp => "This App",
        PanelFilter.Labelled => "Saved",
        _ => f.ToString(),
    };
}

public abstract record PanelEntry
{
    public sealed record Clip(ClipItem Item) : PanelEntry;
    public sealed record SnippetEntry(Snippet Snippet) : PanelEntry;
    public sealed record SecretEntry(SecretRef Secret) : PanelEntry;
    /// <summary>A folder row in Saved, with the number of saved clips in it.</summary>
    public sealed record FolderEntry(ClipFolder Folder, int Count, int Folders = 0) : PanelEntry;
    /// <summary>One of this user's authenticators (owner: it has the seed).</summary>
    public sealed record AuthenticatorEntry(Authenticator Authenticator) : PanelEntry;
    /// <summary>An authenticator shared with this user: codes only.</summary>
    public sealed record SharedCodeEntry(SharedAuthenticator Shared) : PanelEntry;
    /// <summary>The one-off "Add to Authenticator" row at the top of All after an otpauth link was copied.</summary>
    public sealed record OtpSuggestion(OtpAuthDraft Draft) : PanelEntry;

    public string Id => this switch
    {
        Clip c => "c-" + c.Item.Id,
        SnippetEntry s => "s-" + s.Snippet.Id,
        SecretEntry k => "k-" + k.Secret.Id,
        FolderEntry f => "f-" + f.Folder.Id,
        AuthenticatorEntry a => "a-" + a.Authenticator.Id,
        SharedCodeEntry o => "o-" + o.Shared.SpaceId,
        OtpSuggestion => "otp-suggestion",
        _ => "",
    };

    public ClipItem? ClipItem => (this as Clip)?.Item;

    /// <summary>Folders can't go in a quick slot: theirs never matches one.</summary>
    public SlotTarget SlotTarget => this switch
    {
        Clip c => SlotTarget.ForClip(c.Item.Id),
        SnippetEntry s => SlotTarget.ForSnippet(s.Snippet.Id),
        SecretEntry k => SlotTarget.ForSecret(k.Secret.Id),
        _ => new SlotTarget(SlotKind.Clip, "folder:" + Id),
    };
}

public enum PanelMode { Browse, Actions, SnippetForm, SaveSecret, Label, EditSecret, AI, FolderName, AuthenticatorForm, AuthenticatorSecret, AuthenticatorPeople, ConfirmDelete, AddItems }

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
    /// <summary>Saves an unsaved clip without a label.</summary>
    public sealed record AddToSaved : PanelAction;
    /// <summary>Add to Saved for another member's group item, which only its author or the group's owner may change:
    /// a personal copy, saved at the root of the personal Saved.</summary>
    public sealed record SaveCopy : PanelAction;
    /// <summary>For items saved without a label (a labelled one goes when its label does). Also leaves the folder.</summary>
    public sealed record RemoveFromSaved : PanelAction;
    /// <summary>Lists the folders the selection can go into: its space's, and for group items the personal ones too.</summary>
    public sealed record MoveToFolder : PanelAction;
    /// <param name="SectionTitle">The space the folder is in ("‹Group›" or "Mine") when the picker lists two; null
    /// reads "Move to Folder".</param>
    public sealed record MoveTo(Guid FolderId, string FolderName, string? SectionTitle = null) : PanelAction;
    /// <summary>Asks for a name, creates the folder and moves the selection in. <paramref name="Mine"/>: a personal
    /// folder, which group items are copied into.</summary>
    public sealed record MoveToNewFolder(bool Mine = false, string? SectionTitle = null, Guid? ParentId = null, string? ParentName = null) : PanelAction;
    /// <summary>A new folder inside the selected folder.</summary>
    public sealed record NewFolderInside : PanelAction;
    /// <summary>Share to Group's second step when the group has folders: where in the group's Saved the copies go
    /// (null: the root).</summary>
    public sealed record ShareInto(string GroupId, string GroupName, Guid? FolderId, string FolderTitle) : PanelAction;
    /// <summary>Back to the root of Saved; the clip stays saved.</summary>
    public sealed record RemoveFromFolder : PanelAction;
    public sealed record OpenFolder : PanelAction;
    public sealed record RenameFolder : PanelAction;
    /// <summary>Its clips move to the root of Saved.</summary>
    public sealed record DeleteFolder : PanelAction;
    /// <summary>Delete, worded for group items: it deletes the item for everyone in the group.</summary>
    public sealed record RemoveFromGroup : PanelAction;
    /// <summary>Saves into the folder chosen in Settings (Downloads unless changed), named after it.</summary>
    public sealed record SaveToFolder(string FolderName) : PanelAction;
    /// <summary>Asks for a folder, then saves there.</summary>
    public sealed record SaveToChosenFolder : PanelAction;
    public sealed record ShareToGroup : PanelAction;
    public sealed record ShareTo(string GroupId, string GroupName) : PanelAction;
    public sealed record SendTo(string DeviceId, string DeviceName) : PanelAction;
    /// <summary>Sends a copy into a contact's space: it shows up in their Inbox.</summary>
    public sealed record SendToContact(string SpaceId, string ContactName) : PanelAction;
    /// <summary>The large preview (Ctrl+Y).</summary>
    public sealed record Preview : PanelAction;
    public sealed record Delete : PanelAction;
    // Authenticators
    public sealed record AddAuthenticator : PanelAction;
    public sealed record PasteCode : PanelAction;
    public sealed record CopyCode : PanelAction;
    public sealed record RenameAuthenticator : PanelAction;
    public sealed record ShareAuthenticator : PanelAction;
    public sealed record ShareAuthenticatorWith(string Uid, string Name) : PanelAction;
    public sealed record AuthenticatorPeople : PanelAction;
    public sealed record TransferAuthenticator : PanelAction;
    public sealed record TransferAuthenticatorTo(string Uid, string Name) : PanelAction;
    public sealed record ShowAuthenticatorSecret : PanelAction;
    public sealed record DeleteAuthenticator : PanelAction;
    public sealed record LeaveAuthenticator : PanelAction;

    /// <summary>The key that does it, shown next to its title.</summary>
    public string? Shortcut => this switch
    {
        SetLabel => "Ctrl+L",
        MoveToFolder => "Ctrl+Shift+M",
        Preview => "Ctrl+Y",
        _ => null,
    };

    public string Section(string aiName) => this switch
    {
        Paste or PastePlain or Copy => "Paste",
        ApplyTransform => "Transform & Paste",
        Ask or SetUpAI => $"Ask {aiName}",
        ShareTo => "Share to Group",
        ShareInto s => $"Share to “{s.GroupName}”",
        SendTo => "Send to Device",
        SendToContact => "Send to Contact",
        MoveTo m => m.SectionTitle ?? "Move to Folder",
        MoveToNewFolder m => m.SectionTitle ?? "Move to Folder",
        OpenFolder or RenameFolder or DeleteFolder or NewFolderInside => "Folder",
        PasteCode or CopyCode => "Paste",
        ShareAuthenticatorWith => "Share with",
        TransferAuthenticatorTo => "Transfer to",
        AddAuthenticator or RenameAuthenticator or ShareAuthenticator or AuthenticatorPeople or TransferAuthenticator
            or ShowAuthenticatorSecret or DeleteAuthenticator or LeaveAuthenticator => "Authenticator",
        _ => "Item",
    };

    public string Title => this switch
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
        AddToSaved => "Add to Saved",
        SaveCopy => "Save a Copy",
        ShareInto s => s.FolderTitle,
        RemoveFromSaved => "Remove from Saved",
        MoveToFolder => "Move to Folder…",
        MoveTo m => m.FolderName,
        MoveToNewFolder { ParentName: { } parentName } => $"New Folder in {parentName}…",
        MoveToNewFolder => "New Folder…",
        RemoveFromFolder => "Move to Top Level",
        NewFolderInside => "New Folder Inside…",
        OpenFolder => "Open",
        RenameFolder => "Rename…",
        DeleteFolder => "Delete Folder",
        RemoveFromGroup => "Remove from Group",
        SaveToFolder f => $"Save to {f.FolderName}",
        SaveToChosenFolder => "Save to…",
        ShareToGroup => "Share to Group…",
        ShareTo s => s.GroupName,
        SendTo d => $"Send to {d.DeviceName}",
        SendToContact c => $"Send to {c.ContactName}",
        Preview => "Preview",
        AddAuthenticator => "Add to Authenticator…",
        PasteCode => "Paste Code",
        CopyCode => "Copy Code",
        RenameAuthenticator => "Rename…",
        ShareAuthenticator => "Share…",
        ShareAuthenticatorWith s => s.Name,
        AuthenticatorPeople => "People…",
        TransferAuthenticator => "Transfer Ownership…",
        TransferAuthenticatorTo t => t.Name,
        ShowAuthenticatorSecret => "Show Secret / QR",
        DeleteAuthenticator => "Delete",
        LeaveAuthenticator => "Leave",
        _ => "Delete",
    };
}

/// <summary>Another signed-in device of the same account, for "Send to ‹device›".</summary>
public sealed record DeviceTarget(string Id, string Name);

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
    /// <summary>Copies secrets (new ids) into a space: a group (Share to Group) or, with null, the personal one (a
    /// group's secret saved to a personal folder). One Windows Hello confirmation for all of them, asking to
    /// <paramref name="reason"/>. Each copy goes into <paramref name="folderId"/> when given. Shows
    /// <paramref name="notice"/> when done.</summary>
    void CopySecrets(IReadOnlyList<SecretRef> secrets, string? spaceId, Guid? folderId, string reason, string notice);
    /// <summary>Like <see cref="CopySecrets"/>, each into its own folder (a shared folder tree), with one Windows
    /// Hello confirmation.</summary>
    void CopySecretsToFolders(IReadOnlyList<(SecretRef Secret, Guid? FolderId)> secrets, string? spaceId, string reason, string notice)
    {
        foreach (var group in secrets.GroupBy(s => s.FolderId)) CopySecrets([.. group.Select(s => s.Secret)], spaceId, group.Key, reason, notice);
    }
    string? CurrentClipboardText();
    void OpenSettings();
    /// <summary>The folder "Save to ‹folder›" writes to (Settings, or the user's Downloads folder).</summary>
    string SaveFolder { get; }
    /// <summary>Asks the user for a folder; null when cancelled.</summary>
    string? ChooseSaveFolder();
    IAIStreamingClient MakeAIClient();
    string AIProviderTitle { get; }
    bool IsAIReady { get; }
    string AIShortName { get; }
    /// <summary>Pastes text that must never be recorded (an authenticator code): transient, cleared after 30 s.</summary>
    void PasteTransient(string text) => PasteText(text);
    /// <summary>Copies text that must never be recorded (an authenticator code): transient, cleared after 30 s.</summary>
    void CopyTransient(string text) => CopyText(text);
    /// <summary>Windows Hello before showing a seed; false when cancelled or unavailable.</summary>
    Task<bool> VerifyUserAsync(string reason) => Task.FromResult(true);
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
        PanelEntry.FolderEntry f => f.Folder.Label ?? "",
        _ => "",
    };
    public bool IsSecret => Entry is PanelEntry.SecretEntry;
    public bool IsFolder => Entry is PanelEntry.FolderEntry;
    /// <summary>Ctrl+L on several clips: the same label goes on each of these too.</summary>
    public IReadOnlyList<ClipItem> AlsoClips { get; init; } = [];
    public int Count => 1 + AlsoClips.Count;
}

/// <summary>The inline name prompt for a folder: renaming one (<see cref="Folder"/>), or naming a new one that
/// <see cref="ItemIds"/> then move into (Move to Folder ▸ New Folder…).</summary>
public sealed class FolderForm
{
    public ClipFolder? Folder { get; init; }
    public IReadOnlyList<Guid> ItemIds { get; init; } = [];
    public IReadOnlyList<string> SecretIds { get; init; } = [];
    /// <summary>Folders that move into the new folder (Move to Folder ▸ New Folder… on a folder).</summary>
    public IReadOnlyList<Guid> FolderIds { get; init; } = [];
    public string? SpaceId { get; init; }
    /// <summary>Where the new folder goes (null: the top level).</summary>
    public Guid? ParentId { get; init; }
    public int Count => ItemIds.Count + SecretIds.Count;
    public string Text { get; set; } = ClipFolder.DefaultName;
    public bool IsRename => Folder is not null;
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
    public string Name { get; set; } = SuggestedName(item);

    /// <summary>The item's label if it has one, else where it came from.</summary>
    public static string SuggestedName(ClipItem item) =>
        item.Label?.Trim() is { Length: > 0 } label ? label
        : item.SourceName is { } app ? $"Password from {app}" : "New Secret";
}

[Flags] public enum KeyMods { None = 0, Ctrl = 1, Shift = 2, Alt = 4 }
public enum PanelKey { Other, Escape, Up, Down, Left, Right, PageUp, PageDown, Enter, Tab, Delete, Digit, Letter, Backspace, Space }

/// <summary>A key press, mapped from the UI framework so the logic is testable anywhere.</summary>
public readonly record struct KeyInput(PanelKey Key, KeyMods Mods = KeyMods.None, int Digit = 0, char Letter = '\0')
{
    public bool Ctrl => Mods.HasFlag(KeyMods.Ctrl);
    public bool Shift => Mods.HasFlag(KeyMods.Shift);
    public bool Alt => Mods.HasFlag(KeyMods.Alt);
}

/// <summary>The quick panel: search, filters, selection (incl. multi-select), quick slots, the
/// Ctrl+K action menu, snippet/secret/label forms and AI runs. UI-free.</summary>
public sealed partial class PanelModel(ClipStore store, Settings settings, QuickSlots slots, ISecretVault secrets, IPanelHost host)
{
    private IPanelHost Host => host;
    private Settings PanelSettings => settings;

    public const int MaxEntries = 300;

    public event Action? Changed;
    /// <summary>A group was picked in the filter row; the host fetches what members sent since the last sync.</summary>
    public event Action? GroupFilterSelected;
    private void Notify()
    {
        // The preview follows the selection: a different item (or other picked files) starts at its first page.
        if (IsPreviewing && PreviewSelectionKey is var key && key != _previewKey)
        {
            _previewKey = key;
            PreviewIndex = 0;
        }
        Changed?.Invoke();
    }

    public string Query { get; private set; } = "";
    public PanelFilter Filter { get; private set; } = PanelFilter.All;
    /// <summary>When set, the list shows only this sync group (and <see cref="Filter"/> is ignored).</summary>
    public string? GroupFilter { get; private set; }
    /// <summary>Sync groups the user belongs to, by id (badges, filters, sharing).</summary>
    public IReadOnlyDictionary<string, string> GroupNames { get; private set; } = new Dictionary<string, string>();
    /// <summary>The signed-in sync user (null when signed out), so own group items show the own username.</summary>
    public Func<SyncSelf?>? Self { get; set; }
    /// <summary>The account's other devices (empty or null when signed out).</summary>
    public Func<IReadOnlyList<DeviceTarget>>? Devices { get; set; }
    /// <summary>Sends a history item to one device; the host reports failures with <see cref="ShowNotice"/>.</summary>
    public Action<ClipItem, DeviceTarget>? SendToDevice { get; set; }
    private Dictionary<string, SpaceRecord> _groups = [];
    private Dictionary<string, SpaceRecord> _contacts = [];
    private Dictionary<(string Space, string LocalId), string?> _authors = [];
    /// <summary>Contacts (their direct space id → their name), for "Send to ‹contact›".</summary>
    public IReadOnlyDictionary<string, string> ContactNames { get; private set; } = new Dictionary<string, string>();
    /// <summary>The chips: the built-in ones, plus Inbox once there are contacts.</summary>
    public IReadOnlyList<PanelFilter> ChipFilters => _contacts.Count > 0 || Filter == PanelFilter.Inbox ? [.. PanelFilters.Chips, PanelFilter.Inbox] : PanelFilters.Chips;
    /// <summary>In the action menu: picking the group to share with.</summary>
    public bool IsPickingGroup { get; private set; }
    /// <summary>In the action menu: picking the folder to move the selection into.</summary>
    public bool IsPickingFolder { get; private set; }
    public FolderForm? FolderForm { get; private set; }
    /// <summary>The folder open in Saved (personal or a group's), or null at Saved's root.</summary>
    public Guid? OpenFolderId { get; private set; }
    private Dictionary<Guid, ClipFolder> _folders = [];
    private FolderTree _tree = new([]);
    /// <summary>Secret key → the folder it names (<see cref="ClipStore.SecretFolders"/>).</summary>
    private Dictionary<string, Guid> _secretFolders = [];
    /// <summary>In the action menu: Share to Group's second step, picking where in this group's Saved the copies go.</summary>
    public PanelAction.ShareTo? PickingShareFolder { get; private set; }
    public ClipFolder? OpenFolder => OpenFolderId is { } id ? _folders.GetValueOrDefault(id) : null;
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
        IsPreviewing = false;
        Query = "";
        Filter = PanelFilter.All;
        GroupFilter = null;
        OpenFolderId = null;
        _userMovedSelection = false;
        ClearPickedFiles();
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
        IsPreviewing = false;
        SelectionItem = null;
        ClearPickedFiles();
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
        FolderForm = null;
        ActionQuery = "";
        ActionSelection = 0;
        IsPickingGroup = false;
        IsPickingFolder = false;
        PickingShareFolder = null;
        ResetAuthenticatorMode();
        AddItemsForm = null;
        Mode = PanelMode.Browse;
        Notify();
    }

    public void SetQuery(string query)
    {
        if (query == Query) return;
        Query = query;
        Refresh(resetSelection: true);
    }

    /// <summary>Picking the chip that's already selected goes back to the root of Saved.</summary>
    public void SetFilter(PanelFilter filter)
    {
        filter = filter.Normalized();
        if (filter == Filter && GroupFilter is null)
        {
            CloseFolder();
            return;
        }
        Filter = filter;
        GroupFilter = null;
        OpenFolderId = null;
        Refresh(resetSelection: true);
        if (filter == PanelFilter.Inbox) GroupFilterSelected?.Invoke();   // fetch what contacts just sent
    }

    public void SetGroupFilter(string groupId)
    {
        if (GroupFilter == groupId)
        {
            CloseFolder();
            return;
        }
        GroupFilter = groupId;
        Filter = PanelFilter.All;
        OpenFolderId = null;
        Refresh(resetSelection: true);
        GroupFilterSelected?.Invoke();
    }

    // MARK: Saved and folders

    /// <summary>The list shows Saved: the Saved chip, or a group switched to Saved.</summary>
    public bool IsSavedView => GroupFilter is { } group ? GroupShowsSaved(group) : Filter == PanelFilter.Labelled;

    /// <summary>Whose Saved is shown: a group's id, or null for the personal Saved.</summary>
    public string? SavedSpace => GroupFilter;

    /// <summary>The selected group chip's Copies | Saved segments: true for Saved. Remembered per group.</summary>
    public bool GroupShowsSaved(string groupId) => settings.GroupsShowingSaved.Contains(groupId);

    public void SetGroupShowsSaved(bool saved)
    {
        if (GroupFilter is not { } group || GroupShowsSaved(group) == saved) return;
        RememberGroupSegment(group, saved);
        OpenFolderId = null;
        Refresh(resetSelection: true);
    }

    private void RememberGroupSegment(string group, bool saved)
    {
        if (GroupShowsSaved(group) == saved) return;
        if (saved) settings.GroupsShowingSaved.Add(group); else settings.GroupsShowingSaved.Remove(group);
        settings.Save();
    }

    /// <summary>Shows a group on one of its segments (Tab cycling).</summary>
    private void ShowGroup(string group, bool saved)
    {
        if (GroupFilter == group)
        {
            SetGroupShowsSaved(saved);
            return;
        }
        RememberGroupSegment(group, saved);
        SetGroupFilter(group);
    }

    public void OpenFolderById(Guid id)
    {
        if (!IsSavedView || !_folders.ContainsKey(id)) return;
        OpenFolderId = id;
        Query = "";
        Refresh(resetSelection: true);
    }

    /// <summary>Up one level (to the parent, or the root of Saved), with the folder left selected.</summary>
    public void CloseFolder()
    {
        if (OpenFolderId is not { } id) return;
        OpenFolderId = _tree.ParentOf(id);
        Refresh(resetSelection: true);
        if (Entries.Any(e => e.Id == "f-" + id)) Select("f-" + id);
    }

    /// <summary>A breadcrumb segment: that folder, or (null) the root of Saved.</summary>
    public void GoToFolder(Guid? id)
    {
        if (id == OpenFolderId) return;
        if (id is null)
        {
            var from = OpenFolderId is { } open ? _tree.Path(open).FirstOrDefault()?.Id : null;
            OpenFolderId = null;
            Refresh(resetSelection: true);
            if (from is { } top && Entries.Any(e => e.Id == "f-" + top)) Select("f-" + top);
            return;
        }
        OpenFolderById(id.Value);
    }

    /// <summary>The open folder's path from the top level ("Saved › Work › Clients" without "Saved").</summary>
    public List<ClipFolder> OpenFolderPath => OpenFolderId is { } id ? _tree.Path(id) : [];

    /// <summary>The folder's parent, as it reads (an unknown parent or a cycle reads as the top level).</summary>
    public ClipFolder? ParentFolder(ClipFolder folder) => _tree.Parent(folder);

    /// <summary>A folder's subfolders in a space, by name (null: its top level).</summary>
    public List<ClipFolder> FolderChildren(Guid? parent, string? space) => _tree.Children(parent, space);

    /// <summary>"Work › Clients".</summary>
    public string FolderPathText(Guid id) => _tree.PathText(id);

    /// <summary>The folder a clip is in, if this device has it.</summary>
    public ClipFolder? FolderOf(ClipItem item) =>
        item.IsPinned && item.FolderId is { } id && _folders.TryGetValue(id, out var folder) && folder.SpaceId == item.SpaceId ? folder : null;

    /// <summary>The folder a secret is in, if this device has it (and it's of the secret's space).</summary>
    public ClipFolder? FolderOf(SecretRef secret) =>
        _secretFolders.TryGetValue(ClipStore.SecretKey(secret.Id), out var id) && _folders.TryGetValue(id, out var folder)
        && folder.SpaceId == secret.SpaceId ? folder : null;

    /// <summary>The folder a clip or secret is in.</summary>
    public ClipFolder? FolderOf(PanelEntry entry) => entry switch
    {
        PanelEntry.Clip c => FolderOf(c.Item),
        PanelEntry.SecretEntry k => FolderOf(k.Secret),
        _ => null,
    };

    /// <summary>The small caption on an item shown outside its folder (a search, or History): its path relative to
    /// the folder that's open.</summary>
    public string? FolderCaption(PanelEntry entry) =>
        FolderOf(entry) is { } folder && folder.Id != OpenFolderId ? _tree.PathText(folder.Id, OpenFolderId) : null;

    /// <summary>Folders can hold clips of the personal space and of groups: not contacts' (edits to what they send
    /// stay on this device) nor the selection from another app.</summary>
    public bool CanUseFolders(ClipItem item) => item != SelectionItem && (item.SpaceId is null || _groups.ContainsKey(item.SpaceId));

    /// <summary>Clips and secrets go into folders; snippets stay at the root of Saved.</summary>
    public bool CanUseFolders(PanelEntry entry) => entry switch
    {
        PanelEntry.Clip c => CanUseFolders(c.Item),
        PanelEntry.SecretEntry k => k.Secret.SpaceId is null || _groups.ContainsKey(k.Secret.SpaceId),
        _ => false,
    };

    /// <summary>The folders of a space (null = personal), by name.</summary>
    public List<ClipFolder> FoldersIn(string? space) =>
        [.. _folders.Values.Where(f => f.SpaceId == space).OrderBy(f => _tree.PathText(f.Id), StringComparer.CurrentCultureIgnoreCase)];

    /// <summary>Whether the server takes this user's changes to a folder (moving, renaming): personal ones, and in a
    /// group those they made (or haven't pushed yet), or any when they own the group.</summary>
    public bool CanChangeFolder(ClipFolder folder)
    {
        if (folder.SpaceId is not { } space || !_groups.TryGetValue(space, out var group) || group.IsOwner) return true;
        if (!_authors.TryGetValue((space, ClipStore.SyncId(folder.Id)), out var author) || author is null) return true;
        return Self?.Invoke() is not { } self || author == self.Uid;
    }

    /// <summary>Where a folder may go: a folder of its space that isn't itself or below it, within the depth limit
    /// (null: the top level).</summary>
    public bool CanMoveFolder(ClipFolder folder, ClipFolder? parent) =>
        CanChangeFolder(folder) && (parent is null ? _tree.ParentOf(folder.Id) is not null : _tree.CanMove(folder, parent) && _tree.ParentOf(folder.Id) != parent.Id);

    /// <summary>Moves a folder into another (null: the top level), or says why it can't.</summary>
    public bool MoveFolder(ClipFolder folder, ClipFolder? parent)
    {
        if (!CanChangeFolder(folder) || (parent is not null && !_tree.CanMove(folder, parent)) || !store.MoveFolder(folder, parent))
        {
            ResetMode();
            ShowNotice(parent is not null && _tree.IsInSubtree(parent.Id, folder.Id) ? "A folder can't go into itself" : "That folder can't move there");
            return false;
        }
        ResetMode();
        Refresh();
        if (Entries.Any(e => e.Id == "f-" + folder.Id)) Select("f-" + folder.Id);
        ShowNotice(parent is null ? $"Moved “{folder.Name}” to the top level" : $"Moved “{folder.Name}” to “{parent.Name}”");
        return true;
    }

    /// <summary>Whether a row dragged onto a folder row or breadcrumb segment (null: the root) may drop there.</summary>
    public bool CanDrop(string entryId, Guid? folderId)
    {
        var target = folderId is { } id ? _folders.GetValueOrDefault(id) : null;
        if (folderId is not null && target is null) return false;
        if (Entries.FirstOrDefault(e => e.Id == entryId) is PanelEntry.FolderEntry f)
            return target is null ? _tree.ParentOf(f.Folder.Id) is not null && CanChangeFolder(f.Folder) : CanMoveFolder(f.Folder, target);
        return true;
    }

    /// <summary>An item of a sync group: deleting it is "Remove from Group".</summary>
    public bool IsGroupItem(ClipItem item) => item.SpaceId is { } space && _groups.ContainsKey(space);

    /// <summary>Whether the server takes this user's changes to the item: anything personal, and in a group what they
    /// copied themselves (or haven't pushed yet), or anything when they own the group.</summary>
    public bool CanChange(ClipItem item)
    {
        if (item.SpaceId is not { } space || !_groups.TryGetValue(space, out var group) || group.IsOwner) return true;
        if (!_authors.TryGetValue((space, ClipStore.SyncId(item.Id)), out var author) || author is null) return true;
        return Self?.Invoke() is not { } self || author == self.Uid;
    }

    /// <summary>The one space all <paramref name="items"/> share, when they can go into its folders.</summary>
    private bool CommonFolderSpace(IReadOnlyList<ClipItem> items, out string? space) =>
        CommonFolderSpace([.. items.Select(i => (PanelEntry)new PanelEntry.Clip(i))], out space);

    private bool CommonFolderSpace(IReadOnlyList<PanelEntry> entries, out string? space)
    {
        space = entries.Count > 0 ? SpaceOf(entries[0]) : null;
        var first = space;
        return entries.Count > 0 && entries.All(e => SpaceOf(e) == first && CanUseFolders(e));
    }

    /// <summary>The selected clips and secrets: what Move to Folder, Remove from Folder and drags act on.</summary>
    public List<PanelEntry> FolderTargets =>
        IsMultiSelecting ? [.. Entries.Where(e => SelectedIds.Contains(e.Id) && e is PanelEntry.Clip or PanelEntry.SecretEntry)]
        : SelectedEntry is PanelEntry.Clip or PanelEntry.SecretEntry ? [SelectedEntry] : [];

    /// <summary>New Folder Inside: a subfolder of <paramref name="parent"/>, opened there and being renamed.</summary>
    public void NewFolderInside(ClipFolder parent)
    {
        if (!_tree.CanCreateIn(parent.Id))
        {
            ShowNotice($"Folders go at most {FolderTree.MaxDepth} levels deep");
            return;
        }
        var folder = store.CreateFolder(ClipFolder.DefaultName, parent.SpaceId, parent.Id);
        ResetMode();
        OpenFolderId = parent.Id;
        Query = "";
        Refresh();
        BeginRenameFolder(folder);
    }

    /// <summary>The New Folder button: a folder named "New Folder" in the Saved shown, selected and being renamed.</summary>
    public void CreateFolder()
    {
        if (!IsSavedView) return;
        // Inside an open folder, a subfolder there (unless that would be too deep).
        var parent = OpenFolderId is { } open && _tree.CanCreateIn(open) ? open : (Guid?)null;
        var folder = store.CreateFolder(ClipFolder.DefaultName, SavedSpace, parent);
        OpenFolderId = parent;
        Query = "";
        Refresh();
        BeginRenameFolder(folder);
    }

    public void BeginRenameFolder(ClipFolder folder)
    {
        Select("f-" + folder.Id);
        FolderForm = new FolderForm { Folder = folder, SpaceId = folder.SpaceId, Text = folder.Name };
        Mode = PanelMode.FolderName;
        Notify();
    }

    /// <summary>Move to Folder ▸ New Folder…: asks for the name inline, then creates it and moves the clips in.</summary>
    public void BeginNewFolder(IReadOnlyList<ClipItem> items) => BeginNewFolder([.. items.Select(i => (PanelEntry)new PanelEntry.Clip(i))]);

    /// <summary>Move to Folder ▸ New Folder…: asks for the name inline, then creates it and moves the clips and
    /// secrets in. <paramref name="mine"/>: a personal folder, which group items are copied into.</summary>
    public void BeginNewFolder(IReadOnlyList<PanelEntry> entries, bool mine = false, Guid? parentId = null)
    {
        string? space = null;
        if (entries is [PanelEntry.FolderEntry moving])
        {
            // A folder's Move to Folder ▸ New Folder…: the new folder is made at that level and the folder goes in.
            FolderForm = new FolderForm { FolderIds = [moving.Folder.Id], SpaceId = moving.Folder.SpaceId, ParentId = parentId };
            ActionQuery = "";
            IsPickingFolder = false;
            Mode = PanelMode.FolderName;
            Notify();
            return;
        }
        if (mine ? entries.Count == 0 || !entries.All(CanUseFolders) : !CommonFolderSpace(entries, out space))
        {
            ShowNotice("Items can only move into folders of their own space");
            return;
        }
        FolderForm = new FolderForm
        {
            ItemIds = [.. entries.OfType<PanelEntry.Clip>().Select(c => c.Item.Id)],
            SecretIds = [.. entries.OfType<PanelEntry.SecretEntry>().Select(k => k.Secret.Id)],
            SpaceId = mine ? null : space,
            ParentId = parentId,
        };
        ActionQuery = "";
        IsPickingFolder = false;
        Mode = PanelMode.FolderName;
        Notify();
    }

    public void SubmitFolderName()
    {
        if (FolderForm is not { } form) return;
        if (form.Folder is { } folder)
        {
            store.RenameFolder(folder, form.Text);
            ResetMode();
            Refresh();
            Select("f-" + folder.Id);
            return;
        }
        var parentOk = form.ParentId is not { } p || _folders.GetValueOrDefault(p) is { } pf && pf.SpaceId == form.SpaceId && _tree.CanCreateIn(p);
        var created = store.CreateFolder(form.Text, form.SpaceId, parentOk ? form.ParentId : null);
        _folders[created.Id] = created;
        _tree = new FolderTree(_folders.Values);
        if (form.FolderIds.Count > 0)
        {
            if (_folders.GetValueOrDefault(form.FolderIds[0]) is { } moving) MoveFolder(moving, created);
            return;
        }
        List<PanelEntry> entries = [.. form.ItemIds.Select(store.Find).OfType<ClipItem>().Select(i => new PanelEntry.Clip(i)),
            .. form.SecretIds.Select(id => secrets.Secrets.FirstOrDefault(s => s.Id == id)).OfType<SecretRef>().Select(s => new PanelEntry.SecretEntry(s))];
        MoveToFolder(entries, created);
    }

    private static string MovedNotice(int count, string folder) =>
        count == 1 ? $"Moved to “{folder}”" : $"Moved {count} items to “{folder}”";

    private static string CopiedNotice(int count, string folder) =>
        count == 1 ? $"Saved a copy to “{folder}”" : $"Saved {count} copies to “{folder}”";

    /// <summary>Moves clips into a folder of their space (null: out of their folder, to the root of Saved).</summary>
    public void MoveToFolder(IReadOnlyList<ClipItem> items, ClipFolder? folder) =>
        MoveToFolder([.. items.Select(i => (PanelEntry)new PanelEntry.Clip(i))], folder);

    /// <summary>Moves clips and secrets into a folder of their space (null: out of their folder, to the root of Saved).
    /// A personal folder chosen for group items saves personal copies into it; the group items don't change.</summary>
    public void MoveToFolder(IReadOnlyList<PanelEntry> entries, ClipFolder? folder)
    {
        var usable = entries.Where(CanUseFolders).ToList();
        List<PanelEntry> copies = folder is { SpaceId: null } ? [.. usable.Where(e => SpaceOf(e) is not null)] : [];
        var moving = usable.Except(copies).ToList();
        var moved = store.MoveToFolder([.. moving.OfType<PanelEntry.Clip>().Select(c => c.Item)], folder);
        foreach (var secret in moving.OfType<PanelEntry.SecretEntry>().Select(k => k.Secret))
        {
            if (folder is not null && folder.SpaceId != secret.SpaceId) continue;
            // An id this device doesn't know reads as the root already: leave it.
            if (folder is null && FolderOf(secret) is null) continue;
            if (store.SetSecretFolder(secret.Id, folder?.Id)) moved++;
        }
        var copied = 0;
        if (folder is not null)
        {
            foreach (var clip in copies.OfType<PanelEntry.Clip>())
            {
                SavePersonalCopy(clip.Item, folder);
                copied++;
            }
            // Secrets need Windows Hello to be read; the host copies them and says so.
            if (copies.OfType<PanelEntry.SecretEntry>().Select(k => k.Secret).ToList() is { Count: > 0 } groupSecrets)
            {
                var total = copied + groupSecrets.Count;
                host.CopySecrets(groupSecrets, null, folder.Id,
                    groupSecrets.Count == 1 ? $"save a copy of “{groupSecrets[0].Name}”" : $"save copies of {groupSecrets.Count} secrets",
                    CopiedNotice(total, folder.Name));
            }
        }
        ResetMode();
        Refresh();
        if (folder is null) ShowNotice(moved == 1 ? "Moved to Saved" : $"Moved {moved} items to Saved");
        else if (copies.Count > 0 && moved == 0) { if (copied > 0) ShowNotice(CopiedNotice(copies.Count, folder.Name)); }
        else if (moved == 0 && copies.Count == 0 && usable.Any(e => SpaceOf(e) != folder.SpaceId)) ShowNotice("Items can only move into folders of their own space");
        else ShowNotice(MovedNotice(moved + copied, folder.Name));
    }

    /// <summary>A personal copy of a group item (a new id), saved, in <paramref name="folder"/> or (null) wherever an
    /// existing personal copy already is. The group item doesn't change.</summary>
    private ClipItem SavePersonalCopy(ClipItem item, ClipFolder? folder)
    {
        var copy = store.CopyToSpace(item, null);
        if (!copy.IsPinned)
        {
            copy.IsPinned = true;
            copy.PinnedAt = DateTime.UtcNow;
        }
        if (folder is not null) copy.FolderId = folder.Id;
        store.Put(copy);
        return copy;
    }

    /// <summary>A row of this panel dropped on a folder row (or, with null, on the "Saved" breadcrumb): it moves in or
    /// out. Dragging one of several selected rows moves the whole selection.</summary>
    public void DropOnFolder(string entryId, Guid? folderId)
    {
        if (Entries.FirstOrDefault(e => e.Id == entryId) is PanelEntry.FolderEntry dragged)
        {
            // A folder row: nests it (never into itself or below), or moves it up to the top level.
            if (!CanDrop(entryId, folderId)) return;
            MoveFolder(dragged.Folder, folderId is { } into ? _folders.GetValueOrDefault(into) : null);
            return;
        }
        List<PanelEntry> entries = IsMultiSelecting && SelectedIds.Contains(entryId)
            ? FolderTargets
            : Entries.FirstOrDefault(e => e.Id == entryId) is { } entry && entry is PanelEntry.Clip or PanelEntry.SecretEntry ? [entry] : [];
        if (entries.Count == 0) return;
        if (folderId is { } id)
        {
            if (_folders.GetValueOrDefault(id) is not { } folder) return;
            MoveToFolder(entries, folder);
        }
        else MoveToFolder(entries, null);
    }

    /// <summary>Delete Folder: its clips and secrets move to the root of Saved. No confirmation: nothing is lost.</summary>
    public void DeleteFolder(ClipFolder folder)
    {
        var parent = _tree.Parent(folder);
        var moved = store.DeleteFolder(folder);
        if (OpenFolderId is { } open && _tree.IsInSubtree(open, folder.Id)) OpenFolderId = open == folder.Id ? parent?.Id : open;
        ResetMode();
        Refresh(resetSelection: true);
        ShowNotice($"Folder deleted · moved {(moved == 1 ? "1 item" : $"{moved} items")} to {parent?.Name ?? "Saved"}");
    }

    /// <summary>Saves clips without a label. Another member's group item, which the server wouldn't let this user
    /// change, is saved as a personal copy instead (Save a Copy).</summary>
    public void AddToSaved(IReadOnlyList<ClipItem> items)
    {
        var added = items.Where(i => !i.IsPinned && i != SelectionItem).ToList();
        var own = added.Where(CanChange).ToList();
        var others = added.Except(own).ToList();
        foreach (var item in own) store.Pin(item);
        foreach (var item in others) SavePersonalCopy(item, null);
        ResetMode();
        Refresh();
        ShowNotice(own.Count == 0 && others.Count > 0
            ? others.Count == 1 ? "Saved a copy to Saved" : $"Saved {others.Count} copies to Saved"
            : added.Count == 1 ? "Added to Saved" : $"Added {added.Count} items to Saved");
    }

    /// <summary>The Move to Folder picker. One space: its folders (and New Folder…). A group's items also list the
    /// personal folders under "Mine", which save personal copies; items of several spaces list only "Mine".</summary>
    private List<PanelAction> FolderPickActions()
    {
        var targets = !IsMultiSelecting && SelectedEntry is PanelEntry.FolderEntry f ? [f] : FolderTargets;
        // After each section's New Folder…, one per folder that can take a subfolder: "New Folder in Work…".
        var choices = new List<PanelAction>();
        foreach (var choice in FolderChoices(targets))
        {
            choices.Add(choice);
            if (choice is not PanelAction.MoveToNewFolder { ParentId: null } top) continue;
            var space = top.Mine ? null : targets is [PanelEntry.FolderEntry ff] ? ff.Folder.SpaceId : targets.Select(SpaceOf).FirstOrDefault();
            var moving = targets is [PanelEntry.FolderEntry fm] ? fm.Folder : null;
            choices.AddRange(FoldersIn(space).Where(x => _tree.CanCreateIn(x.Id) && (moving is null || CanMoveFolder(moving, x)))
                .Select(x => new PanelAction.MoveToNewFolder(top.Mine, top.SectionTitle, x.Id, _tree.PathText(x.Id))));
        }
        // The picker starts with "Top Level" when something picked is in a folder.
        var nested = targets is [PanelEntry.FolderEntry folder] ? _tree.ParentOf(folder.Folder.Id) is not null && CanChangeFolder(folder.Folder)
            : targets.Any(e => FolderOf(e) is not null);
        return nested ? [new PanelAction.RemoveFromFolder(), .. choices] : choices;
    }

    /// <summary>The sections of the right-click Move to Folder tree: (title, space, mine). One space: one untitled
    /// section; a group's items: the group's tree, then "Mine".</summary>
    public List<(string? Title, string? Space, bool Mine)> FolderMenuSections(IReadOnlyList<PanelEntry> targets)
    {
        if (targets is [PanelEntry.FolderEntry f]) return CanChangeFolder(f.Folder) ? [(null, f.Folder.SpaceId, false)] : [];
        if (targets.Count == 0 || !targets.All(CanUseFolders)) return [];
        var spaces = targets.Select(SpaceOf).Distinct().ToList();
        if (spaces is [null]) return [(null, null, false)];
        if (spaces is [{ } group]) return [(GroupNames.GetValueOrDefault(group, "Group"), group, false), ("Mine", null, true)];
        return [("Mine", null, true)];
    }

    /// <summary>The Move to Folder choices for <paramref name="targets"/> (see <see cref="FolderPickActions"/>); the
    /// right-click menu lists them too.</summary>
    public List<PanelAction> FolderChoices(IReadOnlyList<PanelEntry> targets)
    {
        if (targets is [PanelEntry.FolderEntry moving])
            return [.. FoldersIn(moving.Folder.SpaceId).Where(f => CanMoveFolder(moving.Folder, f))
                .Select(f => new PanelAction.MoveTo(f.Id, _tree.PathText(f.Id))), new PanelAction.MoveToNewFolder()];
        if (targets.Count == 0 || !targets.All(CanUseFolders)) return [];
        var current = targets.Select(e => FolderOf(e)?.Id).Distinct().ToList() is [{ } only] ? only : (Guid?)null;
        var spaces = targets.Select(SpaceOf).Distinct().ToList();
        IEnumerable<PanelAction> In(string? space, string? section, bool mine) =>
            [.. FoldersIn(space).Where(f => f.Id != current).Select(f => new PanelAction.MoveTo(f.Id, _tree.PathText(f.Id), section)),
             new PanelAction.MoveToNewFolder(mine, section)];
        if (spaces is [null]) return [.. In(null, null, false)];
        if (spaces is [{ } group])
            return [.. In(group, GroupNames.GetValueOrDefault(group, "Group"), false), .. In(null, "Mine", true)];
        return [.. In(null, "Mine", true)];
    }

    public void BeginMoveToFolder()
    {
        if (SelectedEntry is null && !IsMultiSelecting) return;
        ActionQuery = "";
        ActionSelection = 0;
        IsPickingGroup = false;
        IsPickingFolder = true;
        PickingShareFolder = null;
        Mode = PanelMode.Actions;
        Notify();
    }

    /// <summary>The badge for a group entry: the username of whoever copied it, or the group's name when that isn't
    /// known (older servers). Null for personal items.</summary>
    public string? GroupBadge(PanelEntry entry)
    {
        if (SpaceOf(entry) is not { } space || _contacts.ContainsKey(space)) return null;
        if (!_groups.TryGetValue(space, out var group)) return GroupNames.GetValueOrDefault(space, "Group");
        var self = Self?.Invoke();
        // Not on the server yet (no sync meta): copied here, so it's ours.
        var author = _authors.TryGetValue((space, SyncIdOf(entry)), out var uid) ? uid : self?.Uid;
        return group.AuthorName(author, self);
    }

    /// <summary>The name of the group an entry belongs to, or null for personal items and contacts' items.</summary>
    public string? GroupName(PanelEntry entry) =>
        SpaceOf(entry) is { } space && !_contacts.ContainsKey(space) ? GroupNames.GetValueOrDefault(space, "Group") : null;

    /// <summary>For an Inbox entry: the contact who sent it. Null for everything else, including what this user sent.</summary>
    public string? SenderName(PanelEntry entry) =>
        SpaceOf(entry) is { } space && _contacts.TryGetValue(space, out var contact) && IsFromContact(space, entry) ? contact.DisplayName : null;

    /// <summary>Written by the other person of a contact (sent from here, or not on the server yet, is this user's).</summary>
    private bool IsFromContact(string space, PanelEntry entry) =>
        _authors.TryGetValue((space, SyncIdOf(entry)), out var author) && author is not null && author != Self?.Invoke()?.Uid;

    private static string SyncIdOf(PanelEntry entry) => entry switch
    {
        PanelEntry.Clip c => ClipStore.SyncId(c.Item.Id),
        PanelEntry.SnippetEntry s => ClipStore.SyncId(s.Snippet.Id),
        PanelEntry.SecretEntry k => Guid.TryParse(k.Secret.Id, out var g) ? ClipStore.SyncId(g) : k.Secret.Id,
        _ => "",
    };

    private int _noticeId;

    /// <summary>Shows a notice in the footer for a few seconds (from the UI thread: the delay resumes there).</summary>
    public void ShowNotice(string text)
    {
        Notice = text;
        _ = ClearNoticeAsync(text, ++_noticeId);
        Notify();
    }

    private async Task ClearNoticeAsync(string text, int id)
    {
        await Task.Delay(NoticeDuration);
        if (id != _noticeId || Notice != text) return;
        Notice = null;
        Notify();
    }

    public static TimeSpan NoticeDuration { get; set; } = TimeSpan.FromSeconds(3);

    /// <summary>When a clip was kept, for Saved's newest-first order: when it was saved, else its last copy.</summary>
    // The later of saved and last copied, like the Mac: a saved clip copied again moves up.
    private static DateTime SavedDate(ClipItem item) =>
        item.PinnedAt is { } pinned && pinned > item.LastCopiedAt ? pinned : item.LastCopiedAt;

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
        _contacts = store.Contacts().ToDictionary(c => c.Id);
        ContactNames = _contacts.ToDictionary(c => c.Key, c => c.Value.DisplayName);
        _authors = _groups.Count == 0 && _contacts.Count == 0 ? [] : store.GroupAuthors();
        if (GroupFilter is not null && !GroupNames.ContainsKey(GroupFilter)) GroupFilter = null;
        var group = GroupFilter;
        _folders = store.AllFolders().ToDictionary(f => f.Id);
        _tree = new FolderTree(_folders.Values);
        _secretFolders = store.SecretFolders();
        var saved = IsSavedView;
        // A folder deleted (here or elsewhere) while open: back to the root.
        if (OpenFolderId is { } openId && (!saved || !_folders.TryGetValue(openId, out var openFolder) || openFolder.SpaceId != SavedSpace))
            OpenFolderId = null;
        // What contacts send lives in the Inbox only; what this user sent them isn't listed again.
        var inbox = Filter == PanelFilter.Inbox && group is null;
        bool Listed(string? space, PanelEntry entry) =>
            space is null || !_contacts.ContainsKey(space) ? !inbox : inbox && IsFromContact(space, entry);

        List<PanelEntry.FolderEntry> folderRows = [];
        List<ClipItem> clips;
        List<Snippet> snippets;
        List<SecretRef> secretList;
        if (saved)
        {
            // Saved holds everything kept in one space (personal, or the group's): its saved clips, secrets and
            // snippets, with the space's folders first. Inside a folder, only its clips and secrets. A search from the
            // root finds what's in folders too.
            var space = SavedSpace;
            clips = [.. store.ItemsInSpace(space).Where(c => c.IsPinned)];
            secretList = [.. secrets.Secrets.Where(s => s.SpaceId == space)];
            snippets = [.. store.AllSnippets().Where(s => s.SpaceId == space)];
            var counts = clips.Select(c => FolderOf(c)?.Id).Concat(secretList.Select(s => FolderOf(s)?.Id)).OfType<Guid>()
                .GroupBy(id => id).ToDictionary(g => g.Key, g => g.Count());
            PanelEntry.FolderEntry Row(ClipFolder f) =>
                new(f, counts.GetValueOrDefault(f.Id), _tree.Children(f.Id, f.SpaceId).Count);
            if (OpenFolderId is { } open)
            {
                // Its subfolders first; a search covers the whole subtree.
                bool Inside(Guid? id) => id is { } f && (q.Length == 0 ? f == open : _tree.IsInSubtree(f, open));
                clips = [.. clips.Where(c => Inside(FolderOf(c)?.Id))];
                secretList = [.. secretList.Where(s => Inside(FolderOf(s)?.Id))];
                snippets = [];   // snippets aren't in folders
                folderRows = q.Length == 0 ? [.. _tree.Children(open, space).Select(Row)]
                    : [.. FoldersIn(space).Where(f => f.Id != open && _tree.IsInSubtree(f.Id, open)).Select(Row)];
            }
            else
            {
                folderRows = q.Length == 0 ? [.. _tree.Children(null, space).Select(Row)] : [.. FoldersIn(space).Select(Row)];
                if (q.Length == 0)
                {
                    clips = [.. clips.Where(c => FolderOf(c) is null)];
                    secretList = [.. secretList.Where(s => FolderOf(s) is null)];
                }
            }
        }
        else
        {
            clips = group is not null ? store.ItemsInSpace(group)
                : store.AllItems().Where(item => Listed(item.SpaceId, new PanelEntry.Clip(item)) && (Filter != PanelFilter.ThisApp
                    || target is not null && string.Equals(item.SourceId, target, StringComparison.OrdinalIgnoreCase))).ToList();
            // Snippets and secrets join "All" only while searching, so history stays uncluttered. They live in Saved.
            var searchingAll = Filter == PanelFilter.All && q.Length > 0;
            snippets = group is not null ? [.. store.AllSnippets().Where(s => s.SpaceId == group)]
                : searchingAll || inbox ? [.. store.AllSnippets().Where(s => Listed(s.SpaceId, new PanelEntry.SnippetEntry(s)))] : [];
            secretList = group is not null ? [.. secrets.Secrets.Where(s => s.SpaceId == group)]
                : searchingAll || inbox ? [.. secrets.Secrets.Where(s => Listed(s.SpaceId, new PanelEntry.SecretEntry(s)))] : [];
        }

        // Authenticators: personal tools, in the personal Saved (not in folders), and in searches of All.
        var otps = (saved && SavedSpace is null && OpenFolderId is null) || (!saved && group is null && Filter == PanelFilter.All && q.Length > 0)
            ? AuthenticatorRows() : [];
        List<PanelEntry> result;
        if (q.Length == 0 && saved)
        {
            // Folders by name, then clips, secrets, snippets and authenticators mixed, newest first.
            List<(PanelEntry Entry, DateTime Date)> kept = [.. clips.Select(c => ((PanelEntry)new PanelEntry.Clip(c), SavedDate(c))),
                .. secretList.Select(s => ((PanelEntry)new PanelEntry.SecretEntry(s), s.CreatedAt ?? DateTime.MinValue)),
                .. snippets.Select(s => ((PanelEntry)new PanelEntry.SnippetEntry(s), s.UpdatedAt)), .. otps];
            result = [.. folderRows, .. kept.OrderByDescending(x => x.Date).Select(x => x.Entry)];
        }
        else if (q.Length == 0)
        {
            result = [.. clips.Select(c => new PanelEntry.Clip(c)), .. snippets.Select(s => new PanelEntry.SnippetEntry(s)),
                      .. secretList.Select(s => new PanelEntry.SecretEntry(s))];
            // An otpauth link just copied: offered once, at the top of All.
            if (PendingOtp is { } draft && Filter == PanelFilter.All && group is null) result.Insert(0, new PanelEntry.OtpSuggestion(draft));
        }
        else
        {
            var scored = new List<(PanelEntry Entry, int Score, DateTime Date)>();
            foreach (var folder in folderRows)
                if (FuzzyMatcher.Score(q, folder.Folder.Name + (folder.Folder.Label is { } l ? " " + l : "")) is { } s)
                    scored.Add((folder, s + 500, folder.Folder.UpdatedAt));
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
            foreach (var (entry, date) in otps)   // issuer and account only
                if (FuzzyMatcher.Score(q, AuthenticatorSearchText(entry)) is { } s) scored.Add((entry, s + 500, date));
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
        if (id != SelectedId) ClearPickedFiles();
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
        ClearPickedFiles();
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
        ClearPickedFiles();
        SelectedIds = Entries.Skip(Math.Min(from, to)).Take(Math.Abs(to - from) + 1).Select(e => e.Id).ToHashSet();
        SelectedId = id;
        Notify();
    }

    public void SelectAll()
    {
        if (Entries.Count == 0) return;
        ClearPickedFiles();
        _anchorId = Entries[0].Id;
        SelectedIds = Entries.Select(e => e.Id).ToHashSet();
        SelectedId ??= Entries[0].Id;
        Notify();
    }

    /// <summary>Tab: the filter chips, then each sync group's two segments, Copies then Saved, in the chip row's order.</summary>
    public void CycleFilter(bool forward)
    {
        List<(PanelFilter Filter, string? Group, bool Saved)> all = [.. ChipFilters.Select(f => (f, (string?)null, false))];
        foreach (var g in store.Groups().OrderBy(g => g.DisplayName, StringComparer.CurrentCultureIgnoreCase))
            all.AddRange([(PanelFilter.All, g.Id, false), (PanelFilter.All, g.Id, true)]);
        var index = all.FindIndex(x => GroupFilter is { } group ? x.Group == group && x.Saved == GroupShowsSaved(group)
            : x.Group is null && x.Filter == Filter);
        var next = all[(Math.Max(index, 0) + (forward ? 1 : all.Count - 1)) % all.Count];
        if (next.Group is { } g2) ShowGroup(g2, next.Saved); else SetFilter(next.Filter);
    }

    // MARK: Picking files of a multi-file item

    private Guid? _pickedItem;
    private List<string> _pickedFiles = [];
    private int? _fileAnchor;

    /// <summary>The selected item when it holds several files and nothing else is selected: its files can be picked
    /// in the preview.</summary>
    public ClipItem? PickableItem =>
        !IsMultiSelecting && SelectedEntry?.ClipItem is { Kind: ClipKind.File, Files.Count: > 1 } item && item != SelectionItem ? item : null;

    /// <summary>Files picked in the preview of <see cref="PickableItem"/>, in the item's order. Empty: the whole item.</summary>
    public IReadOnlyList<string> PickedFiles => PickableItem is { } item && _pickedItem == item.Id ? _pickedFiles : [];

    public bool IsFilePicked(string path) => PickedFiles.Contains(path);

    /// <summary>A click on a file in the preview toggles it; Shift adds the range from the last one clicked.</summary>
    public void ClickFile(string path, bool shift)
    {
        if (PickableItem is not { } item) return;
        var index = item.Files.IndexOf(path);
        if (index < 0) return;
        if (_pickedItem != item.Id)
        {
            _pickedItem = item.Id;
            _pickedFiles = [];
            _fileAnchor = null;
        }
        var picked = _pickedFiles.ToHashSet();
        if (shift && _fileAnchor is { } anchor)
            picked.UnionWith(item.Files.Skip(Math.Min(anchor, index)).Take(Math.Abs(index - anchor) + 1));
        else if (!picked.Remove(path))
            picked.Add(path);
        _fileAnchor = index;
        _pickedFiles = [.. item.Files.Where(picked.Contains)];
        Notify();
    }

    public void ClearPickedFiles()
    {
        if (_pickedItem is null) return;
        _pickedItem = null;
        _pickedFiles = [];
        _fileAnchor = null;
        Notify();
    }

    /// <summary>What Enter, Paste, Copy and drag use: a transient item with only the picked files, or the item itself.
    /// The stored item never changes.</summary>
    public ClipItem ItemForUse(ClipItem item) =>
        PickedFiles is { Count: > 0 } files && files.Count < item.Files.Count && PickableItem?.Id == item.Id
            ? ClipItem.From(ProcessedCapture.ForFiles(files, item.Source), item.LastCopiedAt)
            : item;

    // MARK: Large preview

    /// <summary>The large preview (Ctrl+Y) is open; the app shows <see cref="CurrentPreviewPage"/> in its own window.</summary>
    public bool IsPreviewing { get; private set; }
    /// <summary>The page shown, in <see cref="PreviewPages"/>.</summary>
    public int PreviewIndex { get; private set; }
    private string? _previewKey;

    /// <summary>What the selection previews: every selected clip (in list order), one page per file of a file item
    /// (only the picked ones when some are). Secrets and snippets have none.</summary>
    public List<PreviewPage> PreviewPages =>
        ItemPreview.Pages(IsMultiSelecting ? SelectedClips : SelectedEntry?.ClipItem is { } item ? [ItemForUse(item)] : []);

    public bool CanPreview => PreviewPages.Count > 0;

    public PreviewPage? CurrentPreviewPage => PreviewPages is { Count: > 0 } pages ? pages[Math.Clamp(PreviewIndex, 0, pages.Count - 1)] : null;

    /// <summary>"2 of 5" with several pages, else null.</summary>
    public string? PreviewPosition => PreviewPages.Count is var count and > 1 ? $"{Math.Clamp(PreviewIndex, 0, count - 1) + 1} of {count}" : null;

    /// <summary>Why the selection has nothing to preview.</summary>
    public string PreviewUnavailableReason => SelectedEntry switch
    {
        _ when IsMultiSelecting => "Nothing to preview",
        PanelEntry.SecretEntry => "Secrets aren't previewed",
        PanelEntry.SnippetEntry => "Snippets aren't previewed",
        PanelEntry.AuthenticatorEntry or PanelEntry.SharedCodeEntry => "Authenticators aren't previewed",
        _ => "Nothing to preview",
    };

    private string PreviewSelectionKey => string.Join(",", SelectedIds.Order()) + "|" + string.Join("\n", PickedFiles);

    public void TogglePreview()
    {
        if (IsPreviewing) ClosePreview(); else OpenPreview();
    }

    public void OpenPreview()
    {
        if (!CanPreview)
        {
            ShowNotice(PreviewUnavailableReason);
            return;
        }
        IsPreviewing = true;
        _previewKey = PreviewSelectionKey;
        PreviewIndex = 0;
        Notify();
    }

    public void ClosePreview()
    {
        if (!IsPreviewing) return;
        IsPreviewing = false;
        Notify();
    }

    /// <summary>Next or previous page; stops at either end.</summary>
    public void StepPreview(int delta)
    {
        var count = PreviewPages.Count;
        if (!IsPreviewing || count == 0) return;
        var next = Math.Clamp(PreviewIndex + delta, 0, count - 1);
        if (next == PreviewIndex) return;
        PreviewIndex = next;
        Notify();
    }

    // MARK: Quick slots

    /// <summary>The Ctrl+number shown on a row: its slot, or its position if that number is free.</summary>
    public (int Number, bool IsSlot)? ShortcutNumber(PanelEntry entry, int index)
    {
        if (entry is PanelEntry.FolderEntry or PanelEntry.AuthenticatorEntry or PanelEntry.SharedCodeEntry or PanelEntry.OtpSuggestion) return null;
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
        if (SelectedEntry is not { } entry || entry is PanelEntry.FolderEntry or PanelEntry.AuthenticatorEntry or PanelEntry.SharedCodeEntry
            or PanelEntry.OtpSuggestion) return;
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
                var item = ItemForUse(c.Item);
                host.ClosePanel();
                host.Paste(item, transform);
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
            case PanelEntry.FolderEntry f:
                OpenFolderById(f.Folder.Id);
                break;
            case PanelEntry.AuthenticatorEntry or PanelEntry.SharedCodeEntry:
                _ = PasteCodeAsync(entry);
                break;
            case PanelEntry.OtpSuggestion o:
                BeginAddAuthenticator(o.Draft);
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
                // An item in a quick slot stays kept without its label, so the slot can't lose it.
                foreach (var item in form.AlsoClips.Prepend(c.Item))
                    store.SetLabel(form.Text, item, keepPinned: slots.SlotFor(SlotTarget.ForClip(item.Id)) is not null);
                ShowNotice(c.Item.Label is null ? (form.Count > 1 ? $"Label removed from {form.Count} items" : "Label removed")
                    : form.Count > 1 ? $"Labelled {form.Count} items" : "Labelled");
                break;
            case PanelEntry.FolderEntry f:
                store.SetFolderLabel(f.Folder, form.Text);
                ShowNotice(f.Folder.Label is null ? "Label removed" : "Labelled");
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
        // Labelled already: that's its name, so there's nothing to ask.
        if (item.Label?.Trim() is { Length: > 0 } label)
        {
            SaveAsSecret(item, label);
            return;
        }
        SaveSecretForm = new SaveSecretForm(item);
        Mode = PanelMode.SaveSecret;
        Notify();
    }

    public void SubmitSaveSecret()
    {
        if (SaveSecretForm is not { } form) return;
        SaveAsSecret(form.Item, form.Name.Trim());
    }

    private void SaveAsSecret(ClipItem item, string name)
    {
        if (name.Length == 0 || secrets.Add(name, item.Text) is not { } secret)
        {
            ShowNotice("Couldn't save to Credential Manager");
            return;
        }
        // A personal item's secret stays in its folder; a group item's becomes a personal secret, as before.
        if (item.SpaceId is null && item.FolderId is { } folderId) store.SetSecretFolder(secret.Id, folderId);
        if (item != SelectionItem) store.Delete(item);
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
        IsPickingFolder = false;
        PickingShareFolder = null;
        Mode = PanelMode.Actions;
        Notify();
    }

    /// <summary>Switches the action list to the sync groups to share with.</summary>
    public void BeginShareToGroup()
    {
        if (SelectedEntry is null && !IsMultiSelecting) return;
        ActionQuery = "";
        ActionSelection = 0;
        IsPickingFolder = false;
        PickingShareFolder = null;
        IsPickingGroup = true;
        Mode = PanelMode.Actions;
        Notify();
    }

    private List<PanelAction> ShareActions(string? exceptGroup) =>
        [.. store.Groups().Where(g => g.Id != exceptGroup).Select(g => new PanelAction.ShareTo(g.Id, g.DisplayName))];

    /// <summary>Share to Group's second step: the group's root, then its folders.</summary>
    private List<PanelAction> ShareFolderActions(PanelAction.ShareTo share) =>
        [new PanelAction.ShareInto(share.GroupId, share.GroupName, null, "No Folder"),
         .. FoldersIn(share.GroupId).Where(f => _tree.CanCreateIn(f.Id))
             .Select(f => new PanelAction.ShareInto(share.GroupId, share.GroupName, f.Id, _tree.PathText(f.Id)))];

    /// <summary>Whether sharing the selection to <paramref name="groupId"/> can pick one of its folders: the group has
    /// some, and something selected can go in one (clips and secrets; folders and snippets go to the root).</summary>
    public bool CanShareIntoFolder(string groupId) =>
        FoldersIn(groupId).Count > 0 && (IsMultiSelecting ? Entries.Where(e => SelectedIds.Contains(e.Id)) : SelectedEntry is { } e ? [e] : [])
            .Any(e => e is PanelEntry.Clip or PanelEntry.SecretEntry or PanelEntry.FolderEntry);

    private bool CanShare => store.Groups().Count > 0;

    private IReadOnlyList<DeviceTarget> OtherDevices => SendToDevice is null ? [] : Devices?.Invoke() ?? [];

    private IEnumerable<PanelAction> SendActions =>
        OtherDevices.OrderBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase).Select(d => new PanelAction.SendTo(d.Id, d.Name));

    /// <summary>"Send to ‹contact›" for each contact, except the one whose space the item is already in.</summary>
    private IEnumerable<PanelAction> ContactActions(string? exceptSpace) =>
        ContactNames.Where(c => c.Key != exceptSpace).OrderBy(c => c.Value, StringComparer.CurrentCultureIgnoreCase)
            .Select(c => new PanelAction.SendToContact(c.Key, c.Value));

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

    private static bool IsPinnedWithoutLabel(ClipItem item) => item.IsPinned && item.Label is null;

    /// <summary>The save folder's name for "Save to Downloads" and its notice.</summary>
    public string SaveFolderName => FolderName(host.SaveFolder);

    public static string FolderName(string folder) =>
        Path.GetFileName(folder.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)) is { Length: > 0 } name ? name : folder;

    private PanelAction[] SaveActions => [new PanelAction.SaveToFolder(SaveFolderName), new PanelAction.SaveToChosenFolder()];

    public List<PanelAction> AvailableActions
    {
        get
        {
            if (IsMultiSelecting)
            {
                var clips = SelectedClips;
                // Only secrets selected: they can move between folders and be shared; nothing else acts on several.
                if (clips.Count == 0)
                {
                    var targets = FolderTargets;
                    if (targets.Count == 0) return [];
                    return [.. CanShare ? [new PanelAction.ShareToGroup()] : Array.Empty<PanelAction>(), .. SavedActions(targets)];
                }
                List<PanelAction> multi = [new PanelAction.Paste()];
                if (clips.All(c => c.Kind.IsTextual())) multi.AddRange([new PanelAction.PastePlain(), new PanelAction.Copy(), .. TransformActions]);
                else multi.Add(new PanelAction.Copy());
                if (CanPreview) multi.Add(new PanelAction.Preview());
                if (CanShare) multi.Add(new PanelAction.ShareToGroup());
                multi.AddRange(ContactActions(null));
                multi.AddRange(SaveActions);
                multi.AddRange(SavedActions(FolderTargets));
                return [.. multi, DeleteAction(clips)];
            }
            if (SelectedEntry is not { } entry) return [];
            if (AuthenticatorActions(entry) is { } otpActions) return otpActions;
            if (entry is PanelEntry.FolderEntry folderEntry)
            {
                List<PanelAction> folderActions = [new PanelAction.OpenFolder(), new PanelAction.RenameFolder(), new PanelAction.SetLabel()];
                if (_tree.CanCreateIn(folderEntry.Folder.Id)) folderActions.Add(new PanelAction.NewFolderInside());
                if (CanChangeFolder(folderEntry.Folder))
                {
                    if (FolderChoices([folderEntry]).OfType<PanelAction.MoveTo>().Any()) folderActions.Add(new PanelAction.MoveToFolder());
                    if (_tree.ParentOf(folderEntry.Folder.Id) is not null) folderActions.Add(new PanelAction.RemoveFromFolder());
                }
                // A group's folder isn't shared on: its clips are already the group's.
                if (folderEntry.Folder.SpaceId is null && CanShare) folderActions.Add(new PanelAction.ShareToGroup());
                return [.. folderActions, new PanelAction.DeleteFolder()];
            }
            List<PanelAction> actions = [new PanelAction.Paste()];
            switch (entry)
            {
                case PanelEntry.Clip c when c.Item == SelectionItem:
                    return [new PanelAction.Copy(), .. AIActions, .. TransformActions, new PanelAction.SaveAsSecret(),
                            .. CanShare ? [new PanelAction.ShareToGroup()] : Array.Empty<PanelAction>(), .. ContactActions(null)];
                case PanelEntry.Clip c:
                    if (c.Item.Kind.IsTextual()) actions.Add(new PanelAction.PastePlain());
                    actions.Add(new PanelAction.Copy());
                    if (c.Item.Kind.IsTextual())
                    {
                        actions.AddRange(TransformActions);
                        actions.AddRange(AIActions);
                    }
                    if (CanPreview) actions.Add(new PanelAction.Preview());
                    if (c.Item.Kind.IsTextual()) actions.Add(new PanelAction.SaveAsSecret());
                    actions.Add(new PanelAction.SetLabel());
                    actions.AddRange(SavedActions([entry]));
                    actions.AddRange(SaveActions);
                    break;
                case PanelEntry.SecretEntry:
                    actions.Add(new PanelAction.Copy());
                    actions.Add(new PanelAction.SetLabel());
                    actions.AddRange(SavedActions([entry]));
                    break;
            }
            if (CanShare) actions.Add(new PanelAction.ShareToGroup());
            if (entry is PanelEntry.Clip c2)
            {
                actions.AddRange(ContactActions(c2.Item.SpaceId));
                actions.AddRange(SendActions);
            }
            if (slots.SlotFor(entry.SlotTarget) is { } slot) actions.Add(new PanelAction.ClearSlot(slot));
            if (entry is PanelEntry.Clip c3) actions.Add(DeleteAction([c3.Item]));
            else if (entry is PanelEntry.SecretEntry) actions.Add(new PanelAction.Delete());
            return actions;
        }
    }

    /// <summary>Add to Saved (Save a Copy for another member's group item), Remove from Saved, Move to Folder… and
    /// Remove from Folder, as they apply to the clips and secrets.</summary>
    private List<PanelAction> SavedActions(IReadOnlyList<PanelEntry> entries)
    {
        var clips = entries.OfType<PanelEntry.Clip>().Select(c => c.Item).ToList();
        var unsaved = clips.Where(c => !c.IsPinned).ToList();
        List<PanelAction> list = [];
        if (unsaved.Any(CanChange)) list.Add(new PanelAction.AddToSaved());
        else if (unsaved.Count > 0) list.Add(new PanelAction.SaveCopy());
        if (clips.Any(IsPinnedWithoutLabel)) list.Add(new PanelAction.RemoveFromSaved());
        if (entries.Count > 0 && entries.All(CanUseFolders)) list.Add(new PanelAction.MoveToFolder());
        if (entries.Any(e => FolderOf(e) is not null)) list.Add(new PanelAction.RemoveFromFolder());
        return list;
    }

    /// <summary>Group items read "Remove from Group": deleting one deletes it for everyone.</summary>
    private PanelAction DeleteAction(IReadOnlyList<ClipItem> clips) =>
        clips.Count > 0 && clips.All(IsGroupItem) ? new PanelAction.RemoveFromGroup() : new PanelAction.Delete();

    public List<PanelAction> FilteredActions
    {
        get
        {
            var q = ActionQuery.Trim();
            if (IsPickingGroup || IsPickingFolder || PickingShareFolder is not null || OtpPicker is not null)
            {
                var choices = OtpPicker is not null ? OtpPickerActions()
                    : PickingShareFolder is { } share ? ShareFolderActions(share)
                    : IsPickingFolder ? FolderPickActions() : ShareActions(!IsMultiSelecting && SelectedEntry is { } e ? SpaceOf(e) : null);
                return q.Length == 0 ? choices
                    : [.. choices.Select(a => (Action: a, Score: FuzzyMatcher.Score(q, a.Title))).Where(x => x.Score is not null)
                        .OrderByDescending(x => x.Score).Select(x => x.Action)];
            }
            if (q.Length == 0) return AvailableActions;
            var matches = AvailableActions
                .Select(a => (Action: a, Score: FuzzyMatcher.Score(q, a.Title + " " + a.Section(AIName))))
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
        if (PerformAuthenticatorAction(action)) return;
        // Folder moves and sharing act on clips and secrets alike, one or several.
        switch (action)
        {
            case PanelAction.MoveToFolder:
                BeginMoveToFolder();
                return;
            case PanelAction.MoveTo move when !IsMultiSelecting && SelectedEntry is PanelEntry.FolderEntry movingFolder:
                if (_folders.GetValueOrDefault(move.FolderId) is { } intoFolder) MoveFolder(movingFolder.Folder, intoFolder);
                return;
            case PanelAction.MoveTo move:
                if (_folders.GetValueOrDefault(move.FolderId) is { } target) MoveToFolder(FolderTargets, target);
                return;
            case PanelAction.MoveToNewFolder newFolder when !IsMultiSelecting && SelectedEntry is PanelEntry.FolderEntry folderToMove:
                BeginNewFolder([folderToMove], parentId: newFolder.ParentId);
                return;
            case PanelAction.MoveToNewFolder newFolder:
                BeginNewFolder(FolderTargets, newFolder.Mine, newFolder.ParentId);
                return;
            case PanelAction.RemoveFromFolder when !IsMultiSelecting && SelectedEntry is PanelEntry.FolderEntry nested:
                MoveFolder(nested.Folder, null);
                return;
            case PanelAction.RemoveFromFolder:
                MoveToFolder(FolderTargets, null);
                return;
            case PanelAction.NewFolderInside when SelectedEntry is PanelEntry.FolderEntry outer:
                NewFolderInside(outer.Folder);
                return;
            case PanelAction.ShareTo share when PickingShareFolder is null && CanShareIntoFolder(share.GroupId):
                // The group has folders: pick where the copies go (the root by default).
                ActionQuery = "";
                ActionSelection = 0;
                IsPickingGroup = false;
                IsPickingFolder = false;
                PickingShareFolder = share;
                Mode = PanelMode.Actions;
                Notify();
                return;
            case PanelAction.ShareTo share:
                ShareSelection(share.GroupId, share.GroupName, null);
                return;
            case PanelAction.ShareInto into:
                ShareSelection(into.GroupId, into.GroupName, into.FolderId);
                return;
        }
        if (IsMultiSelecting) { PerformOnSelection(action); return; }
        if (SelectedEntry is not { } entry) return;
        var item = entry.ClipItem;
        switch (action)
        {
            case PanelAction.Paste: Activate(entry); break;
            case PanelAction.PastePlain: Activate(entry, Transform.PlainText); break;
            case PanelAction.Copy:
                if (item is not null && item == SelectionItem) host.CopyText(item.Text);
                else if (item is not null) host.Copy(ItemForUse(item));
                else if (entry is PanelEntry.SecretEntry k) host.CopySecret(k.Secret);
                host.ClosePanel();
                break;
            case PanelAction.ApplyTransform t when item is not null:
                if (t.Transform.Apply(item.Text) is not { } result)
                {
                    ShowNotice($"Can't apply “{t.Transform.Title()}” to this item");
                    return;
                }
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
            case PanelAction.RemoveFromSaved when item is not null:
                RemoveFromSaved([item]);
                break;
            case PanelAction.AddToSaved or PanelAction.SaveCopy when item is not null:
                AddToSaved([item]);
                break;
            case PanelAction.OpenFolder when entry is PanelEntry.FolderEntry f:
                ResetMode();
                OpenFolderById(f.Folder.Id);
                break;
            case PanelAction.RenameFolder when entry is PanelEntry.FolderEntry f:
                BeginRenameFolder(f.Folder);
                break;
            case PanelAction.DeleteFolder when entry is PanelEntry.FolderEntry f:
                DeleteFolder(f.Folder);
                break;
            case PanelAction.RemoveFromGroup:
                Mode = PanelMode.Browse;
                DeleteSelection();
                break;
            case PanelAction.SaveToFolder when item is not null:
                Save([item], host.SaveFolder);
                break;
            case PanelAction.SaveToChosenFolder when item is not null:
                if (host.ChooseSaveFolder() is { } folder) Save([item], folder);
                break;
            case PanelAction.ShareToGroup:
                BeginShareToGroup();
                break;
            case PanelAction.SendTo send when item is not null:
                SendToDevice?.Invoke(item, new DeviceTarget(send.DeviceId, send.DeviceName));
                ResetMode();
                ShowNotice($"Sending to {send.DeviceName}…");
                break;
            case PanelAction.SendToContact send when item is not null:
                SendToContact(item, send);
                break;
            case PanelAction.Preview:
                Mode = PanelMode.Browse;
                OpenPreview();
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
            case PanelAction.RemoveFromSaved:
                RemoveFromSaved(clips);
                break;
            case PanelAction.AddToSaved or PanelAction.SaveCopy:
                AddToSaved(clips);
                break;
            case PanelAction.SaveToFolder:
                Save(clips, host.SaveFolder);
                break;
            case PanelAction.SaveToChosenFolder:
                if (host.ChooseSaveFolder() is { } folder) Save(clips, folder);
                break;
            case PanelAction.ShareToGroup:
                BeginShareToGroup();
                break;
            case PanelAction.SendToContact send:
                // All or nothing, like sharing to a group.
                if (clips.Where(c => c.SpaceId != send.SpaceId).Select(SyncEngine.ContactSendProblem).FirstOrDefault(p => p is not null) is { } tooBig)
                {
                    ResetMode();
                    ShowNotice(tooBig);
                    break;
                }
                foreach (var c in clips.Where(c => c.SpaceId != send.SpaceId)) store.CopyToSpace(c, send.SpaceId, keepLabel: false);
                ResetMode();
                Refresh();
                ShowNotice($"Sent {clips.Count} items to {send.ContactName}");
                break;
            case PanelAction.Preview:
                Mode = PanelMode.Browse;
                OpenPreview();
                break;
            case PanelAction.Delete or PanelAction.RemoveFromGroup:
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
        PanelEntry.FolderEntry f => f.Folder.SpaceId,
        _ => null,
    };

    /// <summary>Share to Group for the selection (one entry or several): copies into the group with new ids; the
    /// originals stay where they are. Clips and secrets go into <paramref name="folderId"/>, one of the group's
    /// folders, when given (saved, as being in a folder implies); snippets and folders go to the root.</summary>
    public void ShareSelection(string groupId, string groupName, Guid? folderId)
    {
        var folder = folderId is { } id && _folders.GetValueOrDefault(id) is { } f && f.SpaceId == groupId ? f : null;
        var where = folder is null ? $"“{groupName}”" : $"“{groupName} › {folder.Name}”";
        if (!IsMultiSelecting)
        {
            if (SelectedEntry is { } entry) Share(entry, groupId, groupName, folder, where);
            return;
        }
        var clips = SelectedClips.Where(c => c.SpaceId != groupId).ToList();
        var groupSecrets = Entries.Where(e => SelectedIds.Contains(e.Id)).OfType<PanelEntry.SecretEntry>()
            .Select(k => k.Secret).Where(s => s.SpaceId != groupId).ToList();
        // All or nothing: one item that can't sync keeps the whole selection out of the group.
        if (clips.Select(SyncEngine.GroupShareProblem).FirstOrDefault(p => p is not null) is { } problem)
        {
            ResetMode();
            ShowNotice(problem);
            return;
        }
        foreach (var c in clips) CopyIntoGroup(c, groupId, folder);
        var notice = $"Shared {clips.Count + groupSecrets.Count} items to {where}";
        if (groupSecrets.Count > 0) host.CopySecrets(groupSecrets, groupId, folder?.Id, $"share {groupSecrets.Count} secrets with {groupName}", notice);
        ResetMode();
        Refresh();
        if (clips.Count > 0 || groupSecrets.Count == 0) ShowNotice(notice);
    }

    private void CopyIntoGroup(ClipItem item, string groupId, ClipFolder? folder)
    {
        var copy = store.CopyToSpace(item, groupId);
        if (folder is null) return;
        if (!copy.IsPinned)
        {
            copy.IsPinned = true;
            copy.PinnedAt = DateTime.UtcNow;
        }
        copy.FolderId = folder.Id;
        store.Put(copy);
    }

    private void Share(PanelEntry entry, string groupId, string groupName, ClipFolder? folder, string where)
    {
        switch (entry)
        {
            case PanelEntry.Clip c when c.Item == SelectionItem:
                var ingested = store.Ingest(ProcessedCapture.ForText(c.Item.Text, source: c.Item.Source), spaceId: groupId);
                if (folder is not null) store.MoveToFolder([ingested], folder);
                host.ClosePanel();
                return;
            case PanelEntry.Clip c when SyncEngine.GroupShareProblem(c.Item) is { } problem:
                ResetMode();
                ShowNotice(problem);
                return;
            case PanelEntry.Clip c:
                CopyIntoGroup(c.Item, groupId, folder);
                break;
            case PanelEntry.SnippetEntry s:
                store.CopySnippetToSpace(s.Snippet, groupId);
                break;
            case PanelEntry.FolderEntry f:
                // The whole subtree, all or nothing, like sharing several items.
                var subtree = _tree.Subtree(f.Folder.Id).Select(x => x.Id).ToHashSet();
                var inFolder = store.ItemsInSpace(f.Folder.SpaceId).Where(i => i.IsPinned && i.FolderId is { } id && subtree.Contains(id)).ToList();
                if (inFolder.Select(SyncEngine.GroupShareProblem).FirstOrDefault(p => p is not null) is { } folderProblem)
                {
                    ResetMode();
                    ShowNotice(folderProblem);
                    return;
                }
                var (_, map) = store.CopyFolderTreeToSpace(f.Folder, groupId, folder?.Id);
                // Its secrets are copied too, after one Windows Hello, into the new folders.
                var folderSecrets = secrets.Secrets.Where(s => s.SpaceId == f.Folder.SpaceId && FolderOf(s) is { } sf && map.ContainsKey(sf.Id))
                    .Select(s => (s, (Guid?)map[FolderOf(s)!.Id])).ToList();
                if (folderSecrets.Count > 0)
                {
                    host.CopySecretsToFolders(folderSecrets, groupId, $"share the secrets in “{f.Folder.Name}” with {groupName}", $"Shared to {where}");
                    ResetMode();
                    Refresh();
                    return;
                }
                break;
            case PanelEntry.SecretEntry k:
                host.CopySecrets([k.Secret], groupId, folder?.Id, $"share “{k.Secret.Name}” with {groupName}", $"Shared “{k.Secret.Name}” to {where}");
                ResetMode();
                return;
        }
        ResetMode();
        Refresh();
        ShowNotice($"Shared to {where}");
    }

    /// <summary>Copies a clip into the contact's space (without this user's label): it arrives in their Inbox.
    /// Same limits as sharing to a group.</summary>
    public void SendToContact(ClipItem item, PanelAction.SendToContact send)
    {
        if (item == SelectionItem)
        {
            store.Ingest(ProcessedCapture.ForText(item.Text, source: item.Source), spaceId: send.SpaceId);
            host.ClosePanel();
            return;
        }
        ResetMode();
        if (SyncEngine.ContactSendProblem(item) is { } problem)
        {
            ShowNotice(problem);
            return;
        }
        store.CopyToSpace(item, send.SpaceId, keepLabel: false);
        Refresh();
        ShowNotice($"Sent to {send.ContactName}");
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

    /// <summary>Unsaves items saved without a label, so they expire like the rest of history, and takes them out of
    /// their folder. Labelled items stay saved: removing the label is what lets them go.</summary>
    public void RemoveFromSaved(IReadOnlyList<ClipItem> items)
    {
        var unpinned = items.Where(IsPinnedWithoutLabel).ToList();
        foreach (var item in unpinned) store.Unpin(item);
        ResetMode();
        Refresh();
        ShowNotice(unpinned.Count == 1 ? "Removed from Saved" : $"Removed {unpinned.Count} items from Saved");
    }

    /// <summary>Writes each item into <paramref name="folder"/> (text as .txt, images as .png, files as copies) and
    /// says how it went in the footer.</summary>
    public void Save(IReadOnlyList<ClipItem> items, string folder)
    {
        if (items.Count == 0) return;
        var outcome = ItemSaver.Save(items, folder, store.Blobs);
        ResetMode();
        ShowNotice(outcome.Notice(FolderName(folder)));
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
                store.SetSecretFolder(k.Secret.Id, null);
                break;
            case PanelEntry.FolderEntry f:
                DeleteFolder(f.Folder);
                if (Entries.Count > 0) Select(Entries[Math.Min(index, Entries.Count - 1)].Id);
                return;
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
        PanelMode.SnippetForm or PanelMode.SaveSecret or PanelMode.Label or PanelMode.EditSecret or PanelMode.FolderName
            or PanelMode.AuthenticatorForm => HandleFormKey(key),
        PanelMode.AuthenticatorSecret or PanelMode.AuthenticatorPeople or PanelMode.ConfirmDelete => HandleAuthenticatorKey(key),
        PanelMode.AddItems => HandleAddItemsKey(key),
        _ => HandleAIKey(key),
    };

    private bool HandleBrowseKey(KeyInput key)
    {
        switch (key.Key)
        {
            case PanelKey.Escape:
                // The preview closes first, then picked files are let go; the next Escape closes.
                // In a folder, Escape goes back to Saved's root rather than closing.
                if (IsPreviewing) ClosePreview();
                else if (PickedFiles.Count > 0) ClearPickedFiles();
                else if (Entries.Any(e => e is PanelEntry.OtpSuggestion)) DismissOtpSuggestion();
                else if (OpenFolderId is not null) CloseFolder();
                else host.ClosePanel();
                return true;
            case PanelKey.Backspace when Query.Length == 0 && OpenFolderId is not null:
                CloseFolder();
                return true;
            case PanelKey.Up: MoveSelection(-1, key.Shift); return true;
            case PanelKey.Down: MoveSelection(1, key.Shift); return true;
            // ←/→ page through the preview; otherwise they move the caret in the search box.
            case PanelKey.Left when !IsPreviewing && Query.Length == 0 && OpenFolderId is not null:
                CloseFolder();
                return true;
            case PanelKey.Left or PanelKey.Right when IsPreviewing:
                StepPreview(key.Key == PanelKey.Right ? 1 : -1);
                return true;
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
                if (!IsMultiSelecting && SelectedEntry is PanelEntry.AuthenticatorEntry { Authenticator: var doomed }) BeginDeleteAuthenticator(doomed);
                else if (IsMultiSelecting) DeleteSelectedClips(); else DeleteSelection();
                return true;
            case PanelKey.Digit when key.Ctrl:
                if (key.Shift) AssignSelection(key.Digit); else ActivateShortcut(key.Digit);
                return true;
            case PanelKey.Letter when key.Ctrl:
                switch (char.ToLowerInvariant(key.Letter))
                {
                    case 'k': OpenActions(); return true;
                    case 'y': TogglePreview(); return true;
                    case 'l': BeginLabelSelection(); return true;
                    case 'm' when key.Shift: BeginMoveSelection(); return true;
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
                // Picking a group's folder goes back to the groups; picking a group or a folder, to the actions.
                if (PickingShareFolder is not null) { PickingShareFolder = null; IsPickingGroup = true; ActionQuery = ""; ActionSelection = 0; Notify(); }
                else if (IsPickingGroup || IsPickingFolder || OtpPicker is not null) { IsPickingGroup = false; IsPickingFolder = false; OtpPicker = null; ActionQuery = ""; ActionSelection = 0; Notify(); }
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
                    case PanelMode.FolderName: SubmitFolderName(); break;
                    case PanelMode.AuthenticatorForm: SubmitAuthenticatorForm(); break;
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
            case PanelKey.Left or PanelKey.Right or PanelKey.Backspace or PanelKey.Space:
                return false;   // the caret in the output, as before these were mapped
            case PanelKey.Letter when key.Ctrl:
                if (char.ToLowerInvariant(key.Letter) == 'c') CopyAIOutput();
                if (char.ToLowerInvariant(key.Letter) == 'r') ReplaceItemWithAIOutput();
                return true;
            default:
                return true;
        }
    }
}
