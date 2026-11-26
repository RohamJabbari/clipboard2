import SwiftUI

/// Settings → Auth → Email accounts (docs/features/auth-autofill.md, phase 4): add Microsoft,
/// Google or IMAP accounts, see how each last look went, remove them. No dialogs: the IMAP form
/// opens in place; OAuth uses the system sign-in sheet.
struct EmailAccountsSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var signingIn: EmailProvider?
    @State private var addError: String?
    @State private var imapForm: IMAPFormState?
    @State private var signIn: OAuthSignIn?

    var body: some View {
        let center = env.emailCodes
        Section {
            if center.accounts.isEmpty && imapForm == nil {
                Text("Sign-in codes sent to your email show at the top of Auth for 10 minutes.")
                    .foregroundStyle(.secondary)
            }
            ForEach(center.accounts) { account in
                AccountRow(account: account, status: center.status[account.id]) { center.remove(account) }
            }
            if let form = Binding($imapForm) {
                IMAPAccountForm(form: form, onCancel: { imapForm = nil }, onAdded: { imapForm = nil })
            } else {
                HStack {
                    ForEach(center.clients.availableProviders) { provider in
                        Button("Add \(provider.title)…") { add(provider) }
                            .disabled(signingIn != nil)
                    }
                    if let signingIn {
                        ProgressView().controlSize(.small)
                        Text("Signing in to \(signingIn.title)…").foregroundStyle(.secondary)
                    }
                }
            }
            if let addError {
                Text(addError).font(.callout).foregroundStyle(.orange)
            }
            Toggle("Notify when a code arrives", isOn: Binding(get: { center.notifies }, set: { center.notifies = $0 }))
            Toggle("Show codes in notifications", isOn: Binding(get: { center.showsCodeInNotification },
                                                               set: { center.showsCodeInNotification = $0 }))
                .disabled(!center.notifies)
        } header: {
            Text("Email accounts")
        } footer: {
            Text("Clipboard2 reads only mail from the last 10 minutes, on this Mac. It keeps the code, the sender's site and the time for 10 minutes, never the message. Nothing is synced or sent anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func add(_ provider: EmailProvider) {
        addError = nil
        guard provider != .imap else {
            imapForm = IMAPFormState()
            return
        }
        signingIn = provider
        let session = OAuthSignIn()
        signIn = session
        Task {
            defer {
                signingIn = nil
                signIn = nil
            }
            do {
                let result = try await session.run(provider, clients: env.emailCodes.clients)
                let account = EmailAccount(provider: provider, address: result.email ?? provider.title + " account")
                env.emailCodes.add(account, credential: .oauth(result.tokens))
            } catch OAuthError.cancelled {
                // The user closed the sheet.
            } catch {
                addError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

private struct AccountRow: View {
    let account: EmailAccount
    let status: EmailAccountStatus?
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: account.provider.symbol).foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.address).lineLimit(1).truncationMode(.middle)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    statusLine(now: context.date)
                }
            }
            Spacer()
            Button("Remove", action: onRemove)
                .accessibilityLabel("Remove \(account.address)")
        }
    }

    @ViewBuilder
    private func statusLine(now: Date) -> some View {
        let via = account.provider == .imap ? (account.imap?.host ?? "IMAP") : account.provider.title
        if let error = status?.error {
            Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
        } else if let checked = status?.lastChecked {
            let seconds = Int(now.timeIntervalSince(checked))
            Text("\(via) · checked \(seconds < 60 ? "just now" : "\(seconds / 60) min ago")")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("\(via) · connecting…").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct IMAPFormState: Equatable {
    var email = ""
    var password = ""
    var host = ""
    var port = "993"
    var useTLS = true
    /// The server fields were edited by hand: the email no longer overwrites them.
    var customServer = false
    var checking = false
    var error: String?
}

private struct IMAPAccountForm: View {
    @Binding var form: IMAPFormState
    let onCancel: () -> Void
    let onAdded: () -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var showsAdvanced = false

    private var guess: IMAPGuess { IMAPPresets.guess(for: form.email) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Email", text: $form.email, prompt: Text("you@example.com"))
                .textContentType(.username)
                .onChange(of: form.email) { applyGuess() }
            SecureField("App password", text: $form.password)
            helpLine
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("IMAP server", text: Binding(get: { form.host }, set: { form.host = $0; form.customServer = true }))
                    TextField("Port", text: Binding(get: { form.port }, set: { form.port = $0; form.customServer = true }))
                    Toggle("Use TLS", isOn: Binding(get: { form.useTLS }, set: { form.useTLS = $0; form.customServer = true }))
                }
                .padding(.top, 4)
            }
            if let error = form.error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                if form.checking { ProgressView().controlSize(.small) }
                Button("Cancel", action: onCancel)
                Button("Add Account") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
    }

    @ViewBuilder
    private var helpLine: some View {
        switch guess {
        case .preset(let preset):
            HStack(spacing: 4) {
                Text(preset.help).font(.caption).foregroundStyle(.secondary)
                if let url = preset.helpURL { Link("How", destination: url).font(.caption) }
            }
        case .useMicrosoft:
            Text("Outlook.com and Hotmail need Microsoft sign-in: use Add Microsoft… instead.")
                .font(.caption).foregroundStyle(.orange)
        case .guessed:
            Text("Use an app password if your provider offers one. Check the server under Advanced.")
                .font(.caption).foregroundStyle(.secondary)
        case .invalid:
            EmptyView()
        }
    }

    private var canAdd: Bool {
        guard !form.checking, !form.password.isEmpty, !form.host.trimmingCharacters(in: .whitespaces).isEmpty,
              UInt16(form.port) != nil else { return false }
        switch guess {
        case .preset, .guessed: return true
        case .useMicrosoft, .invalid: return false
        }
    }

    private func applyGuess() {
        guard !form.customServer else { return }
        switch guess {
        case .preset(let preset):
            form.host = preset.host
            form.port = String(preset.port)
            form.useTLS = true
        case .guessed(let settings):
            form.host = settings.host
            form.port = String(settings.port)
            form.useTLS = settings.useTLS
        case .useMicrosoft, .invalid:
            form.host = ""
        }
    }

    /// Signs in once before saving, so a wrong password shows here, not later.
    private func add() {
        let settings = IMAPSettings(host: form.host.trimmingCharacters(in: .whitespaces), port: UInt16(form.port) ?? 993,
                                    useTLS: form.useTLS)
        let email = form.email.trimmingCharacters(in: .whitespaces)
        let password = form.password
        form.checking = true
        form.error = nil
        Task {
            let client = IMAPClient(host: settings.host, port: settings.port, useTLS: settings.useTLS)
            do {
                try await client.connect()
                try await client.login(user: email, password: password)
                _ = try await client.selectInbox()
                await client.logout()
                env.emailCodes.add(EmailAccount(provider: .imap, address: email, imap: settings), credential: .password(password))
                form.checking = false
                onAdded()
            } catch {
                await client.logout()
                form.checking = false
                form.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
