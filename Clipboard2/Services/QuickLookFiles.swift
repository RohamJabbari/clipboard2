import Foundation

/// The files Quick Look shows for history items: an image's PNG blob, a file item's own files,
/// and text written to a temporary file (`.rtf` for rich text so its formatting shows, `.html`
/// when only HTML was copied, `.txt` otherwise). Snippets, secrets and text that looks like a
/// credential are never previewed, so a password is never written to disk.
///
/// Temporary files live in `directory/<item id>/<name>.<ext>`: the same item reuses its file,
/// and `removeAll()` clears the folder when Quick Look closes.
struct QuickLookFiles {
    let blobs: BlobStore
    let directory: URL
    var fileManager: FileManager = .default

    /// Whether `entry` has anything to show, without writing a file.
    func canPreview(_ entry: PanelEntry) -> Bool {
        guard let item = entry.clip else { return false }
        switch item.kind {
        case .image: return item.imageFile != nil
        case .file: return !item.fileURLs.isEmpty
        case .text, .richText: return Self.textFormat(of: item) != nil
        }
    }

    /// The URLs to preview for `entries`, in order. `files` picks which files of a file item
    /// are shown (all of them unless the user chose some). Writes text items' temporary files.
    func urls(for entries: [PanelEntry], files: (ClipItem) -> [URL] = \.fileURLs) -> [URL] {
        entries.flatMap { entry -> [URL] in
            guard let item = entry.clip else { return [] }
            switch item.kind {
            case .image:
                guard let name = item.imageFile else { return [] }
                let url = blobs.url(for: name)
                return fileManager.fileExists(atPath: url.path) ? [url] : []
            case .file:
                return files(item).filter { fileManager.fileExists(atPath: $0.path) }
            case .text, .richText:
                return textFile(for: item).map { [$0] } ?? []
            }
        }
    }

    enum TextFormat: Equatable {
        case plain, rtf, html

        var fileExtension: String {
            switch self {
            case .plain: "txt"
            case .rtf: "rtf"
            case .html: "html"
            }
        }
    }

    /// How a text item is written, or nil when it must not be (empty, or looks like a credential).
    static func textFormat(of item: ClipItem) -> TextFormat? {
        guard item.kind.isTextual,
              !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.rtfData != nil || item.htmlData != nil
        else { return nil }
        if case .sensitive = ClipContent.classify(item.text) { return nil }
        guard item.kind == .richText else { return .plain }
        if item.rtfData?.isEmpty == false { return .rtf }
        if item.htmlData?.isEmpty == false { return .html }
        return .plain
    }

    /// Writes (or reuses) the item's temporary file.
    func textFile(for item: ClipItem) -> URL? {
        guard let format = Self.textFormat(of: item) else { return nil }
        let data: Data = switch format {
        case .plain: Data(item.text.utf8)
        case .rtf: item.rtfData ?? Data()
        case .html: item.htmlData ?? Data()
        }
        let folder = directory.appending(path: item.id.uuidString.lowercased(), directoryHint: .isDirectory)
        let url = folder.appending(path: "\(FolderSaver.baseName(for: item)).\(format.fileExtension)")
        if fileManager.contents(atPath: url.path) == data { return url }
        do {
            // A new name or format (the label or text changed): start the item's folder afresh.
            try? fileManager.removeItem(at: folder)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Log.panel.error("Couldn't write a Quick Look file: \(error.localizedDescription)")
            return nil
        }
    }

    /// Deletes every temporary file.
    func removeAll() {
        try? fileManager.removeItem(at: directory)
    }
}
