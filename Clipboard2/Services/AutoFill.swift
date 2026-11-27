import Foundation

// Filling by hand (docs/features/auth-autofill.md → Phase 2): the pure parts — what a field is,
// what to type into it, and which site a page belongs to. The Accessibility and keyboard side
// lives in FieldAccessibility.swift and FieldFiller.swift.

// MARK: - Field kinds

/// What a form field asks for, as far as a personal info card can answer it.
nonisolated enum FormFieldKind: String, CaseIterable, Codable, Sendable {
    case email, name, givenName, familyName, phone, company, street, postcode, city, country

    var title: String {
        switch self {
        case .email: "Email"
        case .name: "Name"
        case .givenName: "First name"
        case .familyName: "Last name"
        case .phone: "Phone"
        case .company: "Company"
        case .street: "Street"
        case .postcode: "Postcode"
        case .city: "City"
        case .country: "Country"
        }
    }

    var symbol: String {
        switch self {
        case .email: "envelope"
        case .name, .givenName, .familyName: "person"
        case .phone: "phone"
        case .company: "building.2"
        case .street, .postcode, .city: "house"
        case .country: "globe"
        }
    }
}

/// Guesses a field's kind from its accessibility label, placeholder and identifier (English and
/// German). Fields for logins, passwords, search and codes are never guessed.
nonisolated enum FormFieldGuesser {
    static func guess(_ hints: [String]) -> FormFieldKind? {
        let words = hints.map(normalized).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let text = " " + words.joined(separator: " ") + " "
        let tokens = Set(text.split(separator: " ").map(String.init))
        func has(_ needles: [String]) -> Bool { needles.contains { text.contains($0) } }
        func word(_ needles: [String]) -> Bool { needles.contains { tokens.contains($0) } }

        if has(["user name", "username", "benutzer", "login", "anmelde", "account", "konto", "passw", "kennwort",
                "search", "suche", "captcha", "verification", "verify", "one time", "coupon", "gutschein", "promo",
                "iban", "card number", "kartennummer", "cvc", "cvv"])
            || word(["otp", "pin", "tan", "query", "q"]) { return nil }
        // Before "code" rules a field out: "ZIP code", "Postal code".
        if has(["postcode", "post code", "postal", "zip", "postleitzahl"]) || word(["plz"]) { return .postcode }
        if word(["code"]) { return nil }
        if has(["e mail", "email"]) || word(["mail"]) { return .email }
        if has(["phone", "telefon", "telephone", "mobile", "mobil", "rufnummer"]) || word(["tel", "handy", "cell"]) { return .phone }
        if has(["country"]) || word(["land", "staat"]) { return .country }
        if has(["city", "town", "wohnort", "stadt", "locality", "gemeinde", "address level2"]) || word(["ort"]) { return .city }
        if has(["street", "strasse", "address line", "address1", "address 1", "adresse", "anschrift", "hausnummer"])
            || word(["address", "addr", "str"]) { return .street }
        if has(["company", "organization", "organisation", "firma", "firmen", "unternehmen", "business name"])
            || word(["org"]) { return .company }
        if has(["first name", "firstname", "given name", "givenname", "forename", "vorname"]) || word(["fname"]) { return .givenName }
        if has(["last name", "lastname", "surname", "family name", "familyname", "nachname", "familienname"])
            || word(["lname"]) { return .familyName }
        if has(["full name", "fullname", "your name", "ihr name"]) || word(["name"]) { return .name }
        return nil
    }

    /// Lower case, `ß` → `ss`, camelCase and punctuation split into words ("firstName" → "first name").
    static func normalized(_ hint: String) -> String {
        var out = ""
        var previous: Character?
        for char in hint {
            if char.isUppercase, let previous, previous.isLowercase { out.append(" ") }
            if char.isLetter || char.isNumber {
                out += String(char).lowercased()
            } else {
                out.append(" ")
            }
            previous = char
        }
        out = out.replacingOccurrences(of: "ß", with: "ss")
        return out.split(separator: " ").joined(separator: " ")
    }
}

/// Whether a focused field waits for a one-time code, so email codes are looked for faster.
/// `autocomplete="one-time-code"`, `inputmode` and `maxlength` aren't visible through
/// Accessibility, so it goes by the label, placeholder and identifier (English and German), or by
/// the row of narrow one-digit boxes many sites use.
nonisolated enum OneTimeCodeField {
    /// `width`: the field's; `siblingWidths`: the text fields with the same parent, itself included.
    static func matches(hints: [String], width: CGFloat?, siblingWidths: [CGFloat]) -> Bool {
        if isDigitBox(width: width, siblingWidths: siblingWidths) { return true }
        let words = hints.map(FormFieldGuesser.normalized).filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }
        let text = " " + words.joined(separator: " ") + " "
        let tokens = Set(text.split(separator: " ").map(String.init))
        func has(_ needles: [String]) -> Bool { needles.contains { text.contains($0) } }
        func word(_ needles: [String]) -> Bool { needles.contains { tokens.contains($0) } }
        // Codes that aren't one-time codes.
        if has(["zip", "postal", "postcode", "post code", "postleitzahl", "promo", "coupon", "gutschein", "voucher",
                "discount", "rabatt", "gift", "country code", "area code", "vorwahl", "ländercode", "landercode",
                "zip code", "referral", "invite", "einladung", "qr code", "source code", "swift", "bic", "iban",
                "cvc", "cvv", "card"])
            || word(["plz"]) { return false }
        if has(["one time", "onetime", "verification", "verify", "verifizierung", "bestatigungscode", "bestätigungscode",
                "bestaetigungscode", "sicherheitscode", "security code", "authentication code", "authenticator",
                "auth code", "login code", "sign in code", "signin code", "anmeldecode", "two factor", "2 factor",
                "zwei faktor", "passcode", "einmalcode", "einmal code", "confirmation code", "access code"])
            || word(["otp", "totp", "mfa", "2fa", "tan", "code", "pin"]) { return true }
        return false
    }

    /// One of four to eight equally narrow boxes in a row: one digit each.
    static func isDigitBox(width: CGFloat?, siblingWidths: [CGFloat]) -> Bool {
        guard let width, width > 0, width <= 64 else { return false }
        let alike = siblingWidths.filter { abs($0 - width) <= 4 }.count
        return (4...8).contains(alike)
    }
}

// MARK: - Fill plans

/// What the target app's focused field is.
nonisolated enum FocusedFieldKind: Equatable, Sendable {
    /// A password field.
    case secure
    /// A text field; `nextIsSecure` when the next field on the page is a password field.
    case text(nextIsSecure: Bool)
    /// Unknown (no Accessibility answer).
    case unknown
}

/// What Fill types.
nonisolated enum FillContent: Equatable, Sendable {
    case password(username: String?, password: String)
    /// An authenticator or email code, or any other single value.
    case text(String)
}

/// One step of filling: type text, or press Tab.
nonisolated enum FillStep: Equatable, Sendable {
    case type(String)
    case tab
}

nonisolated enum FillPlanner {
    /// - A password in a text field followed by a password field: username, Tab, password.
    /// - In a password field: only the password.
    /// - In a text field with no password field after it: the username (username-first sign-ins),
    ///   or the password when there's no username.
    /// - A code or other value: just that.
    static func plan(_ content: FillContent, focused: FocusedFieldKind) -> [FillStep] {
        switch content {
        case .text(let text):
            return text.isEmpty ? [] : [.type(text)]
        case .password(let username, let password):
            let user = username?.isEmpty == false ? username : nil
            switch focused {
            case .secure, .unknown:
                return [.type(password)]
            case .text(nextIsSecure: true):
                return user.map { [.type($0), .tab, .type(password)] } ?? [.tab, .type(password)]
            case .text(nextIsSecure: false):
                return [.type(user ?? password)]
            }
        }
    }

    /// Synthetic typing reaches the target unless another app holds Secure Event Input (a
    /// password field in the target itself is fine: its own secure input lets its events through).
    static func canType(secureInputPID: Int32?, targetPID: Int32?) -> Bool {
        guard let secureInputPID, secureInputPID > 0 else { return true }
        return secureInputPID == targetPID
    }
}

// MARK: - Sites

/// The browsers whose page URL Fill reads, and how.
nonisolated enum BrowserKind: Equatable, Sendable {
    /// `AXURL` of the web area, or the address field.
    case safari, chromium
    /// The window title only, best effort.
    case firefox

    static func of(bundleID: String?) -> BrowserKind? {
        guard let id = bundleID?.lowercased() else { return nil }
        if id.hasPrefix("com.apple.safari") { return .safari }
        if id.hasPrefix("org.mozilla.firefox") || id.hasPrefix("org.mozilla.nightly") { return .firefox }
        let chromium = ["com.google.chrome", "company.thebrowser.", "com.brave.browser", "com.microsoft.edgemac",
                        "com.vivaldi.vivaldi", "com.operasoftware.opera", "org.chromium.chromium"]
        return chromium.contains { id.hasPrefix($0) } ? .chromium : nil
    }
}

nonisolated enum SiteMatch {
    /// The source domain of a page URL or an address field's text ("github.com/login" → "github.com").
    static func domain(ofPage url: String, list: PublicSuffixList = .shared) -> String? {
        guard let domain = AuthSource.domain(ofSite: url, list: list), domain.contains(".") else { return nil }
        return domain
    }

    /// Firefox only exposes the title ("Sign in · GitHub — Mozilla Firefox"): a host-looking word
    /// in it, if any.
    static func domain(fromWindowTitle title: String, list: PublicSuffixList = .shared) -> String? {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "—–|·()[]<>\"'"))
        for word in title.components(separatedBy: separators) where word.contains(".") && !word.hasSuffix(".") {
            let candidate = word.trimmingCharacters(in: CharacterSet(charactersIn: ",;:!?"))
            // The last label has letters: "1.2.3" is a version, not a host.
            guard candidate.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z][A-Za-z0-9-]*(/.*)?$"#,
                                  options: .regularExpression) != nil,
                  let domain = domain(ofPage: candidate, list: list),
                  list.publicSuffix(of: domain).map({ $0 != domain }) == true else { continue }
            return domain
        }
        return nil
    }

    static func matches(_ ref: SecretRef, domain: String, list: PublicSuffixList = .shared) -> Bool {
        AuthSource.domains(ofSites: ref.urls, list: list).contains(domain)
    }

    static func matches(_ item: AuthenticatorItem, domain: String, list: PublicSuffixList = .shared) -> Bool {
        AuthSource.domains(ofSites: item.urls, list: list).contains(domain) || AuthSource.of(item, list: list)?.domain == domain
    }

    /// "Remember for ‹site›": the password's sites with this one added (unchanged if it's there).
    static func remembering(_ urls: [String], site: String, list: PublicSuffixList = .shared) -> [String] {
        guard let domain = domain(ofPage: site, list: list) else { return urls }
        if AuthSource.domains(ofSites: urls, list: list).contains(domain) { return urls }
        return SecretExtras.cleanURLs(urls + [domain])
    }
}

// MARK: - Suggest Strong Password

/// Fills fields in the target app (the real one types through Accessibility and key events).
@MainActor
protocol PasswordFieldFilling {
    /// Types into the focused password field.
    func fillFocused(_ text: String) async
    /// Types into the confirm field after it, if there is one; false when there's none.
    func fillConfirm(_ text: String) async -> Bool
}

/// Keeps a new password (SecretStore in the app).
@MainActor
protocol PasswordSaving {
    func savePassword(name: String, value: String, username: String?, urls: [String]) -> SecretRef?
    func deletePassword(_ ref: SecretRef)
}

/// What's known about the password field being filled.
nonisolated struct PasswordFieldContext: Equatable, Sendable {
    /// The page's source domain, if it's a browser page.
    var site: String?
    /// The nearest text field above, as typed there.
    var username: String?
}

/// Suggest Strong Password: fill it, fill the confirm field too, save it for the site.
@MainActor
enum StrongPasswordFlow {
    struct Result {
        var saved: SecretRef?
        var filledConfirm: Bool
        /// "Saved a password for ‹site›".
        var notice: String
    }

    static func run(password: String, context: PasswordFieldContext,
                    filler: some PasswordFieldFilling, saver: some PasswordSaving) async -> Result {
        await filler.fillFocused(password)
        let confirmed = await filler.fillConfirm(password)
        let username = SecretExtras.cleanUsername(context.username)
        let name = context.site ?? username ?? "Password"
        let saved = saver.savePassword(name: name, value: password, username: username,
                                       urls: context.site.map { [$0] } ?? [])
        let notice = saved == nil ? "Couldn't save the password"
            : context.site.map { "Saved a password for \($0)" } ?? "Saved a password"
        return Result(saved: saved, filledConfirm: confirmed, notice: notice)
    }

    /// Undo: the saved password goes again (what was typed stays in the page).
    static func undo(_ result: Result, saver: some PasswordSaving) {
        if let saved = result.saved { saver.deletePassword(saved) }
    }
}
