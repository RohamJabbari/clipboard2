import SwiftUI

/// Who can see an item that lives in a sync group.
struct PreviewSharing {
    let group: String
    /// The member who copied it, when that isn't just the group's name.
    let person: String?
    let memberCount: Int
}

struct PreviewPane: View {
    let entry: PanelEntry
    var sharing: PreviewSharing?
    var onEditSecret: ((SecretRef) -> Void)?
    /// Pastes a variant of the item (a color as RGB, minified JSON) into the target app.
    var onPasteText: (String) -> Void = { _ in }
    var onSaveAsSecret: (ClipItem) -> Void = { _ in }
    /// When set, the account's own text items are editable in place.
    var model: PanelViewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let sharing {
                SharedBanner(sharing: sharing)
                    .padding([.horizontal, .top], 14)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            metadata
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
                    textContent(item)
                }
            case .image:
                VStack(spacing: 0) {
                    ImagePreviewView(item: item)
                    if let text = item.imageText, !text.isEmpty {
                        Divider()
                        ImageTextView(text: text, onCopy: model.map { model in { model.copyImageText(text) } })
                    }
                }
            case .file:
                if let model, item.fileURLs.count > 1 {
                    FilePreviewView(urls: item.fileURLs, picked: model.pickedFiles,
                                    onClick: { model.clickFile($0, in: item) },
                                    onClear: model.clearPickedFiles)
                } else {
                    FilePreviewView(urls: item.fileURLs)
                }
            }
        case .snippet(let snippet):
            TextPreviewView(text: snippet.body, placeholders: true)
        case .secret(let ref):
            SecretPreviewView(ref: ref, onEdit: onEditSecret.map { edit in { edit(ref) } })
        }
    }

    @ViewBuilder
    private func textContent(_ item: ClipItem) -> some View {
        switch ClipContentCache.content(of: item) {
        case .plain:
            TextPreviewView(text: item.text)
        case .color(let color):
            ColorPreview(color: color, onPasteText: onPasteText)
        case .link(let url):
            LinkPreview(url: url)
        case .email(let address):
            ContactPreview(value: address, caption: "Email address",
                           actions: [ContactAction(title: "New Email", symbol: "envelope", url: URL(string: "mailto:\(address)"))])
        case .phone(let number):
            let dialable = number.filter { $0.isNumber || $0 == "+" }
            ContactPreview(value: number, caption: "Phone number",
                           actions: [ContactAction(title: "Call", symbol: "phone", url: URL(string: "tel:\(dialable)")),
                                     ContactAction(title: "Message", symbol: "message", url: URL(string: "sms:\(dialable)"))],
                           onPasteDigits: { onPasteText(dialable) })
        case .json(let pretty):
            JSONPreview(pretty: pretty, onPasteMinified: {
                if let minified = Transform.jsonMinify.apply(item.text) { onPasteText(minified) }
            })
        case .command:
            CommandPreview(text: item.text)
        case .sensitive(let kind):
            SensitivePreview(text: item.text, kind: kind, onSaveAsSecret: { onSaveAsSecret(item) })
        }
    }

    @ViewBuilder
    private var metadata: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            switch entry {
            case .clip(let item):
                if let label = item.label {
                    row("Label", label)
                }
                if let source = item.source {
                    GridRow {
                        Text("From").foregroundStyle(.secondary)
                        HStack(spacing: 5) {
                            Image(nsImage: AppIconCache.icon(for: source.bundleID))
                                .resizable()
                                .frame(width: 14, height: 14)
                                .accessibilityHidden(true)
                            Text(source.name)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                row("Copied", item.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
                if item.copyCount > 1 {
                    row("Times copied", "\(item.copyCount)")
                }
                row("Type", detailType(item))
                GridRow {
                    Text("Visible to").foregroundStyle(.secondary)
                    if let sharing {
                        Text("\(sharing.group) · \(sharing.memberCount) \(sharing.memberCount == 1 ? "person" : "people")")
                            .fontWeight(.semibold)
                            .foregroundStyle(.purple)
                    } else {
                        Text("Only you")
                    }
                }
                row("Expires", expiryText(item))
            case .snippet(let snippet):
                row("Snippet", snippet.name)
                if !snippet.keyword.isEmpty { row("Keyword", snippet.keyword) }
            case .secret(let ref):
                row("Stored in", "Keychain")
                if let created = ref.createdAt {
                    row("Added", created.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(2)
        }
    }

    private func expiryText(_ item: ClipItem) -> String {
        if item.isPinned { return item.label == nil ? "Never (kept)" : "Never (labelled)" }
        guard let date = item.expiryDate(maxAge: AppEnvironment.shared.prefs.maxAge) else { return "Never" }
        if date <= .now { return "Now" }
        return date.formatted(.relative(presentation: .named))
    }

    private func detailType(_ item: ClipItem) -> String {
        switch item.kind {
        case .text, .richText:
            let content = ClipContentCache.content(of: item)
            switch content {
            case .link(let url):
                return "Link · \(url.host() ?? url.absoluteString)"
            case .json(let pretty):
                let lines = pretty.split(separator: "\n", omittingEmptySubsequences: false).count
                return "JSON · \(lines) \(lines == 1 ? "line" : "lines")"
            case .sensitive(let kind):
                return "\(kind.shortName) · hidden in the list"
            case .plain:
                let chars = item.text.count
                let words = item.text.split { $0.isWhitespace || $0.isNewline }.count
                return "\(item.kind.displayName) · \(chars) characters · \(words) words"
            default:
                return content.title ?? item.kind.displayName
            }
        case .image:
            return "Image · \(item.imageWidth)×\(item.imageHeight) · \(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))"
        case .file:
            return item.fileURLs.count == 1 ? "File" : "\(item.fileURLs.count) Files"
        }
    }
}

/// "Shared in Team by Sara · 4 people can see this", above a group item's preview.
private struct SharedBanner: View {
    let sharing: PreviewSharing

    var body: some View {
        Label {
            Text(sharing.person.map { "Shared in **\(sharing.group)** by \($0)" } ?? "Shared in **\(sharing.group)**")
            + Text(" · \(sharing.memberCount) \(sharing.memberCount == 1 ? "person can" : "people can") see this")
        } icon: {
            Image(systemName: "person.2.fill")
        }
        .font(.callout)
        .foregroundStyle(.purple)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct TextPreviewView: View {
    let text: String
    /// Snippets: `{name}` fields are shown as tokens.
    var placeholders = false
    static let displayLimit = 20_000

    /// Short single lines read better large and centred in the pane.
    private var isShort: Bool { text.count <= 80 && !text.contains(where: \.isNewline) }

    var body: some View {
        if isShort && !placeholders {
            Text(text)
                .font(.system(size: 28, weight: .medium))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(20)
                .accessibilityLabel("Preview")
        } else {
            ScrollView {
                Text(placeholders ? Self.withPlaceholders(displayed) : AttributedString(displayed))
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .accessibilityLabel("Preview")
        }
    }

    private var displayed: String {
        text.count > Self.displayLimit ? String(text.prefix(Self.displayLimit)) + "\n…" : text
    }

    private static func withPlaceholders(_ text: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result += AttributedString(String(rest[..<open]))
            var token = AttributedString(" \(rest[rest.index(after: open)..<close]) ")
            token.backgroundColor = .pink.opacity(0.18)
            token.foregroundColor = .pink
            token.inlinePresentationIntent = .stronglyEmphasized
            result += token
            rest = rest[rest.index(after: close)...]
        }
        result += AttributedString(String(rest))
        return result
    }
}

/// A swatch with the color's values, its contrast with text, and paste variants.
private struct ColorPreview: View {
    let color: RGBColor
    let onPasteText: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.swiftUIColor)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1)))
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 12) {
                        Text("Aa").foregroundStyle(.white)
                        Text("Aa").foregroundStyle(.black)
                    }
                    .font(.system(size: 28, weight: .semibold))
                    .padding(14)
                    .accessibilityHidden(true)
                }
                .frame(height: 150)
            Grid(horizontalSpacing: 8) {
                GridRow {
                    value("HEX", color.hex)
                    value("RGB", color.rgb)
                    value("HSL", color.hsl)
                }
            }
            Text("Text on this color: white \(ratio(.white)) · black \(ratio(.black))")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Paste as HEX") { onPasteText(color.hex) }
                Button("Paste as RGB") { onPasteText(color.cssRGB) }
            }
        }
        .padding(16)
    }

    private func ratio(_ other: RGBColor) -> String {
        String(format: "%.1f : 1", color.contrast(with: other))
    }

    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The address taken apart. Nothing is fetched: loading the page would tell the site you copied it.
private struct LinkPreview: View {
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 20))
                    .foregroundStyle(.blue)
                    .frame(width: 42, height: 42)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayHost).font(.title3.weight(.semibold))
                    if !url.path().isEmpty && url.path() != "/" {
                        Text(url.path()).font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                    Label(url.scheme == "https" ? "Secure link" : "Not encrypted (http)",
                          systemImage: url.scheme == "https" ? "lock.fill" : "lock.open")
                        .font(.caption)
                        .foregroundStyle(url.scheme == "https" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(url.absoluteString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(4)
            Button("Open in Browser") { NSWorkspace.shared.open(url) }
        }
        .padding(16)
    }

    private var displayHost: String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

private struct ContactAction {
    let title: String
    let symbol: String
    let url: URL?
}

/// A phone number or email address, large, with the apps that handle it.
private struct ContactPreview: View {
    let value: String
    let caption: String
    let actions: [ContactAction]
    var onPasteDigits: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(value)
                .font(.system(size: 26, weight: .medium).monospacedDigit())
                .textSelection(.enabled)
            Text(caption).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(actions, id: \.title) { action in
                    Button {
                        if let url = action.url { NSWorkspace.shared.open(url) }
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                    .disabled(action.url == nil)
                }
                if let onPasteDigits {
                    Button("Paste Digits Only", action: onPasteDigits)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(20)
    }
}

/// Formatted JSON with keys, strings and numbers told apart.
private struct JSONPreview: View {
    let pretty: String
    let onPasteMinified: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("JSON")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.indigo.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(.indigo)
                Label("Valid", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.green)
                Spacer()
                Button("Paste Minified", action: onPasteMinified)
                    .controlSize(.small)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(JSONHighlighter.highlight(String(pretty.prefix(TextPreviewView.displayLimit))))
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(16)
    }
}

/// A shell command as it would look in Terminal.
private struct CommandPreview: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Shell command", systemImage: "terminal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            (Text("$ ").foregroundStyle(.white.opacity(0.55)) + Text(text.trimmingCharacters(in: .whitespacesAndNewlines)).foregroundStyle(.white))
                .font(.system(.callout, design: .monospaced))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(16)
    }
}

/// A credential in history: blurred until asked, with a nudge to move it into the Keychain.
private struct SensitivePreview: View {
    let text: String
    let kind: SensitiveText.Kind
    let onSaveAsSecret: () -> Void
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("**This looks like \(kind.description).** ")
                + Text(kind.isConfident ? "It's hidden in the list and can't be sent to a group by accident."
                                        : "It can't be sent to a group by accident.")
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
            }
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(.body, design: .monospaced))
                .lineLimit(6)
                .textSelection(.enabled)
                .blur(radius: revealed ? 0 : 7)
                .accessibilityHidden(!revealed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                Button("Save as Secret…", action: onSaveAsSecret)
                    .buttonStyle(.borderedProminent)
                Button(revealed ? "Hide" : "Show") { revealed.toggle() }
            }
        }
        .padding(16)
    }
}

/// Colors pretty-printed JSON by token: keys, strings, and numbers or literals.
enum JSONHighlighter {
    static func highlight(_ json: String) -> AttributedString {
        let keyColor = Color(light: NSColor(red: 0.60, green: 0.29, blue: 0, alpha: 1), dark: NSColor(red: 1, green: 0.70, blue: 0.36, alpha: 1))
        let stringColor = Color(light: NSColor(red: 0.06, green: 0.42, blue: 0.40, alpha: 1), dark: NSColor(red: 0.42, green: 0.86, blue: 0.83, alpha: 1))
        let numberColor = Color(light: NSColor(red: 0.04, green: 0.36, blue: 0.77, alpha: 1), dark: NSColor(red: 0.42, green: 0.71, blue: 1, alpha: 1))
        let chars = Array(json)
        var result = AttributedString()
        var plain = ""
        func flushPlain() {
            guard !plain.isEmpty else { return }
            var part = AttributedString(plain)
            part.foregroundColor = .secondary
            result += part
            plain = ""
        }
        func append(_ text: String, _ color: Color) {
            flushPlain()
            var part = AttributedString(text)
            part.foregroundColor = color
            result += part
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                var j = i + 1
                while j < chars.count, chars[j] != "\"" { j += chars[j] == "\\" ? 2 : 1 }
                let end = min(j, chars.count - 1)
                var k = end + 1
                while k < chars.count, chars[k] == " " { k += 1 }
                let isKey = k < chars.count && chars[k] == ":"
                append(String(chars[i...end]), isKey ? keyColor : stringColor)
                i = end + 1
            } else if c.isNumber || c == "-" {
                var j = i
                while j < chars.count, chars[j].isNumber || "-+.eE".contains(chars[j]) { j += 1 }
                append(String(chars[i..<j]), numberColor)
                i = j
            } else if let literal = ["true", "false", "null"].first(where: { chars[i...].starts(with: $0) }) {
                append(literal, numberColor)
                i += literal.count
            } else {
                plain.append(c)
                i += 1
            }
        }
        flushPlain()
        return result
    }
}

extension Color {
    /// A color with separate light and dark appearance values.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
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
    /// Copies the recognised text (the header's Copy button); hidden when nil.
    var onCopy: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Text in image", systemImage: "text.viewfinder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let onCopy {
                    Button(action: onCopy) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Copy the recognised text")
                    .accessibilityLabel("Copy text in image")
                }
            }
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

/// The files of a file item. With `onClick` set (several files), rows can be picked so that
/// paste, copy, save and drag use only those.
struct FilePreviewView: View {
    let urls: [URL]
    var picked: Set<URL> = []
    var onClick: ((URL) -> Void)?
    var onClear: () -> Void = {}

    private var pickedCount: Int { urls.filter(picked.contains).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if onClick != nil {
                pickHeader
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: onClick == nil ? 10 : 2) {
                    ForEach(urls, id: \.self) { url in
                        row(url, isPicked: picked.contains(url))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(onClick == nil ? 14 : 8)
            }
        }
    }

    /// Says what Return will do: everything, or only the picked files.
    private var pickHeader: some View {
        HStack(spacing: 8) {
            Text(pickedCount == 0 || pickedCount == urls.count
                 ? "Click files to paste only some of them"
                 : "Paste \(pickedCount) of \(urls.count) files")
                .font(.caption.weight(pickedCount == 0 ? .regular : .semibold))
                .foregroundStyle(pickedCount == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            Spacer(minLength: 0)
            if pickedCount > 0 {
                Button("Clear", action: onClear)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .controlSize(.small)
                    .help("Use all files again")
            }
        }
    }

    private func row(_ url: URL, isPicked: Bool) -> some View {
        HStack(spacing: 10) {
            if onClick != nil {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isPicked ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
            Image(nsImage: FileIconCache.icon(for: url))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .foregroundStyle(isPicked ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Text(url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(isPicked ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, onClick == nil ? 0 : 6)
        .padding(.vertical, onClick == nil ? 0 : 4)
        .background {
            if isPicked {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.gradient)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onClick?(url) }
        // Each file can also be dragged out on its own.
        .onDrag { NSItemProvider(object: url as NSURL) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onClick == nil ? [] : (isPicked ? [.isButton, .isSelected] : .isButton))
        .accessibilityHint(onClick == nil ? "" : "Pick to paste only some files")
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
