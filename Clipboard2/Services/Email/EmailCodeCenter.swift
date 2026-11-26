import AppKit
import Observation

// Email codes (docs/features/auth-autofill.md → Phase 4): the accounts, one reading loop each,
// and the codes found in the last 10 minutes. Codes live in memory and the Keychain only; they're
// never synced, sent anywhere, or put in history.

/// How an account's last look went, for Settings.
nonisolated struct EmailAccountStatus: Equatable, Sendable {
    var lastChecked: Date?
    var error: String?
}

@Observable
final class EmailCodeCenter {
    private(set) var accounts: [EmailAccount] = []
    private(set) var status: [String: EmailAccountStatus] = [:]
    /// Live codes, newest first.
    private(set) var codes: [EmailCode] = []
    /// Bumped whenever `codes` changes (the panel refreshes on it).
    private(set) var revision = 0

    @ObservationIgnored let clients: OAuthClients
    @ObservationIgnored private let vault: EmailVault
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var workers: [String: EmailAccountWorker] = [:]
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Messages already looked at (account + message id → when it arrived), so nothing is read twice.
    @ObservationIgnored private var seen: [String: Date] = [:]
    /// A new code arrived (for the notification).
    @ObservationIgnored var onNewCode: (EmailCode) -> Void = { _ in }

    static let notifyKey = "emailCodesNotify"
    static let showCodeKey = "emailCodesShowInNotification"

    init(vault: EmailVault, clients: OAuthClients = .bundled, defaults: UserDefaults = .standard) {
        self.vault = vault
        self.clients = clients
        self.defaults = defaults
        accounts = vault.decode([EmailAccount].self, EmailVaultKey.accounts) ?? []
        codes = (vault.decode([EmailCode].self, EmailVaultKey.codes) ?? []).filter { $0.isLive(at: .now) }
    }

    // MARK: Settings

    var notifies: Bool {
        get { access(keyPath: \.revision); return defaults.object(forKey: Self.notifyKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.notifyKey); revision &+= 1 }
    }

    var showsCodeInNotification: Bool {
        get { access(keyPath: \.revision); return defaults.bool(forKey: Self.showCodeKey) }
        set { defaults.set(newValue, forKey: Self.showCodeKey); revision &+= 1 }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        for account in accounts { startWorker(for: account) }
        scheduleExpiry()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetchNow() }
        }
    }

    /// The panel opened (or the Mac woke): every account looks now.
    func fetchNow() {
        for worker in workers.values { worker.kick() }
    }

    // MARK: Accounts

    /// Adds an account, or replaces the credential of the same address and provider.
    func add(_ account: EmailAccount, credential: EmailCredential) {
        var account = account
        account.address = account.address.trimmingCharacters(in: .whitespaces).lowercased()
        if let existing = accounts.first(where: { $0.provider == account.provider && $0.address == account.address }) {
            account.id = existing.id
            stopWorker(existing.id)
            accounts.removeAll { $0.id == existing.id }
        }
        vault.encode(credential, EmailVaultKey.credential(account.id))
        accounts.append(account)
        saveAccounts()
        status[account.id] = EmailAccountStatus()
        if started { startWorker(for: account) }
    }

    func remove(_ account: EmailAccount) {
        stopWorker(account.id)
        accounts.removeAll { $0.id == account.id }
        vault.set(nil, for: EmailVaultKey.credential(account.id))
        status[account.id] = nil
        saveAccounts()
        let before = codes.count
        codes.removeAll { $0.accountID == account.id }
        if codes.count != before { codesChanged() }
    }

    private func saveAccounts() { vault.encode(accounts, EmailVaultKey.accounts) }

    private func startWorker(for account: EmailAccount) {
        guard let source = makeSource(for: account) else {
            status[account.id] = EmailAccountStatus(error: OAuthError.needsSignIn.localizedDescription)
            return
        }
        let worker = EmailAccountWorker(account: account, source: source, center: self)
        workers[account.id] = worker
        worker.start()
    }

    private func stopWorker(_ id: String) {
        workers.removeValue(forKey: id)?.stop()
    }

    private func makeSource(for account: EmailAccount) -> MailSource? {
        guard let credential = vault.decode(EmailCredential.self, EmailVaultKey.credential(account.id)) else { return nil }
        switch (account.provider, credential) {
        case (.microsoft, .oauth(let tokens)), (.google, .oauth(let tokens)):
            guard !clients.clientID(for: account.provider).isEmpty else { return nil }
            let key = EmailVaultKey.credential(account.id)
            let keeper = TokenKeeper(tokens: tokens, provider: account.provider, clients: clients) { [weak self] fresh in
                self?.vault.encode(EmailCredential.oauth(fresh), key)
            }
            return account.provider == .microsoft ? GraphMailSource(keeper: keeper) : GmailSource(keeper: keeper)
        case (.imap, .password(let password)):
            guard let settings = account.imap else { return nil }
            return IMAPMailSource(settings: settings, user: account.address, password: password)
        default:
            return nil
        }
    }

    // MARK: Results

    func looked(_ account: EmailAccount, found messages: [MailMessage], now: Date = .now) {
        status[account.id] = EmailAccountStatus(lastChecked: now, error: nil)
        let since = now.addingTimeInterval(-EmailCode.lifetime)
        seen = seen.filter { $0.value > since.addingTimeInterval(-300) }
        for code in Self.codes(in: messages, account: account, since: since, seen: &seen)
        where !codes.contains(where: { $0.code == code.code && $0.source == code.source }) {
            codes.insert(code, at: 0)
            if notifies { onNewCode(code) }
            codesChanged()
        }
    }

    func failed(_ account: EmailAccount, _ error: Error, now: Date = .now) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        status[account.id] = EmailAccountStatus(lastChecked: status[account.id]?.lastChecked, error: message)
        Log.app.error("Email codes: \(account.provider.rawValue, privacy: .public) look failed: \(message, privacy: .public)")
    }

    /// The codes in a batch of messages: recent, not looked at before, with a code in them. Pure.
    static func codes(in messages: [MailMessage], account: EmailAccount, since: Date,
                      seen: inout [String: Date]) -> [EmailCode] {
        var found: [EmailCode] = []
        for message in messages.sorted(by: { $0.receivedAt < $1.receivedAt }) where message.receivedAt >= since {
            let key = account.id + " " + message.id
            guard seen[key] == nil else { continue }
            seen[key] = message.receivedAt
            guard let code = EmailCodeExtractor.code(subject: message.subject, body: message.text) else { continue }
            let source = EmailCodeSender.source(ofFrom: message.from) ?? MIME.address(inFrom: message.from).flatMap(MIME.domain) ?? "email"
            found.append(EmailCode(code: code, source: source, accountID: account.id, receivedAt: message.receivedAt))
        }
        return found
    }

    /// Codes that are live at `now`, newest first (expired ones dropped).
    static func live(_ codes: [EmailCode], at now: Date) -> [EmailCode] {
        codes.filter { $0.isLive(at: now) }.sorted { $0.receivedAt > $1.receivedAt }
    }

    func code(id: String) -> EmailCode? { codes.first { $0.id == id } }

    /// The code's account address, for the preview.
    func address(of code: EmailCode) -> String? { accounts.first { $0.id == code.accountID }?.address }

    // MARK: Expiry

    func pruneExpired(now: Date = .now) {
        let fresh = Self.live(codes, at: now)
        if fresh != codes {
            codes = fresh
            codesChanged()
        }
    }

    private func codesChanged() {
        revision &+= 1
        vault.encode(codes.isEmpty ? nil : codes, EmailVaultKey.codes)
        scheduleExpiry()
        // TODO(autofill, phase 3): hand the codes to the AutoFill extension once AutoFillIdentities
        // lands on main:
        // AutoFillIdentities.update(codes: codes.map {
        //     AutoFillEmailCode(id: $0.id, code: $0.code, domain: $0.source, receivedAt: $0.receivedAt) })
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard let next = codes.map(\.expiresAt).min() else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow + 0.5)))
            guard !Task.isCancelled else { return }
            self?.pruneExpired()
        }
    }
}

/// One account's reading loop: look, wait (IDLE, a kick or the interval), look again. Errors back
/// off (15 s, 30 s, 1 min… up to 15 min); a lost sign-in waits for the account to be added again.
final class EmailAccountWorker {
    let account: EmailAccount
    private let source: MailSource
    private let waker = Waker()
    private weak var center: EmailCodeCenter?
    private var task: Task<Void, Never>?

    init(account: EmailAccount, source: MailSource, center: EmailCodeCenter) {
        self.account = account
        self.source = source
        self.center = center
    }

    func start() {
        task = Task { [weak self] in await self?.run() }
    }

    func kick() { waker.kick() }

    func stop() {
        task?.cancel()
        waker.kick()
        source.close()
    }

    static func backoff(failures: Int, base: Duration) -> Duration {
        let seconds = Double(base.components.seconds) * pow(2, Double(min(failures, 8)))
        return .seconds(min(seconds, 15 * 60))
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                let since = Date.now.addingTimeInterval(-EmailCode.lifetime)
                let messages = try await source.recentMessages(since: since)
                guard !Task.isCancelled else { break }
                center?.looked(account, found: messages)
                failures = 0
                try await source.waitForMail(waker)
            } catch {
                guard !Task.isCancelled else { break }
                failures += 1
                center?.failed(account, error)
                if case OAuthError.needsSignIn = error {
                    await waker.wait(.seconds(6 * 3600))
                } else {
                    await waker.wait(Self.backoff(failures: failures, base: source.interval))
                }
            }
        }
    }
}
