import Foundation

// MARK: - Mapping to and from the local models (the shared payloads are in Core/Sync/SyncPayload.swift)

extension ClipPayload {
    /// The payload for a local item. `blobs` are the server ids of its image and thumbnail, or of its files.
    init(item: ClipItem, imageBlob: String? = nil, thumbBlob: String? = nil, fileBlobs: [FileBlob] = []) {
        self.init(kind: item.kind.rawValue, text: item.text, preview: item.preview, isPinned: item.isPinned,
                  copyCount: item.copyCount, createdAt: item.createdAt.syncMillis,
                  lastCopiedAt: item.lastCopiedAt.syncMillis, contentHash: item.contentHash)
        rtf = item.rtfData
        html = item.htmlData
        files = item.fileURLStrings.isEmpty ? nil : item.fileURLStrings
        if item.kind == .file && !fileBlobs.isEmpty { self.fileBlobs = fileBlobs }
        if item.kind == .image {
            self.imageBlob = imageBlob
            self.thumbBlob = thumbBlob
            imageWidth = item.imageWidth
            imageHeight = item.imageHeight
        }
        byteCount = item.byteCount > 0 ? item.byteCount : nil
        sourceId = item.sourceBundleID
        sourceName = item.sourceAppName
        pinnedAt = item.isPinned ? item.pinnedAt?.syncMillis : nil
        label = item.label
        folder = item.isPinned ? item.folderID?.uuidString.lowercased() : nil
    }

    /// Without rich text, for items whose RTF/HTML would push the ciphertext past the limit.
    var withoutRichText: ClipPayload {
        var copy = self
        copy.rtf = nil
        copy.html = nil
        if copy.kind == ClipKind.richText.rawValue { copy.kind = ClipKind.text.rawValue }
        return copy
    }

    /// Writes the payload into a local item. Image files are set by the caller. A file clip stays a
    /// file clip when its contents arrived (`localFiles`); otherwise it arrives as the names, as text.
    /// Times are clamped to `arrivedAt`, so an item can't claim to come from the future.
    func apply(to item: ClipItem, localFiles: [URL] = [], arrivedAt: Date = .now) {
        var kind = ClipKind(rawValue: self.kind) ?? .text
        item.text = text ?? ""
        item.preview = preview ?? TextPreview.make(item.text)
        item.contentHash = contentHash
        item.fileURLStrings = []
        if kind == .file && !localFiles.isEmpty {
            item.fileURLStrings = localFiles.map(\.absoluteString)
            item.text = localFiles.map(\.path).joined(separator: "\n")
            if preview == nil { item.preview = TextPreview.make(localFiles.map(\.lastPathComponent).joined(separator: ", ")) }
        } else if kind == .file {
            kind = .text
            if item.text.isEmpty { item.text = (files ?? []).compactMap { URL(string: $0)?.path }.joined(separator: "\n") }
            if item.preview.isEmpty { item.preview = TextPreview.make(item.text) }
            item.contentHash = ContentHasher.hash(text: item.text)
        }
        if kind == .image && imageBlob == nil { kind = .text }
        item.kind = kind
        item.rtfData = kind == .richText ? rtf : nil
        item.htmlData = kind == .richText ? html : nil
        item.imageWidth = imageWidth ?? 0
        item.imageHeight = imageHeight ?? 0
        item.byteCount = byteCount ?? item.text.utf8.count
        item.sourceBundleID = sourceId
        item.sourceAppName = sourceName
        item.isPinned = isPinned
        item.pinnedAt = isPinned ? pinnedAt.map(Date.init(syncMillis:)) ?? item.pinnedAt ?? .now : nil
        item.label = label
        // Kept even when that folder isn't here (yet): the clip shows at the root until it is.
        item.folderID = isPinned ? folder.flatMap(UUID.init(uuidString:)) : nil
        item.copyCount = max(1, copyCount)
        let arrived = arrivedAt.syncMillis
        item.createdAt = Date(syncMillis: min(createdAt, arrived))
        item.lastCopiedAt = Date(syncMillis: min(lastCopiedAt, arrived))
    }
}

extension SnippetPayload {
    init(snippet: Snippet) {
        self.init(name: snippet.name, keyword: snippet.keyword, body: snippet.body,
                  createdAt: snippet.createdAt.syncMillis, updatedAt: snippet.updatedAt.syncMillis)
    }

    func apply(to snippet: Snippet, arrivedAt: Date = .now) {
        let arrived = arrivedAt.syncMillis
        snippet.name = name
        snippet.keyword = keyword
        snippet.body = body
        snippet.createdAt = Date(syncMillis: min(createdAt, arrived))
        snippet.updatedAt = Date(syncMillis: min(updatedAt, arrived))
    }
}

extension FolderPayload {
    init(folder: ClipFolder) {
        self.init(name: folder.name, label: folder.label, parent: folder.parentID?.uuidString.lowercased(),
                  createdAt: folder.createdAt.syncMillis, updatedAt: folder.updatedAt.syncMillis)
    }

    func apply(to folder: ClipFolder, arrivedAt: Date = .now) {
        let arrived = arrivedAt.syncMillis
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.name = trimmed.isEmpty ? "Folder" : trimmed
        folder.label = label?.isEmpty == true ? nil : label
        // Kept even when that folder isn't here (yet): it shows at the top level until it is.
        folder.parentID = parent.flatMap(UUID.init(uuidString:))
        folder.createdAt = Date(syncMillis: min(createdAt, arrived))
        folder.updatedAt = Date(syncMillis: min(updatedAt, arrived))
    }
}

extension ClipFolder {
    convenience init(syncID: UUID, spaceID: String?) {
        self.init(name: "")
        id = syncID
        self.spaceID = spaceID
    }
}

extension ClipItem {
    /// An empty item with a given id, filled in from a sync payload.
    convenience init(syncID: UUID, spaceID: String?) {
        self.init(capture: .text(""))
        id = syncID
        self.spaceID = spaceID
    }
}

extension Snippet {
    convenience init(syncID: UUID, spaceID: String?) {
        self.init(name: "")
        id = syncID
        self.spaceID = spaceID
    }
}

extension SecretPayload {
    init(ref: SecretRef, value: String, notes: String? = nil, now: Date = .now) {
        self.init(name: ref.name, value: value, createdAt: (ref.createdAt ?? now).syncMillis,
                  folder: ref.folderID?.uuidString.lowercased(), username: ref.username, urls: ref.urls, notes: notes,
                  origin: ref.originID)
    }
}
