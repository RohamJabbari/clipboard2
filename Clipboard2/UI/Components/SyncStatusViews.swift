import SwiftUI
import AppKit

/// What the sync status looks like in the menu bar, the menu and the quick panel footer.
nonisolated enum SyncIndicator: Equatable, Sendable {
    /// Not signed in: nothing is shown anywhere.
    case hidden
    case synced(Date?)
    case syncing
    case offline
    case error(String)

    enum Tone: Equatable { case ok, busy, warning, problem }

    /// Small mark on the menu bar icon. Only for states that need attention, and never for the
    /// routine "syncing" (that would flicker every few seconds).
    enum Badge: Equatable { case ring, dot }

    var isVisible: Bool { self != .hidden }

    func title(now: Date = .now) -> String {
        switch self {
        case .hidden: ""
        case .synced(let date): date.map { "Synced · \(Self.ago($0, now: now))" } ?? "Synced"
        case .syncing: "Syncing…"
        case .offline: "Offline"
        case .error(let message): message.isEmpty ? "Sync failed" : message
        }
    }

    var tone: Tone {
        switch self {
        case .hidden, .synced: .ok
        case .syncing: .busy
        case .offline: .warning
        case .error: .problem
        }
    }

    var badge: Badge? {
        switch self {
        case .offline: .ring
        case .error: .dot
        default: nil
        }
    }

    var offersSyncNow: Bool {
        switch self {
        case .offline, .error: true
        default: false
        }
    }

    /// "just now", "2 min ago", "3 h ago", then the date.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) h ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

extension SyncAccount {
    /// The status as the UI shows it. Switches only on case names, so it doesn't depend on the
    /// status type's name.
    var indicator: SyncIndicator {
        switch status {
        case .idle: .synced(lastSyncAt)
        case .syncing: .syncing
        case .offline: .offline
        case .error(let message): .error(message)
        case .signedOut: .hidden
        }
    }
}

extension SyncIndicator.Tone {
    var color: Color {
        switch self {
        case .ok: .green
        case .busy: .secondary
        case .warning: .orange
        case .problem: .red
        }
    }
}

/// A small coloured dot and one line of text.
struct SyncStatusLabel: View {
    let indicator: SyncIndicator

    var body: some View {
        // The relative time ("2 min ago") stays current without anything else re-rendering.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                Circle()
                    .fill(indicator.tone.color)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(indicator.title(now: context.date))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sync: \(indicator.title(now: context.date))")
        }
    }
}

/// One quiet line in the menu bar menu while signed in to sync, with Sync Now when it's stuck.
struct SyncStatusRow: View {
    let sync: SyncAccount

    var body: some View {
        let indicator = sync.indicator
        HStack(spacing: 8) {
            SyncStatusLabel(indicator: indicator)
                .foregroundStyle(.secondary)
                .help(indicator.title())
            Spacer(minLength: 8)
            if indicator.offersSyncNow {
                Button("Sync Now") { sync.syncNow() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// The menu bar icon, with a small mark cut into its corner when sync needs attention.
/// Always drawn as a template image so it follows the menu bar's colour.
enum MenuBarIcon {
    static func image(symbol: String, badge: SyncIndicator.Badge?, description: String) -> NSImage {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: description) else {
            return NSImage()
        }
        guard let badge else {
            base.isTemplate = true
            return base
        }
        let diameter: CGFloat = 6
        let size = NSSize(width: base.size.width + 2, height: base.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(origin: .zero, size: base.size))
            let mark = NSRect(x: size.width - diameter, y: 0, width: diameter, height: diameter)
            // Clear a gap around the mark so it reads as a badge rather than part of the glyph.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: mark.insetBy(dx: -1.25, dy: -1.25)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.set()
            switch badge {
            case .dot:
                NSBezierPath(ovalIn: mark).fill()
            case .ring:
                let ring = NSBezierPath(ovalIn: mark.insetBy(dx: 0.6, dy: 0.6))
                ring.lineWidth = 1.2
                ring.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
