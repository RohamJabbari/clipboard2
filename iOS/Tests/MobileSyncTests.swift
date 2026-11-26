import Foundation
import Testing
@testable import Clipboard2iOS

// The iOS sync client's pull rules and local changes (PROTOCOL.md → Client sync rules), against
// items sealed here exactly as the server would hand them out.

@MainActor
struct MobileSyncTests {
    let spaceKey = SyncCrypto.randomBytes(32)
    let session: MobileSession
    let store: MobileStore
    let sync: MobileSync

    init() {
        session = MobileSession(uid: SyncCrypto.newID(), email: "me@example.com", token: "t",
                                accountKey: SyncCrypto.randomBytes(32), privateKey: SyncCrypto.newPrivateKey(),
                                personalSpaceId: SyncCrypto.newID())
        store = MobileStore(url: FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString).json"))
        sync = MobileSync(session: session, store: store, vault: MobileVault(keychain: nil), saveSession: { _ in })
    }

    var itemKey: Data { SyncCrypto.itemKey(spaceKey: spaceKey) }

    func remote(_ payload: SyncPayload, id: String, updatedAt: Int64, seq: Int64 = 1) throws -> RemoteItem {
        let plaintext = try payload.withRev(updatedAt).canonicalJSON()
        let sealed = try SyncCrypto.seal(plaintext, key: itemKey,
                                         aad: SyncCrypto.AAD.item(spaceId: session.personalSpaceId, itemId: id,
                                                                  category: payload.category.rawValue))
        return RemoteItem(id: id, category: payload.category.rawValue, seq: seq, sortAt: updatedAt, updatedAt: updatedAt,
                          deleted: nil, ciphertext: sealed, blobIds: [], authorUid: session.uid)
    }

    func textPayload(_ text: String, at ms: Int64) -> SyncPayload {
        .clip(ClipPayload(kind: "text", text: text, preview: text, createdAt: ms, lastCopiedAt: ms,
                          contentHash: ContentHasher.hash(text: text)))
    }

    @Test func pullsClipsAndFolders() throws {
        let id = SyncCrypto.newID()
        sync.apply(try remote(textPayload("hello", at: 1_000), id: id, updatedAt: 1_000), spaceId: session.personalSpaceId, itemKey: itemKey)
        let folder = SyncCrypto.newID()
        sync.apply(try remote(.folder(FolderPayload(name: "Work", createdAt: 1, updatedAt: 1)), id: folder, updatedAt: 1),
                   spaceId: session.personalSpaceId, itemKey: itemKey)
        #expect(store.state.clip(id)?.payload.text == "hello")
        #expect(store.state.clip(id)?.fingerprint != nil)
        #expect(store.state.folders.first?.name == "Work")
    }

    @Test func ignoresARolledBackVersion() throws {
        let id = SyncCrypto.newID()
        sync.apply(try remote(textPayload("new", at: 2_000), id: id, updatedAt: 2_000), spaceId: session.personalSpaceId, itemKey: itemKey)
        sync.apply(try remote(textPayload("old", at: 1_000), id: id, updatedAt: 1_000), spaceId: session.personalSpaceId, itemKey: itemKey)
        #expect(store.state.clip(id)?.payload.text == "new")
        // rev must match updatedAt.
        var forged = try remote(textPayload("forged", at: 3_000), id: id, updatedAt: 3_000)
        forged.updatedAt = 4_000
        sync.apply(forged, spaceId: session.personalSpaceId, itemKey: itemKey)
        #expect(store.state.clip(id)?.payload.text == "new")
    }

    @Test func aLocalChangeWinsOverAnOlderRemoteOne() throws {
        let id = SyncCrypto.newID()
        sync.apply(try remote(textPayload("hello", at: 1_000), id: id, updatedAt: 1_000), spaceId: session.personalSpaceId, itemKey: itemKey)
        store.setSaved(id, true, label: "Greeting", now: Date(syncMillis: 5_000))
        #expect(store.state.clip(id)?.needsPush == true)
        sync.apply(try remote(textPayload("hello", at: 1_000), id: id, updatedAt: 2_000), spaceId: session.personalSpaceId, itemKey: itemKey)
        #expect(store.state.clip(id)?.isSaved == true)
        #expect(store.state.clip(id)?.payload.label == "Greeting")
    }

    @Test func tombstones() throws {
        let kept = SyncCrypto.newID(), gone = SyncCrypto.newID()
        for id in [kept, gone] {
            sync.apply(try remote(textPayload(id, at: 1_000), id: id, updatedAt: 1_000), spaceId: session.personalSpaceId, itemKey: itemKey)
        }
        func tombstone(_ id: String, _ kind: String) -> RemoteItem {
            RemoteItem(id: id, category: "history", seq: 9, sortAt: 0, updatedAt: 3_000, deleted: kind, ciphertext: nil,
                       blobIds: [], authorUid: nil)
        }
        sync.apply(tombstone(kept, "trimmed"), spaceId: session.personalSpaceId, itemKey: itemKey)
        sync.apply(tombstone(gone, "user"), spaceId: session.personalSpaceId, itemKey: itemKey)
        #expect(store.state.clip(kept)?.trimmed == true)
        #expect(store.state.clip(gone) == nil)
    }

    @Test func sharingTheSameTextTwiceMergesIntoOneClip() throws {
        let first = try ClipImporter.makeClip(.text("same"), spaceId: session.personalSpaceId, options: SaveOptions())
        store.add(first)
        let second = try ClipImporter.makeClip(.text("same\n"), spaceId: session.personalSpaceId,
                                               options: SaveOptions(save: true, label: "Pinned"))
        let merged = store.add(second, options: SaveOptions(save: true, label: "Pinned"))
        #expect(store.state.clips.count == 1)
        #expect(merged.id == first.id)
        #expect(merged.payload.copyCount == 2)
        #expect(merged.isSaved)
        #expect(merged.payload.label == "Pinned")
    }

    @Test func deletingASyncedClipQueuesATombstone() throws {
        let synced = SyncCrypto.newID()
        sync.apply(try remote(textPayload("x", at: 1_000), id: synced, updatedAt: 1_000), spaceId: session.personalSpaceId, itemKey: itemKey)
        let local = try ClipImporter.makeClip(.text("local only"), spaceId: session.personalSpaceId, options: SaveOptions())
        store.add(local)
        store.delete(synced)
        store.delete(local.id)
        #expect(store.state.deletes.map(\.id) == [synced])
        #expect(store.state.clips.isEmpty)
    }

    @Test func passwordSignInUnlocksTheKeys() throws {
        let wrapKey = SyncCrypto.randomBytes(32)
        let ak = SyncCrypto.randomBytes(32)
        let priv = SyncCrypto.newPrivateKey()
        let uid = SyncCrypto.newID()
        let account = RemoteAccount(uid: uid, email: "me@example.com", kdf: KDFParams(salt: SyncCrypto.randomBytes(16), iterations: 600_000),
                                    wrappedAccountKey: try SyncCrypto.seal(ak, key: wrapKey, aad: SyncCrypto.AAD.accountKey(uid: uid)),
                                    publicKey: try SyncCrypto.publicKey(of: priv),
                                    wrappedPrivateKey: try SyncCrypto.seal(priv, key: ak, aad: SyncCrypto.AAD.privateKey(uid: uid)),
                                    personalSpaceId: SyncCrypto.newID())
        let unlocked = try PasswordSignIn.unlock(RemoteSession(token: "tok", expiresAt: nil, account: account), wrapKey: wrapKey)
        #expect(unlocked.accountKey == ak)
        #expect(unlocked.privateKey == priv)
        #expect(throws: (any Error).self) {
            try PasswordSignIn.unlock(RemoteSession(token: "tok", expiresAt: nil, account: account), wrapKey: SyncCrypto.randomBytes(32))
        }
    }

    @Test func spaceKeysArePinned() throws {
        let pub = try SyncCrypto.publicKey(of: session.privateKey)
        func space(_ key: Data) throws -> RemoteSpace {
            RemoteSpace(id: session.personalSpaceId, kind: "personal", role: "owner", ownerUid: session.uid,
                        wrappedKey: try SyncCrypto.wrapSpaceKey(key, spaceId: session.personalSpaceId, memberUid: session.uid,
                                                                memberPublicKey: pub),
                        encryptedName: nil, memberCount: 1, createdAt: 0)
        }
        #expect(try sync.spaceKey(for: space(spaceKey)) == spaceKey)
        // A new run (no cached key) with a swapped key is refused.
        let fresh = MobileSync(session: sync.session, store: store, vault: nil, saveSession: { _ in })
        #expect(throws: SyncCryptoError.badKey) { try fresh.spaceKey(for: space(SyncCrypto.randomBytes(32))) }
    }
}
