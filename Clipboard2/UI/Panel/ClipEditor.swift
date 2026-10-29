import AppKit
import SwiftUI

/// The quick panel's preview for text items, editable in place. Edits are saved into the history
/// item (debounced while typing, and right before pasting or switching items), so what gets
/// pasted, synced and bound to slots is the edited version. Styling keeps the item rich text;
/// plain items stay plain unless styling is added.
struct ClipEditor: View {
    let item: ClipItem
    let model: PanelViewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isEditingText {
                StyleBar { model.applyStyle($0) }
                Divider()
            }
            ClipTextEditor(item: item, model: model)
        }
    }
}

enum TextStyle: CaseIterable {
    case bold, italic, underline, strikethrough, clear

    var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        case .clear: "Clear Formatting"
        }
    }

    var symbol: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .clear: "textformat.slash"
        }
    }

    var shortcut: String {
        switch self {
        case .bold: "⌘B"
        case .italic: "⌘I"
        case .underline: "⌘U"
        case .strikethrough: "⌘⇧X"
        case .clear: "⌘\\"
        }
    }
}

private struct StyleBar: View {
    let apply: (TextStyle) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TextStyle.allCases, id: \.self) { style in
                if style == .clear { Divider().frame(height: 14).padding(.horizontal, 4) }
                Button {
                    apply(style)
                } label: {
                    Image(systemName: style.symbol)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("\(style.title) (\(style.shortcut))")
                .accessibilityLabel(style.title)
            }
            Spacer()
            Text("Edits are saved to this item")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// NSTextView, because SwiftUI's TextEditor can't edit attributed text on macOS 14.
private struct ClipTextEditor: NSViewRepresentable {
    let item: ClipItem
    let model: PanelViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ClipEditorTextView(frame: .zero)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 12)
        // Rich text copied from light-mode apps is usually black; show it readable here
        // without changing the colours that get saved and pasted.
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        // Clipboard text is often code, commands or passwords: never "fix" it while typing.
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
        textView.setAccessibilityLabel("Item text, editable")

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.textView = textView
        context.coordinator.load(item)
        model.flushEditor = { [weak coordinator = context.coordinator] in coordinator?.save() }
        model.applyStyle = { [weak coordinator = context.coordinator] in coordinator?.apply($0) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.itemID != item.id {
            coordinator.save()
            coordinator.load(item)
        }
        if coordinator.focusToken != model.editorFocusToken {
            coordinator.focusToken = model.editorFocusToken
            if let textView = coordinator.textView, let window = textView.window {
                window.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.save()
        coordinator.model.isEditingText = false
        coordinator.model.flushEditor = nil
        coordinator.model.applyStyle = { _ in }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: PanelViewModel
        weak var textView: ClipEditorTextView?
        var itemID: UUID?
        var focusToken = 0
        private weak var item: ClipItem?
        private var wasRich = false
        private var isDirty = false
        private var saveTask: Task<Void, Never>?

        init(model: PanelViewModel) {
            self.model = model
            focusToken = model.editorFocusToken
        }

        static var plainAttributes: [NSAttributedString.Key: Any] {
            [.font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.labelColor]
        }

        func load(_ item: ClipItem) {
            self.item = item
            itemID = item.id
            isDirty = false
            saveTask?.cancel()
            let rich = Self.richContent(of: item)
            wasRich = rich != nil
            let content = rich ?? NSAttributedString(string: item.text, attributes: Self.plainAttributes)
            textView?.textStorage?.setAttributedString(content)
            textView?.typingAttributes = content.length > 0
                ? content.attributes(at: content.length - 1, effectiveRange: nil)
                : Self.plainAttributes
            textView?.undoManager?.removeAllActions()
        }

        private static func richContent(of item: ClipItem) -> NSAttributedString? {
            guard item.kind == .richText else { return nil }
            if let rtf = item.rtfData, let text = NSAttributedString(rtf: rtf, documentAttributes: nil), text.length > 0 {
                return text
            }
            if let html = item.htmlData,
               let text = try? NSAttributedString(data: html, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                         .characterEncoding: String.Encoding.utf8.rawValue],
                                                  documentAttributes: nil), text.length > 0 {
                return text
            }
            return nil
        }

        func textDidChange(_ notification: Notification) {
            isDirty = true
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                self?.save()
            }
        }

        /// Writes pending edits to the store (no-op when nothing changed).
        func save() {
            saveTask?.cancel()
            guard isDirty, let item, item.modelContext != nil, let textView else { return }
            isDirty = false
            let content = textView.attributedString()
            let text = content.string
            guard wasRich || Self.hasStyling(content) else {
                model.saveEdit(item, text: text, rtf: nil, html: nil)
                return
            }
            // The editor shows plain text in the system's dynamic label colour; saved rich text
            // must not carry it (it would paste as white text in light apps).
            let saved = NSMutableAttributedString(attributedString: content)
            saved.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: saved.length)) { value, range, _ in
                if (value as? NSColor) == .labelColor { saved.removeAttribute(.foregroundColor, range: range) }
            }
            let range = NSRange(location: 0, length: saved.length)
            let rtf = saved.rtf(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let html = try? saved.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
            model.saveEdit(item, text: text, rtf: rtf, html: html)
        }

        /// Whether a plain item picked up styling (from the style bar or pasted rich text).
        static func hasStyling(_ text: NSAttributedString) -> Bool {
            let base = NSFont.preferredFont(forTextStyle: .body)
            var styled = false
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, stop in
                let font = attributes[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                let color = attributes[.foregroundColor] as? NSColor
                if traits.contains(.boldFontMask) || traits.contains(.italicFontMask)
                    || (font.map { abs($0.pointSize - base.pointSize) > 0.5 || $0.familyName != base.familyName } ?? false)
                    || (attributes[.underlineStyle] as? Int ?? 0) != 0
                    || (attributes[.strikethroughStyle] as? Int ?? 0) != 0
                    || (color != nil && color != .labelColor)
                    || attributes[.link] != nil || attributes[.backgroundColor] != nil {
                    styled = true
                    stop.pointee = true
                }
            }
            return styled
        }

        // MARK: Styling

        func apply(_ style: TextStyle) {
            guard let textView, let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            // Without a selection, style what's typed next.
            guard selection.length > 0 else {
                var typing = textView.typingAttributes
                switch style {
                case .bold, .italic:
                    let font = typing[.font] as? NSFont ?? NSFont.preferredFont(forTextStyle: .body)
                    typing[.font] = Self.toggle(style == .bold ? .boldFontMask : .italicFontMask, in: font, on: !Self.has(style == .bold ? .boldFontMask : .italicFontMask, font))
                case .underline, .strikethrough:
                    let key: NSAttributedString.Key = style == .underline ? .underlineStyle : .strikethroughStyle
                    typing[key] = (typing[key] as? Int ?? 0) == 0 ? NSUnderlineStyle.single.rawValue : nil
                case .clear:
                    typing = Self.plainAttributes
                }
                textView.typingAttributes = typing
                return
            }
            guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }
            storage.beginEditing()
            switch style {
            case .bold, .italic:
                let trait: NSFontTraitMask = style == .bold ? .boldFontMask : .italicFontMask
                // Like TextEdit: if everything selected already has it, remove it; else add it.
                var allHave = true
                storage.enumerateAttribute(.font, in: selection) { value, _, stop in
                    if !Self.has(trait, value as? NSFont ?? NSFont.preferredFont(forTextStyle: .body)) {
                        allHave = false
                        stop.pointee = true
                    }
                }
                storage.enumerateAttribute(.font, in: selection) { value, range, _ in
                    let font = value as? NSFont ?? NSFont.preferredFont(forTextStyle: .body)
                    storage.addAttribute(.font, value: Self.toggle(trait, in: font, on: !allHave), range: range)
                }
            case .underline, .strikethrough:
                let key: NSAttributedString.Key = style == .underline ? .underlineStyle : .strikethroughStyle
                var allHave = true
                storage.enumerateAttribute(key, in: selection) { value, _, stop in
                    if (value as? Int ?? 0) == 0 {
                        allHave = false
                        stop.pointee = true
                    }
                }
                if allHave {
                    storage.removeAttribute(key, range: selection)
                } else {
                    storage.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: selection)
                }
            case .clear:
                storage.setAttributes(Self.plainAttributes, range: selection)
            }
            storage.endEditing()
            textView.didChangeText()
        }

        private static func has(_ trait: NSFontTraitMask, _ font: NSFont) -> Bool {
            NSFontManager.shared.traits(of: font).contains(trait)
        }

        private static func toggle(_ trait: NSFontTraitMask, in font: NSFont, on: Bool) -> NSFont {
            on ? NSFontManager.shared.convert(font, toHaveTrait: trait)
               : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
        }
    }
}

/// Handles the editing shortcuts itself: the quick panel has no Edit or Format menu to route them.
final class ClipEditorTextView: NSTextView {
    fileprivate weak var coordinator: ClipTextEditor.Coordinator?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { editorCoordinator?.model.isEditingText = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted, let coordinator = editorCoordinator {
            coordinator.save()
            coordinator.model.isEditingText = false
        }
        return accepted
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let shift = flags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "x" where shift: editorCoordinator?.apply(.strikethrough)
        case "x": cut(nil)
        case "v": shift ? pasteAsPlainText(nil) : paste(nil)
        case "z": shift ? undoManager?.redo() : undoManager?.undo()
        case "b": editorCoordinator?.apply(.bold)
        case "i": editorCoordinator?.apply(.italic)
        case "u": editorCoordinator?.apply(.underline)
        case "\\": editorCoordinator?.apply(.clear)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private var editorCoordinator: ClipTextEditor.Coordinator? { coordinator }
}
