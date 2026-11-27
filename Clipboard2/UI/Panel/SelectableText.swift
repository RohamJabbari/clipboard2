import AppKit
import SwiftUI

/// Read-only preview text that can be selected. The selection goes to the model, so Return
/// pastes and ⌘C copies just that part (SwiftUI's selectable `Text` doesn't expose it).
/// Sizes like `Text`: full proposed width, as tall as the wrapped text.
struct SelectableText: NSViewRepresentable {
    let text: String
    var font: NSFont = .preferredFont(forTextStyle: .body)
    var lineSpacing: CGFloat = 0
    var model: PanelViewModel?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SelectableTextView {
        let view = SelectableTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        view.setAccessibilityLabel("Preview")
        return view
    }

    func updateNSView(_ view: SelectableTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        if coordinator.shown != Shown(text: text, font: font, lineSpacing: lineSpacing) {
            coordinator.shown = Shown(text: text, font: font, lineSpacing: lineSpacing)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
            ]))
        }
        // The model let go of the selection (another row, a click elsewhere, a paste).
        if model?.previewSelection == nil, view.selectedRange().length > 0 {
            view.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: SelectableTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let proposed = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        container.containerSize = NSSize(width: proposed ?? 100_000, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: proposed ?? ceil(used.width), height: ceil(used.height))
    }

    struct Shown: Equatable {
        var text: String
        var font: NSFont
        var lineSpacing: CGFloat
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var model: PanelViewModel?
        var shown: Shown?

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let selected = Self.selectedText(in: view)
            if model?.previewSelection != selected { model?.previewSelection = selected }
        }

        /// The selected text, or nil when nothing is selected.
        static func selectedText(in view: NSTextView) -> String? {
            selectedText(view.string, range: view.selectedRange())
        }

        nonisolated static func selectedText(_ string: String, range: NSRange) -> String? {
            let text = string as NSString
            guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= text.length else { return nil }
            return text.substring(with: range)
        }
    }
}

final class SelectableTextView: NSTextView {
    fileprivate weak var coordinator: SelectableText.Coordinator?

    // A click into the panel selects right away, even when it isn't key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted, selectedRange().length > 0 { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return accepted
    }

    /// Copy (menu or ⌘C) goes out as plain text, marked as ours: no new history item.
    override func copy(_ sender: Any?) {
        if let model = coordinator?.model, model.previewSelection != nil {
            model.copyPreviewSelection()
        } else {
            super.copy(sender)
        }
    }
}
