import AppKit
import SwiftUI

/// A short notice with one button ("Saved a password for github.com · Undo"), near the bottom of
/// the screen. It takes clicks but never focus, so the app being typed in keeps it.
@MainActor
enum ActionToast {
    private static var panel: FloatingPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String, action title: String, duration: Duration = .seconds(6), action: @escaping () -> Void) {
        hideTask?.cancel()
        let view = ActionToastView(text: text, actionTitle: title) {
            hide()
            action()
        }
        let host = FirstClickHostingView(rootView: view)
        let size = host.fittingSize
        let panel = self.panel ?? FloatingPanel(size: size)
        self.panel = panel
        host.frame.size = size
        panel.contentView = host
        panel.setContentSize(size)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.14))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    static func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }
}

private struct ActionToastView: View {
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.body.weight(.medium))
            Button(actionTitle, action: action)
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .fixedSize()
    }
}
