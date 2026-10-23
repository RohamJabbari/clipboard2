import Testing
import Foundation
@testable import Clipboard2

struct ClipContentTests {
    @Test func colors() {
        guard case .color(let blue) = ClipContent.classify("#0A84FF") else { Issue.record("not a color"); return }
        #expect(blue == RGBColor(red: 10, green: 132, blue: 255))
        #expect(blue.hex == "#0A84FF")
        #expect(blue.rgb == "10 132 255")
        #expect(blue.hsl == "210° 100% 52%")
        #expect((blue.contrast(with: .white) * 10).rounded() / 10 == 3.6)
        #expect(RGBColor(parsing: "#fff") == .white)
        #expect(RGBColor(parsing: "rgb(255, 255, 255)") == .white)
        #expect(RGBColor(parsing: "#00000080")?.alpha == 128.0 / 255)
        #expect(RGBColor(parsing: "#12345") == nil)
        #expect(RGBColor(parsing: "rgb(300, 0, 0)") == nil)
    }

    @Test func linksEmailsAndPhones() {
        #expect(ClipContent.classify("https://www.swift.org/documentation/") == .link(URL(string: "https://www.swift.org/documentation/")!))
        #expect(ClipContent.classify("behrad@example.com") == .email("behrad@example.com"))
        #expect(ClipContent.classify("+43 1 234 5678") == .phone("+43 1 234 5678"))
        #expect(ClipContent.classify("(555) 123-4567") == .phone("(555) 123-4567"))
        #expect(ClipContent.classify("2026-10-23") == .plain)
        #expect(ClipContent.classify("www.swift.org") == .plain)
    }

    @Test func jsonCommandsAndSecrets() {
        guard case .json(let pretty) = ClipContent.classify(#"{"name":"Clipboard2","version":"1.4.0"}"#) else {
            Issue.record("not JSON"); return
        }
        #expect(pretty.contains("\n  \"name\": \"Clipboard2\""))
        #expect(ClipContent.classify("{not json}") == .plain)
        #expect(ClipContent.classify("brew install xcodegen && make debug") == .command)
        #expect(ClipContent.classify("$ ls -la") == .command)
        #expect(ClipContent.classify("make") == .plain)
        #expect(ClipContent.classify("ghp_1234567890abcdefABCDEF1234567890abcd") == .sensitive(.apiKey))
        #expect(ClipContent.classify("Oat milk, lemons, basil") == .plain)
    }

    @Test func maskingKeepsOnlyTheEnds() {
        #expect(SensitiveText.masked("sk-proj-4f9a2c7d1e8b6a3f9c2d7e1b", kind: .apiKey) == "sk-p••••••••7e1b")
        #expect(SensitiveText.masked("4111 1111 1111 1111", kind: .cardNumber) == "•••• 1111")
    }

    @Test func highlightIndicesFollowTheMatch() {
        #expect(FuzzyMatcher.matchedIndices(query: "review", in: "Move the design review") == Array(16..<22))
        #expect(FuzzyMatcher.matchedIndices(query: "mdr", in: "Move the design review") == [0, 9, 16])
        #expect(FuzzyMatcher.matchedIndices(query: "design zzz", in: "Move the design review") == nil)
        #expect(FuzzyMatcher.matchedIndices(query: "", in: "anything") == [])
    }
}
