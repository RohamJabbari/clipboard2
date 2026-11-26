import Testing
import Foundation
@testable import Clipboard2

// Email codes (docs/features/auth-autofill.md, phase 4): recognising codes, MIME, IMAP responses,
// OAuth requests, expiry and where a code is listed. All synthetic: no real mail or accounts.

// MARK: - Corpus

nonisolated struct CodeSample: CustomTestStringConvertible, Sendable {
    var name: String
    var subject: String
    var body: String
    var code: String?
    var testDescription: String { name }
}

nonisolated enum EmailCorpus {
    static let samples: [CodeSample] = [
        // Google
        CodeSample(name: "Google sign-in", subject: "Google Verification Code",
                   body: "Google Verification Code\n\nTo help keep your account safe, Google wants to make sure it's really you trying to sign in.\n\nYour verification code is\n\n482913\n\nIf you didn't request this code, someone may be trying to access your Google Account. © 2026 Google LLC, 1600 Amphitheatre Parkway, Mountain View, CA 94043, USA",
                   code: "482913"),
        CodeSample(name: "Google subject first", subject: "G-718204 is your Google verification code",
                   body: "Use this code to finish setting up your account: 718204. This code will expire in 10 minutes.", code: "718204"),
        CodeSample(name: "Gmail recovery", subject: "Account recovery code",
                   body: "Hi Anna,\nWe received a request to recover your account anna.example@gmail.com.\nYour recovery code: 395 117\nGoogle", code: "395117"),
        // Microsoft
        CodeSample(name: "Microsoft security code", subject: "Microsoft account security code",
                   body: "Microsoft account\nSecurity code\n\nPlease use the following security code for the Microsoft account an*****@outlook.com.\n\nSecurity code: 4827193\n\nIf you don't recognize the Microsoft account an*****@outlook.com, you can click here to remove your email address from that account.\n\nThanks,\nThe Microsoft account team",
                   code: "4827193"),
        CodeSample(name: "Microsoft 365 single-use", subject: "Your single-use code",
                   body: "Hi an***@contoso.com,\n\nWe received your request for a single-use code to use with your Microsoft account.\n\nYour single-use code is: 902114\n\nOnly enter this code on an official website or app.", code: "902114"),
        // Apple
        CodeSample(name: "Apple ID email", subject: "Verify your Apple Account email address",
                   body: "Verify your email address\n\nApple Account\n\nTo verify your email address, enter this code in your browser.\n\n638201\n\nIf you didn't create an Apple Account, you can ignore this email. Apple Distribution International Ltd., Hollyhill Industrial Estate, Cork, Ireland",
                   code: "638201"),
        CodeSample(name: "Apple purchase confirm", subject: "Your verification code",
                   body: "Your verification code is: 104488\nThis code expires in 2 hours.", code: "104488"),
        // Amazon
        CodeSample(name: "Amazon OTP", subject: "Amazon.de: Sign-in attempt",
                   body: "Someone is attempting to sign in to your account.\nIf this was you, your one-time password (OTP) is:\n\n772391\n\nDon't share this OTP with anyone. Amazon will never ask you for it.",
                   code: "772391"),
        CodeSample(name: "Amazon new account", subject: "Verify your new Amazon account",
                   body: "To verify your email address, please use the following One Time Password (OTP):\n\n558102\n\nDo not share this OTP with anyone.", code: "558102"),
        // PayPal
        CodeSample(name: "PayPal security code", subject: "Your PayPal security code",
                   body: "Your PayPal security code is 293817. Don't share it with anyone. Your code expires in 10 minutes.", code: "293817"),
        CodeSample(name: "PayPal German", subject: "Ihr PayPal-Sicherheitscode",
                   body: "Hallo Max Mustermann,\nIhr Sicherheitscode lautet 661204. Geben Sie diesen Code nicht weiter.\nPayPal (Europe) S.à r.l. et Cie, S.C.A., 22-24 Boulevard Royal, L-2449 Luxembourg", code: "661204"),
        // Banks
        CodeSample(name: "Sparkasse TAN", subject: "Ihre TAN für die Anmeldung",
                   body: "Sehr geehrte Kundin, sehr geehrter Kunde,\nIhre TAN lautet: 845210\nDie TAN ist 5 Minuten gültig.\nIhre Sparkasse KölnBonn, Hahnenstraße 57, 50667 Köln, Tel. 0221 226-1", code: "845210"),
        CodeSample(name: "Bank PIN letter notice", subject: "Your login code",
                   body: "Dear customer,\nuse the login code 7730 to confirm your new device.\nCustomer number: 1234567890\nKind regards, Example Bank AG", code: "7730"),
        CodeSample(name: "N26 style", subject: "Bestätige dein Login",
                   body: "Hallo,\ndein Bestätigungscode: 381 902\nGültig für 5 Minuten.", code: "381902"),
        CodeSample(name: "Revolut style", subject: "Your Revolut code",
                   body: "Never share this code with anyone, including Revolut employees.\n\nCode: 405-118\n\nRevolut Ltd, 7 Westferry Circus, London E14 4HD", code: "405118"),
        // Developer and work tools
        CodeSample(name: "GitHub device", subject: "[GitHub] Please verify your device",
                   body: "Hey octocat!\n\nA sign in attempt requires further verification because we did not recognize your device. To complete the sign in, enter the verification code on the unrecognized device.\n\nDevice: Safari on macOS\nVerification code: 302148\n\nIf you did not attempt to sign in to your account, your password may be compromised. Visit https://github.com/settings/security to create a new, strong password for your GitHub account.\n\nThanks,\nThe GitHub Team",
                   code: "302148"),
        CodeSample(name: "GitHub launch code", subject: "Your GitHub launch code",
                   body: "Here's your GitHub launch code, @octocat!\n\n12345678\n\nContinue signing up for GitHub by entering the code above.", code: "12345678"),
        CodeSample(name: "Slack confirmation", subject: "Slack confirmation code: Q5G-B3T",
                   body: "Confirm your email address\n\nYour confirmation code is below — enter it in your open browser window and we'll help you get signed in.\n\nQ5G-B3T\n\nIf you didn't request this email, there's nothing to worry about.",
                   code: "Q5GB3T"),
        CodeSample(name: "Notion login code", subject: "Your Notion login code",
                   body: "Here is your Notion login code: 8KQ2ZT7M\nThis code expires in 10 minutes.", code: "8KQ2ZT7M"),
        CodeSample(name: "Atlassian verify", subject: "Verify your email for Atlassian",
                   body: "Your verification code is 590223. Enter it to finish creating your account.", code: "590223"),
        CodeSample(name: "Stripe passcode", subject: "Your Stripe passcode",
                   body: "Your Stripe passcode is 2418-0937. It expires in 10 minutes.", code: "24180937"),
        // German services
        CodeSample(name: "ELSTER", subject: "Mein ELSTER: Sicherheitscode",
                   body: "Guten Tag,\nIhr Sicherheitscode für die Anmeldung bei Mein ELSTER lautet:\n\n4K7P2Q9X\n\nBitte geben Sie diesen Code innerhalb von 30 Minuten ein.\nIhre Steuerverwaltung", code: "4K7P2Q9X"),
        CodeSample(name: "web.de", subject: "Ihr Bestätigungscode",
                   body: "Hallo,\nIhr Bestätigungscode lautet 834920.\nAus Sicherheitsgründen ist der Code nur 15 Minuten gültig.\nIhr WEB.DE Team\n1&1 Mail & Media GmbH, Brauerstraße 48, 76135 Karlsruhe, Amtsgericht Montabaur HRB 7666",
                   code: "834920"),
        CodeSample(name: "GMX Einmalcode", subject: "GMX: Ihr Einmalcode",
                   body: "Ihr Einmalcode: 227145\nGeben Sie ihn auf der Login-Seite ein.", code: "227145"),
        CodeSample(name: "Lieferando", subject: "Dein Lieferando-Anmeldecode",
                   body: "Hey!\nDein Anmeldecode lautet 4821.\nDer Code läuft in 15 Minuten ab.", code: "4821"),
        CodeSample(name: "DHL Kundenkonto", subject: "Ihr Verifizierungscode für DHL",
                   body: "Guten Tag,\nIhr Verifizierungscode für Ihr DHL Kundenkonto: 913 552\nDeutsche Post AG, Charles-de-Gaulle-Straße 20, 53113 Bonn", code: "913552"),
        CodeSample(name: "HTML-only stripped", subject: "Dein Code",
                   body: "Dein Code für die Anmeldung\nBitte gib diesen Code ein:\n730015\nGültig bis 26.11.2026, 14:30 Uhr", code: "730015"),
        CodeSample(name: "Order number nearby", subject: "Bestätigungscode für Ihre Bestellung",
                   body: "Bestellnummer: 30219988\nIhr Bestätigungscode lautet 664120.", code: "664120"),
        CodeSample(name: "Code after date line", subject: "Login code",
                   body: "Requested on 26.11.2026 at 10:42.\nYour login code is 118204.", code: "118204"),

        // Negatives
        CodeSample(name: "Newsletter promo", subject: "Nur heute: 20 % auf alles",
                   body: "Mit dem Gutscheincode SOMMER24 sparen Sie 20 % auf Ihren Einkauf. Jetzt einlösen bis 31.12.2026!", code: nil),
        CodeSample(name: "Promo code English", subject: "Black Friday deals inside",
                   body: "Use promo code SAVE2026X at checkout for 15% off. Shop now!", code: nil),
        CodeSample(name: "Invoice", subject: "Ihre Rechnung 2026-11-0042",
                   body: "Sehr geehrter Kunde,\nanbei Ihre Rechnung Nr. 48213 vom 26.11.2026.\nRechnungsbetrag: 1.249,90 EUR\nIBAN DE89 3704 0044 0532 0130 00\nKundennummer 552190", code: nil),
        CodeSample(name: "Shipping notice", subject: "Ihre Sendung ist unterwegs",
                   body: "Ihre DHL Sendung 00340434161094042557 wurde heute um 08:14 Uhr bearbeitet. Voraussichtliche Zustellung: 27.11.2026. Postleitzahl 50667. Fragen? Hotline 0228 4333112", code: nil),
        CodeSample(name: "Amazon order shipped", subject: "Your Amazon.de order #302-4567890-1234567 has shipped",
                   body: "Hello, your order 302-4567890-1234567 of 2 items has shipped. Order total: €84.99. Track your package at amazon.de.", code: nil),
        CodeSample(name: "Lieferando order confirmation", subject: "Deine Bestellung bei Pizza Roma",
                   body: "Bestellnummer 88213456\nSumme: 23,50 €\nLieferzeit ca. 45 Minuten\nTelefon des Restaurants: +49 221 123456", code: nil),
        CodeSample(name: "Meeting invite", subject: "Weekly sync",
                   body: "Join Zoom Meeting\nMeeting ID: 845 2211 9034\nPasscode: (see calendar)\nDial by your location +1 646 558 8656 US (New York)", code: nil),
        CodeSample(name: "Newsletter numbers", subject: "Your 2026 year in review",
                   body: "This year you listened to 48213 minutes of music and discovered 1204 new artists. See you in 2027!", code: nil),
        CodeSample(name: "Bank statement", subject: "Kontoauszug November",
                   body: "Ihr Kontoauszug Nr. 11/2026 für Konto 1234567 ist da. Kontostand: 2.450,10 EUR. Ihre Sparkasse", code: nil),
        CodeSample(name: "Postcode", subject: "Address change confirmed",
                   body: "We updated your delivery address. New postcode: 1010 Wien. Order reference 554321.", code: nil),
        CodeSample(name: "QR code ticket", subject: "Ihr Ticket",
                   body: "Zeigen Sie den QR-Code beim Einlass. Ticketnummer 77231904. Sitzplatz 14, Reihe 7.", code: nil),
        CodeSample(name: "Password changed notice", subject: "Your password was changed",
                   body: "Your Google Account password was changed on November 26, 2026. If you didn't change it, contact us.", code: nil),
    ]
}

@MainActor
struct EmailCodeExtractionTests {
    @Test(arguments: EmailCorpus.samples)
    func corpus(_ sample: CodeSample) {
        #expect(EmailCodeExtractor.code(subject: sample.subject, body: sample.body) == sample.code)
    }

    @Test func corpusIsBigEnough() {
        #expect(EmailCorpus.samples.count >= 40)
        #expect(EmailCorpus.samples.filter { $0.code == nil }.count >= 10)
    }

    @Test func closestToTheKeywordWins() {
        let body = "Reference 4417 was opened.\n\nYour verification code: 902731\n\nOther number: 5512"
        #expect(EmailCodeExtractor.code(subject: "Hi", body: body) == "902731")
    }

    @Test func excludesYearsDatesAmountsAndPhones() {
        #expect(EmailCodeExtractor.code(subject: "Code", body: "Your code arrives in 2026.") == nil)
        #expect(EmailCodeExtractor.code(subject: "Code", body: "Code valid until 26.11.2026") == nil)
        #expect(EmailCodeExtractor.code(subject: "Code", body: "Your code costs € 4500") == nil)
        #expect(EmailCodeExtractor.code(subject: "Code", body: "Code questions? Call +43 1 234 5678") == nil)
        #expect(EmailCodeExtractor.code(subject: "Code", body: "Code for order #554433") == nil)
    }

    @Test func noKeywordNoCode() {
        #expect(EmailCodeExtractor.code(subject: "Lunch?", body: "Table 4 at 123456 Main Street") == nil)
    }

    @Test func linksAndAddressesAreIgnored() {
        let body = "Verify here: https://example.com/verify?token=884422&id=553311 or write to code-123456@example.com"
        #expect(EmailCodeExtractor.code(subject: "Verify", body: body) == nil)
    }
}

// MARK: - MIME

@MainActor
struct MIMETests {
    @Test func quotedPrintableAndCharset() {
        let raw = "From: =?UTF-8?Q?Sparkasse_K=C3=B6ln?= <noreply@sparkasse.de>\r\nSubject: =?ISO-8859-1?Q?Ihre_Best=E4tigung?=\r\nContent-Type: text/plain; charset=\"iso-8859-1\"\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nIhr Best=E4tigungscode lautet 552=\r\n910.\r\n"
        let message = MIMEMessage(data: Data(raw.utf8))
        #expect(message.from == "Sparkasse Köln <noreply@sparkasse.de>")
        #expect(message.subject == "Ihre Bestätigung")
        #expect(message.text.contains("Bestätigungscode lautet 552910."))
    }

    @Test func base64EncodedWordsJoin() {
        #expect(MIME.decodeEncodedWords("=?UTF-8?B?SWhyIENvZGU=?= =?UTF-8?B?OiDDvGJlcg==?=") == "Ihr Code: über")
        #expect(MIME.decodeEncodedWords("Plain subject") == "Plain subject")
    }

    @Test func multipartPrefersPlainText() {
        let raw = """
        From: GitHub <noreply@github.com>\r
        Subject: Verify\r
        MIME-Version: 1.0\r
        Content-Type: multipart/alternative; boundary="b1"\r
        \r
        preamble\r
        --b1\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: base64\r
        \r
        VmVyaWZpY2F0aW9uIGNvZGU6IDMwMjE0OA==\r
        --b1\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>Verification code: <b>999999</b></p>\r
        --b1--\r
        """
        let message = MIMEMessage(data: Data(raw.utf8))
        #expect(message.text == "Verification code: 302148")
    }

    @Test func htmlOnlyIsStripped() {
        let raw = """
        Subject: Code\r
        Content-Type: multipart/mixed; boundary=outer\r
        \r
        --outer\r
        Content-Type: multipart/alternative; boundary=inner\r
        \r
        --inner\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        <html><head><style>p{color:red}</style></head><body><p>Dein Best&auml;tigungscode:</p><div style=3D"font-size:24px">730&#48;15</div><script>var x=3D1;</script></body></html>\r
        --inner--\r
        --outer\r
        Content-Type: application/pdf; name=a.pdf\r
        Content-Disposition: attachment\r
        Content-Transfer-Encoding: base64\r
        \r
        JVBERi0=\r
        --outer--\r
        """
        let text = MIMEMessage(data: Data(raw.utf8)).text
        #expect(text == "Dein Bestätigungscode:\n730015")
        #expect(EmailCodeExtractor.code(subject: "Code", body: text) == "730015")
    }

    @Test func truncatedMultipartStillReads() {
        let body = "--x\r\nContent-Type: text/plain\r\n\r\nYour code is 445566\r\n--x\r\nContent-Type: text/html\r\n\r\n<p>cut off he"
        let parts = MIME.splitMultipart(Data(body.utf8), boundary: "x")
        #expect(parts.count == 2)
        #expect(MIME.text(headers: ["content-type": "multipart/alternative; boundary=x"], body: Data(body.utf8)) == "Your code is 445566")
    }

    @Test func base64Tolerance() {
        #expect(MIME.decodeBase64(Data("SGVs\r\nbG8=".utf8)) == Data("Hello".utf8))
        #expect(MIME.decodeBase64(Data("SGVsbG8".utf8)) == Data("Hello".utf8))   // unpadded (base64url)
        #expect(MIME.decodeBase64(Data("PGI-_w".utf8)) == Data([0x3C, 0x62, 0x3E, 0xFF]))
    }

    @Test func addressesAndDates() {
        #expect(MIME.address(inFrom: "\"Google\" <No-Reply@Accounts.Google.com>") == "no-reply@accounts.google.com")
        #expect(MIME.address(inFrom: "security@paypal.de") == "security@paypal.de")
        #expect(MIME.domain(ofAddress: "a@mail.example.co.uk") == "mail.example.co.uk")
        #expect(MIME.parseDate("Thu, 26 Nov 2026 10:04:12 +0100 (CET)") != nil)
    }
}

// MARK: - IMAP

@MainActor
struct IMAPParserTests {
    @Test func fetchWithLiterals() {
        let header = "From: PayPal <service@paypal.de>\r\nSubject: Code\r\n\r\n"
        let text = "Your PayPal security code is 293817."
        let response = "* 12 FETCH (UID 345 INTERNALDATE \" 6-Nov-2026 10:04:12 +0100\" BODY[HEADER.FIELDS (FROM SUBJECT DATE)] {\(header.utf8.count)}\r\n\(header) BODY[TEXT]<0> {\(text.utf8.count)}\r\n\(text))\r\n"
        let fetched = IMAPParser.fetched(in: [Data(response.utf8)])
        #expect(fetched.count == 1)
        #expect(fetched.first?.uid == 345)
        #expect(fetched.first?.header == Data(header.utf8))
        #expect(fetched.first?.text == Data(text.utf8))
        let date = fetched.first?.internalDate
        #expect(date == ISO8601DateFormatter().date(from: "2026-11-06T09:04:12Z"))

        let message = IMAPMailSource.message(fetched[0])
        #expect(message.subject == "Code")
        #expect(EmailCodeSender.source(ofFrom: message.from) == "paypal.de")
        #expect(EmailCodeExtractor.code(subject: message.subject, body: message.text) == "293817")
    }

    @Test func fetchWithNilAndQuoted() {
        let response = "* 3 FETCH (INTERNALDATE \"26-Nov-2026 10:00:00 +0000\" UID 9 BODY[TEXT]<0> \"hi \\\"there\\\"\" BODY[HEADER.FIELDS (FROM)] NIL)"
        let fetched = IMAPParser.fetched(in: [Data(response.utf8)])
        #expect(fetched == [IMAPFetched(uid: 9, internalDate: IMAPParser.internalDate("26-Nov-2026 10:00:00 +0000"),
                                         header: nil, text: Data("hi \"there\"".utf8))])
    }

    @Test func searchCapabilitiesAndValidity() {
        #expect(IMAPParser.searchResults(in: [Data("* SEARCH 4 9 12\r\n".utf8)]) == [4, 9, 12])
        #expect(IMAPParser.searchResults(in: [Data("* SEARCH\r\n".utf8)]) == [])
        let caps = IMAPParser.capabilities(in: [Data("* OK [CAPABILITY IMAP4rev1 IDLE AUTH=PLAIN] Ready\r\n".utf8)])
        #expect(caps.contains("IDLE"))
        #expect(IMAPParser.capabilities(in: [Data("* CAPABILITY IMAP4rev1 UIDPLUS\r\n".utf8)]) == ["IMAP4REV1", "UIDPLUS"])
        #expect(IMAPParser.uidValidity(in: [Data("* 3 EXISTS\r\n".utf8), Data("* OK [UIDVALIDITY 3857529045] UIDs valid\r\n".utf8)]) == 3857529045)
    }

    @Test func lineHelpers() {
        #expect(IMAPParser.literalLength(atEndOf: Data("* 1 FETCH (BODY[TEXT] {42}\r\n".utf8)) == 42)
        #expect(IMAPParser.literalLength(atEndOf: Data("* 1 FETCH (UID 4)\r\n".utf8)) == nil)
        #expect(IMAPParser.status(of: "C7 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n", tag: "C7")?.status == "NO")
        #expect(IMAPParser.status(of: "C71 OK done", tag: "C7") == nil)
        #expect(IMAPClient.humanText("[AUTHENTICATIONFAILED] Invalid credentials") == "Invalid credentials")
        #expect(IMAPParser.quoted("pa\"ss\\word") == "\"pa\\\"ss\\\\word\"")
        #expect(IMAPParser.searchDate(ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z")!) == "5-Nov-2026")
        #expect(IMAPParser.uidSet([12, 4, 9]) == "4,9,12")
    }
}

// MARK: - Accounts and providers

@MainActor
struct EmailAccountTests {
    @Test func providersHiddenWithoutClientIDs() {
        #expect(OAuthClients().availableProviders == [.imap])
        #expect(OAuthClients(microsoftClientID: "  ").availableProviders == [.imap])
        #expect(OAuthClients(microsoftClientID: "abc").availableProviders == [.microsoft, .imap])
        #expect(OAuthClients(dictionary: ["MicrosoftClientID": "m", "GoogleClientID": "g", "GoogleClientSecret": "s"])
            .availableProviders == [.microsoft, .google, .imap])
    }

    @Test func bundledConfigShipsEmpty() {
        // The owner fills OAuthClients.plist; until then only IMAP is offered (no invented ids).
        let url = Bundle(for: EmailCodeCenter.self).url(forResource: "OAuthClients", withExtension: "plist")
        #expect(url != nil)
    }

    @Test func imapPresets() {
        #expect(IMAPPresets.guess(for: "me@gmail.com") == .preset(IMAPPresets.gmail))
        #expect(IMAPPresets.guess(for: "Me@GMX.de") == .preset(IMAPPresets.gmx))
        #expect(IMAPPresets.guess(for: "x@web.de") == .preset(IMAPPresets.webde))
        #expect(IMAPPresets.guess(for: "x@icloud.com") == .preset(IMAPPresets.icloud))
        #expect(IMAPPresets.guess(for: "x@yahoo.com") == .preset(IMAPPresets.yahoo))
        #expect(IMAPPresets.guess(for: "x@aol.com") == .preset(IMAPPresets.aol))
        #expect(IMAPPresets.guess(for: "x@hotmail.com") == .useMicrosoft)
        #expect(IMAPPresets.guess(for: "x@outlook.com") == .useMicrosoft)
        #expect(IMAPPresets.guess(for: "x@softmaze.at") == .guessed(IMAPSettings(host: "imap.softmaze.at")))
        #expect(IMAPPresets.guess(for: "nope") == .invalid)
        #expect(IMAPPresets.gmail.host == "imap.gmail.com" && IMAPPresets.yahoo.host == "imap.mail.yahoo.com")
        #expect(IMAPPresets.icloud.host == "imap.mail.me.com" && IMAPPresets.aol.host == "imap.aol.com")
    }

    @Test func senderToSource() {
        #expect(EmailCodeSender.source(ofFrom: "Google <no-reply@accounts.google.com>") == "google.com")
        #expect(EmailCodeSender.source(ofFrom: "no-reply@microsoft.com") == "microsoft.com")
        #expect(EmailCodeSender.source(ofFrom: "Microsoft account team <account-security-noreply@accountprotection.microsoft.com>") == "microsoft.com")
        #expect(EmailCodeSender.source(ofFrom: "\"WEB.DE\" <keineantwort@web.de>") == "web.de")
        #expect(EmailCodeSender.source(ofFrom: "Amazon <account-update@amazon.co.uk>") == "amazon.co.uk")
        #expect(EmailCodeSender.source(ofFrom: "no address") == nil)
    }

    @Test func vaultRoundTrip() {
        let vault = MemoryEmailVault()
        let center = EmailCodeCenter(vault: vault, clients: OAuthClients(), defaults: UserDefaults(suiteName: "emailtests-\(UUID())")!)
        let account = EmailAccount(provider: .imap, address: " Me@Example.com ", imap: IMAPSettings(host: "imap.example.com"))
        center.add(account, credential: .password("app-pass"))
        #expect(center.accounts.map(\.address) == ["me@example.com"])
        #expect(vault.decode(EmailCredential.self, EmailVaultKey.credential(center.accounts[0].id)) == .password("app-pass"))
        // The same address again replaces, never duplicates.
        center.add(account, credential: .password("new"))
        #expect(center.accounts.count == 1)
        center.remove(center.accounts[0])
        #expect(center.accounts.isEmpty)
        #expect(vault.items.keys.filter { $0.hasPrefix("credential.") }.isEmpty)
    }
}

// MARK: - OAuth

@MainActor
struct OAuthTests {
    @Test func pkceMatchesRFC7636() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = PKCE.makeVerifier()
        #expect(verifier.count == 43)
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(PKCE.makeVerifier() != verifier)
    }

    @Test func microsoftAuthorizeURL() throws {
        let endpoints = try #require(OAuthEndpoints.of(.microsoft))
        let redirect = OAuthRequests.redirectURI(host: endpoints.redirectHost, port: 51234)
        #expect(redirect == "http://localhost:51234")
        let url = OAuthRequests.authorizeURL(endpoints, clientID: "client-1", redirectURI: redirect, state: "st", challenge: "ch")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host() == "login.microsoftonline.com")
        #expect(items["client_id"] == "client-1")
        #expect(items["response_type"] == "code")
        #expect(items["redirect_uri"] == "http://localhost:51234")
        #expect(items["code_challenge"] == "ch")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "st")
        #expect(items["scope"]?.contains("https://graph.microsoft.com/Mail.Read") == true)
        #expect(items["scope"]?.contains("offline_access") == true)
    }

    @Test func googleRequests() throws {
        let endpoints = try #require(OAuthEndpoints.of(.google))
        let redirect = OAuthRequests.redirectURI(host: endpoints.redirectHost, port: 6000)
        #expect(redirect == "http://127.0.0.1:6000")
        let url = OAuthRequests.authorizeURL(endpoints, clientID: "g.apps.googleusercontent.com", redirectURI: redirect,
                                             state: "s", challenge: "c")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "scope", value: "openid email https://www.googleapis.com/auth/gmail.readonly")))
        #expect(query.contains(URLQueryItem(name: "access_type", value: "offline")))

        let exchange = OAuthRequests.codeExchange(endpoints, clientID: "g", clientSecret: "sec", code: "a/b+c",
                                                  redirectURI: redirect, verifier: "v")
        let body = String(decoding: exchange.httpBody ?? Data(), as: UTF8.self)
        #expect(exchange.httpMethod == "POST")
        #expect(exchange.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=a%2Fb%2Bc"))
        #expect(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A6000"))
        #expect(body.contains("code_verifier=v"))
        #expect(body.contains("client_secret=sec"))

        let refresh = OAuthRequests.refresh(try #require(OAuthEndpoints.of(.microsoft)), clientID: "m", clientSecret: nil, refreshToken: "r1")
        let refreshBody = String(decoding: refresh.httpBody ?? Data(), as: UTF8.self)
        #expect(refreshBody.contains("grant_type=refresh_token") && refreshBody.contains("refresh_token=r1"))
        #expect(!refreshBody.contains("client_secret"))
    }

    @Test func callbackAndTokens() throws {
        #expect(OAuthRequests.callbackParameters(requestLine: "GET /?code=4%2F0Ab&state=xyz HTTP/1.1") == ["code": "4/0Ab", "state": "xyz"])
        #expect(OAuthRequests.callbackParameters(requestLine: "POST / HTTP/1.1") == nil)

        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = #"{"access_token":"at","refresh_token":"rt","expires_in":3599,"id_token":"x.eyJlbWFpbCI6Ik1lQEV4YW1wbGUuY29tIn0.y"}"#
        let (tokens, idToken) = try OAuthTokenClient.tokens(from: Data(json.utf8), status: 200, now: now)
        #expect(tokens == OAuthTokens(accessToken: "at", refreshToken: "rt", expiresAt: now.addingTimeInterval(3599)))
        #expect(idToken.flatMap(OAuthRequests.email(fromIDToken:)) == "me@example.com")
        // Google's refresh answer has no refresh token: the old one stays.
        let refreshed = try OAuthTokenClient.tokens(from: Data(#"{"access_token":"at2","expires_in":3600}"#.utf8), status: 200,
                                                    previousRefreshToken: "rt", now: now).0
        #expect(refreshed.refreshToken == "rt")
        #expect(throws: OAuthError.needsSignIn) {
            try OAuthTokenClient.tokens(from: Data(#"{"error":"invalid_grant"}"#.utf8), status: 400)
        }
        #expect(tokens.isFresh(at: now) && !tokens.isFresh(at: now.addingTimeInterval(3560)))
    }

    @Test func gmailAndGraphParsing() throws {
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(GmailSource.listURL(since: since).absoluteString.contains("after:1790000000"))
        #expect(GraphMailSource.url(since: since).absoluteString.contains("receivedDateTime%20ge%202026-"))

        let raw = PKCE.base64URL(Data("From: Google <no-reply@accounts.google.com>\r\nSubject: Code\r\n\r\nYour verification code is 482913".utf8))
        let gmail = try GmailSource.parseRaw(Data(#"{"id":"m1","internalDate":"1790000000000","raw":"\#(raw)"}"#.utf8))
        #expect(gmail.receivedAt == since && gmail.subject == "Code" && gmail.text.contains("482913"))

        let graph = try GraphMailSource.parse(Data(#"{"value":[{"id":"g1","subject":"Security code","receivedDateTime":"2026-11-26T10:00:00Z","from":{"emailAddress":{"name":"Microsoft","address":"account-security-noreply@accountprotection.microsoft.com"}},"body":{"contentType":"html","content":"<p>Security code: <b>4827193</b></p>"}}]}"#.utf8))
        #expect(graph.count == 1)
        #expect(EmailCodeSender.source(ofFrom: graph[0].from) == "microsoft.com")
        #expect(graph[0].text == "Security code: 4827193")
    }
}

// MARK: - Codes: found, kept, expired

@MainActor
struct EmailCodeLifecycleTests {
    let account = EmailAccount(id: "acc", provider: .google, address: "me@gmail.com")

    private func message(_ id: String, at date: Date, body: String = "Your verification code is 482913",
                         from: String = "Google <no-reply@accounts.google.com>") -> MailMessage {
        MailMessage(id: id, from: from, subject: "Code", text: body, receivedAt: date)
    }

    @Test func onlyRecentUnseenMessagesWithCodes() {
        let now = Date.now
        var seen: [String: Date] = [:]
        let messages = [message("1", at: now.addingTimeInterval(-60)),
                        message("2", at: now.addingTimeInterval(-11 * 60)),           // too old
                        message("3", at: now.addingTimeInterval(-30), body: "Lunch at noon?")]
        let codes = EmailCodeCenter.codes(in: messages, account: account, since: now.addingTimeInterval(-600), seen: &seen)
        #expect(codes.map(\.code) == ["482913"])
        #expect(codes.first?.source == "google.com")
        #expect(codes.first?.accountID == "acc")
        // Looked at once: never again.
        #expect(EmailCodeCenter.codes(in: messages, account: account, since: now.addingTimeInterval(-600), seen: &seen).isEmpty)
    }

    @Test func expiryAfterTenMinutes() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let code = EmailCode(code: "1", source: "a.com", accountID: "x", receivedAt: t)
        #expect(code.isLive(at: t.addingTimeInterval(599)))
        #expect(!code.isLive(at: t.addingTimeInterval(600)))
        #expect(code.age(at: t.addingTimeInterval(30)) == "just now")
        #expect(code.age(at: t.addingTimeInterval(150)) == "2 min ago")
        let older = EmailCode(code: "2", source: "b.com", accountID: "x", receivedAt: t.addingTimeInterval(-500))
        #expect(EmailCodeCenter.live([older, code], at: t.addingTimeInterval(120)).map(\.code) == ["1"])
    }

    @Test func centerKeepsOnlyTheFourFieldsAndPrunes() throws {
        let vault = MemoryEmailVault()
        let center = EmailCodeCenter(vault: vault, clients: OAuthClients(), defaults: UserDefaults(suiteName: "emailtests-\(UUID())")!)
        var notified: [EmailCode] = []
        center.onNewCode = { notified.append($0) }
        let now = Date.now
        center.looked(account, found: [message("m", at: now.addingTimeInterval(-30))], now: now)
        #expect(center.codes.map(\.code) == ["482913"])
        #expect(notified.count == 1)
        #expect(center.status["acc"]?.lastChecked == now)
        // Stored: code, source, account, time. Nothing of the message.
        let stored = String(decoding: try #require(vault.data(for: EmailVaultKey.codes)), as: UTF8.self)
        #expect(stored.contains("482913") && stored.contains("google.com"))
        #expect(!stored.contains("verification") && !stored.contains("no-reply") && !stored.contains("Code\""))
        // The same code again (another look, a relaunch) isn't a new one.
        center.looked(account, found: [message("m2", at: now.addingTimeInterval(-20))], now: now)
        #expect(center.codes.count == 1 && notified.count == 1)
        center.pruneExpired(now: now.addingTimeInterval(11 * 60))
        #expect(center.codes.isEmpty)
        #expect(vault.data(for: EmailVaultKey.codes) == nil)
    }

    @Test func backoffGrowsAndCaps() {
        #expect(EmailAccountWorker.backoff(failures: 1, base: .seconds(15)) == .seconds(30))
        #expect(EmailAccountWorker.backoff(failures: 3, base: .seconds(15)) == .seconds(120))
        #expect(EmailAccountWorker.backoff(failures: 20, base: .seconds(30)) == .seconds(900))
    }

    @Test func listedUnderTheirSource() {
        let code = EmailCode(code: "1", source: "google.com", accountID: "x", receivedAt: .now)
        #expect(PanelViewModel.emailCodeEntries([code], under: .domain("google.com")).map(\.id) == ["es-" + code.id])
        #expect(PanelViewModel.emailCodeEntries([code], under: .domain("github.com")).isEmpty)
        #expect(PanelViewModel.emailCodeEntries([code], under: nil).isEmpty)
        #expect(PanelEntry.emailCode(code).id == "e-" + code.id)
        #expect(NotificationTarget(encoded: NotificationTarget.emailCode(id: code.id).encoded) == .emailCode(id: code.id))
    }
}
