import AppKit
import SwiftUI

/// One copied file in the preview pane: a name field (the name it pastes with), and what it holds
/// when that's text: selectable (Return / Paste Selected Only paste just the selection, ⌘C copies
/// it) and editable into a new copy. The user's own file is never changed or renamed.
struct FileContentsPane: View {
    let item: ClipItem
    let url: URL
    let model: PanelViewModel
    @State private var contents: TextFileContents.Contents?

    private var state: FileEditState? {
        model.fileEdit.flatMap { $0.matches(item, url) ? $0 : nil }
    }

    private var isEditing: Bool { state?.isEditing == true }

    private var loaded: TextFileContents.Loaded? {
        if case .text(let loaded) = contents { return loaded }
        return nil
    }

    private var canEdit: Bool { loaded.map { !$0.isTruncated } ?? false }
    private var isMissing: Bool { contents == .missing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .task(id: url) {
            contents = nil
            contents = await TextFileContents.loadInBackground(url)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileIconCache.icon(for: url))
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                FileNameField(text: Binding(get: { model.fileName(for: item, url: url) },
                                            set: { model.setFileName($0, for: item, url: url) }),
                              isEnabled: !isMissing || isEditing, model: model)
                    .help(isEditing ? "The new copy's name" : "The name it pastes with. Renaming keeps a renamed copy; your file keeps its name.")
                Text(isEditing ? "Saving keeps a new copy; the original stays as it is" : url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            buttons
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if isEditing {
            Button("Cancel") { model.cancelFileEdit() }
                .controlSize(.small)
            Button("Save as New Copy") { model.saveFileEdit() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Keeps the edited text as a new item (⌘S)")
        } else {
            if model.previewSelection != nil {
                PasteSelectedOnlyButton(model: model)
                    .fixedSize()
            }
            if model.hasPendingRename(item, url: url) {
                Button(model.renamesInPlace(item) ? "Rename" : "Keep Renamed Copy") { model.renameFile() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Return")
            }
            if canEdit {
                Button {
                    model.beginFileEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .controlSize(.small)
                .help("Edit a copy of this file (⌘E)")
            }
        }
    }

    // MARK: Contents

    @ViewBuilder
    private var content: some View {
        switch contents {
        case nil:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            note("questionmark.folder", "This file isn't there any more",
                 "Clipboard2 keeps where a copied file was, not the file itself. Nothing is at \(url.path) now.")
        case .hidden:
            note("lock.doc", "Contents hidden",
                 "This file looks like it holds a key or password, so it isn't shown here.")
        case .unreadable:
            note("exclamationmark.lock", "Can't read this file", "Clipboard2 isn't allowed to open it.")
        case .notText:
            fileIcon
        case .text(let loaded):
            if isEditing, let state {
                FileTextArea(text: state.original, isEditable: true, isMonospaced: loaded.isMonospaced, model: model, state: state)
            } else {
                FileTextArea(text: loaded.display, isEditable: false, isMonospaced: loaded.isMonospaced, model: model)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let loaded, !isEditing, loaded.isTruncated || loaded.isPrettyJSON {
            Divider()
            Text(loaded.isTruncated
                 ? "Showing the first \(Self.size(TextFileContents.byteLimit)) of \(Self.size(loaded.byteCount)). Only files up to \(Self.size(TextFileContents.byteLimit)) can be edited."
                 : "JSON shown formatted; the file itself is unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
    }

    private var fileIcon: some View {
        VStack(spacing: 8) {
            Image(nsImage: FileIconCache.icon(for: url))
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            if let size = TextFileContents.regularFileSize(url) {
                Text(Self.size(size)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func note(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(14)
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Paste Selected Only

/// "Paste Selected Only", shown while text in the preview is selected. An AppKit button, so a click
/// on it isn't taken for a click elsewhere (which clears the selection; see `QuickPanelController`).
struct PasteSelectedOnlyButton: NSViewRepresentable {
    let model: PanelViewModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PasteSelectionButton {
        let button = PasteSelectionButton(title: "Paste Selected Only", target: context.coordinator,
                                          action: #selector(Coordinator.paste))
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        button.bezelColor = .controlAccentColor
        button.toolTip = "Pastes only the selected text, as plain text (Return)"
        button.setAccessibilityLabel("Paste Selected Only")
        return button
    }

    func updateNSView(_ button: PasteSelectionButton, context: Context) {
        context.coordinator.model = model
    }

    @MainActor
    final class Coordinator: NSObject {
        var model: PanelViewModel?

        @objc func paste() {
            guard let model else { return }
            model.flushEditor?()
            model.pastePreviewSelection()
        }
    }
}

final class PasteSelectionButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Never takes focus, so the selected text keeps its selection until the paste.
    override var acceptsFirstResponder: Bool { false }
}

// MARK: - Name field

/// The file's name, editable. AppKit, so the panel can tell its keys apart (Return renames, esc
/// backs out: `PanelViewModel.handleFileNameKey`).
struct FileNameField: NSViewRepresentable {
    @Binding var text: String
    var isEnabled = true
    let model: PanelViewModel

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> FileNameTextField {
        let field = FileNameTextField()
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .exterior
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.placeholderString = "File name"
        field.setAccessibilityLabel("File name")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: FileNameTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        field.isEnabled = isEnabled
        if model.fileFocusRequest == .name {
            DispatchQueue.main.async { [weak field, model] in
                guard let field, let window = field.window, model.fileFocusRequest == .name else { return }
                model.fileFocusRequest = nil
                window.makeFirstResponder(field)
                // Like Finder: the name without its extension is selected.
                let base = TextFileContents.split(field.stringValue).base
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if text.wrappedValue != field.stringValue { text.wrappedValue = field.stringValue }
        }
    }
}

final class FileNameTextField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Contents text

/// A file's text: read-only and selectable (the selection goes to `previewSelection`), or
/// editable while a copy is being edited. A scrolling NSTextView, so a 1 MB file lays out lazily.
struct FileTextArea: NSViewRepresentable {
    let text: String
    let isEditable: Bool
    let isMonospaced: Bool
    let model: PanelViewModel
    var state: FileEditState?

    private var font: NSFont {
        isMonospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 14)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = FileContentsTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = isEditable
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.setAccessibilityLabel(isEditable ? "File contents, editable" : "File contents")

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.state = state
        guard let textView = coordinator.textView else { return }
        textView.panelModel = model
        state?.editor = textView
        if coordinator.shown != text {
            // While editing, the text view owns the draft; it's loaded once.
            if !isEditable || coordinator.shown == nil {
                coordinator.shown = text
                textView.string = text
                textView.font = font
                textView.textColor = .labelColor
                textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.undoManager?.removeAllActions()
            }
        }
        // The model let go of the selection (another row, a click elsewhere, a paste).
        if !isEditable, model.previewSelection == nil, textView.selectedRange().length > 0 {
            textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
        }
        if isEditable, model.fileFocusRequest == .editor {
            DispatchQueue.main.async { [weak textView, model] in
                guard let textView, let window = textView.window, model.fileFocusRequest == .editor else { return }
                model.fileFocusRequest = nil
                window.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: FileContentsTextView?
        var model: PanelViewModel?
        var state: FileEditState?
        var shown: String?

        func textViewDidChangeSelection(_ notification: Notification) {
            // A read-only file's selection is what Return, Paste Selected Only and ⌘C use.
            guard let view = notification.object as? NSTextView, !view.isEditable else { return }
            let selected = SelectableText.Coordinator.selectedText(in: view)
            if model?.previewSelection != selected { model?.previewSelection = selected }
        }

        func textDidChange(_ notification: Notification) {
            guard let state else { return }
            if !state.isDirty { state.isDirty = true }
            if state.confirmingDiscard { state.confirmingDiscard = false }
        }
    }
}

/// Handles the editing shortcuts itself: the quick panel has no Edit menu to route them. Copies
/// go out as plain text marked as our own, so they never come back as history items.
final class FileContentsTextView: NSTextView {
    weak var panelModel: PanelViewModel?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted, !isEditable, selectedRange().length > 0 { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return accepted
    }

    override func copy(_ sender: Any?) {
        guard let panelModel else { return super.copy(sender) }
        if !isEditable, panelModel.previewSelection != nil {
            panelModel.copyPreviewSelection()
        } else if let text = SelectableText.Coordinator.selectedText(in: self) {
            panelModel.copyPlainText(text)
        }
    }

    override func cut(_ sender: Any?) {
        guard isEditable, selectedRange().length > 0 else { return }
        copy(sender)
        delete(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let shift = flags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "x" where isEditable: cut(nil)
        case "v" where isEditable: pasteAsPlainText(nil)
        case "z" where isEditable: shift ? undoManager?.redo() : undoManager?.undo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
