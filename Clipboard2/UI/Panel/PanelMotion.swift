import CoreGraphics
import Foundation

/// A damped spring described the way Apple's tools describe it: `response` (seconds to roughly
/// reach the target) and `dampingRatio` (1 = no overshoot, below 1 = a little overshoot).
///
/// The quick panel hands these values to `CASpringAnimation`, so the motion runs on the render
/// server. The same closed-form solution is used here to know where the animation is at any
/// instant, which is what makes a mid-flight reversal start from the on-screen value with the
/// on-screen velocity instead of jumping.
nonisolated struct PanelSpring: Equatable, Sendable {
    var response: Double
    var dampingRatio: Double

    /// For a unit mass.
    var stiffness: Double { pow(2 * .pi / response, 2) }
    var damping: Double { 4 * .pi * min(dampingRatio, 1) / response }

    func scaled(by factor: Double) -> PanelSpring {
        PanelSpring(response: response * factor, dampingRatio: dampingRatio)
    }

    /// Normalised progress (0 → 1) and its velocity (per second) `t` seconds after starting at 0
    /// with `initialVelocity` (in units of the full distance per second, as `CASpringAnimation`).
    func state(at t: Double, initialVelocity v0: Double = 0) -> (value: Double, velocity: Double) {
        let t = max(0, t)
        let omega = 2 * .pi / response
        let zeta = min(dampingRatio, 1)
        // Displacement from the target: y(0) = -1, y'(0) = v0.
        if zeta < 1 {
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let a = -1.0
            let b = (v0 + zeta * omega * a) / wd
            let envelope = exp(-zeta * omega * t)
            let c = cos(wd * t), s = sin(wd * t)
            let y = envelope * (a * c + b * s)
            let dy = envelope * (-zeta * omega * (a * c + b * s) + wd * (-a * s + b * c))
            return (1 + y, dy)
        } else {
            let a = -1.0
            let b = v0 - omega
            let envelope = exp(-omega * t)
            let y = (a + b * t) * envelope
            let dy = (b - omega * (a + b * t)) * envelope
            return (1 + y, dy)
        }
    }

    /// Time until the motion stays within `tolerance` of the target (and is nearly still).
    func settlingTime(initialVelocity v0: Double = 0, tolerance: Double = 0.002) -> Double {
        var t = 0.0
        var lastOutside = 0.0
        let step = 1.0 / 240
        while t < response * 8 {
            let (value, velocity) = state(at: t, initialVelocity: v0)
            if abs(1 - value) > tolerance || abs(velocity) > tolerance * 10 { lastOutside = t }
            t += step
        }
        return lastOutside + step
    }
}

/// Where the quick panel rests and the shape it grows from, for one screen and one origin.
/// Everything is in screen points (bottom-left origin) except `pill`, which is in the panel's own
/// coordinates.
nonisolated struct PanelGeometry: Equatable, Sendable {
    static let cornerRadius: CGFloat = 22
    /// Room around the panel for the drawn shadow (the window itself has none: a window-server
    /// shadow can't follow a shape that changes every frame).
    static let shadowMargin: CGFloat = 44

    var origin: PanelOrigin
    /// The panel's resting frame.
    var panel: CGRect
    /// The window's frame: the panel, the path it travels, and the shadow margin.
    var window: CGRect
    /// The panel's translation at progress 0 (it starts against the screen edge).
    var startOffset: CGVector
    /// The small pill the panel morphs out of, in panel coordinates.
    var pill: CGRect

    /// Scale at progress 0 when emerging from the centre.
    static let centerStartScale: CGFloat = 0.94

    static func make(origin: PanelOrigin, size: CGSize, visible: CGRect) -> PanelGeometry {
        let w = min(size.width, visible.width - 16)
        let h = min(size.height, visible.height - 16)
        let edgeGapV = min(max(visible.height * 0.06, 28), 80)
        let edgeGapH = min(max(visible.width * 0.02, 18), 40)

        var x = visible.midX - w / 2
        var y = visible.midY - h / 2
        switch origin {
        case .center: y += visible.height * 0.08
        case .top: y = visible.maxY - edgeGapV - h
        case .bottom: y = visible.minY + edgeGapV
        case .left: x = visible.minX + edgeGapH
        case .right: x = visible.maxX - edgeGapH - w
        }
        x = min(max(x, visible.minX + 8), visible.maxX - 8 - w)
        y = min(max(y, visible.minY + 8), visible.maxY - 8 - h)
        let panel = CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())

        let offset: CGVector
        switch origin {
        case .center: offset = .zero
        case .top: offset = CGVector(dx: 0, dy: visible.maxY - panel.maxY)
        case .bottom: offset = CGVector(dx: 0, dy: visible.minY - panel.minY)
        case .left: offset = CGVector(dx: visible.minX - panel.minX, dy: 0)
        case .right: offset = CGVector(dx: visible.maxX - panel.maxX, dy: 0)
        }

        let thin: CGFloat = 40
        let longH = min(220, w * 0.34).rounded()
        let longV = min(200, h * 0.46).rounded()
        let pill: CGRect
        switch origin {
        case .center: pill = CGRect(origin: .zero, size: panel.size)
        case .top: pill = CGRect(x: (w - longH) / 2, y: h - thin, width: longH, height: thin)
        case .bottom: pill = CGRect(x: (w - longH) / 2, y: 0, width: longH, height: thin)
        case .left: pill = CGRect(x: 0, y: (h - longV) / 2, width: thin, height: longV)
        case .right: pill = CGRect(x: w - thin, y: (h - longV) / 2, width: thin, height: longV)
        }

        let travelled = panel.offsetBy(dx: offset.dx, dy: offset.dy)
        let window = panel.union(travelled).insetBy(dx: -shadowMargin, dy: -shadowMargin).integral
        return PanelGeometry(origin: origin, panel: panel, window: window, startOffset: offset, pill: pill)
    }

    var morphs: Bool { origin != .center }

    /// The visible shape at `progress` (0 = pill, 1 = full panel), in panel coordinates.
    func shape(at progress: CGFloat) -> (rect: CGRect, radius: CGFloat) {
        let full = CGRect(origin: .zero, size: panel.size)
        guard morphs else { return (full, Self.cornerRadius) }
        let p = min(max(progress, 0), 1)   // overshoot past 1 would only be clipped away
        let rect = CGRect(
            x: lerp(pill.minX, full.minX, p),
            y: lerp(pill.minY, full.minY, p),
            width: lerp(pill.width, full.width, p),
            height: lerp(pill.height, full.height, p)
        )
        let pillRadius = min(pill.width, pill.height) / 2 - 0.5
        return (rect, lerp(pillRadius, Self.cornerRadius, p))
    }

    /// Translation of the panel at `progress` (overshoot allowed: that's the "settle").
    func offset(at progress: CGFloat) -> CGVector {
        CGVector(dx: startOffset.dx * (1 - progress), dy: startOffset.dy * (1 - progress))
    }

    func scale(at progress: CGFloat) -> CGFloat {
        morphs ? 1 : lerp(Self.centerStartScale, 1, progress)
    }

    /// The panel's frame inside the window.
    var panelInWindow: CGRect {
        panel.offsetBy(dx: -window.minX, dy: -window.minY)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}
