import Foundation
import SwiftData

/// What sync last sent or received for one local item (PROTOCOL.md → Client sync rules).
/// A changed fingerprint means the item needs a push; a row without its local item means a delete.
@Model
final class SyncMeta {
    /// Lowercase UUID of the clip, snippet or secret (also the server's item id).
    var localId: String = ""
    var spaceId: String = ""
    var category: String = ""
    /// SHA-256 (hex) of the canonical payload JSON last sent or received.
    var fingerprint: String = ""
    var remoteSeq: Int64 = 0
    var updatedAt: Int64 = 0
    /// Blob ids of the image and thumbnail already on the server, so re-pushes don't re-upload.
    var blobIds: [String] = []
    /// Who last wrote the item on the server (shown as "copied by" in groups).
    var authorUid: String?
    /// File clips: `path|size` of each local file → the blob holding its contents. A file whose
    /// size changed no longer matches, so it's uploaded again; one that's gone drops out.
    var fileBlobs: [String: String] = [:]
    /// A cheap digest of the local item's fields when it was last pushed or applied. While it
    /// matches, a tick skips the item without building and hashing its payload.
    var localStamp: String = ""
    /// Personal history the server no longer has after a full resync. It stays on this Mac but is
    /// never pushed (that would bring back items deleted elsewhere), unless it's copied again.
    var detached = false

    init(localId: String, spaceId: String, category: String) {
        self.localId = localId
        self.spaceId = spaceId
        self.category = category
    }
}

/// A space the account belongs to, with its decrypted name and the pull cursor.
@Model
final class SyncSpace {
    var id: String = ""
    var kind: String = "group"
    var role: String = "member"
    var ownerUid: String = ""
    var name: String = ""
    var memberCount: Int = 1
    var createdAt: Int64 = 0
    /// uid → display name of the members, from the server's space list.
    var memberNames: [String: String] = [:]
    /// Set after the one-time re-download that records item authors.
    var authorsBackfilled = false
    /// Highest `seq` applied from `/changes`.
    var since: Int64 = 0
    /// A full resync (`resetRequired`) is under way: the ids seen so far, kept across launches so
    /// an interrupted one resumes instead of starting over or forgetting what it saw.
    var resyncing = false
    var resyncSeen: [String] = []

    init(id: String, kind: String) {
        self.id = id
        self.kind = kind
    }

    var isPersonal: Bool { kind == "personal" }
    var isOwner: Bool { role == "owner" }
}
