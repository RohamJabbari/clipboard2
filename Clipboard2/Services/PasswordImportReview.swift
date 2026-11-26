import Foundation
import Observation

// Settings → Auth → Import: nothing is imported straight from a file. The export's entries are
// listed first with a status and a checkbox, and only the checked ones are imported
// (docs/features/auth-autofill.md → Guided import).

/// One login (or authenticator) of an export, as the review list shows it.
nonisolated struct PasswordImportEntry: Identifiable, Equatable, Sendable {
    enum Status: String, CaseIterable, Sendable {
        /// Not saved yet.
        case new
        /// The same site, username and password is saved already (or earlier in the file).
        case duplicate
        /// The same site and username is saved with another password: importing updates it.
        case changed
        /// A one-time-code setup that isn't saved yet.
        case authenticator

        var title: String {
            switch self {
            case .new: "New"
            case .duplicate: "Duplicate"
            case .changed: "Changed"
            case .authenticator: "Authenticator"
            }
        }
    }

    enum Payload: Equatable, Sendable {
        case password(name: String, value: String, username: String?, urls: [String], notes: String?)
        case authenticator(OTPAccount, urls: [String])
    }

    let id: Int
    /// The site's domain (else the export's title).
    var site: String
    var username: String
    var status: Status
    var payload: Payload
    /// A Changed entry's saved password.
    var existingID: String?
    var isChecked: Bool

    /// Duplicates can't be picked: importing them would add nothing.
    var isSelectable: Bool { status != .duplicate }
}

/// The review list: New, Changed and Authenticator entries start checked, duplicates unchecked
/// (and can't be checked). Only checked entries are imported; `close()` drops every value.
@Observable
final class PasswordImportReview {
    enum Filter: String, CaseIterable, Identifiable {
        case all, new, changed, duplicates
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .new: "New"
            case .changed: "Changed"
            case .duplicates: "Duplicates"
            }
        }

        func includes(_ status: PasswordImportEntry.Status) -> Bool {
            switch self {
            case .all: true
            case .new: status == .new || status == .authenticator
            case .changed: status == .changed
            case .duplicates: status == .duplicate
            }
        }
    }

    /// The export's file name ("Passwords.csv").
    let fileName: String
    private(set) var entries: [PasswordImportEntry]
    /// Rows with neither a password nor a usable one-time code.
    private(set) var unreadable: Int
    var search = ""
    var filter = Filter.all

    init(rows: [PasswordCSVRow], fileName: String, existing: [PasswordImporter.Login], existingCodes: Set<String>) {
        self.fileName = fileName
        var entries: [PasswordImportEntry] = []
        var unreadable = 0
        var known = Set(existing)
        var codes = existingCodes
        for row in rows {
            let urls = row.urls
            let site = urls.first.flatMap { AuthSource.domain(ofSite: $0) } ?? PasswordImporter.name(for: row)
            var used = false
            if !row.password.isEmpty {
                used = true
                let login = PasswordImporter.Login(urls: urls, username: row.username, value: row.password)
                var status = PasswordImportEntry.Status.new
                var existingID: String?
                if known.contains(login) {
                    status = .duplicate
                } else if let saved = existing.first(where: { $0.id != nil && $0.isSameAccount(as: login) }) {
                    status = .changed
                    existingID = saved.id
                }
                known.insert(login)
                entries.append(PasswordImportEntry(
                    id: entries.count, site: site, username: row.username, status: status,
                    payload: .password(name: PasswordImporter.name(for: row), value: row.password,
                                       username: row.username.isEmpty ? nil : row.username, urls: urls,
                                       notes: row.notes.isEmpty ? nil : row.notes),
                    existingID: existingID, isChecked: status != .duplicate))
            }
            if let account = row.authenticator {
                used = true
                let isNew = codes.insert(Self.codeKey(account)).inserted
                entries.append(PasswordImportEntry(
                    id: entries.count, site: account.issuer.isEmpty ? site : account.issuer,
                    username: account.account, status: isNew ? .authenticator : .duplicate,
                    payload: .authenticator(account, urls: urls), existingID: nil, isChecked: isNew))
            }
            if !used { unreadable += 1 }
        }
        self.entries = entries
        self.unreadable = unreadable
    }

    /// The review for an export's text, against what's saved already.
    static func make(text: String, fileName: String, sink: any PasswordImportSink,
                     authenticators: AuthenticatorStore?) -> Result<PasswordImportReview, PasswordCSV.Problem> {
        PasswordCSV.rows(from: text).map { rows in
            PasswordImportReview(rows: rows, fileName: fileName, existing: sink.existingLogins(),
                                 existingCodes: Set((authenticators?.owned ?? []).map { "\($0.secret)|\($0.account)" }))
        }
    }

    static func codeKey(_ account: OTPAccount) -> String { "\(account.secret)|\(account.account)" }

    // MARK: Picking

    /// What the list shows: the filter, then the search (site or username).
    var visible: [PasswordImportEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            filter.includes(entry.status)
                && (needle.isEmpty || entry.site.lowercased().contains(needle) || entry.username.lowercased().contains(needle))
        }
    }

    func count(_ status: PasswordImportEntry.Status) -> Int { entries.filter { $0.status == status }.count }

    var checkedCount: Int { entries.filter(\.isChecked).count }

    func setChecked(_ id: Int, _ checked: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isSelectable else { return }
        entries[index].isChecked = checked
    }

    /// Select all / none: the entries shown (duplicates stay unchecked).
    func selectAll() { setVisible(true) }
    func selectNone() { setVisible(false) }

    private func setVisible(_ checked: Bool) {
        let ids = Set(visible.map(\.id))
        for index in entries.indices where ids.contains(entries[index].id) && entries[index].isSelectable {
            entries[index].isChecked = checked
        }
    }

    // MARK: Importing

    /// Imports the checked entries (New ones are added, Changed ones update the saved password),
    /// then drops every value.
    func importChecked(into sink: any PasswordImportSink, authenticators: AuthenticatorStore?) -> PasswordImportSummary {
        var summary = PasswordImportSummary()
        summary.unreadable = unreadable
        for entry in entries {
            guard entry.isChecked else {
                if entry.status == .duplicate { summary.duplicates += 1 }
                continue
            }
            switch entry.payload {
            case .password(let name, let value, let username, let urls, let notes):
                if entry.status == .changed, let id = entry.existingID {
                    if sink.updateLogin(id: id, value: value) { summary.updated += 1 } else { summary.failed += 1 }
                } else if sink.addLogin(name: name, value: value, username: username, urls: urls, notes: notes) {
                    summary.passwords += 1
                } else {
                    summary.failed += 1
                }
            case .authenticator(let account, let urls):
                if authenticators?.add(account, urls: urls) != nil { summary.authenticators += 1 } else { summary.failed += 1 }
            }
        }
        sink.finishImport()
        close()
        return summary
    }

    var isClosed: Bool { entries.isEmpty && unreadable == 0 }

    /// Drops every value (the review is gone).
    func close() {
        entries = []
        unreadable = 0
        search = ""
    }
}
