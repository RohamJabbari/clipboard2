import Foundation
import SwiftData
import Testing
@testable import Clipboard2

@MainActor
struct FolderSaverTests {
    let store: ClipStore
    let saver: FolderSaver
    let root = FileManager.default.temporaryDirectory.appending(path: "Clipboard2Tests-\(UUID().uuidString)")
    let destination: URL
    let container: ModelContainer   // ModelContext doesn't retain its container

    init() throws {
        let schema = AppEnvironment.schema
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        store = ClipStore(context: container.mainContext, blobs: BlobStore(directory: root.appending(path: "blobs")))
        saver = FolderSaver(blobs: store.blobs)
        destination = root.appending(path: "Saved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    private var savedNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).sorted()
    }

    private func file(_ name: String, directory: Bool = false) throws -> URL {
        let folder = root.appending(path: "Sources")
        let url = folder.appending(path: name)
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("inside".utf8).write(to: url.appending(path: "a.txt"))
        } else {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return url
    }

    private func fileItem(_ urls: [URL]) -> ClipItem {
        var capture = ProcessedCapture.text(urls.map(\.lastPathComponent).joined(separator: " "))
        capture.kind = .file
        capture.fileURLs = urls
        capture.hash = UUID().uuidString
        return store.ingest(capture)
    }

    // MARK: Naming

    @Test func namesComeFromTheLabelOrTheFirstWords() {
        let labelled = store.ingest(.text("10.0.4.12:5432"))
        store.setLabel("Staging DB / host", for: labelled)
        #expect(FolderSaver.baseName(for: labelled) == "Staging DB - host")

        let text = store.ingest(.text("  Hello there,\n\tthis is a rather long note that keeps going on and on"))
        let name = FolderSaver.baseName(for: text)
        #expect(name == "Hello there, this is a rather long note")
        #expect(name.count <= FolderSaver.maxNameLength)

        #expect(FolderSaver.baseName(for: store.ingest(.text(" \n\t "))) == "Text")
        #expect(FolderSaver.sanitized("...hidden") == "hidden")
        #expect(FolderSaver.sanitized(String(repeating: "x", count: 60))?.count == 40)
    }

    @Test func collisionsAreNumberedLikeFinder() throws {
        try Data().write(to: destination.appending(path: "Note.txt"))
        try Data().write(to: destination.appending(path: "Note 2.txt"))
        #expect(FolderSaver.availableURL(in: destination, name: "Note", extension: "txt").lastPathComponent == "Note 3.txt")
        #expect(FolderSaver.availableURL(in: destination, name: "Photos", extension: "").lastPathComponent == "Photos")
    }

    // MARK: What gets written

    @Test func textIsWrittenAsUTF8TextFiles() throws {
        let a = store.ingest(.text("Greetings from Vienna"))
        let b = store.ingest(.text("Greetings   from\nVienna"))
        let rich = store.ingest(.text("Grüße – ✓"))
        rich.kind = .richText
        let outcome = saver.save([a, b, rich], to: destination)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.saved.map(\.lastPathComponent) == ["Greetings from Vienna.txt", "Greetings from Vienna 2.txt", "Grüße – ✓.txt"])
        #expect(try String(contentsOf: outcome.saved[1], encoding: .utf8) == "Greetings   from\nVienna")
        #expect(try Data(contentsOf: outcome.saved[2]) == Data("Grüße – ✓".utf8))
    }

    @Test func imagesAreWrittenAsPNG() throws {
        let name = "\(UUID().uuidString).png"
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        try store.blobs.write(png, name: name)
        var capture = ProcessedCapture.text("")
        capture.kind = .image
        capture.imageFile = name
        capture.hash = UUID().uuidString
        let image = store.ingest(capture)

        let outcome = saver.save([image, image], to: destination)
        #expect(outcome.saved.map(\.lastPathComponent) == ["Image.png", "Image 2.png"])
        #expect(try Data(contentsOf: destination.appending(path: "Image.png")) == png)

        store.setLabel("Receipt", for: image)
        #expect(saver.save([image], to: destination).saved.map(\.lastPathComponent) == ["Receipt.png"])
    }

    @Test func filesAndFoldersAreCopiedAndMissingOnesReported() throws {
        let report = try file("Report.pdf")
        let photos = try file("Photos", directory: true)
        let gone = root.appending(path: "Sources/Gone.txt")
        let item = fileItem([report, photos, gone])

        let outcome = saver.save([item], to: destination)
        #expect(savedNames == ["Photos", "Report.pdf"])
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "Photos/a.txt").path))
        #expect(FileManager.default.fileExists(atPath: report.path))     // copied, not moved
        #expect(outcome.failures == ["“Gone.txt” no longer exists"])

        // Saving again numbers the copies; a chosen subset writes only those.
        let again = saver.save([item], to: destination) { _ in [report] }
        #expect(again.saved.map(\.lastPathComponent) == ["Report 2.pdf"])
    }

    @Test func aMissingFolderIsAnErrorNotSilence() {
        let outcome = saver.save([store.ingest(.text("hi"))], to: root.appending(path: "Nope"))
        #expect(outcome.saved.isEmpty)
        #expect(outcome.failures == ["“Nope” doesn't exist"])
    }

    @Test func saveFolderDefaultsToDownloadsAndPersists() throws {
        let suite = "Clipboard2Tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.saveFolder.lastPathComponent == "Downloads")
        prefs.saveFolder = destination
        #expect(Preferences(defaults: defaults).saveFolder.standardizedFileURL == destination.standardizedFileURL)
    }
}
