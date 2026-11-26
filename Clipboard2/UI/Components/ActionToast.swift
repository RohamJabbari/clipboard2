import AppKit
import SwiftUI

/// A short notice with buttons ("Saved a password for github.com · Undo"), near the bottom of
/// the screen. It takes clicks but never focus, so the app being typed in keeps it.
@MainActor
enum ActionToast {
    struct Action {
        var title: String
        /// The default button (bold).
        var isPrimary = false
        var run: () -> Void
    }

    private static var panel: FloatingPanel?
    private static var hideTask: Task<Void, Never>?
    /// Called when the current toast goes without a button (timed out, replaced or hidden).
    private static var onDismiss: (() -> Void)?

    static func show(_ text: String, action title: String, duration: Duration = .seconds(6), action: @escaping () -> Void) {
        show(text, actions: [Action(title: title, isPrimary: true, run: action)], duration: duration)
    }

    /// `detail` is a second, quieter line (a username). `onDismiss` runs when no button was pressed.
    static func show(_ text: String, detail: String? = nil, symbol: String = "checkmark.circle.fill",
                     actions: [Action], duration: Duration = .seconds(6), onDismiss: (() -> Void)? = nil) {
        hideTask?.cancel()
        finishDismiss()
        self.onDismiss = onDismiss
        let view = ActionToastView(text: text, detail: detail, symbol: symbol, actions: actions.map { action in
            Action(title: action.title, isPrimary: action.isPrimary) {
                self.onDismiss = nil
                hide()
                action.run()
            }
        })
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
        let announcement = detail.map { "\(text) \($0)" } ?? text
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    static func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        finishDismiss()
    }

    private static func finishDismiss() {
        let dismissed = onDismiss
        onDismiss = nil
        dismissed?()
    }
}

private struct ActionToastView: View {
    let text: String
    let detail: String?
    let symbol: String
    let actions: [ActionToast.Action]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(.body.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            ForEach(actions.indices, id: \.self) { index in
                Button(actions[index].title, action: actions[index].run)
                    .buttonStyle(.borderless)
                    .fontWeight(actions[index].isPrimary ? .semibold : .regular)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, detail == nil ? 10 : 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .fixedSize()
    }
}
