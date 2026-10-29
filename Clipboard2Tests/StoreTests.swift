import Testing
import Foundation
import SwiftData
import AppKit
@testable import Clipboard2

@MainActor
struct StoreTests {
    let store: ClipStore
    let blobs: BlobStore
    let container: ModelContainer

    init() throws {
        let schema = AppEnvironment.schema
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let dir = FileManager.default.temporaryDirectory.appending(path: "Clipboard2Tests-\(UUID().uuidString)")
        blobs = BlobStore(directory: dir)
        store = ClipStore(context: container.mainContext, blobs: blobs)
    }

    // MARK: Editing in the panel

    @Test func editingTextKeepsTheItemsPlaceAndPin() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let item = store.ingest(.text("teh draft"), now: t0)
        store.togglePin(item)
        store.editText(of: item, text: "the draft", rtf: nil, html: nil)
        #expect(item.text == "the draft")
        #expect(item.preview == "the draft")
        #expect(item.kind == .text)
        #expect(item.isPinned)
        #expect(item.lastCopiedAt == t0)
        #expect(item.contentHash == ContentHasher.hash(text: "the draft"))
        #expect(store.item(withHash: ContentHasher.hash(text: "teh draft")) == nil)
    }

    @Test func stylingMakesRichTextAndClearingMakesItPlainAgain() {
        let item = store.ingest(.text("hello"))
        let rtf = Data("{\\rtf1 {\\b hello}}".utf8)
        store.editText(of: item, text: "hello", rtf: rtf, html: Data("<b>hello</b>".utf8))
        #expect(item.kind == .richText)
        #expect(item.rtfData == rtf)
        store.editText(of: item, text: "hello", rtf: nil, html: nil)
        #expect(item.kind == .text)
        #expect(item.htmlData == nil)
    }

    @Test func editingIntoAnotherItemsTextMergesThem() {
        let edited = store.ingest(.text("first"))
        store.ingest(.text("second"))
        store.editText(of: edited, text: "second", rtf: nil, html: nil)
        #expect(store.count() == 1)
        #expect(store.allItems().first?.id == edited.id)
        #expect(edited.copyCount == 2)
    }

    // MARK: Dedupe

    @Test func copyingSameTextTwiceKeepsOneItemAndMovesItToTop() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        store.ingest(.text("hello"), now: t0)
        store.ingest(.text("world"), now: t0.addingTimeInterval(1))
        store.ingest(.text("hello"), now: t0.addingTimeInterval(2))

        let items = store.allItems()
        #expect(items.count == 2)
        #expect(items.first?.text == "hello")
        #expect(items.first?.copyCount == 2)
    }

    @Test func richAndPlainVersionsOfSameTextDedupe() {
        store.ingest(.text("same"))
        store.ingest(.text("same", rtf: Data("{\\rtf1 same}".utf8)))
        let items = store.allItems()
        #expect(items.count == 1)
        #expect(items.first?.kind == .richText)
    }

    @Test func differentTextIsNotDeduped() {
        store.ingest(.text("a"))
        store.ingest(.text("b"))
        store.ingest(.text("a b"))
        #expect(store.count() == 3)
    }

    @Test func surroundingWhitespaceIsIgnoredForDedupe() {
        store.ingest(.text("hello"))
        store.ingest(.text("  hello\n"))
        #expect(store.count() == 1)
    }

    @Test func mergeDuplicatesKeepsNewestUnpinnedAndSumsCounts() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let old = store.ingest(.text("dup"), now: t0)
        let new = store.ingest(.text("other"), now: t0.addingTimeInterval(5))
        new.contentHash = old.contentHash          // simulate legacy duplicates
        #expect(store.mergeDuplicates() == 1)
        let remaining = store.allItems()
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == new.id)
        #expect(remaining.first?.copyCount == 2)
    }

    @Test func mergeDuplicatesNeverDeletesPinned() {
        let pinned = store.ingest(.text("p"), now: Date(timeIntervalSince1970: 1))
        store.togglePin(pinned)
        let newer = store.ingest(.text("q"), now: Date(timeIntervalSince1970: 50))
        newer.contentHash = pinned.contentHash
        store.mergeDuplicates()
        let remaining = store.allItems()
        #expect(remaining.map(\.id) == [pinned.id])
        #expect(remaining.first?.lastCopiedAt == Date(timeIntervalSince1970: 50))
    }

    @Test func removeUnpinnedMatchingSecretHashes() {
        let secretCopy = store.ingest(.text("hunter2"))
        let pinnedCopy = store.ingest(.text("pinned-secret"))
        store.togglePin(pinnedCopy)
        store.ingest(.text("normal"))
        store.removeUnpinned(matching: [secretCopy.contentHash, pinnedCopy.contentHash])
        #expect(Set(store.allItems().map(\.text)) == ["pinned-secret", "normal"])
    }

    @Test func samePixelsDifferentEncodingsHashEqual() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
        let image = try #require(ctx.makeImage())
        let png = try #require(ImageProcessor.encodePNG(image))
        let tiff = try #require(NSBitmapImageRep(cgImage: image).representation(using: .tiff, properties: [:]))
        #expect(png != tiff)
        let a = try #require(ImageProcessor.process(png)?.pixelHash)
        let b = try #require(ImageProcessor.process(tiff)?.pixelHash)
        #expect(a == b)
    }

    @Test func dedupeUpdatesSourceApp() {
        store.ingest(.text("x", source: AppRef(bundleID: "com.a", name: "A")))
        store.ingest(.text("x", source: AppRef(bundleID: "com.b", name: "B")))
        #expect(store.allItems().first?.sourceBundleID == "com.b")
    }

    @Test func duplicateImageCaptureRemovesRedundantBlobs() throws {
        func capture(_ file: String) throws -> ProcessedCapture {
            try blobs.write(Data([1, 2, 3]), name: file)
            return ProcessedCapture(kind: .image, text: "", preview: "Image", fileURLs: [], hash: "image:abc",
                                    imageFile: file, thumbnailFile: nil)
        }
        store.ingest(try capture("first.png"))
        store.ingest(try capture("second.png"))
        #expect(store.count() == 1)
        #expect(blobs.allFileNames() == ["first.png"])
    }

    // MARK: Retention

    @Test func retentionTrimsToMaxItemsKeepingNewest() {
        let base = Date(timeIntervalSince1970: 10_000)
        for i in 0..<10 {
            store.ingest(.text("item \(i)"), now: base.addingTimeInterval(Double(i)))
        }
        store.enforceRetention(maxItems: 3, maxAge: nil, now: base.addingTimeInterval(100))
        #expect(store.allItems().map(\.text) == ["item 9", "item 8", "item 7"])
    }

    @Test func retentionRemovesItemsOlderThanMaxAge() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        store.ingest(.text("old"), now: now.addingTimeInterval(-40 * 86_400))
        store.ingest(.text("new"), now: now.addingTimeInterval(-1 * 86_400))
        store.enforceRetention(maxItems: 500, maxAge: 30 * 86_400, now: now)
        #expect(store.allItems().map(\.text) == ["new"])
    }

    @Test func pinnedItemsAreExemptFromRetention() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let pinned = store.ingest(.text("pinned & ancient"), now: now.addingTimeInterval(-400 * 86_400))
        store.togglePin(pinned)
        for i in 0..<5 { store.ingest(.text("n\(i)"), now: now.addingTimeInterval(Double(-i))) }

        store.enforceRetention(maxItems: 2, maxAge: 30 * 86_400, now: now)

        let texts = Set(store.allItems().map(\.text))
        #expect(texts == ["pinned & ancient", "n0", "n1"])
    }

    @Test func retentionDeletesImageBlobs() throws {
        try blobs.write(Data([0]), name: "img.png")
        try blobs.write(Data([0]), name: "img-thumb.png")
        let now = Date(timeIntervalSince1970: 1_000_000)
        store.ingest(ProcessedCapture(kind: .image, text: "", preview: "Image", fileURLs: [], hash: "image:1",
                                      imageFile: "img.png", thumbnailFile: "img-thumb.png"),
                     now: now.addingTimeInterval(-90 * 86_400))
        store.enforceRetention(maxItems: 500, maxAge: 30 * 86_400, now: now)
        #expect(store.count() == 0)
        #expect(blobs.allFileNames().isEmpty)
    }

    @Test func zeroMaxItemsMeansNoCountLimit() {
        for i in 0..<20 { store.ingest(.text("n\(i)")) }
        store.enforceRetention(maxItems: 0, maxAge: nil)
        #expect(store.count() == 20)
    }

    @Test func shortAgeLimitsExpireInMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        store.ingest(.text("20 min old"), now: now.addingTimeInterval(-20 * 60))
        store.ingest(.text("5 min old"), now: now.addingTimeInterval(-5 * 60))
        store.enforceRetention(maxItems: 0, maxAge: 15 * 60, now: now)
        #expect(store.allItems().map(\.text) == ["5 min old"])
    }

    @Test func labellingPinsAndIsSearchable() {
        let item = store.ingest(.text("10.0.4.12:5432"), now: Date(timeIntervalSince1970: 1))
        store.setLabel("  Staging DB host ", for: item)
        #expect(item.label == "Staging DB host")
        #expect(item.isPinned)
        #expect(item.displayTitle == "Staging DB host")
        #expect(FuzzyMatcher.score(query: "staging", in: item.searchableText) != nil)
        store.enforceRetention(maxItems: 0, maxAge: 60, now: Date(timeIntervalSince1970: 1_000_000))
        #expect(store.count() == 1)

        store.setLabel("   ", for: item)
        #expect(item.label == nil)
        #expect(item.displayTitle == "10.0.4.12:5432")
    }

    @Test func clearHistoryKeepsPinned() {
        let a = store.ingest(.text("a"))
        store.ingest(.text("b"))
        store.togglePin(a)
        store.clearHistory()
        #expect(store.allItems().map(\.text) == ["a"])
    }

    @Test func replaceTextUpdatesHashAndMergesDuplicates() {
        let a = store.ingest(.text("draft"))
        store.ingest(.text("final"))
        store.replaceText(of: a, with: "final")
        #expect(store.count() == 1)
        #expect(store.allItems().first?.id == a.id)
    }
}

struct IgnoreRuleTests {
    let ignored: Set<String> = ["com.1password.1password", "com.apple.Passwords"]

    @Test(arguments: [
        ClipboardFilter.concealedType,
        ClipboardFilter.transientType,
        ClipboardFilter.autoGeneratedType,
    ])
    func blockedPasteboardTypesAreNeverCaptured(type: String) {
        let decision = ClipboardFilter.decide(types: ["public.utf8-plain-text", type], sourceBundleID: "com.apple.Safari", ignoredBundleIDs: ignored)
        #expect(decision == .blockedType)
    }

    @Test func ignoredAppsAreSkipped() {
        let decision = ClipboardFilter.decide(types: ["public.utf8-plain-text"], sourceBundleID: "com.1password.1password", ignoredBundleIDs: ignored)
        #expect(decision == .ignoredApp)
    }

    @Test func ownWritesAreSkipped() {
        let decision = ClipboardFilter.decide(types: ["public.utf8-plain-text", ClipboardFilter.internalMarkerType], sourceBundleID: nil, ignoredBundleIDs: ignored)
        #expect(decision == .ownWrite)
    }

    @Test func normalCopiesAreCaptured() {
        let decision = ClipboardFilter.decide(types: ["public.utf8-plain-text"], sourceBundleID: "com.apple.Safari", ignoredBundleIDs: ignored)
        #expect(decision == .capture)
    }

    @Test func emptyPasteboardIsSkipped() {
        #expect(ClipboardFilter.decide(types: [], sourceBundleID: nil, ignoredBundleIDs: []) == .empty)
    }

    @Test func defaultIgnoreListContainsPasswordManagers() {
        let ids = Set(AppRef.defaultIgnored.map(\.bundleID))
        #expect(ids.isSuperset(of: ["com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords"]))
    }
}
