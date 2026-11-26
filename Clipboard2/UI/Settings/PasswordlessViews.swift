import SwiftUI

// Passwordless accounts in Settings → Sync (docs/features/passwordless.md). Everything is inline:
// no sheets, alerts or confirmation dialogs.

// MARK: - Session window picker

/// The window choice, with the risk text and typed acknowledgement inline for Indefinitely.
struct SessionWindowPicker: View {
    @Binding var window: SessionWindow
    @Binding var acknowledgement: String
    var label = "Stay signed in"
    @State private var customDays = 3.0
    @State private var isCustom = false

    private enum Choice: Hashable { case preset(SessionWindow), custom }

    var body: some View {
        Picker(label, selection: Binding<Choice>(
            get: { isCustom ? .custom : .preset(window) },
            set: { choice in
                switch choice {
                case .preset(let preset):
                    isCustom = false
                    window = preset
                case .custom:
                    isCustom = true
                    window = .custom(customDays * 86_400)
                }
            })) {
            ForEach(SessionWindow.presets, id: \.self) { Text($0.title).tag(Choice.preset($0)) }
            Text("Custom…").tag(Choice.custom)
        }
        if isCustom {
            Stepper(value: Binding(get: { customDays }, set: {
                customDays = $0
                window = .custom($0 * 86_400)
            }), in: 1...365, step: 1) {
                Text("For \(SessionWindow.describe(customDays * 86_400))")
            }
        }
        if window == .indefinitely {
            IndefiniteRiskText()
            TextField("Type the sentence above to continue", text: $acknowledgement,
                      prompt: Text(SessionWindow.acknowledgement))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            if !acknowledgement.isEmpty && !SessionWindow.isAcknowledged(acknowledgement) {
                Text("Type it exactly as shown.").font(.caption).foregroundStyle(.orange)
            }
        } else {
            Text("After that, this Mac signs out by itself and removes everything it synced.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// What "Indefinitely" means, said plainly.
struct IndefiniteRiskText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Staying signed in indefinitely", systemImage: "exclamationmark.shield.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("• If this Mac is lost or stolen, it keeps full access to your synced data until you sign it out from another device (Settings → Sync → Devices → Sign Out).")
                Text("• Anyone who can use this Mac while it's unlocked can read your synced items and secrets, approve new devices, and delete your account.")
                Text("• What this Mac has already decrypted stays on it. Signing it out later stops new data, but can't take back what a thief already copied.")
                Text("• Choose a window instead on Macs you don't fully control. Your other devices can shorten this one's window at any time.")
            }
            .font(.caption)
            Text("To continue, type: **\(SessionWindow.acknowledgement)**")
                .font(.caption)
                .textSelection(.disabled)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Continue with Google

/// Runs Continue with Google; on success the caller gets the ID token, and Gmail read-only was
/// added to email codes when the user granted it.
@MainActor
final class GoogleSignInRunner {
    private var session: OAuthSignIn?

    struct Outcome {
        var idToken: String
        var email: String?
        var gmail: OAuthSignIn.Result?
    }

    func run(clients: OAuthClients, offerGmail: Bool) async throws -> Outcome {
        let session = OAuthSignIn()
        self.session = session
        defer { self.session = nil }
        let result = try await session.run(.google, clients: clients, endpoints: .googleIdentity(offerGmail: offerGmail))
        guard let idToken = result.idToken else { throw OAuthError.server("Google didn't confirm your email") }
        let gmail = offerGmail && result.grantedScopes.contains(OAuthEndpoints.gmailReadOnly) ? result : nil
        return Outcome(idToken: idToken, email: result.email, gmail: gmail)
    }

    /// Adds the Gmail account to email codes, once.
    static func addGmail(_ result: OAuthSignIn.Result, to center: EmailCodeCenter) {
        let address = result.email ?? "Gmail"
        guard !center.accounts.contains(where: { $0.provider == .google && $0.address == address }) else { return }
        center.add(EmailAccount(provider: .google, address: address), credential: .oauth(result.tokens))
    }
}

// MARK: - Signed out: passwordless forms

/// Create a passwordless account: invite, email or Google, username.
struct PasswordlessCreateForm: View {
    let sync: SyncAccount
    @Environment(AppEnvironment.self) private var env
    @State private var inviteCode = ""
    @State private var email = ""
    @State private var username = ""
    @State private var offerGmail = true
    @State private var runner = GoogleSignInRunner()
    @State private var googleBusy = false
    @State private var googleError: String?

    private var hasGoogle: Bool { !env.emailCodes.clients.googleClientID.isEmpty }

    private var problem: String? {
        if inviteCode.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter your invite code." }
        if let problem = SyncAccount.usernameProblem(username) { return problem }
        return nil
    }

    var body: some View {
        TextField("Invite code", text: $inviteCode, prompt: Text("From someone who uses Sync"))
            .font(.body.monospaced())
        TextField("Username", text: $username, prompt: Text("Shown to your groups and contacts"))
            .textContentType(.nickname)
        TextField("Email", text: $email, prompt: Text("you@example.com"))
            .textContentType(.username)
        Text("No password: this Mac holds your key. To use Sync on another device, you approve it here. Set up recovery right after, in case you lose this Mac.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            if hasGoogle {
                Button {
                    google()
                } label: {
                    Label("Continue with Google", systemImage: "g.circle")
                }
                .disabled(problem != nil || googleBusy)
                Toggle("Also read Gmail for sign-in codes", isOn: $offerGmail)
                    .toggleStyle(.checkbox)
                    .help("Google asks for each permission separately; you can untick Gmail there and still sign in.")
            }
            Spacer()
            if let problem, !(inviteCode.isEmpty && username.isEmpty) {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }
            Button("Create Account") {
                let (email, username, code) = (email, username, inviteCode)
                Task { await sync.signUpPasswordless(email: email, username: username, inviteCode: code) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(problem != nil || !email.contains("@"))
        }
        if let googleError {
            Text(googleError).font(.caption).foregroundStyle(.orange)
        }
        Text(hasGoogle ? "Continue with Google verifies your email. Without it, your email stays unverified, and a verified account can take the address over later."
                       : "Your email stays unverified for now.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func google() {
        googleError = nil
        googleBusy = true
        let (username, code, offer) = (username, inviteCode, offerGmail)
        Task {
            defer { googleBusy = false }
            do {
                let outcome = try await runner.run(clients: env.emailCodes.clients, offerGmail: offer)
                await sync.signUpPasswordless(email: nil, googleIdToken: outcome.idToken, username: username, inviteCode: code)
                if sync.isSignedIn, let gmail = outcome.gmail { GoogleSignInRunner.addGmail(gmail, to: env.emailCodes) }
            } catch OAuthError.cancelled {
            } catch {
                googleError = error.localizedDescription
            }
        }
    }
}

/// Sign in on this Mac by asking an existing device, or start a recovery.
struct DeviceSignInForm: View {
    let sync: SyncAccount
    var recovering = false
    @State private var identifier = ""
    @State private var window: SessionWindow = .day
    @State private var acknowledgement = ""

    var body: some View {
        TextField("Email or username", text: $identifier, prompt: Text("you@example.com or your username"))
            .textContentType(.username)
        SessionWindowPicker(window: $window, acknowledgement: $acknowledgement)
        if recovering {
            Text("Use this only if you no longer have any signed-in device. Your recovery contacts approve it, then there's a **72-hour wait** during which all your devices are told and can stop it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            Button(recovering ? "Start Recovery" : "Ask My Other Device") {
                let (identifier, window, ack) = (identifier, window, acknowledgement)
                Task {
                    if recovering {
                        await sync.startRecovery(identifier: identifier, window: window, acknowledgement: ack)
                    } else {
                        await sync.startDeviceLogin(identifier: identifier, window: window, acknowledgement: ack)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(identifier.trimmingCharacters(in: .whitespaces).isEmpty || !window.canStart(acknowledgement: acknowledgement))
        }
    }
}

/// The new device's side: the number to find on the other device, and a countdown.
struct DeviceLoginWaitingSection: View {
    let sync: SyncAccount
    let progress: DeviceLoginProgress

    var body: some View {
        Section {
            switch progress.status {
            case .waiting:
                VStack(alignment: .center, spacing: 10) {
                    Text("On a device that's already signed in, open Settings → Sync and pick this number:")
                        .multilineTextAlignment(.center)
                    Text("\(progress.number)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .accessibilityLabel("Number \(progress.number)")
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(progress.expiresAt.timeIntervalSince(context.date)))
                        Text("Waiting for approval · \(left / 60):\(String(format: "%02d", left % 60)) left · stays signed in \(progress.window.title.lowercased())")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    ProgressView().controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                HStack {
                    Spacer()
                    Button("Cancel") { sync.cancelDeviceLogin() }
                }
            default:
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Start Again") { sync.dismissDeviceLogin() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } header: {
            Text("Sign In to Sync")
        }
    }

    private var message: String {
        switch progress.status {
        case .waiting: ""
        case .denied: "The request was declined on your other device."
        case .mismatch: "The wrong number was picked on your other device, so this Mac wasn't let in."
        case .expired: "Nobody approved it in time. Start again and approve it within 5 minutes."
        case .cancelled: "The request was cancelled."
        case .failed(let why): why
        }
    }
}

/// The recovering device's side: the number for the contacts, and the release time.
struct RecoveryWaitingSection: View {
    let sync: SyncAccount
    let progress: RecoveryProgress

    var body: some View {
        Section {
            if progress.status == .waiting {
                VStack(alignment: .center, spacing: 10) {
                    Text("Tell your recovery contact(s) this number. They pick it in Settings → Sync on their device:")
                        .multilineTextAlignment(.center)
                    Text("\(progress.number)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("Approved by \(progress.approvals) of \(progress.needed) · ready \(progress.releaseAt.formatted(date: .abbreviated, time: .shortened)) at the earliest")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Your other devices (if any) are told and can stop this. You can quit the app; the recovery continues.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                HStack {
                    Spacer()
                    Button("Stop Recovery") { sync.cancelRecoveryHere() }
                }
            } else {
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.orange)
                HStack {
                    Spacer()
                    Button("OK") { sync.dismissRecovery() }
                }
            }
        } header: {
            Text("Recovering Your Account")
        }
    }

    private var message: String {
        switch progress.status {
        case .waiting: ""
        case .denied: "A recovery contact declined."
        case .mismatch: "A contact picked the wrong number, so the recovery stopped. Start again."
        case .cancelled: "The recovery was cancelled, from one of your devices or here."
        case .expired: "The recovery expired. Start again."
        case .failed(let why): why
        }
    }
}

// MARK: - Signed in: alerts

/// New devices, recoveries of this account, and contacts' recoveries, at the top of Sync.
struct SecurityAlertsSection: View {
    let sync: SyncAccount

    var body: some View {
        if !sync.accountRecoveries.isEmpty || !sync.deviceRequests.isEmpty || !sync.recoveryHelpRequests.isEmpty
            || sync.recoveryInvitations.contains(where: { !$0.accepted }) || sync.emailReleased {
            Section {
                ForEach(sync.accountRecoveries) { AccountRecoveryBanner(sync: sync, recovery: $0) }
                ForEach(sync.deviceRequests) { DeviceRequestCard(sync: sync, request: $0) }
                ForEach(sync.recoveryHelpRequests) { RecoveryHelpCard(sync: sync, help: $0) }
                ForEach(sync.recoveryInvitations.filter { !$0.accepted }) { RecoveryInvitationRow(sync: sync, invitation: $0) }
                if sync.emailReleased {
                    Label("Another account verified your email address, so it was moved there. Verify or change your email under Account.",
                          systemImage: "envelope.badge.shield.half.filled")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Needs Your Attention")
            }
        }
    }
}

/// Three numbers, enabled after 3 seconds; the right one is the one on the new device.
struct NumberMatchButtons: View {
    let correct: Int
    let onPick: (Int) -> Void
    @State private var choices: [Int] = []
    @State private var armed = false

    var body: some View {
        HStack(spacing: 10) {
            ForEach(choices, id: \.self) { number in
                Button {
                    onPick(number)
                } label: {
                    Text("\(number)").font(.title2.weight(.semibold)).monospacedDigit().frame(minWidth: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!armed)
                .accessibilityLabel("Number \(number)")
            }
        }
        .task {
            if choices.isEmpty { choices = PasswordlessCrypto.choices(correct: correct) }
            try? await Task.sleep(for: .seconds(3))
            armed = true
        }
    }
}

private struct DeviceRequestCard: View {
    let sync: SyncAccount
    let request: PendingDeviceRequest
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("“\(request.deviceName ?? "Unnamed device")” wants to sign in", systemImage: "laptopcomputer.and.arrow.down")
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(PasswordlessText.platform(request.platform)) · \(PasswordlessText.location(country: request.country, city: request.city) ?? "Location unknown") · \(Date(syncMillis: request.createdAt).formatted(date: .omitted, time: .shortened))")
                Text("Asks to stay signed in: \(SessionWindow(milliseconds: request.windowMs).title.lowercased())")
            }
            .font(.caption).foregroundStyle(.secondary)
            if request.newCountry == true {
                Label("New location: this account has never signed in from there.", systemImage: "globe.badge.chevron.backward")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Only approve if you are signing in yourself right now. Pick the number shown on that device:")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                NumberMatchButtons(correct: PasswordlessCrypto.matchNumber(requestId: request.id, devicePublicKey: request.devicePublicKey)) { pick in
                    run { try await sync.approve(request, picked: pick) }
                }
                .disabled(busy)
                Spacer()
                Button("Not Now") { run { try await sync.deny(request, block: false) } }
                Button("This Wasn't Me", role: .destructive) { run { try await sync.deny(request, block: true) } }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .padding(.vertical, 4)
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do { try await operation() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

private struct AccountRecoveryBanner: View {
    let sync: SyncAccount
    let recovery: AccountRecovery
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Someone is recovering your account", systemImage: "exclamationmark.octagon.fill")
                .font(.headline).foregroundStyle(.red)
            Text("On “\(recovery.deviceName ?? "a device")” (\(PasswordlessText.location(country: recovery.country, city: recovery.city) ?? "location unknown")), started \(Date(syncMillis: recovery.createdAt).formatted(date: .abbreviated, time: .shortened)). \(recovery.approvals) of \(recovery.needed) contacts approved. It completes \(Date(syncMillis: recovery.releaseAt).formatted(date: .abbreviated, time: .shortened)) unless you stop it.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("If this isn't you, cancel it now.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel Recovery", role: .destructive) {
                    Task {
                        do { try await sync.cancel(recovery) } catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .padding(.vertical, 4)
    }
}

private struct RecoveryHelpCard: View {
    let sync: SyncAccount
    let help: RecoveryHelpRequest
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(help.name) is recovering their account", systemImage: "person.badge.key.fill").font(.headline)
            Text("On “\(help.deviceName ?? "a device")”, \(PasswordlessText.location(country: help.country, city: help.city) ?? "location unknown"). Call or meet \(help.name) and ask for the number on their new device. Never approve because of a message alone: that's how account takeovers work.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                NumberMatchButtons(correct: PasswordlessCrypto.matchNumber(requestId: help.id, devicePublicKey: help.devicePublicKey)) { pick in
                    run { try await sync.approve(help, picked: pick) }
                }
                .disabled(busy)
                Spacer()
                Button("Decline", role: .destructive) { run { try await sync.deny(help) } }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .padding(.vertical, 4)
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do { try await operation() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

private struct RecoveryInvitationRow: View {
    let sync: SyncAccount
    let invitation: RecoveryInvitation
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("**\(invitation.name)** asks you to be a recovery contact. If they lose all their devices, they'll need your approval to get back in. You can't read their data.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Decline") { run { try await sync.decline(invitation) } }
                Button("Accept") { run { try await sync.accept(invitation) } }.buttonStyle(.borderedProminent)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Signed in: recovery

struct RecoverySection: View {
    let sync: SyncAccount
    @State private var picked: Set<String> = []
    @State private var choosing = false
    @State private var confirmRemove = false
    @State private var busy = false
    @State private var error: String?

    private var candidates: [SyncContact] { sync.contacts.filter { $0.uid != nil } }

    var body: some View {
        Section {
            if sync.needsRecoveryWarning {
                Label("If you lose this Mac, your synced data is gone: it's your only device and recovery isn't set up.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let setup = sync.recoverySetup, !choosing {
                LabeledContent("Recovery") {
                    Text(statusText(setup)).foregroundStyle(setup.status == "active" ? Color.green : Color.orange)
                }
                ForEach(setup.contacts) { contact in
                    LabeledContent(contact.name) {
                        Text(contact.accepted ? "Accepted" : "Waiting for them to accept").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    if confirmRemove {
                        Text("Remove recovery?").font(.caption)
                        Button("Cancel") { confirmRemove = false }
                        Button("Remove", role: .destructive) {
                            confirmRemove = false
                            run { try await sync.removeRecovery() }
                        }
                    } else {
                        Button("Remove…") { confirmRemove = true }
                        Button("Change Contacts…") { begin() }
                    }
                }
            } else if choosing {
                Text("Pick one or two contacts. With one, they and the server together can let you back in; with two, both must approve. Either way there's a 72-hour wait your devices can stop. They never see your data.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if candidates.isEmpty {
                    Text("Add a contact first (Contacts, above).").foregroundStyle(.secondary)
                }
                ForEach(candidates) { contact in
                    Toggle(contact.name, isOn: Binding(
                        get: { picked.contains(contact.id) },
                        set: { on in
                            if on { if picked.count < 2 { picked.insert(contact.id) } } else { picked.remove(contact.id) }
                        }))
                }
                LabeledContent("Recovery code by email") {
                    Text("Not available yet").foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { choosing = false }
                    Button("Set Up") {
                        let chosen = candidates.filter { picked.contains($0.id) }
                        run {
                            try await sync.setUpRecovery(with: chosen)
                            choosing = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(picked.isEmpty || picked.count > 2 || busy)
                }
            } else {
                Text("Choose how you'd get back in if you lost every device.").foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Set Up Recovery…") { begin() }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        } header: {
            Text("Recovery")
        }
        .task { await sync.refreshSecurity() }
    }

    private func statusText(_ setup: RecoverySetupState) -> String {
        switch setup.status {
        case "active": setup.contacts.count == 1 ? "On, with 1 contact" : "On, with \(setup.contacts.count) contacts"
        case "pending": "Waiting for contacts to accept"
        default: "Not working: a contact stepped down. Set it up again."
        }
    }

    private func begin() {
        picked = Set(sync.recoverySetup?.contacts.compactMap { c in candidates.first { $0.uid == c.uid }?.id } ?? [])
        choosing = true
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do { try await operation() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

// MARK: - Signed in: account

/// Switch to passwordless, verify the email, delete a passwordless account.
struct PasswordlessAccountRows: View {
    let sync: SyncAccount
    @Environment(AppEnvironment.self) private var env
    @State private var switching = false
    @State private var password = ""
    @State private var retire = false
    @State private var deleting = false
    @State private var confirmName = ""
    @State private var runner = GoogleSignInRunner()
    @State private var error: String?

    var body: some View {
        if sync.emailVerified != true, !env.emailCodes.clients.googleClientID.isEmpty {
            LabeledContent("Email") {
                HStack {
                    Text(sync.emailReleased ? "Taken by a verified account" : "Not verified").foregroundStyle(.secondary)
                    Button("Verify with Google…") { verify() }
                }
            }
        }
        if !sync.isPasswordlessDevice {
            if switching {
                Text("This Mac becomes a trusted device: new devices sign in when you approve them here. Keep the password if you use Sync on Windows, which still needs it.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Current password", text: $password)
                Toggle("Also remove the password (only when no other device signs in with it)", isOn: $retire)
                HStack {
                    Spacer()
                    Button("Cancel") { switching = false }
                    Button("Switch") {
                        let (pw, retire) = (password, retire)
                        password = ""
                        Task { if await sync.switchToPasswordless(password: pw, retirePassword: retire) { switching = false } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
                }
            } else {
                HStack {
                    Text("Sign in without a password on new devices.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Switch to Passwordless…") { switching = true }
                }
            }
        }
        if sync.isPasswordlessDevice && sync.accountHasPassword == false {
            if deleting {
                Text("This deletes your account and everything synced, for good. Type your username to confirm.")
                    .font(.callout)
                TextField("Username", text: $confirmName)
                HStack {
                    Spacer()
                    Button("Cancel") { deleting = false }
                    Button("Delete Account", role: .destructive) {
                        let name = confirmName
                        Task { if await sync.deletePasswordlessAccount(confirm: name) { deleting = false } }
                    }
                    .disabled(confirmName.trimmingCharacters(in: .whitespaces).lowercased() != (sync.username ?? "").lowercased())
                }
            } else {
                HStack {
                    Spacer()
                    Button("Delete Account…", role: .destructive) { deleting = true }
                }
            }
        }
        if let error { Text(error).font(.caption).foregroundStyle(.orange) }
    }

    private func verify() {
        error = nil
        Task {
            do {
                let outcome = try await runner.run(clients: env.emailCodes.clients, offerGmail: true)
                try await sync.verifyEmail(googleIdToken: outcome.idToken)
                if let gmail = outcome.gmail { GoogleSignInRunner.addGmail(gmail, to: env.emailCodes) }
            } catch OAuthError.cancelled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A device's window, and changing it inline.
struct DeviceWindowRow: View {
    let sync: SyncAccount
    let device: SyncDevice
    @State private var editing = false
    @State private var window: SessionWindow = .day
    @State private var acknowledgement = ""
    @State private var error: String?

    var body: some View {
        if device.isDeviceSession {
            HStack {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(SessionExpiry.describe(device.expiresAt, now: context.date))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !editing { Button("Change Window…") { begin() }.controlSize(.small) }
            }
            if editing {
                SessionWindowPicker(window: $window, acknowledgement: $acknowledgement, label: device.isCurrent ? "Stay signed in" : "Sign it out after")
                if !device.isCurrent {
                    Text("From here you can only shorten this device's window.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save") {
                        let (window, ack) = (window, acknowledgement)
                        Task {
                            do {
                                try await sync.changeWindow(of: device, to: window, acknowledgement: ack)
                                editing = false
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!window.canStart(acknowledgement: acknowledgement)
                              || !SessionExpiry.canChange(current: device.expiresAt, to: window.expiry(from: .now), isThisDevice: device.isCurrent))
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func begin() {
        window = device.window ?? .day
        acknowledgement = ""
        error = nil
        editing = true
    }
}

extension NotificationHub {
    /// New devices and recoveries always notify (they aren't one of the per-kind switches).
    func postSecurityAlert(_ text: String) {
        let notification = AppNotification(kind: .contacts, title: "Clipboard2 Sync", body: text, target: nil, groupId: "security")
        let poster = self.poster
        Task {
            var permission = await poster.permission()
            if permission == .notDetermined { permission = await poster.requestPermission() ? .allowed : .denied }
            if permission == .allowed { poster.post(notification) }
        }
    }
}
