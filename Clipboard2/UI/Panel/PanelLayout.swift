import CoreGraphics

/// The edges a resize handle moves.
nonisolated struct PanelResizeEdges: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let left = PanelResizeEdges(rawValue: 1 << 0)
    static let right = PanelResizeEdges(rawValue: 1 << 1)
    static let top = PanelResizeEdges(rawValue: 1 << 2)
    static let bottom = PanelResizeEdges(rawValue: 1 << 3)
}

/// The quick panel's size, place and split: pure rules, in screen points (bottom-left origin).
nonisolated enum PanelLayout {
    static let minSize = CGSize(width: 640, height: 400)
    static let maxSize = CGSize(width: 1280, height: 900)
    /// First open on a screen: this share of the visible width and height.
    static let defaultFraction: CGFloat = 0.6

    /// The smaller of `maxSize` and 90% of the visible screen.
    static func maximumSize(visible: CGRect) -> CGSize {
        CGSize(width: min(maxSize.width, (visible.width * 0.9).rounded(.down)),
               height: min(maxSize.height, (visible.height * 0.9).rounded(.down)))
    }

    /// `size` within the minimum and the screen's maximum (the maximum wins on a tiny screen).
    static func clamp(_ size: CGSize, visible: CGRect) -> CGSize {
        let maximum = maximumSize(visible: visible)
        return CGSize(width: min(max(size.width, minSize.width), maximum.width).rounded(),
                      height: min(max(size.height, minSize.height), maximum.height).rounded())
    }

    /// The size to open at: the remembered one, else the seed (the old Small/Regular/Large
    /// setting), else 60% × 60% of the screen; always clamped to this screen.
    static func size(remembered: CGSize?, seed: CGSize?, visible: CGRect) -> CGSize {
        clamp(remembered ?? seed ?? CGSize(width: visible.width * defaultFraction, height: visible.height * defaultFraction),
              visible: visible)
    }

    /// The list's width; the preview takes the rest. 44% / 56%, and under 760 pt the preview
    /// narrows first (down to 260 pt) while the list never goes under 320 pt.
    static func listWidth(panelWidth width: CGFloat) -> CGFloat {
        let split: CGFloat = 0.44, threshold: CGFloat = 760, minPreview: CGFloat = 260, minList: CGFloat = 320
        guard width < threshold else { return (width * split).rounded() }
        return max(minList, min(threshold * split, width - minPreview)).rounded()
    }

    /// The panel's frame at a remembered top-left corner, or nil when that place isn't fully on
    /// the visible screen (the caller falls back to the origin setting).
    static func restoredFrame(topLeft: CGPoint?, size: CGSize, visible: CGRect) -> CGRect? {
        guard let topLeft else { return nil }
        let frame = CGRect(x: topLeft.x.rounded(), y: (topLeft.y - size.height).rounded(), width: size.width, height: size.height)
        return visible.insetBy(dx: -1, dy: -1).contains(frame) ? frame : nil
    }

    /// `start` with `edges` dragged by `delta` (screen points, y up), clamped to the size limits;
    /// the opposite edges stay put.
    static func resize(_ start: CGRect, edges: PanelResizeEdges, by delta: CGVector, visible: CGRect) -> CGRect {
        var width = start.width, height = start.height
        if edges.contains(.right) { width += delta.dx }
        if edges.contains(.left) { width -= delta.dx }
        if edges.contains(.top) { height += delta.dy }
        if edges.contains(.bottom) { height -= delta.dy }
        let size = clamp(CGSize(width: width, height: height), visible: visible)
        let x = edges.contains(.left) ? start.maxX - size.width : start.minX
        let y = edges.contains(.bottom) ? start.maxY - size.height : start.minY
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Quick Look's frame: centred on the panel, at most 80% of the visible screen.
    static func quickLookFrame(panel: CGRect, visible: CGRect) -> CGRect {
        let width = min(visible.width * 0.8, max(panel.width, 800))
        let height = min(visible.height * 0.8, max(panel.height, 600))
        var x = panel.midX - width / 2, y = panel.midY - height / 2
        x = min(max(x, visible.minX), visible.maxX - width)
        y = min(max(y, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height).integral
    }
}
