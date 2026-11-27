import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// Shared by the Mac and iOS apps: content hashes (duplicates merge across devices only when
// every client hashes the same way), PNG and thumbnail encoding, and previews.

nonisolated enum ContentHasher {
    /// Text and rich text share a namespace so the same words copied with and without
    /// formatting dedupe into one item.
    /// Leading/trailing whitespace is ignored, so "hello" and "hello\n" are one item.
    static func hash(text: String) -> String {
        "text:" + sha256(Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }
    static func hash(fileURLs: [URL]) -> String {
        "file:" + sha256(Data(fileURLs.map(\.path).joined(separator: "\n").utf8))
    }
    static func hash(imageData: Data) -> String { "image:" + sha256(imageData) }

    /// Hashes decoded pixels rather than file bytes: apps re-encode the same picture with
    /// different metadata/compression each time it's copied, which defeats a byte hash.
    static func pixelHash(of image: CGImage) -> String? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let digest = SHA256.hash(data: UnsafeRawBufferPointer(start: pixels, count: width * height * 4))
        return "image:px:\(width)x\(height):" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func pixelHash(fileURL: URL) -> String? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            return pixelHash(of: image)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum ImageProcessor {
    struct Output: Sendable {
        var png: Data
        var thumbnail: Data
        var width: Int
        var height: Int
        var pixelHash: String?
    }

    static func process(_ data: Data, thumbnailMaxPixels: Int = 480) -> Output? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let isPNG = (CGImageSourceGetType(source) as String?) == UTType.png.identifier
        guard let png = isPNG ? data : encodePNG(image) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let thumb = encodePNG(thumbImage)
        else { return nil }

        return Output(png: png, thumbnail: thumb, width: image.width, height: image.height,
                      pixelHash: ContentHasher.pixelHash(of: image))
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

nonisolated enum TextPreview {
    static func make(_ text: String, limit: Int = 300) -> String {
        var out = ""
        out.reserveCapacity(min(limit, text.count))
        var lastWasSpace = false
        for ch in text.prefix(limit * 4) {
            if ch.isWhitespace {
                if !lastWasSpace && !out.isEmpty { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
            if out.count >= limit { break }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
