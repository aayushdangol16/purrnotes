import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = NotesStore()
    private let todos = TodoStore()
    private let panelState = PanelState()
    private var pet: PetController!
    private var notes: NotesWindowController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One cat is plenty: bow out if another copy is already running.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }

        buildMainMenu()

        notes = NotesWindowController(store: store, todos: todos, state: panelState)
        pet = PetController()
        pet.onClick = { [weak self] in self?.toggleNotes() }
        pet.menuProvider = { [weak self] in
            guard let self else { return nil }
            let menu = NSMenu()
            self.populate(menu)
            return menu
        }
        notes.onVisibilityChange = { [weak self] open in self?.pet.notesOpen = open }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "Purr Notes")
                ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Purr Notes")
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "🐱" }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        pet.start()
        DebugTools.runLaunchHooks(notes: notes,
                                  panel: panelState,
                                  open: { [weak self] in self?.openNotes() },
                                  status: { [weak self] in self?.pet.debugStatus ?? "no cat" },
                                  perform: { [weak self] in self?.pet.debugPerform($0) },
                                  todos: todos)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
        todos.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        if notes.isOpen {
            menu.addItem(item("Close Window", #selector(closeNotes)))
        } else {
            menu.addItem(item("Open Notes", #selector(openNotesTab)))
            menu.addItem(item("Open To-Do List", #selector(openTodoTab)))
        }
        menu.addItem(item("New Note", #selector(newNote)))
        menu.addItem(item("New Task", #selector(newTask)))
        menu.addItem(.separator())

        let sizeItem = NSMenuItem(title: "Cat Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (index, size) in PetController.sizes.enumerated() {
            let entry = item(size.name, #selector(setSize(_:)))
            entry.tag = index
            entry.state = abs(pet.scale - size.scale) < 0.01 ? .on : .off
            sizeMenu.addItem(entry)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let stay = item("Stay Put", #selector(toggleStayPut))
        stay.state = pet.stayPut ? .on : .off
        menu.addItem(stay)
        menu.addItem(item(pet.isHidden ? "Show Cat" : "Hide Cat", #selector(toggleHidden)))
        if LoginItem.isAvailable {
            let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
            login.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Purr Notes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// An accessory app shows no menu bar, but the main menu is still what makes
    /// ⌘C / ⌘V / ⌘Z / ⌘W work inside the notes window.
    private func buildMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Purr Notes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let file = NSMenu(title: "File")
        file.addItem(item("New Note", #selector(newNote), key: "n"))
        let task = item("New Task", #selector(newTask), key: "n")
        task.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(task)
        file.addItem(item("Close", #selector(closeNotes), key: "w"))
        let fileItem = NSMenuItem()
        fileItem.submenu = file
        main.addItem(fileItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // MARK: Actions

    private func openNotes() {
        notes.show(above: pet.frame, on: pet.screen)
    }

    @objc private func toggleNotes() {
        if notes.isOpen { notes.close() } else { openNotes() }
    }

    @objc private func closeNotes() {
        notes.close()
    }

    @objc private func newNote() {
        panelState.tab = .notes
        store.newNote()
        if !notes.isOpen { openNotes() }
    }

    @objc private func newTask() {
        panelState.tab = .todo
        if notes.isOpen { panelState.focusAddTask() } else { openNotes() }
    }

    @objc private func openNotesTab() {
        panelState.tab = .notes
        openNotes()
    }

    @objc private func openTodoTab() {
        panelState.tab = .todo
        openNotes()
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard PetController.sizes.indices.contains(sender.tag) else { return }
        pet.scale = PetController.sizes[sender.tag].scale
    }

    @objc private func toggleStayPut() {
        pet.stayPut.toggle()
    }

    @objc private func toggleHidden() {
        pet.isHidden.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
            // macOS can hold a new login item until the user allows it in System Settings.
            if LoginItem.needsApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
