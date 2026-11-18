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
    /// Wide enough for the Notes / To-Do / Work switch plus the note buttons.
    static let minSize = NSSize(width: 320, height: 240)

    var onVisibilityChange: ((Bool) -> Void)?
    var isOpen: Bool { panel.isVisible }
    var contentView: NSView? { panel.contentView }
    var isKey: Bool { panel.isKeyWindow }

    private let panel: NotesPanel
    private let store: NotesStore
    private let todos: TodoStore
    private let state: PanelState
    private let workstation: Workstation

    init(store: NotesStore, todos: TodoStore, state: PanelState, workstation: Workstation) {
        self.store = store
        self.todos = todos
        self.state = state
        self.workstation = workstation

        var size = NSSize(width: 340, height: 400)
        if let saved = UserDefaults.standard.string(forKey: Self.sizeKey) {
            let s = NSSizeFromString(saved)
            if s.height >= Self.minSize.height { size = NSSize(width: max(s.width, Self.minSize.width), height: s.height) }
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
        panel.minSize = Self.minSize
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        let hosting = NSHostingView(rootView: NotesRootView(store: store, todos: todos, panel: state, workstation: workstation, onClose: { [weak self] in
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
        switch state.tab {
        case .notes: store.requestFocus()
        case .todo: state.focusAddTask()
        case .work: break
        }
        onVisibilityChange?(true)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromSize(panel.frame.size), forKey: Self.sizeKey)
        store.tidyAndSave()
        todos.flush()
        workstation.flush()
        onVisibilityChange?(false)
    }
}
