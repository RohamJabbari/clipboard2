import Foundation
import ImageIO

/// Something to add to Copies, from the share extension or the app's paste button.
nonisolated enum IncomingContent: Sendable {
    case text(String)
    case url(URL)
    case image(Data)
    /// Files already copied somewhere this process can read.
    case files([URL])
}

/// How a new clip is filed: in history (Copies), or saved with a label and folder.
nonisolated struct SaveOptions: Sendable, Equatable {
    var save = false
    var label: String?
    var folderId: String?

    init(save: Bool = false, label: String? = nil, folderId: String? = nil) {
        self.save = save
        self.label = label
        self.folderId = folderId
    }
}

nonisolated enum ClipImporterError: LocalizedError {
    case unreadableImage
    case noFiles

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "This image couldn't be read."
        case .noFiles: "There was nothing to add."
        }
    }
}

/// Builds clips the way the Mac does (same content hashes, previews and payload fields), so a
/// text shared on the iPhone and copied on the Mac merge into one item.
nonisolated enum ClipImporter {
    static var sourceName: String { "iPhone" }

    static func makeClip(_ content: IncomingContent, spaceId: String, options: SaveOptions,
                         now: Date = .now, id: String = SyncCrypto.newID()) throws -> MobileClip {
        let ms = now.syncMillis
        var clip: MobileClip
        switch content {
        case .text(let text):
            var payload = ClipPayload(kind: ClipKind.text.rawValue, text: text, preview: TextPreview.make(text),
                                      createdAt: ms, lastCopiedAt: ms, contentHash: ContentHasher.hash(text: text))
            payload.byteCount = text.utf8.count
            clip = MobileClip(id: id, spaceId: spaceId, payload: payload, updatedAt: ms)
        case .url(let url):
            return try makeClip(.text(url.absoluteString), spaceId: spaceId, options: options, now: now, id: id)
        case .image(let data):
            guard let output = ImageProcessor.process(downscaled(data)) else { throw ClipImporterError.unreadableImage }
            let full = "local-\(id).png", thumb = "local-\(id)-thumb.png"
            try output.png.write(to: SharedContainer.blobsDirectory.appending(path: full), options: .atomic)
            try output.thumbnail.write(to: SharedContainer.blobsDirectory.appending(path: thumb), options: .atomic)
            var payload = ClipPayload(kind: ClipKind.image.rawValue, text: "", preview: "Image \(output.width)×\(output.height)",
                                      createdAt: ms, lastCopiedAt: ms,
                                      contentHash: output.pixelHash ?? ContentHasher.hash(imageData: data))
            payload.imageWidth = output.width
            payload.imageHeight = output.height
            payload.byteCount = output.png.count
            clip = MobileClip(id: id, spaceId: spaceId, payload: payload, updatedAt: ms, localImage: full, localThumb: thumb)
        case .files(let urls):
            let regular = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .prefix(SyncConfig.maxFilesPerItem)
            guard !regular.isEmpty else { throw ClipImporterError.noFiles }
            let folder = SharedContainer.filesDirectory.appending(path: id, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var files: [LocalFile] = []
            var used = Set<String>()
            for url in regular {
                var name = url.lastPathComponent
                while !used.insert(name.lowercased()).inserted { name = "1 " + name }
                let destination = folder.appending(path: name)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: url, to: destination)
                let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                files.append(LocalFile(name: name, path: "\(id)/\(name)", size: size))
            }
            let names = files.map(\.name)
            var payload = ClipPayload(kind: ClipKind.file.rawValue, text: names.joined(separator: "\n"),
                                      preview: names.count == 1 ? names[0] : "\(names.count) files: " + names.joined(separator: ", "),
                                      createdAt: ms, lastCopiedAt: ms,
                                      contentHash: ContentHasher.hash(fileURLs: files.map { folder.appending(path: $0.name) }))
            payload.byteCount = files.reduce(0) { $0 + $1.size }
            clip = MobileClip(id: id, spaceId: spaceId, payload: payload, updatedAt: ms, localFiles: files)
        }
        clip.payload.sourceName = sourceName
        apply(options, to: &clip.payload, now: now)
        clip.needsPush = true
        return clip
    }

    /// Camera photos (48 MP) decoded at full size would blow the share extension's memory limit
    /// (about 120 MB), and as PNG they'd be far over what's worth syncing: larger images are
    /// scaled to this many pixels on the long side first.
    static let maxImagePixels = 4096

    static func downscaled(_ data: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > maxImagePixels
        else { return data }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let png = ImageProcessor.encodePNG(image) else { return data }
        return png
    }

    static func apply(_ options: SaveOptions, to payload: inout ClipPayload, now: Date) {
        guard options.save else { return }
        payload.isPinned = true
        payload.pinnedAt = now.syncMillis
        let label = options.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        payload.label = label?.isEmpty == false ? label : nil
        payload.folder = options.folderId
    }
}

// MARK: - Local changes

extension MobileStore {
    /// Adds a clip, merging it into an item of the same space with the same content (PROTOCOL.md →
    /// Duplicates): that one moves to the top instead.
    @discardableResult
    func add(_ clip: MobileClip, options: SaveOptions = SaveOptions(), now: Date = .now) -> MobileClip {
        update { state in
            if let index = state.clips.firstIndex(where: { $0.spaceId == clip.spaceId && $0.payload.contentHash == clip.payload.contentHash
                                                           && !clip.payload.contentHash.isEmpty }) {
                var existing = state.clips[index]
                existing.payload.lastCopiedAt = now.syncMillis
                existing.payload.copyCount += 1
                ClipImporter.apply(options, to: &existing.payload, now: now)
                existing.updatedAt = max(now.syncMillis, existing.updatedAt + 1)
                existing.needsPush = true
                existing.trimmed = false
                existing.pushError = nil
                state.clips[index] = existing
                MobileStore.deleteFiles(of: clip)
                return existing
            }
            state.upsert(clip)
            state.trimHistory()
            return clip
        }
    }

    /// Changes a clip and marks it for the next push.
    func change(_ id: String, now: Date = .now, _ edit: (inout ClipPayload) -> Void) {
        update { state in
            guard let index = state.clips.firstIndex(where: { $0.id == id }) else { return }
            var clip = state.clips[index]
            edit(&clip.payload)
            guard clip.payload != state.clips[index].payload else { return }
            clip.updatedAt = max(now.syncMillis, clip.updatedAt + 1)
            clip.needsPush = true
            clip.trimmed = false
            clip.pushError = nil
            state.clips[index] = clip
        }
    }

    /// Save to (or remove from) Saved. Removing clears the folder (PROTOCOL.md → Folders).
    func setSaved(_ id: String, _ saved: Bool, label: String? = nil, folderId: String? = nil, now: Date = .now) {
        change(id, now: now) { payload in
            if saved {
                ClipImporter.apply(SaveOptions(save: true, label: label ?? payload.label, folderId: folderId ?? payload.folder),
                                   to: &payload, now: now)
            } else {
                payload.isPinned = false
                payload.pinnedAt = nil
                payload.folder = nil
            }
        }
    }

    /// Copying from Clipboard2 counts as using it again: it moves to the top everywhere.
    func markCopied(_ id: String, now: Date = .now) {
        change(id, now: now) { payload in
            payload.lastCopiedAt = now.syncMillis
            payload.copyCount += 1
        }
    }

    func delete(_ id: String, now: Date = .now) {
        update { state in
            guard let clip = state.clip(id) else { return }
            // Never synced (or trimmed by the server already): nothing to delete there.
            if clip.fingerprint != nil {
                state.deletes.append(PendingDelete(id: id, spaceId: clip.spaceId, at: max(now.syncMillis, clip.updatedAt + 1)))
            }
            state.remove(id)
        }
    }
}
