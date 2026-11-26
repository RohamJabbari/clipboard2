import Foundation

/// What a secret holds besides its name and value, kept in the item's description attribute as
/// JSON. Plain secrets keep the original "Clipboard2 secret" description, so their items are
/// unchanged (and older builds, which never read the description, keep working).
nonisolated struct SecretExtras: Codable, Equatable, Sendable {
    var username: String?
    var urls: [String]?
    /// Short hash of the notes: changes the item (and its modification date) when only the notes do.
    var notes: String?
    /// When it was first saved (Unix ms), kept here once it moved Keychains: a moved item gets a
    /// new creation date, and the creation date is part of what syncs.
    var created: Int64?
    /// The origin it's filed under (`SecretRef.originID`).
    var origin: String?

    static let plainDescription = "Clipboard2 secret"

    var isEmpty: Bool { username == nil && urls == nil && notes == nil && created == nil && origin == nil }

    /// The description attribute for these extras.
    var descriptionValue: String {
        guard !isEmpty else { return Self.plainDescription }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? Self.plainDescription
    }

    /// Anything that isn't a JSON object (the plain description, or nothing) reads as no extras.
    init(descriptionValue: String?) {
        guard let descriptionValue, descriptionValue.hasPrefix("{"),
              let decoded = try? JSONDecoder().decode(SecretExtras.self, from: Data(descriptionValue.utf8))
        else { self.init(); return }
        self.init(username: decoded.username, urls: decoded.urls, notes: decoded.notes, created: decoded.created,
                  origin: decoded.origin)
    }

    init(username: String? = nil, urls: [String]? = nil, notes: String? = nil, created: Int64? = nil, origin: String? = nil) {
        self.username = Self.cleanUsername(username)
        let sites = Self.cleanURLs(urls ?? [])
        self.urls = sites.isEmpty ? nil : sites
        self.notes = notes?.isEmpty == true ? nil : notes
        self.created = created
        self.origin = origin?.isEmpty == true ? nil : origin?.lowercased()
    }

    /// A secret's description on its way to the shared Keychain: its creation date joins it.
    static func movedDescription(_ description: String?, created: Date?) -> String? {
        var extras = SecretExtras(descriptionValue: description)
        guard extras.created == nil, let created else { return description }
        extras.created = Int64((created.timeIntervalSince1970 * 1000).rounded())
        return extras.descriptionValue
    }

    static func cleanUsername(_ username: String?) -> String? {
        let trimmed = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Trimmed, empty ones dropped, duplicates (ignoring case) removed, order kept.
    static func cleanURLs(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func notesStamp(_ notes: String?) -> String? {
        guard let notes, !notes.isEmpty else { return nil }
        return String(SyncCrypto.sha256Hex(Data(notes.utf8)).prefix(12))
    }
}
