import Testing
import Foundation
@testable import Clipboard2

// Auth's sources and the password generator (docs/features/auth-autofill.md, phase 1).

@MainActor
struct PublicSuffixTests {
    let list = PublicSuffixList.shared

    @Test func registrableDomains() {
        #expect(list.registrableDomain(of: "accounts.google.com") == "google.com")
        #expect(list.registrableDomain(of: "mail.google.com") == "google.com")
        #expect(list.registrableDomain(of: "google.com") == "google.com")
        #expect(list.registrableDomain(of: "WWW.GitHub.COM.") == "github.com")
        #expect(list.registrableDomain(of: "com") == nil)
    }

    @Test func multiLabelSuffixes() {
        #expect(list.registrableDomain(of: "www.bbc.co.uk") == "bbc.co.uk")
        #expect(list.registrableDomain(of: "login.bank.co.uk") == "bank.co.uk")
        #expect(list.registrableDomain(of: "co.uk") == nil)
        #expect(list.registrableDomain(of: "shop.example.com.au") == "example.com.au")
        #expect(list.registrableDomain(of: "finanzonline.bmf.gv.at") == "bmf.gv.at")
        #expect(list.registrableDomain(of: "me.github.io") == "me.github.io")
    }

    @Test func wildcardsAndExceptions() {
        #expect(list.publicSuffix(of: "foo.example.bd") == "example.bd")
        #expect(list.registrableDomain(of: "foo.example.bd") == "foo.example.bd")
        #expect(list.registrableDomain(of: "www.ck") == "www.ck")
        #expect(list.registrableDomain(of: "a.b.ck") == "a.b.ck")
    }

    @Test func sitesAsTypedOrImported() {
        #expect(AuthSource.domain(ofSite: "https://accounts.google.com/signin?x=1") == "google.com")
        #expect(AuthSource.domain(ofSite: "youtube.com") == "youtube.com")
        #expect(AuthSource.domain(ofSite: "  login.example.co.uk/path ") == "example.co.uk")
        #expect(AuthSource.domain(ofSite: "http://192.168.1.1:8080") == "192.168.1.1")
        #expect(AuthSource.domain(ofSite: "localhost:3000") == "localhost")
        #expect(AuthSource.domain(ofSite: "android://abc@com.example.app/") == nil)
        #expect(AuthSource.domain(ofSite: "") == nil)
        #expect(AuthSource.domains(ofSites: ["accounts.google.com", "mail.google.com", "youtube.com"]) == ["google.com", "youtube.com"])
    }
}

@MainActor
struct IssuerMappingTests {
    @Test func commonIssuersMapToTheirSites() {
        #expect(IssuerDomains.domain(for: "Google") == "google.com")
        #expect(IssuerDomains.domain(for: "GitHub") == "github.com")
        #expect(IssuerDomains.domain(for: "Battle.net") == "battle.net")
        #expect(IssuerDomains.domain(for: "Amazon Web Services") == "amazon.com")
        #expect(IssuerDomains.domain(for: "Google Workspace") == "google.com")
        #expect(IssuerDomains.domain(for: "Microsoft Azure") == "microsoft.com")
        #expect(IssuerDomains.domain(for: "accounts.firefox.com") == "firefox.com")
        #expect(IssuerDomains.domain(for: "Some Tiny Startup") == nil)
        // Short first words don't stand for the whole issuer.
        #expect(IssuerDomains.domain(for: "Max Mustermann GmbH") == nil)
        #expect(IssuerDomains.table.count >= 200)
    }

    @Test func authenticatorSources() {
        let github = AuthenticatorItem.owned(Authenticator(account: OTPAccount(issuer: "GitHub", account: "me", secret: "JBSWY3DPEHPK3PXP")))
        #expect(AuthSource.of(github) == .domain("github.com"))
        var custom = Authenticator(account: OTPAccount(issuer: "Acme Corp", account: "me", secret: "JBSWY3DPEHPK3PXP"))
        #expect(AuthSource.of(.owned(custom)) == .issuer("Acme Corp"))
        custom.urls = ["https://login.acme.io"]
        #expect(AuthSource.of(.owned(custom)) == .domain("acme.io"))
        let anonymous = Authenticator(account: OTPAccount(issuer: "", account: "me", secret: "JBSWY3DPEHPK3PXP"))
        #expect(AuthSource.of(.owned(anonymous)) == nil)
    }
}

@MainActor
struct AuthGroupingTests {
    private func secret(_ name: String, sites: [String] = [], username: String? = nil) -> SecretRef {
        SecretRef(id: UUID().uuidString, name: name, createdAt: nil, username: username, urls: sites)
    }

    @Test func groupsBySourceRecentFirstThenByNameNoWebsiteLast() {
        let google = secret("Google", sites: ["accounts.google.com"], username: "b@gmail.com")
        let gmail = secret("Gmail", sites: ["mail.google.com"], username: "a@gmail.com")
        let apple = secret("Apple", sites: ["appleid.apple.com"])
        let zed = secret("Zed", sites: ["zed.dev"])
        let token = secret("API token")
        let github = AuthenticatorItem.owned(Authenticator(account: OTPAccount(issuer: "GitHub", account: "me", secret: "JBSWY3DPEHPK3PXP")))

        let groups = PanelViewModel.authGroups(secrets: [token, zed, google, apple, gmail], authenticators: [github],
                                               lastUsed: ["zed.dev": .now])
        #expect(groups.map(\.title) == ["zed.dev", "apple.com", "github.com", "google.com", "No website"])
        // Within a source: passwords by username.
        let googleRows = groups[3].items.map(\.id)
        #expect(googleRows == ["k-" + gmail.id, "k-" + google.id])
        #expect(groups.last?.source == nil && groups.last?.items.map(\.id) == ["k-" + token.id])

        // Two used sources: the latest first.
        let later = PanelViewModel.authGroups(secrets: [google, apple, zed], authenticators: [],
                                              lastUsed: ["zed.dev": .now.addingTimeInterval(-60), "google.com": .now])
        #expect(later.map(\.title) == ["google.com", "zed.dev", "apple.com"])
    }

    @Test func usageIsRemembered() throws {
        let defaults = try #require(UserDefaults(suiteName: "AuthGroupingTests-\(UUID().uuidString)"))
        let usage = AuthSourceUsage(defaults: defaults)
        usage.record(.domain("google.com"), at: Date(timeIntervalSince1970: 100))
        usage.record(nil)
        #expect(AuthSourceUsage(defaults: defaults).lastUsed == ["google.com": Date(timeIntervalSince1970: 100)])
    }

    @Test func searchMatchesSourcesSitesUsernamesAndNamesNeverValues() {
        let ref = secret("Work mail", sites: ["https://accounts.google.com"], username: "me@corp.com")
        let text = PanelViewModel.authSearchText(ref)
        for query in ["google.com", "accounts", "me@corp", "Work mail"] {
            #expect(FuzzyMatcher.score(query: query, in: text) != nil, "\(query)")
        }
        #expect(!text.contains("hunter2"))
        let authenticator = AuthenticatorItem.owned(Authenticator(account: OTPAccount(issuer: "GitHub", account: "octo", secret: "JBSWY3DPEHPK3PXP")))
        let otpText = PanelViewModel.authSearchText(authenticator)
        #expect(otpText.contains("github.com") && otpText.contains("octo"))
        #expect(!otpText.contains("JBSWY3DPEHPK3PXP"))
    }

    @Test func authSearchInThePanelNeverMatchesValues() throws {
        let env = AppEnvironment.shared
        let ref = try #require(env.secrets.add(name: "Clipboard2 search test", value: "zqxjvalue", username: "searcher",
                                               urls: ["search-test.example"]))
        defer { env.secrets.delete(ref) }
        let model = PanelViewModel(env: env)
        model.filter = .auth
        model.query = "zqxjvalue"
        model.refresh()
        #expect(!model.entries.contains { $0.id == "k-" + ref.id })
        model.query = "searcher"
        model.refresh()
        #expect(model.entries.contains { $0.id == "k-" + ref.id })
        model.query = "search-test"
        model.refresh()
        #expect(model.entries.contains { $0.id == "k-" + ref.id })
        model.query = ""
        model.refresh()
        #expect(model.authSourceStarts.values.contains { $0.source == .domain("search-test.example") })
    }
}

@MainActor
struct PasswordFormTests {
    @Test func newPasswordSavesItsFields() throws {
        let env = AppEnvironment.shared
        let model = PanelViewModel(env: env)
        model.beginNewPassword()
        let form = try #require(model.editSecretForm)
        #expect(model.mode == .editSecret && form.isNew && form.showsPasswordFields)
        form.sites = ["https://accounts.form-test.example", "  "]
        form.username = "  formuser "
        form.generate()
        #expect(PasswordGenerator.isValid(form.value, options: form.generator))
        form.notes = "a note"
        model.submitEditSecret()
        #expect(model.mode == .browse)
        let saved = try #require(env.secrets.secrets.first { $0.username == "formuser" && $0.urls == ["https://accounts.form-test.example"] })
        defer { env.secrets.delete(saved) }
        #expect(saved.name == "form-test.example")
        #expect(SecretVault.notes(id: saved.id) == "a note")
    }

    @Test func editingASecretCanGiveItASite() throws {
        let env = AppEnvironment.shared
        let model = PanelViewModel(env: env)
        let ref = try #require(env.secrets.add(name: "Clipboard2 site test", value: "hunter2"))
        defer { env.secrets.delete(ref) }
        model.showEditSecret(ref, value: "hunter2")
        let form = try #require(model.editSecretForm)
        #expect(form.kind == .secret && form.showsPasswordFields)
        form.sites = ["example.org"]
        model.submitEditSecret()
        let updated = try #require(SecretVault.list().first { $0.id == ref.id })
        #expect(updated.urls == ["example.org"] && updated.isPassword && updated.name == "Clipboard2 site test")
        #expect(SecretVault.value(id: ref.id) == "hunter2")
    }

    @Test func aNewSecretNeedsANameAndAValue() throws {
        let model = PanelViewModel(env: AppEnvironment.shared)
        model.beginNewSecret()
        let form = try #require(model.editSecretForm)
        #expect(!form.showsPasswordFields)
        form.value = "v"
        model.submitEditSecret()
        #expect(model.mode == .editSecret && form.error != nil)
    }
}

struct PasswordGeneratorTests {
    @Test func defaultIsApplesStyle() {
        for _ in 0..<200 {
            let password = PasswordGenerator.generate()
            #expect(password.count == 20)
            let groups = password.split(separator: "-", omittingEmptySubsequences: false)
            #expect(groups.count == 3 && groups.allSatisfy { $0.count == 6 })
            #expect(password.contains(where: \.isUppercase) && password.contains(where: \.isNumber))
            #expect(password.allSatisfy { $0 == "-" || ($0.isASCII && ($0.isLetter || $0.isNumber)) })
            #expect(PasswordGenerator.isValid(password, options: .init()))
        }
    }

    @Test func otherLengthsAndSymbols() {
        for length in [8, 13, 14, 21, 32, 64] {
            for symbols in [false, true] {
                let options = PasswordGenerator.Options(length: length, symbols: symbols)
                for _ in 0..<50 {
                    let password = PasswordGenerator.generate(options)
                    #expect(PasswordGenerator.isValid(password, options: options), "\(password)")
                    #expect(!password.hasSuffix("-"))
                }
            }
        }
        #expect(PasswordGenerator.generate(.init(length: 3)).count == 8)
    }

    @Test func guaranteesHoldEvenWithAnUnluckyGenerator() {
        // Nearly always picks the first character (all lowercase "a") before the guarantees.
        // (A constant 0 would never end: Swift's bounded sampling rejects it forever.)
        struct Low: RandomNumberGenerator {
            var state: UInt64 = 0
            mutating func next() -> UInt64 { state &+= 1; return state }
        }
        var rng = Low()
        let password = PasswordGenerator.generate(.init(), using: &rng)
        #expect(PasswordGenerator.isValid(password, options: .init()), "\(password)")
        var rng2 = Low()
        let symbols = PasswordGenerator.generate(.init(length: 12, symbols: true), using: &rng2)
        #expect(PasswordGenerator.isValid(symbols, options: .init(length: 12, symbols: true)), "\(symbols)")
    }
}
