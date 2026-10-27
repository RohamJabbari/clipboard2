import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A history item dragged inside Clipboard2 (its id). Declared in project.yml; never leaves the process.
    static let clipboard2Clip = UTType(exportedAs: "at.softmaze.clippy.clip-reference")
}

enum PanelDrag {
    /// What a row carries when dragged: its id for drops inside the panel, plus the content
    /// (text, the file, or the image file) for drops into other apps.
    static func provider(for item: ClipItem, blobs: BlobStore) -> NSItemProvider {
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
            if let url = item.fileURLs.first { provider.registerObject(url as NSURL, visibility: .all) }
        case .image:
            if let file = item.imageFile { provider.registerObject(blobs.url(for: file) as NSURL, visibility: .all) }
        }
        provider.suggestedName = item.label ?? (item.kind == .image ? "Image" : nil)
        return provider
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

    func body(content: Content) -> some View {
        if let item {
            content.onDrag { PanelDrag.provider(for: item, blobs: blobs) }
        } else {
            content
        }
    }
}
