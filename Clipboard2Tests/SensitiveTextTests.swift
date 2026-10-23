import Testing
import Foundation
@testable import Clipboard2

struct SensitiveTextTests {
    @Test func recognisesAPIKeys() {
        #expect(SensitiveText.detect("sk-proj-4f9a2c7d1e8b6a3f9c2d7e1b") == .apiKey)
        #expect(SensitiveText.detect("ghp_1234567890abcdefABCDEF1234567890abcd") == .apiKey)
        #expect(SensitiveText.detect("AKIAIOSFODNN7EXAMPLE") == .apiKey)
        #expect(SensitiveText.detect("xoxb-123456789012-1234567890123-AbCdEf") == .apiKey)
        #expect(SensitiveText.detect("  sk_live_51H8xYzAbCdEfGh12345678  \n") == .apiKey)
    }

    @Test func recognisesTokensAndPrivateKeys() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(SensitiveText.detect(jwt) == .token)
        #expect(SensitiveText.detect("Zq8vR3mT1xLw9KpB4nYd7HsJ2cFgA6eU5tWoQiXr") == .token)
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n-----END OPENSSH PRIVATE KEY-----"
        #expect(SensitiveText.detect(pem) == .privateKey)
    }

    @Test func recognisesCodesCardsAndPasswords() {
        #expect(SensitiveText.detect("LSWD-FRKT-P3RC-JTYK-KJDV-9QXM") == .code)
        #expect(SensitiveText.detect("4111 1111 1111 1111") == .cardNumber)
        #expect(SensitiveText.detect("4111-1111-1111-1111") == .cardNumber)
        #expect(SensitiveText.detect("Tr0ub4dor&3x") == .password)
        #expect(SensitiveText.detect("Tr0ub4dor&3x")?.isConfident == false)
    }

    @Test func leavesOrdinaryTextAlone() {
        let ordinary = [
            "Let's move the design review to Thursday at 10",
            "https://www.swift.org/documentation/",
            "behrad@example.com",
            "db-staging.internal:5432",
            "#0A84FF",
            "+43 1 234 5678",
            "4111 1111 1111 1112",                               // fails Luhn
            "9f2c1e7a4b6d8f0e1a2b3c4d5e6f7a8b9c0d1e2f",          // a commit hash
            "550e8400-e29b-41d4-a716-446655440000",              // a UUID
            "{\"name\": \"Clipboard2\", \"version\": \"1.4.0\"}",
            "brew install xcodegen && make debug",
            "Clipboard2",
            "iPhone15Pro",
            "/Users/me/Documents/Report2026Final.pdf",
            "Report2026Final.pdf",
            "sk-learn",
        ]
        for text in ordinary {
            #expect(SensitiveText.detect(text) == nil, "\(text)")
        }
    }
}
