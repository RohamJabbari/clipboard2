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

        let process = Process()
        process.executableURL = executable
        process.arguments = cli.loginArguments
        if let environment = cli.environment(for: executable) { process.environment = environment }
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

    private func handleLoginOutput(_ chunk: String) {
        loginOutput += chunk
        // Only complete lines can contain a whole URL.
        if signInURL == nil, let lastNewline = loginOutput.lastIndex(of: "\n"),
           let url = Self.firstURL(in: String(loginOutput[...lastNewline])) {
            signInURL = url
            // Run without a terminal, the CLI often can't open the browser itself; do it here.
            NSWorkspace.shared.open(url)
        }
        let lower = loginOutput.lowercased()
        if lower.contains("paste") && lower.contains("code") {
            needsCode = true
        }
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
