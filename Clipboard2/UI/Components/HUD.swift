import AppKit
import SwiftUI

/// A brief confirmation bubble near the bottom of the screen ("Sent to Team"). Never takes focus.
enum HUD {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", duration: Duration = .seconds(1.6)) {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: HUDView(text: text, symbol: symbol))
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - host.fittingSize.width / 2, y: frame.minY + frame.height * 0.14))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        return panel
    }
}

private struct HUDView: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.title3.weight(.medium))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .fixedSize()
    }
}
