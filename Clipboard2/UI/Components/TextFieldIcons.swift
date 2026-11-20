import AppKit
import SwiftUI
import KeyboardShortcuts

/// A small window over other apps that takes clicks but never focus, so typing stays in the app.
final class FloatingPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Places the window at `origin`, kept inside the screen the point is on.
    func place(at origin: CGPoint, near anchor: CGPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        var frame = NSRect(origin: origin, size: self.frame.size)
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX + 4), visible.maxX - frame.width - 4)
            frame.origin.y = min(max(frame.minY, visible.minY + 4), visible.maxY - frame.height - 4)
        }
        setFrame(frame, display: true)
    }
}

// MARK: - Paste icon in text fields

/// A quiet icon in the corner of the focused text field in another app. Hovering it shows the
/// newest copies; clicking one pastes it where the cursor is, without leaving the app. It stays
/// faint until the pointer reaches it, so it never competes with what's being typed.
final class PasteIconController {
    private let env: AppEnvironment
    private var field: TextFieldWatcher.Field?
    private var icon: FloatingPanel?
    private var popover: FloatingPanel?
    private let model = PastePopoverModel()
    private var overIcon = false
    private var overPopover = false
    private var pendingHover: DispatchWorkItem?

    private static let iconSize = CGSize(width: 22, height: 22)
    /// Opacity while nobody's reaching for it; full on hover and while its list is open.
    static let idleAlpha: CGFloat = 0.35
    static let itemCount = 6

    init(env: AppEnvironment) {
        self.env = env
    }

    func update(_ field: TextFieldWatcher.Field?) {
        guard field != self.field else { return }
        self.field = field
        guard let field else {
            hide()
            return
        }
        showIcon(for: field)
    }

    func hide() {
        field = nil
        overIcon = false   // it may vanish under the pointer, with no exit to report
        closePopover()
        icon?.orderOut(nil)
    }

    private func showIcon(for field: TextFieldWatcher.Field) {
        let panel = icon ?? FloatingPanel(size: Self.iconSize)
        if icon == nil {
            let host = FirstClickHostingView(rootView: PasteIconButton { [weak self] in self?.togglePopover() })
            panel.contentView = HoverTrackingView(content: host) { [weak self] inside in
                self?.overIcon = inside
                self?.hoverChanged()
            }
            icon = panel
        }
        let frame = field.frame
        let size = Self.iconSize
        // Single-line fields: at the end, centred. Larger areas: the bottom-right corner.
        let y = frame.height < 44 ? frame.midY - size.height / 2 : frame.minY + 6
        panel.place(at: CGPoint(x: frame.maxX - size.width - 6, y: y), near: CGPoint(x: frame.midX, y: frame.midY))
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = iconAlpha }
        }
        if popover != nil { positionPopover() }
    }

    private var iconAlpha: CGFloat { overIcon || popover != nil ? 1 : Self.idleAlpha }

    /// Brightens the icon the moment the pointer arrives, and dims it once the list is gone.
    private func updateIconAlpha() {
        guard let icon, icon.isVisible, icon.alphaValue != iconAlpha else { return }
        let alpha = iconAlpha
        NSAnimationContext.runAnimationGroup { context in
            context.duration = alpha == 1 ? 0.1 : 0.25
            icon.animator().alphaValue = alpha
        }
    }

    // MARK: Hover

    private func hoverChanged() {
        pendingHover?.cancel()
        updateIconAlpha()
        let open = overIcon || overPopover
        guard open != (popover != nil) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if overIcon || overPopover { openPopover() } else { closePopover() }
        }
        pendingHover = work
        // Open quickly on purpose, close a little later so crossing the gap doesn't close it.
        DispatchQueue.main.asyncAfter(deadline: .now() + (open ? 0.12 : 0.3), execute: work)
    }

    private func togglePopover() {
        popover == nil ? openPopover() : closePopover()
    }

    // MARK: Popover

    private func openPopover() {
        guard popover == nil, let field else { return }
        // Contacts' items live in the panel's Inbox only.
        let sync = env.sync
        model.items = Array(env.store.allItems().lazy.filter { sync.isListed($0, inInbox: false) }.prefix(Self.itemCount))
        model.hovered = nil
        guard !model.items.isEmpty else { return }
        let view = PastePopoverView(
            model: model,
            shortcut: KeyboardShortcuts.getShortcut(for: .toggleQuickPanel).map { "\($0)" },
            onPaste: { [weak self] item in
                guard let self else { return }
                closePopover()
                env.paste.paste(item, into: field.app)
            },
            onShowAll: { [weak self] in
                self?.closePopover()
                self?.env.showQuickPanel()
            },
            appName: field.app.localizedName,
            onHideInApp: { [weak self] in self?.hide(in: field.app) })
        let host = FirstClickHostingView(rootView: view)
        let size = host.fittingSize
        let panel = FloatingPanel(size: size)
        panel.contentView = HoverTrackingView(content: host) { [weak self] inside in
            self?.overPopover = inside
            self?.hoverChanged()
        }
        popover = panel
        updateIconAlpha()
        positionPopover()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    /// Above the icon, right-aligned with it; below when there's no room above.
    private func positionPopover() {
        guard let popover, let icon else { return }
        let size = popover.frame.size
        let iconFrame = icon.frame
        let screen = NSScreen.screens.first { $0.frame.contains(iconFrame.origin) } ?? NSScreen.main
        var y = iconFrame.maxY + 6
        if let visible = screen?.visibleFrame, y + size.height > visible.maxY { y = iconFrame.minY - 6 - size.height }
        popover.place(at: CGPoint(x: iconFrame.maxX - size.width, y: y), near: iconFrame.origin)
    }

    private func closePopover() {
        pendingHover?.cancel()
        overPopover = false
        popover?.orderOut(nil)
        popover = nil
        updateIconAlpha()
    }

    /// "Don't Show in ‹App›": only the paste icon; the icon beside selected text stays.
    private func hide(in app: NSRunningApplication) {
        guard let ref = FrontmostAppTracker.ref(for: app) else { return }
        if !env.prefs.pasteIconHiddenApps.contains(ref) { env.prefs.pasteIconHiddenApps.append(ref) }
        hide()
        HUD.show("Paste icon hidden in \(ref.name). Settings → General brings it back.", symbol: "eye.slash",
                 duration: .seconds(2.6))
    }
}

@Observable
final class PastePopoverModel {
    var items: [ClipItem] = []
    var hovered: Int?
}

/// Hosts a view and reports the pointer entering and leaving it, even while another app is
/// active (the tracking area is always on).
final class HoverTrackingView: NSView {
    private let onChange: (Bool) -> Void

    init(content: NSView, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(origin: .zero, size: content.fittingSize))
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onChange(true) }
    override func mouseExited(with event: NSEvent) { onChange(false) }
}

/// Reports the pointer over one row, even while another app is active.
private struct RowHover: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> RowHoverView { RowHoverView(onChange: onChange) }
    func updateNSView(_ view: RowHoverView, context: Context) { view.onChange = onChange }

    final class RowHoverView: NSView {
        var onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
        // Clicks go to the row's button above.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The small round icon in the field's corner.
private struct PasteIconButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "list.clipboard")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22)
        .help("Paste a recent copy")
        .accessibilityLabel("Paste a recent copy")
    }
}

/// The newest copies; the hovered one's full text shows underneath.
private struct PastePopoverView: View {
    @Bindable var model: PastePopoverModel
    let shortcut: String?
    let onPaste: (ClipItem) -> Void
    let onShowAll: () -> Void
    /// The app being typed in, for "Don't Show in ‹App›".
    let appName: String?
    let onHideInApp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Paste").font(.headline)
                Spacer()
                Button(action: onShowAll) {
                    HStack(spacing: 5) {
                        Text("All History")
                        if let shortcut {
                            Text(shortcut)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 4)
                                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                Button { onPaste(item) } label: {
                    row(item, hot: model.hovered == index)
                }
                .buttonStyle(.plain)
                .background(RowHover { inside in
                    if inside { model.hovered = index } else if model.hovered == index { model.hovered = nil }
                })
                .accessibilityLabel(PasteRowText.accessibility(item))
            }
            Text(model.hovered.flatMap { model.items.indices.contains($0) ? PasteRowText.preview(model.items[$0]) : nil }
                 ?? "Click an item to paste it where you're typing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 4)
            if let appName {
                Button(action: onHideInApp) {
                    Label("Don't Show in \(appName)", systemImage: "eye.slash")
                        .labelStyle(.titleAndIcon)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Hide the paste icon in \(appName). Settings → General brings it back.")
                .padding(.horizontal, 6)
                .padding(.top, 6)
            }
        }
        .padding(8)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }

    private func row(_ item: ClipItem, hot: Bool) -> some View {
        HStack(spacing: 10) {
            ContentBadge(kind: .clip(item), isSelected: hot, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(PasteRowText.title(item))
                    .lineLimit(1)
                    .foregroundStyle(hot ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Text(PasteRowText.subtitle(item))
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(hot ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(hot ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Row text for the paste list: hidden credentials stay masked, links read as host and path.
private enum PasteRowText {
    static func hiddenKind(_ item: ClipItem) -> SensitiveText.Kind? {
        guard case .sensitive(let kind) = ClipContentCache.content(of: item), kind.isConfident else { return nil }
        return kind
    }

    static func title(_ item: ClipItem) -> String {
        if let label = item.label { return label }
        if let kind = hiddenKind(item) { return SensitiveText.masked(item.text, kind: kind) }
        if case .link(let url) = ClipContentCache.content(of: item) {
            let host = (url.host() ?? "").replacingOccurrences(of: "www.", with: "", options: .anchored)
            return host + (url.path() == "/" ? "" : url.path())
        }
        return item.preview.isEmpty ? item.kind.displayName : item.preview
    }

    static func subtitle(_ item: ClipItem) -> String {
        let place = [item.sourceAppName, item.lastCopiedAt.shortRelative].compactMap { $0 }.joined(separator: " · ")
        if let kind = hiddenKind(item) { return "Hidden \(kind.inlineName) · \(place)" }
        return place
    }

    static func preview(_ item: ClipItem) -> String {
        if let kind = hiddenKind(item) { return "Hidden \(kind.inlineName). It pastes the real value." }
        switch item.kind {
        case .image: return "Image · \(item.imageWidth) × \(item.imageHeight)"
        case .file: return item.fileURLs.map(\.lastPathComponent).joined(separator: ", ")
        default: return String(item.text.prefix(300))
        }
    }

    static func accessibility(_ item: ClipItem) -> String {
        hiddenKind(item).map { "Hidden \($0.inlineName)" } ?? item.accessibilityDescription
    }
}
