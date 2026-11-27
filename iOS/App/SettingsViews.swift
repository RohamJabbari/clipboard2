import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Binding var showSignIn: Bool
    @State private var showSMSSetup = false
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Sync") {
                    if let session = model.session {
                        LabeledContent("Account", value: session.username ?? session.email)
                        if session.expired {
                            Button("Sign In Again…") { showSignIn = true }
                        } else {
                            Button {
                                Task { await model.syncNow() }
                            } label: {
                                HStack {
                                    Text("Sync Now")
                                    Spacer()
                                    if model.isSyncing { ProgressView() }
                                }
                            }
                            .disabled(model.isSyncing)
                        }
                        if let last = model.store.state.lastSync {
                            LabeledContent("Last synced") { Text(last, format: .relative(presentation: .named)) }
                        }
                        if let error = model.errorMessage {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                        Button("Sign Out", role: .destructive) { confirmSignOut = true }
                    } else {
                        Button("Sign In…") { showSignIn = true }
                        Text("Copies, Saved and Auth come from your Mac once you sign in with your Clipboard2 Sync account.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        showSMSSetup = true
                    } label: {
                        Label("Set up SMS codes", systemImage: "message.badge")
                    }
                } header: {
                    Text("Codes from text messages")
                } footer: {
                    Text("Sign-in codes from texts appear in Auth under their site for 10 minutes. Only the code is kept, on this iPhone.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Link("Sync protocol and privacy", destination: URL(string: "https://github.com/RohamJabbari/clipboard2-macOS")!)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showSMSSetup) { SMSSetupView() }
            .confirmationDialog("Sign out of Clipboard2 Sync?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
            } message: {
                Text("Synced items, passwords and authenticators are removed from this iPhone. They stay on your other devices.")
            }
        }
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var approval: ApprovalRequest?
    @FocusState private var focus: Field?

    enum Field { case email, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await signIn() } }
                } footer: {
                    Text("Your password never leaves this iPhone: it unlocks your encryption keys here.")
                }

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Text("Sign In")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working || email.isEmpty || password.isEmpty)
                }

                Section {
                    Button("Approve on My Mac Instead") { Task { await startApproval() } }
                        .disabled(!model.passwordless.isAvailable || email.isEmpty || working)
                } footer: {
                    Text(model.passwordless.isAvailable
                         ? "Your other device asks you to approve this iPhone; no password needed."
                         : "Coming soon: sign in by approving this iPhone on a device that's already signed in.")
                }

                if let approval {
                    Section("Waiting for approval") {
                        LabeledContent("Code on your other device", value: approval.matchCode)
                        Button("Cancel", role: .cancel) {
                            Task { await model.passwordless.cancel(approval) }
                            self.approval = nil
                        }
                    }
                }

                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle(model.needsPassword ? "Sign In Again" : "Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not Now") { dismiss() } }
            }
            .onAppear {
                if let session = model.session { email = session.email }
                focus = email.isEmpty ? .email : .password
            }
        }
        .interactiveDismissDisabled(working)
    }

    private func signIn() async {
        guard !working else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            try await model.signIn(email: email, password: password)
            password = ""
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The passwordless flow, behind `PasswordlessSignIn` (a stub until docs/features/passwordless.md lands).
    private func startApproval() async {
        working = true
        error = nil
        defer { working = false }
        do {
            let request = try await model.passwordless.begin(email: email, deviceName: UIDevice.current.name)
            approval = request
            let session = try await model.passwordless.waitForApproval(request)
            approval = nil
            await model.finishSignIn(session)
            dismiss()
        } catch {
            approval = nil
            self.error = error.localizedDescription
        }
    }
}
