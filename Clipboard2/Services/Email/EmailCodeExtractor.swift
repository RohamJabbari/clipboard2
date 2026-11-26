import Foundation

// Email codes (docs/features/auth-autofill.md → Phase 4 → Recognising a code). Pure and on
// device: the subject and plain-text body go in, at most a code comes out. Nothing is kept.

nonisolated enum EmailCodeExtractor {
    /// How far (in characters) a digit code may sit from its keyword.
    static let maxDistance = 160
    /// Letter-and-digit codes look more like other things (promo codes, references): closer only.
    static let maxAlphanumericDistance = 48
    /// Only the start of a long body is read.
    static let bodyLimit = 6000

    struct Candidate: Equatable {
        var code: String
        var start: Int
        var end: Int
        var isDigits: Bool
    }

    struct Keyword: Equatable {
        var start: Int
        var end: Int
        /// A "code" that isn't a sign-in code (promo code, postcode, QR code…).
        var negative: Bool
    }

    /// The code in a message, or nil. Several candidates: the one closest to a keyword wins.
    static func code(subject: String, body: String) -> String? {
        let text = clean(subject) + "\n\n" + clean(String(body.prefix(bodyLimit)))
        let chars = Array(text)
        let keywords = findKeywords(chars)
        guard keywords.contains(where: { !$0.negative }) else { return nil }
        var best: (code: String, score: Double)?
        for candidate in findCandidates(chars) where !isExcluded(candidate, in: chars) {
            guard let (keyword, distance) = nearest(keywords, to: candidate), !keyword.negative else { continue }
            guard distance <= Double(candidate.isDigits ? maxDistance : maxAlphanumericDistance) else { continue }
            guard !inPromotion(candidate, chars) else { continue }
            // A code alone on its line is what these mails look like.
            let score = max(0, distance - (isAloneOnLine(candidate, chars) ? 24 : 0))
            if best == nil || score < best!.score { best = (candidate.code, score) }
        }
        return best?.code
    }

    // MARK: Text

    /// Links and addresses hold numbers that are never the code.
    static func clean(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        for pattern in [#"(?i)\b(?:https?://|www\.)[^\s<>"]+"#, #"[^\s<>"()]+@[^\s<>"()]+"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return text
    }

    // MARK: Keywords

    /// Words that end in "code" but aren't one to sign in with, and the words before a plain "code" that say so.
    private static let negativeCodePrefixes = ["post", "zip", "bar", "qr", "promo", "rabatt", "gutschein", "voucher",
                                               "coupon", "discount", "aktions", "geschenk", "gift", "referral", "source",
                                               "area", "country", "dress", "farb", "color", "colour", "html", "error",
                                               "fehler", "status", "versand", "tracking", "einlöse", "angebots", "spar",
                                               "vorteils", "bonus", "werbe", "deal"]
    private static let negativeWordsBeforeCode: Set<String> = [
        "promo", "promotion", "discount", "coupon", "voucher", "gift", "zip", "postal", "area", "country", "qr", "source",
        "dress", "bar", "status", "error", "referral", "rabatt", "gutschein", "tracking", "bonus", "deal", "sale",
    ]
    /// Not a "code" word, but the same kind of thing: a nearby one beats a distant "code".
    private static let negativeWords: Set<String> = ["gutschein", "voucher", "coupon", "promo", "rabatt", "rabattcode"]
    private static let exactKeywords: Set<String> = [
        "otp", "pin", "tan", "mtan", "smstan", "pushtan", "chiptan", "passcode", "onetime", "one-time",
    ]
    private static let keywordPrefixes = ["verif", "bestätig", "confirm", "authenti", "einmal", "sicherheits"]

    static func findKeywords(_ chars: [Character]) -> [Keyword] {
        let words = letterWords(chars)
        var keywords: [Keyword] = []
        for (index, word) in words.enumerated() {
            let w = word.text
            let previous = index > 0 ? words[index - 1].text : ""
            let next = index + 1 < words.count ? words[index + 1].text : ""
            if w.hasSuffix("code") || w.hasSuffix("codes") || w.hasSuffix("-code") {
                let stem = w.replacingOccurrences(of: "-", with: "")
                let negative = (stem != "code" && stem != "codes" && negativeCodePrefixes.contains { stem.hasPrefix($0) })
                    || ((stem == "code" || stem == "codes") && negativeWordsBeforeCode.contains(previous)
                        && word.start - words[index - 1].end <= 2)
                keywords.append(Keyword(start: word.start, end: word.end, negative: negative))
            } else if negativeWords.contains(w) {
                keywords.append(Keyword(start: word.start, end: word.end, negative: true))
            } else if exactKeywords.contains(w) || keywordPrefixes.contains(where: { w.hasPrefix($0) })
                        || (w == "one" && next == "time") {
                keywords.append(Keyword(start: word.start, end: word.end, negative: false))
            }
        }
        return keywords
    }

    /// Runs of letters (hyphens inside are kept: "Login-Code", "one-time"), lowercased.
    static func letterWords(_ chars: [Character]) -> [(text: String, start: Int, end: Int)] {
        var words: [(String, Int, Int)] = []
        var i = 0
        while i < chars.count {
            guard chars[i].isLetter else { i += 1; continue }
            let start = i
            while i < chars.count, chars[i].isLetter || (chars[i] == "-" && i + 1 < chars.count && chars[i + 1].isLetter) {
                i += 1
            }
            words.append((String(chars[start..<i]).lowercased(), start, i))
        }
        return words
    }

    /// The keyword closest to a candidate and how far it is. One just before the code reads best.
    static func nearest(_ keywords: [Keyword], to candidate: Candidate) -> (Keyword, Double)? {
        var best: (Keyword, Double)?
        for keyword in keywords {
            let distance: Double
            if keyword.end <= candidate.start {
                distance = Double(candidate.start - keyword.end)
            } else if candidate.end <= keyword.start {
                distance = Double(keyword.start - candidate.end) + 6
            } else {
                continue   // overlapping: the candidate is inside the keyword
            }
            if best == nil || distance < best!.1 { best = (keyword, distance) }
        }
        return best
    }

    // MARK: Candidates

    /// 4–8 digits ("123456", or "123 456" / "123-456"), or 6–8 capitals and digits with at least one digit.
    static func findCandidates(_ chars: [Character]) -> [Candidate] {
        var candidates: [Candidate] = []
        var i = 0
        func isAlnum(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        func run(from start: Int) -> Int {
            var j = start
            while j < chars.count, isAlnum(chars[j]) { j += 1 }
            return j
        }
        while i < chars.count {
            guard isAlnum(chars[i]) else { i += 1; continue }
            let start = i
            let end = run(from: start)
            i = end
            // Glued to other letters ("Müller2024"): part of a word.
            if start > 0, chars[start - 1].isLetter || chars[start - 1].isNumber { continue }
            if end < chars.count, chars[end].isLetter || chars[end].isNumber { continue }
            let token = String(chars[start..<end])
            let digitsOnly = token.allSatisfy(\.isNumber)
            let isCodeChars = token.allSatisfy { $0.isNumber || $0.isUppercase }
            // Two halves: "123 456", "1234-5678", "Q5G-B3T".
            if (token.count == 3 || token.count == 4), end + 1 < chars.count, chars[end] == " " || chars[end] == "-",
               isAlnum(chars[end + 1]), digitsOnly || isCodeChars {
                let secondEnd = run(from: end + 1)
                let second = String(chars[(end + 1)..<secondEnd])
                let sameShape = second.count == token.count
                    && (digitsOnly ? second.allSatisfy(\.isNumber) : second.allSatisfy { $0.isNumber || $0.isUppercase })
                let joined = token + second
                let hasDigit = joined.contains(where: \.isNumber)
                let separatedBefore = start >= 2 && (chars[start - 1] == " " || chars[start - 1] == "-") && chars[start - 2].isNumber
                let separatedAfter = secondEnd + 1 < chars.count && (chars[secondEnd] == " " || chars[secondEnd] == "-")
                    && chars[secondEnd + 1].isNumber
                let gluedAfter = secondEnd < chars.count && (chars[secondEnd].isLetter || chars[secondEnd].isNumber)
                if sameShape, hasDigit, !separatedBefore, !separatedAfter, !gluedAfter,
                   digitsOnly || joined.contains(where: \.isLetter) {
                    candidates.append(Candidate(code: joined, start: start, end: secondEnd, isDigits: digitsOnly))
                    i = secondEnd
                    continue
                }
            }
            if digitsOnly, (4...8).contains(token.count) {
                candidates.append(Candidate(code: token, start: start, end: end, isDigits: true))
            } else if !digitsOnly, isCodeChars, (6...8).contains(token.count), token.contains(where: \.isNumber) {
                candidates.append(Candidate(code: token, start: start, end: end, isDigits: false))
            }
        }
        return candidates
    }

    // MARK: Exclusions

    /// Words just before a number that make it something else: an order, a phone number, an account.
    private static let exclusionStems = ["order", "bestell", "auftrag", "invoice", "rechnung", "kundennummer", "kundennr", "customer",
                                         "sendung", "tracking", "paket", "parcel", "referenz", "reference", "konto",
                                         "iban", "artikel", "telefon", "phone", "hotline", "mobil", "ticket", "vertrag",
                                         "contract", "mitglied", "member", "transaktion", "transaction", "vorgang",
                                         "beleg", "receipt", "shipment", "lieferung", "filiale", "postfach", "zimmer",
                                         "flug", "flight", "booking", "buchung", "versicherung", "policy", "steuer"]
    private static let exclusionWords: Set<String> = ["ref", "nr", "no", "tel", "fax", "call", "plz", "bic", "blz", "id",
                                                      "item", "art", "kd", "best", "ust", "uid", "stnr", "case", "fall",
                                                      "seite", "page", "zip", "box"]
    /// Words just after a number that make it a quantity.
    private static let unitWords: Set<String> = ["minuten", "minutes", "min", "stunden", "hours", "tage", "days", "jahre",
                                                 "years", "uhr", "gb", "mb", "kb", "punkte", "points", "meilen", "miles",
                                                 "kalorien", "kcal", "kg", "km", "stück", "pcs", "items", "artikel", "mal",
                                                 "times", "follower", "followers", "views", "likes", "users", "nutzer"]
    private static let currencies = ["€", "$", "£", "¥", "eur", "euro", "usd", "chf", "gbp", "jpy"]

    static func isExcluded(_ candidate: Candidate, in chars: [Character]) -> Bool {
        let start = candidate.start, end = candidate.end
        // A year.
        if candidate.isDigits, candidate.code.count == 4, let year = Int(candidate.code), (1900...2099).contains(year) {
            return true
        }
        // Part of a date, a time, an amount or a longer number: "26.11.2026", "12:30", "1.234,56", "123-4567890".
        let joiners: Set<Character> = [".", ",", "/", ":", "-", "_"]
        if start >= 2, joiners.contains(chars[start - 1]), chars[start - 2].isNumber { return true }
        if end + 1 < chars.count, joiners.contains(chars[end]), chars[end + 1].isNumber { return true }
        // A group of a phone number or an IBAN: "+43 1 234 5678", "AT61 1904 3002".
        if candidate.isDigits {
            if start >= 2, chars[start - 1] == " ", chars[start - 2].isNumber { return true }
            if end + 1 < chars.count, chars[end] == " ", chars[end + 1].isNumber { return true }
        }
        // "+49…", "#12345", "Nr.12345".
        var before = start - 1
        while before >= 0, chars[before] == " " { before -= 1 }
        if before >= 0, chars[before] == "+" || chars[before] == "#" || chars[before] == "№" { return true }
        // Money: "€ 1234", "1234 EUR", "4500 %".
        let lead = String(chars[max(0, start - 5)..<start]).lowercased().trimmingCharacters(in: .whitespaces)
        let trail = String(chars[end..<min(chars.count, end + 5)]).lowercased().trimmingCharacters(in: .whitespaces)
        if currencies.contains(where: { lead.hasSuffix($0) }) || (currencies + ["%"]).contains(where: { trail.hasPrefix($0) }) {
            return true
        }
        // The words around it.
        let beforeWords = wordsBefore(start, in: chars, limit: 2, within: 28)
        for word in beforeWords {
            if isPositiveKeyword(word) { break }
            if exclusionWords.contains(word) || exclusionStems.contains(where: { word.hasPrefix($0) }) { return true }
        }
        if let next = wordsAfter(end, in: chars, limit: 1, within: 3).first, unitWords.contains(next) { return true }
        return false
    }

    private static func isPositiveKeyword(_ word: String) -> Bool {
        word.hasSuffix("code") || word.hasSuffix("codes") || exactKeywords.contains(word)
            || keywordPrefixes.contains(where: { word.hasPrefix($0) })
    }

    /// Up to `limit` letter words before `index`, nearest first, within `within` characters.
    private static func wordsBefore(_ index: Int, in chars: [Character], limit: Int, within: Int) -> [String] {
        var words: [String] = []
        var i = index - 1
        let floor = max(0, index - within)
        while i >= floor, words.count < limit {
            if chars[i].isLetter {
                let end = i + 1
                while i >= 0, chars[i].isLetter || chars[i] == "-" { i -= 1 }
                words.append(String(chars[(i + 1)..<end]).lowercased())
            } else if chars[i].isNumber || chars[i] == "\n" && i > 0 && chars[i - 1] == "\n" {
                break   // another number, or a paragraph break: what's before is about something else
            } else {
                i -= 1
            }
        }
        return words
    }

    private static func wordsAfter(_ index: Int, in chars: [Character], limit: Int, within: Int) -> [String] {
        var words: [String] = []
        var i = index
        let ceiling = min(chars.count, index + within)
        while i < chars.count, words.count < limit {
            if chars[i].isLetter {
                let start = i
                while i < chars.count, chars[i].isLetter { i += 1 }
                words.append(String(chars[start..<i]).lowercased())
            } else if i >= ceiling || chars[i].isNumber || chars[i] == "\n" {
                break
            } else {
                i += 1
            }
        }
        return words
    }

    private static let promotionMarkers = ["%", "rabatt", "discount", "gutschein", "voucher", "coupon", "promo",
                                           "einlösen", "redeem", "sparen", "shop now", "jetzt shoppen", "angebot"]

    /// Newsletters: "Mit dem Code SOMMER24 sparen Sie 20 %".
    static func inPromotion(_ candidate: Candidate, _ chars: [Character]) -> Bool {
        let around = String(chars[max(0, candidate.start - 60)..<min(chars.count, candidate.end + 60)]).lowercased()
        return promotionMarkers.contains { around.contains($0) }
    }

    static func isAloneOnLine(_ candidate: Candidate, _ chars: [Character]) -> Bool {
        var i = candidate.start - 1
        while i >= 0, chars[i] != "\n" {
            if !chars[i].isWhitespace { return false }
            i -= 1
        }
        var j = candidate.end
        while j < chars.count, chars[j] != "\n" {
            if !chars[j].isWhitespace { return false }
            j += 1
        }
        return true
    }
}
