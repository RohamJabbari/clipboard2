import SwiftUI

struct PreviewPane: View {
    let entry: PanelEntry
    var onEditSecret: ((SecretRef) -> Void)?
    /// When set, the account's own text items are editable in place.
    var model: PanelViewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            metadata
                .padding(12)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch entry {
        case .clip(let item):
            switch item.kind {
            case .text, .richText:
                if let model, model.isEditable(item) {
                    ClipEditor(item: item, model: model)
                } else {
                    TextPreviewView(text: item.text)
                }
            case .image:
                VStack(spacing: 0) {
                    ImagePreviewView(item: item)
                    if let text = item.imageText, !text.isEmpty {
                        Divider()
                        ImageTextView(text: text)
                    }
                }
            case .file:
                FilePreviewView(urls: item.fileURLs)
            }
        case .snippet(let snippet):
            TextPreviewView(text: snippet.body)
        case .secret(let ref):
            SecretPreviewView(ref: ref, onEdit: onEditSecret.map { edit in { edit(ref) } })
        }
    }

    @ViewBuilder
    private var metadata: some View {
        switch entry {
        case .clip(let item):
            VStack(alignment: .leading, spacing: 6) {
                if let label = item.label {
                    LabeledContent("Label", value: label)
                }
                if let source = item.source {
                    HStack(spacing: 6) {
                        Image(nsImage: AppIconCache.icon(for: source.bundleID))
                            .resizable()
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        Text(source.name)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Copied from \(source.name)")
                }
                LabeledContent("Copied", value: item.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
                if item.copyCount > 1 {
                    LabeledContent("Times copied", value: "\(item.copyCount)")
                }
                LabeledContent("Type", value: detailType(item))
                LabeledContent("Expires", value: expiryText(item))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .snippet(let snippet):
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Snippet", value: snippet.name)
                if !snippet.keyword.isEmpty { LabeledContent("Keyword", value: snippet.keyword) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .secret(let ref):
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Stored in", value: "Keychain")
                if let created = ref.createdAt {
                    LabeledContent("Added", value: created.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func expiryText(_ item: ClipItem) -> String {
        if item.isPinned { return "Never (pinned)" }
        guard let date = item.expiryDate(maxAge: AppEnvironment.shared.prefs.maxAge) else { return "Never" }
        if date <= .now { return "Now" }
        return date.formatted(.relative(presentation: .named))
    }

    private func detailType(_ item: ClipItem) -> String {
        switch item.kind {
        case .text, .richText:
            let chars = item.text.count
            let words = item.text.split { $0.isWhitespace || $0.isNewline }.count
            return "\(item.kind.displayName) · \(chars) characters · \(words) words"
        case .image:
            return "Image · \(item.imageWidth)×\(item.imageHeight) · \(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))"
        case .file:
            return item.fileURLs.count == 1 ? "File" : "\(item.fileURLs.count) Files"
        }
    }
}

struct TextPreviewView: View {
    let text: String
    static let displayLimit = 20_000

    var body: some View {
        ScrollView {
            Text(text.count > Self.displayLimit ? String(text.prefix(Self.displayLimit)) + "\n…" : text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .accessibilityLabel("Preview")
    }
}

struct ImagePreviewView: View {
    let item: ClipItem
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Image preview, \(item.imageWidth) by \(item.imageHeight) pixels")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item.id) {
            image = nil
            guard let name = item.imageFile else { return }
            let url = AppEnvironment.shared.blobs.url(for: name)
            image = await Self.load(url)
        }
    }

    @concurrent
    private static func load(_ url: URL) async -> NSImage? {
        NSImage(contentsOf: url)
    }
}

/// The words recognised in an image, selectable, under the picture.
struct ImageTextView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Text in image", systemImage: "text.viewfinder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            // Short text sits at its own height; longer text scrolls inside a fixed strip.
            ViewThatFits(in: .vertical) {
                textBlock(text)
                ScrollView { textBlock(text) }
                    .frame(height: Self.maxHeight)
            }
            .frame(maxHeight: Self.maxHeight)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .help("Recognised on this Mac, so search finds this image by its words")
    }

    private static let maxHeight: CGFloat = 110

    private func textBlock(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct FilePreviewView: View {
    let urls: [URL]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(urls, id: \.self) { url in
                    HStack(spacing: 10) {
                        Image(nsImage: FileIconCache.icon(for: url))
                            .resizable()
                            .frame(width: 32, height: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(url.deletingLastPathComponent().path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }
}

struct SecretPreviewView: View {
    let ref: SecretRef
    var onEdit: (() -> Void)?
    @Environment(AppEnvironment.self) private var env
    @State private var revealed: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: env.secrets.isUnlocked ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(ref.name).font(.title3.weight(.semibold))
            if let revealed {
                Text(revealed)
                    .font(.title3.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                Button("Hide") { self.revealed = nil }
            } else {
                Text("••••••••••")
                    .font(.title3.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Hidden value")
                HStack {
                    Button("Show") {
                        Task { revealed = await env.secrets.reveal(ref, reason: "show “\(ref.name)”") }
                    }
                    if let onEdit { Button("Edit", action: onEdit) }
                }
            }
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            SecretUnlockControl(secrets: env.secrets)
                .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: ref.id) { revealed = nil }
        .onDisappear { revealed = nil }
    }

    private var hint: String {
        let clear = env.prefs.secretClearSeconds > 0
            ? " The clipboard clears after \(env.prefs.secretClearSeconds) seconds."
            : ""
        if env.secrets.isUnlocked { return "Unlocked — press Return to paste." + clear }
        return "Press Return to paste. You'll confirm with Touch ID or your password." + clear
    }
}

/// Shown instead of the single-item preview when several rows are selected.
struct MultiSelectionPreview: View {
    let clips: [ClipItem]
    let totalSelected: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(clips.count) items selected").font(.headline)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(clips) { item in
                        HStack(spacing: 8) {
                            ClipIconView(item: item, size: 20)
                            Text(item.preview.isEmpty ? item.kind.displayName : item.preview)
                                .lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if clips.allSatisfy(\.kind.isTextual) {
            parts.append("Return pastes them as one text, one item per line, in list order.")
        } else if clips.allSatisfy({ $0.kind == .file }) {
            parts.append("Return pastes all files together.")
        } else {
            parts.append("Return pastes them as separate items; apps that accept only one use the first.")
        }
        if totalSelected > clips.count {
            parts.append("Snippets and secrets in the selection are skipped.")
        }
        return parts.joined(separator: " ")
    }
}
