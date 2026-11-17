import AppKit

/// Developer helpers reached through command-line flags. None of this runs in
/// normal use; it exists so the app can be checked and its icon generated
/// without any extra tooling.
///
///   --render-preview <file.png>   draw every cat pose to an image
///   --export-iconset <dir>        write the PNGs for AppIcon.iconset
///   --selftest                    exercise note saving/loading in a temp folder
///   --snapshot-notes <file.png>   launch, open the notes window, save a picture of it, quit
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

    static func runLaunchHooks(notes: NotesWindowController, open: @escaping () -> Void,
                               status: @escaping () -> String, perform: @escaping (String) -> Void) {
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

        print(failures == 0 ? "PASS" : "FAILED (\(failures))")
        return failures == 0
    }
}
