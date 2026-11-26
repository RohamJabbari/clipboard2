import Foundation
import UniformTypeIdentifiers

/// Turns what the share sheet or a paste hands over (item providers) into `IncomingContent`.
/// Images and files are copied out right away: the URLs a provider gives are only valid briefly.
nonisolated enum IncomingContentLoader {
    static func load(_ provider: NSItemProvider) async -> IncomingContent? {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await loadData(provider, type: .image) {
            return .image(data)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(provider), url.scheme != "file" {
            return .url(url)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadText(provider), !text.isEmpty {
            return .text(text)
        }
        // Anything else is a file (PDFs, documents, archives…).
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        if let type = types.first(where: { $0.conforms(to: .data) || $0.conforms(to: .content) }) ?? types.first,
           let file = await copyFile(provider, type: type) {
            return .files([file])
        }
        return nil
    }

    /// Several providers: images and texts one clip each, all files together in one file clip.
    static func loadAll(_ providers: [NSItemProvider]) async -> [IncomingContent] {
        var contents: [IncomingContent] = []
        var files: [URL] = []
        for provider in providers {
            switch await load(provider) {
            case .files(let urls): files += urls
            case let content?: contents.append(content)
            case nil: break
            }
        }
        if !files.isEmpty { contents.append(.files(files)) }
        return contents
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }

    /// Copies the provider's file into a temporary folder of ours, keeping its name.
    private static func copyFile(_ provider: NSItemProvider, type: UTType) async -> URL? {
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                let name = suggestedName.map { name in
                    url.pathExtension.isEmpty || name.hasSuffix("." + url.pathExtension) ? name : name + "." + url.pathExtension
                } ?? url.lastPathComponent
                let destination = folder.appending(path: name)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
