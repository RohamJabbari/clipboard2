import AppKit
import AuthenticationServices

// System autofill, the app's side (docs/features/auth-autofill.md → Phase 3): where the Keychain
// is, what the extension may offer, and the credential identities macOS suggests. Everything here
// does nothing in builds without CLIPBOARD2_AUTOFILL=1 (docs/features/autofill-setup.md).

/// Picks the Keychain once at launch, before any store reads it: in AutoFill builds, secrets,
/// password notes and authenticators move from the login Keychain to the shared one.
enum KeychainLocation {
    static let movedKey = "keychainMovedToShared"

    /// The services that move; secrets keep their creation date in their description.
    static var services: [KeychainMigration.Service] {
        [
            KeychainMigration.Service(KeychainServices.secrets) { SecretExtras.movedDescription($0, created: $1) },
            KeychainMigration.Service(KeychainServices.secretNotes),
            KeychainMigration.Service(KeychainServices.authenticators),
            KeychainMigration.Service(KeychainServices.sharedCodes),
        ]
    }

    /// Whether to use the shared Keychain after a move: yes once a move worked (now or before);
    /// after a failure, the old place until a move ever worked.
    static func useShared(after outcome: KeychainMigration.Outcome, movedBefore: Bool) -> Bool {
        switch outcome {
        case .moved, .nothingToMove: true
        case .failed: movedBefore
        }
    }

    static func prepare(defaults: UserDefaults = .standard) {
        #if AUTOFILL
        let outcome = KeychainMigration.run(services: services, from: SystemKeychain.login, to: SystemKeychain.shared)
        let movedBefore = defaults.bool(forKey: movedKey)
        if useShared(after: outcome, movedBefore: movedBefore) {
            AuthKeychain.current = SystemKeychain.shared
            if !movedBefore { defaults.set(true, forKey: movedKey) }
        } else {
            AuthKeychain.current = SystemKeychain.login
        }
        switch outcome {
        case .moved(let count): Log.app.notice("Moved \(count) Keychain items to the shared Keychain")
        case .failed(let reason): Log.app.error("Keychain move failed, trying again next launch: \(reason, privacy: .public)")
        case .nothingToMove: break
        }
        #endif
    }
}

/// What the AutoFill extension offers and the identities macOS suggests, kept in step with
/// passwords, authenticators and email codes.
enum AutoFillIdentities {
    private static var passwords: [AutoFillIndex.Password] = []
    private static var authenticatorCodes: [AutoFillIndex.Code] = []
    private static var emailCodes: [AutoFillEmailCode] = []
    private static var published: [AutoFillEntry]?
    private static var registration: Task<Void, Never>?
    private static var wasEnabled = false

    private static var vault: AutoFillVault { AutoFillVault(keychain: SystemKeychain.shared) }

    /// After every change to passwords or authenticators (local or from sync).
    static func update(secrets: [SecretRef], authenticators: [AuthenticatorItem]) {
        #if AUTOFILL
        passwords = passwordInputs(secrets)
        authenticatorCodes = codeInputs(authenticators)
        publish()
        #endif
    }

    /// Phase 4: the current email codes (all of them, each time they change). They become
    /// one-time-code identities for their sender's domain; the extension reads them from the
    /// shared Keychain. Does nothing in builds without AutoFill.
    static func update(codes: [AutoFillEmailCode]) {
        #if AUTOFILL
        emailCodes = codes
        vault.writeEmailCodes(codes)
        publish()
        #endif
    }

    /// The app's unlock window, so the extension fills without Touch ID while it's open.
    static func publishUnlockWindow(until: Date?) {
        #if AUTOFILL
        vault.writeUnlock(until: until)
        #endif
    }

    /// Registers everything again once the user turned Clipboard2 on as an AutoFill provider
    /// (macOS drops the identities of a provider that's off). Cheap; called every minute.
    static func checkEnabled() {
        #if AUTOFILL
        Task {
            let enabled = await isEnabled()
            if enabled, !wasEnabled { publish(force: true) }
            wasEnabled = enabled
        }
        #endif
    }

    // MARK: Inputs (pure)

    /// Passwords: secrets with a site or a username, each with its sites' domains.
    static func passwordInputs(_ secrets: [SecretRef]) -> [AutoFillIndex.Password] {
        secrets.filter(\.isPassword).map {
            AutoFillIndex.Password(id: $0.id, name: $0.name, username: $0.username,
                                   domains: AuthSource.domains(ofSites: $0.urls))
        }
    }

    /// Authenticators: the sites set with Edit → Website, else the issuer's domain.
    static func codeInputs(_ items: [AuthenticatorItem]) -> [AutoFillIndex.Code] {
        items.map { item in
            let sites = AuthSource.domains(ofSites: item.urls)
            let domains = sites.isEmpty ? (AuthSource.of(item)?.domain).map { [$0] } ?? [] : sites
            return switch item {
            case .owned(let a):
                AutoFillIndex.Code(kind: .authenticator, id: a.id, title: item.title, user: item.subtitle, domains: domains)
            case .shared(let s):
                AutoFillIndex.Code(kind: .sharedCode, id: s.spaceId, title: item.title, user: item.subtitle, domains: domains)
            }
        }
    }

    static func emailInputs(_ codes: [AutoFillEmailCode], now: Date) -> [AutoFillIndex.Code] {
        codes.filter { $0.isFresh(at: now) }.map {
            AutoFillIndex.Code(kind: .emailCode, id: $0.id, title: $0.domain, user: "", domains: [$0.domain])
        }
    }

    // MARK: Publishing

    private static func publish(force: Bool = false) {
        // Until the move to the shared Keychain worked, the extension couldn't read a thing.
        guard AuthKeychain.current === SystemKeychain.shared else { return }
        let entries = AutoFillIndex.build(passwords: passwords,
                                          codes: authenticatorCodes + emailInputs(emailCodes, now: .now))
        guard force || entries != published else { return }
        published = entries
        vault.writeIndex(entries)
        let identities = AutoFillIndex.identities(for: entries)
        let previous = registration
        registration = Task {
            await previous?.value
            await register(identities)
        }
    }

    private static func register(_ identities: [AutoFillIndex.Identity]) async {
        guard await isEnabled() else { return }
        let store = ASCredentialIdentityStore.shared
        var list: [any ASCredentialIdentity] = identities.filter { !$0.isCode }.map {
            ASPasswordCredentialIdentity(serviceIdentifier: ASCredentialServiceIdentifier(identifier: $0.domain, type: .domain),
                                         user: $0.user, recordIdentifier: $0.recordIdentifier)
        }
        if #available(macOS 15.0, *) {
            list += identities.filter(\.isCode).map {
                ASOneTimeCodeCredentialIdentity(serviceIdentifier: ASCredentialServiceIdentifier(identifier: $0.domain, type: .domain),
                                                label: $0.user, recordIdentifier: $0.recordIdentifier)
            }
        }
        do {
            try await store.replaceCredentialIdentities(list)
        } catch {
            Log.app.error("Registering AutoFill identities failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Settings

    /// Whether Clipboard2 is turned on in System Settings → General → AutoFill & Passwords.
    static func isEnabled() async -> Bool {
        await withCheckedContinuation { continuation in
            ASCredentialIdentityStore.shared.getState { @Sendable state in
                continuation.resume(returning: state.isEnabled)
            }
        }
    }

    /// System Settings → General → AutoFill & Passwords.
    static func openSettings() {
        Task {
            do {
                try await ASSettingsHelper.openCredentialProviderAppSettings()
            } catch {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Passwords-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
