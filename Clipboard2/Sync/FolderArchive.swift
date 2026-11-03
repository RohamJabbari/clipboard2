import CryptoKit
import Foundation

/// Folders sync as one zip blob each (PROTOCOL.md, "Files"). The zip is written by hand rather
/// than with `ditto` or `zip`: those keep symlinks or follow them, and don't flag UTF-8 names,
/// so Windows would read "Ünï.txt" as mojibake.
///
/// Archives are cached by folder path and a summary of its contents, so an unchanged folder
/// yields the same bytes, the same size, and therefore the same file key: nothing re-uploads.
nonisolated enum FolderArchive {
    /// What a received archive may unpack to, so a hostile zip can't fill the disk.
    static let maxEntries = 20_000
    static let maxUnpackedBytes: Int64 = 2 << 30

    static var directory: URL { AppPaths.supportDirectory.appending(path: "Folder Archives", directoryHint: .isDirectory) }

    /// What changes when anything in the folder does: entries, bytes, and the latest change.
    struct Summary: Equatable {
        var entries = 0
        var bytes: Int64 = 0
        var latest: Date = .distantPast

        /// An upper bound on the zip's size, known without writing it: headers are well under 1 KB.
        var estimatedArchiveSize: Int64 { bytes + Int64(entries) * 1024 }
    }

    static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
            .map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
    }

    /// Regular files and folders under `folder`, by path relative to it; symlinks are skipped.
    static func entries(of folder: URL) -> [(url: URL, path: String, isFolder: Bool, size: Int64, modified: Date)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: keys)
        else { return [] }
        var found: [(url: URL, path: String, isFolder: Bool, size: Int64, modified: Date)] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isFolder = values.isDirectory == true
            guard isFolder || values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(root + "/") else { continue }
            found.append((url, String(full.dropFirst(root.count + 1)), isFolder,
                          Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
        return found.sorted { $0.path < $1.path }
    }

    static func summary(of folder: URL) -> Summary {
        var summary = Summary()
        summary.latest = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        for entry in entries(of: folder) {
            summary.entries += 1
            summary.bytes += entry.size
            summary.latest = max(summary.latest, entry.modified)
        }
        return summary
    }

    /// The folder's size, to compare with a limit, without walking more of it than needed.
    static func estimatedArchiveSize(of folder: URL, stoppingAbove limit: Int64) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: Array(keys))
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: keys)
            total += 1024 + (values?.isRegularFile == true ? Int64(values?.fileSize ?? 0) : 0)
            if total > limit { break }
        }
        return total
    }

    /// The cached archive of `folder` as it is now, if there is one.
    static func cached(for folder: URL) -> URL? {
        let url = archiveURL(for: folder, summary: summary(of: folder))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The archive of `folder`, written now unless cached. Nil when it can't be written or
    /// would exceed `limit` bytes. Off the main actor: this reads the whole folder.
    @concurrent
    static func prepare(_ folder: URL, limit: Int) async -> URL? {
        let summary = summary(of: folder)
        guard summary.estimatedArchiveSize <= limit else { return nil }
        let url = archiveURL(for: folder, summary: summary)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            sweep()
            let partial = directory.appending(path: "\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: partial) }
            try write(folder, to: partial)
            removeArchives(of: folder)
            try FileManager.default.moveItem(at: partial, to: url)
            return url
        } catch {
            Log.sync.error("Can't archive a folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Caches a received archive as the archive of the folder it was unpacked to, so the
    /// received item's file key matches what arrived and it isn't sent back.
    static func adopt(_ data: Data, for folder: URL) {
        let url = archiveURL(for: folder, summary: summary(of: folder))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removeArchives(of: folder)
        try? data.write(to: url)
    }

    private static func pathKey(_ folder: URL) -> String {
        hex(SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))).prefix(24).description
    }

    private static func archiveURL(for folder: URL, summary: Summary) -> URL {
        let state = "\(summary.entries)|\(summary.bytes)|\(Int64(summary.latest.timeIntervalSince1970 * 1000))"
        return directory.appending(path: "\(pathKey(folder))-\(hex(SHA256.hash(data: Data(state.utf8))).prefix(16)).zip")
    }

    private static func removeArchives(of folder: URL) {
        let prefix = pathKey(folder) + "-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// Archives are only needed while their items are being sent, and a lost one is simply
    /// rewritten: a week-old one is dropped rather than kept next to its folder forever.
    private static func sweep(olderThan age: TimeInterval = 7 * 24 * 3600) {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in urls {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
            if modified.timeIntervalSinceNow < -age { try? fm.removeItem(at: url) }
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    // MARK: Writing

    /// A zip of the folder's contents (no top folder), UTF-8 names, deflated where that helps.
    static func write(_ folder: URL, to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var central = Data()
        var offset: UInt32 = 0
        var count = 0
        for entry in entries(of: folder) {
            // Composed, as Windows and most zip tools expect; APFS hands out names decomposed.
            let name = Data((entry.path.precomposedStringWithCanonicalMapping + (entry.isFolder ? "/" : "")).utf8)
            var stored = Data()
            var method: UInt16 = 0
            var crc: UInt32 = 0
            var size: UInt32 = 0
            if !entry.isFolder {
                let data = try Data(contentsOf: entry.url, options: .mappedIfSafe)
                crc = CRC32.checksum(data)
                size = UInt32(data.count)
                if let deflated = try? (data as NSData).compressed(using: .zlib) as Data, deflated.count < data.count {
                    (stored, method) = (deflated, 8)
                } else {
                    stored = data
                }
            }
            let (time, date) = dosDateTime(entry.modified)
            var local = Data()
            local.le32(0x0403_4b50); local.le16(20); local.le16(0x0800); local.le16(method)
            local.le16(time); local.le16(date); local.le32(crc)
            local.le32(UInt32(stored.count)); local.le32(size)
            local.le16(UInt16(name.count)); local.le16(0)
            local.append(name)
            try out.write(contentsOf: local)
            try out.write(contentsOf: stored)

            central.le32(0x0201_4b50); central.le16(0x031e); central.le16(20); central.le16(0x0800); central.le16(method)
            central.le16(time); central.le16(date); central.le32(crc)
            central.le32(UInt32(stored.count)); central.le32(size)
            central.le16(UInt16(name.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(entry.isFolder ? 0x41ed_0010 : 0x81a4_0000)   // drwxr-xr-x / -rw-r--r--
            central.le32(offset)
            central.append(name)

            offset += UInt32(local.count + stored.count)
            count += 1
        }
        var end = Data()
        end.le32(0x0605_4b50); end.le16(0); end.le16(0)
        end.le16(UInt16(count)); end.le16(UInt16(count))
        end.le32(UInt32(central.count)); end.le32(offset); end.le16(0)
        try out.write(contentsOf: central)
        try out.write(contentsOf: end)
    }

    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let year: Int = max((c.year ?? 1980) - 1980, 0), month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let time: Int = hour << 11 | minute << 5 | second / 2
        let days: Int = year << 9 | month << 5 | day
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: days))
    }

    // MARK: Unpacking

    /// Unpacks a received archive into `folder` (which must not exist yet). Refuses archives
    /// with absolute or `..` paths or that unpack too large; symlinks in them are dropped.
    static func unpack(_ archive: URL, into folder: URL) -> Bool {
        let fm = FileManager.default
        // An empty folder is a bare end record, which zipinfo calls an error.
        if (try? fm.attributesOfItem(atPath: archive.path)[.size] as? Int) == 22 {
            return (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        }
        guard let listing = run("/usr/bin/zipinfo", ["-1", archive.path]),
              let totals = run("/usr/bin/zipinfo", ["-t", archive.path]) else { return false }
        let names = listing.split(separator: "\n").map(String.init)
        guard names.count <= maxEntries,
              !names.contains(where: { $0.hasPrefix("/") || $0.split(separator: "/").contains("..") || $0.contains("\\") }),
              let unpacked = totals.split(separator: " ").dropFirst(2).first.flatMap({ Int64($0) }),
              unpacked <= maxUnpackedBytes
        else {
            Log.sync.notice("Refused to unpack a received folder")
            return false
        }
        let staging = folder.deletingLastPathComponent().appending(path: ".unpacking-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        guard (try? fm.createDirectory(at: staging, withIntermediateDirectories: true)) != nil,
              run("/usr/bin/unzip", ["-qq", "-o", archive.path, "-d", staging.path]) != nil
        else { return false }
        // unzip makes symlinks last, so none was written through; none is kept either.
        if let walker = fm.enumerator(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in walker
            where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                try? fm.removeItem(at: url)
            }
        }
        return (try? fm.moveItem(at: staging, to: folder)) != nil
    }

    /// Runs a tool and returns its output, or nil when it fails.
    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: output, as: UTF8.self) : nil
    }
}

nonisolated enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    nonisolated mutating func le16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    nonisolated mutating func le32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
