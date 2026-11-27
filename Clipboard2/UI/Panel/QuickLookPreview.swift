import AppKit
import Quartz

/// Drives the system Quick Look panel for the quick panel's selection (⌘Y), like Finder.
///
/// The quick panel stays key while Quick Look is up, so its own key handling keeps working:
/// ↑/↓ move the selection and the preview follows, Esc and ⌘Y close Quick Look. Quick Look finds
/// this controller through the quick panel window (`QuickPanel` forwards the
/// `QLPreviewPanelController` calls here). If the user clicks into Quick Look and it takes key,
/// its key presses are passed to `handleKey` the same way.
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// The files to show for the current selection.
    var urlsProvider: () -> [URL] = { [] }
    /// Key presses that reach Quick Look while it's key; true when handled.
    var handleKey: (NSEvent) -> Bool = { _ in false }
    /// Quick Look closed (by any means): the owner takes focus back and clears temporary files.
    var onEnd: () -> Void = {}
    /// Quick Look lost key focus (to another app, or back to the quick panel).
    var onResignKey: () -> Void = {}

    private var urls: [URL] = []
    private weak var controlled: QLPreviewPanel?
    private var reloadPending = false

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    /// The Quick Look panel while it shows our items.
    private var fedPanel: QLPreviewPanel? {
        if let controlled { return controlled }
        guard isVisible, let panel = QLPreviewPanel.shared(), panel.dataSource === self else { return nil }
        return panel
    }

    var isKey: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isKeyWindow == true
    }

    /// Opens Quick Look above `window` (which must be key, so Quick Look finds us through it),
    /// at `frame` (centred over the quick panel) rather than wherever it last was.
    func show(above window: NSWindow, frame: CGRect? = nil) {
        guard let panel = QLPreviewPanel.shared() else { return }
        urls = urlsProvider()
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        // Clipboard2 usually isn't the active app (the quick panel doesn't activate it); Quick Look
        // must stay up regardless, and above the floating quick panel.
        panel.hidesOnDeactivate = false
        if panel.level.rawValue <= window.level.rawValue {
            panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        }
        panel.updateController()
        // If Quick Look didn't hand control to us (it looks along the key window's responder
        // chain, and the app isn't active), feed it anyway: without a data source it shows
        // "No item selected".
        if panel.dataSource !== self {
            panel.dataSource = self
            panel.delegate = self
        }
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        if let frame { panel.setFrame(frame, display: false) }
        // Front without taking key: the quick panel keeps the keyboard.
        panel.orderFrontRegardless()
    }

    func close() {
        guard isVisible, let panel = QLPreviewPanel.shared() else { return }
        panel.orderOut(nil)
        // Fed without control (see `show`): Quick Look won't call endControl, so end here.
        if controlled == nil, panel.dataSource === self {
            panel.dataSource = nil
            panel.delegate = nil
            urls = []
            onEnd()
        }
    }

    /// The selection changed: show what's selected now (coalesced; several changes arrive per move).
    func selectionChanged() {
        guard fedPanel != nil, !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            guard let panel = self.fedPanel else { return }
            let next = self.urlsProvider()
            guard next != self.urls else { return }
            self.urls = next
            panel.reloadData()
            panel.currentPreviewItemIndex = 0
        }
    }

    // MARK: QLPreviewPanelController (forwarded by QuickPanel)

    func beginControl(_ panel: QLPreviewPanel) {
        controlled = panel
        panel.dataSource = self
        panel.delegate = self
        if urls.isEmpty { urls = urlsProvider() }
        panel.reloadData()
    }

    func endControl(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
        controlled = nil
        urls = []
        onEnd()
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    // MARK: QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return handleKey(event)
    }

    func windowDidResignKey(_ notification: Notification) {
        onResignKey()
    }
}
