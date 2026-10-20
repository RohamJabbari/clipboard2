import AppKit
import Observation

/// The official CLIs Clipboard2 drives for "sign in with your account" providers. Each one handles
/// its own login with the vendor; Clipboard2 never sees or stores subscription tokens.
nonisolated enum SubscriptionCLI: Sendable {
    case claude   // Anthropic's Claude Code → Claude Pro/Max
    case codex    // OpenAI's Codex CLI → ChatGPT Plus/Pro/Team

    var serviceName: String { self == .claude ? "Claude" : "ChatGPT" }
    var toolName: String { self == .claude ? "Claude Code" : "Codex" }
    var planName: String { self == .claude ? "Claude Pro or Max" : "ChatGPT Plus, Pro or Team" }

    var executableURL: URL? {
        self == .claude ? ClaudeCodeCLIClient.executableURL : CodexCLIClient.executableURL
    }

    func environment(for executable: URL) -> [String: String]? {
        self == .codex ? CodexCLIClient.environment(for: executable) : nil
    }

    var statusArguments: [String] { self == .claude ? ["auth", "status"] : ["login", "status"] }
    var loginArguments: [String] { self == .claude ? ["auth", "login", "--claudeai"] : ["login"] }
    var logoutArguments: [String] { self == .claude ? ["auth", "logout"] : ["logout"] }

    /// Shell command that installs the CLI without admin rights.
    var installCommand: String {
        switch self {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "npm install -g @openai/codex || brew install --cask codex"
        }
    }

    func parseStatus(_ output: String) -> SubscriptionAccount.State? {
        switch self {
        case .claude:
            // `claude auth status` prints JSON; tolerate log lines around it.
            guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
                  let data = String(output[start...end]).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            guard json["loggedIn"] as? Bool == true else { return .signedOut }
            let account = ["email", "emailAddress", "account", "organizationName"]
                .lazy.compactMap { json[$0] as? String }.first
            return .signedIn(account: account)
        case .codex:
            let lower = output.lowercased()
            if lower.contains("not logged in") { return .signedOut }
            if lower.contains("logged in") {
                return .signedIn(account: lower.contains("chatgpt") ? "ChatGPT account" : "API key")
            }
            return nil
        }
    }
}

/// In-app sign-in for a subscription provider: install, sign in (browser), sign out.
@Observable
final class SubscriptionAccount {
    enum State: Equatable {
        case checking
        case notInstalled
        case installing
        case signedOut
        case signingIn
        case signedIn(account: String?)
        case failed(String)
    }

    let cli: SubscriptionCLI
    private(set) var state: State = .checking
    /// Sign-in page URL printed by the CLI, as a fallback if the browser didn't open by itself.
    private(set) var signInURL: URL?
    /// True when the CLI asks for a code to be pasted back (manual OAuth flow).
    private(set) var needsCode = false
    @ObservationIgnored private var loginProcess: Process?
    @ObservationIgnored private var loginInput: FileHandle?

    init(cli: SubscriptionCLI) {
        self.cli = cli
    }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    // MARK: Status

    func refresh() async {
        guard let executable = cli.executableURL else {
            state = .notInstalled
            return
        }
        if state != .signingIn && state != .installing { state = .checking }
        let result = await CLIRunner.run(executable, cli.statusArguments, environment: cli.environment(for: executable))
        state = cli.parseStatus(result.output) ?? .failed("Couldn't read the \(cli.serviceName) sign-in status.")
    }

    // MARK: Sign in / out

    func signIn() {
        guard let executable = cli.executableURL else {
            state = .notInstalled
            return
        }
        cancelSignIn()
        state = .signingIn
        signInURL = nil
        needsCode = false
        loginOutput = ""
        printedURL = nil

        let process = Process()
        process.executableURL = executable
        process.arguments = cli.loginArguments
        let shim = BrowserShim.prepare()
        var environment = cli.environment(for: executable) ?? ProcessInfo.processInfo.environment
        if let shim { BrowserShim.apply(shim, to: &environment) }
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.loginProcess = nil
                self?.loginInput = nil
                self?.needsCode = false
                await self?.refresh()
                if self?.isSignedIn == true { NSApp.activate() }
            }
        }
        do {
            try process.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        loginProcess = process
        loginInput = input.fileHandleForWriting
        if let shim { watchBrowserRequests(shim.urlFile, process: process) }

        // Read raw chunks, not lines: the CLI's "Paste code here >" prompt has no newline.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.handleLoginOutput(chunk) }
        }
    }

    @ObservationIgnored private var loginOutput = ""
    /// The link the CLI prints for "browser didn't open". For Claude it's the copy-a-code flow.
    @ObservationIgnored private var printedURL: URL?
    /// True once the CLI's own "open the browser" request reached us: that link finishes the
    /// login by itself (local callback), so there's no code to copy.
    private(set) var isAutomatic = false

    private func handleLoginOutput(_ chunk: String) {
        loginOutput += chunk
        // Only complete lines can contain a whole URL.
        if printedURL == nil, let lastNewline = loginOutput.lastIndex(of: "\n"),
           let url = Self.firstURL(in: String(loginOutput[...lastNewline])) {
            printedURL = url
            // Prefer the CLI's automatic link; it arrives within a moment if it's coming at all.
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard signInURL == nil, state == .signingIn else { return }
                signInURL = url
                openSignInPage()
                updateNeedsCode()
            }
        }
        updateNeedsCode()
    }

    private func updateNeedsCode() {
        let lower = loginOutput.lowercased()
        needsCode = !isAutomatic && signInURL != nil && lower.contains("paste") && lower.contains("code")
    }

    /// The CLI "opens the browser" through our shim, which writes the URL to a file; pick it up.
    private func watchBrowserRequests(_ file: URL, process: Process) {
        Task {
            while process.isRunning, state == .signingIn {
                if let text = try? String(contentsOf: file, encoding: .utf8),
                   let url = text.split(separator: "\n").compactMap({ URL(string: String($0)) }).first(where: { $0.scheme == "https" }),
                   url != signInURL {
                    signInURL = url
                    isAutomatic = true
                    updateNeedsCode()
                    openSignInPage()
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// Why the last attempt to open the browser failed, if it did.
    private(set) var openError: String?

    func openSignInPage() {
        guard let url = signInURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration) { [weak self] app, error in
            Task { @MainActor in
                if let error {
                    self?.openError = error.localizedDescription
                    Log.app.error("Opening the sign-in page failed: \(error.localizedDescription, privacy: .public)")
                    // Last resort: the same request through the `open` command.
                    try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: [url.absoluteString])
                } else {
                    self?.openError = nil
                    Log.app.notice("Opened the sign-in page in \(app?.bundleIdentifier ?? "unknown", privacy: .public)")
                }
            }
        }
    }

    func copySignInLink() {
        guard let url = signInURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        NSPasteboard.general.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardFilter.internalMarkerType))
    }

    nonisolated static func firstURL(in line: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        return detector.firstMatch(in: line, range: range)?.url.flatMap { $0.scheme == "https" ? $0 : nil }
    }

    func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let loginInput else { return }
        loginInput.write(Data((trimmed + "\n").utf8))
    }

    func cancelSignIn() {
        isAutomatic = false
        if loginProcess?.isRunning == true { loginProcess?.terminate() }
        loginProcess = nil
        loginInput = nil
    }

    func signOut() async {
        guard let executable = cli.executableURL else { return }
        _ = await CLIRunner.run(executable, cli.logoutArguments, environment: cli.environment(for: executable))
        await refresh()
    }

    // MARK: Install

    /// Runs the vendor's installer in a login shell (so nvm/Homebrew paths are available).
    func install() async {
        state = .installing
        let result = await CLIRunner.run(URL(fileURLWithPath: "/bin/zsh"), ["-ilc", cli.installCommand])
        if result.status != 0 || cli.executableURL == nil {
            let tail = result.output.split(separator: "\n").suffix(2).joined(separator: " ")
            state = .failed("Installation failed. \(tail)")
            return
        }
        await refresh()
    }
}

/// Stand-in `open` / `xdg-open` / `$BROWSER` for the login CLIs. Run from an app (no terminal),
/// Claude Code's own browser launch goes nowhere and it falls back to a copy-the-code flow; this
/// script hands its automatic sign-in link to Clipboard2, which opens it.
nonisolated enum BrowserShim {
    struct Prepared {
        var directory: URL
        var urlFile: URL
    }

    static let script = """
    #!/bin/sh
    # Clipboard2: passes sign-in links from the login tool to the app, which opens them.
    for arg in "$@"; do
      case "$arg" in https://*) printf '%s\\n' "$arg" >> "$CLIPBOARD2_BROWSER_FILE" ;; esac
    done
    exit 0
    """

    static func prepare() -> Prepared? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "clippy-cli/browser", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in ["open", "xdg-open"] {
                let file = dir.appending(path: name)
                try Data(script.utf8).write(to: file)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            let urlFile = dir.appending(path: "requested-url")
            try? fm.removeItem(at: urlFile)
            return Prepared(directory: dir, urlFile: urlFile)
        } catch {
            Log.app.error("Browser shim unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func apply(_ shim: Prepared, to environment: inout [String: String]) {
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = shim.directory.path + ":" + path
        environment["BROWSER"] = shim.directory.appending(path: "open").path
        environment["CLIPBOARD2_BROWSER_FILE"] = shim.urlFile.path
    }
}

/// Runs a command off the main thread and returns its exit status and combined output.
nonisolated enum CLIRunner {
    struct Result: Sendable {
        var status: Int32
        var output: String
    }

    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                    timeout: Duration = .seconds(300)) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment { process.environment = environment }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            let collector = OutputCollector()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                collector.append(handle.availableData)
            }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: Result(status: process.terminationStatus, output: collector.string))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: Result(status: -1, output: error.localizedDescription))
                return
            }
            let box = ProcessBox.wrap(process)
            Task {
                try? await Task.sleep(for: timeout)
                box.terminate()
            }
        }
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
