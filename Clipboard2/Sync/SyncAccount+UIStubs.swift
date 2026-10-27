// TEMPORARY — DELETE THIS FILE when the sync work lands.
//
// Minimal stand-ins for the SyncAccount API the sync agent is adding (status, activity
// reporting, devices, send to device), so the UI built against it compiles and runs today.
// UI code only uses the member names and enum case names below, never the type names, so the
// real implementation can replace this file without changes elsewhere.

import Foundation

/// TEMPORARY stub. The real type comes with the sync work.
nonisolated enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case offline
    case error(String)
    case signedOut
}

/// TEMPORARY stub: one signed-in device (a session from `GET /v1/sessions`).
nonisolated struct SyncDevice: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var isCurrent: Bool
    var lastUsedAt: Date?
}

extension SyncAccount {
    /// TEMPORARY stub, derived from what SyncAccount already tracks.
    var status: SyncStatus {
        guard isSignedIn else { return .signedOut }
        if isSyncing { return .syncing }
        if let lastSyncError { return .error(lastSyncError) }
        return .idle
    }

    /// TEMPORARY stub: the real one feeds the polling cadence (copy, paste, panel, menu).
    func reportActivity() {}

    /// TEMPORARY stub: the real one polls every 3 s while the panel is open.
    func setPanelOpen(_ open: Bool) {}

    /// TEMPORARY stub: no devices until the real session list exists, so "Send to" stays hidden.
    var devices: [SyncDevice] { [] }

    /// TEMPORARY stub: the real one pushes the item with `toDevice` set.
    func sendToDevice(_ item: ClipItem, deviceId: String) {}
}
