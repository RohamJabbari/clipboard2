import AppKit
import SwiftData
import Testing
@testable import Clipboard2

/// Quick panel v3: size, place, Keep Open, Quick Look files and pasting part of a text.
@MainActor
struct PanelSizeAndPlaceTests {
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 944)

    @Test func maximumIsTheSmallerOfTheCapAndNinetyPercent() {
        #expect(PanelLayout.maximumSize(visible: CGRect(x: 0, y: 0, width: 3000, height: 2000)) == CGSize(width: 1280, height: 900))
        #expect(PanelLayout.maximumSize(visible: CGRect(x: 0, y: 0, width: 1000, height: 700)) == CGSize(width: 900, height: 630))
    }

    @Test func sizesAreClampedToTheRange() {
        #expect(PanelLayout.clamp(CGSize(width: 200, height: 100), visible: laptop) == CGSize(width: 640, height: 400))
        #expect(PanelLayout.clamp(CGSize(width: 5000, height: 5000), visible: laptop) == CGSize(width: 1280, height: 849))
    }

    @Test func firstOpenIsSixtyPercentOfTheScreen() {
        let size = PanelLayout.size(remembered: nil, seed: nil, visible: laptop)
        #expect(size == CGSize(width: (1512 * 0.6).rounded(), height: (944 * 0.6).rounded()))
        // Small screens still get the minimum.
        #expect(PanelLayout.size(remembered: nil, seed: nil, visible: CGRect(x: 0, y: 0, width: 1000, height: 600))
                == CGSize(width: 640, height: 400))
    }

    @Test func oldSizeSettingOnlySeedsAndRememberedSizeWins() {
        #expect(PanelLayout.size(remembered: nil, seed: PanelSize.large.size, visible: laptop) == CGSize(width: 920, height: 580))
        #expect(PanelLayout.size(remembered: CGSize(width: 1000, height: 700), seed: PanelSize.large.size, visible: laptop)
                == CGSize(width: 1000, height: 700))
        // Remembered on a big display, clamped again on a smaller one.
        #expect(PanelLayout.size(remembered: CGSize(width: 1250, height: 880), seed: nil, visible: CGRect(x: 0, y: 0, width: 1280, height: 775))
                == CGSize(width: 1152, height: 697))
    }

    @Test func previewNarrowsFirstAndListKeepsItsMinimum() {
        #expect(PanelLayout.listWidth(panelWidth: 1000) == 440)
        #expect(PanelLayout.listWidth(panelWidth: 760) == 334)
        for width in stride(from: CGFloat(640), through: 1280, by: 10) {
            let list = PanelLayout.listWidth(panelWidth: width)
            #expect(list >= 320, "\(width)")
            #expect(width - list >= 260, "\(width)")
        }
        // Under 760 the list stays put while the preview gives way.
        #expect(PanelLayout.listWidth(panelWidth: 700) == PanelLayout.listWidth(panelWidth: 759))
    }

    @Test func rememberedPlaceIsUsedOnlyWhileFullyVisible() {
        let size = CGSize(width: 800, height: 500)
        let frame = PanelLayout.restoredFrame(topLeft: CGPoint(x: 100, y: 900), size: size, visible: laptop)
        #expect(frame == CGRect(x: 100, y: 400, width: 800, height: 500))
        #expect(PanelLayout.restoredFrame(topLeft: CGPoint(x: 1000, y: 900), size: size, visible: laptop) == nil)
        #expect(PanelLayout.restoredFrame(topLeft: CGPoint(x: 100, y: 300), size: size, visible: laptop) == nil)
        #expect(PanelLayout.restoredFrame(topLeft: nil, size: size, visible: laptop) == nil)
        // A place on another screen's coordinates is off this one.
        #expect(PanelLayout.restoredFrame(topLeft: CGPoint(x: -1500, y: 900), size: size, visible: laptop) == nil)
    }

    @Test func resizingMovesOnlyTheDraggedEdgesWithinTheLimits() {
        let start = CGRect(x: 300, y: 200, width: 800, height: 500)
        let wider = PanelLayout.resize(start, edges: .left, by: CGVector(dx: -100, dy: 0), visible: laptop)
        #expect(wider == CGRect(x: 200, y: 200, width: 900, height: 500))
        let tiny = PanelLayout.resize(start, edges: [.bottom, .right], by: CGVector(dx: -600, dy: 600), visible: laptop)
        #expect(tiny.size == PanelLayout.minSize)
        #expect(tiny.minX == start.minX && tiny.maxY == start.maxY)   // the top-left corner stays
        let tall = PanelLayout.resize(start, edges: .top, by: CGVector(dx: 50, dy: 900), visible: laptop)
        #expect(tall.height == 849 && tall.minY == start.minY && tall.width == start.width)
    }

    @Test func geometryAtARememberedPlaceStillEmergesFromItsEdge() {
        let frame = CGRect(x: 200, y: 150, width: 800, height: 500)
        let g = PanelGeometry.make(origin: .top, frame: frame, visible: laptop)
        #expect(g.panel == frame)
        #expect(g.startOffset == CGVector(dx: 0, dy: laptop.maxY - frame.maxY))
        #expect(g.window.contains(frame))
        #expect(g.restingWindow == frame.insetBy(dx: -PanelGeometry.shadowMargin, dy: -PanelGeometry.shadowMargin))
    }

    @Test func quickLookIsCentredOnThePanelWithinEightyPercent() {
        let panel = CGRect(x: 300, y: 200, width: 900, height: 560)
        let frame = PanelLayout.quickLookFrame(panel: panel, visible: laptop)
        #expect(abs(frame.midX - panel.midX) <= 1 && abs(frame.midY - panel.midY) <= 1)
        #expect(frame.width <= laptop.width * 0.8 + 1 && frame.height <= laptop.height * 0.8 + 1)
        // Near an edge it stays on screen.
        let edge = PanelLayout.quickLookFrame(panel: CGRect(x: 0, y: 0, width: 640, height: 400), visible: laptop)
        #expect(laptop.contains(edge))
    }

    @Test func preferencesRememberSizeAndPlacesAndSeedFromTheOldSetting() throws {
        let defaults = try #require(UserDefaults(suiteName: "PanelV3-\(UUID())"))
        var prefs = Preferences(defaults: defaults)
        #expect(prefs.panelSizeSeed == nil)
        #expect(prefs.panelFrameSize == nil)

        defaults.set("large", forKey: Preferences.Key.panelSize)
        prefs = Preferences(defaults: defaults)
        #expect(prefs.panelSizeSeed == CGSize(width: 920, height: 580))

        prefs.panelFrameSize = CGSize(width: 1001, height: 702)
        prefs.setPanelPosition(CGPoint(x: 40, y: 800), forScreen: "A")
        prefs = Preferences(defaults: defaults)
        #expect(prefs.panelFrameSize == CGSize(width: 1001, height: 702))
        #expect(prefs.panelPosition(forScreen: "A") == CGPoint(x: 40, y: 800))
        #expect(prefs.panelPosition(forScreen: "B") == nil)

        prefs.resetPanelPositions()
        #expect(Preferences(defaults: defaults).panelPosition(forScreen: "A") == nil)
        #expect(Preferences(defaults: defaults).panelFrameSize == CGSize(width: 1001, height: 702))
    }
}

@MainActor
struct QuickLookEveryItemTests {
    let store: ClipStore
    let files: QuickLookFiles
    let root = FileManager.default.temporaryDirectory.appending(path: "Clipboard2Tests-\(UUID().uuidString)")
    let container: ModelContainer

    init() throws {
        let schema = AppEnvironment.schema
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        store = ClipStore(context: container.mainContext, blobs: BlobStore(directory: root.appending(path: "blobs")))
        files = QuickLookFiles(blobs: store.blobs, directory: root.appending(path: "Quick Look"))
    }

    @Test func linksBecomeWeblocFiles() throws {
        let item = store.ingest(.text("https://example.com/docs?q=1"))
        let url = try #require(files.urls(for: [.clip(item)]).first)
        #expect(url.pathExtension == "webloc")
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        #expect(plist["URL"] == "https://example.com/docs?q=1")
    }

    @Test func coloursBecomeASwatch() throws {
        let item = store.ingest(.text("#FF8800"))
        let url = try #require(files.urls(for: [.clip(item)]).first)
        #expect(url.pathExtension == "png")
        let image = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        var pixel = [Int](repeating: 0, count: 4)
        image.getPixel(&pixel, atX: 10, y: 10)
        #expect(Array(pixel.prefix(3)) == [0xFF, 0x88, 0x00])
    }

    @Test func transientTextIsPreviewedToo() throws {
        let selection = ClipItem(capture: .text("Selected in another app", source: nil))
        #expect(selection.isTransient)
        #expect(files.canPreview(.clip(selection)))
        let url = try #require(files.urls(for: [.clip(selection)]).first)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Selected in another app")
    }

    @Test func imagesWithoutAPNGNameGetAPNGCopy() throws {
        let name = UUID().uuidString   // no extension
        try store.blobs.write(Data([0x89, 0x50, 0x4E, 0x47]), name: name)
        var capture = ProcessedCapture.text("")
        capture.kind = .image
        capture.imageFile = name
        capture.hash = UUID().uuidString
        let item = store.ingest(capture)
        let url = try #require(files.urls(for: [.clip(item)]).first)
        #expect(url.pathExtension == "png")
        #expect(url.path.hasPrefix(files.directory.path))
    }

    @Test func secretsAndAuthenticatorsAreNeverPreviewed() {
        let secret = SecretRef(id: UUID().uuidString, name: "DB password", createdAt: nil)
        let credential = store.ingest(.text("sk-proj-4f9a2c7d1e8b6a3f9c2d7e1b"))
        #expect(!files.canPreview(.secret(secret)))
        #expect(!files.canPreview(.clip(credential)))
        #expect(files.urls(for: [.secret(secret), .clip(credential)]).isEmpty)
    }
}

@MainActor
struct PartialPasteAndKeepOpenTests {
    let env = AppEnvironment.shared
    let model: PanelViewModel

    init() {
        model = PanelViewModel(env: env)
    }

    private func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func selectedTextIsTheExactRange() {
        typealias C = SelectableText.Coordinator
        #expect(C.selectedText("Hello brave world", range: NSRange(location: 6, length: 5)) == "brave")
        #expect(C.selectedText("Hello", range: NSRange(location: 2, length: 0)) == nil)
        #expect(C.selectedText("Hello", range: NSRange(location: 3, length: 9)) == nil)
        #expect(C.selectedText("Grüße 👋 dir", range: NSRange(location: 6, length: 2)) == "👋")
    }

    @Test func changingTheRowClearsTheSelection() {
        let tag = UUID().uuidString
        let items = [env.store.ingest(.text("part-a \(tag)")), env.store.ingest(.text("part-b \(tag)"))]
        defer { items.forEach(env.store.delete) }
        model.query = tag
        model.selectedID = PanelEntry.clip(items[0]).id
        model.previewSelection = "part"
        model.selectedID = PanelEntry.clip(items[1]).id
        #expect(model.previewSelection == nil)
    }

    @Test func escapeClearsTheSelectionBeforeClosing() {
        var closed = false
        model.onClose = { closed = true }
        model.previewSelection = "part"
        #expect(model.handleKeyDown(key(KeyCode.escape, "\u{1b}")))
        #expect(model.previewSelection == nil && !closed)
        #expect(model.handleKeyDown(key(KeyCode.escape, "\u{1b}")))
        #expect(closed)
    }

    @Test func keptOpenEscapeAtTheTopLevelDoesNotClose() {
        var closed = false
        model.onClose = { closed = true }
        model.isPinned = true
        #expect(model.handleKeyDown(key(KeyCode.escape, "\u{1b}")))
        #expect(!closed)
        model.isPinned = false
        #expect(model.handleKeyDown(key(KeyCode.escape, "\u{1b}")))
        #expect(closed)
    }

    @Test func partialPasteIsPlainTextAndNotANewHistoryItem() throws {
        let pasteboard = NSPasteboard(name: .init("Clipboard2Tests-\(UUID().uuidString)"))
        let defaults = try #require(UserDefaults(suiteName: "Clipboard2Tests-\(UUID().uuidString)"))
        let paste = PasteService(store: env.store, prefs: Preferences(defaults: defaults), tracker: FrontmostAppTracker(), pasteboard: pasteboard)
        paste.write(text: "just this part")
        let types = (pasteboard.types ?? []).map(\.rawValue)
        #expect(pasteboard.string(forType: .string) == "just this part")
        #expect(!types.contains(NSPasteboard.PasteboardType.rtf.rawValue))
        #expect(ClipboardFilter.decide(types: types, sourceBundleID: nil, ignoredBundleIDs: []) == .ownWrite)
    }
}
