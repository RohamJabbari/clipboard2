// ============================================================================================================
// TEMPORARY UI STUBS. Delete this file when the sync agent's real members land on SyncAccount.
//
// The UI codes against these names. Contract names that differ here:
//   - The contract's `Status` (Idle/Syncing/Offline/Error/SignedOut) is `CurrentStatus`, because
//     SyncAccount already has `string? Status` (the busy/confirmation message shown in Settings → Sync).
//     The UI reads it in exactly one place: SyncStatusText.From (Clipboard2.Core/SyncStatusText.cs).
//   - `Devices` returns SyncDevice records; the stub returns none, so "Send to ‹device›" stays hidden.
//   - `SendToDeviceAsync` throws NotSupportedException.
// ============================================================================================================

namespace Clipboard2.Core.Sync;

/// <summary>TEMPORARY STUB. What the tray and the quick panel show about sync.</summary>
public enum SyncStatus { Idle, Syncing, Offline, Error, SignedOut }

/// <summary>TEMPORARY STUB. A signed-in device (a session from <c>GET /v1/sessions</c>).</summary>
public sealed record SyncDevice(string Id, string Name, bool IsCurrent, DateTime? LastUsedAt);

public sealed partial class SyncAccount
{
    /// <summary>TEMPORARY STUB for the contract's <c>Status</c>, derived from the existing state.</summary>
    public SyncStatus CurrentStatus =>
        Phase == SyncPhase.SignedOut ? SyncStatus.SignedOut
        : Phase == SyncPhase.NeedsSignIn ? SyncStatus.Error
        : IsSyncing ? SyncStatus.Syncing
        : Error is { } error ? (error.StartsWith("Couldn't reach", StringComparison.Ordinal) || error.Contains("didn't answer") ? SyncStatus.Offline : SyncStatus.Error)
        : SyncStatus.Idle;

    /// <summary>TEMPORARY STUB: the last copy, paste, panel or menu use (drives the polling cadence).</summary>
    public DateTime? LastActivity { get; private set; }

    /// <summary>TEMPORARY STUB: whether the quick panel is open (3-second polling).</summary>
    public bool IsPanelOpen { get; private set; }

    /// <summary>TEMPORARY STUB.</summary>
    public void ReportActivity() => LastActivity = _now();

    /// <summary>TEMPORARY STUB.</summary>
    public void SetPanelOpen(bool open)
    {
        IsPanelOpen = open;
        if (open) ReportActivity();
    }

    /// <summary>TEMPORARY STUB: no devices until the real list from /v1/sessions exists.</summary>
    public IReadOnlyList<SyncDevice> Devices => [];

    /// <summary>TEMPORARY STUB.</summary>
    public Task SendToDeviceAsync(ClipItem item, string deviceId) =>
        Task.FromException(new NotSupportedException("Sending to a device isn't available yet."));
}
