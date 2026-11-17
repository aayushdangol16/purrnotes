import AppKit
import SwiftUI

private final class NotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The small floating notes window that pops up above the cat.
@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    private static let sizeKey = "notesWindowSize"

    var onVisibilityChange: ((Bool) -> Void)?
    var isOpen: Bool { panel.isVisible }
    var contentView: NSView? { panel.contentView }
    var isKey: Bool { panel.isKeyWindow }

    private let panel: NotesPanel
    private let store: NotesStore

    init(store: NotesStore) {
        self.store = store

        var size = NSSize(width: 340, height: 400)
        if let saved = UserDefaults.standard.string(forKey: Self.sizeKey) {
            let s = NSSizeFromString(saved)
            if s.width >= 260, s.height >= 240 { size = s }
        }

        panel = NotesPanel(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                           backing: .buffered,
                           defer: false)
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 260, height: 240)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        let hosting = NSHostingView(rootView: NotesRootView(store: store, onClose: { [weak self] in
            self?.close()
        }))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.delegate = self
    }

    /// Opens the window just above the cat, kept fully on screen.
    func show(above catFrame: NSRect, on screen: NSScreen?) {
        store.ensureSelection()

        let size = panel.frame.size
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            var x = catFrame.midX - size.width / 2
            x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
            var y = catFrame.minY + catFrame.height * 0.8 + 4
            y = max(visible.minY + 8, min(y, visible.maxY - size.height - 8))
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        store.requestFocus()
        onVisibilityChange?(true)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromSize(panel.frame.size), forKey: Self.sizeKey)
        store.tidyAndSave()
        onVisibilityChange?(false)
    }
}
