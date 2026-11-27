namespace Clipboard2.Core;

/// <summary>Saved ▸ Add Items: recent unsaved clips of the Saved shown, to check and add (into the open folder).</summary>
public sealed class AddItemsForm
{
    public string Query { get; set; } = "";
    public List<ClipItem> Candidates { get; set; } = [];
    public HashSet<Guid> Checked { get; } = [];
    public int Cursor { get; set; }
    /// <summary>Contacts ▸ People ▸ Send…: the checked clips go to this contact instead of into Saved.</summary>
    public SpaceRecord? SendTo { get; init; }
    public ClipItem? Current => Cursor >= 0 && Cursor < Candidates.Count ? Candidates[Cursor] : null;
}

public sealed partial class PanelModel
{
    public const int AddItemsLimit = 100;

    public AddItemsForm? AddItemsForm { get; private set; }

    // MARK: Label row

    /// <summary>Whether the details' Label row (and Ctrl+L) is offered: clips, secrets and folders this user may
    /// change; not what a contact sent, nor the selection from another app.</summary>
    public bool CanLabel(PanelEntry entry) => entry switch
    {
        PanelEntry.Clip c => c.Item != SelectionItem && CanChange(c.Item) && !IsReceived(c),
        PanelEntry.SecretEntry k => k.Secret.SpaceId is not { } space || !_contacts.ContainsKey(space) || !IsFromContact(space, k),
        PanelEntry.FolderEntry f => CanChangeFolder(f.Folder),
        _ => false,
    };

    private bool IsReceived(PanelEntry.Clip c) => c.Item.SpaceId is { } space && _contacts.ContainsKey(space) && IsFromContact(space, c);

    /// <summary>What the Label row's chip shows (a secret's name is its label), or null for "Add label".</summary>
    public static string? LabelText(PanelEntry entry) => entry switch
    {
        PanelEntry.Clip c => c.Item.Label,
        PanelEntry.SecretEntry k => k.Secret.Name,
        PanelEntry.FolderEntry f => f.Folder.Label,
        _ => null,
    };

    /// <summary>Ctrl+L: the label form for the selection; several clips get the same label.</summary>
    public void BeginLabelSelection()
    {
        if (IsMultiSelecting)
        {
            var clips = Entries.Where(e => SelectedIds.Contains(e.Id)).OfType<PanelEntry.Clip>().Where(CanLabel).ToList();
            if (clips.Count == 0) return;
            var first = clips[0];
            LabelForm = new LabelForm(first) { AlsoClips = [.. clips.Skip(1).Select(c => c.Item)] };
            Mode = PanelMode.Label;
            Notify();
            return;
        }
        if (SelectedEntry is { } entry && CanLabel(entry)) BeginLabel(entry);
    }

    // MARK: Folder row

    /// <summary>Whether the details' Folder row (and Ctrl+Shift+M) is offered for the selection.</summary>
    public bool CanMoveSelection
    {
        get
        {
            var targets = FolderTargets;
            return targets.Count > 0 && targets.All(e => CanUseFolders(e) && (e is not PanelEntry.Clip c || !IsReceived(c)));
        }
    }

    /// <summary>"Saved › Work › Clients" for an item in a folder (the group's name first for a group item), or null
    /// when it isn't in one.</summary>
    public string? FolderLocation(PanelEntry entry)
    {
        if (FolderOf(entry) is not { } folder) return null;
        var root = folder.SpaceId is { } space ? $"{GroupNames.GetValueOrDefault(space, "Group")} › Saved" : "Saved";
        return root + " › " + _tree.PathText(folder.Id);
    }

    /// <summary>The selection's folder when all of it is in the same one, for the multi-select summary.</summary>
    public string? CommonFolderLocation =>
        FolderTargets is { Count: > 0 } targets && targets.Select(e => FolderOf(e)?.Id).Distinct().Count() == 1 ? FolderLocation(targets[0]) : null;

    /// <summary>Ctrl+Shift+M, or the Folder row: the folder picker in the right pane.</summary>
    public void BeginMoveSelection()
    {
        if (!IsMultiSelecting && SelectedEntry is PanelEntry.FolderEntry f)
        {
            if (CanChangeFolder(f.Folder)) BeginMoveToFolder();
            return;
        }
        if (CanMoveSelection) BeginMoveToFolder();
    }

    // MARK: Add Items

    /// <summary>Saved's Add Items button: recent unsaved clips of this space, to check and add here.</summary>
    public bool CanAddItems => IsSavedView && SelectionItem is null && CanSendTo(SavedSpace);

    public void BeginAddItems()
    {
        if (!CanAddItems) return;
        ResetMode();
        AddItemsForm = new AddItemsForm();
        FillAddItems();
        Mode = PanelMode.AddItems;
        Notify();
    }

    private void FillAddItems()
    {
        if (AddItemsForm is not { } form) return;
        var q = form.Query.Trim();
        // Sending: the personal history and Saved, newest first.
        var unsaved = form.SendTo is not null ? store.ItemsInSpace(null)
            : store.ItemsInSpace(SavedSpace).Where(i => !i.IsPinned && CanChange(i));
        form.Candidates = q.Length == 0 ? [.. unsaved.Take(AddItemsLimit)]
            : [.. unsaved.Select(i => (Item: i, Score: FuzzyMatcher.Score(q, i.SearchableText))).Where(x => x.Score is not null)
                .OrderByDescending(x => x.Score).ThenByDescending(x => x.Item.LastCopiedAt).Take(AddItemsLimit).Select(x => x.Item)];
        form.Cursor = Math.Clamp(form.Cursor, 0, Math.Max(0, form.Candidates.Count - 1));
    }

    public void SetAddItemsQuery(string query)
    {
        if (AddItemsForm is not { } form || form.Query == query) return;
        form.Query = query;
        form.Cursor = 0;
        FillAddItems();
        Notify();
    }

    public void ToggleAddItem(Guid id)
    {
        if (AddItemsForm is not { } form) return;
        if (!form.Checked.Remove(id)) form.Checked.Add(id);
        if (form.Candidates.FindIndex(c => c.Id == id) is var i and >= 0) form.Cursor = i;
        Notify();
    }

    /// <summary>Enter: saves the checked clips (the highlighted one when none is checked) and, inside a folder,
    /// moves them into it.</summary>
    public void SubmitAddItems()
    {
        if (AddItemsForm is not { } form) return;
        var ids = form.Checked.Count > 0 ? form.Checked : form.Current is { } current ? [current.Id] : new HashSet<Guid>();
        if (form.SendTo is { } contact)
        {
            var picked = ids.Select(store.Find).OfType<ClipItem>().Select(i => (PanelEntry)new PanelEntry.Clip(i)).ToList();
            ResetMode();
            if (picked.Count == 0) ShowNotice("Nothing to send");
            else SendEntries(picked, [contact]);
            return;
        }
        var items = ids.Select(store.Find).OfType<ClipItem>().Where(i => !i.IsPinned && i.SpaceId == SavedSpace && CanChange(i)).ToList();
        var folder = OpenFolder;
        ResetMode();
        if (items.Count == 0)
        {
            ShowNotice("Nothing to add");
            return;
        }
        foreach (var item in items) store.Pin(item);
        if (folder is not null) store.MoveToFolder(items, folder);
        Refresh();
        ShowNotice((items.Count == 1 ? "Added 1 item" : $"Added {items.Count} items") + $" to {folder?.Name ?? "Saved"}");
    }

    private bool HandleAddItemsKey(KeyInput key)
    {
        if (AddItemsForm is not { } form) return false;
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
            case PanelKey.Space when form.Current is { } current:
                ToggleAddItem(current.Id);
                return true;
            case PanelKey.Enter:
                SubmitAddItems();
                return true;
            default:
                return false;   // typing goes to the search field
        }
    }
}
