import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

nonisolated enum CaptureProcessor {
    /// Runs off the main actor: hashing and image encoding can take tens of milliseconds.
    @concurrent
    static func process(_ raw: RawCapture, blobs: BlobStore) async -> ProcessedCapture? {
        switch raw.kind {
        case .text, .richText:
            return ProcessedCapture(
                kind: raw.kind,
                text: raw.text,
                preview: TextPreview.make(raw.text),
                rtfData: raw.rtfData,
                htmlData: raw.htmlData,
                fileURLs: [],
                source: raw.source,
                hash: ContentHasher.hash(text: raw.text),
                byteCount: raw.text.utf8.count + (raw.rtfData?.count ?? 0) + (raw.htmlData?.count ?? 0)
            )

        case .file:
            let names = raw.fileURLs.map(\.lastPathComponent)
            return ProcessedCapture(
                kind: .file,
                text: raw.fileURLs.map(\.path).joined(separator: "\n"),
                preview: names.count == 1 ? names[0] : "\(names.count) files: " + names.joined(separator: ", "),
                fileURLs: raw.fileURLs,
                source: raw.source,
                hash: ContentHasher.hash(fileURLs: raw.fileURLs)
            )

        case .image:
            guard let data = raw.imageData, let output = ImageProcessor.process(data) else { return nil }
            let base = UUID().uuidString
            let full = "\(base).png"
            let thumb = "\(base)-thumb.png"
            do {
                try blobs.write(output.png, name: full)
                try blobs.write(output.thumbnail, name: thumb)
            } catch {
                blobs.delete(full)
                blobs.delete(thumb)
                Log.capture.error("Failed writing image blob: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            return ProcessedCapture(
                kind: .image,
                text: "",
                preview: "Image \(output.width)×\(output.height)",
                fileURLs: [],
                source: raw.source,
                hash: output.pixelHash ?? ContentHasher.hash(imageData: data),
                imageFile: full,
                thumbnailFile: thumb,
                imageWidth: output.width,
                imageHeight: output.height,
                byteCount: output.png.count
            )
        }
    }
}

nonisolated enum DedupeMigration {
    /// Re-hashes stored images by pixels (off the main actor; decoding large PNGs is slow).
    @concurrent
    static func pixelHashes(for images: [(id: UUID, url: URL)]) async -> [UUID: String] {
        var result: [UUID: String] = [:]
        for image in images {
            if Task.isCancelled { break }
            if let hash = ContentHasher.pixelHash(fileURL: image.url) { result[image.id] = hash }
        }
        return result
    }
}
