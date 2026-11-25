import AppKit
import SwiftUI

/// Behind the top bar (and in the grip): a mouse-down here drags the whole panel. SwiftUI
/// controls on top (the search field, buttons, chips) still get their own clicks.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if let panel = window as? QuickPanel, panel.beginMove(with: event) { return }
            super.mouseDown(with: event)
        }
    }
}

/// Pins the panel: kept open, it doesn't close on paste, focus loss, esc or ⇧⌘V.
struct KeepOpenButton: View {
    @Binding var isPinned: Bool

    var body: some View {
        Button {
            isPinned.toggle()
        } label: {
            Label(isPinned ? "Kept Open" : "Keep Open", systemImage: isPinned ? "pin.fill" : "pin")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(isPinned ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous)
                    .fill(isPinned ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(isPinned ? "Let the panel close after pasting" : "Keep the panel open after pasting")
        .accessibilityLabel("Keep Open")
        .accessibilityAddTraits(isPinned ? [.isSelected, .isButton] : .isButton)
    }
}

/// An invisible strip along one edge (or a corner) of the panel that resizes it.
final class PanelResizeHandle: NSView {
    let edges: PanelResizeEdges
    /// Whether a resize may start now; false ignores the drag.
    var onBegin: () -> Bool = { false }
    /// The mouse moved this far (screen points, y up) since the drag began.
    var onDrag: (CGVector) -> Void = { _ in }
    var onEnd: () -> Void = {}
    private var start: NSPoint?

    init(edges: PanelResizeEdges) {
        self.edges = edges
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Always active: the app is usually not active while the panel is up.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseEntered(with event: NSEvent) { cursor.set() }
    override func mouseExited(with event: NSEvent) { if start == nil { NSCursor.arrow.set() } }

    override func mouseDown(with event: NSEvent) {
        guard onBegin() else { return }
        start = NSEvent.mouseLocation
        cursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = NSEvent.mouseLocation
        onDrag(CGVector(dx: point.x - start.x, dy: point.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        onEnd()
    }

    private var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch edges {
            case [.top, .left]: position = .topLeft
            case [.top, .right]: position = .topRight
            case [.bottom, .left]: position = .bottomLeft
            case [.bottom, .right]: position = .bottomRight
            case .top: position = .top
            case .bottom: position = .bottom
            case .left: position = .left
            default: position = .right
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        if edges == .left || edges == .right { return .resizeLeftRight }
        if edges == .top || edges == .bottom { return .resizeUpDown }
        return .crosshair
    }

    /// The eight handles' frames inside a panel of `bounds` (unflipped).
    static func layout(_ handles: [PanelResizeHandle], in bounds: CGRect) {
        let edge: CGFloat = 5, corner: CGFloat = 14
        let w = bounds.width, h = bounds.height
        for handle in handles {
            let frame: CGRect
            switch handle.edges {
            case .left: frame = CGRect(x: 0, y: corner, width: edge, height: h - 2 * corner)
            case .right: frame = CGRect(x: w - edge, y: corner, width: edge, height: h - 2 * corner)
            case .bottom: frame = CGRect(x: corner, y: 0, width: w - 2 * corner, height: edge)
            case .top: frame = CGRect(x: corner, y: h - edge, width: w - 2 * corner, height: edge)
            case [.bottom, .left]: frame = CGRect(x: 0, y: 0, width: corner, height: corner)
            case [.bottom, .right]: frame = CGRect(x: w - corner, y: 0, width: corner, height: corner)
            case [.top, .left]: frame = CGRect(x: 0, y: h - corner, width: corner, height: corner)
            default: frame = CGRect(x: w - corner, y: h - corner, width: corner, height: corner)
            }
            if handle.frame != frame { handle.frame = frame }
        }
    }

    static let allEdges: [PanelResizeEdges] = [.left, .right, .top, .bottom,
                                               [.top, .left], [.top, .right], [.bottom, .left], [.bottom, .right]]
}
