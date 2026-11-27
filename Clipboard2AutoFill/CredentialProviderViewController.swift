import AppKit
import AuthenticationServices
import LocalAuthentication
import SwiftUI

// Clipboard2's AutoFill credential provider (docs/features/auth-autofill.md → Phase 3): passwords,
// and on macOS 15+ one-time codes, from the shared Keychain the app writes. Every fill asks for
// Touch ID unless the app's unlock window is open.

final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let vault = AutoFillVault(keychain: SystemKeychain.shared)
    private let model = CredentialListModel()

    override func loadView() {
        model.onPick = { [weak self] entry in self?.pick(entry) }
        model.onCancel = { [weak self] in self?.cancel(.userCanceled) }
        let hosting = NSHostingView(rootView: CredentialListView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 440, height: 380)
        view = hosting
        preferredContentSize = hosting.frame.size
    }

    // MARK: Lists

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        model.show(entries: vault.index().filter { !$0.isCode }, kind: .passwords,
                   serviceIdentifiers: serviceIdentifiers.map(\.identifier))
    }

    @available(macOS 15.0, *)
    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        model.show(entries: vault.index().filter(\.isCode), kind: .codes,
                   serviceIdentifiers: serviceIdentifiers.map(\.identifier))
    }

    // MARK: A suggestion the user picked in Safari or an app

    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        guard let entry = entry(for: credentialRequest) else { return cancel(.credentialIdentityNotFound) }
        guard isUnlocked else { return cancel(.userInteractionRequired) }
        complete(with: entry)
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        guard let entry = entry(for: credentialRequest) else { return cancel(.credentialIdentityNotFound) }
        model.unlocking = entry.title
        pick(entry)
    }

    override func prepareInterfaceForExtensionConfiguration() {
        extensionContext.completeExtensionConfigurationRequest()
    }

    // MARK: Filling

    private func entry(for request: any ASCredentialRequest) -> AutoFillEntry? {
        AutoFillEntry(recordIdentifier: request.credentialIdentity.recordIdentifier, in: vault.index())
    }

    /// The app's unlock window is open, and the app is still running (quitting ends it).
    private var isUnlocked: Bool {
        guard AutoFillUnlock.isOpen(until: vault.unlockedUntil(), now: .now) else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: AutoFillConfig.appBundleID).isEmpty
    }

    private func pick(_ entry: AutoFillEntry) {
        if isUnlocked { return complete(with: entry) }
        Task {
            let context = LAContext()
            let reason = entry.isCode ? "fill the code for \(entry.title)" : "fill your password for \(entry.title)"
            do {
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                complete(with: entry)
            } catch {
                model.unlocking = nil
                // Back to the list if there is one; a single suggestion just ends.
                if model.entries.isEmpty { cancel(.userCanceled) }
            }
        }
    }

    private func complete(with entry: AutoFillEntry) {
        if entry.kind == .password {
            guard let password = vault.password(for: entry) else { return cancel(.credentialIdentityNotFound) }
            extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: entry.user, password: password),
                                             completionHandler: nil)
            return
        }
        guard #available(macOS 15.0, *), let code = vault.code(for: entry, at: .now) else {
            return cancel(.credentialIdentityNotFound)
        }
        extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code), completionHandler: nil)
    }

    private func cancel(_ code: ASExtensionError.Code) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
    }
}
