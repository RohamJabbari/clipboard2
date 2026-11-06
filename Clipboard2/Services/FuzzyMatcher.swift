import Foundation

/// Lightweight fuzzy matcher: every whitespace-separated query token must appear in the
/// candidate as a case-insensitive subsequence. Contiguous runs, word starts and exact
/// substrings score higher.
nonisolated enum FuzzyMatcher {
    static let maxCandidateLength = 4_000

    static func score(query: String, in candidate: String) -> Int? {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return 0 }
        let haystack = Array(candidate.prefix(maxCandidateLength).lowercased())
        var total = 0
        for token in tokens {
            guard let s = score(token: Array(token), in: haystack) else { return nil }
            total += s
        }
        return total
    }

    /// Character offsets in `candidate` the query matched, for highlighting. Follows `score`: an
    /// exact substring when there is one, otherwise the subsequence. Nil when a token doesn't match.
    static func matchedIndices(query: String, in candidate: String) -> [Int]? {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return [] }
        let haystack = Array(candidate.prefix(maxCandidateLength).lowercased())
        var indices = Set<Int>()
        for token in tokens {
            let needle = Array(token)
            if let start = firstIndex(of: needle, in: haystack) {
                indices.formUnion(start..<start + needle.count)
                continue
            }
            var next = 0
            for (i, ch) in haystack.enumerated() where next < needle.count && ch == needle[next] {
                indices.insert(i)
                next += 1
            }
            guard next == needle.count else { return nil }
        }
        return indices.sorted()
    }

    private static func score(token: [Character], in haystack: [Character]) -> Int? {
        guard !token.isEmpty else { return 0 }
        guard token.count <= haystack.count else { return nil }

        // Exact substring: strong bonus, earlier is better.
        if let index = firstIndex(of: token, in: haystack) {
            let wordStart = index == 0 || !haystack[index - 1].isLetter
            return 1_000 + token.count * 10 + (wordStart ? 200 : 0) - min(index, 300)
        }

        var score = 0
        var tokenIndex = 0
        var previousMatch = -2
        for (i, ch) in haystack.enumerated() where tokenIndex < token.count {
            guard ch == token[tokenIndex] else { continue }
            score += 1
            if i == previousMatch + 1 { score += 5 }
            if i == 0 || !haystack[i - 1].isLetter { score += 8 }
            previousMatch = i
            tokenIndex += 1
        }
        guard tokenIndex == token.count else { return nil }
        return score
    }

    private static func firstIndex(of needle: [Character], in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        let first = needle[0]
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == first {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }
}
