import SwiftUI
import KeyboardShortcuts

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
                GroupSafetySection()
                SyncContactsSection(sync: sync)
                SyncDevicesSection(sync: sync)
                InviteSomeoneSection(sync: sync)
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
    @State private var username = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var understood = false
    @State private var inviteCode = ""

    private static let minimumPasswordLength = 8

    private var problem: String? {
        let address = email.trimmingCharacters(in: .whitespaces)
        if address.isEmpty || !address.contains("@") { return "Enter your email address." }
        if password.isEmpty { return "Enter a password." }
        guard creating else { return nil }
        if inviteCode.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter your invite code." }
        if let problem = SyncAccount.usernameProblem(username) { return problem }
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
            if creating {
                TextField("Invite code", text: $inviteCode, prompt: Text("From someone who uses Sync"))
                    .font(.body.monospaced())
            }
            TextField("Email", text: $email, prompt: Text("you@example.com"))
                .textContentType(.username)
            if creating {
                TextField("Username", text: $username, prompt: Text("Shown to your groups"))
                    .textContentType(.nickname)
            }
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Keeps recent history (newest 200 items), labelled items, snippets and secrets in step across your Macs and PCs, and shares items with groups. Everything is encrypted on this Mac before upload — the server can't read it. New accounts need an invite code: a sign-up code, or a group's invite code (you join that group right away).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if creating {
                    PrivacyNoticeLink()
                }
            }
        }
        .onChange(of: creating) { sync.clearMessages() }
    }

    private func submit() {
        guard problem == nil else { return }
        let (email, password, username, inviteCode) = (email, password, username, inviteCode)
        self.password = ""
        confirm = ""
        understood = false
        Task {
            if creating {
                await sync.signUp(email: email, password: password, username: username, inviteCode: inviteCode)
            } else {
                await sync.signIn(email: email, password: password)
            }
        }
    }
}

/// Shows the username and edits it in place. Accounts from before usernames get a prompt to pick one.
private struct UsernameRow: View {
    let sync: SyncAccount
    @State private var editing = false
    @State private var draft = ""
    @State private var saving = false

    var body: some View {
        LabeledContent("Username") {
            if editing {
                HStack(spacing: 6) {
                    TextField("Username", text: $draft, prompt: Text("Shown to your groups"))
                        .labelsHidden()
                        .frame(maxWidth: 180)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(saving || SyncAccount.usernameProblem(draft) != nil)
                    Button("Cancel") { editing = false }
                }
            } else if let name = sync.username {
                HStack(spacing: 8) {
                    Text(name)
                    Button("Change…") { begin() }
                }
            } else {
                Button("Set a Username…") { begin() }
                    .buttonStyle(.borderedProminent)
            }
        }
        if editing, !draft.isEmpty, let problem = SyncAccount.usernameProblem(draft) {
            Text(problem).font(.caption).foregroundStyle(.secondary)
        } else if sync.username == nil && !editing {
            Text("Group members see your username on the items you copy.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func begin() {
        draft = sync.username ?? ""
        editing = true
    }

    private func save() {
        guard SyncAccount.usernameProblem(draft) == nil else { return }
        saving = true
        Task {
            if await sync.setUsername(draft) { editing = false }
            saving = false
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
            // Without one, Contacts below asks for it (that's where it matters most).
            if sync.username != nil { UsernameRow(sync: sync) }
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
            Text("Items shared with a group are visible to all its members, encrypted with a key only members hold. To add someone, create an invite code under Manage… and send it to them. In the quick panel, use ⌘K → Share to Group… for any item.")
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

/// What happens before anything leaves this Mac for a group.
private struct GroupSafetySection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var prefs = env.prefs
        Section {
            LabeledContent {
                KeyboardShortcuts.Recorder(for: .sendToGroup)
            } label: {
                Text("Send selection to default group")
                Text("Off until you choose a shortcut.")
            }
            Toggle(isOn: $prefs.confirmGroupSends) {
                Text("Show a preview with Undo")
                Text("Waits 3 seconds before the selection is sent, so you can stop it.")
            }
            Toggle(isOn: $prefs.blockSensitiveGroupSends) {
                Text("Never send passwords, keys or codes")
                Text("Checked on this Mac before anything leaves it. You can still send one on purpose.")
            }
        } header: {
            Text("Before anything is shared")
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
                            Text(member.displayName)
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
                                .accessibilityLabel("Remove \(member.displayName)")
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
                        Text("Anyone with the code can join, so send it privately. With an account, they enter it under Settings → Sync → Join a Group; someone new uses it as the invite code when creating their account.")
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

/// Paste an invite code, see which group it is (or whose contact code), then join or add them.
private struct JoinGroupSheet: View {
    let sync: SyncAccount
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var preview: InvitePreview?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter an Invite Code").font(.headline)
            if let preview, preview.isContact {
                Label("Add \(preview.name) as a contact?", systemImage: "person.crop.circle.badge.plus")
                    .font(.title3)
                Text("You'll be able to send each other items. What \(preview.name) sends you shows up in your Inbox.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let preview {
                Label("Join “\(preview.name)”?", systemImage: "person.2.fill")
                    .font(.title3)
                Text("\(preview.memberCount) \(preview.memberCount == 1 ? "member" : "members"). Everything shared there will appear on this Mac, and they'll see what you share.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Paste the group invite code or contact code you were sent.")
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
                    Button(preview.isContact ? "Add Contact" : "Join") {
                        run {
                            if preview.isContact {
                                try await sync.addContact(preview)
                            } else {
                                try await sync.join(preview)
                            }
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

/// People you send items to without a group: add them by username (they accept) or with a
/// one-time code, answer their requests, and end a contact.
private struct SyncContactsSection: View {
    let sync: SyncAccount
    @State private var username = ""
    @State private var newCode: String?
    @State private var copied = false
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?
    @State private var removing: SyncContact?
    @State private var enteringCode = false

    var body: some View {
        let requests = sync.contactRequests
        Section {
            if let name = sync.username {
                LabeledContent("Your username") {
                    Text(name).textSelection(.enabled)
                }
                Text("Others add you by this name.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("You don't have a username yet, so nobody can add you by name. Set one, or send someone a contact code.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                UsernameRow(sync: sync)
            }
            ForEach(requests.incoming) { request in
                HStack {
                    Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(.tint).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(request.name) wants to add you")
                        Text("Request from \(Date(syncMillis: request.createdAt).formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Decline") { run { try await sync.dismiss(request) } }
                    Button("Accept") {
                        run {
                            try await sync.accept(request)
                            info = "You and \(request.name) are now contacts."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .disabled(busy)
            }
            if sync.contacts.isEmpty && requests.incoming.isEmpty {
                Text("No contacts yet. Add someone to send them items without making a group.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sync.contacts) { contact in
                HStack {
                    Image(systemName: "person.crop.circle.fill").foregroundStyle(.tint).accessibilityHidden(true)
                    Text(contact.name)
                    Spacer()
                    Button("Remove…") { removing = contact }
                }
            }
            ForEach(requests.outgoing) { request in
                HStack {
                    Image(systemName: "clock").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Waiting for \(request.name) to accept")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { run { try await sync.dismiss(request) } }
                }
            }
            HStack {
                TextField("Add by username", text: $username, prompt: Text("Their username"))
                    .onSubmit(request)
                Button("Send Request", action: request)
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            if let newCode {
                HStack {
                    Text(newCode)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(newCode, forType: .string)
                        copied = true
                    }
                }
                Text("Shown only once. Whoever enters it becomes your contact; it works once, for 7 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(sync.contactCodes) { code in
                HStack {
                    Text("Code created \(Date(syncMillis: code.createdAt).formatted(date: .abbreviated, time: .shortened))")
                    Spacer()
                    Text("expires \(Date(syncMillis: code.expiresAt).formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Revoke") { run { try await sync.revoke(code) } }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            } else if let info {
                Text(info).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Enter a Code…") { enteringCode = true }
                Button("Create Contact Code") {
                    run {
                        newCode = try await sync.createContactCode()
                        copied = false
                    }
                }
                .disabled(busy)
            }
        } header: {
            Text("Contacts")
        } footer: {
            Text("Send items to a contact with ⌘K or the right-click menu in the quick panel; they arrive in their Inbox, encrypted so only the two of you can read them. Add someone by their username (they accept the request) or give them a contact code.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await sync.refreshContacts() }
        .sheet(isPresented: $enteringCode) {
            JoinGroupSheet(sync: sync)
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Contact", role: .destructive) {
                guard let contact = removing else { return }
                run { try await sync.remove(contact) }
            }
        } message: {
            Text("This deletes everything you've sent each other, for both of you.")
        }
    }

    private func request() {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !busy else { return }
        run {
            let sent = try await sync.requestContact(username: name)
            username = ""
            info = "Request sent to \(sent.name)."
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

/// Every device signed in to the account, with Sign Out for each.
private struct SyncDevicesSection: View {
    let sync: SyncAccount
    @State private var confirming: SyncDevice?
    @State private var error: String?

    var body: some View {
        Section {
            if sync.devices.isEmpty {
                Text("Loading devices…").foregroundStyle(.secondary)
            }
            ForEach(sync.devices) { device in
                HStack {
                    Image(systemName: device.isCurrent ? "laptopcomputer" : "desktopcomputer")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(device.name)
                            if device.isCurrent {
                                Text("This Mac").font(.caption).foregroundStyle(.tint)
                            }
                        }
                        Text("Last used \(device.lastUsedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign Out…") { confirming = device }
                }
                .accessibilityElement(children: .combine)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Devices")
        } footer: {
            Text("Signing out a device stops it syncing until someone signs in there again with your password.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await sync.refreshDevices() }
        .confirmationDialog("Sign out “\(confirming?.name ?? "")”?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Sign Out", role: .destructive) {
                guard let device = confirming else { return }
                error = nil
                Task {
                    do {
                        try await sync.signOut(device)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        } message: {
            Text(confirming?.isCurrent == true
                 ? "Group items are removed from this Mac. Your own history stays."
                 : "That device stops syncing right away.")
        }
    }
}

/// Sign-up is invite-only: make a code for someone, copy it, and see or revoke open ones.
private struct InviteSomeoneSection: View {
    let sync: SyncAccount
    @State private var newCode: String?
    @State private var codes: [OpenSignupCode] = []
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        Section {
            if let newCode {
                HStack {
                    Text(newCode)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(newCode, forType: .string)
                        copied = true
                    }
                }
                Text("Shown only once. Works for one new account, for 14 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(codes) { code in
                HStack {
                    Text("Code created \(Date(syncMillis: code.createdAt).formatted(date: .abbreviated, time: .shortened))")
                    Spacer()
                    Text("expires \(Date(syncMillis: code.expiresAt).formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Revoke") {
                        run {
                            try await sync.revoke(code)
                            codes.removeAll { $0.id == code.id }
                        }
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Create Invite Code") {
                    run {
                        newCode = try await sync.createSignupCode().code
                        copied = false
                        codes = try await sync.openSignupCodes()
                    }
                }
                .disabled(busy)
            }
        } header: {
            Text("Invite Someone")
        } footer: {
            Text("New accounts need an invite. Send the code privately; it creates one account. To share a group, use its own invite code under Manage….")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            codes = (try? await sync.openSignupCodes()) ?? []
        }
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
            Text("Signing out removes group and contact items from this Mac; your own history stays. Changing the password signs out your other devices.")
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
            Text("Permanently deletes your account, your synced history, labelled items, snippets and secrets, the groups you own (for all their members) and everything you and your contacts sent each other. Items on this Mac stay. This can't be undone.")
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
