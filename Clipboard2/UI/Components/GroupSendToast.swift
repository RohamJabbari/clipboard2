import AppKit
import SwiftUI

/// The bubble for "send selection to group": a short countdown with Undo before anything leaves
/// this Mac, a stop when the text looks like a credential, and a confirmation with Remove.
/// Unlike `HUD` it takes clicks, but it never becomes key, so the app you're in keeps focus.
enum GroupSendToast {
    private static var panel: ToastPanel?
    private static var timer: Task<Void, Never>?
    /// The send waiting for its countdown; a new toast sends it first, as it would have been anyway.
    private static var pendingSend: (() -> Void)?

    /// Sends after `delay` unless Undo is pressed.
    static func confirm(group: SyncGroup, preview: String, delay: Duration = .seconds(3),
                        send: @escaping () -> Void, undo: @escaping () -> Void) {
        flushPending()
        pendingSend = send
        let deadline = Date.now.addingTimeInterval(delay.seconds)
        present(.pending(group: group, preview: preview, deadline: deadline, total: delay.seconds),
                announcement: "Sending to \(group.name). Undo to stop it.",
                actions: ToastActions(
                    primary: { sendNow() },
                    secondary: {
                        cancel()
                        undo()
                        HUD.show("Not sent", symbol: "arrow.uturn.backward.circle.fill")
                    }))
        timer = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            sendNow()
        }
    }

    /// The selection looked like a password or key and was not sent.
    static func blocked(_ kind: SensitiveText.Kind, group: SyncGroup,
                        sendAnyway: @escaping () -> Void, saveAsSecret: @escaping () -> Void, dismissed: @escaping () -> Void) {
        flushPending()
        present(.blocked(kind: kind, group: group),
                announcement: "Not sent. This looks like \(kind.description).",
                actions: ToastActions(
                    primary: { cancel(); saveAsSecret() },
                    secondary: { cancel(); sendAnyway() }))
        hideLater(after: .seconds(10), then: dismissed)
    }

    /// Confirms a send. `remove` takes the item back out of the group (nil when it was already there).
    static func sent(group: SyncGroup, remove: (() -> Void)?) {
        present(.sent(group: group, canRemove: remove != nil),
                announcement: "Sent to \(group.name).",
                actions: ToastActions(
                    primary: nil,
                    secondary: remove.map { remove in { hide(); remove() } }))
        hideLater(after: .seconds(6))
    }

    // MARK: Private

    private static func sendNow() {
        guard let send = pendingSend else { return }
        timer?.cancel()
        pendingSend = nil
        send()
    }

    private static func flushPending() {
        timer?.cancel()
        sendNow()
    }

    private static func cancel() {
        timer?.cancel()
        pendingSend = nil
        hide()
    }

    private static func present(_ content: ToastContent, announcement: String, actions: ToastActions) {
        timer?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = FirstClickHostingView(rootView: GroupSendToastView(content: content, actions: actions))
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
                             userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private static func hideLater(after duration: Duration, then done: (() -> Void)? = nil) {
        timer = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            hide()
            done?()
        }
    }

    private static func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }

    private static func makePanel() -> ToastPanel {
        let panel = ToastPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        return panel
    }
}

/// Takes clicks without ever becoming key, so focus stays in the app the user is typing in.
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum ToastContent {
    case pending(group: SyncGroup, preview: String, deadline: Date, total: TimeInterval)
    case blocked(kind: SensitiveText.Kind, group: SyncGroup)
    case sent(group: SyncGroup, canRemove: Bool)
}

private struct ToastActions {
    /// Send Now, Save as Secret.
    var primary: (() -> Void)?
    /// Undo, Send Anyway, Remove.
    var secondary: (() -> Void)?
}

private struct GroupSendToastView: View {
    let content: ToastContent
    let actions: ToastActions

    var body: some View {
        Group {
            switch content {
            case .pending(let group, let preview, let deadline, let total):
                pending(group: group, preview: preview, deadline: deadline, total: total)
            case .blocked(let kind, let group):
                blocked(kind: kind, group: group)
            case .sent(let group, let canRemove):
                sent(group: group, canRemove: canRemove)
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }

    private func pending(group: SyncGroup, preview: String, deadline: Date, total: TimeInterval) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let remaining = max(0, deadline.timeIntervalSince(context.date))
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 11) {
                    badge("person.2.fill", .purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sending to \(group.name) in \(Int(remaining.rounded(.up))) s")
                            .font(.headline)
                        Text("“\(preview)”")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                ProgressView(value: total > 0 ? 1 - remaining / total : 1)
                    .progressViewStyle(.linear)
                    .tint(.purple)
                    .accessibilityHidden(true)
                HStack(spacing: 8) {
                    Text(members(group, future: true))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    button("Undo", prominent: false, action: actions.secondary)
                    button("Send Now", prominent: true, action: actions.primary)
                }
            }
        }
    }

    private func blocked(kind: SensitiveText.Kind, group: SyncGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                badge("exclamationmark.shield.fill", .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Not sent. This looks like \(kind.description).")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Passwords, keys and codes stay on this Mac unless you send one on purpose.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                button("Send to \(group.name) Anyway", prominent: false, action: actions.secondary)
                button("Save as Secret", prominent: true, action: actions.primary)
            }
        }
    }

    private func sent(group: SyncGroup, canRemove: Bool) -> some View {
        HStack(spacing: 11) {
            badge("checkmark", .green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sent to \(group.name)").font(.headline)
                Text(members(group, future: false)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if canRemove {
                button("Remove", prominent: false, action: actions.secondary)
            }
        }
    }

    private func members(_ group: SyncGroup, future: Bool) -> String {
        let others = max(group.memberCount - 1, 0)
        if others == 0 { return "Only you are in this group" }
        let people = others == 1 ? "1 other person" : "\(others) other people"
        return future ? "\(people) will see it" : "\(people) can see it"
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(color.gradient, in: Circle())
            .accessibilityHidden(true)
    }

    private func button(_ title: String, prominent: Bool, action: (() -> Void)?) -> some View {
        Button(title) { action?() }
            .buttonStyle(.plain)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? AnyShapeStyle(.black) : AnyShapeStyle(.white))
            .background(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.16)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .disabled(action == nil)
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// A hosting view whose buttons work on the first click, even while another app is active.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
