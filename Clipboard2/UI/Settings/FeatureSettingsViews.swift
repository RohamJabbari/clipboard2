import SwiftUI
import SwiftData

// MARK: - Snippets

struct SnippetsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \Snippet.name) private var snippets: [Snippet]
    @State private var selection: Snippet.ID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(snippets) { snippet in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snippet.name.isEmpty ? "Untitled" : snippet.name)
                            if !snippet.keyword.isEmpty {
                                Text(snippet.keyword).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(snippet.id)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 0) {
                    Button {
                        let snippet = env.snippets.create()
                        selection = snippet.id
                    } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .accessibilityLabel("Add snippet")
                    Button {
                        if let snippet = selectedSnippet {
                            env.snippets.delete(snippet)
                            selection = nil
                        }
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .disabled(selection == nil)
                    .accessibilityLabel("Delete snippet")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 200)

            Divider()

            if let snippet = selectedSnippet {
                SnippetEditor(snippet: snippet)
                    .id(snippet.id)
            } else {
                ContentUnavailableView {
                    Label("No Snippet Selected", systemImage: "text.badge.star")
                } description: {
                    Text("Snippets show up in the quick panel when you search or pick the Snippets filter.")
                } actions: {
                    Button("New Snippet") { selection = env.snippets.create().id }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 420)
    }

    private var selectedSnippet: Snippet? {
        snippets.first { $0.id == selection }
    }
}

private struct SnippetEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var snippet: Snippet

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $snippet.name)
                TextField("Keyword", text: $snippet.keyword, prompt: Text("e.g. ;sig"))
            }
            Section {
                TextEditor(text: $snippet.body)
                    .font(.body.monospaced())
                    .frame(minHeight: 150)
                    .accessibilityLabel("Snippet body")
            } header: {
                Text("Body")
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("{date}, {time} — current date and time")
                    Text("{clipboard} — what's on the clipboard right now")
                    Text("{cursor} — where the caret ends up after pasting")
                    Text("{anything} — asks you for a value before pasting, e.g. {name}")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: snippet.name) { env.snippets.didEdit(snippet) }
        .onChange(of: snippet.keyword) { env.snippets.didEdit(snippet) }
        .onChange(of: snippet.body) { env.snippets.didEdit(snippet) }
    }
}

// MARK: - Actions (AI + transforms)

/// Everything ⌘K (and ⌥⌘K) can do: the AI provider, your own prompts, and paste rules per app.
struct ActionsSettingsView: View {
    var body: some View {
        Form {
            AISettingsSections()
            TransformRulesSection()
        }
        .formStyle(.grouped)
    }
}

struct TransformRulesSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var prefs = env.prefs
        Group {
            Section {
                if prefs.appTransforms.isEmpty {
                    Text("No rules yet: everything pastes with its original formatting.")
                        .foregroundStyle(.secondary)
                }
                ForEach($prefs.appTransforms) { $rule in
                    HStack {
                        AppRow(app: rule.app)
                        Picker("Transform for \(rule.app.name)", selection: $rule.transform) {
                            ForEach(Transform.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                        Button {
                            // Read the id first: `rule` is a binding into the array being mutated,
                            // and reading it inside removeAll is an exclusivity violation (crash).
                            let id = rule.id
                            prefs.appTransforms.removeAll { $0.id == id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove rule for \(rule.app.name)")
                    }
                }
                AppPickerMenu(title: "Add App…", exclude: Set(prefs.appTransforms.map(\.app.bundleID))) { app in
                    prefs.appTransforms.append(AppTransformRule(app: app, transform: .plainText))
                }
            } header: {
                Text("Paste rules per app")
            } footer: {
                Text("For example, always paste plain text into Mail. ⌘K in the quick panel still lets you pick another transform.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Built-in transforms") {
                    ForEach(Transform.allCases) { transform in
                        Label(transform.title, systemImage: transform.symbol)
                    }
                }
            }
        }
    }
}

// MARK: - AI

struct AISettingsSections: View {
    @Environment(AppEnvironment.self) private var env
    @State private var keyInput = ""
    @State private var hasKey = false
    @State private var replacingKey = false
    @State private var detecting = false
    @State private var detectError: String?
    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle, running, ok, failed(String)
    }

    private enum Mode: Hashable { case claude, chatGPT, apiKey }

    var body: some View {
        @Bindable var prefs = env.prefs
        let provider = prefs.aiProvider
        Group {
            Section {
                Picker("Use", selection: modeBinding) {
                    Text("Claude — sign in with your account").tag(Mode.claude)
                    Text("ChatGPT — sign in with your account").tag(Mode.chatGPT)
                    Text("API key — any provider").tag(Mode.apiKey)
                }
                .pickerStyle(.radioGroup)

                if let account = env.account(for: provider) {
                    SubscriptionAccountRow(account: account)
                        .id(provider)
                } else {
                    apiKeyRows(provider: provider)
                }

                if env.account(for: provider)?.isSignedIn ?? true {
                    LabeledContent("Model") {
                        HStack {
                            TextField("Model", text: $prefs.aiModel, prompt: Text("model-id"))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(minWidth: 220)
                            ModelPickerMenu()
                        }
                    }
                    HStack {
                        Button("Test Connection") { test() }
                            .disabled(testState == .running || (provider.requiresAPIKey && !hasKey))
                        switch testState {
                        case .idle: EmptyView()
                        case .running: ProgressView().controlSize(.small)
                        case .ok: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed(let message):
                            Label(message, systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                                .lineLimit(3)
                        }
                    }
                }
            } header: {
                Text("AI provider")
            } footer: {
                Text("Text is only sent when you run an AI action with ⌘K or ⌥⌘K. Keys stay in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach($prefs.customPrompts) { $prompt in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Name", text: $prompt.name, prompt: Text("Prompt name"))
                                .labelsHidden()
                                .font(.headline)
                            Button {
                                let id = prompt.id   // see appTransforms: never read the binding mid-mutation
                                prefs.customPrompts.removeAll { $0.id == id }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove prompt \(prompt.name)")
                        }
                        TextField("Instructions", text: $prompt.prompt,
                                  prompt: Text("e.g. Rewrite as a friendly email reply"), axis: .vertical)
                            .labelsHidden()
                            .lineLimit(2...6)
                    }
                    .padding(.vertical, 2)
                }
                Button("Add Prompt") {
                    prefs.customPrompts.append(CustomPrompt(name: "New Prompt", prompt: ""))
                }
            } header: {
                Text("Your prompts")
            } footer: {
                Text("They appear in ⌘K next to the built-ins: Translate (English, German, Farsi), Summarize, Fix Grammar and Explain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { refreshKeyState() }
        .onChange(of: prefs.aiProvider) {
            refreshKeyState()
            testState = .idle
        }
    }

    // MARK: API key rows

    @ViewBuilder
    private func apiKeyRows(provider: AIProviderKind) -> some View {
        @Bindable var prefs = env.prefs
        if hasKey && !replacingKey {
            LabeledContent("Provider") {
                Menu(provider.title) {
                    ForEach(AIProviderKind.apiProviders) { option in
                        Button(option.title) { prefs.aiProvider = option }
                    }
                }
                .fixedSize()
            }
            LabeledContent("API key") {
                HStack {
                    Label("Stored in Keychain", systemImage: "key.fill").foregroundStyle(.secondary)
                    Button("Use Another Key…") {
                        keyInput = ""
                        detectError = nil
                        replacingKey = true
                    }
                    Button("Remove", role: .destructive) {
                        Keychain.delete(account: provider.keychainAccount)
                        refreshKeyState()
                    }
                }
            }
        } else {
            LabeledContent("API key") {
                HStack {
                    SecureField("API key", text: $keyInput, prompt: Text("Paste a key from any provider"))
                        .labelsHidden()
                        .frame(minWidth: 300)
                        .onSubmit { connect() }
                    if detecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Connect") { connect() }
                            .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if replacingKey {
                        Button("Cancel") { replacingKey = false }
                    }
                }
            }
            if let detectError {
                LabeledContent("Provider") {
                    HStack {
                        Text(detectError).foregroundStyle(.orange).lineLimit(2)
                        Menu("Choose…") {
                            ForEach(AIProviderKind.apiProviders) { option in
                                Button(option.title) { save(keyInput, as: option) }
                            }
                        }
                        .fixedSize()
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Works with Anthropic, OpenAI, Google Gemini, DeepSeek, Groq, xAI, Mistral and OpenRouter — the provider is detected from the key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if provider != .custom {
                        Button("Local or custom server…") { prefs.aiProvider = .custom }
                            .controlSize(.small)
                            .help("Ollama, LM Studio or any OpenAI-compatible endpoint; a key is optional")
                    }
                }
            }
        }
        if provider.hasEditableBaseURL {
            TextField("Base URL", text: $prefs.customBaseURL, prompt: Text("http://localhost:11434/v1"))
                .frame(minWidth: 300)
        }
    }

    private var modeBinding: Binding<Mode> {
        Binding(
            get: {
                switch env.prefs.aiProvider {
                case .claudeCode: .claude
                case .chatGPT: .chatGPT
                default: .apiKey
                }
            },
            set: { mode in
                switch mode {
                case .claude:
                    env.prefs.aiProvider = .claudeCode
                case .chatGPT:
                    env.prefs.aiProvider = .chatGPT
                case .apiKey:
                    // Prefer a provider that already has a key stored.
                    env.prefs.aiProvider = AIProviderKind.apiProviders.first { $0.apiKey != nil } ?? .anthropic
                }
            }
        )
    }

    // MARK: Actions

    private func refreshKeyState() {
        let provider = env.prefs.aiProvider
        hasKey = provider.usesAPIKey && provider.apiKey != nil
        replacingKey = false
        detectError = nil
        keyInput = ""
    }

    /// Detects the provider from the pasted key, verifies it, stores it and picks a model.
    private func connect() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        detecting = true
        detectError = nil
        Task {
            let provider = await APIKeyDetector.identify(key)
            detecting = false
            if let provider {
                save(key, as: provider)
            } else {
                detectError = APIKeyDetector.candidates(for: key).isEmpty
                    ? "Couldn't tell which provider this key is for."
                    : "The key was rejected. Check it, or pick the provider:"
            }
        }
    }

    private func save(_ rawKey: String, as provider: AIProviderKind) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.save(key, account: provider.keychainAccount, label: "Clipboard2 – \(provider.title) API key")
        let prefs = env.prefs
        prefs.aiProvider = provider
        if prefs.aiModels[provider.rawValue] == nil {
            if !provider.defaultModel.isEmpty {
                prefs.aiModel = provider.defaultModel
            } else {
                Task {
                    let models = (try? await AIModelLister.fetch(provider: provider, customBaseURL: prefs.customBaseURL)) ?? []
                    if let pick = AIModelLister.preferredModel(from: models, for: provider) { prefs.aiModel = pick }
                }
            }
        }
        env.modelCatalog.reload(provider, customBaseURL: prefs.customBaseURL)
        refreshKeyState()
    }

    private func test() {
        let prefs = env.prefs
        testState = .running
        Task {
            do {
                let client = try AIClientFactory.make(provider: prefs.aiProvider, model: prefs.aiModel, customBaseURL: prefs.customBaseURL)
                var output = ""
                for try await chunk in client.stream(system: "Reply with the single word OK.", user: "Ping") {
                    output += chunk
                }
                testState = output.isEmpty ? .failed("Empty response") : .ok
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Claude subscription account

struct SubscriptionAccountRow: View {
    let account: SubscriptionAccount
    @State private var code = ""

    var body: some View {
        Group {
            LabeledContent("Account") {
                HStack(spacing: 8) {
                    status
                    actions
                }
            }
            if account.state == .signingIn {
                VStack(alignment: .leading, spacing: 8) {
                    Text(account.needsCode
                         ? "Sign in on the page that opened. It then shows a code — copy it and paste it here."
                         : "Finish signing in in your browser — Clipboard2 picks it up by itself.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let url = account.signInURL {
                        signInLink(url)
                    }
                    if account.needsCode {
                        HStack {
                            TextField("Code", text: $code, prompt: Text("Paste the code from the browser"))
                                .onSubmit {
                                    account.submitCode(code)
                                    code = ""
                                }
                            Button("Continue") {
                                account.submitCode(code)
                                code = ""
                            }
                            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
            Text("Uses your \(account.cli.planName) plan through \(account.cli.toolName), with no API key and no API billing. Requests take a few seconds longer to start than with an API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await account.refresh() }
    }

    @ViewBuilder
    private func signInLink(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Text(url.absoluteString)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            Button("Open in Browser") { account.openSignInPage() }
            Button("Copy Link") { account.copySignInLink() }
        }
        if let error = account.openError {
            Text("Couldn't open the browser (\(error)). Copy the link and paste it into your browser's address bar.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Text("No browser window? Copy the link and paste it into your browser's address bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch account.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .notInstalled:
            Label("Not set up", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing…").foregroundStyle(.secondary)
            }
        case .signedOut:
            Label("Signed out", systemImage: "person.crop.circle.badge.xmark").foregroundStyle(.secondary)
        case .signingIn:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for browser…").foregroundStyle(.secondary)
            }
        case .signedIn(let name):
            Label(name ?? "Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch account.state {
        case .notInstalled:
            Button("Set Up \(account.cli.serviceName)") { Task { await account.install(); if case .signedOut = account.state { account.signIn() } } }
                .help("Installs \(account.cli.toolName) (no admin rights needed), then signs you in")
        case .signedOut, .failed:
            Button("Sign in with \(account.cli.serviceName)") { account.signIn() }
                .buttonStyle(.borderedProminent)
        case .signingIn:
            Button("Cancel") { account.cancelSignIn(); Task { await account.refresh() } }
        case .signedIn:
            Button("Sign Out") { Task { await account.signOut() } }
        case .checking, .installing:
            EmptyView()
        }
    }
}

// MARK: - Secrets

struct SecretsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var newName = ""
    @State private var newValue = ""
    @State private var editing: SecretRef?
    @State private var editValue = ""
    @State private var confirmDelete: SecretRef?
    @State private var revealed: [String: String] = [:]

    var body: some View {
        @Bindable var prefs = env.prefs
        Form {
            Section {
                if env.secrets.secrets.isEmpty {
                    Text("No secrets yet. Add one below, or select a copied password in the quick panel and press ⌘K → Save as Secret.")
                        .foregroundStyle(.secondary)
                }
                ForEach(env.secrets.secrets) { ref in
                    HStack {
                        Image(systemName: "key.fill").foregroundStyle(.tint).accessibilityHidden(true)
                        TextField("Name", text: Binding(
                            get: { ref.name },
                            set: { env.secrets.rename(ref, to: $0) }
                        ))
                        .labelsHidden()
                        Text(revealed[ref.id] ?? "••••••••")
                            .font(.body.monospaced())
                            .foregroundStyle(revealed[ref.id] == nil ? .secondary : .primary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .frame(maxWidth: 180, alignment: .leading)
                        Button {
                            if revealed[ref.id] != nil {
                                revealed[ref.id] = nil
                            } else {
                                Task { revealed[ref.id] = await env.secrets.reveal(ref, reason: "show “\(ref.name)”") }
                            }
                        } label: {
                            Image(systemName: revealed[ref.id] == nil ? "eye" : "eye.slash")
                        }
                        .buttonStyle(.borderless)
                        .help(revealed[ref.id] == nil ? "Show value (Touch ID)" : "Hide value")
                        .accessibilityLabel(revealed[ref.id] == nil ? "Show \(ref.name)" : "Hide \(ref.name)")
                        if let slot = env.slots.slot(for: .secret(ref.id)) {
                            Text("⌘\(slot)").font(.caption.monospacedDigit()).foregroundStyle(.tint)
                        }
                        Button("Change Value…") {
                            editValue = ""
                            editing = ref
                        }
                        Button {
                            confirmDelete = ref
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete \(ref.name)")
                    }
                }
            } header: {
                Text("Secrets")
            } footer: {
                Text("Kept in your Keychain, never in history, never sent to AI. Sync encrypts them on this Mac first; the server can't read them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Add a secret") {
                TextField("Name", text: $newName, prompt: Text("e.g. Prod DB password"))
                SecureField("Value", text: $newValue)
                HStack {
                    Spacer()
                    Button("Add Secret") {
                        env.secrets.add(name: newName.trimmingCharacters(in: .whitespaces), value: newValue)
                        newName = ""
                        newValue = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newValue.isEmpty)
                }
            }

            Section("Touch ID and clipboard") {
                Picker("Ask for Touch ID", selection: $prefs.secretGraceMinutes) {
                    ForEach(Preferences.secretGraceChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Every time" : minutes == 1 ? "Once per minute" : "Once per \(minutes) minutes").tag(minutes)
                    }
                }
                Picker("Clear clipboard after pasting", selection: $prefs.secretClearSeconds) {
                    ForEach(Preferences.secretClearChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Never" : "\(seconds) seconds").tag(seconds)
                    }
                }
                Text("Unlocking lasts until your Mac sleeps or locks. Pasted secrets are hidden from clipboard managers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Unlock") {
                    SecretUnlockControl(secrets: env.secrets)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { revealed = [:] }
        .sheet(item: $editing) { ref in
            VStack(alignment: .leading, spacing: 14) {
                Text("New value for “\(ref.name)”").font(.headline)
                SecureField("Value", text: $editValue)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        env.secrets.setValue(editValue, for: ref)
                        editing = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(editValue.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
        .confirmationDialog("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let ref = confirmDelete {
                    env.slots.remove(target: .secret(ref.id))
                    env.secrets.delete(ref)
                }
                confirmDelete = nil
            }
        } message: {
            Text("The value is removed from your Keychain.")
        }
    }
}
