import AppKit

@main
@MainActor
enum PurrNotesApp {
    static func main() {
        if DebugTools.handleCommandLine() { return }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Accessory: no Dock icon and no menu bar takeover, just the cat and a status item.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
