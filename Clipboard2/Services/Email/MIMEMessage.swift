import Foundation

// Just enough MIME to read a code mail: headers (with encoded words), multipart, quoted-printable,
// base64 and charsets, down to plain text. HTML-only mails are reduced to their text.

nonisolated struct MIMEMessage: Equatable, Sendable {
    var from: String
    var subject: String
    var date: Date?
    /// The readable text: the text/plain part, else the HTML part without its markup.
    var text: String

    /// A whole message (RFC 5322), as IMAP's header + text or Gmail's raw form deliver it.
    init(data: Data) {
        let (headerData, body) = MIME.splitHeaders(data)
        let headers = MIME.parseHeaders(headerData)
        from = headers["from"].map(MIME.decodeEncodedWords) ?? ""
        subject = headers["subject"].map(MIME.decodeEncodedWords) ?? ""
        date = headers["date"].flatMap(MIME.parseDate)
        text = MIME.text(headers: headers, body: body)
    }

    init(from: String, subject: String, date: Date?, text: String) {
        self.from = from
        self.subject = subject
        self.date = date
        self.text = text
    }
}

nonisolated enum MIME {
    // MARK: Headers

    /// Header block and body, split at the first empty line (CRLF or bare LF).
    static func splitHeaders(_ data: Data) -> (Data, Data) {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A {
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { return (Data(bytes[0..<i]), Data(bytes[(i + 2)...])) }
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {
                    return (Data(bytes[0..<i]), Data(bytes[(i + 3)...]))
                }
            }
            i += 1
        }
        return (data, Data())
    }

    /// Lowercased names → unfolded values. The first of a repeated header wins.
    static func parseHeaders(_ data: Data) -> [String: String] {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var headers: [String: String] = [:]
        var current: (name: String, value: String)?
        func flush() {
            if let current, headers[current.name] == nil {
                headers[current.name] = current.value.trimmingCharacters(in: .whitespaces)
            }
        }
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            if let first = line.first, first == " " || first == "\t" {
                current?.value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                flush()
                current = (line[..<colon].trimmingCharacters(in: .whitespaces).lowercased(),
                           String(line[line.index(after: colon)...]))
            }
        }
        flush()
        return headers
    }

    /// "text/plain; charset="utf-8"" → ("text/plain", ["charset": "utf-8"]).
    static func parseContentType(_ value: String?) -> (type: String, params: [String: String]) {
        guard let value, !value.isEmpty else { return ("text/plain", [:]) }
        var parts = splitParams(value)
        let type = parts.isEmpty ? "text/plain" : parts.removeFirst().trimmingCharacters(in: .whitespaces).lowercased()
        var params: [String: String] = [:]
        for part in parts {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 { val = String(val.dropFirst().dropLast()) }
            params[key] = val
        }
        return (type.isEmpty ? "text/plain" : type, params)
    }

    /// Splits at semicolons outside quotes.
    private static func splitParams(_ value: String) -> [String] {
        var parts: [String] = [], current = "", quoted = false
        for c in value {
            if c == "\"" { quoted.toggle() }
            if c == ";" && !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts
    }

    /// RFC 2047: "=?UTF-8?B?…?=" and "=?ISO-8859-1?Q?…?=". Whitespace between two encoded words goes.
    static func decodeEncodedWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let ns = value as NSString
        var result = ""
        var last = 0
        var previousWasEncoded = false
        for match in regex.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: last, length: match.range.location - last))
            if !(previousWasEncoded && between.allSatisfy(\.isWhitespace)) { result += between }
            let charset = ns.substring(with: match.range(at: 1))
            let mode = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))
            let bytes: Data
            if mode == "B" {
                bytes = decodeBase64(Data(payload.utf8))
            } else {
                bytes = decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            }
            result += decodeText(bytes, charset: charset)
            last = match.range.location + match.range.length
            previousWasEncoded = true
        }
        result += ns.substring(from: last)
        return result
    }

    static func parseDate(_ value: String) -> Date? {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        if let paren = trimmed.firstIndex(of: "(") { trimmed = trimmed[..<paren].trimmingCharacters(in: .whitespaces) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    // MARK: Body

    /// The readable text of a body with these headers. Plain text is preferred; HTML is stripped.
    static func text(headers: [String: String], body: Data) -> String {
        let parts = leafParts(headers: headers, body: body, depth: 0)
        if let plain = parts.first(where: { $0.type == "text/plain" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return plain.text
        }
        if let html = parts.first(where: { $0.type == "text/html" }) { return HTMLText.plain(html.text) }
        return parts.first?.text ?? ""
    }

    private static func leafParts(headers: [String: String], body: Data, depth: Int) -> [(type: String, text: String)] {
        let (type, params) = parseContentType(headers["content-type"])
        if type.hasPrefix("multipart/"), let boundary = params["boundary"], depth < 8 {
            return splitMultipart(body, boundary: boundary).flatMap { part -> [(type: String, text: String)] in
                let (headerData, partBody) = splitHeaders(part)
                return leafParts(headers: parseHeaders(headerData), body: partBody, depth: depth + 1)
            }
        }
        if type == "message/rfc822", depth < 8 {
            let (headerData, inner) = splitHeaders(body)
            return leafParts(headers: parseHeaders(headerData), body: inner, depth: depth + 1)
        }
        guard type.hasPrefix("text/") else { return [] }
        let disposition = headers["content-disposition"]?.lowercased() ?? ""
        if disposition.hasPrefix("attachment") { return [] }
        let decoded = decodeTransfer(body, encoding: headers["content-transfer-encoding"])
        return [(type, decodeText(decoded, charset: params["charset"]))]
    }

    /// The parts between "--boundary" lines. A missing closing boundary (a truncated fetch) is fine.
    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let bytes = [UInt8](body)
        let marker = [UInt8](("--" + boundary).utf8)
        var parts: [Data] = []
        var partStart: Int?
        var lineStart = 0
        var i = 0
        while i <= bytes.count {
            if i == bytes.count || bytes[i] == 0x0A {
                var line = Array(bytes[lineStart..<i])
                if line.last == 0x0D { line.removeLast() }
                while let last = line.last, last == 0x20 || last == 0x09 { line.removeLast() }
                if line.starts(with: marker) {
                    let rest = line.dropFirst(marker.count)
                    if rest.isEmpty || rest.elementsEqual([0x2D, 0x2D]) {
                        if let start = partStart {
                            // The CRLF before the boundary belongs to it.
                            var end = lineStart
                            if end > start, bytes[end - 1] == 0x0A { end -= 1 }
                            if end > start, bytes[end - 1] == 0x0D { end -= 1 }
                            parts.append(Data(bytes[start..<max(start, end)]))
                        }
                        if !rest.isEmpty { return parts }   // the closing boundary
                        partStart = min(i + 1, bytes.count)
                    }
                }
                lineStart = i + 1
            }
            i += 1
        }
        if let start = partStart, start < bytes.count { parts.append(Data(bytes[start...])) }
        return parts
    }

    static func decodeTransfer(_ data: Data, encoding: String?) -> Data {
        switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64": decodeBase64(data)
        case "quoted-printable": decodeQuotedPrintable(data)
        default: data
        }
    }

    /// Base64 with line breaks and other noise ignored; a truncated tail is dropped.
    static func decodeBase64(_ data: Data) -> Data {
        var clean = data.filter { byte in
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
                || byte == 0x2B || byte == 0x2F || byte == 0x2D || byte == 0x5F
        }
        // base64url as well (Gmail).
        clean = Data(clean.map { $0 == 0x2D ? 0x2B : $0 == 0x5F ? 0x2F : $0 })
        var padded = clean
        switch clean.count % 4 {
        case 1: padded.removeLast()
        case 2: padded.append(contentsOf: [0x3D, 0x3D])
        case 3: padded.append(0x3D)
        default: break
        }
        return Data(base64Encoded: padded) ?? Data()
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: b - 0x30
            case 0x41...0x46: b - 0x41 + 10
            case 0x61...0x66: b - 0x61 + 10
            default: nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D {   // "="
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 2; continue }   // soft break
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { i += 3; continue }
                if i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                    out.append(h << 4 | l)
                    i += 3
                    continue
                }
            }
            out.append(b)
            i += 1
        }
        return Data(out)
    }

    /// Bytes in a named charset; unknown or wrong ones fall back to UTF-8, then Latin-1.
    static func decodeText(_ data: Data, charset: String?) -> String {
        if let charset = charset?.trimmingCharacters(in: .whitespaces).lowercased(), !charset.isEmpty,
           charset != "utf-8", charset != "utf8", charset != "us-ascii" {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: Addresses

    /// The address in a From header: "Google <no-reply@accounts.google.com>" → "no-reply@accounts.google.com".
    static func address(inFrom from: String) -> String? {
        if let open = from.lastIndex(of: "<"), let close = from[open...].firstIndex(of: ">") {
            let inner = from[from.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            return inner.contains("@") ? inner.lowercased() : nil
        }
        let bare = from.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\"" })
            .first { $0.contains("@") }
        return bare.map { String($0).lowercased() }
    }

    static func domain(ofAddress address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...].trimmingCharacters(in: CharacterSet(charactersIn: " >.")).lowercased()
        return domain.contains(".") ? domain : nil
    }
}

/// HTML reduced to its text: no head, styles or scripts; blocks become line breaks; entities decoded.
nonisolated enum HTMLText {
    static func plain(_ html: String) -> String {
        var text = html
        for pattern in [#"(?is)<!--.*?-->"#, #"(?is)<head\b.*?</head>"#, #"(?is)<style\b.*?</style>"#,
                        #"(?is)<script\b.*?</script>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</(p|div|tr|h[1-6]|li|table|td|th|center|blockquote)\s*>"#,
                                         with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)<[^>]*>"#, with: " ", options: .regularExpression)
        text = decodeEntities(text)
        // Tidy: spaces collapsed, blank lines at most one.
        let lines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: #"[ \t\x{00A0}]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) { result.append(line) }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let named: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "auml": "ä", "ouml": "ö",
        "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "eacute": "é", "egrave": "è",
        "euro": "€", "copy": "©", "reg": "®", "ndash": "–", "mdash": "—", "hellip": "…", "zwnj": "", "zwj": "",
        "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "bull": "•", "middot": "·", "shy": "",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        guard let regex = try? NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);") else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let name = ns.substring(with: match.range(at: 1))
            if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                result += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            } else {
                result += named[name] ?? ns.substring(with: match.range)
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
