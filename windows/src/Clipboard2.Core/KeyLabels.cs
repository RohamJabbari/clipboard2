namespace Clipboard2.Core;

/// <summary>
/// Shortcuts are written and stored in English ("Ctrl+Shift+V"); this shows them with the names
/// printed on the user's keyboard ("Strg+Umschalt+V" on a German layout). The app fills
/// <see cref="Names"/> from the active keyboard layout; with none set, the English names stay.
/// </summary>
public static class KeyLabels
{
    /// <summary>The keys that are renamed: English name → name on this keyboard.</summary>
    public static readonly string[] Keys = ["Ctrl", "Shift", "Alt", "Enter", "Esc", "Del", "Backspace", "Tab", "Space"];

    private static IReadOnlyDictionary<string, string> _names = new Dictionary<string, string>();

    /// <summary>Raised after <see cref="Names"/> changes (the keyboard layout was switched).</summary>
    public static event Action? Changed;

    public static IReadOnlyDictionary<string, string> Names
    {
        get => _names;
        set { _names = value; Changed?.Invoke(); }
    }

    /// <summary>One shortcut: "Ctrl+Shift+M" → "Strg+Umschalt+M". Unknown parts are kept.</summary>
    /// <param name="names">For tests: these names instead of the keyboard's.</param>
    public static string Show(string combo, IReadOnlyDictionary<string, string>? names = null)
    {
        names ??= _names;
        if (combo.Length == 0 || names.Count == 0) return combo;
        var parts = combo.Split('+');
        for (var i = 0; i < parts.Length; i++)
            if (names.TryGetValue(parts[i], out var name)) parts[i] = name;
        return string.Join("+", parts);
    }

    /// <summary>
    /// A hint line of "‹keys› ‹what it does›" segments, four spaces apart:
    /// "Enter Paste    Ctrl+K Actions" → "Eingabe Paste    Strg+K Actions".
    /// </summary>
    public static string Hints(string line, IReadOnlyDictionary<string, string>? names = null)
    {
        names ??= _names;
        if (names.Count == 0) return line;
        var segments = line.Split("    ");
        for (var i = 0; i < segments.Length; i++)
        {
            var space = segments[i].IndexOf(' ');
            var keys = space < 0 ? segments[i] : segments[i][..space];
            segments[i] = Show(keys, names) + (space < 0 ? "" : segments[i][space..]);
        }
        return string.Join("    ", segments);
    }

    /// <summary>Every shortcut inside a sentence: "press Ctrl+Shift+1–9 to bind it" → "press Strg+Umschalt+1–9 to bind it".</summary>
    public static string Prose(string text, IReadOnlyDictionary<string, string>? names = null)
    {
        names ??= _names;
        return names.Count == 0 ? text : ProseCombo.Replace(text, m => Show(m.Value, names));
    }

    private static readonly System.Text.RegularExpressions.Regex ProseCombo =
        new(@"\b(?:Ctrl|Alt|Shift)(?:\+[\w–]+)+", System.Text.RegularExpressions.RegexOptions.Compiled);

    /// <summary>"STRG" → "Strg", as Windows writes key names in menus. Mixed case is kept.</summary>
    public static string Tidy(string name)
    {
        name = name.Trim();
        if (name.Length < 2 || name.Any(char.IsLower)) return name;
        return string.Concat(name[..1], name[1..].ToLowerInvariant());
    }
}
