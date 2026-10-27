using Clipboard2.Core.Sync;

namespace Clipboard2.Core;

/// <summary>The one-line sync state shown in the tray menu and the quick panel's footer.</summary>
/// <param name="Text">"Synced · 2 min ago", "Syncing…", "Offline", an error, or "" when signed out.</param>
/// <param name="CanSyncNow">Whether "Sync Now" makes sense (signed in and not already syncing).</param>
public sealed record SyncStatusText(SyncStatus Status, string Text, bool CanSyncNow)
{
    public bool IsVisible => Status != SyncStatus.SignedOut;

    /// <summary>The only place the UI reads the account's status.</summary>
    public static SyncStatusText From(SyncAccount account, DateTime? now = null) =>
        Describe(account.CurrentStatus, account.LastSync, account.Error, now ?? DateTime.UtcNow);

    public static SyncStatusText Describe(SyncStatus status, DateTime? lastSync, string? error, DateTime now) => status switch
    {
        SyncStatus.SignedOut => new(status, "", false),
        SyncStatus.Syncing => new(status, "Syncing…", false),
        SyncStatus.Offline => new(status, lastSync is { } last ? $"Offline · synced {Ago(last, now)}" : "Offline", true),
        SyncStatus.Error => new(status, Shorten(string.IsNullOrWhiteSpace(error) ? "Sync problem" : error!), true),
        _ => new(status, lastSync is { } synced ? $"Synced · {Ago(synced, now)}" : "Not synced yet", true),
    };

    /// <summary>"just now", "2 min ago", "3 hr ago", "2 d ago".</summary>
    public static string Ago(DateTime then, DateTime now)
    {
        var span = now - then;
        if (span < TimeSpan.FromMinutes(1)) return "just now";
        if (span < TimeSpan.FromHours(1)) return $"{(int)span.TotalMinutes} min ago";
        if (span < TimeSpan.FromDays(1)) return $"{(int)span.TotalHours} hr ago";
        return $"{(int)span.TotalDays} d ago";
    }

    /// <summary>Errors can be long ("Couldn't reach the sync server. (…)"): the first sentence, at most 60 characters.</summary>
    public static string Shorten(string text)
    {
        var first = text.Split(". ", 2)[0].Trim().TrimEnd('.');
        return first.Length > 60 ? first[..59] + "…" : first;
    }
}
