import Testing
import Foundation
import SwiftData
@testable import Clipboard2

struct SyncIndicatorTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func titles() {
        #expect(SyncIndicator.synced(now.addingTimeInterval(-120)).title(now: now) == "Synced · 2 min ago")
        #expect(SyncIndicator.synced(now.addingTimeInterval(-20)).title(now: now) == "Synced · just now")
        #expect(SyncIndicator.synced(now.addingTimeInterval(-3 * 3_600)).title(now: now) == "Synced · 3 h ago")
        #expect(SyncIndicator.synced(nil).title(now: now) == "Synced")
        #expect(SyncIndicator.syncing.title(now: now) == "Syncing…")
        #expect(SyncIndicator.offline.title(now: now) == "Offline")
        #expect(SyncIndicator.error("Your clock is off").title(now: now) == "Your clock is off")
        #expect(SyncIndicator.error("").title(now: now) == "Sync failed")
    }

    @Test func onlyStatesThatNeedAttentionBadgeTheIconAndOfferSyncNow() {
        #expect(SyncIndicator.synced(now).badge == nil && !SyncIndicator.synced(now).offersSyncNow)
        #expect(SyncIndicator.syncing.badge == nil && !SyncIndicator.syncing.offersSyncNow)
        #expect(SyncIndicator.offline.badge == .ring && SyncIndicator.offline.offersSyncNow)
        #expect(SyncIndicator.error("x").badge == .dot && SyncIndicator.error("x").offersSyncNow)
        #expect(!SyncIndicator.hidden.isVisible && SyncIndicator.offline.isVisible)
    }
}

@MainActor
struct SendToDeviceTests {
    let devices: [(id: String, name: String, isCurrent: Bool, lastUsedAt: Date?)] = [
        (id: "this", name: "This Mac", isCurrent: true, lastUsedAt: .now),
        (id: "pc", name: "Office PC", isCurrent: false, lastUsedAt: Date(timeIntervalSince1970: 100)),
        (id: "mbp", name: "MacBook Pro", isCurrent: false, lastUsedAt: Date(timeIntervalSince1970: 200)),
        (id: "old", name: "", isCurrent: false, lastUsedAt: nil),
    ]

    @Test func targetsAreTheOtherDevicesMostRecentlyUsedFirst() {
        let targets = DeviceTarget.others(devices)
        #expect(targets.map(\.id) == ["mbp", "pc", "old"])
        #expect(targets.last?.name == "Unnamed Device")
    }

    @Test func offeredForOneSavedItemWhenThereAreOtherDevices() throws {
        let stores = try TestStores()
        let saved = stores.store.ingest(.text("hello"))
        let targets = DeviceTarget.others(devices)

        let actions = PanelAction.sendToDeviceActions(for: saved, multiSelecting: false, targets: targets)
        #expect(actions.map { $0.title(isPinned: false) } == ["Send to MacBook Pro", "Send to Office PC", "Send to Unnamed Device"])
        #expect(actions.allSatisfy { $0.section(aiName: "AI") == "Send" })

        #expect(PanelAction.sendToDeviceActions(for: saved, multiSelecting: false, targets: []).isEmpty)
        #expect(PanelAction.sendToDeviceActions(for: saved, multiSelecting: true, targets: targets).isEmpty)
        #expect(PanelAction.sendToDeviceActions(for: nil, multiSelecting: false, targets: targets).isEmpty)
        let selectedText = ClipItem(capture: .text("selected in another app"))   // never saved
        #expect(PanelAction.sendToDeviceActions(for: selectedText, multiSelecting: false, targets: targets).isEmpty)
        #expect(DeviceTarget.others([devices[0]]).isEmpty)
    }
}

@MainActor
struct ImageTextIndexerTests {
    @Test func selectsOnlyImagesNotYetLookedAt() {
        #expect(ImageTextIndexer.needsIndexing(kind: .image, imageFile: "a.png", imageText: nil))
        #expect(!ImageTextIndexer.needsIndexing(kind: .image, imageFile: "a.png", imageText: ""))
        #expect(!ImageTextIndexer.needsIndexing(kind: .image, imageFile: "a.png", imageText: "words"))
        #expect(!ImageTextIndexer.needsIndexing(kind: .image, imageFile: nil, imageText: nil))
        #expect(!ImageTextIndexer.needsIndexing(kind: .text, imageFile: nil, imageText: nil))
        #expect(!ImageTextIndexer.needsIndexing(kind: .file, imageFile: "a.png", imageText: nil))
    }

    @Test func backlogIsNewestFirstLimitedAndSkipsQueuedItems() throws {
        let stores = try TestStores()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let old = try stores.addImage(try renderTextPNG("one"), now: t0)
        let newer = try stores.addImage(try renderTextPNG("two"), now: t0.addingTimeInterval(10))
        let newest = try stores.addImage(try renderTextPNG("three"), now: t0.addingTimeInterval(20))
        let done = try stores.addImage(try renderTextPNG("four"), now: t0.addingTimeInterval(30))
        done.imageText = ""
        stores.store.ingest(.text("not an image"))

        let items = stores.store.allItems()
        #expect(ImageTextIndexer.backlog(from: items, excluding: [], limit: 10) == [newest.id, newer.id, old.id])
        #expect(ImageTextIndexer.backlog(from: items, excluding: [newest.id], limit: 1) == [newer.id])
    }

    @Test func indexesNewAndOldImagesAndMakesThemSearchable() async throws {
        let stores = try TestStores()
        let old = try stores.addImage(try renderTextPNG("old one"))
        let indexer = ImageTextIndexer(store: stores.store, blobs: stores.store.blobs)
        indexer.backlogPause = .zero
        let calls = RecognizeCalls()
        indexer.recognize = { url in
            await calls.add(url)
            return "  Invoice 2026-104 total €42\n"
        }

        indexer.scheduleBacklog()
        await indexer.waitUntilIdle()
        #expect(old.imageText == "Invoice 2026-104 total €42")
        #expect(old.searchableText.contains("Invoice 2026-104"))
        #expect(FuzzyMatcher.score(query: "invoice 104", in: old.searchableText) != nil)

        // Already looked at: not again, even when it's "copied" once more.
        indexer.enqueue(old)
        indexer.scheduleBacklog()
        await indexer.waitUntilIdle()
        #expect(await calls.count == 1)

        // A new capture with no text is marked as looked at ("").
        indexer.recognize = { _ in nil }
        let blank = try stores.addImage(try renderTextPNG("x"))
        indexer.enqueue(blank)
        await indexer.waitUntilIdle()
        #expect(blank.imageText == "")
    }

    @Test func recognisesRealTextOnDevice() async throws {
        let stores = try TestStores()
        let item = try stores.addImage(try renderTextPNG("quarterly numbers"))
        let indexer = ImageTextIndexer(store: stores.store, blobs: stores.store.blobs)
        indexer.enqueue(item)
        await indexer.waitUntilIdle()
        #expect(item.imageText?.lowercased().contains("quarterly") == true)
    }

    @Test func longTextIsCapped() {
        let long = String(repeating: "a", count: ImageTextIndexer.maxCharacters + 50)
        #expect(ImageTextIndexer.clean(long).count == ImageTextIndexer.maxCharacters)
        #expect(ImageTextIndexer.clean("  hi \n") == "hi")
    }
}

private actor RecognizeCalls {
    private(set) var urls: [URL] = []
    var count: Int { urls.count }
    func add(_ url: URL) { urls.append(url) }
}
