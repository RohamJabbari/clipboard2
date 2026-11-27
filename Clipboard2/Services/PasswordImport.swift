import Foundation

// Settings → Auth → Import: password exports from Apple Passwords, Chrome (and Chromium browsers),
// Firefox, 1Password and Bitwarden (`url,username,password,notes`, with or without `title` and
// `otpauth`, under each exporter's own header names). The file is read once and never kept; what's
// imported is picked in a review list first (PasswordImportReview).

/// RFC 4180 CSV: quoted fields with "" escapes and line breaks inside, CRLF or LF, a BOM.
nonisolated enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == "," {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field)
                field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        return rows
    }
}

/// One login from an export.
nonisolated struct PasswordCSVRow: Equatable, Sendable {
    var title = ""
    var url = ""
    var username = ""
    var password = ""
    var notes = ""
    var otpauth = ""

    /// Bitwarden writes several URIs into one cell, separated by commas.
    var urls: [String] {
        guard !url.isEmpty else { return [] }
        let parts = url.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count > 1, parts.allSatisfy({ !$0.contains(" ") && $0.contains(".") }) { return parts }
        return [url]
    }

    /// The one-time-code setup: an `otpauth://` link, or (Bitwarden) a bare base32 key.
    var authenticator: OTPAccount? {
        guard !otpauth.isEmpty else { return nil }
        var account: OTPAccount
        if case .success(let parsed) = OTPAuthURI.parse(otpauth) {
            account = parsed
        } else if !otpauth.contains("://"), let secret = Base32.normalize(otpauth), Base32.decode(secret)?.isEmpty == false {
            account = OTPAccount(issuer: "", account: "", secret: secret)
        } else {
            return nil
        }
        if account.issuer.isEmpty { account.issuer = title.isEmpty ? (urls.first.flatMap { AuthSource.domain(ofSite: $0) } ?? "") : title }
        if account.account.isEmpty { account.account = username }
        return account
    }
}

nonisolated enum PasswordCSV {
    enum Column: Equatable { case title, url, username, password, notes, otpauth }

    struct Problem: Error, Equatable { var message: String }

    /// Header names as the exporters write them, without case, spaces or punctuation.
    static func column(forHeader header: String) -> Column? {
        switch IssuerDomains.normalized(header) {
        case "title", "name", "itemname": .title
        case "url", "urls", "website", "site", "loginuri", "loginurl", "uri", "address", "weburl": .url
        case "username", "user", "login", "loginusername", "loginname", "email", "emailaddress", "userid", "account": .username
        case "password", "pass", "loginpassword", "pwd": .password
        case "notes", "note", "comments", "comment", "extra", "loginnotes": .notes
        case "otpauth", "otp", "totp", "onetimepassword", "loginotp", "logintotp", "otpauthurl", "twofactorsecret",
             "authenticator": .otpauth
        default: nil
        }
    }

    /// The rows of an export, by its header. Fails when there's no header with a password or
    /// one-time-code column.
    static func rows(from text: String) -> Result<[PasswordCSVRow], Problem> {
        let table = CSV.parse(text)
        guard let header = table.first else { return .failure(Problem(message: "The file is empty.")) }
        var columns: [Int: Column] = [:]
        for (index, name) in header.enumerated() {
            guard let column = column(forHeader: name), !columns.values.contains(column) else { continue }
            columns[index] = column
        }
        guard columns.values.contains(.password) || columns.values.contains(.otpauth) else {
            return .failure(Problem(message: "That isn't a password export: it has no password column."))
        }
        let rows = table.dropFirst().map { cells in
            var row = PasswordCSVRow()
            for (index, cell) in cells.enumerated() {
                let value = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                switch columns[index] {
                case .title: row.title = value
                case .url: row.url = value
                case .username: row.username = value
                case .password: row.password = cell   // as is: spaces can be part of a password
                case .notes: row.notes = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                case .otpauth: row.otpauth = value
                case nil: break
                }
            }
            return row
        }
        return .success(rows)
    }
}

/// Where imported passwords go (the Keychain in the app, a list in tests).
protocol PasswordImportSink: AnyObject {
    /// Personal passwords and secrets already saved, for skipping duplicates.
    func existingLogins() -> [PasswordImporter.Login]
    func addLogin(name: String, value: String, username: String?, urls: [String], notes: String?) -> Bool
    /// A "Changed" entry: the saved password (`Login.id`) gets the imported value.
    func updateLogin(id: String, value: String) -> Bool
    func finishImport()
}

nonisolated struct PasswordImportSummary: Equatable, Sendable {
    var passwords = 0
    var authenticators = 0
    /// Saved passwords that got the imported value ("Changed" entries).
    var updated = 0
    var duplicates = 0
    /// Rows with neither a password nor a usable one-time-code link.
    var unreadable = 0
    var failed = 0

    /// "Imported 42 passwords, 3 authenticators, skipped 2 duplicates".
    var line: String {
        var parts = ["Imported \(BackupSummary.count(passwords, "password"))"]
        if updated > 0 { parts.append("updated \(updated)") }
        if authenticators > 0 { parts.append(BackupSummary.count(authenticators, "authenticator")) }
        if duplicates > 0 { parts.append("skipped \(BackupSummary.count(duplicates, "duplicate"))") }
        if unreadable > 0 { parts.append("skipped \(BackupSummary.count(unreadable, "empty row"))") }
        if failed > 0 { parts.append("\(failed) couldn't be saved") }
        return parts.joined(separator: ", ")
    }
}

enum PasswordImporter {
    /// What makes two logins the same: their sites' domains, username and password.
    nonisolated struct Login: Hashable, Sendable {
        var domains: Set<String>
        var username: String
        var value: String
        /// The saved password it is (not part of what makes two logins the same).
        var id: String?

        init(urls: [String], username: String?, value: String, id: String? = nil) {
            domains = Set(urls.map { AuthSource.domain(ofSite: $0) ?? $0.lowercased() })
            self.username = (username ?? "").lowercased()
            self.value = value
            self.id = id
        }

        /// Same site and username (the password may differ).
        func isSameAccount(as other: Login) -> Bool { domains == other.domains && username == other.username }

        static func == (lhs: Login, rhs: Login) -> Bool {
            lhs.domains == rhs.domains && lhs.username == rhs.username && lhs.value == rhs.value
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(domains)
            hasher.combine(username)
            hasher.combine(value)
        }
    }

    static func run(_ text: String, into sink: any PasswordImportSink,
                    authenticators: AuthenticatorStore?) -> Result<PasswordImportSummary, PasswordCSV.Problem> {
        switch PasswordCSV.rows(from: text) {
        case .failure(let problem): return .failure(problem)
        case .success(let rows): return .success(run(rows, into: sink, authenticators: authenticators))
        }
    }

    static func run(_ rows: [PasswordCSVRow], into sink: any PasswordImportSink,
                    authenticators: AuthenticatorStore?) -> PasswordImportSummary {
        var summary = PasswordImportSummary()
        var known = Set(sink.existingLogins())
        var knownCodes = Set((authenticators?.owned ?? []).map { "\($0.secret)|\($0.account)" })
        for row in rows {
            let urls = row.urls
            var used = false
            if !row.password.isEmpty {
                used = true
                let login = Login(urls: urls, username: row.username, value: row.password)
                if !known.insert(login).inserted {
                    summary.duplicates += 1
                } else if sink.addLogin(name: name(for: row), value: row.password,
                                        username: row.username.isEmpty ? nil : row.username,
                                        urls: urls, notes: row.notes.isEmpty ? nil : row.notes) {
                    summary.passwords += 1
                } else {
                    summary.failed += 1
                }
            }
            if let authenticators, let account = row.authenticator {
                used = true
                if !knownCodes.insert("\(account.secret)|\(account.account)").inserted {
                    summary.duplicates += 1
                } else if authenticators.add(account, urls: urls) != nil {
                    summary.authenticators += 1
                } else {
                    summary.failed += 1
                }
            }
            if !used { summary.unreadable += 1 }
        }
        sink.finishImport()
        return summary
    }

    /// The export's title, else the site, else the username.
    static func name(for row: PasswordCSVRow) -> String {
        if !row.title.isEmpty { return row.title }
        if let domain = row.urls.first.flatMap({ AuthSource.domain(ofSite: $0) }) { return domain }
        if !row.url.isEmpty { return row.url }
        return row.username.isEmpty ? "Imported Password" : row.username
    }
}

extension SecretStore: PasswordImportSink {
    func existingLogins() -> [PasswordImporter.Login] {
        secrets.filter { $0.spaceID == nil }.compactMap { ref in
            SecretVault.value(id: ref.id).map { PasswordImporter.Login(urls: ref.urls, username: ref.username, value: $0, id: ref.id) }
        }
    }

    /// Also LoginSaveStore's (LoginSaveWatcher.swift).
    func updateLogin(id: String, value: String) -> Bool {
        guard let ref = secrets.first(where: { $0.id == id }) else { return false }
        return update(ref, value: value)
    }

    func addLogin(name: String, value: String, username: String?, urls: [String], notes: String?) -> Bool {
        SecretVault.add(name: name, value: value, username: username, urls: urls, notes: notes) != nil
    }
}
