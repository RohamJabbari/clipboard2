import AppKit
import UniformTypeIdentifiers
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

    /// Some files picked from a multi-file item: only those go out, the item stays whole.
    @Test func pickedFilesPasteOnlyThoseURLs() throws {
        let a = try file("a.txt"), b = try file("b.txt"), c = try file("c.txt")
        var capture = ProcessedCapture.text("a.txt b.txt c.txt")
        capture.kind = .file
        capture.fileURLs = a.fileURLs + b.fileURLs + c.fileURLs
        capture.hash = UUID().uuidString
        let item = store.ingest(capture)

        let chosen = [item.fileURLs[0], item.fileURLs[2]]
        paste.write(fileURLs: chosen)
        #expect(pastedURLs == chosen)
        let legacy = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String]
        #expect(legacy == chosen.map(\.path))
        let types = pasteboard.types?.map(\.rawValue) ?? []
        #expect(ClipboardFilter.decide(types: types, sourceBundleID: nil, ignoredBundleIDs: []) == .ownWrite)
        #expect(item.fileURLs.count == 3)
    }

    /// A multi-file item (or its picked files) drags as one pasteboard item per file; the first
    /// also carries the clip id for drops on a group chip.
    @Test func multiFileDragsCarryEveryFile() throws {
        let a = try file("a.txt"), b = try file("b.txt"), c = try file("c.txt")
        var capture = ProcessedCapture.text("a.txt b.txt c.txt")
        capture.kind = .file
        capture.fileURLs = a.fileURLs + b.fileURLs + c.fileURLs
        capture.hash = UUID().uuidString
        let item = store.ingest(capture)
        #expect(PanelDrag.needsMultiFileDrag(item))
        #expect(!PanelDrag.needsMultiFileDrag(a))

        let all = PanelDrag.files(for: item, picked: nil)
        let entries = PanelDrag.pasteboardItems(for: item, files: all)
        #expect(entries.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) } == item.fileURLs)
        let clipType = NSPasteboard.PasteboardType(UTType.clipboard2Clip.identifier)
        #expect(entries.first?.data(forType: clipType) == Data(item.id.uuidString.utf8))
        #expect(entries.dropFirst().allSatisfy { $0.data(forType: clipType) == nil })

        let picked = [item.fileURLs[0], item.fileURLs[2]]
        #expect(PanelDrag.files(for: item, picked: picked) == picked)
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
