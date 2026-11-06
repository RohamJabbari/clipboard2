import AppKit
import SwiftData
import Testing
@testable import Clipboard2

@MainActor
struct PasteTests {
    let store: ClipStore
    let paste: PasteService
    let pasteboard = NSPasteboard(name: .init("Clipboard2Tests-\(UUID().uuidString)"))
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let container: ModelContainer   // ModelContext doesn't retain its container

    init() throws {
        let schema = AppEnvironment.schema
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        store = ClipStore(context: container.mainContext, blobs: BlobStore(directory: folder.appending(path: "blobs")))
        let defaults = try #require(UserDefaults(suiteName: "Clipboard2Tests-\(UUID().uuidString)"))
        paste = PasteService(store: store, prefs: Preferences(defaults: defaults), tracker: FrontmostAppTracker(), pasteboard: pasteboard)
    }

    private func file(_ name: String, directory: Bool = false) throws -> ClipItem {
        let url = folder.appending(path: name)
        if directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        else { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try Data("x".utf8).write(to: url) }
        var capture = ProcessedCapture.text(name)
        capture.kind = .file
        capture.fileURLs = [url]
        capture.hash = UUID().uuidString
        return store.ingest(capture)
    }

    private func image() throws -> ClipItem {
        let name = "\(UUID().uuidString).png"
        try store.blobs.write(Data([0x89, 0x50, 0x4E, 0x47]), name: name)
        var capture = ProcessedCapture.text("")
        capture.kind = .image
        capture.imageFile = name
        capture.hash = UUID().uuidString
        return store.ingest(capture)
    }

    private var pastedURLs: [URL] { pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [] }

    @Test func documentsFoldersAndImagesPasteTogetherAsFiles() throws {
        let items = [try file("Report.pdf"), try file("Photos", directory: true), try image(), try image()]
        paste.write(items, transform: nil)
        let names = pastedURLs.map(\.lastPathComponent)
        #expect(names == ["Report.pdf", "Photos", "Image.png", "Image 2.png"])
        #expect(pastedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let legacy = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String]
        #expect(legacy == pastedURLs.map(\.path))
    }

    @Test func textInAMixedSelectionTravelsAlongsideTheFiles() throws {
        let items = [store.ingest(.text("hello")), try file("Notes.txt"), store.ingest(.text("world"))]
        paste.write(items, transform: nil)
        #expect(pastedURLs.map(\.lastPathComponent) == ["Notes.txt"])
        #expect(pasteboard.string(forType: .string) == "hello\nworld")
    }

    /// "Text in image" → Copy: plain text, marked so the monitor doesn't capture it as a new item.
    @Test func copiedImageTextIsAnOwnWrite() {
        paste.write(text: "INVOICE 2026-114")
        #expect(pasteboard.string(forType: .string) == "INVOICE 2026-114")
        let types = pasteboard.types?.map(\.rawValue) ?? []
        #expect(ClipboardFilter.decide(types: types, sourceBundleID: nil, ignoredBundleIDs: []) == .ownWrite)
    }

    @Test func textOnlySelectionsStillJoinWithLineBreaks() {
        paste.write([store.ingest(.text("a")), store.ingest(.text("b"))], transform: nil)
        #expect(pasteboard.string(forType: .string) == "a\nb")
        #expect(pastedURLs.isEmpty)
    }
}
