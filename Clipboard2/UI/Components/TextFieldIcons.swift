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

/// A quiet icon in the corner of the focused text field in another app. Hovering it shows your
/// copies, with Saved, each group and Contacts a click away, in a list that scrolls; clicking one
/// pastes it where the cursor is, without leaving the app. It stays
/// faint until the pointer reaches it, so it never competes with what's being typed.
///
/// In a password field it lists Auth's passwords for the page's site and Suggest Strong
/// Password; in a field it recognises (email, name, address…) it offers personal info first
/// (docs/features/auth-autofill.md → Phase 2).
final class PasteIconController {
    private let env: AppEnvironment
    private var field: TextFieldWatcher.Field?
    private var icon: FloatingPanel?
    private var popover: FloatingPanel?
    private let model = PastePopoverModel()
    private var overIcon = false
    private var overPopover = false
    private var pendingHover: DispatchWorkItem?
    /// The browser page's source domain, read when the list opens.
    private var pageSite: String?
    /// What the focused text field asks for, guessed from its label when the list opens.
    private var fieldKind: FormFieldKind?

    private static let iconSize = CGSize(width: 22, height: 22)
    /// Opacity while nobody's reaching for it; full on hover and while its list is open.
    static let idleAlpha: CGFloat = 0.35
    /// Rows the list shows before it scrolls, and the most it holds.
    static let visibleRows = 6
    static let itemLimit = 500

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
        pageSite = FieldAX.pageDomain(pid: field.app.processIdentifier, bundleID: field.app.bundleIdentifier)
        if field.isSecure {
            fieldKind = nil
            model.title = "Passwords"
            model.sources = [PasteSourceChip(source: .auth, title: pageSite ?? "Auth", symbol: "key")]
            model.strongPasswords = PasswordGenerator.suggestions()
            load(.auth)
        } else {
            fieldKind = field.element.flatMap { FormFieldGuesser.guess(FieldAX.hints(of: $0)) }
            model.title = "Paste"
            model.strongPasswords = nil
            model.sources = sources()
            let offersMe = fieldKind.map { !env.cards.matches(for: $0).isEmpty } ?? false
            load(offersMe ? .me : .copies)
        }
        let view = PastePopoverView(
            model: model,
            onSource: { [weak self] source in self?.load(source) },
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
            onStrongPassword: { [weak self] password in
                guard let self, let element = field.element else { return }
                closePopover()
                env.suggestStrongPassword(password, field: element, in: field.app, site: pageSite)
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

    /// Copies and Saved always; Me with personal info cards, Auth on a page with passwords for its
    /// site; each group and Contacts while signed in to sync.
    private func sources() -> [PasteSourceChip] {
        var chips = [PasteSourceChip(source: .copies, title: "Copies", symbol: "clock"),
                     PasteSourceChip(source: .saved, title: "Saved", symbol: "bookmark")]
        if !env.cards.cards.isEmpty {
            chips.insert(PasteSourceChip(source: .me, title: "Me", symbol: "person.text.rectangle"), at: 0)
        }
        if let pageSite, env.secrets.secrets.contains(where: { SiteMatch.matches($0, domain: pageSite) }) {
            chips.append(PasteSourceChip(source: .auth, title: "Auth", symbol: "key"))
        }
        guard env.sync.isSignedIn else { return chips }
        chips += env.sync.groups.map { PasteSourceChip(source: .group($0.id), title: $0.name, symbol: "person.2") }
        chips.append(PasteSourceChip(source: .contacts, title: "Contacts", symbol: "person.crop.circle"))
        return chips
    }

    /// Fills the list from one source, newest first. Secrets stay in the panel (they need Touch ID).
    private func load(_ source: PasteSource) {
        let sync = env.sync
        let items: [ClipItem]
        model.rows = []
        switch source {
        case .auth:
            items = []
            model.rows = authRows()
        case .me:
            items = []
            model.rows = meRows()
        case .copies:
            // Contacts' items live in the Inbox only.
            items = Array(env.store.allItems().lazy.filter { sync.isListed($0, inInbox: false) }.prefix(Self.itemLimit))
        case .saved:
            items = Array(env.store.items(inSpace: nil).lazy.filter(\.isPinned).prefix(Self.itemLimit))
        case .group(let id):
            items = Array(env.store.items(inSpace: id).prefix(Self.itemLimit))
        case .contacts:
            items = Array(env.store.allItems().lazy.filter { sync.isListed($0, inInbox: true) }.prefix(Self.itemLimit))
        }
        model.source = source
        model.items = items
        model.hovered = nil
        model.byline = { item in item.spaceID == nil ? nil : sync.badge(for: item)?.text }
    }

    /// Passwords (and codes) for the page's site; every password when it isn't a browser page.
    private func authRows() -> [PasteRow] {
        guard let field else { return [] }
        let site = pageSite
        let passwords = env.secrets.secrets.filter { ref in
            guard ref.spaceID == nil || env.sync.groups.contains(where: { $0.id == ref.spaceID }) else { return false }
            return site.map { SiteMatch.matches(ref, domain: $0) } ?? ref.isPassword
        }
        .sorted { ($0.username ?? $0.name).localizedStandardCompare($1.username ?? $1.name) == .orderedAscending }
        var rows = passwords.prefix(Self.itemLimit).map { ref in
            PasteRow(id: "k-" + ref.id, title: ref.username ?? ref.name,
                     subtitle: AuthSource.of(ref)?.name ?? ref.name, symbol: "person.badge.key",
                     detail: field.isSecure ? "Fills the password." : "Fills the username and password.") { [weak self] in
                guard let self else { return }
                closePopover()
                AuthSourceUsage.shared.record(AuthSource.of(ref))
                env.fillPassword(ref, into: field.app)
            }
        }
        if let site {
            for item in env.authenticators.items where SiteMatch.matches(item, domain: site) {
                rows.append(PasteRow(id: "a-" + item.id, title: item.title, subtitle: "Authenticator code",
                                     symbol: "lock.rotation", detail: "Fills the current code.") { [weak self] in
                    guard let self, let code = item.code(at: .now) else { NSSound.beep(); return }
                    closePopover()
                    env.fillCode(code, into: field.app)
                })
            }
        }
        return rows
    }

    /// Personal info: the value the field asks for first (from each card), Fill Form, then the
    /// cards' other values.
    private func meRows() -> [PasteRow] {
        guard let field else { return [] }
        var rows: [PasteRow] = []
        var used = Set<String>()
        func valueRow(_ card: PersonalCard, _ kind: FormFieldKind, _ value: String) -> PasteRow {
            PasteRow(id: "\(card.id)-\(kind.rawValue)", title: value, subtitle: "\(card.title) · \(kind.title)",
                     symbol: kind.symbol, detail: value) { [weak self] in
                guard let self else { return }
                closePopover()
                env.fillText(value, into: field.app)
            }
        }
        if let fieldKind {
            for match in env.cards.matches(for: fieldKind) {
                rows.append(valueRow(match.card, fieldKind, match.value))
                used.insert("\(match.card.id)-\(fieldKind.rawValue)")
            }
        }
        if let element = field.element {
            for card in env.cards.cards where !card.isEmpty {
                let multiple = env.cards.cards.count > 1
                rows.append(PasteRow(id: "fill-\(card.id)", title: multiple ? "Fill Form with \(card.title)" : "Fill Form",
                                     subtitle: "Every field it recognises on this page", symbol: "text.badge.checkmark",
                                     detail: "Fills empty name, email, phone and address fields.") { [weak self] in
                    guard let self else { return }
                    closePopover()
                    env.fillForm(with: card, around: element, in: field.app)
                })
            }
        }
        for card in env.cards.cards {
            for entry in card.values where !used.contains("\(card.id)-\(entry.kind.rawValue)") {
                rows.append(valueRow(card, entry.kind, entry.value))
            }
        }
        return rows
    }

    /// "Don't Show in ‹App›": hides the paste icon in that app.
    private func hide(in app: NSRunningApplication) {
        guard let ref = FrontmostAppTracker.ref(for: app) else { return }
        if !env.prefs.pasteIconHiddenApps.contains(ref) { env.prefs.pasteIconHiddenApps.append(ref) }
        hide()
        HUD.show("Paste icon hidden in \(ref.name). Settings → General brings it back.", symbol: "eye.slash",
                 duration: .seconds(2.6))
    }
}

/// Where the paste list's items come from.
enum PasteSource: Hashable {
    case copies, saved, group(String), contacts
    /// Passwords (and codes) for the page's site.
    case auth
    /// Personal info cards.
    case me

    /// Lists `PastePopoverModel.rows` rather than clips.
    var listsRows: Bool { self == .auth || self == .me }
}

/// A row of Auth or Me in the paste list: clicking it fills.
struct PasteRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    /// Shown under the list while hovered.
    let detail: String
    let action: () -> Void
}

struct PasteSourceChip: Identifiable, Hashable {
    let source: PasteSource
    let title: String
    let symbol: String
    var id: PasteSource { source }
}

@Observable
final class PastePopoverModel {
    var sources: [PasteSourceChip] = []
    var source: PasteSource = .copies
    var items: [ClipItem] = []
    /// Auth's or Me's rows (instead of `items`).
    var rows: [PasteRow] = []
    var hovered: Int?
    var title = "Paste"
    /// Suggest Strong Password (password fields only).
    var strongPasswords: PasswordGenerator.Suggestions?
    /// Who shared or sent a group or contact item, shown instead of the app it came from.
    @ObservationIgnored var byline: (ClipItem) -> String? = { _ in nil }
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

/// Copies, Saved, groups and Contacts in a scrolling list; the hovered one's text shows underneath.
private struct PastePopoverView: View {
    @Bindable var model: PastePopoverModel
    let onSource: (PasteSource) -> Void
    let shortcut: String?
    let onPaste: (ClipItem) -> Void
    let onShowAll: () -> Void
    let onStrongPassword: (String) -> Void
    /// The app being typed in, for "Don't Show in ‹App›".
    let appName: String?
    let onHideInApp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(model.title).font(.headline)
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
            sourceChips
            list
            if let suggestions = model.strongPasswords, model.source == .auth {
                Text("Suggest Strong Password")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                PasswordSuggestionsView(suggestions: suggestions, compact: true, onPick: onStrongPassword)
                    .padding(.horizontal, 2)
            }
            Text(hoverText)
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

    private var hoverText: String {
        if model.source.listsRows {
            if let hovered = model.hovered, model.rows.indices.contains(hovered) { return model.rows[hovered].detail }
            return model.source == .auth ? "Click one to fill it. Asks for Touch ID." : "Click one to fill it where you're typing."
        }
        return model.hovered.flatMap { model.items.indices.contains($0) ? PasteRowText.preview(model.items[$0]) : nil }
            ?? "Click an item to paste it where you're typing."
    }

    /// Copies · Saved · each group · Contacts. Scrolls sideways when there are many groups.
    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.sources) { chip in
                    let selected = chip.source == model.source
                    Button { onSource(chip.source) } label: {
                        Label(chip.title, systemImage: chip.symbol)
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                            .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.07)),
                                        in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .animation(.easeOut(duration: 0.15), value: model.source)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.bottom, 4)
    }

    /// A fixed height, so the popover doesn't jump between sources; it scrolls past six rows.
    private var list: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 2) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    Button(action: row.action) {
                        extraRow(row, hot: model.hovered == index)
                    }
                    .buttonStyle(.plain)
                    .background(RowHover { inside in
                        if inside { model.hovered = index } else if model.hovered == index { model.hovered = nil }
                    })
                    .accessibilityLabel("\(row.title), \(row.subtitle)")
                }
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
            }
        }
        .id(model.source)   // back to the top when the source changes
        .overlay {
            if model.items.isEmpty && model.rows.isEmpty {
                Text(model.source == .auth ? "No passwords for this site" : "Nothing here yet")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(height: CGFloat(PasteIconController.visibleRows) * 44)
    }

    private func extraRow(_ row: PasteRow, hot: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .foregroundStyle(hot ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .background(hot ? AnyShapeStyle(.white.opacity(0.15)) : AnyShapeStyle(Color.primary.opacity(0.06)),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .lineLimit(1)
                    .foregroundStyle(hot ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Text(row.subtitle)
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

    private func row(_ item: ClipItem, hot: Bool) -> some View {
        HStack(spacing: 10) {
            ContentBadge(kind: .clip(item), isSelected: hot, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(PasteRowText.title(item))
                    .lineLimit(1)
                    .foregroundStyle(hot ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Text(PasteRowText.subtitle(item, byline: model.byline(item)))
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

    static func subtitle(_ item: ClipItem, byline: String? = nil) -> String {
        let place = [byline ?? item.sourceAppName, item.lastCopiedAt.shortRelative].compactMap { $0 }.joined(separator: " · ")
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
