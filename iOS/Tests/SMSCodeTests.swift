import Foundation
import Testing
@testable import Clipboard2iOS

// SMS codes (docs/features/ios.md → SMS codes): finding the code in a text and the site it's for.
// All messages are synthetic, written in the shape real services send.

nonisolated struct SMSSample: CustomTestStringConvertible, Sendable {
    var name: String
    var message: String
    var sender: String?
    var code: String?
    var domain: String?

    var testDescription: String { name }
}

/// Enough of the public suffix list for the samples (the app bundles the trimmed real one).
nonisolated let testSuffixes = PublicSuffixList(text: "com\nde\nat\nco.at\ngv.at\nnet\norg\neu\nio\nco.uk\nuk\nme\napp")

nonisolated let smsSamples: [SMSSample] = [
    // Google
    .init(name: "Google G- prefix", message: "G-482913 is your Google verification code.", sender: "22000",
          code: "482913", domain: "google.com"),
    .init(name: "Google G- prefix, unknown sender", message: "G-120934 is your Google verification code. Don't share it.",
          sender: "+4915112345678", code: "120934", domain: "google.com"),
    .init(name: "Google German", message: "G-731045 ist Ihr Bestätigungscode von Google.", sender: "Google",
          code: "731045", domain: "google.com"),
    // Origin-bound (domain-bound) codes
    .init(name: "Origin-bound", message: "Your Example code is 551234.\n\n@login.example.com #551234",
          sender: "+12025550123", code: "551234", domain: "example.com"),
    .init(name: "Origin-bound with embedding site", message: "123456 is your code\n\n@shop.example.de #123456 @pay.example.com",
          code: "123456", domain: "example.de"),
    // German
    .init(name: "Ihr Code lautet", message: "Ihr Code lautet 839201. Er ist 10 Minuten gültig.", sender: "Raiffeisen",
          code: "839201", domain: "raiffeisen.at"),
    .init(name: "Dein Bestätigungscode", message: "Dein Bestätigungscode für Bolt: 4821", sender: "Bolt",
          code: "4821", domain: "bolt.eu"),
    .init(name: "mTAN with amount and IBAN", message: "mTAN für Überweisung von EUR 150,00 an AT61 1904 3002 3457 3201: 552194",
          sender: "George", code: "552194", domain: "sparkasse.at"),
    .init(name: "Freigabe-TAN", message: "Ihre Freigabe-TAN lautet 774310. Gültig bis 14:32 Uhr.", sender: "DKB",
          code: "774310", domain: "dkb.de"),
    .init(name: "Anmeldung", message: "Ihr Einmalpasswort für die Anmeldung: 908172", sender: "BAWAG",
          code: "908172", domain: "bawag.at"),
    .init(name: "ID Austria", message: "Ihr TAN für ID Austria lautet 4F7KQ2", sender: "ID Austria",
          code: "4F7KQ2", domain: "oesterreich.gv.at"),
    // Banks and payments
    .init(name: "PayPal", message: "PayPal: Your security code is 385102. Your code expires in 10 minutes. Don't share your code.",
          sender: "729725", code: "385102", domain: "paypal.com"),
    .init(name: "Revolut", message: "Your Revolut code is 112-358. Don't share it with anyone, not even Revolut.",
          sender: "Revolut", code: "112358", domain: "revolut.com"),
    .init(name: "N26 in text", message: "Your N26 verification code: 607142", sender: "+491711234567",
          code: "607142", domain: "n26.com"),
    .init(name: "Bank, phone sender, no name", message: "Your one-time passcode is 449021. Never share it.",
          sender: "+43664123456", code: "449021", domain: nil),
    // Other services
    .init(name: "WhatsApp dash", message: "Your WhatsApp code: 123-456\nYou can also tap on this link to verify your phone: v.whatsapp.com/123456\nDon't share this code with others",
          sender: "WhatsApp", code: "123456", domain: "whatsapp.com"),
    .init(name: "Use to log in", message: "Use 482913 to log in to your Acme account.", sender: "Acme",
          code: "482913", domain: nil),
    .init(name: "Microsoft", message: "Use 7351 as Microsoft account security code", sender: "Microsoft",
          code: "7351", domain: "microsoft.com"),
    .init(name: "Domain in text", message: "Your code for amazon.de is 882011", sender: "+4930123456",
          code: "882011", domain: "amazon.de"),
    .init(name: "iMessage from email", message: "Your GitHub authentication code is 203948.", sender: "noreply@github.com",
          code: "203948", domain: "github.com"),
    .init(name: "Learned sender", message: "Code: 5520", sender: "+4366012345", code: "5520", domain: "mybank.at"),
    // Not codes
    .init(name: "Delivery with tracking number", message: "Ihr Paket 123456789 wird heute zugestellt. Sendungsnummer: 482910",
          sender: "DHL", code: nil, domain: "dhl.com"),
    .init(name: "Promo code", message: "Mit dem Code SOMMER24 sparen Sie 20 % auf alles!", sender: "Shop", code: nil, domain: nil),
    .init(name: "Appointment", message: "Reminder: your appointment is on 26.11.2026 at 14:30. Call 0800 123456 to reschedule.",
          sender: "Clinic", code: nil, domain: nil),
    .init(name: "Chat", message: "See you at 8, table for 4", sender: "+436641234567", code: nil, domain: nil),
]

@Suite("SMS code extraction")
struct SMSCodeExtractionTests {
    @Test(arguments: smsSamples)
    func extractsTheCode(_ sample: SMSSample) {
        #expect(SMSCodeExtractor.extract(sample.message)?.code == sample.code)
    }

    @Test func originBoundNeedsTheLastLine() {
        let result = SMSCodeExtractor.extract("@example.com #123456 is not at the end\nYour code is 654321")
        #expect(result?.code == "654321")
        #expect(result?.boundDomain == nil)
    }

    @Test func googlePrefixIsNotPartOfTheCode() {
        #expect(SMSCodeExtractor.extract("G-123456")?.code == "123456")
    }

    @Test func longMessagesAreCut() {
        let long = String(repeating: "Lorem ipsum dolor sit amet. ", count: 100) + "Your code is 123456"
        #expect(SMSCodeExtractor.extract(long) == nil)
    }
}

@Suite("SMS origin matching")
struct SMSOriginTests {
    static let context = SMSOriginContext(learnedSenders: [SMSOriginMatcher.senderKey("+43 660 12345"): "mybank.at"])

    @Test(arguments: smsSamples.filter { $0.code != nil })
    func matchesTheSite(_ sample: SMSSample) {
        let result = SMSCodeExtractor.extract(sample.message)
        let match = SMSOriginMatcher.match(message: sample.message, sender: sample.sender, boundDomain: result?.boundDomain,
                                           context: Self.context, list: testSuffixes)
        #expect(match?.domain == sample.domain)
    }

    @Test func reasons() {
        func reason(_ message: String, _ sender: String?, recent: String? = nil) -> SMSOriginMatcher.Reason? {
            let bound = SMSCodeExtractor.extract(message)?.boundDomain
            return SMSOriginMatcher.match(message: message, sender: sender, boundDomain: bound,
                                          context: SMSOriginContext(learnedSenders: Self.context.learnedSenders, recentDomain: recent),
                                          list: testSuffixes)?.reason
        }
        #expect(reason("Code 1234\n\n@example.com #1234", "Google") == .originBound)
        #expect(reason("Code: 5520", "+4366012345") == .learnedSender)
        #expect(reason("Your code is 1234", "PayPal") == .sender)
        #expect(reason("G-123456 is your code", "+1555") == .messagePrefix)
        #expect(reason("Your code for amazon.de is 1234", nil) == .domainInText)
        #expect(reason("Your PayPal code is 1234", "+1555") == .nameInText)
        #expect(reason("Your code is 1234", "+1555", recent: "example.com") == .recentlyUsed)
        #expect(reason("Your code is 1234", "+1555") == nil)
    }

    @Test func senderKeys() {
        #expect(SMSOriginMatcher.senderKey("+43 660 123-45") == "+4366012345")
        #expect(SMSOriginMatcher.senderKey("  PayPal ") == "paypal")
        #expect(SMSOriginMatcher.senderKey("NoReply@GitHub.com") == "noreply@github.com")
    }

    @Test func phoneNumbersSayNothing() {
        #expect(SMSOriginMatcher.domain(ofSender: "+4915112345678", list: testSuffixes) == nil)
        #expect(SMSOriginMatcher.domain(ofSender: "22000", list: testSuffixes) == "google.com")
    }

    @Test func everydayWordsDontNameAService() {
        #expect(SMSOriginMatcher.nameInText("Your Target order code is 1234", list: testSuffixes) == nil)
        #expect(SMSOriginMatcher.nameInText("Max, your code is 1234", list: testSuffixes) == nil)
        #expect(SMSOriginMatcher.nameInText("Your eBay code is 1234", list: testSuffixes) == "ebay.com")
    }

    @Test func abbreviationsAreNotDomains() {
        #expect(SMSOriginMatcher.domainInText("z.B. Code 1234, Nr.5", list: testSuffixes) == nil)
        #expect(SMSOriginMatcher.domainInText("Visit https://accounts.example.com/x", list: testSuffixes) == "example.com")
    }
}

@Suite("Sign-in code store")
struct SignInCodeStoreTests {
    @MainActor @Test func keepsCodesTenMinutesAndLearnsSenders() throws {
        let defaults = try #require(UserDefaults(suiteName: "SignInCodeStoreTests-\(UUID().uuidString)"))
        let store = SignInCodeStore(keychain: nil, defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(store.save(message: "Hello there", sender: "+431", now: start) == nil)
        let code = try #require(store.save(message: "Your code is 4821", sender: "+43 1 234", now: start))
        #expect(code.domain == nil)
        #expect(store.codes.count == 1)
        // The same code again is one entry.
        store.save(message: "Your code is 4821", sender: "+43 1 234", now: start.addingTimeInterval(5))
        #expect(store.codes.count == 1)

        store.assign(store.codes[0].id, to: "https://login.mybank.at")
        #expect(store.codes[0].domain == "mybank.at")
        let next = try #require(store.save(message: "Your code is 9911", sender: "+431234", now: start.addingTimeInterval(60)))
        #expect(next.domain == "mybank.at")
        #expect(next.reason == .learnedSender)

        store.reload(now: start.addingTimeInterval(SignInCode.lifetime + 61))
        #expect(store.codes.isEmpty)
    }
}
