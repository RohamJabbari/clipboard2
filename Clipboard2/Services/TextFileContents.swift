import Foundation
import UniformTypeIdentifiers

/// What a copied file holds, when it's text: read for the preview pane (the first ~1 MB),
/// pretty-printed when it's valid JSON, and hidden when it looks like a key or password. Also
/// names and writes the copies Clipboard2 keeps of edited and renamed files. Pure, apart from
/// reading and writing the files it's given.
nonisolated enum TextFileContents {
    /// The most bytes read for the preview; longer files show this much, with a note.
    static let byteLimit = 1_000_000
    /// How much of a file without a known text extension is sniffed before it counts as text.
    static let sniffLength = 8_192

    /// Extensions that are text whatever `UTType` says (code, data, markup, config, logs).
    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdown", "mkd", "log", "csv", "tsv", "json", "jsonl", "ndjson",
        "geojson", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf", "properties", "html", "htm", "xhtml",
        "css", "scss", "sass", "less", "js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx", "py", "pyw",
        "rb", "swift", "java", "kt", "kts", "go", "rs", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm",
        "cs", "fs", "php", "pl", "pm", "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "sql", "graphql",
        "gql", "vue", "svelte", "dart", "scala", "lua", "r", "gradle", "groovy", "tex", "srt", "vtt", "svg",
        "csproj", "sln", "xaml", "plist", "strings", "gitignore", "gitattributes", "editorconfig", "dockerfile",
        "makefile", "cmake", "proto", "tf", "hcl", "nix", "ex", "exs", "erl", "hs", "clj", "elm", "jl",
        "rst", "adoc", "org", "diff", "patch", "lock", "env", "sample", "example",
    ]

    /// Prose reads better in the system font; everything else (code, data, logs) is monospaced.
    static let proseExtensions: Set<String> = ["txt", "text", "md", "markdown", "mdown", "mkd", "rst", "adoc", "org", ""]

    /// File names that hold keys and passwords: never shown, whatever they contain.
    static let secretNames: Set<String> = [
        ".env", ".netrc", ".npmrc", ".pypirc", ".pgpass", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
        "credentials", ".git-credentials", "authorized_keys",
    ]
    static let secretExtensions: Set<String> = ["pem", "key", "p8", "p12", "pfx", "keystore", "jks", "asc", "gpg", "kdbx", "env"]

    struct Loaded: Equatable, Sendable {
        /// The file's text as read (what editing starts from).
        var text: String
        /// What the preview shows: `text`, or pretty-printed when it's valid JSON.
        var display: String
        /// Only the first `byteLimit` bytes were read.
        var isTruncated: Bool
        /// The file's full size in bytes.
        var byteCount: Int
        var isMonospaced: Bool
        var isPrettyJSON: Bool { display != text }
    }

    enum Contents: Equatable, Sendable {
        case text(Loaded)
        /// Nothing at the path any more (Clipboard2 keeps only the path of a copied file).
        case missing
        /// A folder, a binary file, or text in an encoding we don't read.
        case notText
        /// Looks like a key or password: never shown.
        case hidden
        /// There, but can't be read (permissions).
        case unreadable
    }

    // MARK: Detection

    static func isTextExtension(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        if textExtensions.contains(ext) || textExtensions.contains(name.hasPrefix(".") ? String(name.dropFirst()) : name) {
            return true
        }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        // `.text` alone would take RTF and Word files, whose raw bytes aren't what anyone wants to read.
        return [UTType.plainText, .sourceCode, .json, .xml, .yaml, .commaSeparatedText, .tabSeparatedText, .html, .script]
            .contains { type.conforms(to: $0) }
    }

    /// A file whose name says it holds secrets (`.env`, `id_rsa`, `*.pem`…).
    static func isSecretName(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if secretNames.contains(name) || name.hasPrefix(".env.") { return true }
        return secretExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether the bytes read as text: no NUL bytes (unless UTF-16 with a BOM) and valid UTF-8,
    /// ignoring a sequence cut off at the end.
    static func looksLikeText(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return true }
        if data.contains(0) { return false }
        return String(data: trimmingPartialUTF8(data), encoding: .utf8) != nil
    }

    /// Cheap check for the ⌘K list and ⌘E: a regular file of up to `byteLimit` bytes that reads
    /// as text and isn't named like a secret. The full read happens when editing starts.
    static func canEdit(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let size = regularFileSize(url, fileManager: fileManager), size <= byteLimit, !isSecretName(url) else { return false }
        if isTextExtension(url) { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return looksLikeText((try? handle.read(upToCount: sniffLength)) ?? Data())
    }

    /// The size of a regular file (not a folder or package), or nil when there's none at `url`.
    static func regularFileSize(_ url: URL, fileManager: FileManager = .default) -> Int? {
        var isDirectory: ObjCBool = false
        guard url.isFileURL, fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: Loading

    /// Reads up to `limit` bytes of `url` for the preview.
    static func load(_ url: URL, limit: Int = byteLimit, fileManager: FileManager = .default) -> Contents {
        var isDirectory: ObjCBool = false
        guard url.isFileURL, fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .missing }
        if isDirectory.boolValue { return .notText }
        let known = isTextExtension(url)
        guard let size = regularFileSize(url, fileManager: fileManager) else { return .notText }
        // Unknown types only count as text when they're small enough to read whole.
        if !known && size > limit { return .notText }
        if isSecretName(url) { return .hidden }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) ?? Data() else { return .unreadable }
        let truncated = size > data.count
        guard let text = decode(data, truncated: truncated, lenient: known) else { return .notText }
        if SensitiveText.detect(text) != nil { return .hidden }
        let ext = url.pathExtension.lowercased()
        var display = text
        if !truncated, ["json", "geojson"].contains(ext), let pretty = Transform.jsonPrettify.apply(text) {
            display = pretty
        }
        return .text(Loaded(text: text, display: display, isTruncated: truncated, byteCount: size,
                            isMonospaced: !proseExtensions.contains(ext)))
    }

    /// Reads off the main actor (a 1 MB file takes a moment).
    @concurrent
    static func loadInBackground(_ url: URL) async -> Contents {
        load(url)
    }

    /// UTF-8 (BOM dropped) or UTF-16 with a BOM; Windows Latin 1 too when `lenient` (a known
    /// text extension). Nil for anything else, or bytes with NULs.
    static func decode(_ data: Data, truncated: Bool = false, lenient: Bool = false) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            let even = data.prefix(data.count - data.count % 2)
            return String(data: even, encoding: .utf16)
        }
        if data.contains(0) { return nil }
        var bytes = truncated ? trimmingPartialUTF8(data) : data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return lenient ? String(data: bytes, encoding: .windowsCP1252) : nil
    }

    /// Drops a UTF-8 sequence cut off by the read limit.
    static func trimmingPartialUTF8(_ data: Data) -> Data {
        let tail = [UInt8](data.suffix(4))
        var index = tail.count - 1
        var continuation = 0
        while index >= 0, tail[index] & 0xC0 == 0x80 {
            continuation += 1
            index -= 1
        }
        guard index >= 0, tail[index] & 0xC0 == 0xC0 else { return data }   // ends in ASCII (or isn't UTF-8)
        let lead = tail[index]
        let needed = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2
        return continuation + 1 < needed ? Data(data.prefix(data.count - continuation - 1)) : data
    }

    // MARK: Names

    /// `‹name›-edited.‹ext›`, then `-edited-2`, `-edited-3`… until it's not in `taken` (compared
    /// case-insensitively, as the Mac's file system does). Editing an edited copy doesn't stack
    /// suffixes: `notes-edited.txt` becomes `notes-edited-2.txt`.
    static func editedName(for name: String, taken: Set<String> = []) -> String {
        let (base, ext) = split(name)
        let stem = stripEditedSuffix(base)
        let lowered = Set(taken.map { $0.lowercased() })
        var number = 1
        while true {
            let candidate = join(stem + (number == 1 ? "-edited" : "-edited-\(number)"), ext)
            if !lowered.contains(candidate.lowercased()) && candidate.lowercased() != name.lowercased() { return candidate }
            number += 1
        }
    }

    /// A name typed by the user, made safe for one path component: slashes and colons become
    /// dashes, control characters go, and it fits in 255 bytes. Nil when nothing usable is left.
    static func sanitizedName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        while name.utf8.count > 255 {
            let (base, ext) = split(name)
            if base.count > 1 { name = join(String(base.dropLast()), ext) } else { name = String(name.dropLast()) }
        }
        return name
    }

    /// "notes.txt" → ("notes", "txt"); ".env" → (".env", ""); "archive.tar.gz" → ("archive.tar", "gz").
    static func split(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    private static func join(_ base: String, _ ext: String) -> String {
        ext.isEmpty ? base : "\(base).\(ext)"
    }

    private static func stripEditedSuffix(_ base: String) -> String {
        guard let range = base.range(of: #"-edited(-\d+)?$"#, options: .regularExpression), range.lowerBound != base.startIndex
        else { return base }
        return String(base[..<range.lowerBound])
    }

    // MARK: Writing copies

    /// Writes `contents` as `folder/name`, creating the folder. Returns the file's URL.
    static func write(_ contents: Data, named name: String, into folder: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        try contents.write(to: url, options: .atomic)
        return url
    }

    /// Copies `source` (a file or folder) to `folder/name`. The original isn't touched.
    static func copy(_ source: URL, named name: String, into folder: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        try fileManager.copyItem(at: source, to: url)
        return url
    }
}
