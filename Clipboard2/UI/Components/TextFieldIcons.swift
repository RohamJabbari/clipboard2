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
