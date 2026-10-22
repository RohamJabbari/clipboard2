import Foundation
import SwiftData
import Observation

@Observable
final class SnippetStore {
    @ObservationIgnored let context: ModelContext
    private(set) var revision = 0
    /// Called after every commit (sync schedules a push from it).
    @ObservationIgnored var onCommit: (() -> Void)?

    init(context: ModelContext) {
        self.context = context
    }

    func all() -> [Snippet] {
        let descriptor = FetchDescriptor<Snippet>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(descriptor)) ?? []
    }

    @discardableResult
    func create(name: String = "New Snippet", keyword: String = "", body: String = "") -> Snippet {
        let snippet = Snippet(name: name, keyword: keyword, body: body)
        context.insert(snippet)
        commit()
        return snippet
    }

    func delete(_ snippet: Snippet) {
        context.delete(snippet)
        commit()
    }

    func didEdit(_ snippet: Snippet) {
        snippet.updatedAt = .now
        commit()
    }

    private func commit() {
        do { try context.save() } catch {
            Log.store.error("Snippet save failed: \(error.localizedDescription, privacy: .public)")
        }
        revision &+= 1
        onCommit?()
    }

    // MARK: Sync

    func snippet(withID id: UUID) -> Snippet? {
        var descriptor = FetchDescriptor<Snippet>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func snippets(inSpace spaceID: String?) -> [Snippet] {
        (try? context.fetch(FetchDescriptor<Snippet>(predicate: #Predicate { $0.spaceID == spaceID }))) ?? []
    }

    /// Inserts a snippet received from sync without committing.
    func insertSynced(_ snippet: Snippet) {
        context.insert(snippet)
    }

    func removeSynced(_ snippet: Snippet) {
        context.delete(snippet)
    }

    func commitSynced() {
        commit()
    }

    func removeAll(inSpace spaceID: String) {
        let doomed = snippets(inSpace: spaceID)
        guard !doomed.isEmpty else { return }
        for snippet in doomed { context.delete(snippet) }
        commit()
    }
}
