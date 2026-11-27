import AppKit
import AuthenticationServices
import CryptoKit
import Network

// Signing in to Microsoft and Google for email codes: OAuth 2 authorization code + PKCE in the
// system sign-in sheet (ASWebAuthenticationSession), redirected to a loopback port this app
// listens on for that one request. Tokens are refreshed; nothing here touches the Keychain.

// MARK: - Client ids

/// The app's OAuth clients, from `OAuthClients.plist` (filled in by the owner; see
/// docs/features/auth-autofill.md → Phase 4). An empty id hides that provider.
nonisolated struct OAuthClients: Equatable, Sendable {
    var microsoftClientID: String
    var googleClientID: String
    /// Google's desktop clients have a "secret" that isn't one (it ships in every copy of the app).
    var googleClientSecret: String

    init(microsoftClientID: String = "", googleClientID: String = "", googleClientSecret: String = "") {
        self.microsoftClientID = microsoftClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.googleClientID = googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.googleClientSecret = googleClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(dictionary: [String: Any]) {
        self.init(microsoftClientID: dictionary["MicrosoftClientID"] as? String ?? "",
                  googleClientID: dictionary["GoogleClientID"] as? String ?? "",
                  googleClientSecret: dictionary["GoogleClientSecret"] as? String ?? "")
    }

    static let bundled: OAuthClients = {
        func load(_ name: String) -> [String: Any] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "plist") else { return [:] }
            return NSDictionary(contentsOf: url) as? [String: Any] ?? [:]
        }
        // OAuthSecrets.plist is gitignored (the repo is public); its non-empty values win.
        let secrets = load("OAuthSecrets").filter { ($0.value as? String)?.isEmpty == false }
        return OAuthClients(dictionary: load("OAuthClients").merging(secrets) { _, secret in secret })
    }()

    func clientID(for provider: EmailProvider) -> String {
        switch provider {
        case .microsoft: microsoftClientID
        case .google: googleClientID
        case .imap: ""
        }
    }

    /// The providers Settings offers: IMAP always, the others once their client id is set.
    var availableProviders: [EmailProvider] {
        EmailProvider.allCases.filter { $0 == .imap || !clientID(for: $0).isEmpty }
    }
}

// MARK: - Providers

nonisolated enum EmailProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case microsoft, google, imap
    var id: String { rawValue }

    var title: String {
        switch self {
        case .microsoft: "Microsoft"
        case .google: "Google"
        case .imap: "Other (IMAP)"
        }
    }

    var symbol: String {
        switch self {
        case .microsoft: "envelope.badge.shield.half.filled"
        case .google: "envelope.badge"
        case .imap: "envelope"
        }
    }
}

/// Where and how each provider signs in.
nonisolated struct OAuthEndpoints: Equatable, Sendable {
    var authorize: URL
    var token: URL
    var scopes: [String]
    /// The loopback host in the redirect ("localhost" for Microsoft, "127.0.0.1" for Google).
    var redirectHost: String
    var extraAuthorizeParameters: [(String, String)]

    static func == (a: OAuthEndpoints, b: OAuthEndpoints) -> Bool {
        a.authorize == b.authorize && a.token == b.token && a.scopes == b.scopes && a.redirectHost == b.redirectHost
    }

    static func of(_ provider: EmailProvider) -> OAuthEndpoints? {
        switch provider {
        case .microsoft:
            // "common": personal (Outlook.com, Hotmail) and work or school accounts.
            OAuthEndpoints(authorize: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
                           token: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
                           scopes: ["openid", "email", "offline_access", "https://graph.microsoft.com/Mail.Read"],
                           redirectHost: "localhost",
                           extraAuthorizeParameters: [("prompt", "select_account")])
        case .google:
            // access_type=offline for a refresh token; prompt=consent so one comes on every sign-in.
            OAuthEndpoints(authorize: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                           token: URL(string: "https://oauth2.googleapis.com/token")!,
                           scopes: ["openid", "email", "https://www.googleapis.com/auth/gmail.readonly"],
                           redirectHost: "127.0.0.1",
                           extraAuthorizeParameters: [("access_type", "offline"), ("prompt", "consent")])
        case .imap:
            nil
        }
    }

    static let gmailReadOnly = "https://www.googleapis.com/auth/gmail.readonly"

    /// Continue with Google (docs/features/passwordless.md): `openid email` for the ID token that
    /// verifies the address, plus Gmail read-only when offered. Google shows a checkbox per scope
    /// (granular consent), so the user may decline Gmail and still sign in; `include_granted_scopes`
    /// keeps scopes granted earlier (incremental auth).
    static func googleIdentity(offerGmail: Bool) -> OAuthEndpoints {
        OAuthEndpoints(authorize: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                       token: URL(string: "https://oauth2.googleapis.com/token")!,
                       scopes: ["openid", "email"] + (offerGmail ? [gmailReadOnly] : []),
                       redirectHost: "127.0.0.1",
                       extraAuthorizeParameters: [("access_type", "offline"), ("prompt", "consent"),
                                                  ("include_granted_scopes", "true")])
    }
}

// MARK: - PKCE and requests

nonisolated enum PKCE {
    /// 32 random bytes, base64url: 43 characters (RFC 7636 allows 43–128).
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    /// S256: base64url(SHA-256(verifier)).
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

nonisolated enum OAuthRequests {
    static func redirectURI(host: String, port: UInt16) -> String { "http://\(host):\(port)" }

    static func authorizeURL(_ endpoints: OAuthEndpoints, clientID: String, redirectURI: String, state: String,
                             challenge: String, loginHint: String? = nil) -> URL {
        var components = URLComponents(url: endpoints.authorize, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: endpoints.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        items += endpoints.extraAuthorizeParameters.map { URLQueryItem(name: $0.0, value: $0.1) }
        if let loginHint, !loginHint.isEmpty { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = items
        return components.url!
    }

    static func codeExchange(_ endpoints: OAuthEndpoints, clientID: String, clientSecret: String?, code: String,
                             redirectURI: String, verifier: String) -> URLRequest {
        var fields = [("client_id", clientID), ("grant_type", "authorization_code"), ("code", code),
                      ("redirect_uri", redirectURI), ("code_verifier", verifier)]
        if let clientSecret, !clientSecret.isEmpty { fields.append(("client_secret", clientSecret)) }
        return form(endpoints.token, fields)
    }

    static func refresh(_ endpoints: OAuthEndpoints, clientID: String, clientSecret: String?, refreshToken: String) -> URLRequest {
        var fields = [("client_id", clientID), ("grant_type", "refresh_token"), ("refresh_token", refreshToken)]
        // Microsoft wants the scopes again; Google ignores them.
        fields.append(("scope", endpoints.scopes.joined(separator: " ")))
        if let clientSecret, !clientSecret.isEmpty { fields.append(("client_secret", clientSecret)) }
        return form(endpoints.token, fields)
    }

    static func form(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&").utf8)
        return request
    }

    static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// The query of the loopback request: "GET /?code=…&state=… HTTP/1.1".
    static func callbackParameters(requestLine: String) -> [String: String]? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: "http://localhost" + parts[1]) else { return nil }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }

    /// The email in an id_token's claims (not verified: it only names the account in Settings).
    static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["email", "preferred_username", "upn"] {
            if let value = claims[key] as? String, value.contains("@") { return value.lowercased() }
        }
        return nil
    }
}

// MARK: - Tokens

nonisolated struct OAuthTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    /// Refreshed a minute early.
    func isFresh(at now: Date = .now) -> Bool { expiresAt.timeIntervalSince(now) > 60 }
}

nonisolated struct TokenResponse: Decodable, Sendable {
    var access_token: String?
    var refresh_token: String?
    var expires_in: Double?
    var id_token: String?
    /// The scopes actually granted, space-separated (Google: what the user ticked).
    var scope: String?
    var error: String?
    var error_description: String?
}

nonisolated enum OAuthError: Error, LocalizedError, Equatable {
    case notConfigured
    case cancelled
    case denied(String)
    case stateMismatch
    case server(String)
    /// The refresh token is gone (revoked, expired, password changed): sign in again.
    case needsSignIn

    var errorDescription: String? {
        switch self {
        case .notConfigured: "This provider isn't set up in this build"
        case .cancelled: "Sign-in cancelled"
        case .denied(let why): why.isEmpty ? "Access wasn't granted" : why
        case .stateMismatch: "The sign-in answer didn't match. Try again."
        case .server(let why): why
        case .needsSignIn: "Signed out. Add the account again to reconnect."
        }
    }
}

nonisolated enum OAuthTokenClient {
    /// The tokens from a token endpoint answer. `previous` keeps a refresh token Google doesn't resend.
    static func tokens(from data: Data, status: Int, previousRefreshToken: String? = nil,
                       now: Date = .now) throws -> (OAuthTokens, idToken: String?) {
        let response = try? JSONDecoder().decode(TokenResponse.self, from: data)
        if let error = response?.error {
            if error == "invalid_grant" { throw OAuthError.needsSignIn }
            throw OAuthError.server(response?.error_description?.components(separatedBy: "\r\n").first ?? error)
        }
        guard (200..<300).contains(status), let access = response?.access_token,
              let refresh = response?.refresh_token ?? previousRefreshToken else {
            throw OAuthError.server("The sign-in server answered \(status)")
        }
        return (OAuthTokens(accessToken: access, refreshToken: refresh,
                            expiresAt: now.addingTimeInterval(response?.expires_in ?? 3600)), response?.id_token)
    }

    static func refresh(_ tokens: OAuthTokens, provider: EmailProvider, clients: OAuthClients) async throws -> OAuthTokens {
        guard let endpoints = OAuthEndpoints.of(provider) else { throw OAuthError.notConfigured }
        let request = OAuthRequests.refresh(endpoints, clientID: clients.clientID(for: provider),
                                            clientSecret: provider == .google ? clients.googleClientSecret : nil,
                                            refreshToken: tokens.refreshToken)
        let (data, response) = try await EmailHTTP.session.data(for: request)
        return try Self.tokens(from: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                               previousRefreshToken: tokens.refreshToken).0
    }
}

nonisolated enum EmailHTTP {
    /// No cookies, no cache: every call carries its own token.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

// MARK: - Signing in

/// One sign-in: listen on a loopback port, show the provider's page in the system sign-in sheet,
/// take the code from the redirect, exchange it.
final class OAuthSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var server: LoopbackServer?

    struct Result {
        var tokens: OAuthTokens
        var email: String?
        /// The raw ID token (Continue with Google sends it to the sync server to verify the email).
        var idToken: String? = nil
        var grantedScopes: Set<String> = []
    }

    /// `endpoints` overrides the provider's (Continue with Google asks for other scopes).
    func run(_ provider: EmailProvider, clients: OAuthClients, loginHint: String? = nil,
             endpoints override: OAuthEndpoints? = nil) async throws -> Result {
        guard let endpoints = override ?? OAuthEndpoints.of(provider), !clients.clientID(for: provider).isEmpty else {
            throw OAuthError.notConfigured
        }
        let clientID = clients.clientID(for: provider)
        let server = LoopbackServer()
        self.server = server
        defer {
            server.stop()
            self.server = nil
        }
        let port = try await server.start()
        let redirect = OAuthRequests.redirectURI(host: endpoints.redirectHost, port: port)
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier()
        let url = OAuthRequests.authorizeURL(endpoints, clientID: clientID, redirectURI: redirect, state: state,
                                             challenge: PKCE.challenge(for: verifier), loginHint: loginHint)

        let parameters: [String: String] = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            server.onRequest = { [weak self] parameters in
                once.run { continuation.resume(returning: parameters) }
                Task { @MainActor in self?.session?.cancel() }
            }
            // No callback scheme: the redirect goes to the loopback server, which ends the sheet.
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, error in
                once.run { continuation.resume(throwing: error.map { _ in OAuthError.cancelled } ?? OAuthError.cancelled) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() { once.run { continuation.resume(throwing: OAuthError.cancelled) } }
        }
        session = nil
        if let error = parameters["error"] {
            throw OAuthError.denied(parameters["error_description"] ?? (error == "access_denied" ? "" : error))
        }
        guard parameters["state"] == state else { throw OAuthError.stateMismatch }
        guard let code = parameters["code"], !code.isEmpty else { throw OAuthError.denied("") }

        let request = OAuthRequests.codeExchange(endpoints, clientID: clientID,
                                                 clientSecret: provider == .google ? clients.googleClientSecret : nil,
                                                 code: code, redirectURI: redirect, verifier: verifier)
        let (data, response) = try await EmailHTTP.session.data(for: request)
        let (tokens, idToken) = try OAuthTokenClient.tokens(from: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        let granted = (try? JSONDecoder().decode(TokenResponse.self, from: data))?.scope ?? endpoints.scopes.joined(separator: " ")
        return Result(tokens: tokens, email: idToken.flatMap(OAuthRequests.email(fromIDToken:)), idToken: idToken,
                      grantedScopes: Set(granted.split(separator: " ").map(String.init)))
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
        }
    }
}

/// Answers one HTTP request on 127.0.0.1 / ::1 at a random port, then stops.
nonisolated final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "at.softmaze.clippy.oauth-loopback")
    /// The redirect's query parameters (called once, on a background queue).
    var onRequest: (@Sendable ([String: String]) -> Void)?

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    once.run { continuation.resume(throwing: OAuthError.server(error.localizedDescription)) }
                case .cancelled:
                    once.run { continuation.resume(throwing: OAuthError.cancelled) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parameters = OAuthRequests.callbackParameters(requestLine: firstLine)
            let isCallback = parameters.map { $0["code"] != nil || $0["error"] != nil } ?? false
            let body = isCallback
                ? "<!doctype html><meta charset=utf-8><title>Clipboard2</title><body style=\"font:15px -apple-system;text-align:center;padding-top:80px\">Signed in. You can close this window.</body>"
                : ""
            let status = isCallback ? "200 OK" : "404 Not Found"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isCallback, let parameters, let self {
                self.onRequest?(parameters)
                self.onRequest = nil
            }
        }
    }
}
