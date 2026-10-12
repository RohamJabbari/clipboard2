using System.Text.Json;
using System.Text.Json.Serialization;
using Clipboard2.Core.AI;

namespace Clipboard2.Core;

public enum AppearanceMode { System, Light, Dark }
public enum PanelSize { Compact, Regular, Large }
public enum ContextMenuModifier { Control, Alt }

public sealed record AppTransformRule(AppRef App, Transform Transform);

public sealed class CustomPrompt
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "New Prompt";
    public string Prompt { get; set; } = "";
}

[JsonConverter(typeof(JsonStringEnumConverter<SlotKind>))]
public enum SlotKind { Clip, Snippet, Secret }

/// <summary>What a quick slot (Ctrl+1…9) points at.</summary>
public sealed record SlotTarget(SlotKind Kind, string Id)
{
    public static SlotTarget ForClip(Guid id) => new(SlotKind.Clip, id.ToString());
    public static SlotTarget ForSnippet(Guid id) => new(SlotKind.Snippet, id.ToString());
    public static SlotTarget ForSecret(string id) => new(SlotKind.Secret, id);
}

/// <summary>User settings, stored as JSON in %APPDATA%\Clipboard2\settings.json.
/// Secrets and API keys are never stored here — see the Credential Manager store.</summary>
public sealed class Settings
{
    public const int DefaultMaxItems = 500;
    public const int DefaultMaxAgeMinutes = 43_200;   // 30 days
    public static readonly int[] MaxItemChoices = [100, 250, 500, 1000, 2500, 5000, 0];
    public static readonly int[] MaxAgeChoices = [15, 60, 480, 1_440, 10_080, 43_200, 129_600, 525_600, 0];
    public static readonly int[] SecretGraceChoices = [0, 1, 5, 15, 60];
    public static readonly int[] SecretClearChoices = [15, 30, 60, 120, 0];

    public int MaxItems { get; set; } = DefaultMaxItems;
    public int MaxAgeMinutes { get; set; } = DefaultMaxAgeMinutes;
    public bool IsPaused { get; set; }
    public AppearanceMode Appearance { get; set; } = AppearanceMode.System;
    public PanelSize PanelSize { get; set; } = PanelSize.Regular;
    public List<AppRef> IgnoredApps { get; set; } = [.. AppRef.DefaultIgnored];
    public List<AppTransformRule> AppTransforms { get; set; } = [];
    public AIProviderKind AIProvider { get; set; } = AIProviderKind.ClaudeCode;
    public Dictionary<string, string> AIModels { get; set; } = [];
    public string CustomBaseUrl { get; set; } = "http://localhost:11434/v1";
    public List<CustomPrompt> CustomPrompts { get; set; } = [];
    public int SecretGraceMinutes { get; set; } = 15;
    public int SecretClearSeconds { get; set; } = 30;
    public bool ContextMenuEnabled { get; set; } = true;
    public ContextMenuModifier ContextMenuModifier { get; set; } = ContextMenuModifier.Control;
    public Dictionary<int, SlotTarget> QuickSlots { get; set; } = [];
    public Dictionary<string, string> Hotkeys { get; set; } = new(Hotkey.Defaults);
    public bool LaunchAtLogin { get; set; } = true;
    public bool CheckForUpdates { get; set; } = true;
    public bool InstallUpdatesAutomatically { get; set; }
    public bool HasLaunchedBefore { get; set; }

    [JsonIgnore] public TimeSpan? MaxAge => MaxAgeMinutes > 0 ? TimeSpan.FromMinutes(MaxAgeMinutes) : null;
    [JsonIgnore] public HashSet<string> IgnoredIds => IgnoredApps.Select(a => a.Id.ToLowerInvariant()).ToHashSet();

    [JsonIgnore]
    public string AIModel
    {
        get => AIModels.TryGetValue(AIProvider.ToString(), out var m) ? m : AIProvider.DefaultModel();
        set => AIModels[AIProvider.ToString()] = value;
    }

    public Transform? DefaultTransform(string? appId) =>
        appId is null ? null : AppTransforms.FirstOrDefault(r => string.Equals(r.App.Id, appId, StringComparison.OrdinalIgnoreCase))?.Transform;

    public static string DescribeAge(int minutes) => minutes switch
    {
        0 => "Never",
        < 60 => $"{minutes} minutes",
        60 => "1 hour",
        < 1_440 => $"{minutes / 60} hours",
        1_440 => "1 day",
        _ => $"{minutes / 1_440} days",
    };

    // MARK: Persistence

    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    [JsonIgnore] public string? FilePath { get; private set; }
    public event Action? Changed;

    public static Settings Load(string path)
    {
        Settings settings;
        try
        {
            settings = File.Exists(path) ? JsonSerializer.Deserialize<Settings>(File.ReadAllText(path), Json) ?? new() : new();
        }
        catch
        {
            settings = new();   // corrupt file: start fresh rather than refusing to launch
        }
        foreach (var (name, combo) in Hotkey.Defaults) settings.Hotkeys.TryAdd(name, combo);
        settings.FilePath = path;
        return settings;
    }

    public void Save()
    {
        if (FilePath is not null)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            var temp = FilePath + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(this, Json));
            File.Move(temp, FilePath, overwrite: true);
        }
        Changed?.Invoke();
    }
}

/// <summary>Global shortcut names and their defaults (Windows equivalents of the Mac ones).</summary>
public static class Hotkey
{
    public const string QuickPanel = "quickPanel";
    public const string SelectionActions = "selectionActions";
    public const string PasteAsText = "pasteAsText";
    public const string CaptureText = "captureText";
    public static string Slot(int n) => $"slot{n}";

    public static readonly IReadOnlyDictionary<string, string> Defaults = new Dictionary<string, string>
    {
        [QuickPanel] = "Ctrl+Shift+V",
        [SelectionActions] = "Ctrl+Alt+K",
        [PasteAsText] = "Ctrl+Alt+Shift+V",
        [CaptureText] = "Ctrl+Alt+Shift+2",
    };

    public static string Title(string name) => name switch
    {
        QuickPanel => "Open quick panel",
        SelectionActions => "Actions on selected text",
        PasteAsText => "Paste as text",
        CaptureText => "Capture text from screen",
        _ when name.StartsWith("slot") => $"Paste quick slot {name[4..]}",
        _ => name,
    };
}

/// <summary>Ctrl+1…9 bound to saved things instead of list positions.</summary>
public sealed class QuickSlots(Settings settings)
{
    public const int First = 1, Last = 9;

    public SlotTarget? Target(int slot) => settings.QuickSlots.GetValueOrDefault(slot);

    public int? SlotFor(SlotTarget target) =>
        settings.QuickSlots.FirstOrDefault(p => p.Value == target) is { Value: not null } pair ? pair.Key : null;

    public void Assign(SlotTarget target, int slot)
    {
        if (slot is < First or > Last) return;
        if (SlotFor(target) is { } existing) settings.QuickSlots.Remove(existing);
        settings.QuickSlots[slot] = target;
        settings.Save();
    }

    public void Clear(int slot)
    {
        if (settings.QuickSlots.Remove(slot)) settings.Save();
    }

    public void Remove(SlotTarget target)
    {
        if (SlotFor(target) is { } slot) Clear(slot);
    }
}
