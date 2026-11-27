import Foundation
import Observation

// The iOS item store (docs/features/ios.md → Storage): one JSON file in the App Group container,
// shared by the app and the share extension through file coordination. Clips and folders only;
// secret and authenticator payloads live in the Keychain (MobileVault).

/// A file of a clip that isn't uploaded yet, inside `SharedContainer.filesDirectory`.
nonisolated struct LocalFile: Codable, Equatable, Sendable {
    var name: String
    /// Relative to `SharedContainer.filesDirectory`.
    var path: String
    var size: Int
}

nonisolated struct MobileClip: Codable, Identifiable, Equatable, Sendable {
    /// Lowercase UUID, also the server item id.
    var id: String
    var spaceId: String
    var payload: ClipPayload
    /// The server's `updatedAt` of the version we have, or the time of a local change.
    var updatedAt: Int64
    /// Fingerprint of the payload last sent or received; nil: never synced.
    var fingerprint: String?
    var needsPush = false
    var authorUid: String?
    /// The server trimmed it from history (personal space): kept here, no longer synced.
    var trimmed = false
    /// Why the last push was refused for good (too large, quota); cleared by the next change.
    var pushError: String?
    /// Not uploaded yet: the image and thumbnail (names in `blobsDirectory`) and files.
    var localImage: String?
    var localThumb: String?
    var localFiles: [LocalFile]?

    var kind: ClipKind { ClipKind(rawValue: payload.kind) ?? .text }
    var isSaved: Bool { payload.isPinned }
    var lastCopiedAt: Date { Date(syncMillis: payload.lastCopiedAt) }
    var title: String {
        if let label = payload.label, !label.isEmpty { return label }
        let preview = payload.preview ?? TextPreview.make(payload.text ?? "")
        return preview.isEmpty ? kind.displayName : preview
    }

    /// The thumbnail file, downloaded or local.
    var thumbnailFile: URL? {
        let name = payload.thumbBlob ?? localThumb
        guard let name else { return nil }
        let url = SharedContainer.blobsDirectory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

nonisolated struct MobileFolder: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var spaceId: String
    var payload: FolderPayload
    var updatedAt: Int64

    var name: String { payload.name.isEmpty ? "Folder" : payload.name }
}

nonisolated struct PendingDelete: Codable, Equatable, Sendable {
    var id: String
    var spaceId: String
    var at: Int64
}

nonisolated struct MobileState: Codable, Equatable, Sendable {
    var clips: [MobileClip] = []
    var folders: [MobileFolder] = []
    /// Space id → `since` cursor.
    var cursors: [String: Int64] = [:]
    var deletes: [PendingDelete] = []
    var lastSync: Date?

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clips = try c.decodeIfPresent([MobileClip].self, forKey: .clips) ?? []
        folders = try c.decodeIfPresent([MobileFolder].self, forKey: .folders) ?? []
        cursors = try c.decodeIfPresent([String: Int64].self, forKey: .cursors) ?? [:]
        deletes = try c.decodeIfPresent([PendingDelete].self, forKey: .deletes) ?? []
        lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
    }

    func clip(_ id: String) -> MobileClip? { clips.first { $0.id == id } }

    mutating func upsert(_ clip: MobileClip) {
        if let index = clips.firstIndex(where: { $0.id == clip.id }) { clips[index] = clip } else { clips.append(clip) }
    }

    mutating func upsert(_ folder: MobileFolder) {
        if let index = folders.firstIndex(where: { $0.id == folder.id }) { folders[index] = folder } else { folders.append(folder) }
    }

    /// Removes an item locally, and its files.
    mutating func remove(_ id: String) {
        if let clip = clip(id) { MobileStore.deleteFiles(of: clip) }
        clips.removeAll { $0.id == id }
        folders.removeAll { $0.id == id }
    }

    /// Everything of one space (sign-out, or a space that went away).
    mutating func removeSpace(_ spaceId: String) {
        for clip in clips where clip.spaceId == spaceId { MobileStore.deleteFiles(of: clip) }
        clips.removeAll { $0.spaceId == spaceId }
        folders.removeAll { $0.spaceId == spaceId }
        deletes.removeAll { $0.spaceId == spaceId }
        cursors[spaceId] = nil
    }

    /// Local history beyond this is dropped, oldest first (saved clips are kept).
    static let localHistoryLimit = 1000

    mutating func trimHistory() {
        let history = clips.filter { !$0.isSaved && !$0.needsPush }.sorted { $0.payload.lastCopiedAt > $1.payload.lastCopiedAt }
        guard history.count > Self.localHistoryLimit else { return }
        for clip in history.dropFirst(Self.localHistoryLimit) { remove(clip.id) }
    }
}

/// Reads and writes `MobileState` with `NSFileCoordinator`, so the app and the share extension
/// never overwrite each other's changes.
@Observable
final class MobileStore {
    private(set) var state = MobileState()
    let url: URL

    init(url: URL = SharedContainer.storeURL) {
        self.url = url
        reload()
    }

    /// Picks up changes another process (the share extension) made.
    func reload() {
        state = Self.read(url) ?? MobileState()
    }

    /// Read-modify-write under a coordinated write: `change` sees the latest state on disk.
    @discardableResult
    func update<T>(_ change: (inout MobileState) -> T) -> T {
        var result: T?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { url in
            var current = Self.read(url) ?? MobileState()
            result = change(&current)
            Self.write(current, to: url)
            state = current
        }
        if let result { return result }
        // Coordination failed (should not happen): apply to what we have and write directly.
        var current = state
        let value = change(&current)
        Self.write(current, to: url)
        state = current
        return value
    }

    private static func read(_ url: URL) -> MobileState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MobileState.self, from: data)
    }

    private static func write(_ state: MobileState, to url: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    nonisolated static func deleteFiles(of clip: MobileClip) {
        let fm = FileManager.default
        for name in [clip.localImage, clip.localThumb, clip.payload.imageBlob, clip.payload.thumbBlob].compactMap({ $0 }) {
            try? fm.removeItem(at: SharedContainer.blobsDirectory.appending(path: name))
        }
        try? fm.removeItem(at: SharedContainer.filesDirectory.appending(path: clip.id, directoryHint: .isDirectory))
    }
}

// MARK: - Secrets and authenticators

nonisolated struct MobileSecret: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var spaceId: String
    var payload: SecretPayload
}

nonisolated struct MobileOTP: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var spaceId: String
    var payload: OTPPayload
}

/// A code batch someone shared with you (PROTOCOL.md → Authenticators).
nonisolated struct MobileSharedCodes: Codable, Identifiable, Equatable, Sendable {
    var spaceId: String
    var ownerName: String
    var batch: CodeBatch
    var id: String { spaceId }
}

nonisolated struct VaultState: Codable, Equatable, Sendable {
    var secrets: [MobileSecret] = []
    var otps: [MobileOTP] = []
    var shared: [MobileSharedCodes] = []
}

/// Passwords, secrets and authenticator seeds, in this app's own Keychain (not shared with the
/// share extension, which never needs them).
@Observable
final class MobileVault {
    private(set) var state: VaultState
    private let keychain: KeychainJSON<VaultState>?

    init(keychain: KeychainJSON<VaultState>? = KeychainJSON(service: "at.softmaze.Clippy.ios.vault", account: "vault", shared: false)) {
        self.keychain = keychain
        state = keychain?.read() ?? VaultState()
    }

    func update(_ change: (inout VaultState) -> Void) {
        var copy = state
        change(&copy)
        guard copy != state else { return }
        state = copy
        keychain?.write(copy)
    }

    func clear() {
        state = VaultState()
        keychain?.delete()
    }
}
