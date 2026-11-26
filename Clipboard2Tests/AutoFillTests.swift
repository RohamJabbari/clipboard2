import Testing
import Foundation
@testable import Clipboard2

// Filling by hand (docs/features/auth-autofill.md, phase 2).

struct FormFieldGuesserTests {
    @Test(arguments: [
        // English labels, placeholders and identifiers
        (["Email address"], FormFieldKind.email), (["E-mail"], .email), (["user_email"], .email),
        (["Full name"], .name), (["Name"], .name), (["firstName"], .givenName), (["given-name"], .givenName),
        (["Last name"], .familyName), (["Surname"], .familyName), (["family-name"], .familyName),
        (["Phone number"], .phone), (["tel"], .phone), (["Mobile"], .phone),
        (["Company"], .company), (["organization"], .company),
        (["Street address"], .street), (["address-line1"], .street), (["Address"], .street),
        (["ZIP code"], .postcode), (["Postal code"], .postcode), (["postcode"], .postcode),
        (["City"], .city), (["address-level2"], .city), (["Town"], .city),
        (["Country"], .country), (["Country/Region"], .country),
        // German
        (["E-Mail-Adresse"], .email), (["Vorname"], .givenName), (["Nachname"], .familyName),
        (["Telefonnummer"], .phone), (["Handy"], .phone), (["Firma"], .company), (["Firmenname"], .company),
        (["Straße und Hausnummer"], .street), (["Strasse"], .street), (["PLZ"], .postcode),
        (["Postleitzahl"], .postcode), (["Ort"], .city), (["Wohnort"], .city), (["Land"], .country),
        // Placeholder beats an unhelpful identifier
        (["input-17", "Ihre E-Mail"], .email),
    ] as [([String], FormFieldKind)])
    func recognises(_ hints: [String], _ kind: FormFieldKind) {
        #expect(FormFieldGuesser.guess(hints) == kind, "\(hints)")
    }

    @Test(arguments: [["Username"], ["Benutzername"], ["Password"], ["Passwort"], ["Search"], ["Suche"],
                      ["Verification code"], ["Bestätigungscode"], ["Gutscheincode"], ["Login"], ["Account name"],
                      ["Message"], [""], []])
    func leavesOthersAlone(_ hints: [String]) {
        #expect(FormFieldGuesser.guess(hints) == nil, "\(hints)")
    }
}

struct FillPlanTests {
    @Test func passwordInAUsernameFieldBeforeAPasswordField() {
        #expect(FillPlanner.plan(.password(username: "me@x.com", password: "pw"), focused: .text(nextIsSecure: true))
                == [.type("me@x.com"), .tab, .type("pw")])
        // No username saved: skip to the password field.
        #expect(FillPlanner.plan(.password(username: nil, password: "pw"), focused: .text(nextIsSecure: true))
                == [.tab, .type("pw")])
    }

    @Test func passwordInAPasswordFieldIsOnlyThePassword() {
        #expect(FillPlanner.plan(.password(username: "me", password: "pw"), focused: .secure) == [.type("pw")])
        #expect(FillPlanner.plan(.password(username: "me", password: "pw"), focused: .unknown) == [.type("pw")])
    }

    @Test func usernameFirstSignIns() {
        #expect(FillPlanner.plan(.password(username: "me", password: "pw"), focused: .text(nextIsSecure: false)) == [.type("me")])
        #expect(FillPlanner.plan(.password(username: "", password: "pw"), focused: .text(nextIsSecure: false)) == [.type("pw")])
    }

    @Test func codesAreJustTheCode() {
        for focused in [FocusedFieldKind.secure, .text(nextIsSecure: true), .unknown] {
            #expect(FillPlanner.plan(.text("123456"), focused: focused) == [.type("123456")])
        }
        #expect(FillPlanner.plan(.text(""), focused: .unknown).isEmpty)
    }

    @Test func typingFallsBackOnlyWhenAnotherAppHoldsSecureInput() {
        #expect(FillPlanner.canType(secureInputPID: nil, targetPID: 42))
        #expect(FillPlanner.canType(secureInputPID: 0, targetPID: 42))
        #expect(FillPlanner.canType(secureInputPID: 42, targetPID: 42))
        #expect(!FillPlanner.canType(secureInputPID: 7, targetPID: 42))
    }
}

@MainActor
struct SiteMatchTests {
    private let list = PublicSuffixList(text: "com\nco.uk\norg\nde\nat\nio")

    @Test func pageURLsAndAddressFieldsGiveTheSource() {
        #expect(SiteMatch.domain(ofPage: "https://accounts.google.com/signin?x=1", list: list) == "google.com")
        #expect(SiteMatch.domain(ofPage: "github.com/login", list: list) == "github.com")
        #expect(SiteMatch.domain(ofPage: "https://www.bbc.co.uk/", list: list) == "bbc.co.uk")
        #expect(SiteMatch.domain(ofPage: "about:blank", list: list) == nil)
        #expect(SiteMatch.domain(ofPage: "Search Google or type a URL", list: list) == nil)
    }

    @Test func firefoxTitlesBestEffort() {
        #expect(SiteMatch.domain(fromWindowTitle: "Sign in · login.example.org — Mozilla Firefox", list: list) == "example.org")
        #expect(SiteMatch.domain(fromWindowTitle: "GitHub — Mozilla Firefox", list: list) == nil)
        #expect(SiteMatch.domain(fromWindowTitle: "Version 1.2.3 notes — Mozilla Firefox", list: list) == nil)
    }

    @Test func browsers() {
        #expect(BrowserKind.of(bundleID: "com.apple.Safari") == .safari)
        #expect(BrowserKind.of(bundleID: "com.google.Chrome.canary") == .chromium)
        #expect(BrowserKind.of(bundleID: "company.thebrowser.Browser") == .chromium)
        #expect(BrowserKind.of(bundleID: "com.brave.Browser") == .chromium)
        #expect(BrowserKind.of(bundleID: "com.microsoft.edgemac") == .chromium)
        #expect(BrowserKind.of(bundleID: "com.vivaldi.Vivaldi") == .chromium)
        #expect(BrowserKind.of(bundleID: "com.operasoftware.Opera") == .chromium)
        #expect(BrowserKind.of(bundleID: "org.mozilla.firefox") == .firefox)
        #expect(BrowserKind.of(bundleID: "com.apple.TextEdit") == nil)
    }

    @Test func passwordsMatchAnyOfTheirSites() {
        let ref = SecretRef(id: "1", name: "Google", username: "me", urls: ["https://accounts.google.com", "youtube.com"])
        #expect(SiteMatch.matches(ref, domain: "google.com", list: list))
        #expect(SiteMatch.matches(ref, domain: "youtube.com", list: list))
        #expect(!SiteMatch.matches(ref, domain: "github.com", list: list))
    }

    @Test func rememberAddsTheSiteOnce() {
        #expect(SiteMatch.remembering(["github.com"], site: "https://gist.github.com/x", list: list) == ["github.com"])
        #expect(SiteMatch.remembering(["github.com"], site: "https://login.example.org/a", list: list)
                == ["github.com", "example.org"])
        #expect(SiteMatch.remembering([], site: "example.org", list: list) == ["example.org"])
        #expect(SiteMatch.remembering(["a.com"], site: "not a site", list: list) == ["a.com"])
    }

    @Test func forSiteSectionPutsThePageFirst() throws {
        let env = AppEnvironment.shared
        let model = PanelViewModel(env: env)
        let matching = try #require(env.secrets.add(name: "fill-test", value: "pw", username: "filler",
                                                    urls: ["https://login.fill-test.example"]))
        let other = try #require(env.secrets.add(name: "other-fill-test", value: "pw", username: "other",
                                                 urls: ["other-fill-test.example"]))
        defer { env.secrets.delete(matching); env.secrets.delete(other) }
        let suggested = PanelViewModel.authSuggestions(secrets: [other, matching], authenticators: [], site: "fill-test.example")
        #expect(suggested.map(\.id) == ["k-" + matching.id])
        #expect(model.remembersSite(for: other) == nil)   // no page yet
        #expect(AuthSourceHeading(source: .domain("fill-test.example"), isSuggestion: true).title == "For fill-test.example")
    }
}

// MARK: - Suggest Strong Password

@MainActor
final class FakeFieldFiller: PasswordFieldFilling {
    var hasConfirm: Bool
    private(set) var focused: [String] = []
    private(set) var confirmed: [String] = []
    init(hasConfirm: Bool) { self.hasConfirm = hasConfirm }

    func fillFocused(_ text: String) async { focused.append(text) }
    func fillConfirm(_ text: String) async -> Bool {
        guard hasConfirm else { return false }
        confirmed.append(text)
        return true
    }
}

@MainActor
final class FakePasswordSaver: PasswordSaving {
    private(set) var saved: [SecretRef] = []
    private(set) var values: [String: String] = [:]

    func savePassword(name: String, value: String, username: String?, urls: [String]) -> SecretRef? {
        let ref = SecretRef(id: UUID().uuidString, name: name, username: username, urls: urls)
        saved.append(ref)
        values[ref.id] = value
        return ref
    }

    func deletePassword(_ ref: SecretRef) {
        saved.removeAll { $0.id == ref.id }
    }
}

@MainActor
struct StrongPasswordFlowTests {
    @Test func fillsBothFieldsAndSavesForTheSite() async {
        let filler = FakeFieldFiller(hasConfirm: true)
        let saver = FakePasswordSaver()
        let password = PasswordGenerator.suggestions().symbols
        let result = await StrongPasswordFlow.run(password: password,
                                                  context: PasswordFieldContext(site: "github.com", username: "  octo  "),
                                                  filler: filler, saver: saver)
        #expect(filler.focused == [password] && filler.confirmed == [password] && result.filledConfirm)
        #expect(saver.saved.count == 1)
        #expect(saver.saved.first?.name == "github.com" && saver.saved.first?.username == "octo")
        #expect(saver.saved.first?.urls == ["github.com"] && saver.values.values.first == password)
        #expect(result.notice == "Saved a password for github.com")

        StrongPasswordFlow.undo(result, saver: saver)
        #expect(saver.saved.isEmpty)
    }

    @Test func noConfirmFieldNoSiteNoUsername() async {
        let filler = FakeFieldFiller(hasConfirm: false)
        let saver = FakePasswordSaver()
        let result = await StrongPasswordFlow.run(password: "abc", context: PasswordFieldContext(), filler: filler, saver: saver)
        #expect(filler.focused == ["abc"] && filler.confirmed.isEmpty && !result.filledConfirm)
        #expect(saver.saved.first?.name == "Password" && saver.saved.first?.urls == [] && saver.saved.first?.username == nil)
        #expect(result.notice == "Saved a password")
    }
}

// MARK: - Personal info cards

@MainActor
struct PersonalCardTests {
    private func sample() -> PersonalCard {
        PersonalCard(label: "Work", name: "Anna Maria Huber", email: "anna@example.at", phone: "+43 1 234",
                     company: "Softmaze", street: "Ringstraße 1", postcode: "1010", city: "Wien", country: "Österreich")
    }

    @Test func roundTripsThroughItsBackend() {
        let backend = InMemoryCardBackend()
        let store = PersonalCardStore(backend: backend)
        #expect(store.cards.isEmpty)
        var card = sample()
        #expect(store.save(card))
        #expect(store.save(PersonalCard(label: "Home", email: "anna@home.example")))
        let reloaded = PersonalCardStore(backend: backend)
        #expect(reloaded.cards.count == 2 && reloaded.cards.first == card)
        card.city = "Graz"
        reloaded.save(card)
        #expect(PersonalCardStore(backend: backend).card(withID: card.id)?.city == "Graz")
        reloaded.delete(card)
        #expect(PersonalCardStore(backend: backend).cards.map(\.label) == ["Home"])
        #expect(reloaded.matches(for: .email).map(\.value) == ["anna@home.example"])
    }

    @Test func roundTripsThroughTheKeychain() {
        let backend = KeychainCardBackend(service: "at.softmaze.Clippy.tests.cards", account: "cards-\(UUID().uuidString)")
        defer { backend.remove() }
        let store = PersonalCardStore(backend: backend)
        #expect(store.save(sample()))
        #expect(PersonalCardStore(backend: backend).cards == [sample()].map { card in
            var copy = card
            copy.id = store.cards[0].id
            return copy
        })
    }

    @Test func valuesAndNameParts() {
        let card = sample()
        #expect(card.value(for: .givenName) == "Anna Maria" && card.value(for: .familyName) == "Huber")
        #expect(card.value(for: .postcode) == "1010" && card.value(for: .country) == "Österreich")
        #expect(card.values.map(\.kind) == PersonalCard.fields)
        let single = PersonalCard(label: "", name: "Cher")
        #expect(single.value(for: .givenName) == "Cher" && single.value(for: .familyName) == nil && single.title == "Cher")
        #expect(PersonalCard(label: "Empty").isEmpty)
    }
}

// MARK: - Two strong passwords

struct PasswordSuggestionTests {
    @Test func plainAndWithSymbolsSideBySide() {
        for _ in 0..<200 {
            let suggestions = PasswordGenerator.suggestions()
            #expect(suggestions.plain.count == 20 && suggestions.symbols.count == 20)
            #expect(PasswordGenerator.isValid(suggestions.plain, options: .init()))
            #expect(PasswordGenerator.isValid(suggestions.symbols, options: .init(symbols: true)))
            #expect(suggestions.symbols.contains(where: PasswordGenerator.symbolSet.contains))
            #expect(suggestions.symbols.contains(where: \.isUppercase) && suggestions.symbols.contains(where: \.isLowercase)
                    && suggestions.symbols.contains(where: \.isNumber))
            #expect(!suggestions.both.joined().contains { "\"'`\\ ".contains($0) })
        }
    }

    @MainActor
    @Test func formOffersBothAndUsesThePickedOne() throws {
        let model = PanelViewModel(env: AppEnvironment.shared)
        model.beginNewPassword()
        let form = try #require(model.editSecretForm)
        form.generate()
        let suggestions = try #require(form.suggestions)
        #expect(form.value.isEmpty)   // nothing is filled before picking
        form.use(suggestions.symbols)
        #expect(form.value == suggestions.symbols && form.suggestions == nil)
    }
}
