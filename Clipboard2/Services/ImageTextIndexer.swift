import Foundation
import SwiftData
import ImageIO

/// Recognises text in image items on this Mac (Vision, nothing is uploaded) so search finds
/// screenshots by their words. New captures go first; older images are worked through in the
/// background, one at a time with a pause in between, never on the main thread.
final class ImageTextIndexer {
    /// Recognised text kept per image; screenshots of long documents can produce a lot.
    nonisolated static let maxCharacters = 20_000
    /// Older images picked up per pass (each maintenance run starts another pass if needed).
    static let backlogBatch = 100

    private let store: ClipStore
    private let blobs: BlobStore
    private var urgent: [UUID] = []
    private var backlog: [UUID] = []
    private var queued: Set<UUID> = []
    private var worker: Task<Void, Never>?

    /// Pause after each older image, so a big history is indexed gently.
    var backlogPause: Duration = .seconds(1)
    /// Reads the text in the image file at a URL; replaceable in tests.
    var recognize: @Sendable (URL) async -> String? = { await ImageTextIndexer.recognizeText(at: $0) }

    init(store: ClipStore, blobs: BlobStore) {
        self.store = store
        self.blobs = blobs
    }

    // MARK: Selection

    /// Only images that have a file and haven't been looked at yet.
    nonisolated static func needsIndexing(kind: ClipKind, imageFile: String?, imageText: String?) -> Bool {
        kind == .image && imageText == nil && !(imageFile ?? "").isEmpty
    }

    static func needsIndexing(_ item: ClipItem) -> Bool {
        needsIndexing(kind: item.kind, imageFile: item.imageFile, imageText: item.imageText)
    }

    /// Up to `limit` items still to index, newest first, skipping ids already queued.
    static func backlog(from items: [ClipItem], excluding queued: Set<UUID>, limit: Int) -> [UUID] {
        Array(items
            .filter { needsIndexing($0) && !queued.contains($0.id) }
            .sorted { $0.lastCopiedAt > $1.lastCopiedAt }
            .prefix(limit)
            .map(\.id))
    }

    /// Trimmed and capped.
    nonisolated static func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > maxCharacters ? String(trimmed.prefix(maxCharacters)) : trimmed
    }

    // MARK: Queue

    /// A new capture: indexed right away, ahead of the backlog.
    func enqueue(_ item: ClipItem) {
        guard Self.needsIndexing(item) else { return }
        if queued.contains(item.id) { backlog.removeAll { $0 == item.id } } else { queued.insert(item.id) }
        urgent.append(item.id)
        startIfNeeded()
    }

    /// Picks up older images that haven't been indexed (at launch and from maintenance).
    func scheduleBacklog() {
        guard backlog.count < Self.backlogBatch else { return }
        let imageKind = ClipKind.image.rawValue
        let descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.kindRaw == imageKind && $0.imageText == nil })
        let candidates = (try? store.context.fetch(descriptor)) ?? []
        let ids = Self.backlog(from: candidates, excluding: queued, limit: Self.backlogBatch - backlog.count)
        guard !ids.isEmpty else { return }
        backlog += ids
        queued.formUnion(ids)
        startIfNeeded()
    }

    /// Waits until everything queued so far is done (tests).
    func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.run()
            self?.worker = nil
        }
    }

    private func next() -> (id: UUID, isBacklog: Bool)? {
        if !urgent.isEmpty { return (urgent.removeFirst(), false) }
        if !backlog.isEmpty { return (backlog.removeFirst(), true) }
        return nil
    }

    private func run() async {
        while let entry = next() {
            let (id, isBacklog) = entry
            if Task.isCancelled { return }
            defer { queued.remove(id) }
            guard let item = store.item(withID: id), Self.needsIndexing(item), let file = item.imageFile else { continue }
            let text = await recognize(blobs.url(for: file))
            // The item may have been deleted or replaced while Vision was working.
            guard let live = store.item(withID: id), live.imageFile == file, live.imageText == nil else { continue }
            live.imageText = Self.clean(text ?? "")
            // Saved directly: the recognised text isn't part of what sync sends, so there's nothing to push.
            do { try store.context.save() } catch {
                Log.store.error("Saving image text failed: \(error.localizedDescription, privacy: .public)")
            }
            if isBacklog && backlogPause > .zero { try? await Task.sleep(for: backlogPause) }
        }
    }

    // MARK: Recognition

    /// Off the main actor; nil if the file can't be read.
    @concurrent
    nonisolated static func recognizeText(at url: URL) async -> String? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            return try? ScreenTextCapture.recognizeTextNow(in: image)
        }
    }
}
