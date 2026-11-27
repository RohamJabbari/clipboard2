import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The files Quick Look shows for history items: an image's PNG, a file item's own files, and
/// a temporary file for everything else: text (`.rtf` for rich text so its formatting shows,
/// `.html` when only HTML was copied, `.txt` otherwise), a link as a `.webloc`, and a colour as
/// a small `.png` swatch. Snippets, secrets, authenticators and text that looks like a
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
    /// are shown (all of them unless the user chose some). Writes temporary files as needed.
    func urls(for entries: [PanelEntry], files: (ClipItem) -> [URL] = \.fileURLs) -> [URL] {
        entries.flatMap { entry -> [URL] in
            guard let item = entry.clip else { return [] }
            switch item.kind {
            case .image:
                return imageFile(for: item).map { [$0] } ?? []
            case .file:
                return files(item).filter { fileManager.fileExists(atPath: $0.path) }
            case .text, .richText:
                return textFile(for: item).map { [$0] } ?? []
            }
        }
    }

    enum TextFormat: Equatable {
        case plain, rtf, html, webloc, swatch

        var fileExtension: String {
            switch self {
            case .plain: "txt"
            case .rtf: "rtf"
            case .html: "html"
            case .webloc: "webloc"
            case .swatch: "png"
            }
        }
    }

    /// How a text item is written, or nil when it must not be (empty, or looks like a credential).
    static func textFormat(of item: ClipItem) -> TextFormat? {
        guard item.kind.isTextual,
              !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.rtfData != nil || item.htmlData != nil
        else { return nil }
        switch ClipContent.classify(item.text) {
        case .sensitive: return nil
        case .link: return .webloc
        case .color: return .swatch
        default: break
        }
        guard item.kind == .richText else { return .plain }
        if item.rtfData?.isEmpty == false { return .rtf }
        if item.htmlData?.isEmpty == false { return .html }
        return .plain
    }

    /// Writes (or reuses) a text item's temporary file.
    func textFile(for item: ClipItem) -> URL? {
        guard let format = Self.textFormat(of: item) else { return nil }
        let data: Data?
        switch format {
        case .plain: data = Data(item.text.utf8)
        case .rtf: data = item.rtfData
        case .html: data = item.htmlData
        case .webloc:
            guard case .link(let url) = ClipContent.classify(item.text) else { return nil }
            data = Self.webloc(for: url)
        case .swatch:
            guard case .color(let color) = ClipContent.classify(item.text) else { return nil }
            data = Self.swatch(color)
        }
        guard let data else { return nil }
        return write(data, for: item, extension: format.fileExtension)
    }

    /// An image's PNG: its stored blob, or a `.png` copy when the blob's name doesn't say so
    /// (Quick Look goes by the extension).
    func imageFile(for item: ClipItem) -> URL? {
        guard let name = item.imageFile else { return nil }
        let blob = blobs.url(for: name)
        guard fileManager.fileExists(atPath: blob.path) else { return nil }
        if blob.pathExtension.lowercased() == "png" { return blob }
        guard let data = fileManager.contents(atPath: blob.path) else { return nil }
        return write(data, for: item, extension: "png")
    }

    private func write(_ data: Data, for item: ClipItem, extension ext: String) -> URL? {
        let folder = directory.appending(path: item.id.uuidString.lowercased(), directoryHint: .isDirectory)
        let url = folder.appending(path: "\(FolderSaver.baseName(for: item)).\(ext)")
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

    /// A Finder internet location file.
    static func webloc(for url: URL) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
    }

    /// A square PNG filled with `color`.
    static func swatch(_ color: RGBColor, side: Int = 512) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
                                     blue: CGFloat(color.blue) / 255, alpha: CGFloat(color.alpha)))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Deletes every temporary file.
    func removeAll() {
        try? fileManager.removeItem(at: directory)
    }
}
