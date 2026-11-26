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
    /// Called with the ids retention removed (their sync metadata is already gone).
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

    /// When the newest item of a space was copied or arrived.
    func newestDate(inSpace spaceID: String?) -> Date? {
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.spaceID == spaceID },
            sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.lastCopiedAt
    }

    /// The newest item of a space (nil = personal: Copies' newest).
    func newestItem(inSpace spaceID: String?) -> ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.spaceID == spaceID },
            sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
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

    /// Sets (or clears, for empty text) a label. Labels are how items are kept: a labelled item is
    /// pinned so it never expires, and removing the label releases it again — unless `keepPinned`
    /// (a quick slot still needs the item) or it's in a folder.
    func setLabel(_ label: String?, for item: ClipItem, keepPinned: Bool = false) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hadLabel = item.label != nil
        item.label = trimmed.isEmpty ? nil : trimmed
        if item.label != nil && !item.isPinned {
            item.isPinned = true
            item.pinnedAt = .now
        } else if item.label == nil && hadLabel && item.isPinned && !keepPinned && item.folderID == nil {
            item.isPinned = false
            item.pinnedAt = nil
        }
        commit()
    }

    /// Pinning is internal ("kept forever", shown as Saved): labels, folders and quick slots set
    /// it. Unpinning takes the item out of its folder.
    func togglePin(_ item: ClipItem) {
        item.isPinned.toggle()
        item.pinnedAt = item.isPinned ? .now : nil
        if !item.isPinned { item.folderID = nil }
        commit()
    }

    /// Remove from Saved: releases an item kept without a label (a labelled one is released by
    /// removing its label), out of its folder too, so it expires normally.
    func removeFromLabelled(_ item: ClipItem) {
        removeFromSaved([item])
    }

    func removeFromSaved(_ items: [ClipItem]) {
        var changed = false
        for item in items where item.isPinned && item.label == nil {
            item.isPinned = false
            item.pinnedAt = nil
            item.folderID = nil
            changed = true
        }
        if changed { commit() }
    }

    /// Add to Saved: keeps the items forever without a label.
    func addToSaved(_ items: [ClipItem], now: Date = .now) {
        var changed = false
        for item in items where !item.isPinned && !item.isTransient {
            item.isPinned = true
            item.pinnedAt = now
            changed = true
        }
        if changed { commit() }
    }

    // MARK: Folders

    /// Folders of one space (nil = personal), by name.
    func folders(inSpace spaceID: String?) -> [ClipFolder] {
        let descriptor = FetchDescriptor<ClipFolder>(predicate: #Predicate { $0.spaceID == spaceID })
        return ((try? context.fetch(descriptor)) ?? []).sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.createdAt < $1.createdAt : order == .orderedAscending
        }
    }

    func allFolders() -> [ClipFolder] {
        (try? context.fetch(FetchDescriptor<ClipFolder>())) ?? []
    }

    func folder(withID id: UUID) -> ClipFolder? {
        var descriptor = FetchDescriptor<ClipFolder>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// The folder an item shows in: nil when it has none, or one that isn't here (deleted, or
    /// not synced yet), or one in another space.
    func folder(of item: ClipItem) -> ClipFolder? {
        guard item.isPinned, let id = item.folderID, let folder = folder(withID: id), folder.spaceID == item.spaceID else {
            return nil
        }
        return folder
    }

    /// Saved items in a folder.
    func items(inFolder folder: ClipFolder) -> [ClipItem] {
        let id: UUID? = folder.id
        let spaceID = folder.spaceID
        let descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.folderID == id && $0.spaceID == spaceID && $0.isPinned == true },
            sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The folders of a space as a tree.
    func tree(inSpace spaceID: String?) -> FolderTree {
        FolderTree(folders(inSpace: spaceID))
    }

    /// `parent`: a folder of the same space it goes in (ignored if it's another space's or
    /// already 8 levels deep); nil at the top level.
    @discardableResult
    func createFolder(named name: String = "New Folder", inSpace spaceID: String?, parent: ClipFolder? = nil,
                      now: Date = .now) -> ClipFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = ClipFolder(name: trimmed.isEmpty ? "New Folder" : trimmed, spaceID: spaceID, now: now)
        if let parent, parent.spaceID == spaceID, tree(inSpace: spaceID).canCreate(in: parent.id) {
            folder.parentID = parent.id
        }
        context.insert(folder)
        commit()
        return folder
    }

    /// Moves a folder (with everything in it) into another folder of its space, or (nil) to the
    /// top level. Refuses moves into itself or below itself, and deeper than 8 levels.
    @discardableResult
    func moveFolder(_ folder: ClipFolder, under parent: ClipFolder?, now: Date = .now) -> Bool {
        if let parent, parent.spaceID != folder.spaceID { return false }
        guard tree(inSpace: folder.spaceID).canMove(folder.id, under: parent?.id) else { return false }
        folder.parentID = parent?.id
        folder.updatedAt = max(now, folder.updatedAt.addingTimeInterval(0.001))
        commit()
        return true
    }

    /// An empty name is ignored.
    func rename(_ folder: ClipFolder, to name: String, now: Date = .now) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != folder.name else { return }
        folder.name = trimmed
        folder.updatedAt = now
        commit()
    }

    /// Sets (or clears, for empty text) a folder's label.
    func setLabel(_ label: String?, for folder: ClipFolder, now: Date = .now) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let new = trimmed.isEmpty ? nil : trimmed
        guard new != folder.label else { return }
        folder.label = new
        folder.updatedAt = now
        commit()
    }

    /// Deletes the folder; its clips stay saved and, with its subfolders, move up to its parent
    /// (the root of Saved for a top-level folder), so sync pushes them with the new place.
    /// Returns how many clips moved.
    @discardableResult
    func deleteFolder(_ folder: ClipFolder, now: Date = .now) -> Int {
        let id: UUID? = folder.id
        let spaceID = folder.spaceID
        let tree = tree(inSpace: spaceID)
        let parent = tree.parent(of: folder.id)
        let descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.folderID == id && $0.spaceID == spaceID })
        let items = (try? context.fetch(descriptor)) ?? []
        for item in items { item.folderID = parent }
        for child in tree.children(of: folder.id) {
            guard let subfolder = self.folder(withID: child.id) else { continue }
            subfolder.parentID = parent
            subfolder.updatedAt = max(now, subfolder.updatedAt.addingTimeInterval(0.001))
        }
        context.delete(folder)
        commit()
        return items.filter(\.isPinned).count
    }

    /// Moves items into a folder of their own space (which saves them). Items of another space,
    /// and transient ones, are left alone. Returns how many moved.
    @discardableResult
    func move(_ items: [ClipItem], to folder: ClipFolder, now: Date = .now) -> Int {
        var moved = 0
        for item in items where !item.isTransient && item.spaceID == folder.spaceID {
            if !item.isPinned {
                item.isPinned = true
                item.pinnedAt = now
            }
            if item.folderID != folder.id { item.folderID = folder.id }
            moved += 1
        }
        if moved > 0 { commit() }
        return moved
    }

    /// Takes items out of their folder; they stay saved, at the root of Saved.
    func removeFromFolder(_ items: [ClipItem]) {
        var changed = false
        for item in items where item.folderID != nil {
            item.folderID = nil
            changed = true
        }
        if changed { commit() }
    }

    /// Copies a folder, its subfolders and their clips into a group with new ids, keeping the
    /// structure (Share to Group); with `parent` (one of the group's folders) it goes in there.
    /// The original stays as it is; later changes don't follow. Returns the copy; `mapping` gets
    /// original folder id → copy, e.g. to put copied secrets in the right place.
    @discardableResult
    func shareCopy(of folder: ClipFolder, toSpace spaceID: String?, parent: ClipFolder? = nil, now: Date = .now,
                   mapping: ((UUID, ClipFolder) -> Void)? = nil) -> ClipFolder {
        let tree = tree(inSpace: folder.spaceID)
        func copySubtree(_ original: ClipFolder, under parentID: UUID?) -> ClipFolder {
            let made = ClipFolder(name: original.name, spaceID: spaceID, now: now)
            made.label = original.label
            made.parentID = parentID
            context.insert(made)
            mapping?(original.id, made)
            for item in items(inFolder: original) {
                let shared = shareCopy(of: item, toSpace: spaceID, now: now)
                if !shared.isPinned {
                    shared.isPinned = true
                    shared.pinnedAt = now
                }
                shared.folderID = made.id
            }
            for child in tree.children(of: original.id) {
                if let subfolder = self.folder(withID: child.id) { _ = copySubtree(subfolder, under: made.id) }
            }
            return made
        }
        let target = parent.flatMap { $0.spaceID == spaceID ? $0.id : nil }
        let result = copySubtree(folder, under: target)
        commit()
        return result
    }

    /// Inserts a folder received from sync (without committing).
    func insertSynced(_ folder: ClipFolder) {
        context.insert(folder)
    }

    /// Deletes a folder received as deleted, without committing. Its clips keep their
    /// `folderID` and read as the root of Saved.
    func removeSynced(_ folder: ClipFolder) {
        context.delete(folder)
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
        if item.kind == .file { removeSyncedFiles(of: item.id) }
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

    /// Saves text edited in the quick panel. `rtf`/`html` are nil for plain text. The item keeps
    /// its place, pin and label; another item that now has the same content is merged into it.
    func editText(of item: ClipItem, text: String, rtf: Data?, html: Data?) {
        guard item.kind.isTextual, text != item.text || rtf != item.rtfData else { return }
        let hash = ContentHasher.hash(text: text)
        if let duplicate = self.item(withHash: hash, inSpace: item.spaceID), duplicate.id != item.id {
            item.copyCount += duplicate.copyCount
            remove(duplicate)
        }
        item.kind = rtf == nil ? .text : .richText
        item.text = text
        item.preview = TextPreview.make(text)
        item.rtfData = rtf
        item.htmlData = html
        item.contentHash = hash
        item.byteCount = text.utf8.count + (rtf?.count ?? 0) + (html?.count ?? 0)
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
            forgetSyncState(of: removed)
            onExpire?(removed)
            commit()
        }
    }

    /// Retention only stops tracking items; it never deletes them on other devices. Done here
    /// rather than by sync, so it also holds while no sync session is running (signed out of
    /// the server, waiting for the password): a missing meta row never turns into a DELETE.
    private func forgetSyncState(of ids: [UUID]) {
        let keys = ids.map { $0.uuidString.lowercased() }
        let clipCategories = [SyncCategory.history.rawValue, SyncCategory.pinned.rawValue]
        let descriptor = FetchDescriptor<SyncMeta>(predicate: #Predicate { keys.contains($0.localId) })
        for meta in (try? context.fetch(descriptor)) ?? [] where clipCategories.contains(meta.category) {
            context.delete(meta)
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

    /// Deletes `Synced Files/<id>` folders whose item is gone or no longer a file clip. Young
    /// folders are left alone: sync writes a folder just before inserting its item.
    func removeOrphanedSyncedFiles(in directory: URL = AppPaths.syncedFilesDirectory,
                                   olderThan age: TimeInterval = SyncConfig.orphanedFilesAge, now: Date = .now) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                         options: [.skipsHiddenFiles]) else { return }
        let fileClips = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.kindRaw == "file" })
        let live = Set(((try? context.fetch(fileClips)) ?? []).map { $0.id.uuidString.lowercased() })
        for folder in folders where !live.contains(folder.lastPathComponent.lowercased()) {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > age else { continue }
            try? fm.removeItem(at: folder)
        }
    }

    /// Removes the folder of files sync received for an item (only ever inside Synced Files).
    func removeSyncedFiles(of id: UUID) {
        try? FileManager.default.removeItem(at: AppPaths.syncedFilesFolder(for: id))
    }

    // MARK: Files kept by Clipboard2

    /// A new personal file clip whose one file Clipboard2 keeps itself, in the item's own folder
    /// (`directory/<id>/<name>`, the same place synced files live, so it syncs, is copied and is
    /// deleted with the item like those). The file is `contents`, or a copy of `source`. `original`
    /// lends its source app. Nothing on disk outside `directory` changes.
    @discardableResult
    func addKeptFile(named name: String, contents: Data? = nil, copying source: URL? = nil, like original: ClipItem? = nil,
                     directory: URL = AppPaths.syncedFilesDirectory, now: Date = .now) throws -> ClipItem {
        let id = UUID()
        let folder = directory.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
        let url: URL
        if let contents {
            url = try TextFileContents.write(contents, named: name, into: folder)
        } else if let source {
            url = try TextFileContents.copy(source, named: name, into: folder)
        } else {
            throw CocoaError(.fileNoSuchFile)
        }
        let size = TextFileContents.regularFileSize(url) ?? contents?.count ?? 0
        let capture = ProcessedCapture(kind: .file, text: url.path, preview: name, fileURLs: [url], source: original?.source,
                                       hash: ContentHasher.hash(fileURLs: [url]), byteCount: size)
        let item = ClipItem(capture: capture, now: now)
        item.id = id
        context.insert(item)
        commit()
        return item
    }

    /// Whether every file of `item` is one Clipboard2 keeps in the item's own folder (an edited or
    /// renamed copy, or files that arrived through sync), so it may be renamed in place.
    func keepsFiles(of item: ClipItem, directory: URL = AppPaths.syncedFilesDirectory) -> Bool {
        let folder = directory.appending(path: item.id.uuidString.lowercased(), directoryHint: .isDirectory).standardizedFileURL.path
        return item.kind == .file && !item.fileURLs.isEmpty
            && item.fileURLs.allSatisfy { $0.standardizedFileURL.deletingLastPathComponent().path == folder }
    }

    /// Renames the one kept file of `item` (see `keepsFiles`) and points the item at it.
    func renameKeptFile(of item: ClipItem, to name: String, directory: URL = AppPaths.syncedFilesDirectory) throws {
        guard keepsFiles(of: item, directory: directory), item.fileURLs.count == 1, let old = item.fileURLs.first else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let new = old.deletingLastPathComponent().appending(path: name, directoryHint: .notDirectory)
        guard new.path != old.path else { return }
        let fm = FileManager.default
        if old.lastPathComponent.lowercased() == name.lowercased() {
            // Only the case changes: go through a temporary name (the file system ignores case).
            let temporary = old.deletingLastPathComponent().appending(path: UUID().uuidString)
            try fm.moveItem(at: old, to: temporary)
            try fm.moveItem(at: temporary, to: new)
        } else {
            if fm.fileExists(atPath: new.path) { try fm.removeItem(at: new) }
            try fm.moveItem(at: old, to: new)
        }
        item.fileURLStrings = [new.absoluteString]
        item.text = new.path
        item.preview = name
        item.contentHash = ContentHasher.hash(fileURLs: [new])
        commit()
    }

    /// Saves personal copies of (group) items: new ids in the personal space, saved, in `folder`
    /// (a personal folder) or at the root of Saved. The originals don't change. A personal item
    /// with the same content is reused rather than duplicated. Returns the copies.
    @discardableResult
    func savePersonalCopies(of items: [ClipItem], into folder: ClipFolder? = nil, now: Date = .now) -> [ClipItem] {
        guard folder?.spaceID == nil else { return [] }
        var copies: [ClipItem] = []
        for item in items where !item.isTransient {
            let copy = item.spaceID == nil ? item : shareCopy(of: item, toSpace: nil, now: now)
            if !copy.isPinned {
                copy.isPinned = true
                copy.pinnedAt = now
            }
            // A personal item reused for the copy keeps the folder it's in, unless one was chosen.
            if let folder { copy.folderID = folder.id }
            copies.append(copy)
        }
        if !copies.isEmpty { commit() }
        return copies
    }

    // MARK: Sync

    /// Copies an item into a sync group (or, for nil, the personal space) with a new id. Images
    /// and synced files get their own copies, so deleting one item never breaks the other.
    /// `keepLabel: false` (sending to a contact) leaves this user's label and pin behind.
    @discardableResult
    func shareCopy(of item: ClipItem, toSpace spaceID: String?, keepLabel: Bool = true, now: Date = .now) -> ClipItem {
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
        if keepLabel {
            copy.label = item.label
            copy.isPinned = item.isPinned
            copy.pinnedAt = item.pinnedAt
        }
        let base = UUID().uuidString
        copy.imageFile = copyBlob(item.imageFile, to: base + ".png")
        copy.thumbnailFile = copyBlob(item.thumbnailFile, to: base + "-thumb.png")
        if item.kind == .file { copySyncedFiles(from: item, to: copy) }
        context.insert(copy)
        commit()
        return copy
    }

    /// Files sync received live in the item's own folder, which goes when the item does: give
    /// the copy its own folder and point it there.
    private func copySyncedFiles(from item: ClipItem, to copy: ClipItem) {
        let fm = FileManager.default
        let source = AppPaths.syncedFilesFolder(for: item.id).standardizedFileURL
        guard fm.fileExists(atPath: source.path) else { return }
        let destination = AppPaths.syncedFilesFolder(for: copy.id)
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
        } catch {
            Log.store.error("Can't copy synced files: \(error.localizedDescription, privacy: .public)")
            return
        }
        let urls = item.fileURLs.map { url in
            url.standardizedFileURL.deletingLastPathComponent().path == source.path
                ? destination.appending(path: url.lastPathComponent) : url
        }
        copy.fileURLStrings = urls.map(\.absoluteString)
        copy.text = urls.map(\.path).joined(separator: "\n")
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
            if winner.folderID == nil { winner.folderID = sorted.lazy.filter(\.isPinned).compactMap(\.folderID).first }
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
        let folders = folders(inSpace: spaceID)
        guard !items.isEmpty || !folders.isEmpty else { return }
        for item in items { remove(item) }
        for folder in folders { context.delete(folder) }
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
        if item.kind == .file { try? FileManager.default.removeItem(at: AppPaths.syncedFilesFolder(for: item.id)) }
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
