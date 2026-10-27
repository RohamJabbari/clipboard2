import Testing
import Foundation
import SwiftData
@testable import Clipboard2

struct ProviderParsingTests {
    @Test func openAIStreamDeltasAndDone() {
        let delta = #"data: {"id":"x","choices":[{"index":0,"delta":{"content":"Hallo"},"finish_reason":null}]}"#
        #expect(SSEParser.parseOpenAI(line: delta) == .textDelta("Hallo"))
        #expect(SSEParser.parseOpenAI(line: "data: [DONE]") == .done)
        #expect(SSEParser.parseOpenAI(line: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#) == .stop(reason: "stop"))
        #expect(SSEParser.parseOpenAI(line: #"data: {"error":{"message":"Rate limited"}}"#) == .error("Rate limited"))
        #expect(SSEParser.parseOpenAI(line: ": keep-alive") == nil)
    }

    @Test func openAICompatibleRequest() throws {
        let client = OpenAICompatibleClient(baseURL: "https://api.deepseek.com/", apiKey: "sk-x", model: "deepseek-flash")
        let request = try client.makeRequest(system: "sys", user: "hi")
        #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sk-x")
        let json = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(json["stream"] as? Bool == true)
    }

    @Test func customEndpointWithoutKeyHasNoAuthHeader() throws {
        let request = try OpenAICompatibleClient(baseURL: "http://localhost:11434/v1", apiKey: nil, model: "llama3")
            .makeRequest(system: "s", user: "u")
        #expect(request.value(forHTTPHeaderField: "authorization") == nil)
        #expect(throws: AIError.badURL) {
            try OpenAICompatibleClient(baseURL: "not a url", apiKey: nil, model: "m").makeRequest(system: "s", user: "u")
        }
    }

    @Test func claudeCodeStreamJSON() {
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Guten"}}}"#
        #expect(ClaudeCodeCLIClient.parse(line: delta) == .delta("Guten"))
        let error = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#
        #expect(ClaudeCodeCLIClient.parse(line: error) == .result(isError: true, text: "Not logged in · Please run /login"))
        let message = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hallo"}]}}"#
        #expect(ClaudeCodeCLIClient.parse(line: message) == .message("Hallo"))
    }

    @Test func claudeCodeArgumentsDisableToolsAndSessions() {
        let args = ClaudeCodeCLIClient(model: "sonnet").arguments(system: "S")
        #expect(args.contains("-p"))
        #expect(args.firstIndex(of: "--tools").map { args[$0 + 1] } == "")
        #expect(args.contains("--no-session-persistence"))
        #expect(args.firstIndex(of: "--model").map { args[$0 + 1] } == "sonnet")
    }

    @Test func providersNeedingKeysFailFastWithoutOne() {
        // The debug keychain has no DeepSeek key in CI/test runs.
        if AIProviderKind.deepSeek.apiKey == nil {
            #expect(throws: AIError.missingAPIKey(.deepSeek)) {
                _ = try AIClientFactory.make(provider: .deepSeek, model: "deepseek-flash", customBaseURL: "")
            }
        }
        #expect(throws: AIError.missingModel) {
            _ = try AIClientFactory.make(provider: .custom, model: " ", customBaseURL: "http://localhost:1/v1")
        }
    }
}

@MainActor
struct QuickSlotTests {
    let store: ClipStore
    let snippets: SnippetStore
    let secrets: SecretStore
    let slots: QuickSlots
    let defaults: UserDefaults
    let container: ModelContainer   // ModelContext doesn't retain its container

    init() throws {
        let schema = AppEnvironment.schema
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        store = ClipStore(context: container.mainContext,
                          blobs: BlobStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))
        snippets = SnippetStore(context: container.mainContext)
        defaults = try #require(UserDefaults(suiteName: "Clipboard2Tests-\(UUID().uuidString)"))
        secrets = SecretStore(prefs: Preferences(defaults: defaults))
        slots = QuickSlots(defaults: defaults, store: store, snippets: snippets, secrets: secrets)
    }

    @Test func assigningAClipPinsItAndResolves() {
        let item = store.ingest(.text("db password"))
        slots.assign(.clip(item), to: 1)
        #expect(item.isPinned)
        #expect(slots.entry(for: 1)?.id == PanelEntry.clip(item).id)
        #expect(slots.slot(for: .clip(item.id)) == 1)
    }

    @Test func reassigningMovesTheItemToTheNewSlot() {
        let item = store.ingest(.text("x"))
        slots.assign(.clip(item), to: 1)
        slots.assign(.clip(item), to: 4)
        #expect(slots.target(for: 1) == nil)
        #expect(slots.slot(for: .clip(item.id)) == 4)
    }

    @Test func deletedItemsDropOutOfTheirSlot() {
        let item = store.ingest(.text("gone"))
        slots.assign(.clip(item), to: 2)
        store.delete(item)
        #expect(slots.entry(for: 2) == nil)
        #expect(slots.target(for: 2) == nil)
    }

    @Test func assignmentsPersist() {
        let snippet = snippets.create(name: "sig", body: "Best, R")
        slots.assign(.snippet(snippet), to: 9)
        let reloaded = QuickSlots(defaults: defaults, store: store, snippets: snippets, secrets: secrets)
        #expect(reloaded.target(for: 9) == .snippet(snippet.id))
    }

    @Test func outOfRangeSlotsAreIgnored() {
        let item = store.ingest(.text("y"))
        slots.assign(.clip(item), to: 10)
        #expect(slots.slot(for: .clip(item.id)) == nil)
    }
}

struct SecretVaultTests {
    @Test func keychainRoundTrip() throws {
        let ref = try #require(SecretVault.add(name: "Clipboard2 test secret", value: "hunter2"))
        defer { SecretVault.delete(id: ref.id) }

        #expect(SecretVault.value(id: ref.id) == "hunter2")
        #expect(SecretVault.list().contains { $0.id == ref.id && $0.name == "Clipboard2 test secret" })

        SecretVault.update(id: ref.id, name: "Renamed", value: "correct horse")
        #expect(SecretVault.value(id: ref.id) == "correct horse")
        #expect(SecretVault.list().first { $0.id == ref.id }?.name == "Renamed")

        SecretVault.delete(id: ref.id)
        #expect(SecretVault.value(id: ref.id) == nil)
    }
}

struct ClaudeAccountTests {
    @Test func parsesSignedOutStatus() {
        let json = #"{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}"#
        #expect(SubscriptionCLI.claude.parseStatus(json) == .signedOut)
    }

    @Test func parsesSignedInStatusWithEmailAndNoise() {
        let output = "warning: something\n{\"loggedIn\": true, \"authMethod\": \"claudeai\", \"email\": \"admin@softmaze.at\"}\n"
        #expect(SubscriptionCLI.claude.parseStatus(output) == .signedIn(account: "admin@softmaze.at"))
    }

    @Test func garbageIsNotAStatus() {
        #expect(SubscriptionCLI.claude.parseStatus("command not found") == nil)
    }

    @Test func extractsHTTPSLoginURL() {
        let line = "Browser didn't open? Use: https://claude.ai/oauth/authorize?code=true&client_id=x"
        #expect(SubscriptionAccount.firstURL(in: line)?.host() == "claude.ai")
        #expect(SubscriptionAccount.firstURL(in: "no url here") == nil)
    }

    @Test func extractsTheFullClaudeCodeSignInURL() throws {
        let line = "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile&code_challenge=9shm&code_challenge_method=S256&state=YG85\n"
        let url = try #require(SubscriptionAccount.firstURL(in: line))
        #expect(url.absoluteString.hasSuffix("state=YG85"))
        #expect(url.absoluteString.contains("redirect_uri=https%3A%2F%2Fplatform.claude.com"))
    }

    @Test func notLoggedInMapsToSignInError() {
        #expect(AIError.notSignedIn.needsSettings)
    }
}

struct PreferenceMigrationTests {
    @Test func legacyDaysBecomeMinutes() throws {
        let defaults = try #require(UserDefaults(suiteName: "Clipboard2Prefs-\(UUID().uuidString)"))
        defaults.set(7, forKey: Preferences.Key.maxAgeDays)
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.maxAgeMinutes == 7 * 1_440)
        #expect(prefs.maxAge == TimeInterval(7 * 86_400))
    }

    @Test func defaultsAreThirtyDaysAnd500Items() throws {
        let prefs = Preferences(defaults: try #require(UserDefaults(suiteName: "Clipboard2Prefs-\(UUID().uuidString)")))
        #expect(prefs.maxAgeMinutes == 43_200)
        #expect(prefs.maxItems == 500)
    }

    @Test func ageDescriptions() {
        #expect(Preferences.describeAge(minutes: 15) == "15 minutes")
        #expect(Preferences.describeAge(minutes: 60) == "1 hour")
        #expect(Preferences.describeAge(minutes: 480) == "8 hours")
        #expect(Preferences.describeAge(minutes: 1_440) == "1 day")
        #expect(Preferences.describeAge(minutes: 43_200) == "30 days")
        #expect(Preferences.describeAge(minutes: 0) == "Never")
    }
}

struct UnlockDurationTests {
    @Test func durationsMatchMenu() {
        #expect(UnlockDuration.allCases.map(\.title) == ["15 Minutes", "1 Hour", "8 Hours", "1 Day", "1 Week"])
        #expect(UnlockDuration.oneWeek.interval == 7 * 86_400)
    }

    @MainActor @Test func lockClearsManualUnlock() throws {
        let secrets = SecretStore(prefs: Preferences(defaults: try #require(UserDefaults(suiteName: "Clipboard2Unlock-\(UUID())"))))
        #expect(!secrets.isManuallyUnlocked)
        secrets.lock()
        #expect(!secrets.isUnlocked)
    }
}

struct ModelCatalogTests {
    @MainActor @Test func claudeSubscriptionListsAliasesAndKeepsCurrent() {
        let catalog = AIModelCatalog()
        #expect(catalog.models(for: .claudeCode, current: "sonnet") == ["sonnet", "opus", "haiku"])
        #expect(catalog.models(for: .claudeCode, current: "claude-opus-5-5").first == "claude-opus-5-5")
        #expect(AIModelCatalog.displayName("opus") == "Opus")
    }

    @Test func openAIListDropsNonChatModels() {
        let ids = ["gpt-5.6", "text-embedding-3-large", "whisper-1", "gpt-5.6-luna", "dall-e-3", "tts-1"]
        #expect(AIModelCatalog.relevant(ids, for: .openAI) == ["gpt-5.6", "gpt-5.6-luna"])
        #expect(AIModelCatalog.relevant(ids, for: .openRouter) == ids)
    }
}

struct APIKeyDetectorTests {
    @Test(arguments: [
        ("sk-ant-api03-abc", AIProviderKind.anthropic as AIProviderKind?),
        ("sk-or-v1-abc", .openRouter),
        ("AIzaSyD-abc", .gemini),
        ("gsk_abc", .groq),
        ("xai-abc", .xai),
        ("sk-proj-abc", .openAI),
        ("sk-" + String(repeating: "0123456789abcdef", count: 2), .deepSeek),
        ("sk-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuv", .openAI),
        ("Ab3dEfGhIjKlMnOpQrStUvWxYz012345", .mistral),
        ("hello world", nil),
    ])
    func providerFromPrefix(key: String, expected: AIProviderKind?) {
        #expect(APIKeyDetector.provider(for: "  \(key)\n") == expected)
    }

    /// An OpenAI key whose check fails is never offered to DeepSeek (or anyone else).
    @Test func identifyOnlyAsksTheMatchingProvider() async {
        let asked = AskedProviders()
        let openAIKey = "sk-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuv"
        let rejected = await APIKeyDetector.identify(openAIKey) { provider, _ in
            await asked.add(provider)
            return false
        }
        #expect(rejected == nil)
        #expect(await asked.all == [.openAI])

        let deepSeekKey = "sk-" + String(repeating: "0123456789abcdef", count: 2)
        let accepted = await APIKeyDetector.identify(deepSeekKey) { provider, _ in
            await asked.add(provider)
            return true
        }
        #expect(accepted == .deepSeek)
        #expect(await asked.all == [.openAI, .deepSeek])

        let unknown = await APIKeyDetector.identify("hello world") { provider, _ in
            await asked.add(provider)
            return true
        }
        #expect(unknown == nil)
        #expect(await asked.all.count == 2)
    }

    @Test func preferredModelUsesHints() {
        let models = ["gemini-embedding-001", "gemini-3-pro", "gemini-3-flash"]
        #expect(AIModelLister.preferredModel(from: models, for: .gemini) == "gemini-3-flash")
        #expect(AIModelLister.preferredModel(from: ["a", "b"], for: .custom) == "a")
    }

    @Test func everyAPIProviderBuildsAClient() throws {
        for provider in AIProviderKind.apiProviders where provider != .anthropic {
            let url = URL(string: provider == .custom ? "http://localhost:11434/v1" : provider.defaultBaseURL)
            #expect(url != nil, "\(provider)")
        }
        #expect(!AIProviderKind.apiProviders.contains(.claudeCode))
    }
}

struct ContextMenuTests {
    @Test func onlyTheChosenModifierAloneTriggers() {
        #expect(ContextMenuController.matches(.maskCommand, .command))
        #expect(!ContextMenuController.matches([], .command))                          // plain right-click
        #expect(!ContextMenuController.matches([.maskCommand, .maskShift], .command))   // other combos untouched
        #expect(ContextMenuController.matches([.maskAlternate, .maskNonCoalesced], .option))
        #expect(!ContextMenuController.matches(.maskCommand, .option))
    }
}


struct CodexProviderTests {
    @Test func parsesCodexStatus() {
        #expect(SubscriptionCLI.codex.parseStatus("Logged in using ChatGPT\n") == .signedIn(account: "ChatGPT account"))
        #expect(SubscriptionCLI.codex.parseStatus("Not logged in") == .signedOut)
        #expect(SubscriptionCLI.codex.parseStatus("boom") == nil)
    }

    @Test func parsesCodexExecEvents() {
        let message = #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Guten Morgen"}}"#
        #expect(CodexCLIClient.parse(line: message) == .message("Guten Morgen"))
        let warning = #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata not found"}}"#
        #expect(CodexCLIClient.parse(line: warning) == .other)
        let failed = #"{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'x' model is not supported\"}}"}}"#
        #expect(CodexCLIClient.parse(line: failed) == .failure("The 'x' model is not supported"))
    }

    @Test func execArgumentsAreSandboxedAndIgnoreUserConfig() {
        let args = CodexCLIClient(model: "gpt-5.5").arguments()
        #expect(args.first == "exec")
        #expect(args.contains("--ephemeral") && args.contains("--ignore-user-config"))
        #expect(args.firstIndex(of: "--sandbox").map { args[$0 + 1] } == "read-only")
        #expect(args.last == "-")
    }

    /// Clipboard text is untrusted: Codex must not be able to run commands (which could read ~/.ssh).
    @Test func execArgumentsTurnOffCommandExecution() {
        let args = CodexCLIClient(model: "").arguments()
        let disabled = args.indices.filter { args[$0] == "--disable" }.map { args[$0 + 1] }
        #expect(Set(disabled).isSuperset(of: ["shell_tool", "unified_exec"]))
        let overrides = args.indices.filter { args[$0] == "-c" }.map { args[$0 + 1] }
        #expect(overrides.contains("features.computer_use=false"))
        #expect(!args.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(!args.contains("danger-full-access") && !args.contains("workspace-write"))
    }

    @Test func subscriptionProvidersAreNotAPIProviders() {
        #expect(!AIProviderKind.apiProviders.contains(.chatGPT))
        #expect(AIProviderKind.chatGPT.isSubscription && !AIProviderKind.chatGPT.requiresAPIKey)
    }
}

struct ImageAndSignInTests {
    private var image: AIImage {
        AIImage(data: Data([1, 2, 3]), mediaType: "image/png", fileURL: URL(fileURLWithPath: "/tmp/x.png"))
    }

    @Test func claudeRequestPutsImageBlockBeforeText() throws {
        let request = try ClaudeClient(apiKey: "k", model: "claude-sonnet-5-5").makeRequest(system: "s", user: "what is this?", image: image)
        let json = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let content = try #require((json["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        #expect((content[0]["source"] as? [String: String])?["data"] == "AQID")
    }

    @Test func openAIRequestUsesDataURL() throws {
        let request = try OpenAICompatibleClient(baseURL: "https://api.openai.com/v1", apiKey: "k", model: "m")
            .makeRequest(system: "s", user: "u", image: image)
        let json = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let content = try #require((json["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        #expect((content[1]["image_url"] as? [String: String])?["url"] == "data:image/png;base64,AQID")
    }

    @Test func cliClientsPassImages() throws {
        #expect(ClaudeCodeCLIClient(model: "").arguments(system: "S", jsonInput: true).suffix(2) == ["--input-format", "stream-json"])
        let line = ClaudeCodeCLIClient.jsonInput(user: "u", image: image)
        #expect(line.last == 0x0A)
        let json = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        #expect(json["type"] as? String == "user")
        let args = CodexCLIClient(model: "").arguments(image: URL(fileURLWithPath: "/tmp/x.png"))
        #expect(args.suffix(3) == ["-i", "/tmp/x.png", "-"])
    }

    @Test func imageActionsAndPrompts() {
        #expect(!AIAction.fixGrammar.worksOnImages && AIAction.explain.worksOnImages)
        #expect(AIAction.instruction("what is this?").imageSystemPrompt.contains("what is this?"))
        #expect(!AIAction.explain.imageSystemPrompt.contains("<text>"))
    }

    @Test func browserShimRecordsOnlyLinks() throws {
        let shim = try #require(BrowserShim.prepare())
        var env: [String: String] = ["PATH": "/usr/bin:/bin"]
        BrowserShim.apply(shim, to: &env)
        #expect(env["PATH"]?.hasPrefix(shim.directory.path + ":") == true)
        let process = Process()
        process.executableURL = shim.directory.appending(path: "open")
        process.arguments = ["-a", "Safari", "https://claude.com/x?redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcallback"]
        process.environment = env
        try process.run()
        process.waitUntilExit()
        let text = try String(contentsOf: shim.urlFile, encoding: .utf8)
        #expect(text == "https://claude.com/x?redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcallback\n")
    }
}

private actor AskedProviders {
    private(set) var all: [AIProviderKind] = []
    func add(_ provider: AIProviderKind) { all.append(provider) }
}
