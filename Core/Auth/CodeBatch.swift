import Foundation

/// `codesJSON` (PROTOCOL.md → Authenticators): the codes from `from` (Unix seconds, start of a
/// step) on, one per step.
nonisolated struct CodeBatch: Codable, Equatable, Hashable, Sendable {
    var v = 1
    var issuer: String
    var account: String
    var digits: Int
    var period: Int
    var from: Int64
    var codes: [String]

    static let duration: TimeInterval = 24 * 3600
    /// Keeps a batch under the server's 64 KiB for very short periods.
    static let maxCodes = 4_000
    /// Owner devices top a share up once fewer than this many seconds of codes remain.
    static let topUpThreshold: TimeInterval = 12 * 3600

    init(issuer: String, account: String, digits: Int, period: Int, from: Int64, codes: [String]) {
        self.issuer = issuer
        self.account = account
        self.digits = digits
        self.period = period
        self.from = from
        self.codes = codes
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        issuer = try c.decodeIfPresent(String.self, forKey: .issuer) ?? ""
        account = try c.decodeIfPresent(String.self, forKey: .account) ?? ""
        digits = try c.decodeIfPresent(Int.self, forKey: .digits) ?? 6
        period = max(1, try c.decodeIfPresent(Int.self, forKey: .period) ?? 30)
        from = try c.decodeIfPresent(Int64.self, forKey: .from) ?? 0
        codes = try c.decodeIfPresent([String].self, forKey: .codes) ?? []
    }

    /// End of the last code's step.
    var until: Date { Date(timeIntervalSince1970: TimeInterval(from + Int64(codes.count * period))) }

    func code(at time: Date) -> String? {
        let seconds = Int64(floor(time.timeIntervalSince1970))
        guard seconds >= from else { return nil }
        let index = Int((seconds - from) / Int64(period))
        return codes.indices.contains(index) ? codes[index] : nil
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
