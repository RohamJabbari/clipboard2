import Foundation
import ImageIO
import SwiftData


/// Secrets as sync sees them: the Keychain in the app, a dictionary in tests.
protocol SyncSecretSource: AnyObject {
    /// Fresh from the store (not a cached list), with `spaceID` and `updatedAt`.
    var syncSecrets: [SecretRef] { get }
    func syncValue(id: String) -> String?
    /// Creates the secret with this id, or replaces its name and value.
    func syncUpsert(id: String, name: String, value: String, spaceID: String?)
    func syncDelete(id: String)
    /// Called once after a batch of upserts and deletes.
    func syncDidChange()
}

/// Who this device syncs as: the uid, its unwrapped identity key and the personal space.
nonisolated struct SyncIdentity: Sendable, Equatable {
    var uid: String
    var privateKey: Data
    var publicKey: Data
    var personalSpaceId: String
}

/// One sync pass over every space (PROTOCOL.md → Client sync rules): refresh the space list and
/// keys, then for each space pull, converge duplicates, and push (deletions first).
@MainActor
final class SyncEngine {
    let api: any SyncService
    let identity: SyncIdentity
    let context: ModelContext
    let store: ClipStore
    let snippets: SnippetStore
    let secrets: any SyncSecretSource
    var now: () -> Date = { .now }

    /// This Mac's session id (from `/v1/sessions`), to recognise items sent to it.
    var deviceId: String?
    /// This Mac's name, sent with items it sends to another device.
    var deviceName: String?
    /// An item sent to this Mac arrived: its id and the sending device's name.
    var onSentToThisDevice: ((UUID, String?) -> Void)?
    /// The space-key pins changed; they're kept with the session keys.
    var onPinsChanged: (([String: String]) -> Void)?
    /// The space list was refreshed (start of every tick), so groups show before items arrive.
    var onSpacesUpdated: (() -> Void)?

    /// Images downloaded ahead of `apply` (see `prefetchImages`), by image blob id: the decrypted
    /// image and a thumbnail made from it.
    private var prefetched: [String: (image: Data, thumbnail: Data?)] = [:]
    /// How many images download at once while pulling, and how many items one prefetch covers
    /// (bounds the memory held to that many images).
    static let parallelDownloads = 6
    static let prefetchWindow = 8

    private var spaceKeys: [String: Data] = [:]
    /// SHA-256 (hex) of each space's key as first unwrapped or adopted, by space id.
    private(set) var keyPins: [String: String]
    /// The wrapped key last checked against the pin, so it's unwrapped again only when it changes.
    private var checkedWraps: [String: Data] = [:]
    /// Spaces whose key no longer matches its pin. They don't sync until left and joined again.
    private(set) var keyMismatches: Set<String> = []

    private struct Rejection {
        /// The clip's change stamp, or a snippet's or secret's fingerprint, when it was refused.
        var key: String
        var quota: Bool
        /// Shown while the refusal stands (quota: the storage is full).
        var message: String? = nil
    }
    /// Items the server refused for good (too large, over quota, clock off, someone else's), so
    /// they're retried only after they change. Quota refusals also after a deletion.
    private var rejected: [String: Rejection] = [:]
    /// Deletions the server refused for good; tried again after the next launch.
    private var rejectedDeletes: Set<String> = []
    /// Item id → session id it goes to with its next push (`toDevice`).
    private var pendingToDevice: [String: String] = [:]
    /// The server said this Mac's clock is off; cleared by the next accepted write.
    private(set) var clockSkew = false
    /// Refusals from the current tick worth showing.
    private(set) var warnings: [String] = []
    private var secretsChanged = false
    private var applyingDepth = 0
    /// Set on sign-out: a tick still in flight stops at its next await instead of touching
    /// models that were just deleted.
    private(set) var isStopped = false

    func stop() { isStopped = true }

    private func checkActive() throws {
        if isStopped { throw CancellationError() }
    }

    init(api: any SyncService, identity: SyncIdentity, context: ModelContext, store: ClipStore,
         snippets: SnippetStore, secrets: any SyncSecretSource, keyPins: [String: String] = [:]) {
        self.api = api
        self.identity = identity
        self.context = context
        self.store = store
        self.snippets = snippets
        self.secrets = secrets
        self.keyPins = keyPins
    }

    /// True while the engine writes what it received: those commits aren't local changes, so they
    /// must not schedule another tick.
    var isApplyingRemote: Bool { applyingDepth > 0 }

    private func quietly<T>(_ work: () throws -> T) rethrows -> T {
        applyingDepth += 1
        defer { applyingDepth -= 1 }
        return try work()
    }

    /// What to show after a tick: a key that changed, a clock that's off, or a refused item.
    var problem: String? {
        if let id = keyMismatches.sorted().first {
            if id == identity.personalSpaceId {
                return "Your personal sync key changed unexpectedly, so your own items aren't syncing. Sign out of Sync and in again."
            }
            let name = allSpaces().first { $0.id == id }?.name ?? "A group"
            return "This group's key changed unexpectedly, so “\(name)” isn't syncing. Leave the group and join it again."
        }
        if clockSkew {
            return SyncAPIError.server(status: 400, code: "clock_skew", message: "", retryAfter: nil).errorDescription
        }
        if let full = rejected.values.lazy.compactMap(\.message).sorted().first { return full }
        return warnings.first
    }

    // MARK: Keys

    func spaceKey(for spaceId: String) -> Data? { spaceKeys[spaceId] }

    /// Remembers a key this device created or joined with, and pins it.
    func adoptSpaceKey(_ key: Data, for spaceId: String) {
        spaceKeys[spaceId] = key
        keyMismatches.remove(spaceId)
        keyPins[spaceId] = SyncCrypto.sha256Hex(key)
        onPinsChanged?(keyPins)
    }

    /// Local `spaceID` for a server space: nil for the personal space.
    func localSpaceID(_ spaceId: String) -> String? {
        spaceId == identity.personalSpaceId ? nil : spaceId
    }

    // MARK: Send to device

    /// The item's next push carries `toDevice`.
    func send(itemID: UUID, toDevice deviceId: String) {
        pendingToDevice[itemID.uuidString.lowercased()] = deviceId
    }

    func isSendPending(itemID: UUID) -> Bool {
        pendingToDevice[itemID.uuidString.lowercased()] != nil
    }

    // MARK: Tick

    func tick() async throws {
        try checkActive()
        warnings = []
        let remote = try await api.spaces()
        try checkActive()
        // Groups first, and every download before any upload: a long first upload (or a rate limit
        // while sending it) must never keep new group items from arriving.
        let spaces = updateSpaces(remote).sorted { !$0.isPersonal && $1.isPersonal }
        onSpacesUpdated?()
        defer {
            prefetched = [:]
            save()
        }
        for space in spaces {
            try await inSpace(space, merging: .quietly) { try await self.pull(space, itemKey: $0) }
        }
        for space in spaces {
            // Duplicates found after the push need one more tick to send their tombstones.
            try await inSpace(space, merging: .asLocalChange) { try await self.push(space, itemKey: $0) }
        }
    }

    private enum MergeMode { case quietly, asLocalChange }

    private func inSpace(_ space: SyncSpace, merging: MergeMode, _ work: (Data) async throws -> Void) async throws {
        try checkActive()
        let spaceId = space.id
        guard let key = spaceKeys[spaceId], !keyMismatches.contains(spaceId) else { return }
        do {
            try await work(SyncCrypto.itemKey(spaceKey: key))
            try checkActive()
            let local = localSpaceID(spaceId)
            let merged = merging == .quietly ? quietly { store.convergeDuplicates(inSpace: local) }
                                             : store.convergeDuplicates(inSpace: local)
            if merged > 0 { Log.sync.info("Merged duplicates in a space") }
        } catch let error as SyncAPIError where error.status == 404 || error.code == "forbidden" {
            // Removed from the group mid-tick; the next space list drops it.
            try checkActive()
            Log.sync.notice("Space \(spaceId, privacy: .public) is gone: \(error.localizedDescription, privacy: .public)")
        }
        quietly { flushSecrets() }
    }

    /// Stop tracking items removed locally without deleting them elsewhere.
    func forget(_ ids: [UUID]) {
        for id in ids {
            if let meta = meta(for: id.uuidString.lowercased()), SyncCategory(rawValue: meta.category)?.isClip == true {
                context.delete(meta)
            }
        }
        save()
    }

    // MARK: Spaces

    /// Updates the cached space rows (names, roles), unwraps new keys and drops local data of
    /// spaces this account no longer belongs to. Returns the usable spaces, personal first.
    private func updateSpaces(_ remote: [RemoteSpace]) -> [SyncSpace] {
        var rows = Dictionary(allSpaces().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [SyncSpace] = []
        for space in remote {
            let existing = rows.removeValue(forKey: space.id)
            guard checkKey(of: space) else { continue }
            let row = existing ?? {
                let row = SyncSpace(id: space.id, kind: space.kind)
                context.insert(row)
                return row
            }()
            row.kind = space.kind
            row.role = space.role
            row.ownerUid = space.ownerUid
            row.memberCount = space.memberCount
            row.createdAt = space.createdAt
            if !row.authorsBackfilled {
                // Once per group after the update that added "copied by": download everything again
                // so items synced earlier learn who wrote them. New groups start from 0 anyway.
                if !space.isPersonal { row.since = 0 }
                row.authorsBackfilled = true
            }
            if let members = space.members {
                row.memberNames = Dictionary(members.map { ($0.uid, $0.name) }, uniquingKeysWith: { first, _ in first })
            }
            if space.isPersonal {
                row.name = "Personal"
            } else if let sealed = space.encryptedName, let key = spaceKeys[space.id] {
                row.name = (try? SyncCrypto.decryptGroupName(sealed, spaceKey: key, spaceId: space.id)) ?? "Group"
            } else if row.name.isEmpty {
                row.name = "Group"
            }
            result.append(row)
        }
        quietly {
            for gone in rows.values { removeSpaceLocally(gone) }
        }
        save()
        return result.sorted { $0.isPersonal && !$1.isPersonal }
    }

    /// Unwraps a space's key the first time and whenever its wrap changes, and holds it to the
    /// pin. A key that differs from the pin is never adopted: the space stops syncing.
    private func checkKey(of space: RemoteSpace) -> Bool {
        if spaceKeys[space.id] != nil, checkedWraps[space.id] == space.wrappedKey, !keyMismatches.contains(space.id) {
            return true
        }
        let key: Data
        do {
            key = try SyncCrypto.unwrapSpaceKey(space.wrappedKey, spaceId: space.id, uid: identity.uid,
                                                privateKey: identity.privateKey)
        } catch {
            Log.sync.error("Can't unwrap the key of space \(space.id, privacy: .public)")
            // A key this device made or joined with keeps working; don't retry the same wrap.
            checkedWraps[space.id] = space.wrappedKey
            return spaceKeys[space.id] != nil && !keyMismatches.contains(space.id)
        }
        let digest = SyncCrypto.sha256Hex(key)
        if let pin = keyPins[space.id], pin != digest {
            if !keyMismatches.contains(space.id) {
                Log.sync.error("The key of space \(space.id, privacy: .public) changed unexpectedly; not syncing it")
            }
            keyMismatches.insert(space.id)
            spaceKeys[space.id] = nil
            return false
        }
        keyMismatches.remove(space.id)
        spaceKeys[space.id] = key
        checkedWraps[space.id] = space.wrappedKey
        if keyPins[space.id] == nil {
            keyPins[space.id] = digest
            onPinsChanged?(keyPins)
        }
        return true
    }

    private func removeSpaceLocally(_ space: SyncSpace) {
        Log.sync.info("Leaving space \(space.id, privacy: .public)")
        for meta in metas(inSpace: space.id) { context.delete(meta) }
        if !space.isPersonal && space.id != identity.personalSpaceId {
            store.removeAll(inSpace: space.id)
            snippets.removeAll(inSpace: space.id)
            for ref in secrets.syncSecrets where ref.spaceID == space.id {
                secrets.syncDelete(id: ref.id)
                secretsChanged = true
            }
        }
        spaceKeys[space.id] = nil
        checkedWraps[space.id] = nil
        keyMismatches.remove(space.id)
        // Leaving and joining again starts a new pin.
        if keyPins.removeValue(forKey: space.id) != nil { onPinsChanged?(keyPins) }
        context.delete(space)
    }

    // MARK: Pull

    private func pull(_ space: SyncSpace, itemKey: Data) async throws {
        let spaceId = space.id
        while true {
            let since = space.since
            let page = try await api.changes(spaceId: spaceId, since: since, limit: SyncConfig.changesPageSize, full: space.resyncing)
            try checkActive()
            if page.resetRequired {
                guard since > 0 else { break }
                Log.sync.notice("Full resync of space \(spaceId, privacy: .public)")
                space.since = 0
                space.resyncing = true
                space.resyncSeen = []
                save()
                continue
            }
            if space.resyncing { space.resyncSeen.append(contentsOf: page.items.map(\.id)) }
            for (index, item) in page.items.enumerated() {
                if index % Self.prefetchWindow == 0 {
                    await prefetchImages(page.items[index..<min(index + Self.prefetchWindow, page.items.count)],
                                         spaceId: spaceId, itemKey: itemKey)
                    try checkActive()
                }
                try await apply(item, spaceId: spaceId, itemKey: itemKey, force: false)
                try checkActive()
            }
            prefetched = [:]
            space.since = max(since, page.nextSince)
            save()
            if !page.hasMore || page.items.isEmpty { break }
        }
        if space.resyncing { finishResync(space) }
    }

    /// After a full resync: the tombstones older than the purge horizon are gone, so whatever we
    /// track but the full state lacks was deleted. Group items go; personal pinned items, snippets
    /// and secrets go; personal history stays here (it may just have been trimmed) but is
    /// detached, so it's never pushed back as if it were new.
    private func finishResync(_ space: SyncSpace) {
        let seen = Set(space.resyncSeen)
        quietly {
            for meta in metas(inSpace: space.id) where !seen.contains(meta.localId) {
                if space.isPersonal && meta.category == SyncCategory.history.rawValue {
                    if let uuid = UUID(uuidString: meta.localId), let item = store.item(withID: uuid) {
                        meta.detached = true
                        meta.localStamp = Self.stamp(item)
                        meta.fingerprint = ""
                        meta.blobIds = []
                        meta.fileBlobs = [:]
                    } else {
                        context.delete(meta)
                    }
                } else {
                    deleteLocal(meta.localId)
                    context.delete(meta)
                }
            }
            space.resyncing = false
            space.resyncSeen = []
            commitLocal()
        }
    }

    /// Applies one server item: a newer upsert, a `user` tombstone or a `trimmed` one. `force`
    /// (after a 409) applies it even over unpushed local changes.
    private func apply(_ remote: RemoteItem, spaceId: String, itemKey: Data, force: Bool) async throws {
        let meta = self.meta(for: remote.id)
        if !force, let meta, meta.spaceId == spaceId, remote.seq > 0, meta.remoteSeq >= remote.seq {
            // Items synced before authors were tracked learn theirs on the one-time re-download.
            if meta.authorUid == nil, let author = remote.authorUid { meta.authorUid = author }
            return
        }
        let isPersonal = spaceId == identity.personalSpaceId

        if let deleted = remote.deleted {
            quietly {
                if deleted == "trimmed" && isPersonal {
                    // The server only keeps the newest 200; this device keeps its longer history.
                    if let meta { context.delete(meta) }
                } else {
                    deleteLocal(remote.id)
                    if let meta { context.delete(meta) }
                    commitLocal()
                }
            }
            return
        }

        guard let ciphertext = remote.ciphertext, let category = SyncCategory(rawValue: remote.category) else { return }
        let payload: SyncPayload
        do {
            let plaintext = try await Self.open(ciphertext, key: itemKey,
                                                aad: SyncCrypto.AAD.item(spaceId: spaceId, itemId: remote.id, category: category.rawValue))
            payload = try SyncPayload.decode(plaintext)
        } catch {
            Log.sync.error("Can't open item \(remote.id, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        try checkActive()
        // The writer's `rev` must match the server's `updatedAt`, and never goes back in time:
        // a server replaying an older version of an item is ignored.
        if let rev = payload.rev {
            guard rev == remote.updatedAt else {
                Log.sync.error("Item \(remote.id, privacy: .public) has rev \(rev) but updatedAt \(remote.updatedAt); ignoring it")
                return
            }
            let known = self.meta(for: remote.id)
            if let known, known.spaceId == spaceId, rev < known.updatedAt {
                Log.sync.error("Item \(remote.id, privacy: .public) went back to an older version; ignoring it")
                return
            }
        }
        // Deleted here but not yet pushed: the push sends the delete.
        if !force, let meta = self.meta(for: remote.id), !localExists(meta) { return }

        switch payload {
        case .clip(let clip):
            try await applyClip(clip, remote: remote, spaceId: spaceId, itemKey: itemKey, force: force)
        case .snippet(let snippet):
            applySnippet(snippet, remote: remote, spaceId: spaceId, force: force)
        case .secret(let secret):
            applySecret(secret, remote: remote, spaceId: spaceId, force: force)
        }
    }

    private func applyClip(_ payload: ClipPayload, remote: RemoteItem, spaceId: String, itemKey: Data, force: Bool) async throws {
        guard let uuid = UUID(uuidString: remote.id) else { return }
        let isFile = payload.kind == ClipKind.file.rawValue
        let blobIds = payload.kind == ClipKind.image.rawValue || isFile ? payload.blobIds : []
        let known = meta(for: remote.id)
        let before = store.item(withID: uuid)
        let dirty = !force && before != nil && known != nil && isChangedLocally(before!, meta: known!)
        let hasImages = before?.imageFile != nil && known?.blobIds == blobIds
        let keptFiles = before.map(\.fileURLs) ?? []
        let hasFiles = isFile && known?.blobIds == blobIds && !keptFiles.isEmpty
            && keptFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }

        var received: [ReceivedFile] = []
        if isFile && !hasFiles {
            for file in payload.fileBlobs ?? [] {
                do {
                    received.append(ReceivedFile(name: file.name, blob: file.blob,
                                                 data: try await downloadBlob(spaceId: spaceId, blobId: file.blob, itemKey: itemKey)))
                } catch let error as SyncAPIError where error.status == 404 {
                    Log.sync.notice("A file of \(remote.id, privacy: .public) is gone; skipping it")
                }
                try checkActive()
            }
        }

        var imageData: Data?
        var thumbData: Data?
        if !blobIds.isEmpty && !hasImages, let imageBlob = payload.imageBlob {
            do {
                if let ready = prefetched.removeValue(forKey: imageBlob) {
                    (imageData, thumbData) = (ready.image, ready.thumbnail)
                } else {
                    let image = try await downloadBlob(spaceId: spaceId, blobId: imageBlob, itemKey: itemKey)
                    // The thumbnail is made here rather than downloaded: half the requests.
                    (imageData, thumbData) = (image, await Self.thumbnail(of: image))
                }
                // An image this Mac can't decode: use the sender's thumbnail.
                if thumbData == nil, let thumb = payload.thumbBlob {
                    thumbData = try? await downloadBlob(spaceId: spaceId, blobId: thumb, itemKey: itemKey)
                }
            } catch let error as SyncAPIError where error.status == 404 {
                Log.sync.notice("Image of \(remote.id, privacy: .public) is gone; skipping it")
                return
            }
            try checkActive()
        }

        var written: [WrittenFile] = []
        if !received.isEmpty {
            written = await Self.writeReceivedFiles(received, to: AppPaths.syncedFilesFolder(for: uuid))
            try checkActive()
        }

        // No awaits from here on: blobs are written before the item that references them is
        // inserted, so `removeOrphanedBlobs` can never see one without the other.
        let arrived = now()
        let forThisDevice = payload.toDevice != nil && payload.toDevice == deviceId
        let existing = store.item(withID: uuid)
        let item = existing ?? ClipItem(syncID: uuid, spaceID: localSpaceID(spaceId))
        let localCopied = item.lastCopiedAt
        let localCount = item.copyCount
        let oldImage = item.imageFile
        let oldThumb = item.thumbnailFile
        payload.apply(to: item, localFiles: hasFiles ? keptFiles : written.map(\.url), arrivedAt: arrived)
        item.spaceID = localSpaceID(spaceId)
        if dirty && existing != nil {
            // Unpushed local copy activity survives; content and pin state come from the server.
            item.lastCopiedAt = max(localCopied, item.lastCopiedAt)
            item.copyCount = max(localCount, item.copyCount)
        }
        // Sent to this Mac: it goes to the top.
        if forThisDevice { item.lastCopiedAt = arrived }
        if let imageData {
            let base = UUID().uuidString
            do {
                try store.blobs.write(imageData, name: base + ".png")
                item.imageFile = base + ".png"
                if let thumbData {
                    try store.blobs.write(thumbData, name: base + "-thumb.png")
                    item.thumbnailFile = base + "-thumb.png"
                } else {
                    item.thumbnailFile = nil
                }
            } catch {
                Log.sync.error("Can't write an image blob: \(error.localizedDescription, privacy: .public)")
                if existing == nil { return }
            }
            if oldImage != item.imageFile { store.blobs.delete(oldImage) }
            if oldThumb != item.thumbnailFile { store.blobs.delete(oldThumb) }
        } else if item.kind != .image {
            store.blobs.delete(oldImage)
            store.blobs.delete(oldThumb)
            item.imageFile = nil
            item.thumbnailFile = nil
        }
        // No longer (or never) a file clip with contents: no folder may stay behind.
        if item.kind != .file { store.removeSyncedFiles(of: uuid) }
        quietly {
            if existing == nil { store.insertSynced(item) }
            store.commitSynced()
        }

        let fileBlobs = hasFiles
            ? (known?.fileBlobs ?? [:])
            : Dictionary(written.map { (Self.fileKey($0.url.path, $0.size), $0.blob) }, uniquingKeysWith: { first, _ in first })
        let fingerprint = dirty ? ((try? SyncPayload.clip(payload).fingerprint()) ?? "")
                                : clipFingerprint(item, blobIds: blobIds, fileBlobs: fileBlobs)
        // Dirty: no stamp, so the merged local activity is fingerprinted and pushed.
        recordMeta(id: remote.id, spaceId: spaceId, category: payload.category, fingerprint: fingerprint,
                   seq: remote.seq, updatedAt: remote.updatedAt, blobIds: blobIds, fileBlobs: fileBlobs,
                   localStamp: dirty ? "" : Self.stamp(item), authorUid: remote.authorUid)
        if forThisDevice { onSentToThisDevice?(uuid, payload.fromDevice) }
    }

    nonisolated struct ReceivedFile: Sendable {
        var name: String
        var blob: String
        var data: Data
    }

    nonisolated struct WrittenFile: Sendable {
        var url: URL
        var blob: String
        var size: Int
    }

    /// Saves downloaded files as `Synced Files/<item id>/<name>`, replacing an earlier version,
    /// and marks them as downloaded. Off the main actor: this is disk IO of up to 250 MB.
    @concurrent
    nonisolated static func writeReceivedFiles(_ files: [ReceivedFile], to folder: URL) async -> [WrittenFile] {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Log.sync.error("Can't create a folder for synced files: \(error.localizedDescription, privacy: .public)")
            return []
        }
        var taken = Set<String>()
        var written: [WrittenFile] = []
        for file in files {
            let url = folder.appending(path: safeFileName(file.name, taken: &taken))
            do {
                try file.data.write(to: url)
                markDownloaded(url)
                written.append(WrittenFile(url: url, blob: file.blob, size: file.data.count))
            } catch {
                Log.sync.error("Can't write a synced file: \(error.localizedDescription, privacy: .public)")
            }
        }
        return written
    }

    /// Quarantines a received file like a browser download, naming Clipboard2 as the agent, so
    /// Gatekeeper checks it before it's opened. Written as the attribute itself (flags 0x0081:
    /// quarantined, downloaded; not yet approved) because LaunchServices names the calling
    /// process instead of the agent we pass.
    nonisolated static func markDownloaded(_ url: URL) {
        let value = String(format: "0081;%08x;Clipboard2;%@", UInt32(Date.now.timeIntervalSince1970), UUID().uuidString)
        let status = value.withCString { bytes in
            setxattr(url.path, "com.apple.quarantine", bytes, strlen(bytes), 0, 0)
        }
        if status != 0 {
            Log.sync.error("Can't quarantine a synced file: errno \(errno)")
        }
    }

    /// A sender-chosen name made safe to use inside our folder: no path parts, never empty, unique.
    nonisolated static func safeFileName(_ name: String, taken: inout Set<String>) -> String {
        var base = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." || base == ".." { base = "File" }
        var candidate = base
        var n = 2
        while taken.contains(candidate.lowercased()) {
            let ext = (base as NSString).pathExtension
            let stem = (base as NSString).deletingPathExtension
            candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            n += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    private func applySnippet(_ payload: SnippetPayload, remote: RemoteItem, spaceId: String, force: Bool) {
        guard let uuid = UUID(uuidString: remote.id) else { return }
        let existing = snippets.snippet(withID: uuid)
        if !force, let existing, let known = meta(for: remote.id),
           snippetFingerprint(existing) != known.fingerprint,
           existing.updatedAt.syncMillis > remote.updatedAt {
            // Edited here after the server's version: keep ours, the push sends it.
            known.fingerprint = (try? SyncPayload.snippet(payload).fingerprint()) ?? ""
            known.remoteSeq = remote.seq
            known.updatedAt = remote.updatedAt
            return
        }
        let snippet = existing ?? Snippet(syncID: uuid, spaceID: localSpaceID(spaceId))
        payload.apply(to: snippet, arrivedAt: now())
        snippet.spaceID = localSpaceID(spaceId)
        quietly {
            if existing == nil { snippets.insertSynced(snippet) }
            snippets.commitSynced()
        }
        recordMeta(id: remote.id, spaceId: spaceId, category: .snippet, fingerprint: snippetFingerprint(snippet),
                   seq: remote.seq, updatedAt: remote.updatedAt, authorUid: remote.authorUid)
    }

    private func applySecret(_ payload: SecretPayload, remote: RemoteItem, spaceId: String, force: Bool) {
        let existing = secret(withID: remote.id)
        if !force, let existing, let known = meta(for: remote.id),
           secretFingerprint(existing) != known.fingerprint,
           (existing.updatedAt?.syncMillis ?? 0) > remote.updatedAt {
            known.fingerprint = (try? SyncPayload.secret(payload).fingerprint()) ?? ""
            known.localStamp = ""
            known.remoteSeq = remote.seq
            known.updatedAt = remote.updatedAt
            return
        }
        var received = payload
        received.createdAt = min(received.createdAt, now().syncMillis)
        quietly {
            secrets.syncUpsert(id: existing?.id ?? remote.id, name: received.name, value: received.value,
                               spaceID: localSpaceID(spaceId))
        }
        secretsChanged = true
        let ref = secret(withID: remote.id)
        recordMeta(id: remote.id, spaceId: spaceId, category: .secret, fingerprint: ref.flatMap(secretFingerprint) ?? "",
                   seq: remote.seq, updatedAt: remote.updatedAt, localStamp: ref.flatMap(Self.secretStamp) ?? "",
                   authorUid: remote.authorUid)
    }

    // MARK: Parallel image downloads

    /// Downloads, decrypts and thumbnails the images `apply` is about to need for `items`, a few at
    /// once. Best effort: anything that fails here is fetched again by `applyClip`, one at a time,
    /// with the usual error and rate-limit handling.
    private func prefetchImages(_ items: ArraySlice<RemoteItem>, spaceId: String, itemKey: Data) async {
        var wanted: [String] = []
        for remote in items {
            guard remote.deleted == nil, let ciphertext = remote.ciphertext, SyncCategory(rawValue: remote.category)?.isClip == true,
                  !isApplied(remote, spaceId: spaceId),
                  let plaintext = try? await Self.open(ciphertext, key: itemKey,
                                                       aad: SyncCrypto.AAD.item(spaceId: spaceId, itemId: remote.id, category: remote.category)),
                  case .clip(let clip) = try? SyncPayload.decode(plaintext),
                  let blob = clip.imageBlob, prefetched[blob] == nil,
                  needsImage(clip, itemId: remote.id)
            else { continue }
            wanted.append(blob)
        }
        guard !wanted.isEmpty, !isStopped else { return }
        let api = self.api
        await withTaskGroup(of: (String, Data, Data?)?.self) { group in
            var next = wanted.makeIterator()
            func add() -> Bool {
                guard let blob = next.next() else { return false }
                group.addTask {
                    guard let sealed = try? await api.downloadBlob(spaceId: spaceId, blobId: blob),
                          let image = try? await Self.open(sealed, key: itemKey, aad: SyncCrypto.AAD.blob(spaceId: spaceId, blobId: blob))
                    else { return nil }
                    return (blob, image, await Self.thumbnail(of: image))
                }
                return true
            }
            for _ in 0..<Self.parallelDownloads where add() {}
            for await result in group {
                if let (blob, image, thumbnail) = result { prefetched[blob] = (image, thumbnail) }
                _ = add()
            }
        }
    }

    /// `apply` would skip this item: this device already has the server's version.
    private func isApplied(_ remote: RemoteItem, spaceId: String) -> Bool {
        guard let meta = meta(for: remote.id) else { return false }
        return meta.spaceId == spaceId && remote.seq > 0 && meta.remoteSeq >= remote.seq
    }

    /// Mirrors `applyClip`: the image is downloaded unless this exact version is already here.
    private func needsImage(_ payload: ClipPayload, itemId: String) -> Bool {
        guard payload.kind == ClipKind.image.rawValue, let uuid = UUID(uuidString: itemId) else { return false }
        let hasImages = store.item(withID: uuid)?.imageFile != nil && meta(for: itemId)?.blobIds == payload.blobIds
        return !hasImages
    }

    @concurrent
    nonisolated static func thumbnail(of image: Data, maxPixels: Int = 480) async -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return ImageProcessor.encodePNG(thumb)
    }

    private func downloadBlob(spaceId: String, blobId: String, itemKey: Data) async throws -> Data {
        let sealed = try await api.downloadBlob(spaceId: spaceId, blobId: blobId)
        return try await Self.open(sealed, key: itemKey, aad: SyncCrypto.AAD.blob(spaceId: spaceId, blobId: blobId))
    }

    // MARK: Crypto and file reads, off the main actor

    @concurrent
    nonisolated static func open(_ sealed: Data, key: Data, aad: String) async throws -> Data {
        try SyncCrypto.open(sealed, key: key, aad: aad)
    }

    @concurrent
    nonisolated static func seal(_ plaintext: Data, key: Data, aad: String) async throws -> Data {
        try SyncCrypto.seal(plaintext, key: key, aad: aad)
    }

    /// Reads and seals a file, or nil when it can't be read.
    @concurrent
    nonisolated static func sealFile(at url: URL, key: Data, aad: String) async throws -> Data? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try SyncCrypto.seal(data, key: key, aad: aad)
    }

    // MARK: Push

    /// Everything a PUT needs, captured before any await so a local delete mid-push can't
    /// leave us holding an invalidated model object.
    private struct PushJob {
        var id: String
        var category: SyncCategory
        var sortAt: Int64
        var updatedAt: Int64
        var plaintext: Data
        var fingerprint: String
        var blobIds: [String]
        var fileBlobs: [String: String] = [:]
        /// What a refusal is remembered by (see `Rejection.key`).
        var rejectKey: String
        /// Recorded on success, so an unchanged item is skipped cheaply.
        var localStamp: String = ""
        var toDevice: String?
        /// Read from disk only when sent, so a tick with many files never holds them all in memory.
        var uploads: [(id: String, file: URL)] = []
    }

    private func push(_ space: SyncSpace, itemKey: Data) async throws {
        let spaceId = space.id
        // Deletions first: a full quota or a rate limit while uploading must never hold them back.
        try await pushDeletions(spaceId: spaceId, itemKey: itemKey)

        let localSpace = localSpaceID(spaceId)
        var metaByID: [String: SyncMeta] = [:]
        for meta in metas(inSpace: spaceId) { metaByID[meta.localId] = meta }
        let nowMs = now().syncMillis

        var jobs: [PushJob] = []
        var history = 0
        for item in store.items(inSpace: localSpace) {
            if !item.isPinned {
                // Only the newest 200 history items, so the server doesn't trim right away.
                history += 1
                if history > SyncConfig.historyLimit { continue }
            }
            if let job = clipJob(item, meta: metaByID[item.id.uuidString.lowercased()], nowMs: nowMs) { jobs.append(job) }
        }
        for snippet in snippets.snippets(inSpace: localSpace) {
            let id = snippet.id.uuidString.lowercased()
            let payload = SyncPayload.snippet(SnippetPayload(snippet: snippet))
            if let job = makeJob(id: id, payload: payload, meta: metaByID[id], sortAt: snippet.updatedAt.syncMillis,
                                 updatedAt: snippet.updatedAt.syncMillis) { jobs.append(job) }
        }
        for ref in secrets.syncSecrets where ref.spaceID == localSpace {
            let id = ref.id.lowercased()
            let meta = metaByID[id]
            let stamp = Self.secretStamp(ref)
            // Unchanged since it was last synced: don't read the Keychain to find out.
            if let meta, let stamp, !meta.localStamp.isEmpty, meta.localStamp == stamp { continue }
            guard let value = secrets.syncValue(id: ref.id) else { continue }
            let payload = SyncPayload.secret(SecretPayload(name: ref.name, value: value, createdAt: (ref.createdAt ?? .now).syncMillis))
            let updatedAt = max(ref.updatedAt?.syncMillis ?? nowMs, (meta?.updatedAt ?? 0) + 1)
            if let job = makeJob(id: id, payload: payload, meta: meta, sortAt: (ref.createdAt ?? .now).syncMillis,
                                 updatedAt: updatedAt, localStamp: stamp) { jobs.append(job) }
        }

        for job in jobs {
            try checkActive()
            try await send(job, spaceId: spaceId, itemKey: itemKey)
        }
        try checkActive()
    }

    /// Tracked items that no longer exist here were deleted by the user.
    private func pushDeletions(spaceId: String, itemKey: Data) async throws {
        let existing = localIDs(inSpace: localSpaceID(spaceId))
        var doomed: [(id: String, updatedAt: Int64)] = []
        for meta in metas(inSpace: spaceId) where !existing.contains(meta.localId) {
            if meta.detached {
                context.delete(meta)   // never on the server since the resync: nothing to delete there
            } else if !rejectedDeletes.contains(meta.localId) {
                doomed.append((meta.localId, meta.updatedAt))
            }
        }
        for (id, updatedAt) in doomed {
            try checkActive()
            do {
                let outcome = try await api.deleteItem(spaceId: spaceId, itemId: id, updatedAt: max(now().syncMillis, updatedAt + 1))
                try checkActive()
                switch outcome {
                case .saved:
                    if let meta = meta(for: id) { context.delete(meta) }
                    clockSkew = false
                    // Space was freed: items refused for quota may fit now.
                    rejected = rejected.filter { !$0.value.quota }
                case .conflict(let current):
                    try await apply(current, spaceId: spaceId, itemKey: itemKey, force: true)
                }
            } catch let error as SyncAPIError where error.code == "forbidden" {
                // Someone else's item in a group: the deletion stays on this Mac.
                Log.sync.notice("Server refused deleting \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if let meta = meta(for: id) { context.delete(meta) }
                warn(error)
            } catch let error as SyncAPIError where error.isPermanentForItem {
                Log.sync.notice("Server refused deleting \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                rejectedDeletes.insert(id)
                if error.code == "clock_skew" { clockSkew = true }
            }
            save()
        }
    }

    private func clipJob(_ item: ClipItem, meta: SyncMeta?, nowMs: Int64) -> PushJob? {
        let id = item.id.uuidString.lowercased()
        let stamp = Self.stamp(item)
        let toDevice = pendingToDevice[id]
        if toDevice == nil, let meta, !meta.localStamp.isEmpty, meta.localStamp == stamp {
            return nil   // unchanged since it was last pushed or received (or a detached straggler)
        }
        guard rejected[id]?.key != stamp else { return nil }
        let tracked = meta.flatMap { $0.detached ? nil : $0 }

        var blobIds = item.kind == .image ? (tracked?.blobIds ?? []) : []
        var fileBlobs = item.kind == .file ? (tracked.map { fileBlobMap(for: item, meta: $0) } ?? [:]) : [:]
        if let tracked, toDevice == nil, clipFingerprint(item, blobIds: blobIds, fileBlobs: fileBlobs) == tracked.fingerprint {
            // Same content after all: remember the stamp so it isn't built and hashed again.
            tracked.localStamp = stamp
            tracked.fileBlobs = fileBlobs
            return nil
        }

        var uploads: [(id: String, file: URL)] = []
        if item.kind == .image && blobIds.isEmpty {
            let fm = FileManager.default
            guard let file = item.imageFile.map(store.blobs.url(for:)), fm.fileExists(atPath: file.path) else {
                rejected[id] = Rejection(key: stamp, quota: false)   // image file missing: nothing to sync
                return nil
            }
            uploads.append((SyncCrypto.newID(), file))
            if let thumb = item.thumbnailFile.map(store.blobs.url(for:)), fm.fileExists(atPath: thumb.path) {
                uploads.append((SyncCrypto.newID(), thumb))
            }
            blobIds = uploads.map(\.id)
        } else if item.kind == .file {
            // Each file by path and size: a known one reuses its blob, a new or changed one is
            // uploaded, and one that's gone drops out (never shifting the others' blobs).
            var current: [String: String] = [:]
            for file in Self.uploadableFiles(item) {
                let key = Self.fileKey(file.url.path, file.size)
                if let blob = fileBlobs[key] {
                    current[key] = blob
                } else if current[key] == nil {
                    let blob = SyncCrypto.newID()
                    uploads.append((blob, file.url))
                    current[key] = blob
                }
            }
            fileBlobs = current
        }
        var clip = pushPayload(item, blobIds: blobIds, fileBlobs: fileBlobs)
        let fingerprint = (try? SyncPayload.clip(clip).fingerprint()) ?? ""
        if item.kind == .file { blobIds = clip.blobIds }
        if let toDevice {
            clip.toDevice = toDevice
            clip.fromDevice = deviceName
        }
        let updatedAt = max(nowMs, (meta?.updatedAt ?? 0) + 1)
        clip.rev = updatedAt
        let payload = SyncPayload.clip(clip)
        guard let plaintext = try? payload.canonicalJSON() else { return nil }
        guard plaintext.count + SyncCrypto.sealOverhead <= SyncConfig.maxItemCiphertext else {
            Log.sync.notice("Item \(id, privacy: .public) is too large to sync")
            rejected[id] = Rejection(key: stamp, quota: false)
            return nil
        }
        return PushJob(id: id, category: payload.category, sortAt: item.lastCopiedAt.syncMillis, updatedAt: updatedAt,
                       plaintext: plaintext, fingerprint: fingerprint, blobIds: blobIds, fileBlobs: fileBlobs,
                       rejectKey: stamp, localStamp: stamp, toDevice: toDevice, uploads: uploads)
    }

    private func makeJob(id: String, payload: SyncPayload, meta: SyncMeta?, sortAt: Int64, updatedAt: Int64,
                         localStamp: String? = nil) -> PushJob? {
        guard let fingerprint = try? payload.fingerprint() else { return nil }
        if let meta, fingerprint == meta.fingerprint {
            if let localStamp, meta.localStamp != localStamp { meta.localStamp = localStamp }
            return nil
        }
        guard rejected[id]?.key != fingerprint else { return nil }
        guard let plaintext = try? payload.withRev(updatedAt).canonicalJSON() else { return nil }
        guard plaintext.count + SyncCrypto.sealOverhead <= SyncConfig.maxItemCiphertext else {
            rejected[id] = Rejection(key: fingerprint, quota: false)
            return nil
        }
        return PushJob(id: id, category: payload.category, sortAt: sortAt, updatedAt: updatedAt, plaintext: plaintext,
                       fingerprint: fingerprint, blobIds: [], rejectKey: fingerprint, localStamp: localStamp ?? "")
    }

    private func send(_ job: PushJob, spaceId: String, itemKey: Data) async throws {
        do {
            for upload in job.uploads {
                guard let sealed = try await Self.sealFile(at: upload.file, key: itemKey,
                                                           aad: SyncCrypto.AAD.blob(spaceId: spaceId, blobId: upload.id)) else {
                    Log.sync.notice("\(upload.file.lastPathComponent, privacy: .private) is gone; not syncing \(job.id, privacy: .public)")
                    rejected[job.id] = Rejection(key: job.rejectKey, quota: false)
                    return
                }
                try checkActive()
                guard sealed.count <= SyncConfig.maxBlobCiphertext else {
                    rejected[job.id] = Rejection(key: job.rejectKey, quota: false)
                    return
                }
                do {
                    let ticket = try await api.registerBlob(spaceId: spaceId, blobId: upload.id, size: sealed.count)
                    try await api.uploadBlob(ticket, data: sealed)
                } catch let error as SyncAPIError where error.status == 409 {
                    // An item already references this blob id: it's uploaded.
                    Log.sync.notice("Blob \(upload.id, privacy: .public) is already on the server")
                }
                try checkActive()
            }
            let ciphertext = try await Self.seal(job.plaintext, key: itemKey,
                                                 aad: SyncCrypto.AAD.item(spaceId: spaceId, itemId: job.id, category: job.category.rawValue))
            try checkActive()
            let body = ItemUpload(category: job.category.rawValue, sortAt: job.sortAt, updatedAt: job.updatedAt,
                                  ciphertext: ciphertext, blobIds: job.blobIds)
            let outcome = try await api.putItem(spaceId: spaceId, itemId: job.id, body)
            try checkActive()
            switch outcome {
            case .saved(let seq, let trimmed):
                clockSkew = false
                if let target = job.toDevice, pendingToDevice[job.id] == target { pendingToDevice[job.id] = nil }
                recordMeta(id: job.id, spaceId: spaceId, category: job.category, fingerprint: job.fingerprint,
                           seq: seq, updatedAt: job.updatedAt, blobIds: job.blobIds, fileBlobs: job.fileBlobs,
                           localStamp: job.localStamp, authorUid: identity.uid)
                for id in trimmed { handleTrimmed(id, spaceId: spaceId) }
            case .conflict(let current):
                try await apply(current, spaceId: spaceId, itemKey: itemKey, force: true)
            }
            save()
        } catch let error as SyncAPIError where error.isPermanentForItem {
            // Kept locally, retried once it changes (quota: also after a deletion or relaunch).
            Log.sync.notice("Server refused \(job.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let quota = error.code == "quota_exceeded"
            rejected[job.id] = Rejection(key: job.rejectKey, quota: quota, message: quota ? error.errorDescription : nil)
            switch error.code {
            case "clock_skew": clockSkew = true
            case "forbidden": warn(error)
            default: break
            }
        }
    }

    private func warn(_ error: SyncAPIError) {
        guard let message = error.errorDescription, !warnings.contains(message) else { return }
        warnings.append(message)
    }

    /// Files of a file clip whose contents sync: regular files that fit in one blob, at most 10.
    static func uploadableFiles(_ item: ClipItem) -> [(url: URL, size: Int)] {
        let limit = SyncConfig.maxBlobCiphertext - SyncCrypto.sealOverhead
        var files: [(url: URL, size: Int)] = []
        for url in item.fileURLs where url.isFileURL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= limit
            else { continue }
            files.append((url, size))
            if files.count == SyncConfig.maxFilesPerItem { break }
        }
        return files
    }

    /// The key of a file in `SyncMeta.fileBlobs`.
    nonisolated static func fileKey(_ path: String, _ size: Int) -> String { "\(path)|\(size)" }

    /// The file → blob map of a tracked file clip. Clips synced before the map existed listed
    /// their blobs in the order of the files on disk; that order is trusted only while the
    /// payload is exactly what was sent (names, sizes and paths are all in its fingerprint).
    private func fileBlobMap(for item: ClipItem, meta: SyncMeta) -> [String: String] {
        guard meta.fileBlobs.isEmpty, !meta.blobIds.isEmpty else { return meta.fileBlobs }
        let positional = Dictionary(zip(Self.uploadableFiles(item), meta.blobIds).map { (Self.fileKey($0.url.path, $0.size), $1) },
                                    uniquingKeysWith: { first, _ in first })
        return clipFingerprint(item, blobIds: [], fileBlobs: positional) == meta.fingerprint ? positional : [:]
    }

    private func handleTrimmed(_ id: String, spaceId: String) {
        quietly {
            if spaceId != identity.personalSpaceId { deleteLocal(id) }
            if let meta = meta(for: id) { context.delete(meta) }
            commitLocal()
        }
    }

    // MARK: Fingerprints

    /// The clip payload as pushed: images by `blobIds` (image, thumbnail), files by the map;
    /// rich text is dropped when it would exceed the item limit.
    func pushPayload(_ item: ClipItem, blobIds: [String], fileBlobs: [String: String] = [:]) -> ClipPayload {
        let payload: ClipPayload
        if item.kind == .file {
            let files = Self.uploadableFiles(item).compactMap { file -> FileBlob? in
                guard let blob = fileBlobs[Self.fileKey(file.url.path, file.size)] else { return nil }
                return FileBlob(name: file.url.lastPathComponent, blob: blob, size: file.size)
            }
            payload = ClipPayload(item: item, fileBlobs: files)
        } else {
            payload = ClipPayload(item: item, imageBlob: blobIds.first, thumbBlob: blobIds.dropFirst().first)
        }
        guard payload.rtf != nil || payload.html != nil,
              let size = try? SyncPayload.clip(payload).canonicalJSON().count,
              size + SyncCrypto.sealOverhead > SyncConfig.maxItemCiphertext
        else { return payload }
        return payload.withoutRichText
    }

    func clipFingerprint(_ item: ClipItem, blobIds: [String], fileBlobs: [String: String] = [:]) -> String {
        (try? SyncPayload.clip(pushPayload(item, blobIds: blobIds, fileBlobs: fileBlobs)).fingerprint()) ?? ""
    }

    /// Whether a tracked item changed here since it was last pushed or received.
    private func isChangedLocally(_ item: ClipItem, meta: SyncMeta) -> Bool {
        if !meta.localStamp.isEmpty { return Self.stamp(item) != meta.localStamp }
        let blobIds = item.kind == .image ? meta.blobIds : []
        let files = item.kind == .file ? fileBlobMap(for: item, meta: meta) : [:]
        return clipFingerprint(item, blobIds: blobIds, fileBlobs: files) != meta.fingerprint
    }

    /// A digest of every field the payload is built from, without loading rich text or reading
    /// files: cheap enough to check each item on every tick.
    static func stamp(_ item: ClipItem) -> String {
        let fields: [String] = [
            item.kindRaw, item.contentHash, item.preview, item.fileURLStrings.joined(separator: "\n"),
            item.imageFile ?? "", item.thumbnailFile ?? "", "\(item.imageWidth)x\(item.imageHeight)", "\(item.byteCount)",
            item.sourceBundleID ?? "", item.sourceAppName ?? "", item.isPinned ? "pinned" : "",
            "\(item.pinnedAt?.syncMillis ?? 0)", item.label ?? "", "\(item.copyCount)",
            "\(item.createdAt.syncMillis)", "\(item.lastCopiedAt.syncMillis)", item.spaceID ?? "",
        ]
        return SyncCrypto.sha256Hex(Data(fields.joined(separator: "\u{1F}").utf8))
    }

    /// For secrets with an `updatedAt`: changes whenever the name or value does.
    private static func secretStamp(_ ref: SecretRef) -> String? {
        guard let updated = ref.updatedAt else { return nil }
        let fields = [ref.name, "\(updated.syncMillis)", "\(ref.createdAt?.syncMillis ?? 0)", ref.spaceID ?? ""]
        return SyncCrypto.sha256Hex(Data(fields.joined(separator: "\u{1F}").utf8))
    }

    private func snippetFingerprint(_ snippet: Snippet) -> String {
        (try? SyncPayload.snippet(SnippetPayload(snippet: snippet)).fingerprint()) ?? ""
    }

    private func secretFingerprint(_ ref: SecretRef) -> String? {
        guard let value = secrets.syncValue(id: ref.id) else { return nil }
        return try? SyncPayload.secret(SecretPayload(name: ref.name, value: value, createdAt: (ref.createdAt ?? .now).syncMillis)).fingerprint()
    }

    // MARK: Local state

    private func secret(withID id: String) -> SecretRef? {
        secrets.syncSecrets.first { $0.id.lowercased() == id.lowercased() }
    }

    private func localExists(_ meta: SyncMeta) -> Bool {
        let space = localSpaceID(meta.spaceId)
        switch SyncCategory(rawValue: meta.category) {
        case .history, .pinned:
            guard let uuid = UUID(uuidString: meta.localId), let item = store.item(withID: uuid) else { return false }
            return item.spaceID == space
        case .snippet:
            guard let uuid = UUID(uuidString: meta.localId) else { return false }
            return snippets.snippet(withID: uuid) != nil
        case .secret:
            return secret(withID: meta.localId) != nil
        case nil:
            return false
        }
    }

    /// Ids of everything that could be tracked in a space: its clips, and every snippet and
    /// secret (as `localExists`, in one fetch each instead of one per item).
    private func localIDs(inSpace space: String?) -> Set<String> {
        var ids = Set(store.items(inSpace: space).map { $0.id.uuidString.lowercased() })
        let allSnippets = (try? context.fetch(FetchDescriptor<Snippet>())) ?? []
        ids.formUnion(allSnippets.map { $0.id.uuidString.lowercased() })
        ids.formUnion(secrets.syncSecrets.map { $0.id.lowercased() })
        return ids
    }

    /// Deletes the local clip, snippet or secret with this id (without committing).
    private func deleteLocal(_ id: String) {
        if let uuid = UUID(uuidString: id) {
            if let item = store.item(withID: uuid) { store.removeSynced(item) }
            if let snippet = snippets.snippet(withID: uuid) { snippets.removeSynced(snippet) }
        }
        if let ref = secret(withID: id) {
            secrets.syncDelete(id: ref.id)
            secretsChanged = true
        }
    }

    private func commitLocal() {
        store.commitSynced()
        snippets.commitSynced()
    }

    private func flushSecrets() {
        guard secretsChanged else { return }
        secretsChanged = false
        secrets.syncDidChange()
    }

    private func recordMeta(id: String, spaceId: String, category: SyncCategory, fingerprint: String,
                            seq: Int64, updatedAt: Int64, blobIds: [String] = [], fileBlobs: [String: String] = [:],
                            localStamp: String = "", authorUid: String?) {
        let meta = self.meta(for: id) ?? {
            let meta = SyncMeta(localId: id, spaceId: spaceId, category: category.rawValue)
            context.insert(meta)
            return meta
        }()
        meta.spaceId = spaceId
        meta.category = category.rawValue
        meta.fingerprint = fingerprint
        meta.remoteSeq = max(meta.remoteSeq, seq)
        meta.updatedAt = updatedAt
        meta.blobIds = blobIds
        meta.fileBlobs = fileBlobs
        meta.localStamp = localStamp
        meta.detached = false
        if let authorUid { meta.authorUid = authorUid }
    }

    func meta(for id: String) -> SyncMeta? {
        var descriptor = FetchDescriptor<SyncMeta>(predicate: #Predicate { $0.localId == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func metas(inSpace spaceId: String) -> [SyncMeta] {
        (try? context.fetch(FetchDescriptor<SyncMeta>(predicate: #Predicate { $0.spaceId == spaceId }))) ?? []
    }

    func allSpaces() -> [SyncSpace] {
        (try? context.fetch(FetchDescriptor<SyncSpace>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Log.sync.error("Sync state save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Sign-out

    /// Deletes group data, sync metadata and cursors. Personal history stays.
    static func wipeLocalState(context: ModelContext, store: ClipStore, snippets: SnippetStore,
                               secrets: any SyncSecretSource) {
        let spaces = (try? context.fetch(FetchDescriptor<SyncSpace>())) ?? []
        var groupIDs = Set(spaces.filter { !$0.isPersonal }.map(\.id))
        groupIDs.formUnion(store.allItems().compactMap(\.spaceID))
        groupIDs.formUnion(((try? context.fetch(FetchDescriptor<Snippet>())) ?? []).compactMap(\.spaceID))
        for id in groupIDs {
            store.removeAll(inSpace: id)
            snippets.removeAll(inSpace: id)
        }
        var removedSecret = false
        for ref in secrets.syncSecrets where ref.spaceID != nil {
            secrets.syncDelete(id: ref.id)
            removedSecret = true
        }
        if removedSecret { secrets.syncDidChange() }
        // One by one: a batch delete resets the context under objects other code still holds.
        for meta in (try? context.fetch(FetchDescriptor<SyncMeta>())) ?? [] { context.delete(meta) }
        for space in spaces { context.delete(space) }
        try? context.save()
    }
}
