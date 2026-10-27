import Foundation
import SwiftData

// The store's versions. Anyone changing a persisted model adds a new version here (freezing a
// copy of the previous one) and a stage to the plan: a store whose shape matches no version
// can't be opened with the plan.

/// The models as shipped in 1.3.0, frozen (entity names and stored properties must not change).
nonisolated enum StoreSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [ClipItem.self, Snippet.self, SyncMeta.self, SyncSpace.self] }

    @Model
    final class ClipItem {
        var id: UUID = UUID()
        var createdAt: Date = Date.now
        var lastCopiedAt: Date = Date.now
        var kindRaw: String = "text"
        var text: String = ""
        var preview: String = ""
        @Attribute(.externalStorage) var rtfData: Data?
        @Attribute(.externalStorage) var htmlData: Data?
        var contentHash: String = ""
        var fileURLStrings: [String] = []
        var imageFile: String?
        var thumbnailFile: String?
        var imageWidth: Int = 0
        var imageHeight: Int = 0
        var byteCount: Int = 0
        var sourceBundleID: String?
        var sourceAppName: String?
        var isPinned: Bool = false
        var label: String?
        var pinnedAt: Date?
        var copyCount: Int = 1
        var spaceID: String?

        init() {}
    }

    @Model
    final class Snippet {
        var id: UUID = UUID()
        var name: String = ""
        var keyword: String = ""
        var body: String = ""
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now
        var spaceID: String?

        init() {}
    }

    @Model
    final class SyncMeta {
        var localId: String = ""
        var spaceId: String = ""
        var category: String = ""
        var fingerprint: String = ""
        var remoteSeq: Int64 = 0
        var updatedAt: Int64 = 0
        var blobIds: [String] = []
        var authorUid: String?

        init() {}
    }

    @Model
    final class SyncSpace {
        var id: String = ""
        var kind: String = "group"
        var role: String = "member"
        var ownerUid: String = ""
        var name: String = ""
        var memberCount: Int = 1
        var createdAt: Int64 = 0
        var memberNames: [String: String] = [:]
        var authorsBackfilled = false
        var since: Int64 = 0

        init() {}
    }
}

/// The current models: sync metadata gained the file → blob map, the change stamp, detached
/// stragglers and persisted resync progress.
nonisolated enum StoreSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Clipboard2.ClipItem.self, Clipboard2.Snippet.self, Clipboard2.SyncMeta.self, Clipboard2.SyncSpace.self]
    }
}

nonisolated enum StoreMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [StoreSchemaV1.self, StoreSchemaV2.self] }
    /// Only added properties with defaults, so a lightweight stage is enough.
    static var stages: [MigrationStage] { [.lightweight(fromVersion: StoreSchemaV1.self, toVersion: StoreSchemaV2.self)] }
}
