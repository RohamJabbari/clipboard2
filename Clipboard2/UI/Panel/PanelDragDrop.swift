import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A history item dragged inside Clipboard2 (its id). Declared in project.yml; never leaves the process.
    static let clipboard2Clip = UTType(exportedAs: "at.softmaze.clippy.clip-reference")
}

enum PanelDrag {
    /// What a row carries when dragged: its id for drops inside the panel, plus the content
    /// (text, the file, or the image file) for drops into other apps. A SwiftUI drag carries one
    /// item, so a file item with several files is dragged by `MultiFileDragSource` instead.
    static func provider(for item: ClipItem, blobs: BlobStore, files: [URL]? = nil) -> NSItemProvider {
        let provider = NSItemProvider()
        let id = Data(item.id.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.clipboard2Clip.identifier, visibility: .ownProcess) { completion in
            completion(id, nil)
            return nil
        }
        switch item.kind {
        case .text, .richText:
            provider.registerObject(item.text as NSString, visibility: .all)
        case .file:
            if let url = (files ?? item.fileURLs).first { provider.registerObject(url as NSURL, visibility: .all) }
        case .image:
            if let file = item.imageFile { provider.registerObject(blobs.url(for: file) as NSURL, visibility: .all) }
        }
        provider.suggestedName = item.label ?? (item.kind == .image ? "Image" : nil)
        return provider
    }

    /// The files a drag of a file item carries: the ones picked in the preview, or all of them.
    static func files(for item: ClipItem, picked: [URL]?) -> [URL] {
        (picked ?? item.fileURLs).filter(\.isFileURL)
    }

    /// Whether dragging `item` needs one drag item per file (an AppKit drag).
    static func needsMultiFileDrag(_ item: ClipItem) -> Bool {
        item.kind == .file && item.fileURLs.filter(\.isFileURL).count > 1
    }

    /// One pasteboard item per file, so Finder and other apps get every file. The first also
    /// carries the clip id, so the drag still works on a group chip.
    static func pasteboardItems(for item: ClipItem, files: [URL]) -> [NSPasteboardItem] {
        files.enumerated().map { index, url in
            let entry = NSPasteboardItem()
            entry.setString(url.absoluteString, forType: .fileURL)
            if index == 0 {
                entry.setData(Data(item.id.uuidString.utf8), forType: NSPasteboard.PasteboardType(UTType.clipboard2Clip.identifier))
            }
            return entry
        }
    }

    static func loadClipID(from providers: [NSItemProvider]) async -> UUID? {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.clipboard2Clip.identifier) }) else {
            return nil
        }
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.clipboard2Clip.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        return data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(UUID.init(uuidString:))
    }

    static func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let url, url.isFileURL { urls.append(url) }
        }
        return urls
    }
}

/// Drops on the result list (files from Finder → history) or on a group chip (a history item or
/// files → shared to that group). Highlights while something droppable hovers.
struct PanelDropDelegate: DropDelegate {
    enum Target: Equatable {
        case list
        case group(String)
    }

    let target: Target
    let model: PanelViewModel
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        let isClip = info.hasItemsConforming(to: [.clipboard2Clip])
        switch target {
        case .list: return !isClip && info.hasItemsConforming(to: [.fileURL])
        case .group: return isClip || info.hasItemsConforming(to: [.fileURL])
        }
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        setTargeted(true)
    }

    func dropExited(info: DropInfo) {
        setTargeted(false)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        setTargeted(false)
        guard validateDrop(info: info) else { return false }
        let model = model
        switch target {
        case .list:
            let providers = info.itemProviders(for: [.fileURL])
            Task { model.dropFiles(await PanelDrag.loadFileURLs(from: providers)) }
        case .group(let groupID):
            if info.hasItemsConforming(to: [.clipboard2Clip]) {
                let providers = info.itemProviders(for: [.clipboard2Clip])
                Task {
                    guard let id = await PanelDrag.loadClipID(from: providers) else { return }
                    model.dropClip(id: id, onGroup: groupID)
                }
            } else {
                let providers = info.itemProviders(for: [.fileURL])
                Task { model.dropFiles(await PanelDrag.loadFileURLs(from: providers), onGroup: groupID) }
            }
        }
        return true
    }

    private func setTargeted(_ value: Bool) {
        guard isTargeted != value else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            isTargeted = value
        } else {
            withAnimation(.snappy(duration: 0.15)) { isTargeted = value }
        }
    }
}

/// Makes a saved history row draggable (onto a group chip, or out into another app).
struct ClipDragSource: ViewModifier {
    let item: ClipItem?
    let blobs: BlobStore
    /// The files picked in the preview, read when the drag starts.
    var pickedFiles: (ClipItem) -> [URL]? = { _ in nil }
    @State private var fileDrag = MultiFileDragSource()

    func body(content: Content) -> some View {
        if let item, PanelDrag.needsMultiFileDrag(item) {
            content.gesture(DragGesture(minimumDistance: 4).onChanged { _ in startFileDrag(item) })
        } else if let item {
            content.onDrag { PanelDrag.provider(for: item, blobs: blobs, files: pickedFiles(item)) }
        } else {
            content
        }
    }

    private func startFileDrag(_ item: ClipItem) {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDragged else { return }
        let files = PanelDrag.files(for: item, picked: pickedFiles(item))
        guard !files.isEmpty else { return }
        fileDrag.begin(PanelDrag.pasteboardItems(for: item, files: files), files: files, event: event)
    }
}

/// Drags several files at once: an AppKit dragging session with one item per file, which a
/// SwiftUI drag (a single item provider) can't do.
final class MultiFileDragSource: NSObject, NSDraggingSource {
    /// A session is running; the gesture keeps reporting changes until the mouse comes up.
    private(set) var isDragging = false

    func begin(_ items: [NSPasteboardItem], files: [URL], event: NSEvent) {
        guard !isDragging, let view = event.window?.contentView else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        let side: CGFloat = 32
        // Fanned out a little, so it reads as a stack of files.
        let dragged = zip(items, files).enumerated().map { index, pair in
            let item = NSDraggingItem(pasteboardWriter: pair.0)
            let offset = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(NSRect(x: point.x - side / 2 + offset, y: point.y - side / 2 - offset, width: side, height: side),
                                  contents: NSWorkspace.shared.icon(forFile: pair.1.path))
            return item
        }
        isDragging = true
        let session = view.beginDraggingSession(with: dragged, event: event, source: self)
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
    }
}
