namespace Clipboard2.Core;

/// <summary>The one line a subtle notice shows when contacts send something: "anna sent you “hello”",
/// "anna sent you 3 items", "2 contacts sent you 5 items". Arrivals of one sync are shown together.</summary>
public static class ContactNotice
{
    public const int PreviewLength = 40;

    /// <param name="arrivals">Who sent what, as (contact name, item preview), in arrival order.</param>
    public static string Title(IReadOnlyList<(string From, string Preview)> arrivals)
    {
        if (arrivals.Count == 0) return "";
        var senders = arrivals.Select(a => a.From).Distinct().ToList();
        if (arrivals.Count == 1) return $"{senders[0]} sent you “{Short(arrivals[0].Preview)}”";
        return senders.Count == 1 ? $"{senders[0]} sent you {arrivals.Count} items" : $"{senders.Count} contacts sent you {arrivals.Count} items";
    }

    /// <summary>The first line, at most <see cref="PreviewLength"/> characters.</summary>
    public static string Short(string preview)
    {
        var line = preview.Split('\n', 2)[0].Trim();
        if (line.Length == 0) return "an item";
        return line.Length > PreviewLength ? line[..(PreviewLength - 1)] + "…" : line;
    }
}
