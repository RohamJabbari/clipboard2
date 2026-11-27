namespace Clipboard2.Core.Tests;

/// <summary>Shortcuts shown with the key names of the user's keyboard (Strg on German layouts).</summary>
public sealed class KeyLabelsTests
{
    private static readonly Dictionary<string, string> German = new()
    {
        ["Ctrl"] = "Strg", ["Shift"] = "Umschalt", ["Enter"] = "Eingabe", ["Del"] = "Entf", ["Esc"] = "Esc",
    };

    [Fact]
    public void English_keyboards_keep_the_written_names() =>
        Assert.Equal("Ctrl+Shift+M", KeyLabels.Show("Ctrl+Shift+M", new Dictionary<string, string>()));

    [Fact]
    public void Shortcut_uses_the_keyboards_names()
    {
        Assert.Equal("Strg+Umschalt+M", KeyLabels.Show("Ctrl+Shift+M", German));
        Assert.Equal("Strg+Alt+C", KeyLabels.Show("Ctrl+Alt+C", German));   // Alt has no German name of its own
    }

    [Fact]
    public void Hint_line_renames_only_the_keys_of_each_segment() =>
        Assert.Equal("Eingabe Paste    Umschalt+Eingabe Plain Text    ↑↓ Choose    Type to Search    Entf Delete    Esc Close",
            KeyLabels.Hints("Enter Paste    Shift+Enter Plain Text    ↑↓ Choose    Type to Search    Del Delete    Esc Close", German));

    [Fact]
    public void Prose_renames_shortcuts_but_not_words() =>
        Assert.Equal("Press Strg+Umschalt+1–9 to bind it; Strg+K. Enter stays a word, Shift too.",
            KeyLabels.Prose("Press Ctrl+Shift+1–9 to bind it; Ctrl+K. Enter stays a word, Shift too.", German));

    [Theory]
    [InlineData("STRG", "Strg")]
    [InlineData("UMSCHALT", "Umschalt")]
    [InlineData("Ctrl", "Ctrl")]
    [InlineData("A", "A")]
    public void Windows_key_names_are_written_as_in_menus(string raw, string shown) => Assert.Equal(shown, KeyLabels.Tidy(raw));
}
