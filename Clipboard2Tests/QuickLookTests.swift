import AppKit
import Foundation
import SwiftData
import Testing
@testable import Clipboard2

@MainActor
struct QuickLookTests {
    let store: ClipStore
    let files: QuickLookFiles
    let root = FileManager.default.temporaryDirectory.appending(path: "Clipboard2Tests-\(UUID().uuidString)")
    let container: ModelContainer   // ModelContext doesn't retain its container

    init() throws {
        let schema = AppEnvironment.schema
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        store = ClipStore(context: container.mainContext, blobs: BlobStore(directory: root.appending(path: "blobs")))
        files = QuickLookFiles(blobs: store.blobs, directory: root.appending(path: "Quick Look"))
    }

    private func file(_ name: String) throws -> URL {
        let folder = root.appending(path: "Sources")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func fileItem(_ urls: [URL]) -> ClipItem {
        var capture = ProcessedCapture.text(urls.map(\.lastPathComponent).joined(separator: " "))
        capture.kind = .file
        capture.fileURLs = urls
        capture.hash = UUID().uuidString
        return store.ingest(capture)
    }

    private func imageItem() throws -> ClipItem {
        let name = "\(UUID().uuidString).png"
        try store.blobs.write(Data("png".utf8), name: name)
        var capture = ProcessedCapture.text("")
        capture.kind = .image
        capture.imageFile = name
        capture.hash = UUID().uuidString
        return store.ingest(capture)
    }

    @Test func imagesPreviewTheirBlob() throws {
        let item = try imageItem()
        let urls = files.urls(for: [.clip(item)])
        #expect(urls == [store.blobs.url(for: item.imageFile!)])
        #expect(files.canPreview(.clip(item)))
    }

    @Test func fileItemsPreviewTheirExistingFiles() throws {
        let a = try file("a.pdf"), b = try file("b.txt")
        let gone = root.appending(path: "Sources/gone.txt")
        let item = fileItem([a, gone, b])
        #expect(files.urls(for: [.clip(item)]) == [a, b])
        #expect(files.urls(for: [.clip(item)]) { _ in [b] } == [b])
    }

    @Test func plainTextIsWrittenAsTxt() throws {
        let item = store.ingest(.text("Hello Quick Look\nsecond line"))
        let url = try #require(files.urls(for: [.clip(item)]).first)
        #expect(url.pathExtension == "txt")
        #expect(url.path.hasPrefix(files.directory.path))
        #expect(try String(contentsOf: url, encoding: .utf8) == "Hello Quick Look\nsecond line")
    }

    @Test func richTextKeepsItsFormatting() throws {
        let rtf = try NSAttributedString(string: "Bold").data(from: NSRange(location: 0, length: 4),
                                                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let item = store.ingest(.text("Bold", rtf: rtf))
        #expect(item.kind == .richText)
        let url = try #require(files.urls(for: [.clip(item)]).first)
        #expect(url.pathExtension == "rtf")
        #expect(try Data(contentsOf: url) == rtf)

        let html = store.ingest(.text("Linked \(UUID())"))
        html.kind = .richText
        html.htmlData = Data("<b>Linked</b>".utf8)
        #expect(QuickLookFiles.textFormat(of: html) == .html)
    }

    @Test func credentialsSnippetsAndSecretsAreNeverWritten() throws {
        let key = store.ingest(.text("sk-proj-4f9a2c7d1e8b6a3f9c2d7e1b"))
        let snippet = Snippet(name: "Sig", body: "Best, Me")
        let secret = SecretRef(id: UUID().uuidString, name: "DB password", createdAt: nil)
        let entries: [PanelEntry] = [.clip(key), .snippet(snippet), .secret(secret)]
        #expect(files.urls(for: entries).isEmpty)
        #expect(entries.allSatisfy { !files.canPreview($0) })
        #expect(!FileManager.default.fileExists(atPath: files.directory.path))
    }

    @Test func severalItemsPreviewTogetherInOrder() throws {
        let image = try imageItem()
        let a = try file("a.pdf")
        let text = store.ingest(.text("note \(UUID())"))
        let urls = files.urls(for: [.clip(image), .clip(fileItem([a])), .clip(text)])
        #expect(urls.count == 3)
        #expect(urls[0].pathExtension == "png")
        #expect(urls[1] == a)
        #expect(urls[2].pathExtension == "txt")
    }

    @Test func temporaryFilesAreReusedPerItemAndCleared() throws {
        let item = store.ingest(.text("reuse me"))
        let first = try #require(files.textFile(for: item))
        let created = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)
        let again = try #require(files.textFile(for: item))
        #expect(again == first)
        #expect(try FileManager.default.attributesOfItem(atPath: again.path)[.modificationDate] as? Date == created)

        // A label renames the file; the old one doesn't linger in the item's folder.
        store.setLabel("Renamed", for: item)
        let renamed = try #require(files.textFile(for: item))
        #expect(renamed.lastPathComponent == "Renamed.txt")
        let folder = renamed.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Renamed.txt"])

        files.removeAll()
        #expect(!FileManager.default.fileExists(atPath: files.directory.path))
    }
}

/// The panel's selection decides what Quick Look shows.
@MainActor
struct QuickLookSelectionTests {
    let env = AppEnvironment.shared
    let model: PanelViewModel
    let root = FileManager.default.temporaryDirectory.appending(path: "Clipboard2Tests-\(UUID().uuidString)")

    init() {
        model = PanelViewModel(env: env)
        model.quickLookFiles = QuickLookFiles(blobs: env.blobs, directory: root.appending(path: "Quick Look"))
    }

    private func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func pickedFilesLimitThePreview() throws {
        let folder = root.appending(path: "Sources")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = try ["one.txt", "two.txt", "three.txt"].map { name in
            let url = folder.appending(path: name)
            try Data(name.utf8).write(to: url)
            return url
        }
        var capture = ProcessedCapture.text("ql-files")
        capture.kind = .file
        capture.fileURLs = urls
        capture.hash = UUID().uuidString
        let item = env.store.ingest(capture)
        defer { env.store.delete(item) }
        model.refresh(resetSelection: true)
        model.selectedID = PanelEntry.clip(item).id

        #expect(model.quickLookURLs() == urls)
        model.togglePickedFile(urls[2])
        model.togglePickedFile(urls[0])
        #expect(model.quickLookURLs() == [urls[0], urls[2]])
    }

    @Test func multiSelectionPreviewsEveryItem() {
        let tag = UUID().uuidString
        let a = env.store.ingest(.text("qlmulti-a \(tag)"))
        let b = env.store.ingest(.text("qlmulti-b \(tag)"))
        defer { [a, b].forEach(env.store.delete) }
        model.query = tag
        model.refresh(resetSelection: true)
        model.selectAll()
        #expect(model.quickLookURLs().count == 2)
    }

    @Test func commandYAndEscapeDriveQuickLook() {
        let tag = UUID().uuidString
        let items = [env.store.ingest(.text("ql-keys-a \(tag)")), env.store.ingest(.text("ql-keys-b \(tag)"))]
        defer { items.forEach(env.store.delete) }
        model.query = tag
        model.selectedID = PanelEntry.clip(items[0]).id

        var open = false
        var closedPanel = false
        var changes = 0
        model.isQuickLookOpen = { open }
        model.onQuickLook = { open = $0 }
        model.onClose = { closedPanel = true }
        model.onQuickLookItemsChanged = { changes += 1 }

        #expect(model.canQuickLook)
        #expect(model.availableActions.contains(.quickLook))
        #expect(model.handleKeyDown(key(16, "y", flags: .command)))
        #expect(open)
        // Esc closes Quick Look first, then the panel.
        #expect(model.handleKeyDown(key(KeyCode.escape, "\u{1b}")))
        #expect(!open && !closedPanel)
        #expect(model.handleKeyDown(key(16, "y", flags: .command)))
        #expect(model.handleKeyDown(key(16, "y", flags: .command)))
        #expect(!open)
        #expect(model.handleKeyDown(key(KeyCode.escape, "\u{1b}")))
        #expect(closedPanel)

        // Moving the selection tells an open Quick Look to follow.
        #expect(model.entries.count == 2)
        model.selectedID = model.entries.first?.id
        let before = changes
        model.moveSelection(by: 1)
        #expect(changes > before)
    }
}
