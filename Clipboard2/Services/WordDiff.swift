import Foundation

/// Word-level differences between two texts, for showing what Fix Grammar changed. Pure.
nonisolated enum WordDiff {
    enum Part: Equatable, Sendable {
        case same(String)
        case removed(String)
        case added(String)
    }

    /// Above this many tokens on either side the texts are shown as one replacement.
    static let tokenLimit = 2_000

    static func diff(_ old: String, _ new: String) -> [Part] {
        let a = tokens(old), b = tokens(new)
        guard a.count <= tokenLimit, b.count <= tokenLimit else {
            return merge([.removed(old), .added(new)])
        }
        // Longest common subsequence, filled from the end so the walk below goes forward.
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var parts: [Part] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                parts.append(.same(a[i])); i += 1; j += 1
            } else if i < a.count, j == b.count || lcs[i + 1][j] >= lcs[i][j + 1] {
                // Removals first, so a replaced word reads "old, then new".
                parts.append(.removed(a[i])); i += 1
            } else {
                parts.append(.added(b[j])); j += 1
            }
        }
        return merge(parts)
    }

    /// How many places changed: a removal next to an addition counts once.
    static func changeCount(_ parts: [Part]) -> Int {
        var count = 0
        var inChange = false
        for part in parts {
            if case .same = part {
                inChange = false
            } else if !inChange {
                count += 1
                inChange = true
            }
        }
        return count
    }

    /// Words (letters, digits and inner apostrophes) and single other characters.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var word = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let isApostrophe = (character == "'" || character == "’") && !word.isEmpty
                && index + 1 < characters.count && characters[index + 1].isLetter
            if character.isLetter || character.isNumber || isApostrophe {
                word.append(character)
            } else {
                if !word.isEmpty { result.append(word); word = "" }
                result.append(String(character))
            }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }

    /// Joins neighbouring parts of the same kind.
    private static func merge(_ parts: [Part]) -> [Part] {
        var merged: [Part] = []
        for part in parts {
            switch (merged.last, part) {
            case (.same(let a)?, .same(let b)): merged[merged.count - 1] = .same(a + b)
            case (.removed(let a)?, .removed(let b)): merged[merged.count - 1] = .removed(a + b)
            case (.added(let a)?, .added(let b)): merged[merged.count - 1] = .added(a + b)
            default: merged.append(part)
            }
        }
        return merged.filter {
            switch $0 {
            case .same(let s), .removed(let s), .added(let s): !s.isEmpty
            }
        }
    }
}
