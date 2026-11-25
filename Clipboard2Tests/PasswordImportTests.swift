import Testing
import Foundation
@testable import Clipboard2

// Settings → Auth → Import CSV… (docs/features/auth-autofill.md, phase 1).

@MainActor
final class FakeLoginSink: PasswordImportSink {
    var logins: [(name: String, value: String, username: String?, urls: [String], notes: String?)] = []
    var existing: [PasswordImporter.Login] = []
    var finished = 0

    func existingLogins() -> [PasswordImporter.Login] { existing }
    func addLogin(name: String, value: String, username: String?, urls: [String], notes: String?) -> Bool {
        logins.append((name, value, username, urls, notes))
        return true
    }
    func finishImport() { finished += 1 }
}

@MainActor
struct PasswordImportTests {
    @Test func csvQuotingAndLineBreaks() {
        let rows = CSV.parse("\u{FEFF}a,b,c\r\n\"x, y\",\"he said \"\"hi\"\"\",\"line1\nline2\"\r\n\n1,,3")
        #expect(rows == [["a", "b", "c"], ["x, y", "he said \"hi\"", "line1\nline2"], ["1", "", "3"]])
    }

    @Test func applePasswordsExport() throws {
        let csv = """
        Title,URL,Username,Password,Notes,OTPAuth
        google.com (me@gmail.com),https://accounts.google.com/,me@gmail.com,pw1,,
        GitHub,https://github.com/,octo,"p,w2",recovery codes,otpauth://totp/GitHub:octo?secret=JBSWY3DPEHPK3PXP&issuer=GitHub
        """
        let sink = FakeLoginSink()
        let store = AuthenticatorStore(backing: MemoryAuthenticatorBacking())
        let summary = try PasswordImporter.run(csv, into: sink, authenticators: store).get()
        #expect(summary == PasswordImportSummary(passwords: 2, authenticators: 1))
        #expect(summary.line == "Imported 2 passwords, 1 authenticator")
        #expect(sink.logins.map(\.name) == ["google.com (me@gmail.com)", "GitHub"])
        #expect(sink.logins[1].value == "p,w2" && sink.logins[1].notes == "recovery codes")
        #expect(sink.logins[0].urls == ["https://accounts.google.com/"] && sink.logins[0].username == "me@gmail.com")
        #expect(store.owned.first?.issuer == "GitHub" && store.owned.first?.urls == ["https://github.com/"])
        #expect(sink.finished == 1)
    }

    @Test func chromeExportWithDuplicates() throws {
        let csv = """
        name,url,username,password,note
        accounts.google.com,https://accounts.google.com/signin,me@gmail.com,pw1,
        mail.google.com,https://mail.google.com/,me@gmail.com,pw1,
        example.com,https://example.com/,,pw3,
        ,,,,
        """
        let sink = FakeLoginSink()
        sink.existing = [PasswordImporter.Login(urls: ["example.com"], username: nil, value: "pw3")]
        let summary = try PasswordImporter.run(csv, into: sink, authenticators: nil).get()
        // The second Google row is the same login (same site, username and password).
        #expect(summary.passwords == 1 && summary.duplicates == 2 && summary.unreadable == 1)
        #expect(summary.line == "Imported 1 password, skipped 2 duplicates, skipped 1 empty row")
    }

    @Test func onePasswordExportWithHeaderVariants() throws {
        let csv = """
        "Title","Url","Username","Password","OTPAuth","Favorite","Archived","Tags","Notes"
        "Bank","https://bank.example.co.uk","me","s3cret","","false","false","","PIN 1234"
        "Codes only","","","","otpauth://totp/Acme:me?secret=JBSWY3DPEHPK3PXP","false","false","",""
        """
        let sink = FakeLoginSink()
        let store = AuthenticatorStore(backing: MemoryAuthenticatorBacking())
        let summary = try PasswordImporter.run(csv, into: sink, authenticators: store).get()
        #expect(summary.passwords == 1 && summary.authenticators == 1 && summary.duplicates == 0)
        #expect(sink.logins.first?.notes == "PIN 1234")
        #expect(store.owned.first?.issuer == "Acme")

        // Importing again: everything is a duplicate.
        sink.existing = sink.logins.map { PasswordImporter.Login(urls: $0.urls, username: $0.username, value: $0.value) }
        let again = try PasswordImporter.run(csv, into: sink, authenticators: store).get()
        #expect(again.passwords == 0 && again.authenticators == 0 && again.duplicates == 2)
    }

    @Test func notAPasswordExport() {
        let result = PasswordImporter.run("a,b\n1,2", into: FakeLoginSink(), authenticators: nil)
        #expect(throws: PasswordCSV.Problem.self) { try result.get() }
        #expect(PasswordCSV.column(forHeader: "Login URI") == .url)
        #expect(PasswordCSV.column(forHeader: "login_password") == .password)
        #expect(PasswordCSV.column(forHeader: "E-mail") == .username)
    }
}
