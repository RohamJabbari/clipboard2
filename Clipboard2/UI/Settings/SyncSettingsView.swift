import SwiftUI

// MARK: - Sync tab

struct SyncSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let sync = env.sync
        Form {
            SyncMessages(sync: sync)
            switch sync.state {
            case .signedOut:
                SyncSignInSection(sync: sync)
            case .working(let text):
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(text).foregroundStyle(.secondary)
                    }
                }
            case .needsPassword(let email):
                NeedsPasswordSection(sync: sync, email: email)
            case .signedIn(let email):
                SyncStatusSection(sync: sync, email: email)
                SyncGroupsSection(sync: sync)
                SyncAccountSection(sync: sync)
            }
        }
        .formStyle(.grouped)
    }
}

/// Error and confirmation lines from the last account action.
private struct SyncMessages: View {
    let sync: SyncAccount

    var body: some View {
        if sync.errorMessage != nil || sync.notice != nil {
            Section {
                if let error = sync.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notice = sync.notice {
                    Label(notice, systemImage: "info.circle")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Shown before an account exists and whenever the user picks a password.
private struct LostPasswordWarning: View {
    var body: some View {
        Label {
            Text("Your password is the key to your synced data, which is encrypted on this Mac. **There's no password recovery: if you forget it, your synced data is lost.** Keep it in a password manager.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.lock.fill").foregroundStyle(.orange)
        }
        .font(.callout)
    }
}

// MARK: - Signed out

private struct SyncSignInSection: View {
    let sync: SyncAccount
    @State private var creating = true
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var understood = false

    private static let minimumPasswordLength = 8

    private var problem: String? {
        let address = email.trimmingCharacters(in: .whitespaces)
        if address.isEmpty || !address.contains("@") { return "Enter your email address." }
        if password.isEmpty { return "Enter a password." }
        guard creating else { return nil }
        if password.count < Self.minimumPasswordLength { return "Use at least \(Self.minimumPasswordLength) characters." }
        if confirm != password { return "The passwords don't match." }
        if !understood { return "Confirm that you understand there's no recovery." }
        return nil
    }

    var body: some View {
        Section {
            Picker("Account", selection: $creating) {
                Text("Create Account").tag(true)
                Text("Sign In").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Email", text: $email, prompt: Text("you@example.com"))
                .textContentType(.username)
            SecureField("Password", text: $password)
                .textContentType(creating ? .newPassword : .password)
            if creating {
                SecureField("Confirm password", text: $confirm)
                    .textContentType(.newPassword)
                LostPasswordWarning()
                Toggle("I understand that a forgotten password can't be recovered", isOn: $understood)
            }
            HStack {
                Spacer()
                if let problem, !(email.isEmpty && password.isEmpty) {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
                Button(creating ? "Create Account" : "Sign In") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Keeps recent history (newest 200 items), pinned items, snippets and secrets in step across your Macs and PCs, and shares items with groups. Everything is encrypted on this Mac before upload — the server can't read it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: creating) { sync.clearMessages() }
    }

    private func submit() {
        guard problem == nil else { return }
        let (email, password) = (email, password)
        self.password = ""
        confirm = ""
        understood = false
        Task {
            if creating {
                await sync.signUp(email: email, password: password)
            } else {
                await sync.signIn(email: email, password: password)
            }
        }
    }
}

// MARK: - Session ended

private struct NeedsPasswordSection: View {
    let sync: SyncAccount
    let email: String
    @State private var password = ""

    var body: some View {
        Section {
            Text("Enter your password to resume syncing as **\(email)**.")
            SecureField("Password", text: $password)
                .textContentType(.password)
            HStack {
                Spacer()
                Button("Sign Out") { sync.signOut() }
                Button("Sign In") {
                    let entered = password
                    password = ""
                    Task { await sync.unlock(password: entered) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        } header: {
            Text("Sync Paused")
        }
    }
}

// MARK: - Signed in

private struct SyncStatusSection: View {
    let sync: SyncAccount
    let email: String

    var body: some View {
        Section("Sync") {
            LabeledContent("Account") {
                Label(email, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            }
            LabeledContent("Last sync") {
                HStack(spacing: 8) {
                    if sync.isSyncing {
                        ProgressView().controlSize(.small)
                        Text("Syncing…").foregroundStyle(.secondary)
                    } else if let last = sync.lastSyncAt {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text(last.formatted(.relative(presentation: .named)))
                        }
                    } else {
                        Text("Not yet").foregroundStyle(.secondary)
                    }
                    Button("Sync Now") { sync.syncNow() }
                        .disabled(sync.isSyncing)
                }
            }
            if let error = sync.lastSyncError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SyncGroupsSection: View {
    let sync: SyncAccount
    @Environment(AppEnvironment.self) private var env
    @State private var newName = ""
    @State private var managing: SyncGroup?
    @State private var joining = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        @Bindable var prefs = env.prefs
        Section {
            if sync.groups.isEmpty {
                Text("No groups yet. Create one to share items with other people.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sync.groups) { group in
                HStack {
                    Image(systemName: "person.2.fill").foregroundStyle(.tint).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name)
                        Text("\(group.isOwner ? "Owner" : "Member") · \(group.memberCount) \(group.memberCount == 1 ? "member" : "members")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if prefs.syncDefaultGroupID == group.id {
                        Text("Default").font(.caption).foregroundStyle(.tint)
                    }
                    Button(group.isOwner ? "Manage…" : "Members…") { managing = group }
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                TextField("New group", text: $newName, prompt: Text("Group name, e.g. Team"))
                    .onSubmit(create)
                Button("Create Group", action: create)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            HStack {
                Text("Got an invite code?").foregroundStyle(.secondary)
                Spacer()
                Button("Join a Group…") { joining = true }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Picker("Default group", selection: $prefs.syncDefaultGroupID) {
                Text("None").tag(String?.none)
                ForEach(sync.groups) { Text($0.name).tag(Optional($0.id)) }
            }
            .disabled(sync.groups.isEmpty)
        } header: {
            Text("Groups")
        } footer: {
            Text("Items shared with a group are visible to all its members, encrypted with a key only members hold. To add someone, create an invite code under Manage… and send it to them. The “Send selection to default group” shortcut (⌥⌘C, change it in General) stores the selected text there; in the quick panel, use ⌘K → Share to Group… for any item.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(item: $managing) { group in
            GroupManageSheet(sync: sync, group: group)
        }
        .sheet(isPresented: $joining) {
            JoinGroupSheet(sync: sync)
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await sync.createGroup(named: name)
                newName = ""
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Members, invitations, rename, leave and delete for one group.
private struct GroupManageSheet: View {
    let sync: SyncAccount
    let group: SyncGroup
    @Environment(\.dismiss) private var dismiss
    @State private var members: [RemoteMember] = []
    @State private var loading = true
    @State private var invites: [PendingInvite] = []
    @State private var newCode: String?
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?
    @State private var confirmLeaveOrDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(group.name, systemImage: "person.2.fill").font(.headline)
            Form {
                if group.isOwner {
                    Section("Name") {
                        HStack {
                            TextField("Name", text: $name).labelsHidden()
                            Button("Rename") { run { try await sync.renameGroup(group, to: name.trimmingCharacters(in: .whitespaces)) } }
                                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == group.name)
                        }
                    }
                }
                Section("Members") {
                    if loading {
                        ProgressView().controlSize(.small)
                    }
                    ForEach(members) { member in
                        HStack {
                            Text(member.email)
                            Spacer()
                            Text(member.role == "owner" ? "Owner" : "Member").font(.caption).foregroundStyle(.secondary)
                            if group.isOwner && member.role != "owner" {
                                Button {
                                    run {
                                        try await sync.remove(member, from: group)
                                        members.removeAll { $0.uid == member.uid }
                                    }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(member.email)")
                            }
                        }
                    }
                }
                if group.isOwner {
                    Section {
                        if let newCode {
                            HStack {
                                Text(newCode)
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                                Spacer()
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(newCode, forType: .string)
                                    info = "Copied. Send it to the person you're inviting."
                                }
                            }
                            Text("Shown only once. Works for one person, for 7 days.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(invites) { invite in
                            HStack {
                                Text("Code created \(Date(syncMillis: invite.createdAt).formatted(date: .abbreviated, time: .shortened))")
                                Spacer()
                                Text("expires \(Date(syncMillis: invite.expiresAt).formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Revoke") {
                                    run {
                                        try await sync.revoke(invite, in: group)
                                        invites.removeAll { $0.inviteId == invite.inviteId }
                                    }
                                }
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Create Invite Code") {
                                run {
                                    newCode = try await sync.createInviteCode(for: group)
                                    await loadInvites()
                                }
                            }
                        }
                    } header: {
                        Text("Invites")
                    } footer: {
                        Text("Anyone with the code can join, so send it privately. They need their own Clipboard2 Sync account and enter it under Settings → Sync → Join a Group.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            } else if let info {
                Label(info, systemImage: "checkmark.circle").font(.callout)
            }
            HStack {
                Button(group.isOwner ? "Delete Group…" : "Leave Group…", role: .destructive) { confirmLeaveOrDelete = true }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 540)
        .task {
            await loadMembers()
            if group.isOwner { await loadInvites() }
        }
        .onAppear { name = group.name }
        .confirmationDialog(group.isOwner ? "Delete “\(group.name)”?" : "Leave “\(group.name)”?",
                            isPresented: $confirmLeaveOrDelete) {
            Button(group.isOwner ? "Delete Group" : "Leave Group", role: .destructive) {
                run {
                    if group.isOwner { try await sync.delete(group) } else { try await sync.leave(group) }
                    dismiss()
                }
            }
        } message: {
            Text(group.isOwner
                 ? "All items in the group are deleted for every member. This can't be undone."
                 : "The group's items are removed from this Mac. The owner can invite you again.")
        }
    }

    private func loadMembers() async {
        loading = true
        do {
            members = try await sync.members(of: group)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func loadInvites() async {
        do {
            invites = try await sync.pendingInvites(for: group)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        busy = true
        error = nil
        info = nil
        Task {
            do {
                try await operation()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Paste an invite code, see which group it is, then join.
private struct JoinGroupSheet: View {
    let sync: SyncAccount
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var preview: InvitePreview?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join a Group").font(.headline)
            if let preview {
                Label("Join “\(preview.name)”?", systemImage: "person.2.fill")
                    .font(.title3)
                Text("\(preview.memberCount) \(preview.memberCount == 1 ? "member" : "members"). Everything shared there will appear on this Mac, and they'll see what you share.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Paste the invite code you were sent.")
                    .foregroundStyle(.secondary)
                TextField("Code", text: $code, prompt: Text("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX"))
                    .font(.body.monospaced())
                    .onSubmit(look)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if let preview {
                    Button("Join") {
                        run {
                            try await sync.join(preview)
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
                } else {
                    Button("Continue", action: look)
                        .keyboardShortcut(.defaultAction)
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func look() {
        guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        run { preview = try await sync.previewInvite(code: code) }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do {
                try await operation()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

private struct SyncAccountSection: View {
    let sync: SyncAccount
    @State private var changingPassword = false
    @State private var deleting = false
    @State private var confirmSignOut = false

    var body: some View {
        Section {
            HStack {
                Button("Change Password…") { changingPassword = true }
                Spacer()
                Button("Sign Out…") { confirmSignOut = true }
                Button("Delete Account…", role: .destructive) { deleting = true }
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Signing out removes group items from this Mac; your own history stays. Changing the password signs out your other devices.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Sign out of Sync?", isPresented: $confirmSignOut) {
            Button("Sign Out") { sync.signOut() }
        } message: {
            Text("Group items are removed from this Mac. Your synced data stays on the server; sign in again to get it back.")
        }
        .sheet(isPresented: $changingPassword) { ChangePasswordSheet(sync: sync) }
        .sheet(isPresented: $deleting) { DeleteAccountSheet(sync: sync) }
    }
}

private struct ChangePasswordSheet: View {
    let sync: SyncAccount
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?

    private var valid: Bool { !current.isEmpty && new.count >= 8 && new == confirm }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Password").font(.headline)
            Form {
                SecureField("Current password", text: $current).textContentType(.password)
                SecureField("New password", text: $new).textContentType(.newPassword)
                SecureField("Confirm new password", text: $confirm).textContentType(.newPassword)
            }
            .formStyle(.grouped)
            LostPasswordWarning()
            if let error {
                Text(error).font(.callout).foregroundStyle(.orange)
            } else if !new.isEmpty && new.count < 8 {
                Text("Use at least 8 characters.").font(.caption).foregroundStyle(.secondary)
            } else if !confirm.isEmpty && new != confirm {
                Text("The passwords don't match.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Change Password") {
                    busy = true
                    Task {
                        if await sync.changePassword(current: current, new: new) {
                            dismiss()
                        } else {
                            error = sync.errorMessage
                        }
                        busy = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid || busy)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct DeleteAccountSheet: View {
    let sync: SyncAccount
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete Sync Account").font(.headline)
            Text("Permanently deletes your account, your synced history, pinned items, snippets and secrets, and the groups you own (for all their members). Items on this Mac stay. This can't be undone.")
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password).textContentType(.password)
            if let error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete Account", role: .destructive) {
                    busy = true
                    Task {
                        if await sync.deleteAccount(password: password) {
                            dismiss()
                        } else {
                            error = sync.errorMessage
                        }
                        busy = false
                    }
                }
                .disabled(password.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
