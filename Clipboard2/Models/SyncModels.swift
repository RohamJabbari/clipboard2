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

    init(id: String, kind: String) {
        self.id = id
        self.kind = kind
    }

    var isPersonal: Bool { kind == "personal" }
    var isOwner: Bool { role == "owner" }
}
