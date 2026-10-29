import AppKit
import SwiftUI
import QuartzCore
import os

/// Borderless, non-activating panel: it takes keyboard focus without making Clipboard2 the active
/// app, so the app the user was typing in stays frontmost and receives the paste.
final class QuickPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // The shadow is drawn (see QuickPanelController): a window-server shadow is computed once
        // and can't follow a shape that morphs every frame.
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        setAccessibilityLabel("Clipboard2 Quick Panel")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The window's transparent root. Clicks that land on the shadow halo (not on the panel) close it.
private final class PanelRootView: NSView {
    var onClickOutside: () -> Void = {}
    override var isOpaque: Bool { false }
    override func mouseDown(with event: NSEvent) { onClickOutside() }
}

/// Presents the quick panel and drives its open/close motion.
///
/// Motion: the panel emerges from the edge chosen in Settings → Appearance as a small pill that
/// grows into the full panel while travelling into place, on a spring with a touch of overshoot.
/// "Center" scales up from slightly smaller. Everything animates with Core Animation on layers
/// (transform, a mask's bounds and corner radius, shadow path, opacity), so it runs on the render
/// server: SwiftUI lays the list out once at its final size and never per frame.
///
/// Every open/close is a spring towards progress 1 or 0. The spring's closed form tells us the
/// progress and velocity at any instant, so pressing the shortcut again mid-flight starts the
/// reverse from exactly what's on screen, carrying its velocity — no jump.
final class QuickPanelController: NSObject, NSWindowDelegate {
    enum Phase: Equatable { case hidden, opening, open, closing }

    private let env: AppEnvironment
    let model: PanelViewModel
    private(set) var phase: Phase = .hidden
    private var panel: QuickPanel?
    private var keyMonitor: Any?
    private var authObserver: NSObjectProtocol?
    /// While the mouse is held down in another app after the panel lost focus (a possible drag in).
    private var resignWatch: Timer?
    private var lastDropAt: Date?

    // View tree: root → [shadowView (our own layers), morphView → shell (material) → hosting].
    private var root: PanelRootView?
    private var shadowView: NSView?
    private var morphView: NSView?
    private var shell: NSView?
    private var shellKind: ShellKind?
    private var hosting: NSView?
    private let maskLayer = CALayer()
    private let ambientShadow = CALayer()
    private let contactShadow = CALayer()

    private var geometry: PanelGeometry?
    private var motion: Motion?
    /// Bumped on every open and close; stale completions and deferred work check it.
    private var generation = 0
    private var probe: FrameProbe?

    static let cornerRadius = PanelGeometry.cornerRadius
    static let openSpring = PanelSpring(response: 0.34, dampingRatio: 0.78)
    static let closeSpring = PanelSpring(response: 0.22, dampingRatio: 1)

    private struct Motion {
        var from: CGFloat
        var to: CGFloat
        var begin: CFTimeInterval
        var spring: PanelSpring
        var initialVelocity: Double

        func state(at time: CFTimeInterval) -> (progress: CGFloat, velocity: CGFloat) {
            let (s, ds) = spring.state(at: time - begin, initialVelocity: initialVelocity)
            return (from + (to - from) * s, (to - from) * ds)
        }
    }

    private enum ShellKind: Equatable { case glass, vibrancy, solid }

    private static let signposter = OSSignposter(logger: Log.panel)

    init(env: AppEnvironment) {
        self.env = env
        self.model = PanelViewModel(env: env)
        super.init()
        model.onClose = { [weak self] in self?.close() }
        // A drag from Finder makes Finder key on the way in; take focus back once the drop lands.
        model.onDropFinished = { [weak self] in
            guard let self, let panel = self.panel, self.isVisible else { return }
            self.lastDropAt = .now
            panel.makeKey()
        }
        // Touch ID takes key focus; take it back afterwards if the panel is still meant to be up.
        authObserver = NotificationCenter.default.addObserver(forName: SecretStore.authenticationEnded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, self.isVisible, !panel.isKeyWindow else { return }
                panel.makeKey()
            }
        }
    }

    /// True while opening or open (a closing panel counts as gone: pressing the shortcut reopens it).
    var isVisible: Bool { phase == .opening || phase == .open }

    func toggle() {
        isVisible ? close() : show()
    }

    /// Opens the panel. `then` runs once the list is ready (the list is filled just after the
    /// first frame, so anything that acts on the model must wait for it).
    func show(then: (() -> Void)? = nil) {
        let target = env.appTracker.targetApp
        present(target: target) { [model] in
            model.prepareForOpen(target: target)
            then?()
        }
    }

    /// Opens straight into the action menu for text selected in `target`.
    func showForSelection(_ text: String, target: NSRunningApplication?) {
        present(target: target) { [model] in model.prepareForSelection(text, target: target) }
    }

    /// Builds the panel and renders it once, invisibly, so the first real open has no setup cost:
    /// SwiftUI's view graph, the first rows, app icons and thumbnails are all ready.
    func warmUp() {
        guard panel == nil else { return }
        let panel = makePanel()
        self.panel = panel
        model.refresh(resetSelection: true)
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        layout(for: PanelGeometry.make(origin: env.prefs.panelOrigin, size: env.prefs.panelSize.size, visible: visible))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(progress: 1)
        CATransaction.commit()
        // Fully drawn but invisible (window alpha 0), so every layer gets real content.
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        if let root { probe = FrameProbe(view: root) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.phase == .hidden else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    // MARK: Present / close

    private func present(target: NSRunningApplication?, prepare: @escaping () -> Void) {
        let t0 = CACurrentMediaTime()
        let interval = Self.signposter.beginInterval("PanelOpen")
        let panel = self.panel ?? makePanel()
        self.panel = panel

        if phase == .opening || phase == .open {
            panel.makeKey()
            Self.signposter.endInterval("PanelOpen", interval)
            prepare()
            return
        }
        generation &+= 1
        let gen = generation
        env.sync.setPanelOpen(true)
        env.sync.reportActivity()

        switch phase {
        case .opening, .open:
            return
        case .closing:
            // Reverse from wherever the close animation is right now.
            phase = .opening
        case .hidden:
            phase = .opening
            updateShellIfNeeded()
            let screen = ScreenLocator.screen(forActiveWindowOf: target?.processIdentifier)
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let geometry = PanelGeometry.make(origin: env.prefs.panelOrigin, size: env.prefs.panelSize.size, visible: visible)
            layout(for: geometry)
            setInitialState()
        }

        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        // Order front first and take key focus right after the first frame is out: becoming key
        // moves text-input focus into the search field, which costs ~30 ms in AppKit.
        panel.orderFrontRegardless()
        installKeyMonitor()
        animate(opening: true)
        // Push the first frame to the render server now, before any list work happens.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        let tShown = CACurrentMediaTime()
        Self.signposter.endInterval("PanelOpen", interval)
        if probe == nil, let root { probe = FrameProbe(view: root) }
        probe?.begin(start: t0, committed: tShown, duration: Self.openSpring.scaled(by: Self.timeScale).settlingTime())

        // Key focus and the list refresh come right after the first frame is out; the content
        // fades in a beat later, by which time it's ready.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == gen else { return }
            panel.makeKey()
            let keyed = CACurrentMediaTime()
            Self.signposter.withIntervalSignpost("PanelPrepare") { prepare() }
            let prepared = CACurrentMediaTime()
            self.probe?.note(keyAfter: keyed - t0, listMs: prepared - keyed)
        }
    }

    func close() {
        guard isVisible, let panel else {
            if phase == .hidden { model.didClose() }
            return
        }
        removeKeyMonitor()
        model.didClose()
        env.sync.setPanelOpen(false)
        resignWatch?.invalidate()
        resignWatch = nil
        generation &+= 1
        phase = .closing
        // Hand keyboard focus straight back to the app underneath (a paste follows within ~90 ms),
        // then keep the window on screen, non-key and click-through, for the close animation.
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFront(nil)
        }
        panel.ignoresMouseEvents = true
        animate(opening: false)
    }

    private func finishClose() {
        panel?.orderOut(nil)
        phase = .hidden
        motion = nil
        for layer in [morphView?.layer, shadowView?.layer, hosting?.layer, maskLayer] {
            layer?.removeAllAnimations()
        }
    }

    // MARK: Animation

    #if DEBUG
    /// `defaults write at.softmaze.Clippy.debug PanelMotionTimeScale 8` plays the motion 8× slower.
    static var timeScale: Double {
        let value = UserDefaults.standard.double(forKey: "PanelMotionTimeScale")
        return value > 0 ? value : 1
    }
    #else
    static let timeScale: Double = 1
    #endif

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Applies progress 0 (the pill at the edge, transparent) without animation.
    private func setInitialState() {
        guard let geometry, let morphView, let shadowView, let hosting else { return }
        motion = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [morphView.layer, shadowView.layer, hosting.layer, maskLayer] {
            layer?.removeAllAnimations()
        }
        let p: CGFloat = reduceMotion ? 1 : 0
        if geometry.morphs && !reduceMotion {
            morphView.layer?.mask = maskLayer
        } else {
            morphView.layer?.mask = nil
        }
        apply(progress: p)
        morphView.layer?.opacity = 0
        shadowView.layer?.opacity = 0
        hosting.layer?.opacity = 0
        CATransaction.commit()
    }

    /// Sets every geometry-driven layer property for `progress` (no animation).
    private func apply(progress p: CGFloat) {
        guard let geometry else { return }
        let shape = geometry.shape(at: p)
        maskLayer.bounds = CGRect(origin: .zero, size: shape.rect.size)
        maskLayer.position = CGPoint(x: shape.rect.midX, y: shape.rect.midY)
        maskLayer.cornerRadius = shape.radius
        let path = Self.path(shape.rect, shape.radius)
        ambientShadow.shadowPath = path
        contactShadow.shadowPath = path
        if let layer = morphView?.layer { layer.transform = transform(for: layer, progress: p) }
        if let layer = shadowView?.layer { layer.transform = transform(for: layer, progress: p) }
    }

    private func animate(opening: Bool) {
        guard let geometry, let morphView, let shadowView, let hosting,
              let morphLayer = morphView.layer, let shadowLayer = shadowView.layer, let contentLayer = hosting.layer
        else { return }
        let now = CACurrentMediaTime()
        let scale = Self.timeScale
        let gen = generation

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let finishAfter: Double
        if reduceMotion {
            // A quick, gentle fade in place: no travel, no growth.
            motion = nil
            if morphLayer.mask != nil { morphLayer.mask = nil }
            apply(progress: 1)
            let duration = (opening ? 0.16 : 0.1) * scale
            for layer in [morphLayer, shadowLayer, contentLayer] {
                fade(layer, to: opening ? 1 : 0, duration: duration, delay: 0, now: now)
            }
            finishAfter = duration
        } else {
            let target: CGFloat = opening ? 1 : 0
            let spring = (opening ? Self.openSpring : Self.closeSpring).scaled(by: scale)
            let current = motion?.state(at: now) ?? (progress: opening ? 0 : 1, velocity: 0)
            let distance = target - current.progress
            let relativeVelocity = abs(distance) > 0.0001 ? Double(current.velocity / distance) : 0
            motion = Motion(from: current.progress, to: target, begin: now, spring: spring, initialVelocity: relativeVelocity)

            if geometry.morphs, morphLayer.mask == nil {
                morphLayer.mask = maskLayer      // removed while at rest; needed for the morph
            }
            animateGeometry(from: current.progress, to: target, spring: spring, velocity: relativeVelocity, now: now)

            if opening {
                fade(morphLayer, to: 1, duration: (geometry.morphs ? 0.12 : 0.16) * scale, delay: 0, now: now)
                fade(shadowLayer, to: 1, duration: 0.2 * scale, delay: 0, now: now)
                fade(contentLayer, to: 1, duration: 0.2 * scale, delay: (geometry.morphs ? 0.07 : 0.04) * scale, now: now)
                if geometry.morphs && current.progress < 0.05 {
                    // The content drifts in from the edge a few points behind the shell.
                    let drift = CABasicAnimation(keyPath: "transform")
                    let unit = CGVector(dx: geometry.startOffset.dx == 0 ? 0 : (geometry.startOffset.dx > 0 ? 1 : -1),
                                        dy: geometry.startOffset.dy == 0 ? 0 : (geometry.startOffset.dy > 0 ? 1 : -1))
                    drift.fromValue = CATransform3DMakeTranslation(unit.dx * 10, unit.dy * 10, 0)
                    drift.toValue = CATransform3DIdentity
                    drift.duration = 0.34 * scale
                    drift.beginTime = now
                    drift.fillMode = .backwards
                    drift.timingFunction = Self.easeOut
                    contentLayer.add(drift, forKey: "panel.drift")
                }
                finishAfter = spring.settlingTime(initialVelocity: relativeVelocity)
            } else {
                fade(contentLayer, to: 0, duration: 0.07 * scale, delay: 0, now: now)
                let fadeDelay = (geometry.morphs ? 0.07 : 0) * scale
                let fadeDuration = (geometry.morphs ? 0.13 : 0.14) * scale
                fade(morphLayer, to: 0, duration: fadeDuration, delay: fadeDelay, now: now)
                fade(shadowLayer, to: 0, duration: fadeDuration, delay: 0, now: now)
                finishAfter = fadeDelay + fadeDuration
            }
        }
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + finishAfter) { [weak self] in
            guard let self, self.generation == gen else { return }
            if opening {
                guard self.phase == .opening else { return }
                self.phase = .open
                self.motion = nil
                // At rest the mask is pure cost (an offscreen pass per frame while scrolling).
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.morphView?.layer?.mask = nil
                CATransaction.commit()
            } else if self.phase == .closing {
                self.finishClose()
            }
        }
    }

    private func animateGeometry(from: CGFloat, to: CGFloat, spring: PanelSpring, velocity: Double, now: CFTimeInterval) {
        guard let geometry, let morphLayer = morphView?.layer, let shadowLayer = shadowView?.layer else { return }
        let a = geometry.shape(at: from), b = geometry.shape(at: to)

        func add(_ layer: CALayer, _ keyPath: String, _ fromValue: Any, _ toValue: Any) {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.mass = 1
            animation.stiffness = spring.stiffness
            animation.damping = spring.damping
            animation.initialVelocity = velocity
            animation.fromValue = fromValue
            animation.toValue = toValue
            animation.duration = animation.settlingDuration
            animation.beginTime = now
            animation.fillMode = .backwards
            layer.add(animation, forKey: "panel." + keyPath)
        }

        apply(progress: to)   // model values = destination
        add(morphLayer, "transform", transform(for: morphLayer, progress: from), transform(for: morphLayer, progress: to))
        add(shadowLayer, "transform", transform(for: shadowLayer, progress: from), transform(for: shadowLayer, progress: to))
        if geometry.morphs {
            add(maskLayer, "bounds", CGRect(origin: .zero, size: a.rect.size), CGRect(origin: .zero, size: b.rect.size))
            add(maskLayer, "position", CGPoint(x: a.rect.midX, y: a.rect.midY), CGPoint(x: b.rect.midX, y: b.rect.midY))
            add(maskLayer, "cornerRadius", a.radius, b.radius)
            let pathA = Self.path(a.rect, a.radius), pathB = Self.path(b.rect, b.radius)
            add(ambientShadow, "shadowPath", pathA, pathB)
            add(contactShadow, "shadowPath", pathA, pathB)
        }
    }

    /// Opacity from its current on-screen value to `target`.
    private func fade(_ layer: CALayer, to target: Float, duration: Double, delay: Double, now: CFTimeInterval) {
        let current = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "panel.opacity")
        layer.opacity = target
        guard current != target else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = current
        animation.toValue = target
        animation.duration = duration
        animation.beginTime = now + delay
        animation.fillMode = .backwards
        animation.timingFunction = target > current ? Self.easeOut : Self.easeIn
        layer.add(animation, forKey: "panel.opacity")
    }

    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    private static let easeIn = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0)

    /// The panel's translation (edges) or scale about its centre (center) for `progress`,
    /// expressed for `layer`'s anchor point.
    private func transform(for layer: CALayer, progress p: CGFloat) -> CATransform3D {
        guard let geometry else { return CATransform3DIdentity }
        let offset = geometry.offset(at: p)
        let s = geometry.scale(at: p)
        guard s != 1 else { return CATransform3DMakeTranslation(offset.dx, offset.dy, 0) }
        // Scale about the panel's centre: transforms apply around the anchor point.
        let size = layer.bounds.size
        let dx = size.width / 2 - layer.anchorPoint.x * size.width
        let dy = size.height / 2 - layer.anchorPoint.y * size.height
        var t = CATransform3DMakeTranslation(-dx, -dy, 0)
        t = CATransform3DConcat(t, CATransform3DMakeScale(s, s, 1))
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(dx + offset.dx, dy + offset.dy, 0))
        return t
    }

    private static func path(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let r = max(0.5, min(radius, min(rect.width, rect.height) / 2 - 0.25))
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    // MARK: Layout

    private func layout(for geometry: PanelGeometry) {
        guard let panel, let shadowView, let morphView, let shell else { return }
        self.geometry = geometry
        let panelFrame = geometry.panelInWindow
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if panel.frame != geometry.window {
            panel.setFrame(geometry.window, display: false)
        }
        if shadowView.frame != panelFrame { shadowView.frame = panelFrame }
        if morphView.frame != panelFrame {
            morphView.frame = panelFrame
            shell.frame = morphView.bounds
        }
        ambientShadow.frame = shadowView.bounds
        contactShadow.frame = shadowView.bounds
        updateShadowAppearance()
        CATransaction.commit()
    }

    private func updateShadowAppearance() {
        let dark = panel?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ambientShadow.shadowColor = NSColor.black.cgColor
        ambientShadow.shadowOpacity = dark ? 0.5 : 0.2
        ambientShadow.shadowRadius = 26
        ambientShadow.shadowOffset = CGSize(width: 0, height: -14)
        contactShadow.shadowColor = NSColor.black.cgColor
        contactShadow.shadowOpacity = dark ? 0.35 : 0.12
        contactShadow.shadowRadius = 1.5
        contactShadow.shadowOffset = CGSize(width: 0, height: -0.5)
    }

    #if DEBUG
    func writeSnapshot(to url: URL) {
        guard let container = hosting else { return }
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
        container.cacheDisplay(in: container.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The panel's window number, for `screencapture -l`.
    var windowNumber: Int? { panel?.windowNumber }
    #endif

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // The Touch ID / password sheet steals focus; that isn't the user leaving the panel.
        if env.secrets.isAuthenticating { return }
        guard isVisible else { return }
        // A mouse button is down in another app: maybe the start of a drag from Finder into the
        // panel. Decide when the button comes up; a drop takes focus back by then.
        if NSEvent.pressedMouseButtons & 1 != 0 {
            watchForDragEnd()
            return
        }
        Log.panel.debug("panel lost key focus; closing")
        close()
    }

    private func watchForDragEnd() {
        resignWatch?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.resignWatch?.invalidate()
                self.resignWatch = nil
                // Give a drop's async loading a moment to land and refocus the panel.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self, self.isVisible, let panel = self.panel, !panel.isKeyWindow else { return }
                    if let lastDropAt = self.lastDropAt, Date.now.timeIntervalSince(lastDropAt) < 2 {
                        panel.makeKey()
                    } else {
                        Log.panel.debug("panel lost key focus; closing")
                        self.close()
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resignWatch = timer
    }

    // MARK: Building

    private func makePanel() -> QuickPanel {
        let panel = QuickPanel()
        panel.delegate = self

        let root = PanelRootView(frame: NSRect(origin: .zero, size: panel.frame.size))
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        root.onClickOutside = { [weak self] in self?.close() }

        let shadowView = NSView()
        let shadowHost = CALayer()
        shadowHost.addSublayer(ambientShadow)
        shadowHost.addSublayer(contactShadow)
        shadowView.layer = shadowHost          // layer-hosting: AppKit leaves these layers alone
        shadowView.wantsLayer = true

        let morphView = NSView()
        morphView.wantsLayer = true
        maskLayer.backgroundColor = NSColor.black.cgColor
        maskLayer.cornerCurve = .continuous

        let content = QuickPanelView(model: model)
            .environment(env)
            .modelContainer(env.container)
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.autoresizingMask = [.width, .height]

        root.addSubview(shadowView)
        root.addSubview(morphView)
        panel.contentView = root

        self.root = root
        self.shadowView = shadowView
        self.morphView = morphView
        self.hosting = hosting
        updateShellIfNeeded()
        return panel
    }

    /// Liquid Glass on macOS 26, vibrancy before that, and a solid surface with Reduce Transparency.
    private func updateShellIfNeeded() {
        guard let morphView, let hosting else { return }
        let kind: ShellKind
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            kind = .solid
        } else if #available(macOS 26.0, *) {
            kind = .glass
        } else {
            kind = .vibrancy
        }
        guard kind != shellKind else { return }
        shellKind = kind
        shell?.removeFromSuperview()
        hosting.removeFromSuperview()

        let shell: NSView
        switch kind {
        case .glass:
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.cornerRadius = Self.cornerRadius
                glass.contentView = hosting
                shell = glass
            } else {
                fallthrough
            }
        case .vibrancy:
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.cornerRadius
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            effect.addSubview(hosting)
            shell = effect
        case .solid:
            let box = NSBox()
            box.boxType = .custom
            box.borderWidth = 1
            box.borderColor = .separatorColor
            box.fillColor = .windowBackgroundColor
            box.cornerRadius = Self.cornerRadius
            box.contentViewMargins = .zero
            box.wantsLayer = true
            box.layer?.cornerCurve = .continuous
            box.contentView = hosting
            shell = box
        }
        shell.frame = morphView.bounds
        shell.autoresizingMask = [.width, .height]
        hosting.frame = shell.bounds
        morphView.addSubview(shell)
        self.shell = shell
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors are always invoked on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.panel, event.window === window else { return false }
                if window.firstResponder is ClipEditorTextView { return self.model.handleEditorKey(event) }
                return self.model.handleKeyDown(event)
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// Measures an open from the main thread's point of view, logged as one line per open:
/// shortcut → first frame committed to the render server, → first display refresh after that,
/// → key focus, list refresh time, and any refreshes the main thread missed while it animated.
/// (`log stream --predicate 'subsystem == "at.softmaze.Clippy" AND category == "panel"'`)
private final class FrameProbe: NSObject {
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var committed: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private var firstVsync: CFTimeInterval?
    private var last: CFTimeInterval?
    private var frames = 0
    private var dropped = 0
    private var longestGap: CFTimeInterval = 0
    private var frameDuration: CFTimeInterval = 1.0 / 60
    private var keyAfter: CFTimeInterval = 0
    private var listMs: CFTimeInterval = 0
    private var active = false

    init(view: NSView) {
        super.init()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func begin(start: CFTimeInterval, committed: CFTimeInterval, duration: CFTimeInterval) {
        self.start = start
        self.committed = committed
        self.duration = duration
        firstVsync = nil
        last = nil
        frames = 0
        dropped = 0
        longestGap = 0
        active = true
        link?.isPaused = false
    }

    func note(keyAfter: CFTimeInterval, listMs: CFTimeInterval) {
        self.keyAfter = keyAfter
        self.listMs = listMs
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard active else { link.isPaused = true; return }
        if link.duration > 0 { frameDuration = link.duration }
        let now = link.timestamp
        if firstVsync == nil {
            // The link needs a couple of frames to resume, so project its vsync grid back to the
            // first refresh after the commit: that's when the first frame reaches the screen.
            var vsync = now
            while vsync - frameDuration >= committed { vsync -= frameDuration }
            firstVsync = vsync
        }
        if let last {
            let gap = now - last
            longestGap = max(longestGap, gap)
            if gap > frameDuration * 1.5 { dropped += Int((gap / frameDuration).rounded()) - 1 }
        }
        last = now
        frames += 1
        guard now - start >= duration else { return }
        active = false
        link.isPaused = true
        let ms = { (t: CFTimeInterval) in String(format: "%.1f", t * 1000) }
        Log.panel.notice("""
            open: committed \(ms(self.committed - self.start), privacy: .public) ms, \
            on screen at the next refresh, \(ms((self.firstVsync ?? now) - self.start), privacy: .public) ms, \
            key \(ms(self.keyAfter), privacy: .public) ms, list \(ms(self.listMs), privacy: .public) ms; \
            animation \(self.frames, privacy: .public) frames @ \(String(format: "%.0f", 1 / self.frameDuration), privacy: .public) Hz, \
            \(self.dropped, privacy: .public) dropped, longest gap \(ms(self.longestGap), privacy: .public) ms
            """)
    }
}

enum ScreenLocator {
    /// The screen containing the frontmost window of `pid`, falling back to the main screen.
    static func screen(forActiveWindowOf pid: pid_t?) -> NSScreen? {
        let fallback = NSScreen.main ?? NSScreen.screens.first
        guard let pid,
              let primary = NSScreen.screens.first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return fallback }

        for window in info {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 50, bounds.height > 50
            else { continue }
            // CG window coordinates are top-left based on the primary display.
            let center = NSPoint(x: bounds.midX, y: primary.frame.maxY - bounds.midY)
            return NSScreen.screens.first { $0.frame.contains(center) } ?? fallback
        }
        return fallback
    }
}
