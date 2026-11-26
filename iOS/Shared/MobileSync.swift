import Foundation

/// The iOS sync client (PROTOCOL.md → Client sync rules), on the shared `SyncAPI`, `SyncCrypto`
/// and payloads. Smaller than the Mac engine on purpose: it pulls the personal and authenticator
/// spaces and shared codes, and pushes clips made or changed on this device. Groups, contacts,
/// snippets and editing secrets are Mac and Windows only for now (docs/features/ios.md → Next).
final class MobileSync {
    let store: MobileStore
    let vault: MobileVault?
    private(set) var session: MobileSession
    private let makeAPI: (String) -> any SyncService
    private let saveSession: (MobileSession) -> Void
    /// Space keys unwrapped this run, by space id.
    private var spaceKeys: [String: Data] = [:]
    var onSessionChange: ((MobileSession) -> Void)?

    static let thumbnailsPerSync = 60

    init(session: MobileSession, store: MobileStore, vault: MobileVault?,
         makeAPI: @escaping (String) -> any SyncService = MobileSync.liveAPI,
         saveSession: @escaping (MobileSession) -> Void = SessionKeychain.save) {
        self.session = session
        self.saveSession = saveSession
        self.store = store
        self.vault = vault
        self.makeAPI = makeAPI
    }

    nonisolated static func liveAPI(token: String) -> any SyncService {
        SyncAPI(base: SyncConfig.apiBase, transport: URLSessionTransport(), token: { token })
    }

    private var api: any SyncService { makeAPI(session.token) }

    // MARK: Runs

    /// Pull, then push. The app's "Sync now", launch and foreground.
    func sync() async throws {
        do {
            let spaces = try await api.spaces()
            let wanted = spaces.filter { $0.isPersonal || $0.kind == "authenticator" }
            for space in wanted {
                let key = try spaceKey(for: space)
                try await pull(spaceId: space.id, itemKey: SyncCrypto.itemKey(spaceKey: key))
            }
            removeGoneAuthenticators(keeping: Set(wanted.map(\.id)))
            try await pullSharedCodes()
            try await push()
            await fetchThumbnails()
            store.update { $0.lastSync = .now }
        } catch let error as SyncAPIError where error.code == "unauthenticated" {
            expire()
            throw error
        }
    }

    /// Only this device's changes to the personal space: the share extension.
    func pushPersonal() async throws {
        do {
            if spaceKeys[session.personalSpaceId] == nil {
                let spaces = try await api.spaces()
                guard let personal = spaces.first(where: { $0.id == session.personalSpaceId }) else { return }
                _ = try spaceKey(for: personal)
            }
            try await push()
        } catch let error as SyncAPIError where error.code == "unauthenticated" {
            expire()
            throw error
        }
    }

    private func expire() {
        session.expired = true
        saveSession(session)
        onSessionChange?(session)
    }

    // MARK: Keys

    /// Unwraps a space key and pins it: the same space must always come with the same key.
    func spaceKey(for space: RemoteSpace) throws -> Data {
        if let key = spaceKeys[space.id] { return key }
        let key = try SyncCrypto.unwrapSpaceKey(space.wrappedKey, spaceId: space.id, uid: session.uid,
                                                privateKey: session.privateKey)
        let pin = SyncCrypto.sha256Hex(key)
        if let known = session.spaceKeyPins[space.id] {
            guard known == pin else {
                Log.sync.error("Space \(space.id, privacy: .public) came with a different key; ignoring it")
                throw SyncCryptoError.badKey
            }
        } else {
            session.spaceKeyPins[space.id] = pin
            saveSession(session)
            onSessionChange?(session)
        }
        spaceKeys[space.id] = key
        return key
    }

    private func itemKey(_ spaceId: String) -> Data? {
        spaceKeys[spaceId].map { SyncCrypto.itemKey(spaceKey: $0) }
    }

    // MARK: Pull

    private func pull(spaceId: String, itemKey: Data) async throws {
        var since = store.state.cursors[spaceId] ?? 0
        var full = false
        while true {
            let page = try await api.changes(spaceId: spaceId, since: since, limit: SyncConfig.changesPageSize, full: full)
            if page.resetRequired {
                // Past the purge horizon: walk the space from the start again.
                since = 0
                full = true
                continue
            }
            for item in page.items { apply(item, spaceId: spaceId, itemKey: itemKey) }
            since = max(since, page.nextSince)
            let cursor = since
            store.update { $0.cursors[spaceId] = cursor }
            if !page.hasMore { break }
        }
    }

    /// One remote item into the store or the vault: newer upserts replace, `user` tombstones
    /// delete, `trimmed` ones stop tracking a personal history item.
    func apply(_ remote: RemoteItem, spaceId: String, itemKey: Data, now: Date = .now) {
        let isPersonal = spaceId == session.personalSpaceId
        if let deleted = remote.deleted {
            store.update { state in
                if deleted == "trimmed", isPersonal, let index = state.clips.firstIndex(where: { $0.id == remote.id }) {
                    state.clips[index].trimmed = true
                    state.clips[index].fingerprint = nil
                } else {
                    state.remove(remote.id)
                }
            }
            vault?.update { vault in
                vault.secrets.removeAll { $0.id == remote.id }
                vault.otps.removeAll { $0.id == remote.id }
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
        // The writer's `rev` must match the server's `updatedAt` (rollback protection).
        if let rev = payload.rev, rev != remote.updatedAt { return }
        let fingerprint = try? payload.fingerprint()
        let arrived = now.syncMillis

        switch payload {
        case .clip(var clip):
            clip.createdAt = min(clip.createdAt, arrived)
            clip.lastCopiedAt = min(clip.lastCopiedAt, arrived)
            store.update { state in
                // Last write wins: a newer local version (pushed or not) stays.
                if let local = state.clip(remote.id), local.updatedAt > remote.updatedAt { return }
                let previous = state.clip(remote.id)
                state.upsert(MobileClip(id: remote.id, spaceId: spaceId, payload: clip, updatedAt: remote.updatedAt,
                                        fingerprint: fingerprint, needsPush: false, authorUid: remote.authorUid,
                                        localImage: previous?.localImage, localThumb: previous?.localThumb))
            }
        case .folder(let folder):
            store.update { state in
                if let local = state.folders.first(where: { $0.id == remote.id }), local.updatedAt > remote.updatedAt { return }
                state.upsert(MobileFolder(id: remote.id, spaceId: spaceId, payload: folder, updatedAt: remote.updatedAt))
            }
        case .secret(let secret):
            vault?.update { vault in
                vault.secrets.removeAll { $0.id == remote.id }
                vault.secrets.append(MobileSecret(id: remote.id, spaceId: spaceId, payload: secret))
            }
        case .otp(let otp):
            vault?.update { vault in
                vault.otps.removeAll { $0.id == remote.id }
                vault.otps.append(MobileOTP(id: remote.id, spaceId: spaceId, payload: otp))
            }
        case .snippet:
            break   // Snippets expand as you type on the Mac; nothing to show on iOS yet.
        case .origin:
            break   // Sites edited by hand (Mac 1.13); iOS still groups Auth by website.
        }
    }

    /// Authenticator spaces that are gone (deleted, transferred) take their seed with them.
    private func removeGoneAuthenticators(keeping spaces: Set<String>) {
        vault?.update { vault in vault.otps.removeAll { !spaces.contains($0.spaceId) } }
    }

    private func pullSharedCodes() async throws {
        guard let vault else { return }
        let entries = try await api.sharedCodes()
        var shared: [MobileSharedCodes] = []
        for entry in entries {
            guard let sealed = entry.sealedCodes, !sealed.isEmpty,
                  let json = try? SyncCrypto.openCodes(sealed, spaceId: entry.spaceId, uid: session.uid,
                                                       privateKey: session.privateKey),
                  let batch = try? JSONDecoder().decode(CodeBatch.self, from: json)
            else { continue }
            shared.append(MobileSharedCodes(spaceId: entry.spaceId, ownerName: entry.ownerName, batch: batch))
        }
        vault.update { $0.shared = shared }
    }

    // MARK: Push

    private func push() async throws {
        for delete in store.state.deletes {
            guard itemKey(delete.spaceId) != nil else { continue }
            let updatedAt = max(Date.now.syncMillis, delete.at)
            do {
                if case .conflict(let current) = try await api.deleteItem(spaceId: delete.spaceId, itemId: delete.id,
                                                                          updatedAt: updatedAt),
                   let key = itemKey(delete.spaceId) {
                    apply(current, spaceId: delete.spaceId, itemKey: key)
                }
            } catch let error as SyncAPIError where error.isPermanentForItem || error.status == 404 {
                Log.sync.notice("Delete of \(delete.id, privacy: .public) refused: \(error.code ?? "", privacy: .public)")
            }
            store.update { $0.deletes.removeAll { $0.id == delete.id } }
        }

        for clip in store.state.clips where clip.needsPush {
            guard let key = itemKey(clip.spaceId) else { continue }
            do {
                try await push(clip, itemKey: key)
            } catch let error as SyncAPIError where error.isPermanentForItem {
                store.update { state in
                    guard let index = state.clips.firstIndex(where: { $0.id == clip.id }) else { return }
                    state.clips[index].needsPush = false
                    state.clips[index].pushError = error.localizedDescription
                }
            }
        }
    }

    private func push(_ clip: MobileClip, itemKey: Data) async throws {
        var payload = clip.payload
        var uploaded: [String: String] = [:]   // local name → blob id
        // Upload the image, thumbnail and files first (PROTOCOL.md → Images, Files).
        if let image = clip.localImage, let thumb = clip.localThumb {
            let imageId = try await upload(SharedContainer.blobsDirectory.appending(path: image), spaceId: clip.spaceId, itemKey: itemKey)
            let thumbId = try await upload(SharedContainer.blobsDirectory.appending(path: thumb), spaceId: clip.spaceId, itemKey: itemKey)
            payload.imageBlob = imageId
            payload.thumbBlob = thumbId
            uploaded[image] = imageId
            uploaded[thumb] = thumbId
        }
        if let files = clip.localFiles, !files.isEmpty {
            var blobs: [FileBlob] = []
            for file in files.prefix(SyncConfig.maxFilesPerItem) {
                let url = SharedContainer.filesDirectory.appending(path: file.path)
                let id = try await upload(url, spaceId: clip.spaceId, itemKey: itemKey)
                blobs.append(FileBlob(name: file.name, blob: id, size: file.size))
            }
            payload.fileBlobs = blobs
        }

        let updatedAt = max(Date.now.syncMillis, clip.updatedAt + 1)
        let fingerprint = try SyncPayload.clip(payload).fingerprint()
        let plaintext = try SyncPayload.clip(payload).withRev(updatedAt).canonicalJSON()
        guard plaintext.count + SyncCrypto.sealOverhead <= SyncConfig.maxItemCiphertext else {
            throw SyncAPIError.server(status: 413, code: "too_large", message: "This item is too large to sync.", retryAfter: nil)
        }
        let category = payload.category
        let ciphertext = try SyncCrypto.seal(plaintext, key: itemKey,
                                             aad: SyncCrypto.AAD.item(spaceId: clip.spaceId, itemId: clip.id, category: category.rawValue))
        let outcome = try await api.putItem(spaceId: clip.spaceId, itemId: clip.id,
                                            ItemUpload(category: category.rawValue, sortAt: payload.lastCopiedAt,
                                                       updatedAt: updatedAt, ciphertext: ciphertext, blobIds: payload.blobIds))
        switch outcome {
        case .saved(_, let trimmed):
            // Uploaded files keep their bytes here, renamed to their blob ids.
            for (local, blob) in uploaded {
                let fm = FileManager.default
                let from = SharedContainer.blobsDirectory.appending(path: local)
                let to = SharedContainer.blobsDirectory.appending(path: blob)
                try? fm.removeItem(at: to)
                try? fm.moveItem(at: from, to: to)
            }
            store.update { state in
                guard let index = state.clips.firstIndex(where: { $0.id == clip.id }) else { return }
                var current = state.clips[index]
                // Changed again while pushing: keep the change, push it next time.
                let changedMeanwhile = current.payload != clip.payload
                current.payload.imageBlob = payload.imageBlob
                current.payload.thumbBlob = payload.thumbBlob
                current.payload.fileBlobs = payload.fileBlobs
                current.localImage = nil
                current.localThumb = nil
                current.localFiles = nil
                current.updatedAt = updatedAt
                current.fingerprint = fingerprint
                current.needsPush = changedMeanwhile
                current.pushError = nil
                current.authorUid = session.uid
                state.clips[index] = current
                for id in trimmed where id != clip.id {
                    if let i = state.clips.firstIndex(where: { $0.id == id }) { state.clips[i].trimmed = true }
                }
            }
        case .conflict(let current):
            store.update { state in
                if let index = state.clips.firstIndex(where: { $0.id == clip.id }) { state.clips[index].needsPush = false }
            }
            apply(current, spaceId: clip.spaceId, itemKey: itemKey)
        }
    }

    /// Seals a file and uploads it as a new blob; returns its id.
    private func upload(_ url: URL, spaceId: String, itemKey: Data) async throws -> String {
        let id = SyncCrypto.newID()
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let sealed = try SyncCrypto.seal(data, key: itemKey, aad: SyncCrypto.AAD.blob(spaceId: spaceId, blobId: id))
        guard sealed.count <= SyncConfig.maxBlobCiphertext else {
            throw SyncAPIError.server(status: 413, code: "too_large", message: "A file is larger than 100 MB.", retryAfter: nil)
        }
        let ticket = try await api.registerBlob(spaceId: spaceId, blobId: id, size: sealed.count)
        try await api.uploadBlob(ticket, data: sealed)
        return id
    }

    // MARK: Blobs

    /// Thumbnails of the newest image clips that don't have one here yet.
    private func fetchThumbnails() async {
        let missing = store.state.clips
            .filter { $0.kind == .image && $0.payload.thumbBlob != nil && $0.thumbnailFile == nil }
            .sorted { $0.payload.lastCopiedAt > $1.payload.lastCopiedAt }
            .prefix(Self.thumbnailsPerSync)
        for clip in missing {
            guard let blob = clip.payload.thumbBlob else { continue }
            _ = try? await downloadBlob(blob, spaceId: clip.spaceId)
        }
        if !missing.isEmpty { store.reload() }
    }

    /// A blob's plaintext, cached in `blobsDirectory` under its id.
    func downloadBlob(_ blobId: String, spaceId: String) async throws -> URL {
        let url = SharedContainer.blobsDirectory.appending(path: blobId)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if itemKey(spaceId) == nil, let space = try await api.spaces().first(where: { $0.id == spaceId }) {
            _ = try spaceKey(for: space)
        }
        guard let key = itemKey(spaceId) else { throw SyncCryptoError.badKey }
        let sealed = try await api.downloadBlob(spaceId: spaceId, blobId: blobId)
        let plain = try SyncCrypto.open(sealed, key: key, aad: SyncCrypto.AAD.blob(spaceId: spaceId, blobId: blobId))
        try plain.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    /// Signs out on the server; the caller wipes local state.
    func signOut() async {
        try? await api.logout()
    }
}
