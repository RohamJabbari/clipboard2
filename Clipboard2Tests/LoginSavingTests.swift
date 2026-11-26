import Testing
import Foundation
@testable import Clipboard2

// Offering to save new logins (docs/features/auth-autofill.md → Saving logins).

@MainActor
final class FakeLoginSaveStore: LoginSaveStore {
    var saved: [(ref: SavedLoginRef, site: LoginSite, value: String)] = []
    var knownSecrets: Set<String> = []
    var added: [(site: LoginSite, username: String?, value: String)] = []
    var updated: [(id: String, value: String)] = []

    func savedLogins(for site: LoginSite) -> [SavedLoginRef] { saved.filter { $0.site == site }.map(\.ref) }
    func hasValue(_ value: SensitiveValue, id: String) -> Bool { saved.contains { $0.ref.id == id && value.equals($0.value) } }
    func isKnownSecret(_ value: SensitiveValue) -> Bool { knownSecrets.contains { value.equals($0) } }
    func saveLogin(site: LoginSite, username: String?, value: String) -> Bool {
        added.append((site, username, value))
        return true
    }
    func updateLogin(id: String, value: String) -> Bool {
        updated.append((id, value))
        return true
    }
}

@MainActor
final class FakeOfferPresenter: SaveOfferPresenting {
    var offers: [SaveOffer] = []
    var respond: ((SaveOfferResponse) -> Void)?
    var dismissals = 0

    func present(_ offer: SaveOffer, respond: @escaping (SaveOfferResponse) -> Void) {
        offers.append(offer)
        self.respond = respond
    }
    func dismiss() { dismissals += 1 }
}

struct SaveOfferPolicyTests {
    let github = LoginSite.web(domain: "github.com")

    private func decide(username: String? = "octo", saved: [SavedLoginRef] = [], same: Set<String> = [],
                        enabled: Bool = true, never: Set<String> = [], alreadySaved: Bool = false,
                        knownSecret: Bool = false) -> SaveOfferDecision {
        SaveOfferPolicy.decide(site: github, username: username, saved: saved, sameValue: { same.contains($0) },
                               enabled: enabled, neverSites: never, alreadySaved: alreadySaved, knownSecret: knownSecret)
    }

    @Test func newLoginIsOfferedForSaving() {
        #expect(decide() == .save)
        #expect(decide(saved: [SavedLoginRef(id: "a", username: "someone-else")]) == .save)
    }

    @Test func sameUsernameWithAnotherPasswordIsAnUpdate() {
        #expect(decide(username: "Octo", saved: [SavedLoginRef(id: "a", username: "octo")]) == .update(id: "a"))
    }

    @Test func sameValueIsNotOffered() {
        #expect(decide(saved: [SavedLoginRef(id: "a", username: "octo")], same: ["a"]) == .skip(.sameAsSaved))
        // The value is saved for the site under another username (or none): nothing new either.
        #expect(decide(username: nil, saved: [SavedLoginRef(id: "b", username: "x")], same: ["b"]) == .skip(.sameAsSaved))
    }

    @Test func neverSiteDisabledAndAlreadySavedAreSkipped() {
        #expect(decide(never: ["github.com"]) == .skip(.neverForSite))
        #expect(decide(never: ["gitlab.com"]) == .save)
        #expect(decide(enabled: false) == .skip(.disabled))
        #expect(decide(alreadySaved: true) == .skip(.alreadySaved))
        #expect(decide(knownSecret: true) == .skip(.alreadySaved))
    }

    @Test func unknownUsernameUpdatesTheSitesOnlyPassword() {
        #expect(decide(username: nil, saved: [SavedLoginRef(id: "a", username: "octo")]) == .update(id: "a"))
        #expect(decide(username: nil, saved: [SavedLoginRef(id: "a", username: "1"), SavedLoginRef(id: "b", username: "2")]) == .save)
    }

    @Test func appSites() {
        let app = LoginSite.app(bundleID: "com.example.mail", name: "Example Mail")
        #expect(app.key == "app:com.example.mail" && app.title == "Example Mail" && app.urls.isEmpty)
        #expect(app.matches(SecretRef(id: "1", name: "example mail", createdAt: nil)))
        #expect(!app.matches(SecretRef(id: "2", name: "Example Mail", createdAt: nil, urls: ["example.com"])))
        #expect(github.matches(SecretRef(id: "3", name: "x", createdAt: nil, urls: ["https://github.com/login"])))
    }
}

struct SubmitDetectorTests {
    let start = Date(timeIntervalSince1970: 1_000)

    @Test func returnAndLeavingForAButtonOrThePageSubmit() {
        var detector = SubmitDetector(page: "Sign in", at: start)
        let r1 = detector.handle(.returnKey, at: start)
        #expect(r1 == true)
        let r2 = detector.handle(.focusLeft(to: .button), at: start)
        #expect(r2 == true)
        let r3 = detector.handle(.focusLeft(to: .page), at: start)
        #expect(r3 == true)
    }

    @Test func otherFieldsAndOtherAppsDoNot() {
        var detector = SubmitDetector(page: "Sign in", at: start)
        let r4 = detector.handle(.focusLeft(to: .textField), at: start)
        #expect(r4 == false)
        let r5 = detector.handle(.focusLeft(to: .otherApp), at: start)
        #expect(r5 == false)
        let r6 = detector.handle(.page("Sign in"), at: start.addingTimeInterval(3))
        #expect(r6 == false)
        let r7 = detector.handle(.page(nil), at: start.addingTimeInterval(3))
        #expect(r7 == false)
    }

    @Test func pageChangeCountsWithinTenSeconds() {
        var detector = SubmitDetector(page: "Sign in", at: start)
        let r8 = detector.handle(.page("Dashboard"), at: start.addingTimeInterval(9))
        #expect(r8 == true)

        var late = SubmitDetector(page: "Sign in", at: start)
        let r9 = late.handle(.page("Dashboard"), at: start.addingTimeInterval(11))
        #expect(r9 == false)
        // Using the field again restarts the window.
        _ = late.handle(.secureActivity, at: start.addingTimeInterval(20))
        let r10 = late.handle(.page("Inbox"), at: start.addingTimeInterval(25))
        #expect(r10 == true)
    }

    @Test func unknownBaselineIsLearnedFirst() {
        var detector = SubmitDetector(page: nil, at: start)
        let r11 = detector.handle(.page("Sign in"), at: start.addingTimeInterval(1))
        #expect(r11 == false)
        let r12 = detector.handle(.page("Home"), at: start.addingTimeInterval(2))
        #expect(r12 == true)
    }

    @Test func pasteGuess() {
        #expect(PasteGuess.isPaste(oldLength: 0, newLength: 12, clipboard: "correct-hors"))
        #expect(PasteGuess.isPaste(oldLength: 3, newLength: 15, clipboard: "abcdefghijkl"))
        #expect(PasteGuess.isPaste(oldLength: 8, newLength: 12, clipboard: "abcdefghijkl"))   // replaced a selection
        #expect(!PasteGuess.isPaste(oldLength: 4, newLength: 5, clipboard: "abcdefghijkl"))   // typing
        #expect(!PasteGuess.isPaste(oldLength: 0, newLength: 2, clipboard: "ab"))             // too short to tell
        #expect(!PasteGuess.isPaste(oldLength: 0, newLength: 9, clipboard: "two\nlines"))
    }
}

@MainActor
struct LoginSaveCoordinatorTests {
    let github = LoginSite.web(domain: "github.com")
    let start = Date(timeIntervalSince1970: 5_000)

    private func make(never: Set<String> = []) -> (LoginSaveCoordinator, FakeLoginSaveStore, FakeOfferPresenter) {
        let store = FakeLoginSaveStore()
        let presenter = FakeOfferPresenter()
        let coordinator = LoginSaveCoordinator(store: store, presenter: presenter, neverSites: { never })
        return (coordinator, store, presenter)
    }

    @Test func pastedLoginIsOfferedAfterSubmitAndSaved() throws {
        let (coordinator, store, presenter) = make()
        coordinator.captured("hunter2-long", site: github, username: " octo ", page: "Sign in", at: start)
        let value = try #require(coordinator.pending?.value)
        coordinator.handle(.focusLeft(to: .textField), at: start)
        #expect(presenter.offers.isEmpty)
        coordinator.handle(.returnKey, at: start.addingTimeInterval(1))
        #expect(presenter.offers == [SaveOffer(kind: .save, site: github, username: "octo")])
        #expect(presenter.offers.first?.title == "Save password for github.com?")
        #expect(coordinator.pending == nil && !value.isZeroed)
        presenter.respond?(.save)
        #expect(store.added.count == 1 && store.added.first?.value == "hunter2-long" && store.added.first?.username == "octo")
        #expect(value.isZeroed && coordinator.offered == nil)
    }

    @Test func changedPasswordOffersUpdate() {
        let (coordinator, store, presenter) = make()
        store.saved = [(SavedLoginRef(id: "p1", username: "octo"), github, "old-password")]
        coordinator.captured("new-password", site: github, username: "octo", page: "Sign in", at: start)
        coordinator.handle(.page("Home"), at: start.addingTimeInterval(2))
        #expect(presenter.offers.first?.kind == .update)
        #expect(presenter.offers.first?.title == "Update password for github.com?")
        presenter.respond?(.save)
        #expect(store.updated.map(\.id) == ["p1"] && store.updated.first?.value == "new-password")
        #expect(store.added.isEmpty)
    }

    @Test func sameValueAndFilledValuesAreNeverOffered() throws {
        let (coordinator, store, presenter) = make()
        store.saved = [(SavedLoginRef(id: "p1", username: "octo"), github, "same-password")]
        coordinator.captured("same-password", site: github, username: "octo", page: nil, at: start)
        let same = try #require(coordinator.pending?.value)
        coordinator.handle(.returnKey, at: start)
        #expect(presenter.offers.isEmpty && coordinator.lastDecision == .skip(.sameAsSaved) && same.isZeroed)

        coordinator.captured("generated-password", site: github, username: "new", alreadySaved: true, page: nil, at: start)
        let filled = try #require(coordinator.pending?.value)
        coordinator.handle(.returnKey, at: start)
        #expect(presenter.offers.isEmpty && coordinator.lastDecision == .skip(.alreadySaved) && filled.isZeroed)
    }

    @Test func neverForThisSite() throws {
        var never: [LoginSite] = []
        let (coordinator, _, presenter) = make()
        coordinator.addNeverSite = { never.append($0) }
        coordinator.captured("password-1", site: github, username: "octo", page: nil, at: start)
        let value = try #require(coordinator.pending?.value)
        coordinator.handle(.returnKey, at: start)
        presenter.respond?(.never)
        #expect(never == [github] && value.isZeroed)

        let (blocked, _, blockedPresenter) = make(never: ["github.com"])
        blocked.captured("password-2", site: github, username: "octo", page: nil, at: start)
        blocked.handle(.returnKey, at: start)
        #expect(blockedPresenter.offers.isEmpty && blocked.lastDecision == .skip(.neverForSite))
    }

    @Test func valueIsZeroedOnTimeoutReplacementAndExpiry() throws {
        let (coordinator, store, presenter) = make()
        coordinator.captured("first-value", site: github, username: nil, page: nil, at: start)
        let first = try #require(coordinator.pending?.value)
        coordinator.captured("second-value", site: github, username: nil, page: nil, at: start)
        #expect(first.isZeroed)   // replaced

        let second = try #require(coordinator.pending?.value)
        coordinator.handle(.returnKey, at: start)
        presenter.respond?(.timedOut)
        #expect(second.isZeroed && store.added.isEmpty)

        coordinator.captured("third-value", site: github, username: nil, page: nil, at: start)
        let third = try #require(coordinator.pending?.value)
        coordinator.expire(at: start.addingTimeInterval(LoginSaveCoordinator.pendingLifetime + 1))
        #expect(third.isZeroed && coordinator.pending == nil)

        coordinator.captured("fourth-value", site: github, username: nil, page: nil, at: start)
        let fourth = try #require(coordinator.pending?.value)
        coordinator.invalidate()   // typed into after the paste
        #expect(fourth.isZeroed && coordinator.pending == nil)
    }

    @Test func disabledCapturesNothing() {
        let (coordinator, _, _) = make()
        coordinator.isEnabled = { false }
        coordinator.captured("password", site: github, username: nil, page: nil, at: start)
        #expect(coordinator.pending == nil)
    }

    @Test func sensitiveValue() {
        let value = SensitiveValue("pässword")
        #expect(value.equals("pässword") && !value.equals("password"))
        #expect(value.fits(length: 8) && !value.fits(length: 7))
        #expect(value.string == "pässword")
        value.zero()
        #expect(value.isZeroed && value.string == nil && !value.equals("pässword"))
    }
}
