import Foundation

// Reading the newest mails of one account: Microsoft Graph, the Gmail API, or IMAP. Each source
// returns only what arrived since a given time; EmailCodeCenter decides what's a code.

nonisolated struct MailMessage: Equatable, Sendable {
    var id: String
    var from: String
    var subject: String
    var text: String
    var receivedAt: Date
}

protocol MailSource: AnyObject {
    /// How long to wait between looks when there's no push (IDLE).
    var interval: Duration { get }
    /// The same while a code is probably wanted (the panel is open, a code field is focused).
    var urgentInterval: Duration { get }
    func recentMessages(since: Date) async throws -> [MailMessage]
    /// Returns when it's time to look again: new mail (IMAP IDLE), a kick, or the interval passed.
    func waitForMail(_ waker: Waker, urgent: Bool) async throws
    func close()
}

extension MailSource {
    var urgentInterval: Duration { interval }

    func waitForMail(_ waker: Waker, urgent: Bool) async throws {
        await waker.wait(urgent ? urgentInterval : interval)
    }
}

/// Polling cadence of the HTTP sources. One look is one request (Graph) or one list request plus
/// one per new message (Gmail): at most 30 a minute per account while urgent, 12 otherwise. Graph
/// allows 10 000 requests per 10 minutes per mailbox; Gmail 15 000 quota units a minute per user
/// (a list or get costs 5). Both are far above this.
nonisolated enum MailPolling {
    static let interval: Duration = .seconds(5)
    static let urgentInterval: Duration = .seconds(2)
}

/// Wakes a waiting loop early (the panel opened, the Mac woke), or after its time.
final class Waker {
    private var continuation: CheckedContinuation<Void, Never>?
    private var timer: Task<Void, Never>?
    private var pending = false
    /// While IMAP is in IDLE, a kick ends the IDLE instead.
    var onKick: (() -> Void)?

    func wait(_ duration: Duration) async {
        if takePending() { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            timer = Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                self?.resume()
            }
        }
    }

    func kick() {
        if continuation != nil {
            resume()
        } else if let onKick {
            onKick()
        } else {
            pending = true
        }
    }

    /// A kick that came while nothing was waiting.
    func takePending() -> Bool {
        defer { pending = false }
        return pending
    }

    private func resume() {
        timer?.cancel()
        timer = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}

/// Hands out a valid access token, refreshing (and saving) it when it's about to expire.
final class TokenKeeper {
    private var tokens: OAuthTokens
    private let provider: EmailProvider
    private let clients: OAuthClients
    private let save: (OAuthTokens) -> Void

    init(tokens: OAuthTokens, provider: EmailProvider, clients: OAuthClients, save: @escaping (OAuthTokens) -> Void) {
        self.tokens = tokens
        self.provider = provider
        self.clients = clients
        self.save = save
    }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if forceRefresh || !tokens.isFresh() {
            tokens = try await OAuthTokenClient.refresh(tokens, provider: provider, clients: clients)
            save(tokens)
        }
        return tokens.accessToken
    }

    /// A GET with the bearer token; a 401 refreshes once and tries again.
    func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        for attempt in 0..<2 {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("Bearer \(try await accessToken(forceRefresh: attempt == 1))", forHTTPHeaderField: "Authorization")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let (data, response) = try await EmailHTTP.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            guard (200..<300).contains(status) else { throw MailSourceError.http(status, Self.message(in: data)) }
            return data
        }
        throw OAuthError.needsSignIn
    }

    private static func message(in data: Data) -> String {
        struct Envelope: Decodable {
            struct Inner: Decodable { var message: String? }
            var error: Inner?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message ?? ""
    }
}

nonisolated enum MailSourceError: Error, LocalizedError, Equatable {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            if status == 403 { return message.isEmpty ? "Access to mail was refused" : message }
            if status == 429 { return "Too many requests; trying again later" }
            return message.isEmpty ? "The mail server answered \(status)" : message
        }
    }
}

// MARK: - Microsoft Graph

/// The inbox's messages received since a time, as plain text (`Prefer: outlook.body-content-type="text"`).
final class GraphMailSource: MailSource {
    let interval = MailPolling.interval
    let urgentInterval = MailPolling.urgentInterval
    private let keeper: TokenKeeper
    /// The newest message seen: later looks ask only for a little before it, so polling every few
    /// seconds doesn't download the last 10 minutes' bodies each time.
    private var newest: Date?
    /// Mail can show up with a receive time a bit before mail already seen (delivery delays).
    static let overlap: TimeInterval = 120

    init(keeper: TokenKeeper) { self.keeper = keeper }

    static func url(since: Date) -> URL {
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages")!
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        components.queryItems = [
            URLQueryItem(name: "$filter", value: "receivedDateTime ge \(iso.string(from: since))"),
            URLQueryItem(name: "$select", value: "id,subject,from,receivedDateTime,body"),
            URLQueryItem(name: "$top", value: "25"),
        ]
        return components.url!
    }

    func recentMessages(since: Date) async throws -> [MailMessage] {
        let from = newest.map { max(since, $0.addingTimeInterval(-Self.overlap)) } ?? since
        let data = try await keeper.get(Self.url(since: from), headers: ["Prefer": "outlook.body-content-type=\"text\""])
        let messages = try Self.parse(data)
        if let latest = messages.map(\.receivedAt).max(), latest > (newest ?? .distantPast) { newest = latest }
        return messages
    }

    static func parse(_ data: Data) throws -> [MailMessage] {
        struct List: Decodable { var value: [Item] }
        struct Item: Decodable {
            struct Address: Decodable { var emailAddress: Inner?; struct Inner: Decodable { var name: String?; var address: String? } }
            struct Body: Decodable { var contentType: String?; var content: String? }
            var id: String
            var subject: String?
            var from: Address?
            var receivedDateTime: String?
            var body: Body?
        }
        let iso = ISO8601DateFormatter()
        return try JSONDecoder().decode(List.self, from: data).value.map { item in
            let content = item.body?.content ?? ""
            let text = item.body?.contentType?.lowercased() == "html" ? HTMLText.plain(content) : content
            let address = item.from?.emailAddress?.address ?? ""
            return MailMessage(id: item.id, from: "<\(address)>", subject: item.subject ?? "", text: text,
                               receivedAt: item.receivedDateTime.flatMap(iso.date(from:)) ?? .now)
        }
    }

    func close() {}
}

// MARK: - Gmail

/// `messages.list` with `after:<epoch>` in the inbox or Updates, then each new one as raw MIME.
final class GmailSource: MailSource {
    let interval = MailPolling.interval
    let urgentInterval = MailPolling.urgentInterval
    private let keeper: TokenKeeper
    /// Messages already read (Gmail lists them again on every look).
    private var read: [String: Date] = [:]

    init(keeper: TokenKeeper) { self.keeper = keeper }

    static func listURL(since: Date) -> URL {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "after:\(Int(since.timeIntervalSince1970)) {in:inbox category:updates}"),
            URLQueryItem(name: "maxResults", value: "20"),
        ]
        return components.url!
    }

    func recentMessages(since: Date) async throws -> [MailMessage] {
        struct List: Decodable { var messages: [Ref]?; struct Ref: Decodable { var id: String } }
        let list = try JSONDecoder().decode(List.self, from: try await keeper.get(Self.listURL(since: since)))
        read = read.filter { $0.value > since.addingTimeInterval(-300) }
        var messages: [MailMessage] = []
        for ref in list.messages ?? [] where read[ref.id] == nil {
            guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(ref.id)?format=raw") else { continue }
            let message = try Self.parseRaw(try await keeper.get(url))
            read[ref.id] = message.receivedAt
            messages.append(message)
        }
        return messages
    }

    static func parseRaw(_ data: Data) throws -> MailMessage {
        struct Raw: Decodable { var id: String; var raw: String?; var internalDate: String? }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let mime = MIMEMessage(data: MIME.decodeBase64(Data((raw.raw ?? "").utf8)))
        let received = raw.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? mime.date ?? .now
        return MailMessage(id: raw.id, from: mime.from, subject: mime.subject, text: mime.text, receivedAt: received)
    }

    func close() {}
}

// MARK: - IMAP

/// One connection, kept open: EXAMINE INBOX, then the UIDs past the last one seen. IDLE when the
/// server has it, else a look every 30 s.
final class IMAPMailSource: MailSource {
    let interval: Duration = .seconds(30)
    /// Without IDLE only; with it, new mail arrives at once anyway.
    let urgentInterval: Duration = .seconds(5)
    private let settings: IMAPSettings
    private let user: String
    private let password: String
    private var client: IMAPClient?
    private var uidValidity: UInt32?
    private var lastUID: UInt32?
    /// IDLE is renewed well inside the 29 minutes servers allow.
    static let idleLimit: Duration = .seconds(9 * 60)
    static let bodyBytes = 32 * 1024
    static let fetchItems = "(UID INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING MIME-VERSION)] BODY.PEEK[TEXT]<0.\(bodyBytes)>)"

    init(settings: IMAPSettings, user: String, password: String) {
        self.settings = settings
        self.user = user
        self.password = password
    }

    private func connected() async throws -> IMAPClient {
        if let client { return client }
        let client = IMAPClient(host: settings.host, port: settings.port, useTLS: settings.useTLS)
        do {
            try await client.connect()
            try await client.login(user: user, password: password)
            let validity = try await client.selectInbox()
            if validity != uidValidity { lastUID = nil }
            uidValidity = validity
        } catch {
            await client.logout()
            throw error
        }
        self.client = client
        return client
    }

    func recentMessages(since: Date) async throws -> [MailMessage] {
        do {
            let client = try await connected()
            let criteria = lastUID.map { "UID \($0 + 1):*" } ?? "SINCE \(IMAPParser.searchDate(since.addingTimeInterval(-86_400)))"
            var uids = try await client.uidSearch(criteria)
            if let lastUID { uids = uids.filter { $0 > lastUID } }
            guard let newest = uids.max() else { return [] }
            lastUID = max(lastUID ?? 0, newest)
            // The newest 30 at most; dates first, so only recent ones are downloaded.
            let dated = try await client.uidFetch(Array(uids.sorted().suffix(30)), items: "(UID INTERNALDATE)")
            let recent = dated.filter { ($0.internalDate ?? .distantPast) >= since }.map(\.uid)
            return try await client.uidFetch(recent, items: Self.fetchItems).map(Self.message)
        } catch {
            await dropConnection()
            throw error
        }
    }

    static func message(_ fetched: IMAPFetched) -> MailMessage {
        var raw = fetched.header ?? Data()
        if !raw.isEmpty, raw.suffix(2) != Data("\r\n".utf8) { raw += Data("\r\n".utf8) }
        raw += Data("\r\n".utf8)
        raw += fetched.text ?? Data()
        let mime = MIMEMessage(data: raw)
        return MailMessage(id: String(fetched.uid), from: mime.from, subject: mime.subject, text: mime.text,
                           receivedAt: fetched.internalDate ?? mime.date ?? .now)
    }

    func waitForMail(_ waker: Waker, urgent: Bool) async throws {
        guard let client, await client.supportsIdle else {
            await waker.wait(urgent ? urgentInterval : interval)
            return
        }
        if waker.takePending() { return }
        waker.onKick = { Task { await client.endIdle() } }
        defer { waker.onKick = nil }
        do {
            try await client.idle(limit: Self.idleLimit)
        } catch {
            await dropConnection()
            throw error
        }
    }

    private func dropConnection() async {
        await client?.logout()
        client = nil
    }

    func close() {
        let client = self.client
        self.client = nil
        Task { await client?.logout() }
    }
}
