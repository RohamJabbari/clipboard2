import Foundation
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
/// keys, then for each space pull, converge duplicates, and push.
@MainActor
final class SyncEngine {
    let api: any SyncService
    let identity: SyncIdentity
    let context: ModelContext
    let store: ClipStore
    let snippets: SnippetStore
    let secrets: any SyncSecretSource
    var now: () -> Date = { .now }

    private var spaceKeys: [String: Data] = [:]
    /// Items the server refused for good (too large, over quota), id → fingerprint, so they're
    /// retried only after they change.
    private var rejected: [String: String] = [:]
    private var secretsChanged = false
    /// Set on sign-out: a tick still in flight stops at its next await instead of touching
    /// models that were just deleted.
    private(set) var isStopped = false

    func stop() { isStopped = true }

    private func checkActive() throws {
        if isStopped { throw CancellationError() }
    }

    init(api: any SyncService, identity: SyncIdentity, context: ModelContext, store: ClipStore,
         snippets: SnippetStore, secrets: any SyncSecretSource) {
        self.api = api
        self.identity = identity
        self.context = context
        self.store = store
        self.snippets = snippets
        self.secrets = secrets
    }

    // MARK: Keys

    func spaceKey(for spaceId: String) -> Data? { spaceKeys[spaceId] }

    /// Remembers a key this device created (a new group), so it needn't be unwrapped again.
    func adoptSpaceKey(_ key: Data, for spaceId: String) { spaceKeys[spaceId] = key }

    /// Local `spaceID` for a server space: nil for the personal space.
    func localSpaceID(_ spaceId: String) -> String? {
        spaceId == identity.personalSpaceId ? nil : spaceId
    }

    private func serverSpaceID(_ localSpaceID: String?) -> String {
        localSpaceID ?? identity.personalSpaceId
    }

    // MARK: Tick

    func tick() async throws {
        try checkActive()
        let remote = try await api.spaces()
        try checkActive()
        // Groups first, and every download before any upload: a long first upload (or a rate limit
        // while sending it) must never keep new group items from arriving.
        let spaces = updateSpaces(remote).sorted { $0.kind != "personal" && $1.kind == "personal" }
        defer { save() }
        for space in spaces {
            try await inSpace(space) { try await self.pull(space, itemKey: $0) }
        }
        for space in spaces {
            try await inSpace(space) { try await self.push(space, itemKey: $0) }
        }
    }

    private func inSpace(_ space: SyncSpace, _ work: (Data) async throws -> Void) async throws {
        try checkActive()
        let spaceId = space.id
        guard let key = spaceKeys[spaceId] else { return }
        do {
            try await work(SyncCrypto.itemKey(spaceKey: key))
            if store.convergeDuplicates(inSpace: localSpaceID(spaceId)) > 0 {
                Log.sync.info("Merged duplicates in a space")
            }
        } catch let error as SyncAPIError where error.status == 404 || error.code == "forbidden" {
            // Removed from the group mid-tick; the next space list drops it.
            try checkActive()
            Log.sync.notice("Space \(spaceId, privacy: .public) is gone: \(error.localizedDescription, privacy: .public)")
        }
        flushSecrets()
    }

    /// Stop tracking items retention removed locally (they stay on the server and other devices).
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
            if spaceKeys[space.id] == nil {
                do {
                    spaceKeys[space.id] = try SyncCrypto.unwrapSpaceKey(space.wrappedKey, spaceId: space.id,
                                                                       uid: identity.uid, privateKey: identity.privateKey)
                } catch {
                    Log.sync.error("Can't unwrap the key of space \(space.id, privacy: .public)")
                    continue
                }
            }
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
            if space.isPersonal {
                row.name = "Personal"
            } else if let sealed = space.encryptedName, let key = spaceKeys[space.id] {
                row.name = (try? SyncCrypto.decryptGroupName(sealed, spaceKey: key, spaceId: space.id)) ?? "Group"
            } else if row.name.isEmpty {
                row.name = "Group"
            }
            result.append(row)
        }
        for gone in rows.values { removeSpaceLocally(gone) }
        save()
        return result.sorted { $0.isPersonal && !$1.isPersonal }
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
        context.delete(space)
    }

    // MARK: Pull

    private func pull(_ space: SyncSpace, itemKey: Data) async throws {
        let spaceId = space.id
        var seen: Set<String>?
        while true {
            let since = space.since
            let page = try await api.changes(spaceId: spaceId, since: since, limit: SyncConfig.changesPageSize)
            try checkActive()
            if page.resetRequired {
                guard since > 0 else { break }
                Log.sync.notice("Full resync of space \(spaceId, privacy: .public)")
                space.since = 0
                seen = []
                continue
            }
            for item in page.items {
                seen?.insert(item.id)
                try await apply(item, spaceId: spaceId, itemKey: itemKey, force: false)
                try checkActive()
            }
            space.since = max(since, page.nextSince)
            save()
            if !page.hasMore || page.items.isEmpty { break }
        }
        if let seen {
            // Tombstones older than the purge horizon are gone: whatever we track but the full
            // state lacks was deleted (history may just have been trimmed, so only stop tracking it).
            for meta in metas(inSpace: spaceId) where !seen.contains(meta.localId) {
                if meta.category != SyncCategory.history.rawValue { deleteLocal(meta.localId) }
                context.delete(meta)
            }
            commitLocal()
        }
    }

    /// Applies one server item: a newer upsert, a `user` tombstone or a `trimmed` one. `force`
    /// (after a 409) applies it even over unpushed local changes.
    private func apply(_ remote: RemoteItem, spaceId: String, itemKey: Data, force: Bool) async throws {
        let meta = self.meta(for: remote.id)
        if !force, let meta, meta.spaceId == spaceId, remote.seq > 0, meta.remoteSeq >= remote.seq { return }
        let isPersonal = spaceId == identity.personalSpaceId

        if let deleted = remote.deleted {
            if deleted == "trimmed" && isPersonal {
                // The server only keeps the newest 200; this device keeps its longer history.
                if let meta { context.delete(meta) }
            } else {
                deleteLocal(remote.id)
                if let meta { context.delete(meta) }
                commitLocal()
            }
            return
        }

        guard let ciphertext = remote.ciphertext, let category = SyncCategory(rawValue: remote.category) else { return }
        let payload: SyncPayload
        do {
            let plaintext = try SyncCrypto.open(ciphertext, key: itemKey,
                                                aad: SyncCrypto.AAD.item(spaceId: spaceId, itemId: remote.id, category: category.rawValue))
            payload = try SyncPayload.decode(plaintext)
        } catch {
            Log.sync.error("Can't open item \(remote.id, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        // Deleted here but not yet pushed: the push sends the delete.
        if !force, let meta, !localExists(meta) { return }

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
        let blobIds = payload.kind == ClipKind.image.rawValue ? payload.blobIds : []
        let known = meta(for: remote.id)
        let before = store.item(withID: uuid)
        let dirty = !force && before != nil && known != nil
            && clipFingerprint(before!, blobIds: known!.blobIds) != known!.fingerprint
        let hasImages = before?.imageFile != nil && known?.blobIds == blobIds

        var imageData: Data?
        var thumbData: Data?
        if !blobIds.isEmpty && !hasImages, let imageBlob = payload.imageBlob {
            do {
                imageData = try await downloadBlob(spaceId: spaceId, blobId: imageBlob, itemKey: itemKey)
                if let thumb = payload.thumbBlob {
                    thumbData = try? await downloadBlob(spaceId: spaceId, blobId: thumb, itemKey: itemKey)
                }
            } catch let error as SyncAPIError where error.status == 404 {
                Log.sync.notice("Image of \(remote.id, privacy: .public) is gone; skipping it")
                return
            }
            try checkActive()
        }

        // No awaits from here on: blobs are written before the item that references them is
        // inserted, so `removeOrphanedBlobs` can never see one without the other.
        let existing = store.item(withID: uuid)
        let item = existing ?? ClipItem(syncID: uuid, spaceID: localSpaceID(spaceId))
        let localCopied = item.lastCopiedAt
        let localCount = item.copyCount
        let oldImage = item.imageFile
        let oldThumb = item.thumbnailFile
        payload.apply(to: item)
        item.spaceID = localSpaceID(spaceId)
        if dirty && existing != nil {
            // Unpushed local copy activity survives; content and pin state come from the server.
            item.lastCopiedAt = max(localCopied, item.lastCopiedAt)
            item.copyCount = max(localCount, item.copyCount)
        }
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
        if existing == nil { store.insertSynced(item) }
        store.commitSynced()

        let fingerprint = dirty ? ((try? SyncPayload.clip(payload).fingerprint()) ?? "")
                                : clipFingerprint(item, blobIds: blobIds)
        recordMeta(id: remote.id, spaceId: spaceId, category: payload.category, fingerprint: fingerprint,
                   seq: remote.seq, updatedAt: remote.updatedAt, blobIds: blobIds)
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
        payload.apply(to: snippet)
        snippet.spaceID = localSpaceID(spaceId)
        if existing == nil { snippets.insertSynced(snippet) }
        snippets.commitSynced()
        recordMeta(id: remote.id, spaceId: spaceId, category: .snippet, fingerprint: snippetFingerprint(snippet),
                   seq: remote.seq, updatedAt: remote.updatedAt, blobIds: [])
    }

    private func applySecret(_ payload: SecretPayload, remote: RemoteItem, spaceId: String, force: Bool) {
        let existing = secret(withID: remote.id)
        if !force, let existing, let known = meta(for: remote.id),
           secretFingerprint(existing) != known.fingerprint,
           (existing.updatedAt?.syncMillis ?? 0) > remote.updatedAt {
            known.fingerprint = (try? SyncPayload.secret(payload).fingerprint()) ?? ""
            known.remoteSeq = remote.seq
            known.updatedAt = remote.updatedAt
            return
        }
        secrets.syncUpsert(id: existing?.id ?? remote.id, name: payload.name, value: payload.value,
                           spaceID: localSpaceID(spaceId))
        secretsChanged = true
        let fingerprint = secret(withID: remote.id).flatMap(secretFingerprint) ?? ""
        recordMeta(id: remote.id, spaceId: spaceId, category: .secret, fingerprint: fingerprint,
                   seq: remote.seq, updatedAt: remote.updatedAt, blobIds: [])
    }

    private func downloadBlob(spaceId: String, blobId: String, itemKey: Data) async throws -> Data {
        let sealed = try await api.downloadBlob(spaceId: spaceId, blobId: blobId)
        return try SyncCrypto.open(sealed, key: itemKey, aad: SyncCrypto.AAD.blob(spaceId: spaceId, blobId: blobId))
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
        var uploads: [(id: String, data: Data)]
    }

    private func push(_ space: SyncSpace, itemKey: Data) async throws {
        let spaceId = space.id
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
            guard let value = secrets.syncValue(id: ref.id) else { continue }
            let id = ref.id.lowercased()
            let payload = SyncPayload.secret(SecretPayload(name: ref.name, value: value, createdAt: (ref.createdAt ?? .now).syncMillis))
            let meta = metaByID[id]
            let updatedAt = max(ref.updatedAt?.syncMillis ?? nowMs, (meta?.updatedAt ?? 0) + 1)
            if let job = makeJob(id: id, payload: payload, meta: meta, sortAt: (ref.createdAt ?? .now).syncMillis,
                                 updatedAt: updatedAt) { jobs.append(job) }
        }

        for job in jobs {
            try checkActive()
            try await send(job, spaceId: spaceId, itemKey: itemKey)
        }
        try checkActive()

        // Tracked items that no longer exist here were deleted by the user.
        let deletions = metas(inSpace: spaceId).filter { !localExists($0) }.map { ($0.localId, $0.updatedAt) }
        for (id, updatedAt) in deletions {
            let outcome = try await api.deleteItem(spaceId: spaceId, itemId: id, updatedAt: max(now().syncMillis, updatedAt + 1))
            try checkActive()
            switch outcome {
            case .saved:
                if let meta = meta(for: id) { context.delete(meta) }
            case .conflict(let current):
                try await apply(current, spaceId: spaceId, itemKey: itemKey, force: true)
            }
            save()
        }
    }

    private func clipJob(_ item: ClipItem, meta: SyncMeta?, nowMs: Int64) -> PushJob? {
        let id = item.id.uuidString.lowercased()
        var blobIds = item.kind == .image ? (meta?.blobIds ?? []) : []
        var fingerprint = clipFingerprint(item, blobIds: blobIds)
        guard fingerprint != meta?.fingerprint, rejected[id] != fingerprint else { return nil }

        var uploads: [(id: String, data: Data)] = []
        if item.kind == .image && blobIds.isEmpty {
            guard let file = item.imageFile, let data = try? Data(contentsOf: store.blobs.url(for: file)) else {
                return nil   // image file missing: nothing to sync
            }
            uploads.append((SyncCrypto.newID(), data))
            if let thumb = item.thumbnailFile, let data = try? Data(contentsOf: store.blobs.url(for: thumb)) {
                uploads.append((SyncCrypto.newID(), data))
            }
            blobIds = uploads.map(\.id)
            fingerprint = clipFingerprint(item, blobIds: blobIds)
        }
        let payload = SyncPayload.clip(pushPayload(item, blobIds: blobIds))
        guard let plaintext = try? payload.canonicalJSON() else { return nil }
        guard plaintext.count + 29 <= SyncConfig.maxItemCiphertext else {
            Log.sync.notice("Item \(id, privacy: .public) is too large to sync")
            rejected[id] = clipFingerprint(item, blobIds: meta?.blobIds ?? [])
            return nil
        }
        let updatedAt = max(nowMs, (meta?.updatedAt ?? 0) + 1)
        return PushJob(id: id, category: payload.category, sortAt: item.lastCopiedAt.syncMillis, updatedAt: updatedAt,
                       plaintext: plaintext, fingerprint: fingerprint, blobIds: blobIds, uploads: uploads)
    }

    private func makeJob(id: String, payload: SyncPayload, meta: SyncMeta?, sortAt: Int64, updatedAt: Int64) -> PushJob? {
        guard let plaintext = try? payload.canonicalJSON() else { return nil }
        let fingerprint = SyncCrypto.sha256Hex(plaintext)
        guard fingerprint != meta?.fingerprint, rejected[id] != fingerprint else { return nil }
        guard plaintext.count + 29 <= SyncConfig.maxItemCiphertext else {
            rejected[id] = fingerprint
            return nil
        }
        return PushJob(id: id, category: payload.category, sortAt: sortAt, updatedAt: updatedAt, plaintext: plaintext,
                       fingerprint: fingerprint, blobIds: [], uploads: [])
    }

    private func send(_ job: PushJob, spaceId: String, itemKey: Data) async throws {
        do {
            for upload in job.uploads {
                let sealed = try SyncCrypto.seal(upload.data, key: itemKey,
                                                 aad: SyncCrypto.AAD.blob(spaceId: spaceId, blobId: upload.id))
                guard sealed.count <= SyncConfig.maxBlobCiphertext else {
                    rejected[job.id] = job.fingerprint
                    return
                }
                let ticket = try await api.registerBlob(spaceId: spaceId, blobId: upload.id, size: sealed.count)
                try await api.uploadBlob(ticket, data: sealed)
                try checkActive()
            }
            let ciphertext = try SyncCrypto.seal(job.plaintext, key: itemKey,
                                                 aad: SyncCrypto.AAD.item(spaceId: spaceId, itemId: job.id, category: job.category.rawValue))
            let body = ItemUpload(category: job.category.rawValue, sortAt: job.sortAt, updatedAt: job.updatedAt,
                                  ciphertext: ciphertext, blobIds: job.blobIds)
            let outcome = try await api.putItem(spaceId: spaceId, itemId: job.id, body)
            try checkActive()
            switch outcome {
            case .saved(let seq, let trimmed):
                recordMeta(id: job.id, spaceId: spaceId, category: job.category, fingerprint: job.fingerprint,
                           seq: seq, updatedAt: job.updatedAt, blobIds: job.blobIds)
                for id in trimmed { handleTrimmed(id, spaceId: spaceId) }
            case .conflict(let current):
                try await apply(current, spaceId: spaceId, itemKey: itemKey, force: true)
            }
            save()
        } catch let error as SyncAPIError where error.isPermanentForItem {
            Log.sync.notice("Server refused \(job.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            rejected[job.id] = job.fingerprint
        }
    }

    private func handleTrimmed(_ id: String, spaceId: String) {
        if spaceId != identity.personalSpaceId { deleteLocal(id) }
        if let meta = meta(for: id) { context.delete(meta) }
        commitLocal()
    }

    // MARK: Fingerprints

    /// The clip payload as pushed: rich text is dropped when it would exceed the item limit.
    func pushPayload(_ item: ClipItem, blobIds: [String]) -> ClipPayload {
        let payload = ClipPayload(item: item, imageBlob: blobIds.first, thumbBlob: blobIds.dropFirst().first)
        guard payload.rtf != nil || payload.html != nil,
              let size = try? SyncPayload.clip(payload).canonicalJSON().count,
              size + 29 > SyncConfig.maxItemCiphertext
        else { return payload }
        return payload.withoutRichText
    }

    func clipFingerprint(_ item: ClipItem, blobIds: [String]) -> String {
        (try? SyncPayload.clip(pushPayload(item, blobIds: blobIds)).fingerprint()) ?? ""
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
                            seq: Int64, updatedAt: Int64, blobIds: [String]) {
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
