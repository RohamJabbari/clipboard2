import AppKit
import SwiftUI

/// A brief confirmation bubble near the bottom of the screen ("Sent to Team"). Never takes focus.
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", duration: Duration = .seconds(1.6)) {
        present(HUDView(text: text, symbol: symbol), announcing: text)
        hide(after: duration)
    }

    /// Stays up, following `progress`, until `hide()` or the next `show`.
    static func show(progress: HUDProgress) {
        present(ProgressHUDView(progress: progress), announcing: progress.title)
    }

    static func hide(after delay: Duration = .zero) {
        hideTask?.cancel()
        guard let panel else { return }
        hideTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private static func present(_ view: some View, announcing text: String) {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: view)
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

/// What a progress HUD shows; change it and the HUD follows.
@MainActor @Observable
final class HUDProgress {
    var title: String
    var detail = ""
    /// nil while the size is unknown: an indeterminate bar.
    var fraction: Double?
    var symbol = "arrow.down.circle.fill"

    init(title: String) { self.title = title }
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

private struct ProgressHUDView: View {
    let progress: HUDProgress

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: progress.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 6) {
                Text(progress.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .animation(.smooth(duration: 0.2), value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text(progress.detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
