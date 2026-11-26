import SwiftUI
import UniformTypeIdentifiers

/// Copies: history, newest first. Tap copies; swipe saves or deletes.
struct CopiesView: View {
    @Environment(AppModel.self) private var model
    @Binding var showSignIn: Bool
    @State private var search = ""

    private var clips: [MobileClip] {
        model.store.state.clips
            .filter { !$0.isSaved && $0.spaceId == model.personalSpaceId && matches($0, search) }
            .sorted { $0.payload.lastCopiedAt > $1.payload.lastCopiedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                if !model.isSignedIn || model.needsPassword {
                    Button {
                        showSignIn = true
                    } label: {
                        Label(model.needsPassword ? "Sign in again to keep syncing" : "Sign in to sync with your Mac",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                ForEach(clips) { clip in
                    ClipRow(clip: clip)
                        .swipeActions(edge: .leading) {
                            Button {
                                model.store.setSaved(clip.id, true)
                                Task { await model.syncNow() }
                            } label: { Label("Save", systemImage: "bookmark") }
                                .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                model.store.delete(clip.id)
                                Task { await model.syncNow() }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            }
            .overlay {
                if clips.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No copies yet" : "No results",
                                           systemImage: "doc.on.clipboard",
                                           description: Text(search.isEmpty
                                                             ? "What you copy on your Mac shows up here. Share something to Clipboard2, or paste it with the button above."
                                                             : ""))
                }
            }
            .searchable(text: $search)
            .refreshable { await model.syncNow() }
            .navigationTitle("Copies")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PasteButton(supportedContentTypes: [.image, .url, .plainText]) { providers in
                        Task { await addPasted(providers) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                }
            }
        }
    }

    private func addPasted(_ providers: [NSItemProvider]) async {
        for provider in providers {
            if let content = await IncomingContentLoader.load(provider) { model.add(content) }
        }
    }
}

/// Saved: by folder, like the Mac's Saved.
struct SavedView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        NavigationStack {
            FolderList(folderId: nil, search: search)
                .searchable(text: $search)
                .refreshable { await model.syncNow() }
                .navigationTitle("Saved")
        }
    }
}

struct FolderList: View {
    @Environment(AppModel.self) private var model
    let folderId: String?
    let search: String

    private var folders: [MobileFolder] {
        let all = model.store.state.folders.filter { $0.spaceId == model.personalSpaceId }
        let ids = Set(all.map(\.id))
        return all.filter { folder in
            // An unknown parent reads as top level (PROTOCOL.md → Folders).
            let parent = folder.payload.parent.flatMap { ids.contains($0) ? $0 : nil }
            return parent == folderId
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var clips: [MobileClip] {
        let ids = Set(model.store.state.folders.map(\.id))
        return model.store.state.clips
            .filter { clip in
                guard clip.isSaved, clip.spaceId == model.personalSpaceId, matches(clip, search) else { return false }
                if !search.isEmpty { return folderId == nil }   // searching: everything, from the top
                let folder = clip.payload.folder.flatMap { ids.contains($0) ? $0 : nil }
                return folder == folderId
            }
            .sorted { ($0.payload.pinnedAt ?? 0) > ($1.payload.pinnedAt ?? 0) }
    }

    var body: some View {
        List {
            if search.isEmpty {
                ForEach(folders) { folder in
                    NavigationLink {
                        FolderList(folderId: folder.id, search: "")
                            .navigationTitle(folder.name)
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                }
            }
            ForEach(clips) { clip in
                ClipRow(clip: clip)
                    .swipeActions(edge: .trailing) {
                        Button {
                            model.store.setSaved(clip.id, false)
                            Task { await model.syncNow() }
                        } label: { Label("Unsave", systemImage: "bookmark.slash") }
                            .tint(.orange)
                        Button(role: .destructive) {
                            model.store.delete(clip.id)
                            Task { await model.syncNow() }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
            }
        }
        .overlay {
            if folders.isEmpty && clips.isEmpty {
                ContentUnavailableView("Nothing saved here", systemImage: "bookmark",
                                       description: Text("Swipe right on a copy to save it."))
            }
        }
    }
}

struct ClipRow: View {
    @Environment(AppModel.self) private var model
    let clip: MobileClip

    var body: some View {
        Button {
            Task { await model.copy(clip) }
        } label: {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 3) {
                    Text(clip.title)
                        .lineLimit(3)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        if clip.payload.label != nil, let text = clip.payload.preview, !text.isEmpty {
                            Text(text).lineLimit(1)
                        }
                        Text(clip.lastCopiedAt, format: .relative(presentation: .named))
                        if let source = clip.payload.sourceName { Text("· \(source)") }
                        if clip.needsPush && model.isSignedIn { Image(systemName: "icloud.and.arrow.up") }
                        if clip.pushError != nil { Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { Task { await model.copy(clip) } }
            if clip.kind.isTextual, let text = clip.payload.text {
                ShareLink(item: text)
            }
            Button(clip.isSaved ? "Unsave" : "Save", systemImage: clip.isSaved ? "bookmark.slash" : "bookmark") {
                model.store.setSaved(clip.id, !clip.isSaved)
                Task { await model.syncNow() }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.store.delete(clip.id)
                Task { await model.syncNow() }
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if clip.kind == .image, let url = clip.thumbnailFile, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: clip.kind.symbol)
                .frame(width: 44, height: 44)
                .foregroundStyle(.secondary)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Search matches label, preview and text; never secret values (there are none in clips).
func matches(_ clip: MobileClip, _ search: String) -> Bool {
    let query = search.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return true }
    return [clip.payload.label, clip.payload.preview, clip.payload.text].compactMap { $0 }
        .contains { $0.localizedStandardContains(query) }
}
