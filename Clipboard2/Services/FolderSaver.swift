import Foundation

/// Writes history items into a folder as ordinary files: text as a UTF-8 `.txt`, images as `.png`,
/// file items as copies of their files and folders. Names never overwrite: Finder-style "Name 2.txt".
struct FolderSaver {
    let blobs: BlobStore
    var fileManager: FileManager = .default

    struct Outcome {
        var saved: [URL] = []
        /// One short reason per item or file that couldn't be written.
        var failures: [String] = []
    }

    /// Saves each item; one that fails doesn't stop the rest. `files` picks which files of a file
    /// item are written (all of them unless the user chose some).
    func save(_ items: [ClipItem], to folder: URL, files: (ClipItem) -> [URL] = \.fileURLs) -> Outcome {
        var outcome = Outcome()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            outcome.failures.append("“\(folder.lastPathComponent)” doesn't exist")
            return outcome
        }
        for item in items {
            switch item.kind {
            case .text, .richText:
                let url = Self.availableURL(in: folder, name: Self.baseName(for: item), extension: "txt", fileManager: fileManager)
                record(&outcome, url, name: url.lastPathComponent) { try Data(item.text.utf8).write(to: url, options: .withoutOverwriting) }
            case .image:
                guard let file = item.imageFile else {
                    outcome.failures.append("The image is missing")
                    continue
                }
                let source = blobs.url(for: file)
                guard fileManager.fileExists(atPath: source.path) else {
                    outcome.failures.append("The image is missing")
                    continue
                }
                let url = Self.availableURL(in: folder, name: Self.baseName(for: item), extension: "png", fileManager: fileManager)
                record(&outcome, url, name: url.lastPathComponent) { try fileManager.copyItem(at: source, to: url) }
            case .file:
                for source in files(item) {
                    guard fileManager.fileExists(atPath: source.path) else {
                        outcome.failures.append("“\(source.lastPathComponent)” no longer exists")
                        continue
                    }
                    let url = Self.availableURL(in: folder, name: source.deletingPathExtension().lastPathComponent,
                                                extension: source.pathExtension, fileManager: fileManager)
                    record(&outcome, url, name: source.lastPathComponent) { try fileManager.copyItem(at: source, to: url) }
                }
            }
        }
        return outcome
    }

    private func record(_ outcome: inout Outcome, _ url: URL, name: String, _ write: () throws -> Void) {
        do {
            try write()
            outcome.saved.append(url)
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            outcome.failures.append("No permission to write to “\(url.deletingLastPathComponent().lastPathComponent)”")
        } catch {
            Log.store.error("Couldn't save \(name, privacy: .private): \(error.localizedDescription)")
            outcome.failures.append("Couldn't write “\(name)”")
        }
    }

    // MARK: Naming

    static let maxNameLength = 40

    /// The label if there is one, else the first words of the text; "Text" or "Image" otherwise.
    static func baseName(for item: ClipItem) -> String {
        if let label = item.label, let name = sanitized(label) { return name }
        switch item.kind {
        case .image: return "Image"
        case .text, .richText: return sanitized(item.text) ?? "Text"
        case .file: return item.fileURLs.first?.deletingPathExtension().lastPathComponent ?? "File"
        }
    }

    /// One line, no path separators, no leading dot (hidden file), cut at a word near `maxLength`.
    static func sanitized(_ raw: String, maxLength: Int = maxNameLength) -> String? {
        let words = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
            .filter { !$0.isEmpty }
        var name = words.joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > maxLength {
            let cut = String(name.prefix(maxLength))
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= maxLength / 2 {
                name = String(cut[..<space])
            } else {
                name = cut
            }
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// `name.ext`, or the first free "name 2.ext", "name 3.ext"… as Finder numbers copies.
    static func availableURL(in folder: URL, name: String, extension ext: String, fileManager: FileManager = .default) -> URL {
        func candidate(_ number: Int) -> URL {
            let base = number == 1 ? name : "\(name) \(number)"
            return folder.appending(path: ext.isEmpty ? base : "\(base).\(ext)")
        }
        var number = 1
        while fileManager.fileExists(atPath: candidate(number).path) { number += 1 }
        return candidate(number)
    }
}
