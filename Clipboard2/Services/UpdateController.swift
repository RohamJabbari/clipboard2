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
/// - Notify: "Update available" in the menu and the panel footer; clicking it downloads, then
///   "Restart to Update" asks before relaunching.
/// - Check Now reports "Up to date", progress, or "Restart to Update" in place.
/// Besides Sparkle's hourly schedule, quiet probes (`checkForUpdateInformation`, no UI) run at
/// launch, hourly, and when the quick panel opens (at most every 2 minutes) so a new version shows
/// up quickly; they read the appcast pinned to its latest commit (see `PinnedFeed`).
/// Every update is still verified (EdDSA signature + Apple notarization) by Sparkle.
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate, SPUUserDriver {
    nonisolated enum Phase: Equatable, Sendable {
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
    @ObservationIgnored private var throttle = UpdateCheckThrottle()
    /// When the running probe started; one that never reported back stops counting after a minute.
    @ObservationIgnored private var probeStarted: Date?
    private var probing: Bool { probeStarted.map { Date.now.timeIntervalSince($0) < 60 } ?? false }
    @ObservationIgnored private var probeFound: (version: String, infoOnly: Bool)?
    @ObservationIgnored private var hourly: Timer?
    @ObservationIgnored private lazy var feed = FeedResolver(
        feedURL: (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:)))

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
        // At launch (once the app has settled), then hourly; each only sets the indicator.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.probe() }
        hourly = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe(ignoringThrottle: true) }
        }
    }

    /// The quick panel opened: look for a new version, at most once every 2 minutes.
    func panelDidOpen() {
        probe()
    }

    /// What the quick panel footer shows.
    var indicator: UpdateIndicator { UpdateIndicator(phase) }

    /// A silent look at the appcast: sets the indicator (and "Up to date" in Settings), never a window.
    private func probe(ignoringThrottle: Bool = false) {
        guard policy != .off, let updater, !updater.sessionInProgress, !probing else { return }
        switch phase {
        case .idle, .upToDate, .failed, .available: break
        case .checking, .downloading, .preparing, .ready, .installing: return
        }
        guard ignoringThrottle || throttle.isDue() else { return }
        throttle.record()
        probeStarted = .now
        Task {
            await feed.resolve()
            guard !updater.sessionInProgress else {
                probeStarted = nil
                return
            }
            probeFound = nil
            updater.checkForUpdateInformation()
        }
    }

    /// Runs a real (user-initiated) check against a freshly resolved feed.
    private func checkNow(_ updater: SPUUpdater) {
        throttle.record()
        Task {
            await feed.resolve()
            guard updater.canCheckForUpdates else {
                switch phase {
                case .checking, .downloading: phase = .idle
                default: break
                }
                return
            }
            updater.checkForUpdates()
        }
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
        guard updater.canCheckForUpdates, !probing else { return }
        userInitiated = true
        phase = .checking
        checkNow(updater)
    }

    /// Restart to Update / Update available: applies a downloaded update (relaunching), or downloads
    /// one that was only announced. After that download, "Install automatically" relaunches right
    /// away; "Tell me" shows "Restart to Update" and waits for the click.
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
            let downloaded = readyVersion != nil
            installWhenReady = downloaded || policy == .automatic
            phase = downloaded ? .installing : .downloading(fraction: nil)
            pendingChoice(.install)
            return
        }
        if availableVersion != nil, let updater, !updater.sessionInProgress, !probing {
            // Found by a quiet probe: run the real check, which downloads it.
            installWhenReady = policy == .automatic
            userInitiated = true
            phase = .downloading(fraction: nil)
            checkNow(updater)
        }
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        feed.feedURLString()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard probing else { return }
        offer(item)
        probeFound = (item.displayVersionString, item.isInformationOnlyUpdate)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        // Downloaded in the background (Automatic). It installs on quit anyway; offer it now too.
        offer(item)
        immediateInstall = immediateInstallHandler
        if installWhenReady {
            // "Update available" was clicked while it downloaded quietly.
            installWhenReady = false
            phase = .installing
            immediateInstallHandler()
            return true
        }
        phase = .ready(version: item.displayVersionString)
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastCheck = updater.lastUpdateCheckDate ?? lastCheck
        if updateCheck == .updateInformation {
            probeStarted = nil
            let found = probeFound
            probeFound = nil
            // "No update" also ends with an error (SUNoUpdateError); real failures stay silent.
            let noUpdate = (error as NSError?).map { $0.domain == SUSparkleErrorDomain && $0.code == Int(SUError.noUpdateError.rawValue) } ?? true
            guard found != nil || noUpdate else {
                Log.updates.notice("Update probe failed: \(error?.localizedDescription ?? "", privacy: .public)")
                return
            }
            lastCheck = .now
            phase = phase.afterProbe(found: found)
            if let found, !found.infoOnly, policy == .automatic {
                // Install automatically: fetch it quietly now, then "Restart to Update".
                DispatchQueue.main.async { [weak self] in
                    guard let self, !updater.sessionInProgress, case .available = self.phase else { return }
                    self.phase = .downloading(fraction: nil)
                    updater.checkForUpdatesInBackground()
                }
            }
            return
        }
        if let error { Log.updates.notice("Update cycle ended: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: SPUUserDriver — all quiet

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist turns automatic checks on, so Sparkle rarely asks; answer without a window.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // An "Update available" click already shows the download starting.
        if case .downloading = phase { return }
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
