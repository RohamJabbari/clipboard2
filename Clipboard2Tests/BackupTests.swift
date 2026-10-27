import Testing
import Foundation
import SwiftData
import AppKit
@testable import Clipboard2

/// Renders text to a PNG the way a screenshot would look.
func renderTextPNG(_ text: String, width: Int = 520, height: Int = 70) throws -> Data {
    let size = NSSize(width: width, height: height)
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    (text as NSString).draw(at: NSPoint(x: 14, y: 18), withAttributes: [
        .font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black,
    ])
    NSGraphicsContext.restoreGraphicsState()
    return try #require(rep.representation(using: .png, properties: [:]))
}

@MainActor
final class FakeSecretSink: BackupSecretSink {
    var stored: [(name: String, value: String)] = []
    var finished = 0

    init(_ stored: [(name: String, value: String)] = []) { self.stored = stored }
    func existingSecrets() -> [(name: String, value: String)] { stored }
    func addSecret(name: String, value: String) -> Bool {
        stored.append((name, value))
        return true
    }
    func finishImport() { finished += 1 }
}

/// An in-memory history, snippets and blob folder.
@MainActor
struct TestStores {
    let container: ModelContainer
    let store: ClipStore
    let snippets: SnippetStore

    init() throws {
        let schema = AppEnvironment.schema
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let dir = FileManager.default.temporaryDirectory.appending(path: "Clipboard2Tests-\(UUID().uuidString)")
        store = ClipStore(context: container.mainContext, blobs: BlobStore(directory: dir))
        snippets = SnippetStore(context: container.mainContext)
    }

    /// An image item whose PNG and thumbnail are real files in the blob folder.
    @discardableResult
    func addImage(_ png: Data, now: Date = .now) throws -> ClipItem {
        let base = UUID().uuidString
        try store.blobs.write(png, name: base + ".png")
        try store.blobs.write(png, name: base + "-thumb.png")
        let capture = ProcessedCapture(kind: .image, text: "", preview: "Image 520×70", fileURLs: [], source: nil,
                                       hash: ContentHasher.hash(imageData: png), imageFile: base + ".png",
                                       thumbnailFile: base + "-thumb.png", imageWidth: 520, imageHeight: 70,
                                       byteCount: png.count)
        return store.ingest(capture, now: now)
    }
}

struct BackupCryptoTests {
    @Test func headerIsTheSharedThirtySevenByteLayout() throws {
        let salt = Data(repeating: 0xAB, count: 16)
        let nonce = Data(repeating: 0xCD, count: 12)
        let file = try BackupCrypto.seal(Data("hi".utf8), passphrase: "correct horse", salt: salt, nonce: nonce)
        #expect(BackupCrypto.headerLength == 37)
        #expect(file.prefix(4) == Data("C2BK".utf8))
        #expect(file[4] == 0x01)
        #expect(file.subdata(in: 5..<21) == salt)
        #expect(file.subdata(in: 21..<25) == Data([0x00, 0x09, 0x27, 0xC0]))   // 600 000, big-endian
        #expect(file.subdata(in: 25..<37) == nonce)
        #expect(file.count == 37 + 2 + 16)                                      // ciphertext + tag
    }

    @Test func roundTripsAndRejectsTheWrongPassphrase() throws {
        let plaintext = Data("{\"format\":\"clipboard2-backup\"}".utf8)
        let file = try BackupCrypto.seal(plaintext, passphrase: "correct horse")
        #expect(try BackupCrypto.open(file, passphrase: "correct horse") == plaintext)
        #expect(throws: BackupError.wrongPassphraseOrDamaged) { try BackupCrypto.open(file, passphrase: "wrong horse") }
    }

    @Test func passphraseIsNormalisedToNFC() throws {
        let composed = "caf\u{E9} au lait"            // é as one code point
        let decomposed = "cafe\u{301} au lait"        // e + combining accent
        let file = try BackupCrypto.seal(Data("x".utf8), passphrase: composed)
        #expect(try BackupCrypto.open(file, passphrase: decomposed) == Data("x".utf8))
    }

    @Test func tamperingWithTheHeaderOrBodyIsDetected() throws {
        let file = try BackupCrypto.seal(Data("secret stuff".utf8), passphrase: "correct horse")
        var header = file
        header[30] ^= 0x01                               // the nonce is authenticated as AAD
        #expect(throws: BackupError.wrongPassphraseOrDamaged) { try BackupCrypto.open(header, passphrase: "correct horse") }
        var body = file
        body[40] ^= 0x01
        #expect(throws: BackupError.wrongPassphraseOrDamaged) { try BackupCrypto.open(body, passphrase: "correct horse") }
    }

    @Test func refusesForeignFilesWeakSettingsAndNewerVersions() throws {
        #expect(throws: BackupError.notABackup) { try BackupCrypto.open(Data("hello world, not a backup at all....................".utf8), passphrase: "x") }
        let file = try BackupCrypto.seal(Data("x".utf8), passphrase: "correct horse")
        var weak = file
        weak.replaceSubrange(21..<25, with: Data([0x00, 0x00, 0x03, 0xE8]))   // 1 000 iterations
        #expect(throws: BackupError.unsupportedIterations) { try BackupCrypto.open(weak, passphrase: "correct horse") }
        var newer = file
        newer[4] = 0x02
        #expect(throws: BackupError.newerVersion) { try BackupCrypto.open(newer, passphrase: "correct horse") }
        #expect(throws: BackupError.emptyPassphrase) { try BackupCrypto.seal(Data(), passphrase: "") }
    }
}

@MainActor
struct BackupRoundTripTests {
    @Test func exportsAndRestoresHistorySnippetsAndSecrets() throws {
        let source = try TestStores()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        source.store.ingest(.text("plain text", source: AppRef(bundleID: "com.apple.Notes", name: "Notes")), now: t0)
        source.store.ingest(.text("bold", rtf: Data("{\\rtf1 bold}".utf8)), now: t0.addingTimeInterval(1))
        let labelled = source.store.ingest(.text("db.internal:5432"), now: t0.addingTimeInterval(2))
        source.store.setLabel("Staging DB", for: labelled)
        let png = try renderTextPNG("hello backup")
        try source.addImage(png, now: t0.addingTimeInterval(3))
        let file = URL(fileURLWithPath: "/tmp/Report.pdf")
        source.store.ingest(ProcessedCapture(kind: .file, text: file.path, preview: "Report.pdf", fileURLs: [file],
                                             source: nil, hash: ContentHasher.hash(fileURLs: [file])), now: t0.addingTimeInterval(4))
        // A group item stays out of the backup.
        source.store.ingest(.text("group only"), spaceID: "group-1", now: t0)
        source.snippets.create(name: "Sign-off", keyword: ";sig", body: "Best,\n{name}")
        let secret = SecretRef(id: UUID().uuidString, name: "API token", createdAt: t0)

        let contents = BackupExporter.contents(store: source.store, snippets: source.snippets,
                                               secrets: [(ref: secret, value: "s3cr3t")])
        let sealed = try BackupExporter.seal(contents, passphrase: "a long passphrase", now: t0)
        let document = try BackupImporter.open(sealed, passphrase: "a long passphrase")
        #expect(document.app == "mac" && document.format == "clipboard2-backup" && document.version == 1)
        #expect(document.clips.count == 5)
        #expect(document.clips.first { $0.kind == "image" }?.image == png)

        let target = try TestStores()
        let sink = FakeSecretSink()
        let summary = BackupImporter.merge(document, store: target.store, snippets: target.snippets, secrets: sink,
                                           maxAge: nil, now: t0)
        #expect(summary.clipsAdded == 5 && summary.snippetsAdded == 1 && summary.secretsAdded == 1)
        #expect(summary.skipped == 0)

        let restored = target.store.allItems()
        #expect(restored.count == 5)
        #expect(restored.allSatisfy { $0.spaceID == nil })
        let staging = try #require(restored.first { $0.label == "Staging DB" })
        #expect(staging.isPinned && staging.text == "db.internal:5432")
        #expect(staging.id == labelled.id)
        let rich = try #require(restored.first { $0.text == "bold" })
        #expect(rich.kind == .richText && rich.rtfData == Data("{\\rtf1 bold}".utf8))
        #expect(restored.first { $0.text == "plain text" }?.sourceAppName == "Notes")
        #expect(restored.first { $0.kind == .file }?.fileURLs == [file])
        let image = try #require(restored.first { $0.kind == .image })
        let imageFile = try #require(image.imageFile)
        #expect(try Data(contentsOf: target.store.blobs.url(for: imageFile)) == png)
        #expect(image.thumbnailFile != nil && image.imageWidth == 520)
        #expect(target.store.allItems().first?.lastCopiedAt == t0.addingTimeInterval(4))   // order kept

        let snippet = try #require(target.snippets.all().first)
        #expect(snippet.keyword == ";sig" && snippet.body == "Best,\n{name}")
        #expect(sink.stored.count == 1 && sink.stored[0].name == "API token" && sink.stored[0].value == "s3cr3t")

        // A second import changes nothing.
        let again = BackupImporter.merge(document, store: target.store, snippets: target.snippets, secrets: sink,
                                         maxAge: nil, now: t0)
        #expect(again.added == 0)
        #expect(again.clipsSkipped == 5 && again.snippetsSkipped == 1 && again.secretsSkipped == 1)
        #expect(target.store.count() == 5 && target.snippets.all().count == 1 && sink.stored.count == 1)
        #expect(again.message.hasPrefix("Nothing new to add."))
    }

    @Test func mergeSkipsDuplicatesByContentAndLeavesExpiredItemsOut() throws {
        let stores = try TestStores()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        stores.store.ingest(.text("already here"), now: now)
        stores.snippets.create(name: "Hello", keyword: "", body: "Hi there")

        var old = BackupClip(id: UUID().uuidString, kind: "text", createdAt: now.addingTimeInterval(-90 * 86_400).backupMillis,
                             lastCopiedAt: now.addingTimeInterval(-90 * 86_400).backupMillis,
                             contentHash: ContentHasher.hash(text: "old news"))
        old.text = "old news"
        var oldPinned = old
        oldPinned.id = UUID().uuidString
        oldPinned.text = "old but pinned"
        oldPinned.contentHash = ContentHasher.hash(text: "old but pinned")
        oldPinned.isPinned = true
        var duplicate = BackupClip(id: UUID().uuidString, kind: "text", createdAt: now.backupMillis,
                                   lastCopiedAt: now.backupMillis, contentHash: "")   // hash recomputed
        duplicate.text = "already here\n"
        let document = BackupDocument(createdAt: now.backupMillis, clips: [old, oldPinned, duplicate],
                                      snippets: [BackupSnippet(id: "", name: "Hello", keyword: "hi", body: "Hi there", createdAt: 1, updatedAt: 1),
                                                 BackupSnippet(id: "", name: "Hello", keyword: "", body: "Different", createdAt: 1, updatedAt: 1)],
                                      secrets: nil)

        let summary = BackupImporter.merge(document, store: stores.store, snippets: stores.snippets, secrets: nil,
                                           maxAge: 30 * 86_400, now: now)
        #expect(summary.clipsAdded == 1 && summary.clipsExpired == 1 && summary.clipsSkipped == 1)
        #expect(summary.snippetsAdded == 1 && summary.snippetsSkipped == 1)
        #expect(Set(stores.store.allItems().map(\.text)) == ["already here", "old but pinned"])
    }

    @Test func secretsAreLeftOutUnlessChosen() throws {
        let stores = try TestStores()
        stores.store.ingest(.text("x"))
        let contents = BackupExporter.contents(store: stores.store, snippets: stores.snippets, secrets: nil)
        let json = try BackupDocument(createdAt: 1, clips: contents.clips, snippets: [], secrets: contents.secrets).encoded()
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["secrets"] == nil)
        #expect(object["format"] as? String == "clipboard2-backup")
        let clip = try #require((object["clips"] as? [[String: Any]])?.first)
        #expect(clip["id"] is String && clip["type"] as? String == "clip" && clip["image"] == nil)
    }

    @Test func clipsFromAnotherPlatformWithOnlyFileNamesArriveAsText() throws {
        let stores = try TestStores()
        var clip = BackupClip(id: "not-a-uuid", kind: "file", createdAt: 1, lastCopiedAt: 1, contentHash: "file:abc")
        clip.files = ["Report.pdf", "Notes.txt"]
        let document = BackupDocument(createdAt: 1, clips: [clip], snippets: [], secrets: nil)
        let summary = BackupImporter.merge(document, store: stores.store, snippets: stores.snippets, secrets: nil, maxAge: nil)
        #expect(summary.clipsAdded == 1)
        let item = try #require(stores.store.allItems().first)
        #expect(item.kind == .text && item.text == "Report.pdf\nNotes.txt")
        #expect(item.contentHash == ContentHasher.hash(text: "Report.pdf\nNotes.txt"))
    }

    @Test func imageWithoutPixelsIsCountedAsUnreadable() throws {
        let stores = try TestStores()
        let clip = BackupClip(id: UUID().uuidString, kind: "image", createdAt: 1, lastCopiedAt: 1, contentHash: "image:x")
        let summary = BackupImporter.merge(BackupDocument(createdAt: 1, clips: [clip], snippets: [], secrets: nil),
                                           store: stores.store, snippets: stores.snippets, secrets: nil, maxAge: nil)
        #expect(summary.clipsUnreadable == 1 && stores.store.count() == 0)
    }

    @Test func decodingRejectsOtherJSON() {
        #expect(throws: BackupError.notABackup) { try BackupDocument.decode(Data("{\"format\":\"something-else\"}".utf8)) }
        #expect(throws: BackupError.newerVersion) {
            try BackupDocument.decode(Data("{\"format\":\"clipboard2-backup\",\"version\":2}".utf8))
        }
    }

    @Test func writesAFileThatReadsBack() async throws {
        let stores = try TestStores()
        stores.store.ingest(.text("to disk"))
        let contents = BackupExporter.contents(store: stores.store, snippets: stores.snippets, secrets: nil)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).clipboard2backup")
        defer { try? FileManager.default.removeItem(at: url) }
        try await BackupExporter.write(contents, passphrase: "a long passphrase", to: url)
        let document = try await BackupImporter.read(from: url, passphrase: "a long passphrase")
        #expect(document.clips.map(\.text) == ["to disk"])
    }
}
