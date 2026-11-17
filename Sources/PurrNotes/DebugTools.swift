import AppKit

/// Developer helpers reached through command-line flags. None of this runs in
/// normal use; it exists so the app can be checked and its icon generated
/// without any extra tooling.
///
///   --render-preview <file.png>   draw every cat pose to an image
///   --export-iconset <dir>        write the PNGs for AppIcon.iconset
///   --selftest                    exercise note saving/loading in a temp folder
///   --snapshot-notes <file.png>   launch, open the notes window, save a picture of it, quit
///                                 (`--tab todo` for the To-Do page, `--appearance light|dark`)
///   --login-item status|on|off    read or change Launch at Login (run from inside the .app)
///   --trace                       launch, click / lift / drop the cat in code, print what it does, quit
@MainActor
enum DebugTools {
    /// Returns true if a flag was handled and the process should exit.
    static func handleCommandLine() -> Bool {
        let args = CommandLine.arguments
        if let path = value(after: "--render-preview", in: args) {
            renderPreview(to: path)
            return true
        }
        if let dir = value(after: "--export-iconset", in: args) {
            exportIconset(to: dir)
            return true
        }
        if let action = value(after: "--login-item", in: args) {
            do {
                if action == "on" { try LoginItem.setEnabled(true) }
                if action == "off" { try LoginItem.setEnabled(false) }
                print("login item: \(LoginItem.statusDescription)")
            } catch {
                print("login item error: \(error.localizedDescription)")
                exit(1)
            }
            return true
        }
        if args.contains("--selftest") {
            exit(storeSelfTest() ? 0 : 1)
        }
        return false
    }

    static func runLaunchHooks(notes: NotesWindowController, panel: PanelState, open: @escaping () -> Void,
                               status: @escaping () -> String, perform: @escaping (String) -> Void,
                               todos: TodoStore? = nil) {
        if CommandLine.arguments.contains("--todo-input-test"), let todos {
            panel.tab = .todo
            Task { @MainActor in await todoInputTest(notes: notes, todos: todos, open: open) }
            return
        }
        if CommandLine.arguments.contains("--trace") {
            // Step index (every 0.25 s) -> scripted input.
            let script = [8: "click", 18: "click", 28: "lift", 32: "drop"]
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm:ss.S"
            Task { @MainActor in
                for step in 0..<140 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if let action = script[step] {
                        perform(action)
                        print(">>> \(action)")
                    }
                    print("\(clock.string(from: Date())) notes=\(notes.isOpen) \(status())")
                }
                NSApp.terminate(nil)
            }
            return
        }
        guard let path = value(after: "--snapshot-notes", in: CommandLine.arguments) else { return }
        if let tab = value(after: "--tab", in: CommandLine.arguments).flatMap(PanelState.Tab.init(rawValue:)) {
            panel.tab = tab
        }
        switch value(after: "--appearance", in: CommandLine.arguments) {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            open()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if let view = notes.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                write(rep, to: path)
            }
            print("notes window visible=\(notes.isOpen) key=\(notes.isKey) appActive=\(NSApp.isActive)")
            NSApp.terminate(nil)
        }
    }

    /// Sends real key and mouse events to the To-Do page, the same way typing and
    /// clicking would arrive, and reports what happened. Run with PURRNOTES_DIR set.
    private static func todoInputTest(notes: NotesWindowController, todos: TodoStore, open: () -> Void) async {
        func pause(_ s: Double = 0.35) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            print(ok ? "  ok    \(label)" : "  FAIL  \(label)")
            if !ok { failures += 1 }
            let list = todos.items.map { "\($0.isDone ? "[x]" : "[ ]") \($0.title)" }.joined(separator: " | ")
            if CommandLine.arguments.contains("--verbose") { print("          list: \(list)") }
        }
        guard let window = notes.contentView?.window else { print("no window"); exit(1) }
        func panelTab() -> String { UserDefaults.standard.string(forKey: "panelTab") ?? "?" }

        func key(_ code: UInt16, _ chars: String) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    window.sendEvent(e)
                }
            }
        }
        func type(_ text: String) { for ch in text { key(0, String(ch)) } }
        func ret() { key(36, "\r") }
        func esc() { key(53, "\u{1b}") }
        func click(atFromTop y: CGFloat, x: CGFloat, count: Int) {
            let p = NSPoint(x: x, y: (window.contentView?.bounds.height ?? 0) - y)
            for n in 1...count {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                  clickCount: n, pressure: 1) {
                        window.sendEvent(e)
                    }
                }
            }
        }

        var shot = 0
        func snapshot(_ label: String) {
            guard let dir = value(after: "--shots", in: CommandLine.arguments),
                  let view = notes.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            shot += 1
            write(rep, to: "\(dir)/\(shot)-\(label).png")
            print("          shot \(shot)-\(label): view \(view.bounds.size) contentLayout \(window.contentLayoutRect.size)")
        }

        await pause(0.8)
        open()
        await pause(0.8)

        type("Buy milk"); ret(); await pause()
        type("Feed the cat"); ret(); await pause()
        check(todos.pending.map(\.title) == ["Buy milk", "Feed the cat"],
              "typing + Return adds tasks, and the field stays ready for the next one")

        esc(); await pause()
        check(!notes.isOpen, "Esc in the add field closes the window, like other quick panels")
        open()
        await pause(0.8)
        check(notes.isOpen, "the window reopens on the To-Do page")

        // Double-click the first task's text to edit it.
        let firstRowY: CGFloat = 38 + 40 + 1 + 8 + 14
        click(atFromTop: firstRowY, x: 120, count: 2); await pause()
        type(" and eggs"); await pause(0.2)
        esc(); await pause()
        check(notes.isOpen, "Esc while editing a task leaves the window open")
        check(todos.pending.first?.title == "Buy milk", "Esc while editing discards the change")

        // Starting an edit selects the whole text (like renaming in Finder), so typing replaces it.
        click(atFromTop: firstRowY, x: 120, count: 2); await pause()
        snapshot("after-double-click")
        type("Buy milk and eggs"); await pause(0.2)
        snapshot("after-typing")
        ret(); await pause()
        check(todos.pending.map(\.title) == ["Buy milk and eggs", "Feed the cat"],
              "double-click, type, Return saves the edit to that task only")

        click(atFromTop: firstRowY, x: 120, count: 2); await pause()
        type("Buy oat milk"); await pause(0.2)
        click(atFromTop: 20, x: 60, count: 1); await pause()   // click the Notes tab: the edit loses focus
        check(todos.pending.first?.title == "Buy oat milk", "clicking away while editing saves the edit")
        click(atFromTop: 20, x: 100, count: 1); await pause(0.6)   // back to To-Do
        check(panelTab() == "todo", "clicking the To-Do pill switches back")

        // Click the first checkbox.
        click(atFromTop: firstRowY, x: 25, count: 1); await pause(0.6)
        check(todos.completed.map(\.title) == ["Buy oat milk"], "clicking a checkbox marks that task done")
        snapshot("after-check")
        // Second row is now "Feed the cat"; check it too, with the pointer resting on it like a real click.
        click(atFromTop: firstRowY, x: 25, count: 1); await pause(0.6)
        snapshot("after-second-check")
        // Uncheck the first completed row ("Feed the cat"), just under the "Completed" heading.
        click(atFromTop: firstRowY + 22, x: 25, count: 1); await pause(0.6)
        check(todos.pending.map(\.title) == ["Feed the cat"], "unchecking a completed task moves it back")
        snapshot("after-uncheck")

        todos.flush()
        print(failures == 0 ? "PASS" : "FAILED (\(failures))")
        NSApp.terminate(nil)
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: Rendering

    private static func bitmap(width: Int, height: Int, draw: () -> Void) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        draw()
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to path: String) {
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("could not write \(path): \(error)\n".utf8))
        }
    }

    private static func renderPreview(to path: String) {
        let scale: CGFloat = 3
        let cell = CatRenderer.baseSize
        var frames: [CatState] = []
        for i in 0..<4 {
            frames.append(CatState(pose: .walk, facingRight: true, phase: CGFloat(i) * .pi / 2, time: CGFloat(i) * 0.2))
        }
        frames.append(CatState(pose: .walk, facingRight: false, phase: 1, time: 0.3))
        frames.append(CatState(pose: .sit, time: 0.4))
        frames.append(CatState(pose: .sit, facingRight: false, time: 0.9, eyes: .happy, hearts: 0.4))
        frames.append(CatState(pose: .sleep, time: 1.1, eyes: .closed))
        frames.append(CatState(pose: .sleep, facingRight: false, time: 2.3, eyes: .closed))
        frames.append(CatState(pose: .held, time: 0.5, eyes: .wide))

        let columns = 5
        let rows = 2
        let width = Int(cell.width * scale) * columns
        let height = Int(cell.height * scale) * rows
        guard let rep = bitmap(width: width, height: height, draw: {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            // Top row on a light desktop, bottom row on a dark one.
            NSColor(srgbRed: 0.90, green: 0.93, blue: 0.96, alpha: 1).setFill()
            NSRect(x: 0, y: height / 2, width: width, height: height / 2).fill()
            NSColor(srgbRed: 0.13, green: 0.15, blue: 0.19, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: width, height: height / 2).fill()
            for (i, frame) in frames.enumerated() {
                let col = i % columns
                let row = rows - 1 - i / columns
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(col) * cell.width * scale, y: CGFloat(row) * cell.height * scale)
                CatRenderer.draw(frame, scale: scale)
                ctx.restoreGState()
            }
        }) else { return }
        write(rep, to: path)
    }

    private static func exportIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let variants: [(name: String, pixels: Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for variant in variants {
            let px = CGFloat(variant.pixels)
            guard let rep = bitmap(width: variant.pixels, height: variant.pixels, draw: {
                guard let ctx = NSGraphicsContext.current?.cgContext else { return }
                let unit = px / 1024
                let plate = NSBezierPath(roundedRect: NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit),
                                         xRadius: 185 * unit, yRadius: 185 * unit)
                NSGradient(starting: NSColor(srgbRed: 1.0, green: 0.95, blue: 0.84, alpha: 1),
                           ending: NSColor(srgbRed: 1.0, green: 0.80, blue: 0.62, alpha: 1))?
                    .draw(in: plate, angle: -90)
                let catScale = 6.6 * unit
                ctx.translateBy(x: (px - CatRenderer.baseSize.width * catScale) / 2, y: 175 * unit)
                CatRenderer.draw(CatState(pose: .sit, time: 0.4), scale: catScale)
            }) else { continue }
            write(rep, to: "\(dir)/\(variant.name).png")
        }
    }

    // MARK: Self-test

    private static func storeSelfTest() -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("purrnotes-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "  ok    \(label)" : "  FAIL  \(label)")
            if !condition { failures += 1 }
        }

        let first = NotesStore(directory: dir)
        check(first.notes.count == 1 && first.currentNote != nil, "first launch starts with a welcome note")
        first.newNote()
        first.updateCurrentText("Groceries\nmilk, tuna, catnip")
        let groceriesID = first.selectedID
        check(first.hasUnsavedChanges, "edits are marked unsaved until written")
        first.newNote()
        first.updateCurrentText("Second note")
        if let id = groceriesID { first.select(id) }
        first.flush()
        check(!first.hasUnsavedChanges, "flush clears the unsaved flag")
        check(FileManager.default.fileExists(atPath: first.fileURL.path), "notes.json is written")

        let second = NotesStore(directory: dir)
        check(second.notes.count == 3, "all notes are restored after relaunch")
        check(second.selectedID == groceriesID, "the selected note is restored")
        check(second.currentNote?.text == "Groceries\nmilk, tuna, catnip", "note text survives a relaunch")
        check(second.currentNote?.title == "Groceries", "title comes from the first line")

        second.newNote()
        second.tidyAndSave()
        check(second.notes.count == 3, "empty notes are dropped on close")
        if let id = second.selectedID { second.delete(id) }
        second.flush()
        check(NotesStore(directory: dir).notes.count == 2, "deletions persist")

        try? Data("not json".utf8).write(to: second.fileURL)
        let third = NotesStore(directory: dir)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        check(third.notes.isEmpty && leftovers.contains { $0.hasPrefix("notes.unreadable-") },
              "an unreadable file is set aside, not overwritten")
        third.ensureSelection()
        check(third.currentNote != nil, "a fresh note is available after recovery")

        // To-dos live in their own file beside the notes.
        print("  -- to-dos")
        let todoDir = dir.appendingPathComponent("todos", isDirectory: true)
        let notesBeside = NotesStore(directory: todoDir)
        notesBeside.updateCurrentText("A note that must survive")
        notesBeside.flush()
        let notesBytes = try? Data(contentsOf: notesBeside.fileURL)

        let t1 = TodoStore(directory: todoDir)
        check(t1.items.isEmpty, "first launch starts with an empty to-do list")
        check(!t1.add("   \n  "), "blank tasks are ignored")
        t1.add("Buy cat food")
        t1.add("Water the plants")
        t1.add("Call  the vet\nabout shots")
        check(t1.pending.map(\.title) == ["Buy cat food", "Water the plants", "Call  the vet about shots"],
              "tasks are listed in the order they were added")
        let food = t1.pending[0].id, plants = t1.pending[1].id, vet = t1.pending[2].id
        t1.toggle(food)
        check(t1.completed.first?.id == food && t1.completed.first?.completedAt != nil,
              "a checked task moves to Completed")
        check(!t1.pending.contains { $0.id == food }, "a checked task leaves the pending list")
        t1.rename(plants, to: "Water the plants twice")
        t1.rename(vet, to: "   ")
        check(t1.items.first { $0.id == plants }?.title == "Water the plants twice", "tasks can be edited")
        check(t1.items.first { $0.id == vet }?.title == "Call  the vet about shots",
              "editing a task down to nothing keeps the old text")
        t1.delete(vet)
        check(t1.items.count == 2, "tasks can be deleted")
        t1.flush()

        let t2 = TodoStore(directory: todoDir)
        // Dates are stored to the second, so compare what the user sees.
        func summary(_ items: [TodoItem]) -> [String] {
            items.map { "\($0.id) \($0.title) \($0.isDone) \($0.completedAt != nil)" }
        }
        check(summary(t2.items) == summary(t1.items) && t2.completed.first?.id == food,
              "tasks, edits and checkmarks survive a relaunch")
        t2.toggle(food)
        check(t2.pending.contains { $0.id == food } && t2.items.first { $0.id == food }?.completedAt == nil,
              "unchecking puts a task back")
        t2.flush()
        check(TodoStore(directory: todoDir).pending.count == 2, "unchecking persists")
        check((try? Data(contentsOf: notesBeside.fileURL)) == notesBytes, "to-do saves never touch notes.json")

        try? Data("{ broken".utf8).write(to: t2.fileURL)
        let t3 = TodoStore(directory: todoDir)
        let todoLeftovers = (try? FileManager.default.contentsOfDirectory(atPath: todoDir.path)) ?? []
        check(t3.items.isEmpty && todoLeftovers.contains { $0.hasPrefix("todos.unreadable-") },
              "an unreadable to-do file is set aside, not overwritten")
        check(NotesStore(directory: todoDir).currentNote?.text == "A note that must survive",
              "notes still load when the to-do file is broken")

        print(failures == 0 ? "PASS" : "FAILED (\(failures))")
        return failures == 0
    }
}
