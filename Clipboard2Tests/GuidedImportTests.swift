import Testing
import Foundation
@testable import Clipboard2

// Guided import and the review list (docs/features/auth-autofill.md → Guided import).

final class FakeTrash: FileTrashing {
    var trashed: [URL] = []
    var restored: [(URL, URL)] = []

    func trash(_ url: URL) throws -> URL {
        trashed.append(url)
        return URL(fileURLWithPath: "/tmp/.Trash").appendingPathComponent(url.lastPathComponent)
    }

    func restore(_ trashed: URL, to original: URL) throws {
        restored.append((trashed, original))
    }
}

@MainActor
struct ExporterCSVTests {
    @Test func firefoxExport() throws {
        let csv = """
        "url","username","password","httpRealm","formActionOrigin","guid","timeCreated","timeLastUsed","timePasswordChanged"
        "https://accounts.firefox.com","me@example.com","fx-pass",,"https://accounts.firefox.com","{a1}","1700000000000","1700000000000","1700000000000"
        "https://www.example.org","","only-pass",,"","{a2}","1","1","1"
        """
        let rows = try PasswordCSV.rows(from: csv).get()
        #expect(rows.count == 2)
        #expect(rows[0].url == "https://accounts.firefox.com" && rows[0].username == "me@example.com" && rows[0].password == "fx-pass")
        #expect(rows[1].username.isEmpty && rows[1].password == "only-pass")
        #expect(PasswordImporter.name(for: rows[1]) == "example.org")
    }

    @Test func bitwardenExport() throws {
        let csv = """
        folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
        Work,1,login,GitHub,my notes,,0,"https://github.com/login,https://gist.github.com",octo,gh-pass,JBSWY3DPEHPK3PXP
        ,,login,Bank,,,0,https://bank.example.com,me,bank-pass,otpauth://totp/Bank:me?secret=JBSWY3DPEHPK3PXP&issuer=Bank
        ,,note,Wifi,The wifi code,,0,,,,
        """
        let rows = try PasswordCSV.rows(from: csv).get()
        #expect(rows.count == 3)
        #expect(rows[0].title == "GitHub" && rows[0].username == "octo" && rows[0].password == "gh-pass" && rows[0].notes == "my notes")
        #expect(rows[0].urls == ["https://github.com/login", "https://gist.github.com"])
        // A bare key becomes an authenticator named after the item.
        #expect(rows[0].authenticator?.issuer == "GitHub" && rows[0].authenticator?.account == "octo")
        #expect(rows[1].authenticator?.issuer == "Bank")

        let sink = FakeLoginSink()
        let store = AuthenticatorStore(backing: MemoryAuthenticatorBacking())
        let summary = PasswordImporter.run(rows, into: sink, authenticators: store)
        #expect(summary.passwords == 2 && summary.authenticators == 2 && summary.unreadable == 1)
        #expect(sink.logins.first?.urls == ["https://github.com/login", "https://gist.github.com"])
    }

    @Test func headerNames() {
        #expect(PasswordCSV.column(forHeader: "login_totp") == .otpauth)
        #expect(PasswordCSV.column(forHeader: "login_uri") == .url)
        #expect(PasswordCSV.column(forHeader: "login_username") == .username)
        #expect(PasswordCSV.column(forHeader: "httpRealm") == nil)
    }

    @Test func singleURLWithCommaStaysWhole() {
        let row = PasswordCSVRow(url: "https://example.com/?a=1,2")
        #expect(row.urls == ["https://example.com/?a=1,2"])
    }
}

@MainActor
struct ImportReviewTests {
    let csv = """
    name,url,username,password,otpauth
    GitHub,https://github.com/,octo,new-pass,
    Example,https://example.com/,me,same-pass,
    Example again,https://www.example.com/login,me,same-pass,
    Bank,https://bank.example.co.uk/,me,changed-pass,
    Codes,https://acme.com/,ann,,otpauth://totp/Acme:ann?secret=JBSWY3DPEHPK3PXP
    ,,,,
    """

    private func review(_ sink: FakeLoginSink = FakeLoginSink()) throws -> PasswordImportReview {
        sink.existing = [
            PasswordImporter.Login(urls: ["example.com"], username: "me", value: "same-pass", id: "e1"),
            PasswordImporter.Login(urls: ["bank.example.co.uk"], username: "ME", value: "old-pass", id: "b1"),
        ]
        return try PasswordImportReview.make(text: csv, fileName: "Passwords.csv", sink: sink, authenticators: nil).get()
    }

    @Test func statusesAndDefaults() throws {
        let review = try review()
        #expect(review.entries.map(\.status) == [.new, .duplicate, .duplicate, .changed, .authenticator])
        #expect(review.entries.map(\.isChecked) == [true, false, false, true, true])
        #expect(review.entries.map(\.site) == ["github.com", "example.com", "example.com", "example.co.uk", "Acme"])
        #expect(review.entries[3].existingID == "b1")
        #expect(review.unreadable == 1 && review.checkedCount == 3)
        // Duplicates can't be picked.
        review.setChecked(1, true)
        #expect(!review.entries[1].isChecked)
    }

    @Test func filterSearchAndSelectAll() throws {
        let review = try review()
        review.filter = .duplicates
        #expect(review.visible.map(\.id) == [1, 2])
        review.filter = .new
        #expect(review.visible.map(\.id) == [0, 4])
        review.filter = .changed
        #expect(review.visible.map(\.id) == [3])
        review.filter = .all
        review.search = "OCTO"
        #expect(review.visible.map(\.id) == [0])
        review.selectNone()
        #expect(review.checkedCount == 2)   // only the visible one changed
        review.search = ""
        review.selectNone()
        #expect(review.checkedCount == 0)
        review.selectAll()
        #expect(review.checkedCount == 3)   // duplicates stay unchecked
    }

    @Test func importsOnlyCheckedEntries() throws {
        let sink = FakeLoginSink()
        let review = try review(sink)
        let store = AuthenticatorStore(backing: MemoryAuthenticatorBacking())
        review.setChecked(0, false)   // not GitHub
        let summary = review.importChecked(into: sink, authenticators: store)
        #expect(sink.logins.isEmpty)
        #expect(sink.updates.map(\.id) == ["b1"] && sink.updates.first?.value == "changed-pass")
        #expect(store.owned.count == 1)
        #expect(summary.passwords == 0 && summary.updated == 1 && summary.authenticators == 1 && summary.duplicates == 2)
        #expect(summary.line == "Imported 0 passwords, updated 1, 1 authenticator, skipped 2 duplicates, skipped 1 empty row")
        #expect(sink.finished == 1)
        // The values are gone once the review closes.
        #expect(review.entries.isEmpty && review.isClosed)
    }
}

@MainActor
struct ExportWatcherTests {
    let now = Date(timeIntervalSince1970: 100_000)

    private func file(_ name: String, age: TimeInterval = 0, size: Int = 10) -> ExportFileCandidate {
        ExportFileCandidate(url: URL(fileURLWithPath: "/Users/x/Downloads/\(name)"), created: now.addingTimeInterval(-age), size: size)
    }

    @Test(arguments: [
        (PasswordExportSource.apple, "Passwords.csv", true), (.apple, "Passwords (1).csv", true), (.apple, "Chrome Passwords.csv", false),
        (.chromium, "Chrome Passwords.csv", true), (.chromium, "Microsoft Edge Passwords.csv", true), (.chromium, "Brave Passwords.csv", true),
        (.chromium, "logins.csv", false), (.firefox, "logins.csv", true), (.firefox, "logins (2).csv", true), (.firefox, "Passwords.csv", false),
        (.onePassword, "1PasswordExport-ABC-20261126-120000.csv", true), (.onePassword, "1Password Export.csv", true), (.onePassword, "logins.csv", false),
        (.bitwarden, "bitwarden_export_20261126120000.csv", true), (.bitwarden, "Passwords.csv", false),
        (.other, "anything.csv", true), (.other, "Passwords.csv.crdownload", false), (.apple, "Passwords.txt", false),
    ] as [(PasswordExportSource, String, Bool)])
    func fileNames(_ source: PasswordExportSource, _ name: String, _ matches: Bool) {
        #expect(source.matches(fileName: name) == matches, "\(source) \(name)")
    }

    @Test func picksTheNewestFreshNonEmptyMatch() {
        let since = now.addingTimeInterval(-60)
        let candidates = [
            file("Passwords.csv", age: 3_600),            // old: there before watching
            file("Passwords 2.csv", age: 30, size: 0),    // still empty
            file("Passwords 3.csv", age: 20),
            file("Passwords 4.csv", age: 10),
            file("logins.csv", age: 1),                   // another source's
        ]
        #expect(ExportFileMatcher.pick(candidates, source: .apple, since: since)?.lastPathComponent == "Passwords 4.csv")
        #expect(ExportFileMatcher.pick([file("Passwords.csv", age: 3_600)], source: .apple, since: since) == nil)
        // Saved just before watching started still counts.
        #expect(ExportFileMatcher.pick([file("Passwords.csv", age: 62)], source: .apple, since: since) != nil)
    }

    @Test func everySourceHasStepsAndOpeners() {
        for source in PasswordExportSource.allCases {
            #expect(!source.steps.isEmpty)
            #expect(ExportOpener.openers(for: source).isEmpty == (source == .other))
        }
        #expect(ExportOpener.openers(for: .firefox).first?.url == "about:logins")
        #expect(ExportOpener.openers(for: .chromium).map(\.name) == ["Chrome", "Arc", "Brave", "Edge"])
    }

    // MARK: The flow, with a real folder and a fake Trash

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GuidedImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let export = "url,username,password\nhttps://github.com,octo,pw1\nhttps://example.com,me,pw2\n"

    @Test func foundExportIsReviewedImportedAndTrashed() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("logins.csv")
        try export.write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -7_200)], ofItemAtPath: old.path)

        let sink = FakeLoginSink()
        let trash = FakeTrash()
        let center = PasswordImportCenter(sink: sink, authenticators: nil, trash: trash, folders: [dir])
        center.choose(.firefox)
        #expect(center.isWatching)
        center.checkFolders()
        #expect(center.review == nil)   // the old export is ignored

        let fresh = dir.appendingPathComponent("logins (1).csv")
        try export.write(to: fresh, atomically: true, encoding: .utf8)
        center.checkFolders()
        let review = try #require(center.review)
        #expect(review.entries.count == 2 && !center.isWatching)

        review.setChecked(1, false)
        center.importChecked()
        #expect(sink.logins.map(\.value) == ["pw1"])
        #expect(center.review == nil && review.entries.isEmpty)
        #expect(trash.trashed.map(\.lastPathComponent) == ["logins (1).csv"])
        #expect(center.result == "Imported 1 password")
        #expect(center.trashLine == "Moved “logins (1).csv” to the Trash.")

        center.undoTrash()
        #expect(trash.restored.first?.1.lastPathComponent == "logins (1).csv" && center.trashLine == nil)
        center.stopWatching()
    }

    @Test func cancelImportsNothingButStillTrashes() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Passwords.csv")
        try export.write(to: url, atomically: true, encoding: .utf8)
        let sink = FakeLoginSink()
        let trash = FakeTrash()
        let center = PasswordImportCenter(sink: sink, authenticators: nil, trash: trash, folders: [dir])
        center.load(url)
        let review = try #require(center.review)
        center.cancel()
        #expect(sink.logins.isEmpty && sink.finished == 0)
        #expect(review.entries.isEmpty && center.review == nil)
        #expect(trash.trashed == [url] && center.result == "Nothing imported")
    }

    @Test func notAnExportIsNotTrashed() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("budget.csv")
        try "month,amount\nJan,3".write(to: url, atomically: true, encoding: .utf8)
        let trash = FakeTrash()
        let center = PasswordImportCenter(sink: FakeLoginSink(), authenticators: nil, trash: trash, folders: [dir])
        center.load(url)
        #expect(center.review == nil && trash.trashed.isEmpty)
        #expect(center.result?.contains("no password column") == true)
    }
}
