import AppKit
import Observation
import Sparkle

/// How Clipboard2 handles new versions. One plain choice in Settings → General.
nonisolated enum UpdatePolicy: String, CaseIterable, Identifiable, Sendable {
    case automatic, notify, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Install automatically"
        case .notify: "Tell me, don't install"
        case .off: "Don't check"
        }
    }
    var summary: String {
        switch self {
        case .automatic: "New versions download quietly and install the next time Clipboard2 restarts."
        case .notify: "A note appears in the menu bar menu; nothing installs until you click it."
        case .off: "Clipboard2 never checks on its own. Use Check Now when you want."
        }
    }
}

/// In-place updates from GitHub (Sparkle) without update windows.
///
/// Sparkle's standard UI pops modal windows; for a menu bar utility that interrupts whatever you
/// were doing. This class is Sparkle's user driver instead, so every step is quiet state the menu
/// bar menu, the quick panel's footer and Settings show inline:
/// - Automatic (default): updates download in the background and install when the app quits;
///   "Restart to Update" applies one right away.
/// - Notify: "Update available" in the menu; clicking it downloads and relaunches.
/// - Check Now reports "Up to date", progress, or "Restart to Update" in place.
/// Every update is still verified (EdDSA signature + Apple notarization) by Sparkle.
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate, SPUUserDriver {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        /// Found, not downloaded (Notify policy). `infoOnly`: no download, link to the release.
        case available(version: String, infoOnly: Bool)
        case downloading(fraction: Double?)
        case preparing
        case ready(version: String)
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastCheck: Date?
    private(set) var policy: UpdatePolicy = .automatic
    /// Release notes for the version on offer (or the release list).
    private(set) var releaseNotesURL = URL(string: "https://github.com/RohamJabbari/clipboard2-macOS/releases")!

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var immediateInstall: (() -> Void)?
    @ObservationIgnored private var installWhenReady = false
    @ObservationIgnored private var expectedBytes: UInt64 = 0
    @ObservationIgnored private var receivedBytes: UInt64 = 0
    @ObservationIgnored private var userInitiated = false
    @ObservationIgnored private var offeredVersion: String?

    func start() {
        guard updater == nil else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
        } catch {
            Log.updates.error("Updater failed to start: \(error.localizedDescription, privacy: .public)")
        }
        self.updater = updater
        policy = Self.policy(checks: updater.automaticallyChecksForUpdates, downloads: updater.automaticallyDownloadsUpdates)
        lastCheck = updater.lastUpdateCheckDate
    }

    private static func policy(checks: Bool, downloads: Bool) -> UpdatePolicy {
        !checks ? .off : downloads ? .automatic : .notify
    }

    func setPolicy(_ policy: UpdatePolicy) {
        self.policy = policy
        updater?.automaticallyChecksForUpdates = policy != .off
        updater?.automaticallyDownloadsUpdates = policy == .automatic
    }

    /// The version waiting for a relaunch (for the menu bar and the quick panel footer).
    var readyVersion: String? {
        if case .ready(let version) = phase { return version }
        return nil
    }

    /// A version that's been found but not downloaded (Notify policy).
    var availableVersion: String? {
        if case .available(let version, _) = phase { return version }
        return nil
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .preparing, .installing: true
        default: false
        }
    }

    /// Check Now: results show up inline (no window).
    func checkForUpdates() {
        guard let updater else { return }
        if readyVersion != nil || availableVersion != nil { return }
        guard updater.canCheckForUpdates else { return }
        userInitiated = true
        updater.checkForUpdates()
    }

    /// Restart to Update / Install: applies a downloaded update (relaunching), or downloads one that
    /// was only announced and relaunches when it's ready.
    func installNow() {
        if case .available(_, true) = phase {
            NSWorkspace.shared.open(releaseNotesURL)
            return
        }
        if let immediateInstall {
            phase = .installing
            immediateInstall()
            return
        }
        if let pendingChoice {
            self.pendingChoice = nil
            installWhenReady = true
            phase = readyVersion != nil ? .installing : .downloading(fraction: nil)
            pendingChoice(.install)
        }
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        // Downloaded in the background (Automatic). It installs on quit anyway; offer it now too.
        offer(item)
        immediateInstall = immediateInstallHandler
        phase = .ready(version: item.displayVersionString)
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastCheck = updater.lastUpdateCheckDate ?? lastCheck
        if let error { Log.updates.notice("Update cycle ended: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: SPUUserDriver — all quiet

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist turns automatic checks on, so Sparkle rarely asks; answer without a window.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        phase = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        offer(appcastItem)
        let version = appcastItem.displayVersionString
        if appcastItem.isInformationOnlyUpdate {
            phase = .available(version: version, infoOnly: true)
            reply(.dismiss)
            return
        }
        switch state.stage {
        case .downloaded, .installing:
            // Already on disk: wait for the user's "Restart to Update" (it also installs on quit).
            pendingChoice = reply
            phase = .ready(version: version)
        case .notDownloaded:
            if state.userInitiated || policy == .automatic {
                // Check Now (or Automatic): fetch it, then offer the restart.
                phase = .downloading(fraction: nil)
                reply(.install)
            } else {
                pendingChoice = reply
                phase = .available(version: version, infoOnly: false)
            }
        @unknown default:
            reply(.dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        phase = .upToDate
        lastCheck = .now
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        Log.updates.error("Update failed: \(error.localizedDescription, privacy: .public)")
        // Background failures (offline, GitHub hiccup) stay silent; a Check Now gets an answer.
        phase = userInitiated ? .failed(error.localizedDescription) : .idle
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedBytes = 0
        receivedBytes = 0
        phase = .downloading(fraction: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        guard expectedBytes > 0 else { return }
        phase = .downloading(fraction: min(1, Double(receivedBytes) / Double(expectedBytes)))
    }

    func showDownloadDidStartExtractingUpdate() {
        phase = .preparing
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if installWhenReady {
            installWhenReady = false
            phase = .installing
            reply(.install)
        } else {
            pendingChoice = reply
            phase = .ready(version: offeredVersion ?? "")
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        phase = .idle
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        pendingChoice = nil
        installWhenReady = false
        userInitiated = false
        switch phase {
        case .checking, .downloading, .preparing, .installing, .available, .ready:
            // An update installed on quit keeps its "ready" state via `immediateInstall`.
            if immediateInstall == nil { phase = .idle }
        case .idle, .upToDate, .failed:
            break
        }
    }

    private func offer(_ item: SUAppcastItem) {
        offeredVersion = item.displayVersionString
        if let url = item.fullReleaseNotesURL ?? item.releaseNotesURL ?? item.infoURL {
            releaseNotesURL = url
        }
    }
}
