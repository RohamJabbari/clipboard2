import Foundation
import SwiftData
import Observation

/// All history mutations go through here so blobs and the database stay consistent.
@Observable
final class ClipStore {
    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let blobs: BlobStore

    /// Bumped after every committed change; views observe it to refresh derived lists.
    private(set) var revision = 0
    /// Called after every commit (sync schedules a push from it).
    @ObservationIgnored var onCommit: (() -> Void)?
    /// Called with the ids retention removed, so sync stops tracking them instead of deleting
    /// them on other devices.
    @ObservationIgnored var onExpire: (([UUID]) -> Void)?

    init(context: ModelContext, blobs: BlobStore) {
        self.context = context
        self.blobs = blobs
    }

    // MARK: Reads

    func allItems() -> [ClipItem] {
        let descriptor = FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Items of one space (nil = personal), newest first.
    func items(inSpace spaceID: String?) -> [ClipItem] {
        let descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.spaceID == spaceID },
            sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func item(withHash hash: String, inSpace spaceID: String? = nil) -> ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.contentHash == hash && $0.spaceID == spaceID })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func item(withID id: UUID) -> ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func count() -> Int {
        (try? context.fetchCount(FetchDescriptor<ClipItem>())) ?? 0
    }

    // MARK: Writes

    /// Inserts a capture, or — if identical content already exists in that space — moves that
    /// item to the top. `spaceID` nil is the personal space.
    @discardableResult
    func ingest(_ capture: ProcessedCapture, spaceID: String? = nil, now: Date = .now) -> ClipItem {
        if let existing = item(withHash: capture.hash, inSpace: spaceID) {
            existing.lastCopiedAt = now
            existing.copyCount += 1
            if let source = capture.source {
                existing.sourceBundleID = source.bundleID
                existing.sourceAppName = source.name
            }
            if capture.rtfData != nil || capture.htmlData != nil {
                existing.rtfData = capture.rtfData ?? existing.rtfData
                existing.htmlData = capture.htmlData ?? existing.htmlData
                existing.kind = .richText
            }
            // The processor already wrote blobs for this capture; they're redundant now.
            if capture.imageFile != existing.imageFile { blobs.delete(capture.imageFile) }
            if capture.thumbnailFile != existing.thumbnailFile { blobs.delete(capture.thumbnailFile) }
            commit()
            return existing
        }

        let item = ClipItem(capture: capture, now: now)
        item.spaceID = spaceID
        context.insert(item)
        commit()
        return item
    }

    func touch(_ item: ClipItem, now: Date = .now) {
        item.lastCopiedAt = now
        commit()
    }

    /// Sets (or clears, for empty text) a label. Labelled items are pinned so they never expire.
    func setLabel(_ label: String?, for item: ClipItem) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        item.label = trimmed.isEmpty ? nil : trimmed
        if item.label != nil && !item.isPinned {
            item.isPinned = true
            item.pinnedAt = .now
        }
        commit()
    }

    func togglePin(_ item: ClipItem) {
        item.isPinned.toggle()
        item.pinnedAt = item.isPinned ? .now : nil
        commit()
    }

    func delete(_ item: ClipItem) {
        remove(item)
        commit()
    }

    func clearHistory(includingPinned: Bool = false) {
        for item in allItems() where includingPinned || !item.isPinned {
            remove(item)
        }
        commit()
    }

    /// Replaces an item's content with new plain text (e.g. a Claude result).
    func replaceText(of item: ClipItem, with text: String) {
        let hash = ContentHasher.hash(text: text)
        if let duplicate = self.item(withHash: hash, inSpace: item.spaceID), duplicate.id != item.id {
            remove(duplicate)
        }
        blobs.delete(item.imageFile)
        blobs.delete(item.thumbnailFile)
        item.kind = .text
        item.text = text
        item.preview = TextPreview.make(text)
        item.rtfData = nil
        item.htmlData = nil
        item.fileURLStrings = []
        item.imageFile = nil
        item.thumbnailFile = nil
        item.contentHash = hash
        item.byteCount = text.utf8.count
        item.lastCopiedAt = .now
        commit()
    }

    // MARK: Duplicates

    /// Recomputes text hashes (after a hashing change) and applies precomputed image hashes.
    func applyHashes(images: [UUID: String]) {
        for item in allItems() {
            if item.kind.isTextual {
                item.contentHash = ContentHasher.hash(text: item.text)
            } else if let hash = images[item.id] {
                item.contentHash = hash
            }
        }
        commit()
    }

    /// Collapses items with the same content within each space. Pinned items are never deleted;
    /// otherwise the most recently copied one survives and inherits the group's copy count.
    @discardableResult
    func mergeDuplicates() -> Int {
        var removed = 0
        let groups = Dictionary(grouping: allItems()) { DuplicateKey(spaceID: $0.spaceID, hash: $0.contentHash) }
        for (_, items) in groups where items.count > 1 {
            let pinned = items.filter(\.isPinned)
            guard let newest = items.max(by: { $0.lastCopiedAt < $1.lastCopiedAt }) else { continue }
            let keepers = pinned.isEmpty ? [newest] : pinned
            guard let survivor = keepers.max(by: { $0.lastCopiedAt < $1.lastCopiedAt }) else { continue }
            survivor.lastCopiedAt = newest.lastCopiedAt
            survivor.copyCount = items.reduce(0) { $0 + $1.copyCount }
            for item in items where !keepers.contains(where: { $0.id == item.id }) {
                remove(item)
                removed += 1
            }
        }
        if removed > 0 {
            Log.store.info("Merged \(removed) duplicate items")
            commit()
        }
        return removed
    }

    /// Removes unpinned history items of one space whose text matches one of `hashes` (e.g. the
    /// secrets saved in that space).
    func removeUnpinned(matching hashes: Set<String>, inSpace spaceID: String? = nil) {
        guard !hashes.isEmpty else { return }
        var removed = 0
        for item in items(inSpace: spaceID) where !item.isPinned && hashes.contains(item.contentHash) {
            remove(item)
            removed += 1
        }
        if removed > 0 { commit() }
    }

    // MARK: Retention

    /// The user's limits apply to the personal space only; pinned items are exempt from both.
    /// `maxAge == nil` keeps forever; `maxItems == 0` means no count limit. Each sync group keeps
    /// its newest `groupLimit` history items.
    func enforceRetention(maxItems: Int, maxAge: TimeInterval?, groupLimit: Int = SyncConfig.historyLimit,
                          now: Date = .now) {
        var removed: [UUID] = []

        if let maxAge {
            let cutoff = now.addingTimeInterval(-maxAge)
            let expired = FetchDescriptor<ClipItem>(
                predicate: #Predicate { $0.isPinned == false && $0.lastCopiedAt < cutoff && $0.spaceID == nil }
            )
            for item in (try? context.fetch(expired)) ?? [] {
                removed.append(item.id)
                remove(item)
            }
        }

        if maxItems > 0 {
            var overflow = FetchDescriptor<ClipItem>(
                predicate: #Predicate { $0.isPinned == false && $0.spaceID == nil },
                sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
            )
            overflow.fetchOffset = maxItems
            for item in (try? context.fetch(overflow)) ?? [] {
                removed.append(item.id)
                remove(item)
            }
        }

        let groupHistory = FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.isPinned == false && $0.spaceID != nil },
            sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
        )
        let bySpace = Dictionary(grouping: (try? context.fetch(groupHistory)) ?? []) { $0.spaceID ?? "" }
        for items in bySpace.values where items.count > groupLimit {
            for item in items.dropFirst(groupLimit) {
                removed.append(item.id)
                remove(item)
            }
        }

        if !removed.isEmpty {
            Log.store.info("Retention removed \(removed.count) items")
            onExpire?(removed)
            commit()
        }
    }

    /// Deletes blob files no item references (e.g. after a crash mid-capture).
    func removeOrphanedBlobs() {
        var referenced = Set<String>()
        for item in allItems() {
            if let f = item.imageFile { referenced.insert(f) }
            if let f = item.thumbnailFile { referenced.insert(f) }
        }
        for name in blobs.allFileNames() where !referenced.contains(name) {
            blobs.delete(name)
        }
    }

    // MARK: Sync

    /// Copies an item into a sync group with a new id (images get their own blob files, so
    /// deleting one copy never breaks the other).
    @discardableResult
    func shareCopy(of item: ClipItem, toSpace spaceID: String, now: Date = .now) -> ClipItem {
        if let existing = self.item(withHash: item.contentHash, inSpace: spaceID), !item.contentHash.isEmpty {
            existing.lastCopiedAt = now
            existing.copyCount += 1
            commit()
            return existing
        }
        let copy = ClipItem(capture: .text(""), now: now)
        copy.spaceID = spaceID
        copy.kind = item.kind
        copy.text = item.text
        copy.preview = item.preview
        copy.rtfData = item.rtfData
        copy.htmlData = item.htmlData
        copy.contentHash = item.contentHash
        copy.fileURLStrings = item.fileURLStrings
        copy.imageWidth = item.imageWidth
        copy.imageHeight = item.imageHeight
        copy.byteCount = item.byteCount
        copy.sourceBundleID = item.sourceBundleID
        copy.sourceAppName = item.sourceAppName
        copy.label = item.label
        copy.isPinned = item.isPinned
        copy.pinnedAt = item.pinnedAt
        let base = UUID().uuidString
        copy.imageFile = copyBlob(item.imageFile, to: base + ".png")
        copy.thumbnailFile = copyBlob(item.thumbnailFile, to: base + "-thumb.png")
        context.insert(copy)
        commit()
        return copy
    }

    private func copyBlob(_ name: String?, to newName: String) -> String? {
        guard let name, let data = try? Data(contentsOf: blobs.url(for: name)) else { return nil }
        do {
            try blobs.write(data, name: newName)
            return newName
        } catch {
            return nil
        }
    }

    /// Sync's duplicate rule: within one space the lexicographically smallest (lowercase) id wins,
    /// adds up the copy counts, keeps the newest `lastCopiedAt` and either side's label and pin.
    /// Every device picks the same survivor, so they converge. Returns the number removed.
    @discardableResult
    func convergeDuplicates(inSpace spaceID: String?) -> Int {
        var removed = 0
        let byHash = Dictionary(grouping: items(inSpace: spaceID).filter { !$0.contentHash.isEmpty }, by: \.contentHash)
        for (_, items) in byHash where items.count > 1 {
            let sorted = items.sorted { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() }
            let winner = sorted[0]
            winner.copyCount = items.reduce(0) { $0 + $1.copyCount }
            winner.lastCopiedAt = items.map(\.lastCopiedAt).max() ?? winner.lastCopiedAt
            winner.createdAt = items.map(\.createdAt).min() ?? winner.createdAt
            if winner.label == nil { winner.label = sorted.lazy.compactMap(\.label).first }
            if !winner.isPinned, let pinned = sorted.first(where: \.isPinned) {
                winner.isPinned = true
                winner.pinnedAt = pinned.pinnedAt
            }
            for loser in sorted.dropFirst() {
                remove(loser)
                removed += 1
            }
        }
        if removed > 0 { commit() }
        return removed
    }

    /// Inserts an item received from sync (its blobs must already be written).
    func insertSynced(_ item: ClipItem) {
        context.insert(item)
    }

    /// Deletes without committing; the caller commits once after a batch.
    func removeSynced(_ item: ClipItem) {
        remove(item)
    }

    /// Drops every item of a space, e.g. after leaving a group or signing out.
    func removeAll(inSpace spaceID: String) {
        let items = items(inSpace: spaceID)
        guard !items.isEmpty else { return }
        for item in items { remove(item) }
        commit()
    }

    /// Commits a batch of sync changes.
    func commitSynced() {
        commit()
    }

    // MARK: Private

    private func remove(_ item: ClipItem) {
        blobs.delete(item.imageFile)
        blobs.delete(item.thumbnailFile)
        context.delete(item)
    }

    private func commit() {
        do {
            try context.save()
        } catch {
            Log.store.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
        revision &+= 1
        onCommit?()
    }
}

nonisolated private struct DuplicateKey: Hashable {
    let spaceID: String?
    let hash: String
}
