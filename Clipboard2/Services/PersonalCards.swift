import Foundation
import Observation
import Security

// Personal info cards (docs/features/auth-autofill.md → Phase 2): "Me" in Auth. Local only for
// now: kept in the login Keychain as one item, never synced.

nonisolated struct PersonalCard: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// "Work", "Home".
    var label: String
    var name = ""
    var email = ""
    var phone = ""
    var company = ""
    var street = ""
    var postcode = ""
    var city = ""
    var country = ""

    /// The kinds a card holds, in the order they're shown.
    static let fields: [FormFieldKind] = [.name, .email, .phone, .company, .street, .postcode, .city, .country]

    func value(for kind: FormFieldKind) -> String? {
        let value: String
        switch kind {
        case .name: value = name
        case .email: value = email
        case .phone: value = phone
        case .company: value = company
        case .street: value = street
        case .postcode: value = postcode
        case .city: value = city
        case .country: value = country
        case .givenName, .familyName:
            // "Anna Maria Huber": "Anna Maria" and "Huber".
            let parts = name.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { return kind == .givenName && !parts.isEmpty ? parts[0] : nil }
            value = kind == .givenName ? parts.dropLast().joined(separator: " ") : parts[parts.count - 1]
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    mutating func set(_ value: String, for kind: FormFieldKind) {
        switch kind {
        case .name, .givenName, .familyName: name = value
        case .email: email = value
        case .phone: phone = value
        case .company: company = value
        case .street: street = value
        case .postcode: postcode = value
        case .city: city = value
        case .country: country = value
        }
    }

    /// Its filled-in values, in display order.
    var values: [(kind: FormFieldKind, value: String)] {
        Self.fields.compactMap { kind in value(for: kind).map { (kind, $0) } }
    }

    var title: String {
        let label = label.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? (value(for: .name) ?? "Card") : label
    }

    var subtitle: String {
        [value(for: .name), value(for: .email)].compactMap { $0 }.joined(separator: " · ")
    }

    var isEmpty: Bool { values.isEmpty }
}

/// Where the cards are kept: a Keychain item in the app, memory in tests.
nonisolated protocol PersonalCardBackend {
    func load() -> Data?
    @discardableResult func save(_ data: Data) -> Bool
}

/// One generic-password item holding every card as JSON. Login Keychain, this Mac only.
nonisolated struct KeychainCardBackend: PersonalCardBackend {
    var service = (Bundle.main.bundleIdentifier ?? "at.softmaze.Clippy") + ".cards"
    var account = "cards"

    private var base: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    func load() -> Data? {
        var query = base
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func save(_ data: Data) -> Bool {
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData] = data
            add[kSecAttrLabel] = "Clipboard2 personal info"
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    func remove() {
        SecItemDelete(base as CFDictionary)
    }
}

nonisolated final class InMemoryCardBackend: PersonalCardBackend {
    var data: Data?
    init(data: Data? = nil) { self.data = data }
    func load() -> Data? { data }
    func save(_ data: Data) -> Bool { self.data = data; return true }
}

@Observable
final class PersonalCardStore {
    private(set) var cards: [PersonalCard] = []
    @ObservationIgnored private let backend: any PersonalCardBackend

    init(backend: any PersonalCardBackend = KeychainCardBackend()) {
        self.backend = backend
        reload()
    }

    func reload() {
        cards = backend.load().flatMap { try? JSONDecoder().decode([PersonalCard].self, from: $0) } ?? []
    }

    func card(withID id: UUID) -> PersonalCard? { cards.first { $0.id == id } }

    /// Adds it, or replaces the card with its id.
    @discardableResult
    func save(_ card: PersonalCard) -> Bool {
        var next = cards
        if let index = next.firstIndex(where: { $0.id == card.id }) { next[index] = card } else { next.append(card) }
        return write(next)
    }

    func delete(_ card: PersonalCard) {
        write(cards.filter { $0.id != card.id })
    }

    @discardableResult
    private func write(_ next: [PersonalCard]) -> Bool {
        guard let data = try? JSONEncoder().encode(next), backend.save(data) else { return false }
        cards = next
        return true
    }

    /// Every card's value for a field kind, first card first.
    func matches(for kind: FormFieldKind) -> [(card: PersonalCard, value: String)] {
        cards.compactMap { card in card.value(for: kind).map { (card, $0) } }
    }
}
