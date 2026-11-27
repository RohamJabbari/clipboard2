import Foundation
import SwiftData
import Observation
import KeyboardShortcuts

nonisolated enum SlotTarget: Codable, Hashable, Sendable {
    case clip(UUID)
    case snippet(UUID)
    case secret(String)
}

extension KeyboardShortcuts.Name {
    /// Optional global shortcuts that paste quick slot 1…9 from any app (no defaults).
    static let quickSlots: [KeyboardShortcuts.Name] = (1...9).map { Self("quickSlot\($0)") }
}

/// ⌘1…⌘9 in the quick panel, bound to saved things instead of list positions.
@Observable
final class QuickSlots {
    static let range = 1...9

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: ClipStore
    @ObservationIgnored private let snippets: SnippetStore
    @ObservationIgnored private let secrets: SecretStore
    private static let key = "quickSlots"

    private(set) var assignments: [Int: SlotTarget] = [:] {
        didSet { persist() }
    }

    init(defaults: UserDefaults, store: ClipStore, snippets: SnippetStore, secrets: SecretStore) {
        self.defaults = defaults
        self.store = store
        self.snippets = snippets
        self.secrets = secrets
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: SlotTarget].self, from: data) {
            assignments = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                Int(key).flatMap { Self.range.contains($0) ? ($0, value) : nil }
            })
        }
    }

    func target(for slot: Int) -> SlotTarget? { assignments[slot] }

    func slot(for target: SlotTarget) -> Int? {
        assignments.first { $0.value == target }?.key
    }

    /// Assigns an entry; clips get pinned so retention never deletes a slotted item.
    func assign(_ entry: PanelEntry, to slot: Int) {
        guard Self.range.contains(slot), let target = entry.slotTarget else { return }
        if let existing = self.slot(for: target) { assignments[existing] = nil }
        if case .clip(let item) = entry, !item.isPinned { store.togglePin(item) }
        assignments[slot] = target
    }

    func clear(_ slot: Int) {
        assignments[slot] = nil
    }

    func remove(target: SlotTarget) {
        if let slot = slot(for: target) { assignments[slot] = nil }
    }

    /// Resolves a slot to a live entry, dropping assignments whose item no longer exists.
    func entry(for slot: Int) -> PanelEntry? {
        guard let target = assignments[slot] else { return nil }
        let entry: PanelEntry?
        switch target {
        case .clip(let id):
            var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            entry = (try? store.context.fetch(descriptor))?.first.map(PanelEntry.clip)
        case .snippet(let id):
            entry = snippets.all().first { $0.id == id }.map(PanelEntry.snippet)
        case .secret(let id):
            entry = secrets.secrets.first { $0.id == id }.map(PanelEntry.secret)
        }
        if entry == nil { assignments[slot] = nil }
        return entry
    }

    func title(for slot: Int) -> String? {
        switch entry(for: slot) {
        case .clip(let item): item.preview.isEmpty ? item.kind.displayName : item.preview
        case .snippet(let snippet): snippet.name
        case .secret(let ref): ref.name
        case .folder(let folder): folder.name
        case .authenticator(let item): item.title
        case .authenticatorSuggestion, .emailCode, nil: nil
        }
    }

    private func persist() {
        let encoded = Dictionary(uniqueKeysWithValues: assignments.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(encoded) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
