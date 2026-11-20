namespace Clipboard2.Core;

/// <summary>Folders in folders (docs/features/nested-folders.md): each folder's effective parent, paths and subtrees.
/// A parent this device doesn't have, of another space, a cycle or more than <see cref="MaxDepth"/> levels reads as
/// the top level.</summary>
public sealed class FolderTree
{
    public const int MaxDepth = 8;

    private readonly Dictionary<Guid, ClipFolder> _all;
    private readonly Dictionary<Guid, Guid?> _parent = [];
    private readonly Dictionary<Guid, int> _depth = [];

    public FolderTree(IEnumerable<ClipFolder> folders)
    {
        _all = folders.GroupBy(f => f.Id).ToDictionary(g => g.Key, g => g.First());
        foreach (var id in _all.Keys) Depth(id);
    }

    public ClipFolder? Find(Guid id) => _all.GetValueOrDefault(id);
    public IEnumerable<ClipFolder> All => _all.Values;

    /// <summary>The parent the UI uses, or null for the top level.</summary>
    public Guid? ParentOf(Guid id)
    {
        Depth(id);
        return _parent.GetValueOrDefault(id);
    }

    public ClipFolder? Parent(ClipFolder folder) => ParentOf(folder.Id) is { } p ? _all.GetValueOrDefault(p) : null;

    /// <summary>1 for a top-level folder.</summary>
    public int Depth(Guid id)
    {
        if (_depth.TryGetValue(id, out var known)) return known;
        if (!_all.TryGetValue(id, out var folder)) return 0;
        Guid? parent = folder.ParentId is { } p && p != id && _all.TryGetValue(p, out var pf) && pf.SpaceId == folder.SpaceId && !MeetsItself(folder)
            ? p : null;
        _depth[id] = 1;   // provisional, in case of a cycle among the ancestors
        var depth = parent is { } q ? Depth(q) + 1 : 1;
        if (depth > MaxDepth)
        {
            parent = null;
            depth = 1;
        }
        _parent[id] = parent;
        _depth[id] = depth;
        return depth;
    }

    /// <summary>Walking up the stored parents meets the folder again.</summary>
    private bool MeetsItself(ClipFolder folder)
    {
        var seen = new HashSet<Guid>();
        var current = folder.ParentId;
        while (current is { } id && _all.TryGetValue(id, out var f) && seen.Add(id))
        {
            if (id == folder.Id) return true;
            current = f.ParentId;
        }
        return false;
    }

    /// <summary>The folder's subfolders, by name.</summary>
    public List<ClipFolder> Children(Guid? parent, string? space) =>
        [.. _all.Values.Where(f => f.SpaceId == space && ParentOf(f.Id) == parent).OrderBy(f => f.Name, StringComparer.CurrentCultureIgnoreCase)];

    /// <summary>From the top level down to the folder itself.</summary>
    public List<ClipFolder> Path(Guid id)
    {
        var path = new List<ClipFolder>();
        for (Guid? current = id; current is { } c && _all.TryGetValue(c, out var f) && path.Count <= MaxDepth; current = ParentOf(c))
            path.Insert(0, f);
        return path;
    }

    /// <summary>"Work › Clients", or relative to <paramref name="from"/> (left out with its ancestors).</summary>
    public string PathText(Guid id, Guid? from = null)
    {
        var path = Path(id);
        if (from is { } start && path.FindIndex(f => f.Id == start) is var i and >= 0) path = path[(i + 1)..];
        return string.Join(" › ", path.Select(f => f.Name));
    }

    public bool IsInSubtree(Guid id, Guid root)
    {
        for (Guid? current = id; current is { } c; current = ParentOf(c))
            if (c == root) return true;
        return false;
    }

    /// <summary>The folder and everything under it.</summary>
    public List<ClipFolder> Subtree(Guid root) => [.. _all.Values.Where(f => IsInSubtree(f.Id, root))];

    /// <summary>Levels from the folder down to its deepest subfolder (1 without subfolders).</summary>
    public int Height(Guid root) => Subtree(root).Select(f => Depth(f.Id) - Depth(root) + 1).DefaultIfEmpty(1).Max();

    /// <summary>Whether <paramref name="folder"/> may go into <paramref name="parent"/> (null: the top level): same
    /// space, never into itself or below itself, and never deeper than <see cref="MaxDepth"/>.</summary>
    public bool CanMove(ClipFolder folder, ClipFolder? parent)
    {
        if (parent is null) return true;
        if (parent.SpaceId != folder.SpaceId || IsInSubtree(parent.Id, folder.Id)) return false;
        return Depth(parent.Id) + Height(folder.Id) <= MaxDepth;
    }

    /// <summary>Whether a new folder may be made inside <paramref name="parent"/>.</summary>
    public bool CanCreateIn(Guid? parent) => parent is not { } p || Depth(p) < MaxDepth;
}
