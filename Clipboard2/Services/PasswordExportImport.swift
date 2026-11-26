import AppKit
import Observation

// Guided import (docs/features/auth-autofill.md → Guided import): Settings → Auth → Import says how
// to export from each password manager, opens it, then watches ~/Downloads and the Desktop for the
// export for ten minutes. The file found (or dropped, or chosen) goes to the review list; after
// Import or Cancel it's moved to the Trash, with Undo.

// MARK: - Sources

nonisolated enum PasswordExportSource: String, CaseIterable, Identifiable, Sendable {
    case apple, chromium, firefox, onePassword, bitwarden, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple Passwords / Safari"
        case .chromium: "Chrome"
        case .firefox: "Firefox"
        case .onePassword: "1Password"
        case .bitwarden: "Bitwarden"
        case .other: "Other CSV"
        }
    }

    /// The export steps, one or two lines.
    var steps: String {
        switch self {
        case .apple:
            if #available(macOS 15, *) { "In the Passwords app: File → Export All Passwords…, then save it." }
            else { "In Safari: File → Export → Passwords…, then save it." }
        case .chromium:
            "In Chrome's Password Manager (chrome://password-manager/settings): Export passwords → Export. Arc, Brave and Edge work the same."
        case .firefox:
            "In Firefox, open about:logins, click ⋯ (top right) → Export Logins…, then save it."
        case .onePassword:
            "In 1Password: File → Export → your account, choose CSV, then save it."
        case .bitwarden:
            "In Bitwarden: File → Export vault (Tools → Export vault on the web), choose .csv, then save it."
        case .other:
            "Any CSV with url, username and password columns."
        }
    }

    /// Whether a file's name looks like this source's export ("Passwords.csv", "Chrome Passwords.csv",
    /// "logins.csv", "1PasswordExport-….csv", "bitwarden_export_….csv"). Other CSV takes any CSV.
    func matches(fileName: String) -> Bool {
        let name = fileName.lowercased()
        guard name.hasSuffix(".csv") else { return false }
        switch self {
        case .apple: return name.hasPrefix("passwords")
        case .chromium: return name.contains("passwords")
        case .firefox: return name.hasPrefix("logins")
        case .onePassword: return name.contains("1password")
        case .bitwarden: return name.hasPrefix("bitwarden")
        case .other: return true
        }
    }
}

/// A browser or app to open for an export, with the page to open in it.
nonisolated struct ExportOpener: Identifiable, Equatable, Sendable {
    var name: String
    var bundleIDs: [String]
    /// Opened in that app; nil: just launch it.
    var url: String?
    /// When the app isn't installed (Bitwarden's web vault).
    var fallbackURL: String?
    var id: String { name }

    static func openers(for source: PasswordExportSource) -> [ExportOpener] {
        switch source {
        case .apple:
            [ExportOpener(name: "Passwords", bundleIDs: ["com.apple.Passwords"]),
             ExportOpener(name: "Safari", bundleIDs: ["com.apple.Safari"])]
        case .chromium:
            [ExportOpener(name: "Chrome", bundleIDs: ["com.google.Chrome"], url: "chrome://password-manager/settings"),
             ExportOpener(name: "Arc", bundleIDs: ["company.thebrowser.Browser"], url: "chrome://password-manager/settings"),
             ExportOpener(name: "Brave", bundleIDs: ["com.brave.Browser"], url: "brave://password-manager/settings"),
             ExportOpener(name: "Edge", bundleIDs: ["com.microsoft.edgemac"], url: "edge://password-manager/settings")]
        case .firefox:
            [ExportOpener(name: "Firefox", bundleIDs: ["org.mozilla.firefox"], url: "about:logins")]
        case .onePassword:
            [ExportOpener(name: "1Password", bundleIDs: ["com.1password.1password", "com.agilebits.onepassword7"])]
        case .bitwarden:
            [ExportOpener(name: "Bitwarden", bundleIDs: ["com.bitwarden.desktop"],
                          fallbackURL: "https://vault.bitwarden.com/#/tools/export")]
        case .other:
            []
        }
    }
}

// MARK: - Finding the export

/// A file in a watched folder.
nonisolated struct ExportFileCandidate: Equatable, Sendable {
    var url: URL
    var created: Date
    var size: Int
}

nonisolated enum ExportFileMatcher {
    /// Files from just before watching started still count (the export may have been saved first).
    static let grace: TimeInterval = 5

    /// The newest non-empty file that looks like the source's export and appeared after `since`.
    static func pick(_ candidates: [ExportFileCandidate], source: PasswordExportSource, since: Date) -> URL? {
        candidates
            .filter { $0.size > 0 && $0.created >= since.addingTimeInterval(-grace) && source.matches(fileName: $0.url.lastPathComponent) }
            .max { $0.created < $1.created }?
            .url
    }

    static func candidates(in directory: URL) -> [ExportFileCandidate] {
        let keys: [URLResourceKey] = [.creationDateKey, .addedToDirectoryDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "csv", let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            let created = values.creationDate ?? values.addedToDirectoryDate ?? .distantPast
            return ExportFileCandidate(url: url, created: created, size: values.fileSize ?? 0)
        }
    }
}

/// Calls back (on the main queue) whenever something in one of the folders changes.
final class FolderChangeWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []

    init(folders: [URL], onChange: @escaping @MainActor () -> Void) {
        for folder in folders {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .link],
                                                                   queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { onChange() } }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    func cancel() {
        sources.forEach { $0.cancel() }
        sources = []
    }
}

// MARK: - The Trash

/// Moves files to the Trash and back (FileManager in the app, a fake in tests).
protocol FileTrashing {
    /// The file's place in the Trash.
    func trash(_ url: URL) throws -> URL
    func restore(_ trashed: URL, to original: URL) throws
}

struct SystemTrash: FileTrashing {
    func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    func restore(_ trashed: URL, to original: URL) throws {
        try FileManager.default.moveItem(at: trashed, to: original)
    }
}

// MARK: - The flow

/// Settings → Auth → Import, start to end. Lives in AppEnvironment so watching goes on while the
/// Settings tab changes.
@Observable
final class PasswordImportCenter {
    static let watchDuration: TimeInterval = 600

    /// The source picked (its steps and Open buttons show).
    private(set) var source: PasswordExportSource?
    /// Watching until then.
    private(set) var watchingUntil: Date?
    /// The export being reviewed.
    private(set) var review: PasswordImportReview?
    /// The last result ("Imported 42 passwords", or why the file couldn't be read).
    private(set) var result: String?
    /// The export moved to the Trash, until Undo or the next import.
    private(set) var trashed: (original: URL, inTrash: URL)?

    @ObservationIgnored private let sink: any PasswordImportSink
    @ObservationIgnored private let authenticators: AuthenticatorStore?
    @ObservationIgnored private let trash: any FileTrashing
    @ObservationIgnored let folders: [URL]
    @ObservationIgnored private var watcher: FolderChangeWatcher?
    @ObservationIgnored private var watchStart = Date.distantPast
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    /// The file behind the review.
    @ObservationIgnored private(set) var reviewedFile: URL?
    /// Files already offered while watching (not picked up twice).
    @ObservationIgnored private var seen: Set<URL> = []

    init(sink: any PasswordImportSink, authenticators: AuthenticatorStore?, trash: any FileTrashing = SystemTrash(),
         folders: [URL] = PasswordImportCenter.defaultFolders) {
        self.sink = sink
        self.authenticators = authenticators
        self.trash = trash
        self.folders = folders
    }

    nonisolated static var defaultFolders: [URL] {
        [FileManager.SearchPathDirectory.downloadsDirectory, .desktopDirectory].compactMap {
            FileManager.default.urls(for: $0, in: .userDomainMask).first
        }
    }

    var isWatching: Bool { watchingUntil != nil }

    // MARK: Watching

    /// Picks a source and watches the folders for its export for ten minutes.
    func choose(_ source: PasswordExportSource, now: Date = .now) {
        self.source = source
        startWatching(now: now)
    }

    func startWatching(now: Date = .now) {
        stopWatching()
        guard review == nil else { return }
        watchStart = now
        watchingUntil = now.addingTimeInterval(Self.watchDuration)
        seen = []
        watcher = FolderChangeWatcher(folders: folders) { [weak self] in self?.scheduleCheck() }
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.watchDuration))
            guard !Task.isCancelled else { return }
            self?.stopWatching()
        }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
        stopTask?.cancel()
        checkTask?.cancel()
        watchingUntil = nil
    }

    /// A folder changed: look once things settle (a download being written grows for a moment).
    private func scheduleCheck() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.checkFolders()
        }
    }

    /// Looks for the export now (the folder watcher calls this; tests call it directly).
    func checkFolders() {
        guard isWatching, let source else { return }
        let candidates = folders.flatMap(ExportFileMatcher.candidates(in:)).filter { !seen.contains($0.url) }
        guard let url = ExportFileMatcher.pick(candidates, source: source, since: watchStart) else { return }
        seen.insert(url)
        load(url)
    }

    // MARK: Reviewing

    /// Reads a file (found, dropped or chosen) into the review list. The text isn't kept.
    func load(_ url: URL) {
        guard review == nil else { return }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            result = "Couldn't read “\(url.lastPathComponent)”."
            return
        }
        switch PasswordImportReview.make(text: text, fileName: url.lastPathComponent, sink: sink, authenticators: authenticators) {
        case .success(let review):
            stopWatching()
            self.review = review
            reviewedFile = url
            result = nil
            trashed = nil
        case .failure(let problem):
            result = "“\(url.lastPathComponent)”: \(problem.message)"
        }
    }

    /// Imports the checked entries, then moves the export to the Trash.
    func importChecked() {
        guard let review else { return }
        let summary = review.importChecked(into: sink, authenticators: authenticators)
        finishReview(result: summary.line)
    }

    /// Imports nothing; the export still goes to the Trash.
    func cancel() {
        review?.close()
        finishReview(result: "Nothing imported")
    }

    private func finishReview(result: String) {
        review?.close()
        review = nil
        self.result = result
        defer { reviewedFile = nil }
        guard let file = reviewedFile else { return }
        do {
            trashed = (file, try trash.trash(file))
        } catch {
            trashed = nil
            self.result = result + ". Couldn't move “\(file.lastPathComponent)” to the Trash: delete it yourself, it isn't encrypted."
        }
    }

    /// Undo: the export goes back where it was.
    func undoTrash() {
        guard let trashed else { return }
        do {
            try trash.restore(trashed.inTrash, to: trashed.original)
        } catch {
            result = "Couldn't put “\(trashed.original.lastPathComponent)” back. It's in the Trash."
        }
        self.trashed = nil
    }

    /// "Moved “Passwords.csv” to the Trash."
    var trashLine: String? {
        trashed.map { "Moved “\($0.original.lastPathComponent)” to the Trash." }
    }

    /// Leaves the import (the source's steps go away).
    func reset() {
        stopWatching()
        if review != nil { cancel() }
        source = nil
    }
}

// MARK: - Opening the app

extension ExportOpener {
    var appURL: URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    var isAvailable: Bool { appURL != nil || fallbackURL != nil }

    /// Opens the app (on its export page when it has one), else the fallback page.
    func open() {
        guard let appURL else {
            if let fallbackURL, let url = URL(string: fallbackURL) { NSWorkspace.shared.open(url) }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let url = url.flatMap(URL.init(string:)) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }
    }
}
