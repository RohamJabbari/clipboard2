import Testing
import CoreGraphics
import Foundation
@testable import Clipboard2

@MainActor
struct PanelMotionTests {
    @Test func openSpringOvershootsSlightlyAndDoesNotWobble() {
        let spring = QuickPanelController.openSpring
        var peak = 0.0
        var crossings = 0
        var previousAbove = false
        for step in 0...600 {
            let value = spring.state(at: Double(step) / 600).value
            peak = max(peak, value)
            let above = value > 1.0005
            if above != previousAbove { crossings += 1 }
            previousAbove = above
        }
        #expect(peak > 1.005)          // a touch of overshoot…
        #expect(peak < 1.04)           // …but only a touch
        #expect(crossings <= 2)        // up through 1 and back once: no visible wobble
    }

    @Test func openSettlesInAboutThreeHundredMilliseconds() {
        let time = QuickPanelController.openSpring.settlingTime(tolerance: 0.01)
        #expect(time > 0.22 && time < 0.4)
    }

    @Test func closeIsFasterAndNeverOvershoots() {
        let close = QuickPanelController.closeSpring
        #expect(close.settlingTime(tolerance: 0.01) < QuickPanelController.openSpring.settlingTime(tolerance: 0.01))
        for step in 0...300 {
            #expect(close.state(at: Double(step) / 300).value <= 1.0001)
        }
    }

    @Test func springStateMatchesFiniteDifferences() {
        let spring = PanelSpring(response: 0.34, dampingRatio: 0.78)
        let t = 0.08, h = 1e-5
        let v = spring.state(at: t, initialVelocity: 2).velocity
        let numeric = (spring.state(at: t + h, initialVelocity: 2).value - spring.state(at: t - h, initialVelocity: 2).value) / (2 * h)
        #expect(abs(v - numeric) < 1e-3)
        #expect(spring.state(at: 0).value == 0)
    }

    @Test func topPanelHangsBelowTheMenuBarAndStartsAtTheEdge() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let g = PanelGeometry.make(origin: .top, size: CGSize(width: 780, height: 480), visible: visible)
        #expect(g.panel.maxY < visible.maxY)
        #expect(abs(g.panel.midX - visible.midX) <= 1)
        // At progress 0 the pill touches the top edge.
        let start = g.offset(at: 0)
        #expect(abs(g.panel.minY + g.pill.maxY + start.dy - visible.maxY) < 0.5)
        #expect(g.pill.height < g.pill.width)
        #expect(g.window.contains(g.panel))
        #expect(g.window.maxY >= visible.maxY)
    }

    @Test func everyOriginStaysOnScreenAndMorphsFromItsEdge() {
        let visible = CGRect(x: 100, y: 50, width: 1440, height: 875)
        for origin in PanelOrigin.allCases {
            let g = PanelGeometry.make(origin: origin, size: CGSize(width: 920, height: 580), visible: visible)
            #expect(visible.contains(g.panel), "\(origin)")
            let full = g.shape(at: 1)
            #expect(full.rect.size == g.panel.size)
            #expect(full.radius == PanelGeometry.cornerRadius)
            switch origin {
            case .center:
                #expect(g.startOffset == .zero)
                #expect(g.scale(at: 0) < 1)
            case .left, .right:
                #expect(g.pill.width < g.pill.height)
                #expect(g.startOffset.dy == 0)
            case .top, .bottom:
                #expect(g.startOffset.dx == 0)
            }
        }
    }

    @Test func oldSettingsTabsStillOpen() {
        #expect(SettingsTab(stored: "ai") == .actions)
        #expect(SettingsTab(stored: "transforms") == .actions)
        #expect(SettingsTab(stored: "ignoredApps") == .history)
        #expect(SettingsTab(stored: "permissions") == .general)
        #expect(SettingsTab(stored: "about") == .general)
        #expect(SettingsTab(stored: "sync") == .sync)
        #expect(SettingsTab(stored: "nonsense") == nil)
    }

    @Test func panelOriginDefaultsToTop() throws {
        let defaults = try #require(UserDefaults(suiteName: "PanelOrigin-\(UUID())"))
        #expect(Preferences(defaults: defaults).panelOrigin == .top)
        defaults.set("left", forKey: Preferences.Key.panelOrigin)
        #expect(Preferences(defaults: defaults).panelOrigin == .left)
    }
}
