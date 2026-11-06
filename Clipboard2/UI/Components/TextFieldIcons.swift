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

// MARK: - Icon beside selected text

/// The icon beside text selected in another app. Clicking it offers Fix Grammar, Translate,
/// Summarize and more; AI results open in a bubble with Replace and Copy, so the user never
/// leaves the app they're writing in.
final class SelectionIconController {
    private let env: AppEnvironment
    private var selection: TextFieldWatcher.Selection?
    private var icon: FloatingPanel?
    private var bubble: FloatingPanel?
    private var run: AIRun?
    private var isMenuOpen = false

    private static let iconSize = CGSize(width: 26, height: 26)
    private static let bubbleSize = CGSize(width: 400, height: 220)

    init(env: AppEnvironment) {
        self.env = env
    }

    func update(_ selection: TextFieldWatcher.Selection?) {
        guard !isMenuOpen else { return }
        if let selection, let current = self.selection, selection.text == current.text, selection.app == current.app {
            // Same text, perhaps moved with its window: follow it unless a result is showing.
            self.selection = selection
            if bubble == nil { showIcon() }
            return
        }
        self.selection = selection
        closeBubble()
        if selection == nil { hideIcon() } else { showIcon() }
    }

    func hideAll() {
        selection = nil
        closeBubble()
        hideIcon()
    }

    // MARK: Icon

    private func showIcon() {
        guard let selection else { return }
        let panel = icon ?? FloatingPanel(size: Self.iconSize)
        if icon == nil {
            panel.contentView = FirstClickHostingView(rootView: SelectionIconButton { [weak self] in self?.openMenu() })
            icon = panel
        }
        let anchor = selection.anchor
        panel.place(at: CGPoint(x: anchor.maxX + 5, y: anchor.midY - Self.iconSize.height / 2), near: anchor.origin)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
    }

    private func hideIcon() {
        icon?.orderOut(nil)
    }

    // MARK: Menu

    private func openMenu() {
        guard let selection, let icon else { return }
        let menu = NSMenu(title: "Clipboard2")
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "\(selection.text.count) characters selected"))
        menu.addItem(item("Fix Grammar & Spelling", symbol: "checkmark.seal") { [weak self] in self?.startRun(.fixGrammar) })
        let translate = NSMenuItem(title: "Translate", action: nil, keyEquivalent: "")
        translate.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: nil)
        let languages = NSMenu(title: "Translate")
        for language in ["English", "German", "Farsi"] {
            languages.addItem(item(language, symbol: nil) { [weak self] in self?.startRun(.translate(language: language)) })
        }
        translate.submenu = languages
        menu.addItem(translate)
        menu.addItem(item("Summarize", symbol: "text.line.first.and.arrowtriangle.forward") { [weak self] in self?.startRun(.summarize) })
        menu.addItem(item("Make Shorter", symbol: "arrow.down.right.and.arrow.up.left") { [weak self] in
            self?.startRun(.instruction("Make this shorter, keeping its meaning and tone."))
        })
        let more = item("More Actions & Ask AI…", symbol: "wand.and.stars") { [weak self] in
            guard let self else { return }
            hideAll()
            env.showSelectionActions(text: selection.text)
        }
        more.setShortcut(for: .selectionActions)
        menu.addItem(more)
        menu.addItem(.separator())
        menu.addItem(item("Save as Snippet", symbol: "text.badge.star") { [weak self] in self?.saveSnippet(selection.text) })
        menu.addItem(item("Save as Secret…", symbol: "key") { [weak self] in
            guard let self else { return }
            hideAll()
            env.panel.showForSelection(selection.text, target: selection.app) { [env] in
                if let item = env.panel.model.selectionItem { env.panel.model.beginSaveSecret(item) }
            }
        })
        menu.addItem(item("Copy", symbol: "doc.on.doc") { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selection.text, forType: .string)
            HUD.show("Copied", symbol: "doc.on.doc.fill")
            self?.hideAll()
        })
        menu.addItem(.separator())
        if let name = selection.app.localizedName {
            menu.addItem(item("Don't Show in \(name)", symbol: "eye.slash") { [weak self] in self?.hide(in: selection.app) })
        }

        isMenuOpen = true
        // Doesn't activate Clipboard2: the app with the selection keeps focus throughout.
        menu.popUp(positioning: nil, at: NSPoint(x: icon.frame.minX, y: icon.frame.minY - 4), in: nil)
        isMenuOpen = false
    }

    private func item(_ title: String, symbol: String?, action: @escaping () -> Void) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: #selector(MenuActionTarget.perform(_:)), keyEquivalent: "")
        menuItem.target = MenuActionTarget.shared
        menuItem.representedObject = MenuActionTarget.Handler(action)
        if let symbol { menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return menuItem
    }

    private func saveSnippet(_ text: String) {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(5).joined(separator: " ")
        let name = words.count > 40 ? String(words.prefix(40)) + "…" : words
        _ = env.snippets.create(name: name, body: text)
        HUD.show("Saved as snippet “\(name)”", symbol: "text.badge.star")
        hideAll()
    }

    private func hide(in app: NSRunningApplication) {
        guard let ref = FrontmostAppTracker.ref(for: app) else { return }
        if !env.prefs.textIconHiddenApps.contains(ref) { env.prefs.textIconHiddenApps.append(ref) }
        hideAll()
        HUD.show("Hidden in \(ref.name). Settings → General brings it back.", symbol: "eye.slash", duration: .seconds(2.6))
    }

    // MARK: Result bubble

    private func startRun(_ action: AIAction) {
        guard let selection else { return }
        run?.cancel()
        let item = ClipItem(capture: .text(selection.text, source: FrontmostAppTracker.ref(for: selection.app)))
        let run = AIRun(action: action, item: item, providerName: env.prefs.aiProvider.title)
        self.run = run
        run.start(prefs: env.prefs)
        showBubble(run, for: selection)
    }

    private func showBubble(_ run: AIRun, for selection: TextFieldWatcher.Selection) {
        hideIcon()
        let view = SelectionResultView(
            run: run, original: selection.text,
            onReplace: { [weak self] text in
                guard let self else { return }
                env.paste.pastePreservingClipboard(text: text, into: selection.app) {}
                hideAll()
            },
            onCopy: { [weak self] text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                HUD.show("Copied", symbol: "doc.on.doc.fill")
                self?.hideAll()
            },
            onRetry: { [weak self] in self?.startRun(run.action) },
            onSettings: { [weak self] in
                self?.hideAll()
                SettingsOpener.open(tab: .actions)
            },
            onClose: { [weak self] in self?.hideAll() })
        let panel = bubble ?? FloatingPanel(size: Self.bubbleSize)
        panel.contentView = FirstClickHostingView(rootView: view)
        bubble = panel
        // Below the selection, or above it when there's no room.
        let anchor = selection.anchor
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        var y = anchor.minY - 10 - Self.bubbleSize.height
        if let visible = screen?.visibleFrame, y < visible.minY { y = anchor.maxY + 10 }
        panel.place(at: CGPoint(x: anchor.maxX - 24, y: y), near: anchor.origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    }

    private func closeBubble() {
        run?.cancel()
        run = nil
        bubble?.orderOut(nil)
        bubble = nil
    }
}

/// The round icon itself.
private struct SelectionIconButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "list.clipboard")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.gradient, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 26, height: 26)
        .help("Clipboard2: fix, translate or summarize (⌥⌘K)")
        .accessibilityLabel("Clipboard2 actions for the selected text")
    }
}

/// The streamed result, shown as changes for Fix Grammar, with Replace, Copy and Try Again.
private struct SelectionResultView: View {
    let run: AIRun
    let original: String
    let onReplace: (String) -> Void
    let onCopy: (String) -> Void
    let onRetry: () -> Void
    let onSettings: () -> Void
    let onClose: () -> Void

    private var result: String { run.output.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView {
                content
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            buttons
        }
        .padding(14)
        .frame(width: 400, height: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if run.isStreaming {
                ProgressView().controlSize(.small)
                Text(run.action.title + "…").fontWeight(.semibold)
            } else if run.errorMessage != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't finish").fontWeight(.semibold)
            } else if case .fixGrammar = run.action {
                let changes = WordDiff.changeCount(WordDiff.diff(original, result))
                Image(systemName: changes == 0 ? "checkmark.seal.fill" : "checkmark.circle.fill").foregroundStyle(.green)
                Text(changes == 0 ? "No mistakes found" : changes == 1 ? "1 fix" : "\(changes) fixes").fontWeight(.semibold)
            } else {
                Text(run.action.title).fontWeight(.semibold)
            }
            Text("· \(run.providerName)").foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close")
        }
        .font(.callout)
    }

    @ViewBuilder
    private var content: some View {
        if let error = run.errorMessage {
            Text(error).foregroundStyle(.secondary)
        } else if case .fixGrammar = run.action, run.isFinished {
            WordDiff.diff(original, result).reduce(Text("")) { text, part in
                switch part {
                case .same(let s): text + Text(s)
                case .removed(let s): text + Text(s).strikethrough().foregroundStyle(.red)
                case .added(let s): text + Text(s).foregroundStyle(.green).bold()
                }
            }
        } else {
            Text(result.isEmpty ? " " : result)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if run.errorMessage != nil {
                Button("Try Again", action: onRetry)
                Button("AI Settings…", action: onSettings)
            } else {
                Button("Replace") { onReplace(result) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!run.isFinished)
                Button("Copy") { onCopy(result) }
                    .disabled(!run.isFinished)
                Button("Try Again", action: onRetry)
                    .buttonStyle(.borderless)
                    .disabled(run.isStreaming)
            }
            Spacer()
        }
        .controlSize(.regular)
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
            })
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
