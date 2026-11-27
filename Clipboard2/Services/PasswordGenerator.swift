import Foundation

/// Strong passwords in Apple's style: `xxxxxx-xxxxxx-xxxxxx`, letters and digits with at least
/// one uppercase letter, one lowercase letter and one digit. Other lengths keep the groups of six
/// (the last one may be shorter); with symbols there are no hyphens, and at least one symbol.
nonisolated enum PasswordGenerator {
    struct Options: Equatable, Sendable {
        /// Total length, hyphens included.
        var length = 20
        var symbols = false

        static let lengthRange = 8...64
    }

    static let lowercase = Array("abcdefghijkmnopqrstuvwxyz")   // no l: it reads like 1 and I
    static let uppercase = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")    // no I, O
    static let digits = Array("23456789")                      // no 0, 1
    /// No "-" (it reads as a group separator), and nothing that commonly breaks sites or shells:
    /// no quotes, backslash, backtick or space.
    static let symbolSet = Array("!#$%&*+.=?@^_~")

    /// What Generate and Suggest Strong Password offer side by side: the same length, one with
    /// letters and digits only (`xxxxxx-xxxxxx-xxxxxx`), one with symbols.
    struct Suggestions: Equatable, Sendable {
        let plain: String
        let symbols: String

        var both: [String] { [plain, symbols] }
    }

    static func suggestions(length: Int = Options().length) -> Suggestions {
        Suggestions(plain: generate(Options(length: length, symbols: false)),
                    symbols: generate(Options(length: length, symbols: true)))
    }

    static func generate(_ options: Options = Options()) -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(options, using: &rng)
    }

    static func generate<R: RandomNumberGenerator>(_ options: Options, using rng: inout R) -> String {
        let length = min(max(options.length, Options.lengthRange.lowerBound), Options.lengthRange.upperBound)
        if options.symbols {
            let all = lowercase + uppercase + digits + symbolSet
            var chars = (0..<length).map { _ in all.randomElement(using: &rng)! }
            guarantee(&chars, positions: Array(chars.indices), using: &rng,
                      sets: [uppercase, lowercase, digits, symbolSet])
            return String(chars)
        }
        // A hyphen after every sixth character, never at the end.
        var chars: [Character] = []
        var letterPositions: [Int] = []
        let all = lowercase + uppercase + digits
        while chars.count < length {
            if chars.count % 7 == 6 && chars.count < length - 1 {
                chars.append("-")
            } else {
                letterPositions.append(chars.count)
                chars.append(all.randomElement(using: &rng)!)
            }
        }
        guarantee(&chars, positions: letterPositions, using: &rng, sets: [uppercase, lowercase, digits])
        return String(chars)
    }

    /// Puts one character of each set the password lacks at a distinct random position.
    private static func guarantee<R: RandomNumberGenerator>(_ chars: inout [Character], positions: [Int],
                                                            using rng: inout R, sets: [[Character]]) {
        var free = positions.shuffled(using: &rng)
        for set in sets where !chars.contains(where: set.contains) {
            // Never overwrite the only member of another required set.
            guard let index = free.firstIndex(where: { position in
                let current = chars[position]
                return !sets.contains { other in other.contains(current) && chars.filter(other.contains).count == 1 }
            }) else { continue }
            let position = free.remove(at: index)
            chars[position] = set.randomElement(using: &rng)!
        }
    }

    /// Meets the rules for its options (used by the tests and as a sanity check).
    static func isValid(_ password: String, options: Options) -> Bool {
        let chars = Array(password)
        guard chars.count == options.length else { return false }
        let hasUpper = chars.contains(where: uppercase.contains)
        let hasLower = chars.contains(where: lowercase.contains)
        let hasDigit = chars.contains(where: digits.contains)
        if options.symbols {
            return hasUpper && hasLower && hasDigit && chars.contains(where: symbolSet.contains)
                && chars.allSatisfy { (lowercase + uppercase + digits + symbolSet).contains($0) }
        }
        for (index, char) in chars.enumerated() {
            let shouldBeHyphen = index % 7 == 6 && index < chars.count - 1
            if shouldBeHyphen != (char == "-") { return false }
        }
        return hasUpper && hasLower && hasDigit
    }
}
