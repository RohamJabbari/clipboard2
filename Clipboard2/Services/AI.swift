import Foundation
import ImageIO
import Security
import Observation

// MARK: - Keychain

/// API keys live only in the login keychain, never in UserDefaults or files.
nonisolated enum Keychain {
    static let service = (Bundle.main.bundleIdentifier ?? "at.softmaze.Clippy") + ".anthropic"

    static func read(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    static func save(_ value: String, account: String, label: String) -> Bool {
        delete(account: account)
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrLabel: label,
            kSecValueData: Data(value.utf8),
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Providers

nonisolated enum AIProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case claudeCode
    case chatGPT
    case anthropic
    case openAI
    case gemini
    case deepSeek
    case groq
    case xai
    case mistral
    case openRouter
    case custom

    var id: String { rawValue }

    /// Every provider reached with an API key (everything except the Claude subscription).
    static let apiProviders: [AIProviderKind] = allCases.filter { !$0.isSubscription }

    /// Signed in with a consumer plan through the vendor's own CLI, rather than an API key.
    var isSubscription: Bool { self == .claudeCode || self == .chatGPT }

    var title: String {
        switch self {
        case .claudeCode: "Claude — sign in with your account"
        case .chatGPT: "ChatGPT — sign in with your account"
        case .anthropic: "Anthropic (Claude)"
        case .openAI: "OpenAI (GPT)"
        case .gemini: "Google Gemini"
        case .deepSeek: "DeepSeek"
        case .groq: "Groq"
        case .xai: "xAI (Grok)"
        case .mistral: "Mistral"
        case .openRouter: "OpenRouter"
        case .custom: "Custom endpoint (OpenAI-compatible)"
        }
    }

    var shortName: String {
        switch self {
        case .anthropic, .claudeCode: "Claude"
        case .openAI, .chatGPT: "GPT"
        case .gemini: "Gemini"
        case .deepSeek: "DeepSeek"
        case .groq: "Groq"
        case .xai: "Grok"
        case .mistral: "Mistral"
        case .openRouter: "OpenRouter"
        case .custom: "AI"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: "https://api.anthropic.com/v1"
        case .openAI: "https://api.openai.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepSeek: "https://api.deepseek.com"
        case .groq: "https://api.groq.com/openai/v1"
        case .xai: "https://api.x.ai/v1"
        case .mistral: "https://api.mistral.ai/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .custom: "http://localhost:11434/v1"
        case .claudeCode, .chatGPT: ""
        }
    }

    /// Empty means "pick from the provider's live model list".
    var defaultModel: String {
        switch self {
        case .anthropic: "claude-sonnet-5-5"
        case .openAI: "gpt-5.6"
        case .deepSeek: "deepseek-flash"
        case .openRouter: "openrouter/auto"
        case .claudeCode: "sonnet"
        case .chatGPT: "gpt-5.5"
        case .gemini, .groq, .xai, .mistral, .custom: ""
        }
    }

    /// Substrings preferred when picking a default from a fetched model list.
    var preferredModelHints: [String] {
        switch self {
        case .gemini: ["flash", "pro"]
        case .groq: ["llama", "qwen"]
        case .xai: ["grok"]
        case .mistral: ["mistral-medium-latest", "mistral-small-latest", "latest"]
        default: []
        }
    }

    /// Custom endpoints (Ollama, LM Studio, …) often run without a key.
    var requiresAPIKey: Bool {
        switch self {
        case .custom, .claudeCode, .chatGPT: false
        default: true
        }
    }

    var usesAPIKey: Bool { !isSubscription }
    var hasEditableBaseURL: Bool { self == .custom }

    var keychainAccount: String {
        self == .anthropic ? "api-key" : "api-key-\(rawValue)"
    }

    var apiKey: String? { Keychain.read(account: keychainAccount) }
}

/// Works out which provider an API key belongs to: prefix first, then a live check.
nonisolated enum APIKeyDetector {
    /// Providers to try, most likely first. Empty means the key format is unknown.
    static func candidates(for rawKey: String) -> [AIProviderKind] {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("sk-ant-") { return [.anthropic] }
        if key.hasPrefix("sk-or-") { return [.openRouter] }
        if key.hasPrefix("AIza") { return [.gemini] }
        if key.hasPrefix("gsk_") { return [.groq] }
        if key.hasPrefix("xai-") { return [.xai] }
        if key.hasPrefix("sk-proj-") || key.hasPrefix("sk-svcacct-") || key.hasPrefix("sk-admin-") { return [.openAI] }
        if key.hasPrefix("sk-") {
            // DeepSeek keys are "sk-" + 32 hex characters; OpenAI's legacy keys are longer.
            let body = key.dropFirst(3)
            let isHex32 = body.count == 32 && body.allSatisfy(\.isHexDigit)
            return isHex32 ? [.deepSeek, .openAI] : [.openAI, .deepSeek]
        }
        if key.count == 32, key.allSatisfy({ $0.isLetter || $0.isNumber }) { return [.mistral] }
        return []
    }

    /// Returns the first candidate whose `/models` endpoint accepts the key.
    static func identify(_ key: String) async -> AIProviderKind? {
        for provider in candidates(for: key) {
            if (try? await AIModelLister.fetch(provider: provider, customBaseURL: "", apiKey: key)) != nil {
                return provider
            }
        }
        return nil
    }
}

// MARK: - Actions

nonisolated enum AIAction: Hashable, Identifiable, Sendable {
    case translate(language: String)
    case summarize
    case fixGrammar
    case explain
    case custom(CustomPrompt)
    /// Free-form instruction typed into the ⌘K filter.
    case instruction(String)

    static let builtIn: [AIAction] = [
        .translate(language: "English"),
        .translate(language: "German"),
        .translate(language: "Farsi"),
        .summarize,
        .fixGrammar,
        .explain,
    ]

    var id: String {
        switch self {
        case .translate(let language): "translate-\(language)"
        case .summarize: "summarize"
        case .fixGrammar: "fixGrammar"
        case .explain: "explain"
        case .custom(let prompt): "custom-\(prompt.id.uuidString)"
        case .instruction(let text): "instruction-\(text)"
        }
    }

    var title: String {
        switch self {
        case .translate(let language): "Translate to \(language)"
        case .summarize: "Summarize"
        case .fixGrammar: "Fix Grammar"
        case .explain: "Explain"
        case .custom(let prompt): prompt.name.isEmpty ? "Custom Prompt" : prompt.name
        case .instruction(let text): text
        }
    }

    var symbol: String {
        switch self {
        case .translate: "character.bubble"
        case .summarize: "text.line.first.and.arrowtriangle.forward"
        case .fixGrammar: "checkmark.seal"
        case .explain: "questionmark.bubble"
        case .custom, .instruction: "sparkles"
        }
    }

    var systemPrompt: String {
        let suffix = "The input is the text inside the <text> tags. Reply with the result only — no preamble, quotes or commentary."
        switch self {
        case .translate(let language):
            return "Translate the input into \(language). Preserve meaning, tone, formatting and line breaks. \(suffix)"
        case .summarize:
            return "Summarize the input concisely in the same language as the input. \(suffix)"
        case .fixGrammar:
            return "Correct grammar, spelling and punctuation in the input. Keep its language, meaning, tone and formatting unchanged otherwise. \(suffix)"
        case .explain:
            return "Explain the input clearly and concisely for a smart reader. If it is code, explain what it does. Answer in the language of the input unless it is code. The input is the text inside the <text> tags."
        case .custom(let prompt):
            return "\(prompt.prompt)\n\n\(suffix)"
        case .instruction(let text):
            return "Do the following with the input: \(text)\n\nIf it asks a question about the input, answer it concisely. Otherwise reply with the resulting text only — no preamble, quotes or commentary. The input is the text inside the <text> tags."
        }
    }

    static func userMessage(for input: String) -> String {
        "<text>\n\(input)\n</text>"
    }

    /// Actions that make sense for an image (Fix Grammar needs editable text).
    var worksOnImages: Bool {
        if case .fixGrammar = self { return false }
        return true
    }

    /// Same instructions, but the input is an attached image instead of `<text>`.
    var imageSystemPrompt: String {
        let suffix = "The input is the attached image."
        switch self {
        case .translate(let language):
            return "Translate all text in the image into \(language), keeping its structure and line breaks. Reply with the translation only. \(suffix)"
        case .summarize:
            return "Summarize what the image shows and the text in it, concisely. \(suffix)"
        case .fixGrammar:
            return "Transcribe the text in the image with grammar, spelling and punctuation corrected. Reply with the text only. \(suffix)"
        case .explain:
            return "Explain what the image shows, clearly and concisely for a smart reader. If it contains code, an error message, a chart or a document, explain that content. \(suffix)"
        case .custom(let prompt):
            return "\(prompt.prompt)\n\n\(suffix) Reply with the result only — no preamble."
        case .instruction(let text):
            return "Do the following with the image: \(text)\n\nIf it asks a question, answer it concisely. \(suffix)"
        }
    }

    static let imageUserMessage = "Here is the image."
}

/// An image sent along with the prompt (screenshots, copied pictures), downscaled for the model.
nonisolated struct AIImage: Sendable, Hashable {
    var data: Data
    var mediaType: String
    /// The same bytes on disk, for CLIs that take a file path.
    var fileURL: URL

    var base64: String { data.base64EncodedString() }

    /// Longest edge the vision models use anyway; bigger only costs tokens and upload time.
    static let maxPixelSize = 1_568

    static func load(from url: URL) -> AIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary)
        else { return nil }
        // PNG keeps screenshot text crisp; fall back to JPEG for large photos (APIs cap at ~5 MB).
        var encoded = encode(image, type: "public.png", options: [:])
        var mediaType = "image/png"
        if (encoded?.count ?? .max) > 3_500_000 {
            encoded = encode(image, type: "public.jpeg", options: [kCGImageDestinationLossyCompressionQuality: 0.85])
            mediaType = "image/jpeg"
        }
        guard let encoded else { return nil }
        let dir = FileManager.default.temporaryDirectory.appending(path: "clippy-cli", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "image-\(UUID().uuidString).\(mediaType == "image/png" ? "png" : "jpg")")
        guard (try? encoded.write(to: file)) != nil else { return nil }
        return AIImage(data: encoded, mediaType: mediaType, fileURL: file)
    }

    private static func encode(_ image: CGImage, type: String, options: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

// MARK: - Errors & SSE

nonisolated enum AIError: LocalizedError, Equatable {
    case missingAPIKey(AIProviderKind)
    case missingModel
    case badURL
    case http(status: Int, message: String)
    case api(String)
    case refusal
    case invalidResponse
    case cliNotFound
    case notSignedIn
    case codexNotFound

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider): "Add your \(provider.title) API key in Settings → AI."
        case .missingModel: "Choose a model in Settings → AI."
        case .badURL: "The base URL in Settings → AI isn't valid."
        case .http(let status, let message): "Request failed (\(status)): \(message)"
        case .api(let message): message
        case .refusal: "The model declined this request."
        case .invalidResponse: "Unexpected response from the API."
        case .cliNotFound: "Claude isn't set up yet. Open Settings → AI to install it and sign in."
        case .notSignedIn: "Sign in with your account in Settings → AI."
        case .codexNotFound: "ChatGPT isn't set up yet. Open Settings → AI to install it and sign in."
        }
    }

    var needsSettings: Bool {
        switch self {
        case .missingAPIKey, .missingModel, .badURL, .cliNotFound, .notSignedIn, .codexNotFound: true
        default: false
        }
    }
}

nonisolated enum SSEEvent: Equatable, Sendable {
    case textDelta(String)
    case stop(reason: String?)
    case error(String)
    case done
    case other
}

nonisolated enum SSEParser {
    private static func json(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Anthropic Messages API stream (`content_block_delta`, `message_delta`, `error`).
    static func parse(line: String) -> SSEEvent? {
        guard let json = json(line), let type = json["type"] as? String else { return nil }
        switch type {
        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                return .textDelta(text)
            }
            return .other
        case "message_delta":
            let delta = json["delta"] as? [String: Any]
            return .stop(reason: delta?["stop_reason"] as? String)
        case "error":
            let error = json["error"] as? [String: Any]
            return .error(error?["message"] as? String ?? "Unknown API error")
        default:
            return .other
        }
    }

    /// OpenAI-style Chat Completions stream (`choices[].delta.content`, `[DONE]`).
    static func parseOpenAI(line: String) -> SSEEvent? {
        guard line.hasPrefix("data:") else { return nil }
        if line.dropFirst(5).trimmingCharacters(in: .whitespaces) == "[DONE]" { return .done }
        guard let json = json(line) else { return nil }
        if let error = json["error"] as? [String: Any] {
            return .error(error["message"] as? String ?? "Unknown API error")
        }
        guard let choice = (json["choices"] as? [[String: Any]])?.first else { return .other }
        if let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty {
            return .textDelta(text)
        }
        if let reason = choice["finish_reason"] as? String {
            return .stop(reason: reason)
        }
        return .other
    }

    static func errorMessage(fromBody data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = json["error"] as? String { return message }
            if let message = json["message"] as? String { return message }
        }
        return String(data: data.prefix(500), encoding: .utf8) ?? "No details"
    }
}

// MARK: - Clients

nonisolated protocol AIStreamingClient: Sendable {
    func stream(system: String, user: String, image: AIImage?) -> AsyncThrowingStream<String, Error>
}

extension AIStreamingClient {
    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        stream(system: system, user: user, image: nil)
    }
}

nonisolated enum HTTPStreaming {
    /// Runs a streaming request and feeds each line to `handle`, which yields text or throws.
    static func stream(
        _ request: @escaping @Sendable () throws -> URLRequest,
        session: URLSession,
        handle: @escaping @Sendable (String, AsyncThrowingStream<String, Error>.Continuation) throws -> Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: try request())
                    guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 65_536 { break }
                        }
                        throw AIError.http(status: http.statusCode, message: SSEParser.errorMessage(fromBody: body))
                    }
                    for try await line in bytes.lines {
                        if try handle(line, continuation) == false { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

nonisolated struct ClaudeClient: AIStreamingClient {
    var apiKey: String
    var model: String
    var session: URLSession = .shared

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// Models that accept server-side refusal fallbacks with `fallbacks: "default"`.
    static let fallbackModels: Set<String> = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-opus-5", "claude-fable-5-1"]
    /// Model families that accept `output_config.effort`.
    static let effortPrefixes = ["claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-sonnet-5", "claude-haiku-5",
                                 "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6"]

    func makeRequest(system: String, user: String, image: AIImage? = nil, maxTokens: Int = 8_192) throws -> URLRequest {
        guard let endpoint = Self.endpoint else { throw AIError.badURL }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": [["role": "user", "content": Self.content(user: user, image: image)]],
        ]
        if Self.effortPrefixes.contains(where: model.hasPrefix) {
            body["output_config"] = ["effort": "low"]
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if Self.fallbackModels.contains(model) {
            body["fallbacks"] = "default"
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Plain string for text; image block first, then the text, when there's an image.
    static func content(user: String, image: AIImage?) -> Any {
        guard let image else { return user }
        return [
            ["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": image.base64]],
            ["type": "text", "text": user],
        ]
    }

    func stream(system: String, user: String, image: AIImage?) -> AsyncThrowingStream<String, Error> {
        HTTPStreaming.stream({ try makeRequest(system: system, user: user, image: image) }, session: session) { line, continuation in
            switch SSEParser.parse(line: line) {
            case .textDelta(let text): continuation.yield(text)
            case .stop(let reason) where reason == "refusal": throw AIError.refusal
            case .error(let message): throw AIError.api(message)
            default: break
            }
            return true
        }
    }
}

/// OpenAI Chat Completions format — also spoken by DeepSeek, OpenRouter, Ollama, LM Studio, Groq, …
nonisolated struct OpenAICompatibleClient: AIStreamingClient {
    var baseURL: String
    var apiKey: String?
    var model: String
    var extraHeaders: [String: String] = [:]
    var session: URLSession = .shared

    func makeRequest(system: String, user: String, image: AIImage? = nil) throws -> URLRequest {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: trimmed + "/chat/completions"), url.scheme?.hasPrefix("http") == true else {
            throw AIError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": Self.content(user: user, image: image)],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func content(user: String, image: AIImage?) -> Any {
        guard let image else { return user }
        return [
            ["type": "text", "text": user],
            ["type": "image_url", "image_url": ["url": "data:\(image.mediaType);base64,\(image.base64)"]],
        ]
    }

    func stream(system: String, user: String, image: AIImage?) -> AsyncThrowingStream<String, Error> {
        HTTPStreaming.stream({ try makeRequest(system: system, user: user, image: image) }, session: session) { line, continuation in
            switch SSEParser.parseOpenAI(line: line) {
            case .textDelta(let text): continuation.yield(text)
            case .stop(let reason) where reason == "content_filter": throw AIError.refusal
            case .error(let message): throw AIError.api(message)
            case .done: return false
            default: break
            }
            return true
        }
    }
}

/// Uses the locally installed Claude Code CLI (`claude -p`), which runs on the user's own
/// Claude subscription login. Slower to start than the API, but no API key or API billing.
nonisolated struct ClaudeCodeCLIClient: AIStreamingClient {
    var model: String

    static let candidatePaths = [
        "~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
    ].map { NSString(string: $0).expandingTildeInPath }

    static var executableURL: URL? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    func arguments(system: String, jsonInput: Bool = false) -> [String] {
        var args = [
            "-p",
            "--system-prompt", system,
            "--tools", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
        ]
        if !model.isEmpty { args += ["--model", model] }
        // Images can only be passed as content blocks, which need stream-json input.
        if jsonInput { args += ["--input-format", "stream-json"] }
        return args
    }

    /// One stream-json user message carrying the image and the text.
    static func jsonInput(user: String, image: AIImage) -> Data {
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": ClaudeClient.content(user: user, image: image)],
        ]
        var data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Parses one stream-json line. Returns text to yield, or throws for errors.
    enum LineEvent: Equatable { case delta(String), message(String), result(isError: Bool, text: String), other }

    static func parse(line: String) -> LineEvent {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return .other }
        switch type {
        case "stream_event":
            if let event = json["event"] as? [String: Any],
               event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                return .delta(text)
            }
            return .other
        case "assistant":
            let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            return text.isEmpty ? .other : .message(text)
        case "result":
            return .result(isError: json["is_error"] as? Bool ?? false, text: json["result"] as? String ?? "")
        default:
            return .other
        }
    }

    func stream(system: String, user: String, image: AIImage?) -> AsyncThrowingStream<String, Error> {
        let arguments = arguments(system: system, jsonInput: image != nil)
        let input = image.map { Self.jsonInput(user: user, image: $0) } ?? Data(user.utf8)
        return AsyncThrowingStream { continuation in
            guard let executable = Self.executableURL else {
                continuation.finish(throwing: AIError.cliNotFound)
                return
            }
            let process = ProcessBox()
            let task = Task {
                do {
                    let (stdout, stdin) = try process.launch(executable: executable, arguments: arguments)
                    stdin.write(input)
                    try? stdin.close()
                    var streamed = false
                    var buffered = ""
                    for try await line in stdout.bytes.lines {
                        switch Self.parse(line: line) {
                        case .delta(let text):
                            streamed = true
                            continuation.yield(text)
                        case .message(let text):
                            buffered += text
                        case .result(let isError, let text):
                            if isError {
                                if text.localizedCaseInsensitiveContains("not logged in")
                                    || text.localizedCaseInsensitiveContains("/login") {
                                    throw AIError.notSignedIn
                                }
                                throw AIError.api(text.isEmpty ? "Claude reported an error." : text)
                            }
                            if !streamed { continuation.yield(buffered.isEmpty ? text : buffered) }
                        case .other:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                process.terminate()
            }
        }
    }
}

/// `Process` isn't Sendable; all access is serialised through this box.
nonisolated final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func launch(executable: URL, arguments: [String], environment: [String: String]? = nil) throws -> (stdout: FileHandle, stdin: FileHandle) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        // An empty working directory keeps project CLAUDE.md files out of the prompt.
        let workdir = FileManager.default.temporaryDirectory.appending(path: "clippy-cli", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        process.currentDirectoryURL = workdir
        let out = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        try process.run()
        lock.withLock { self.process = process }
        return (out.fileHandleForReading, input.fileHandleForWriting)
    }

    static func wrap(_ process: Process) -> ProcessBox {
        let box = ProcessBox()
        box.lock.withLock { box.process = process }
        return box
    }

    func terminate() {
        lock.withLock {
            if process?.isRunning == true { process?.terminate() }
        }
    }
}

/// Uses OpenAI's Codex CLI (`codex exec`), signed in with the user's ChatGPT plan.
nonisolated struct CodexCLIClient: AIStreamingClient {
    var model: String

    /// Codex is usually an npm global (often under nvm), so look in the common places.
    static var executableURL: URL? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var candidates = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          "\(home)/.bun/bin/codex", "\(home)/.volta/bin/codex", "\(home)/.npm-global/bin/codex"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvm) {
            candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(nvm)/\($0)/bin/codex" }
        }
        return candidates.first(where: fm.isExecutableFile).map(URL.init(fileURLWithPath:))
    }

    /// `codex` is a Node script; GUI apps get a minimal PATH, so put its own bin dir (with node) first.
    static func environment(for executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return environment
    }

    func arguments(image: URL? = nil) -> [String] {
        var args = ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only",
                    "--ignore-rules", "--ignore-user-config", "--json"]
        if !model.isEmpty { args += ["-m", model] }
        if let image { args += ["-i", image.path] }
        return args + ["-"]   // prompt from stdin
    }

    enum LineEvent: Equatable { case message(String), failure(String), other }

    static func parse(line: String) -> LineEvent {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return .other }
        switch type {
        case "item.completed":
            let item = json["item"] as? [String: Any]
            guard item?["type"] as? String == "agent_message", let text = item?["text"] as? String else { return .other }
            return .message(text)
        case "turn.failed", "error":
            let raw = (json["error"] as? [String: Any])?["message"] as? String ?? json["message"] as? String ?? "Unknown error"
            return .failure(innerMessage(raw))
        default:
            return .other
        }
    }

    /// Codex wraps API errors as a JSON string; pull out the human-readable message.
    static func innerMessage(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (json["error"] as? [String: Any])?["message"] as? String
        else { return raw }
        return message
    }

    func stream(system: String, user: String, image: AIImage?) -> AsyncThrowingStream<String, Error> {
        let arguments = arguments(image: image?.fileURL)
        let prompt = system + "\n\n" + user
        return AsyncThrowingStream { continuation in
            guard let executable = Self.executableURL else {
                continuation.finish(throwing: AIError.codexNotFound)
                return
            }
            let process = ProcessBox()
            let task = Task {
                do {
                    let (stdout, stdin) = try process.launch(executable: executable, arguments: arguments,
                                                             environment: Self.environment(for: executable))
                    stdin.write(Data(prompt.utf8))
                    try? stdin.close()
                    for try await line in stdout.bytes.lines {
                        switch Self.parse(line: line) {
                        case .message(let text):
                            continuation.yield(text)
                        case .failure(let message):
                            let lower = message.lowercased()
                            if lower.contains("not logged in") || lower.contains("401") || lower.contains("unauthorized") || lower.contains("login") {
                                throw AIError.notSignedIn
                            }
                            throw AIError.api(message)
                        case .other:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                process.terminate()
            }
        }
    }
}

nonisolated enum AIClientFactory {
    static func make(provider: AIProviderKind, model: String, customBaseURL: String) throws -> any AIStreamingClient {
        let model = model.trimmingCharacters(in: .whitespaces)
        if !provider.isSubscription, model.isEmpty { throw AIError.missingModel }
        let key = provider.apiKey
        if provider.requiresAPIKey, key == nil { throw AIError.missingAPIKey(provider) }

        switch provider {
        case .anthropic:
            return ClaudeClient(apiKey: key ?? "", model: model)
        case .openAI, .gemini, .deepSeek, .groq, .xai, .mistral:
            return OpenAICompatibleClient(baseURL: provider.defaultBaseURL, apiKey: key, model: model)
        case .openRouter:
            return OpenAICompatibleClient(baseURL: provider.defaultBaseURL, apiKey: key, model: model,
                                          extraHeaders: ["X-Title": "Clipboard2"])
        case .custom:
            return OpenAICompatibleClient(baseURL: customBaseURL, apiKey: key, model: model)
        case .claudeCode:
            return ClaudeCodeCLIClient(model: model)
        case .chatGPT:
            return CodexCLIClient(model: model)
        }
    }
}

/// Lists models from the provider's `/models` endpoint so IDs never go stale in the app.
nonisolated enum AIModelLister {
    /// `apiKey` overrides the stored key (used while detecting a freshly pasted key).
    static func fetch(provider: AIProviderKind, customBaseURL: String, apiKey: String? = nil) async throws -> [String] {
        if provider == .claudeCode { return ["sonnet", "opus", "haiku"] }
        if provider == .chatGPT { return AIModelCatalog.chatGPTModels() }
        let base = (provider == .custom ? customBaseURL : provider.defaultBaseURL)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/models") else { throw AIError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let key = apiKey ?? provider.apiKey
        if provider.requiresAPIKey, key == nil { throw AIError.missingAPIKey(provider) }
        if provider == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if let key {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIError.http(status: http.statusCode, message: SSEParser.errorMessage(fromBody: data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]]
        else { throw AIError.invalidResponse }
        // Gemini's OpenAI-compatible endpoint prefixes ids with "models/".
        return items.compactMap { ($0["id"] as? String).map { $0.replacingOccurrences(of: "models/", with: "") } }.sorted()
    }

    /// A sensible default when the provider has no fixed default model.
    static func preferredModel(from models: [String], for provider: AIProviderKind) -> String? {
        for hint in provider.preferredModelHints {
            if let match = models.first(where: { $0.contains(hint) }) { return match }
        }
        return models.first
    }
}

// MARK: - Run state

/// One streaming AI request shown in the quick panel's preview pane.
@Observable
final class AIRun {
    let action: AIAction
    let item: ClipItem
    let providerName: String
    private(set) var output = ""
    private(set) var isStreaming = false
    private(set) var error: AIError?
    private(set) var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Set for image items; the prompt then asks about the picture instead of `<text>`.
    let image: AIImage?

    init(action: AIAction, item: ClipItem, providerName: String, image: AIImage? = nil) {
        self.action = action
        self.item = item
        self.providerName = providerName
        self.image = image
    }

    var isFinished: Bool { !isStreaming && errorMessage == nil && !output.isEmpty }

    func start(prefs: Preferences) {
        let client: any AIStreamingClient
        do {
            client = try AIClientFactory.make(provider: prefs.aiProvider, model: prefs.aiModel, customBaseURL: prefs.customBaseURL)
        } catch {
            fail(error)
            return
        }
        let image = self.image
        let system = image == nil ? action.systemPrompt : action.imageSystemPrompt
        let user = image == nil ? AIAction.userMessage(for: item.text) : AIAction.imageUserMessage
        isStreaming = true
        task = Task { [weak self] in
            do {
                for try await chunk in client.stream(system: system, user: user, image: image) {
                    self?.output += chunk
                }
                self?.isStreaming = false
                if self?.output.isEmpty == true { self?.errorMessage = "The model returned an empty response." }
            } catch is CancellationError {
                self?.isStreaming = false
            } catch {
                self?.isStreaming = false
                if (error as? URLError)?.code == .cancelled { return }
                self?.fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        self.error = error as? AIError
        errorMessage = error.localizedDescription
        Log.claude.error("AI request failed: \(error.localizedDescription, privacy: .public)")
    }

    func cancel() {
        task?.cancel()
        task = nil
        isStreaming = false
    }
}

// MARK: - Model catalog

/// Per-provider model lists for the in-panel model menu, fetched once per session.
@Observable
final class AIModelCatalog {
    private(set) var models: [AIProviderKind: [String]] = [:]
    private(set) var loading: Set<AIProviderKind> = []
    private(set) var errors: [AIProviderKind: String] = [:]

    /// Short names the Claude Code CLI accepts.
    nonisolated static let claudeCodeModels = ["sonnet", "opus", "haiku"]

    /// Models a ChatGPT login may use, from Codex's own cache (falls back to the known default).
    nonisolated static func chatGPTModels() -> [String] {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data),
              let list = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["models"] as? [[String: Any]])
        else { return ["gpt-5.5"] }
        let slugs = list.compactMap { ($0["slug"] ?? $0["id"]) as? String }.filter { !$0.contains("review") }
        return slugs.isEmpty ? ["gpt-5.5"] : slugs
    }

    func models(for provider: AIProviderKind, current: String) -> [String] {
        var list = provider == .claudeCode ? Self.claudeCodeModels
            : provider == .chatGPT ? Self.chatGPTModels()
            : (models[provider] ?? [])
        if !current.isEmpty, !list.contains(current) { list.insert(current, at: 0) }
        return list
    }

    func loadIfNeeded(_ provider: AIProviderKind, customBaseURL: String) {
        guard !provider.isSubscription, models[provider] == nil, !loading.contains(provider) else { return }
        loading.insert(provider)
        Task {
            do {
                let fetched = try await AIModelLister.fetch(provider: provider, customBaseURL: customBaseURL)
                models[provider] = Self.relevant(fetched, for: provider)
                errors[provider] = nil
            } catch {
                errors[provider] = error.localizedDescription
            }
            loading.remove(provider)
        }
    }

    func reload(_ provider: AIProviderKind, customBaseURL: String) {
        models[provider] = nil
        loadIfNeeded(provider, customBaseURL: customBaseURL)
    }

    /// OpenAI's /models also lists embeddings, audio, image and moderation models; keep chat ones.
    nonisolated static func relevant(_ ids: [String], for provider: AIProviderKind) -> [String] {
        guard provider == .openAI else { return ids }
        let excluded = ["embedding", "whisper", "tts", "dall-e", "image", "audio", "moderation", "realtime",
                        "transcribe", "search", "davinci", "babbage", "sora"]
        return ids.filter { id in !excluded.contains { id.contains($0) } }
    }

    nonisolated static func displayName(_ model: String) -> String {
        claudeCodeModels.contains(model) ? model.capitalized : model
    }
}
