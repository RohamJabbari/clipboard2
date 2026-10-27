namespace Clipboard2.Core;

public sealed record LegalSection(string Title, string Body);

/// <summary>The privacy notice (Art. 13 GDPR) and the Impressum, shown in Settings → About and linked at sign-up.
/// <c>[ADDRESS]</c> and <c>[CONTACT EMAIL]</c> are placeholders until the operator fills them in.</summary>
public static class Legal
{
    public const string Operator = "Roham Jabbari";
    public const string Address = "[ADDRESS]";
    public const string ContactEmail = "[CONTACT EMAIL]";
    public const string PrivacyUpdated = "October 2026";

    public static readonly IReadOnlyList<LegalSection> PrivacyNotice =
    [
        new("Who is responsible",
            $"Clipboard2 is run by {Operator}, a private person in Austria ({Address}). He is the controller for the sync service under the GDPR. " +
            $"For anything about your data, write to {ContactEmail}."),
        new("Without an account, nothing leaves your PC",
            "Your history, images, files, snippets and settings are stored only on this PC. Secrets are stored in Windows Credential Manager. " +
            "Text recognition in images runs on this PC. Clipboard2 has no analytics, no tracking and no advertising.\n" +
            "• Updates: if update checks are on (Settings → About), the app asks GitHub (GitHub, Inc., USA) for new versions about once an hour. " +
            "GitHub sees your IP address and the app version, as with any download."),
        new("What sync stores, if you create an account",
            "• Your email address. It's only your sign-in name; it isn't verified and you get no emails.\n" +
            "• Your username, shown to the people in your groups next to the items you share.\n" +
            "• A value derived from your password, used to check your sign-in, and your encryption keys, themselves encrypted with your password. " +
            "Your password never leaves your devices.\n" +
            "• Your synced content: history (the newest 200 items), pinned items, images, files, snippets and secrets, and your group names. " +
            "All of it is encrypted on your device before upload.\n" +
            "• Metadata needed to sync: item ids and types (history, pinned, snippet or secret), sizes, timestamps, who wrote each item, " +
            "which groups you're in and your role, the names of your signed-in devices (e.g. your PC's name) and when they were last used, " +
            "and invite and sign-up codes (stored only as hashes).\n" +
            "Your IP address is used to answer requests and to limit abuse (rate limits). Request logs don't record IP addresses or email addresses."),
        new("The server can't read your clipboard",
            "Sync is end-to-end encrypted. Your content is encrypted on your device with keys only your devices have. " +
            "The server, the operator and Google can see that an encrypted item exists, its size and its timestamps, but not what's in it. " +
            "This is also why there's no password recovery: nobody but you can unlock the data."),
        new("Where it's stored",
            "On Google Cloud (Cloud Run, Cloud SQL and Cloud Storage) in the europe-west1 region (Belgium, EU). Google acts as a processor under a " +
            "data processing agreement. Where Google's staff or sub-processors outside the EU could access data, transfers rely on the EU Standard " +
            "Contractual Clauses and the EU–US Data Privacy Framework."),
        new("Why, and on what legal basis",
            "• To provide the sync you signed up for: storing and delivering your encrypted items, groups and invites (Art. 6(1)(b) GDPR, contract).\n" +
            "• To keep the service secure and working: rate limits, abuse prevention and error logs (Art. 6(1)(f) GDPR, legitimate interest in a " +
            "secure service).\n" +
            "Providing your data isn't a legal requirement. Without an email and password you can't use sync; the rest of the app works without it. " +
            "There's no automated decision-making or profiling."),
        new("How long it's kept",
            "• Your account and synced data: until you delete them.\n" +
            "• Personal history on the server: the newest 200 items; older ones are removed as new ones arrive.\n" +
            "• Deleted items leave a tombstone (id and timestamps, no content) for 90 days, so your other devices learn about the deletion.\n" +
            "• Sessions end after 30 days without use. Group invites expire after 7 days, sign-up codes after 14 days.\n" +
            "• Google Cloud's automatic database backups may hold encrypted copies for a few more days before they're overwritten."),
        new("Deleting your account",
            "Settings → Sync → Delete Account deletes your account, your personal space, the groups you own and the items you wrote in other groups, " +
            "straight away. Your local history on this PC stays until you clear it."),
        new("AI features, only if you turn them on",
            "AI actions are off until you set them up in Settings → AI. When you run one, the text you chose and your instruction are sent " +
            "directly from your PC to the provider you picked: Anthropic (Claude), OpenAI (ChatGPT), Google (Gemini), DeepSeek, Groq, xAI, Mistral, " +
            "OpenRouter, or a custom endpoint you entered. They don't pass through Clipboard2's server. That provider processes the text under its " +
            "own terms and privacy policy, with your account or API key; several are outside the EU (mostly the USA). API keys are stored in " +
            "Windows Credential Manager on this PC."),
        new("Your rights",
            "You can ask for access to your data (Art. 15 GDPR), correction (Art. 16), deletion (Art. 17), restriction (Art. 18), a portable copy " +
            "(Art. 20; Settings → General → Export Backup also gives you one) and you can object to processing based on legitimate interest (Art. 21). " +
            $"Write to {ContactEmail}. Because your content is end-to-end encrypted, the operator can only hand out or delete it as encrypted data.\n" +
            "You can also complain to a data protection authority, in Austria the Datenschutzbehörde (Barichgasse 40–42, 1030 Vienna, www.dsb.gv.at)."),
        new("Changes", $"If this notice changes, the new version ships with the app. Last updated: {PrivacyUpdated}."),
    ];

    public static readonly IReadOnlyList<LegalSection> Impressum =
    [
        new("Impressum",
            $"Medieninhaber und Betreiber / Owner and operator:\n{Operator}\n{Address}\nAustria\n\nKontakt / Contact: {ContactEmail}"),
        new("Offenlegung (§ 25 MedienG)",
            "Clipboard2 is a private, non-commercial project. Grundlegende Richtung: information about the Clipboard2 app and its sync service."),
    ];

    /// <summary>The whole notice as plain text (for copying).</summary>
    public static string PlainText(IReadOnlyList<LegalSection> sections) =>
        string.Join("\n\n", sections.Select(s => s.Title + "\n" + s.Body));
}
