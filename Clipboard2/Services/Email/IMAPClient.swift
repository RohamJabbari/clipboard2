import Foundation
import Network

// A minimal IMAP client over Network.framework: TLS (993) or plain, LOGIN, SELECT INBOX,
// UID SEARCH / UID FETCH and IDLE. Enough to read the newest mails for codes; nothing else.

nonisolated enum IMAPError: Error, LocalizedError, Equatable {
    case connection(String)
    case closed
    case timedOut
    case loginFailed(String)
    case command(String)

    var errorDescription: String? {
        switch self {
        case .connection(let why): "Can't reach the server: \(why)"
        case .closed: "The server closed the connection"
        case .timedOut: "The server didn't answer"
        case .loginFailed(let why): why.isEmpty ? "Wrong email or app password" : "Sign-in refused: \(why)"
        case .command(let why): "The server refused: \(why)"
        }
    }
}

actor IMAPClient {
    private let connection: NWConnection
    private var buffer = Data()
    private var tagCounter = 0
    private(set) var capabilities = Set<String>()
    private var idleTag: String?
    private var idleEnded = false
    /// No answer for this long ends a command (IDLE has its own clock).
    private let commandTimeout: Duration = .seconds(45)

    init(host: String, port: UInt16, useTLS: Bool) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 20
        tcp.enableKeepalive = true
        let parameters = useTLS ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp) : NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 993, using: parameters)
    }

    deinit { connection.cancel() }

    // MARK: Session

    func connect() async throws {
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume() }
                case .failed(let error): once.run { continuation.resume(throwing: IMAPError.connection(error.localizedDescription)) }
                case .waiting(let error): once.run { continuation.resume(throwing: IMAPError.connection(error.localizedDescription)) }
                case .cancelled: once.run { continuation.resume(throwing: IMAPError.closed) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
        let greeting = try await readLine()
        let text = String(decoding: greeting, as: UTF8.self)
        guard text.hasPrefix("* OK") || text.hasPrefix("* PREAUTH") else { throw IMAPError.connection(text) }
        capabilities = IMAPParser.capabilities(in: [greeting])
    }

    func login(user: String, password: String) async throws {
        let response = try await command("LOGIN \(IMAPParser.quoted(user)) \(IMAPParser.quoted(password))", redact: true)
        guard response.isOK else { throw IMAPError.loginFailed(Self.humanText(response.text)) }
        let fresh = IMAPParser.capabilities(in: response.untagged, text: response.text)
        if !fresh.isEmpty { capabilities = fresh }
        if !capabilities.contains("IDLE") {
            let caps = try await command("CAPABILITY")
            capabilities.formUnion(IMAPParser.capabilities(in: caps.untagged))
        }
    }

    /// The inbox's UIDVALIDITY.
    func selectInbox() async throws -> UInt32? {
        let response = try await command("EXAMINE INBOX")
        guard response.isOK else { throw IMAPError.command(response.text) }
        return IMAPParser.uidValidity(in: response.untagged)
    }

    var supportsIdle: Bool { capabilities.contains("IDLE") }

    func uidSearch(_ criteria: String) async throws -> [UInt32] {
        let response = try await command("UID SEARCH \(criteria)")
        guard response.isOK else { throw IMAPError.command(response.text) }
        return IMAPParser.searchResults(in: response.untagged)
    }

    func uidFetch(_ uids: [UInt32], items: String) async throws -> [IMAPFetched] {
        guard !uids.isEmpty else { return [] }
        let response = try await command("UID FETCH \(IMAPParser.uidSet(uids)) \(items)")
        guard response.isOK else { throw IMAPError.command(response.text) }
        return IMAPParser.fetched(in: response.untagged)
    }

    /// Waits in IDLE until new mail arrives, `endIdle()` is called, or `limit` passes.
    func idle(limit: Duration) async throws {
        tagCounter += 1
        let tag = "C\(tagCounter)"
        try await send("\(tag) IDLE\r\n")
        let first = try await readLine()
        guard first.first == UInt8(ascii: "+") else {
            throw IMAPError.command(String(decoding: first, as: UTF8.self))
        }
        idleTag = tag
        idleEnded = false
        let timer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            await self?.endIdle()
        }
        defer { timer.cancel() }
        while true {
            let line = try await readLine(timeout: limit + .seconds(60))
            let text = String(decoding: line, as: UTF8.self)
            if IMAPParser.status(of: text, tag: tag) != nil {
                idleTag = nil
                return
            }
            let upper = text.uppercased()
            if upper.hasPrefix("* "), upper.contains(" EXISTS") || upper.contains(" RECENT") { endIdle() }
            if upper.hasPrefix("* BYE") { throw IMAPError.closed }
        }
    }

    /// Ends a running IDLE (new mail, the panel opened, or its time is up).
    func endIdle() {
        guard idleTag != nil, !idleEnded else { return }
        idleEnded = true
        connection.send(content: Data("DONE\r\n".utf8), completion: .contentProcessed { _ in })
    }

    func logout() {
        connection.send(content: Data("Z LOGOUT\r\n".utf8), completion: .contentProcessed { _ in })
        connection.cancel()
    }

    // MARK: Commands

    func command(_ text: String, redact: Bool = false) async throws -> IMAPResponse {
        tagCounter += 1
        let tag = "C\(tagCounter)"
        try await send("\(tag) \(text)\r\n")
        var untagged: [Data] = []
        while true {
            var line = try await readLine()
            // A literal: its bytes, then the rest of the same response.
            while let count = IMAPParser.literalLength(atEndOf: line) {
                line += try await readBytes(count)
                line += try await readLine()
            }
            let text = String(decoding: line, as: UTF8.self)
            if let status = IMAPParser.status(of: text, tag: tag) {
                return IMAPResponse(untagged: untagged, status: status.status, text: status.text)
            }
            if text.hasPrefix("* BYE") { throw IMAPError.closed }
            untagged.append(line)
        }
    }

    private func send(_ text: String) async throws {
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                once.run {
                    if let error { continuation.resume(throwing: IMAPError.connection(error.localizedDescription)) } else { continuation.resume() }
                }
            })
        }
    }

    // MARK: Reading

    /// One line, CRLF included.
    private func readLine(timeout: Duration? = nil) async throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex...newline]
                buffer = Data(buffer[(newline + 1)...])
                return Data(line)
            }
            try await receive(timeout: timeout ?? (idleTag == nil ? commandTimeout : nil))
        }
    }

    private func readBytes(_ count: Int) async throws -> Data {
        while buffer.count < count { try await receive(timeout: commandTimeout) }
        let bytes = buffer.prefix(count)
        buffer = Data(buffer.dropFirst(count))
        return Data(bytes)
    }

    private func receive(timeout: Duration?) async throws {
        let connection = self.connection
        let chunk: Data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let once = ResumeOnce()
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                        once.run {
                            if let error {
                                continuation.resume(throwing: IMAPError.connection(error.localizedDescription))
                            } else if let data, !data.isEmpty {
                                continuation.resume(returning: data)
                            } else if isComplete {
                                continuation.resume(throwing: IMAPError.closed)
                            } else {
                                continuation.resume(returning: Data())
                            }
                        }
                    }
                }
            }
            if let timeout {
                group.addTask {
                    try await Task.sleep(for: timeout)
                    // A silent server: the session is over (this also ends the pending receive).
                    connection.cancel()
                    throw IMAPError.timedOut
                }
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw IMAPError.closed }
            return first
        }
        buffer += chunk
        // A buffer this big without a line end isn't a mail we want.
        if buffer.count > 8 * 1024 * 1024 { throw IMAPError.command("response too large") }
    }

    /// "[AUTHENTICATIONFAILED] Invalid credentials (Failure)" → "Invalid credentials (Failure)".
    static func humanText(_ text: String) -> String {
        var text = text
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") { text = String(text[text.index(after: close)...]) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Resumes a continuation once, whichever callback comes first.
nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
