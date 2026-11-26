import Foundation
import SwiftData
import Testing
@testable import Clipboard2

@MainActor
struct TextFileContentsTests {
    let store: ClipStore
    let root = FileManager.default.temporaryDirectory.appending(path: "Clipboard2Tests-\(UUID().uuidString)")
    let container: ModelContainer   // ModelContext doesn't retain its container

    init() throws {
        let schema = AppEnvironment.schema
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        store = ClipStore(context: container.mainContext, blobs: BlobStore(directory: root.appending(path: "blobs")))
    }

    private var kept: URL { root.appending(path: "Kept", directoryHint: .isDirectory) }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let folder = root.appending(path: "Sources")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try data.write(to: url)
        return url
    }

    private func file(_ name: String, _ text: String) throws -> URL { try file(name, Data(text.utf8)) }

    private func fileItem(_ url: URL) -> ClipItem {
        var capture = ProcessedCapture.text(url.path)
        capture.kind = .file
        capture.fileURLs = [url]
        capture.preview = url.lastPathComponent
        capture.hash = ContentHasher.hash(fileURLs: [url])
        capture.source = AppRef(bundleID: "com.apple.finder", name: "Finder")
        return store.ingest(capture)
    }

    // MARK: Detection

    @Test func knownExtensionsAreText() {
        for name in ["a.txt", "a.json", "a.xml", "a.csv", "a.md", "a.yaml", "a.yml", "a.log", "a.html", "a.js",
                     "a.ts", "a.py", "a.swift", "Makefile", ".gitignore"] {
            #expect(TextFileContents.isTextExtension(URL(filePath: "/tmp/\(name)")), "\(name)")
        }
        for name in ["a.pdf", "a.png", "a.docx", "a.rtf", "a.zip"] {
            #expect(!TextFileContents.isTextExtension(URL(filePath: "/tmp/\(name)")), "\(name)")
        }
    }

    @Test func textFilesLoadAndCodeIsMonospaced() throws {
        guard case .text(let notes) = TextFileContents.load(try file("notes.txt", "Hello\nWorld")) else {
            Issue.record("not text")
            return
        }
        #expect(notes.text == "Hello\nWorld")
        #expect(!notes.isMonospaced && !notes.isTruncated)
        guard case .text(let code) = TextFileContents.load(try file("main.swift", "let x = 1")) else {
            Issue.record("not text")
            return
        }
        #expect(code.isMonospaced)
    }

    @Test func unknownExtensionIsSniffed() throws {
        guard case .text(let loaded) = TextFileContents.load(try file("README", "plain words, ünïcode")) else {
            Issue.record("not text")
            return
        }
        #expect(loaded.text == "plain words, ünïcode")
        #expect(TextFileContents.load(try file("blob.bin", Data([0x89, 0x50, 0x00, 0x01, 0xFF]))) == .notText)
        #expect(TextFileContents.load(try file("photo.dat", Data([0xFF, 0xD8, 0xFF, 0xE0, 0x80]))) == .notText)
    }

    @Test func validJSONIsPrettyPrintedAndInvalidKeptAsIs() throws {
        guard case .text(let valid) = TextFileContents.load(try file("a.json", #"{"b":1,"a":[1,2]}"#)) else {
            Issue.record("not text")
            return
        }
        #expect(valid.isPrettyJSON)
        #expect(valid.display.contains("\n"))
        #expect(valid.text == #"{"b":1,"a":[1,2]}"#)
        guard case .text(let invalid) = TextFileContents.load(try file("b.json", #"{"b":1,"#)) else {
            Issue.record("not text")
            return
        }
        #expect(!invalid.isPrettyJSON)
        #expect(invalid.display == #"{"b":1,"#)
    }

    @Test func largeFilesShowTheFirstPartWithoutBreakingACharacter() throws {
        // "é" is two bytes: a limit of 5 cuts the third one in half.
        let url = try file("big.txt", "ééééé")
        guard case .text(let loaded) = TextFileContents.load(url, limit: 5) else {
            Issue.record("not text")
            return
        }
        #expect(loaded.isTruncated)
        #expect(loaded.text == "éé")
        #expect(loaded.byteCount == 10)
        // An unknown type that's too big to read whole doesn't count as text.
        #expect(TextFileContents.load(try file("big", String(repeating: "a", count: 20)), limit: 10) == .notText)
    }

    @Test func missingFilesAndSecretsSaySo() throws {
        #expect(TextFileContents.load(root.appending(path: "gone.txt")) == .missing)
        #expect(TextFileContents.load(try file(".env", "API_KEY=abc")) == .hidden)
        #expect(TextFileContents.load(try file("server.pem", "x")) == .hidden)
        let key = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA\n-----END OPENSSH PRIVATE KEY-----"
        #expect(TextFileContents.load(try file("notes.txt", key)) == .hidden)
        #expect(!TextFileContents.canEdit(try file("id_rsa", "x")))
    }

    @Test func utf16WithBOMDecodes() throws {
        var data = Data([0xFF, 0xFE])
        data.append("Hi".data(using: .utf16LittleEndian)!)
        guard case .text(let loaded) = TextFileContents.load(try file("w.txt", data)) else {
            Issue.record("not text")
            return
        }
        #expect(loaded.text == "Hi")
    }

    @Test func canEditOnlySmallTextFiles() throws {
        #expect(TextFileContents.canEdit(try file("a.txt", "x")))
        #expect(!TextFileContents.canEdit(try file("a.bin", Data([0, 1, 2]))))
        #expect(!TextFileContents.canEdit(root))
        #expect(!TextFileContents.canEdit(root.appending(path: "gone.txt")))
    }

    // MARK: Names

    @Test func editedNamesCountUp() {
        #expect(TextFileContents.editedName(for: "notes.txt") == "notes-edited.txt")
        #expect(TextFileContents.editedName(for: "notes.txt", taken: ["notes-edited.txt"]) == "notes-edited-2.txt")
        #expect(TextFileContents.editedName(for: "notes.txt", taken: ["Notes-Edited.txt", "notes-edited-2.txt"]) == "notes-edited-3.txt")
        // Editing an edited copy doesn't stack suffixes.
        #expect(TextFileContents.editedName(for: "notes-edited.txt") == "notes-edited-2.txt")
        #expect(TextFileContents.editedName(for: "notes-edited-2.txt", taken: ["notes-edited.txt"]) == "notes-edited-3.txt")
        #expect(TextFileContents.editedName(for: "Makefile") == "Makefile-edited")
        #expect(TextFileContents.editedName(for: ".gitignore") == ".gitignore-edited")
        #expect(TextFileContents.editedName(for: "archive.tar.gz") == "archive.tar-edited.gz")
    }

    @Test func typedNamesAreMadeSafe() {
        #expect(TextFileContents.sanitizedName("  report.txt \n") == "report.txt")
        #expect(TextFileContents.sanitizedName("a/b:c.txt") == "a-b-c.txt")
        #expect(TextFileContents.sanitizedName("   ") == nil)
        #expect(TextFileContents.sanitizedName("..") == nil)
        let long = TextFileContents.sanitizedName(String(repeating: "x", count: 300) + ".txt")
        #expect(long?.utf8.count ?? 0 <= 255)
        #expect(long?.hasSuffix(".txt") == true)
    }

    // MARK: Kept files

    @Test func savingAnEditKeepsANewItemAndLeavesTheOriginal() throws {
        let source = try file("notes.txt", "original")
        let original = fileItem(source)
        let copy = try store.addKeptFile(named: "notes-edited.txt", contents: Data("changed".utf8), like: original, directory: kept)

        #expect(copy.id != original.id)
        #expect(copy.kind == .file)
        #expect(copy.spaceID == nil)
        #expect(copy.fileURLs.count == 1)
        let url = try #require(copy.fileURLs.first)
        #expect(url.lastPathComponent == "notes-edited.txt")
        #expect(url.deletingLastPathComponent().lastPathComponent == copy.id.uuidString.lowercased())
        #expect(try String(contentsOf: url, encoding: .utf8) == "changed")
        #expect(copy.source?.bundleID == "com.apple.finder")
        #expect(copy.preview == "notes-edited.txt")
        #expect(store.keepsFiles(of: copy, directory: kept))
        // The original is untouched, on disk and in the store.
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
        #expect(original.fileURLs == [source])
        #expect(!store.keepsFiles(of: original, directory: kept))
        #expect(store.count() == 2)
    }

    @Test func renamingAnOutsideFileKeepsARenamedCopy() throws {
        let source = try file("report.pdf", Data([1, 2, 3]))
        let original = fileItem(source)
        let copy = try store.addKeptFile(named: "Q3 report.pdf", copying: source, like: original, directory: kept)
        #expect(copy.fileURLs.first?.lastPathComponent == "Q3 report.pdf")
        #expect(FileManager.default.contents(atPath: copy.fileURLs[0].path) == Data([1, 2, 3]))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(source.lastPathComponent == "report.pdf")
    }

    @Test func renamingAKeptFileRenamesItInPlace() throws {
        let copy = try store.addKeptFile(named: "a-edited.txt", contents: Data("x".utf8), directory: kept)
        let before = copy.fileURLs[0]
        let hash = copy.contentHash
        try store.renameKeptFile(of: copy, to: "final.txt", directory: kept)
        let after = try #require(copy.fileURLs.first)
        #expect(after.lastPathComponent == "final.txt")
        #expect(after.deletingLastPathComponent().path == before.deletingLastPathComponent().path)
        #expect(!FileManager.default.fileExists(atPath: before.path))
        #expect(try String(contentsOf: after, encoding: .utf8) == "x")
        #expect(copy.preview == "final.txt")
        #expect(copy.text == after.path)
        #expect(copy.contentHash != hash)
        // Only the case changes.
        try store.renameKeptFile(of: copy, to: "Final.txt", directory: kept)
        #expect(copy.fileURLs.first?.lastPathComponent == "Final.txt")
        #expect(FileManager.default.fileExists(atPath: copy.fileURLs[0].path))
    }

    @Test func outsideFilesAreNeverRenamedInPlace() throws {
        let source = try file("mine.txt", "x")
        let item = fileItem(source)
        #expect(throws: (any Error).self) { try store.renameKeptFile(of: item, to: "other.txt", directory: kept) }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}
