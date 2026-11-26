import Foundation

// The IMAP responses the email-code reader needs (RFC 9051 / 3501), parsed from raw bytes:
// CAPABILITY, SELECT's UIDVALIDITY, UID SEARCH and UID FETCH. The connection lives in IMAPClient.swift.

/// One tagged command's result: the untagged responses (literals inline) and the final status.
nonisolated struct IMAPResponse: Sendable {
    var untagged: [Data]
    var status: String   // OK, NO or BAD
    var text: String

    var isOK: Bool { status == "OK" }
}

/// A message as `UID FETCH (UID INTERNALDATE BODY.PEEK[HEADER.FIELDS …] BODY.PEEK[TEXT]<…>)` returns it.
nonisolated struct IMAPFetched: Equatable, Sendable {
    var uid: UInt32
    var internalDate: Date?
    var header: Data?
    var text: Data?
}

/// A parsed IMAP value: an atom (or number), a string (quoted or literal), NIL, or a list.
nonisolated indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    case string(Data)
    case nilValue
    case list([IMAPValue])

    var atom: String? { if case .atom(let a) = self { a } else { nil } }

    var data: Data? {
        switch self {
        case .string(let data): data
        case .atom(let atom): Data(atom.utf8)
        default: nil
        }
    }

    var stringValue: String? { data.map { String(decoding: $0, as: UTF8.self) } }
}

nonisolated enum IMAPParser {
    /// Quoted for a command: backslashes and quotes escaped.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The tokens of one response line, literals included.
    static func tokens(_ data: Data) -> [IMAPValue] {
        let bytes = [UInt8](data)
        var i = 0
        return parseList(bytes, &i, closing: nil)
    }

    private static func parseList(_ b: [UInt8], _ i: inout Int, closing: UInt8?) -> [IMAPValue] {
        var values: [IMAPValue] = []
        while i < b.count {
            let c = b[i]
            if c == 0x20 || c == 0x0D || c == 0x0A { i += 1; continue }
            if let closing, c == closing { i += 1; return values }
            switch c {
            case 0x28:   // (
                i += 1
                values.append(.list(parseList(b, &i, closing: 0x29)))
            case 0x29:   // stray )
                i += 1
            case 0x22:   // "
                i += 1
                var out = [UInt8]()
                while i < b.count, b[i] != 0x22 {
                    if b[i] == 0x5C, i + 1 < b.count { i += 1 }
                    out.append(b[i])
                    i += 1
                }
                i += 1
                values.append(.string(Data(out)))
            case 0x7B:   // {n} or {n+}, CRLF, then n bytes
                var j = i + 1
                var count = 0
                while j < b.count, (0x30...0x39).contains(b[j]) {
                    count = count * 10 + Int(b[j] - 0x30)
                    j += 1
                }
                if j < b.count, b[j] == 0x2B { j += 1 }
                guard j < b.count, b[j] == 0x7D else {
                    values.append(.atom(String(decoding: b[i..<j], as: UTF8.self)))
                    i = j
                    continue
                }
                j += 1
                if j < b.count, b[j] == 0x0D { j += 1 }
                if j < b.count, b[j] == 0x0A { j += 1 }
                let end = min(b.count, j + count)
                values.append(.string(Data(b[j..<end])))
                i = end
            default:
                // An atom; brackets keep their spaces and parentheses ("BODY[HEADER.FIELDS (FROM)]<0>").
                var j = i
                var depth = 0
                while j < b.count {
                    let d = b[j]
                    if d == 0x5B { depth += 1 } else if d == 0x5D { depth = max(0, depth - 1) }
                    if depth == 0 && (d == 0x20 || d == 0x28 || d == 0x29 || d == 0x0D || d == 0x0A) { break }
                    j += 1
                }
                let atom = String(decoding: b[i..<j], as: UTF8.self)
                values.append(atom.uppercased() == "NIL" ? .nilValue : .atom(atom))
                i = j
            }
        }
        return values
    }

    // MARK: Responses

    /// Capabilities from "* CAPABILITY …" or a "[CAPABILITY …]" response code, uppercased.
    static func capabilities(in responses: [Data], text: String = "") -> Set<String> {
        var caps = Set<String>()
        for line in responses.map({ String(decoding: $0, as: UTF8.self) }) + [text] {
            let upper = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if upper.hasPrefix("* CAPABILITY ") {
                caps.formUnion(upper.dropFirst("* CAPABILITY ".count).split(separator: " ").map(String.init))
            } else if let range = upper.range(of: "[CAPABILITY "), let close = upper[range.upperBound...].firstIndex(of: "]") {
                caps.formUnion(upper[range.upperBound..<close].split(separator: " ").map(String.init))
            }
        }
        return caps
    }

    /// "* OK [UIDVALIDITY 3857529045] UIDs valid".
    static func uidValidity(in responses: [Data]) -> UInt32? {
        for line in responses.map({ String(decoding: $0, as: UTF8.self).uppercased() }) {
            if let range = line.range(of: "[UIDVALIDITY ") {
                let digits = line[range.upperBound...].prefix { $0.isNumber }
                if let value = UInt32(digits) { return value }
            }
        }
        return nil
    }

    /// "* SEARCH 4 9 12" (or "* ESEARCH" not used) → the numbers.
    static func searchResults(in responses: [Data]) -> [UInt32] {
        var result: [UInt32] = []
        for line in responses.map({ String(decoding: $0, as: UTF8.self) }) {
            let upper = line.uppercased()
            guard upper.hasPrefix("* SEARCH") else { continue }
            result += line.dropFirst("* SEARCH".count)
                .split(whereSeparator: \.isWhitespace)
                .compactMap { UInt32($0) }
        }
        return result
    }

    /// "* 12 FETCH (UID 345 INTERNALDATE "…" BODY[…] {n}…)" → the messages.
    static func fetched(in responses: [Data]) -> [IMAPFetched] {
        responses.compactMap { response in
            let values = tokens(response)
            guard values.count >= 4, values[0].atom == "*", values[2].atom?.uppercased() == "FETCH",
                  case .list(let items) = values[3] else { return nil }
            var fetched = IMAPFetched(uid: 0)
            var index = 0
            while index + 1 < items.count {
                let key = items[index].atom?.uppercased() ?? ""
                let value = items[index + 1]
                if key == "UID" {
                    fetched.uid = value.atom.flatMap { UInt32($0) } ?? 0
                } else if key == "INTERNALDATE" {
                    fetched.internalDate = value.stringValue.flatMap(internalDate)
                } else if key.hasPrefix("BODY[HEADER") || key.hasPrefix("RFC822.HEADER") {
                    fetched.header = value.data
                } else if key.hasPrefix("BODY[TEXT]") || key.hasPrefix("RFC822.TEXT") {
                    fetched.text = value.data
                }
                index += 2
            }
            return fetched.uid == 0 ? nil : fetched
        }
    }

    /// "26-Nov-2026 10:04:12 +0100" (the day may be space-padded).
    static func internalDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    /// SEARCH SINCE takes a day: "25-Nov-2026".
    static func searchDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d-MMM-yyyy"
        return formatter.string(from: date)
    }

    /// A UID set for FETCH: "4,9,12".
    static func uidSet(_ uids: [UInt32]) -> String {
        uids.sorted().map(String.init).joined(separator: ",")
    }

    /// The tagged status line: "A7 OK Done" → ("OK", "Done").
    static func status(of line: String, tag: String) -> (status: String, text: String)? {
        guard line.hasPrefix(tag + " ") else { return nil }
        let rest = line.dropFirst(tag.count + 1)
        let parts = rest.split(separator: " ", maxSplits: 1)
        guard let first = parts.first else { return nil }
        return (first.uppercased(), parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : "")
    }

    /// The literal length a line ends with ("… {123}"), if any.
    static func literalLength(atEndOf line: Data) -> Int? {
        var bytes = [UInt8](line)
        while let last = bytes.last, last == 0x0A || last == 0x0D { bytes.removeLast() }
        guard bytes.last == 0x7D else { return nil }
        bytes.removeLast()
        if bytes.last == 0x2B { bytes.removeLast() }
        var digits = [UInt8]()
        while let last = bytes.last, (0x30...0x39).contains(last) { digits.insert(bytes.removeLast(), at: 0) }
        guard !digits.isEmpty, bytes.last == 0x7B else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }
}
