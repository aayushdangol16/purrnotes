import AppKit
import ApplicationServices

/// Puts another app's window into native macOS full screen (its own Space, as if
/// the user had clicked the green button), using the Accessibility API.
///
/// macOS only allows this once the user has switched PurrNotes on under
/// System Settings › Privacy & Security › Accessibility.
@MainActor
enum FullScreen {
    enum Result: Equatable {
        case done
        case alreadyFullScreen
        /// The app's window can't go full screen (e.g. Calculator).
        case unsupported
        /// Asked, but the window never reported full screen.
        case didNotSwitch
        /// The app didn't show a window in time.
        case noWindow
        /// PurrNotes isn't allowed to control other apps' windows.
        case notAllowed

        var explanation: String {
            switch self {
            case .done, .alreadyFullScreen: return "full screen"
            case .unsupported: return "this app doesn't support full screen"
            case .didNotSwitch: return "the window didn't switch to full screen"
            case .noWindow: return "no window appeared in time"
            case .notAllowed: return "PurrNotes isn't allowed under Accessibility"
            }
        }
    }

    private static let fullScreenAttribute = "AXFullScreen" as CFString

    /// Whether PurrNotes may control other apps' windows. Never shows a prompt.
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own "allow PurrNotes" prompt (which also adds PurrNotes to
    /// the Accessibility list) and opens that page of System Settings.
    static func askForPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Waits for the app's main window, switches it to full screen, and waits for
    /// the animation to finish so the next app can be launched cleanly.
    static func enter(pid: pid_t, windowTimeout: TimeInterval = 15) async -> Result {
        guard isAllowed else { return .notAllowed }
        let app = AXUIElementCreateApplication(pid)
        // Never let a busy, still-launching app freeze PurrNotes for long.
        AXUIElementSetMessagingTimeout(app, 1.0)
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

        // Bring the app to the front first. If the previous app just went full
        // screen, this switches back to the desktop where this app's window is;
        // until then its window is invisible to the Accessibility API.
        await bringToFront(pid: pid)

        // Wait for a real window that is ready to go full screen. A window that has
        // only just appeared often isn't ready yet, so keep checking until the deadline.
        var window: AXUIElement?
        var ready = false
        let deadline = Date().addingTimeInterval(windowTimeout)
        var nextActivate = Date().addingTimeInterval(2)
        while Date() < deadline {
            if Date() >= nextActivate {
                // Still nothing: the app may have lost the front; ask again.
                NSRunningApplication(processIdentifier: pid)?.activate()
                nextActivate = Date().addingTimeInterval(2)
            }
            if let w = mainWindow(of: app) {
                AXUIElementSetMessagingTimeout(w, 1.0)
                window = w
                if isFullScreen(w) { return .alreadyFullScreen }
                if canSetFullScreen(w) || fullScreenButton(of: w) != nil {
                    ready = true
                    break
                }
            }
            await pause(0.25)
        }
        guard let window else { return .noWindow }
        guard ready else { return .unsupported }

        // Full screen is applied most reliably to the frontmost app's window.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            await bringToFront(pid: pid)
        }

        // First ask directly; if the window doesn't switch, press its green button.
        if canSetFullScreen(window) {
            AXUIElementSetAttributeValue(window, fullScreenAttribute, kCFBooleanTrue)
            if await waitForFullScreen(window, seconds: 3) { return .done }
        }
        if let button = fullScreenButton(of: window), AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            if await waitForFullScreen(window, seconds: 4) { return .done }
        }
        return isFullScreen(window) ? .done : .didNotSwitch
    }

    /// Reads whether a process's main window is in full screen (used by the test).
    static func isMainWindowFullScreen(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        return mainWindow(of: app).map(isFullScreen) ?? false
    }

    /// Debug: describes every window of a running app as the Accessibility API sees it.
    static func probe(bundleID: String) -> String {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return "\(bundleID) is not running"
        }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1.0)
        var lines = ["allowed=\(isAllowed) pid=\(running.processIdentifier) active=\(running.isActive)"]
        let main: AXUIElement? = copy(app, kAXMainWindowAttribute)
        let focused: AXUIElement? = copy(app, kAXFocusedWindowAttribute)
        lines.append("main window: \(main.map(describe) ?? "none")")
        lines.append("focused window: \(focused.map(describe) ?? "none")")
        let windows: [AXUIElement] = copy(app, kAXWindowsAttribute) ?? []
        for (i, w) in windows.enumerated() { lines.append("window \(i): \(describe(w))") }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    /// Activates the app and waits until it is frontmost and any Space switch has finished.
    private static func bringToFront(pid: pid_t) async {
        guard let running = NSRunningApplication(processIdentifier: pid) else { return }
        running.activate()
        let until = Date().addingTimeInterval(3)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, Date() < until {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // The slide between Spaces takes a moment; windows show up once it ends.
        try? await Task.sleep(nanoseconds: 900_000_000)
    }

    /// Waits for the full-screen animation; true once the window reports full screen.
    private static func waitForFullScreen(_ window: AXUIElement, seconds: Double) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while !isFullScreen(window), Date() < until {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard isFullScreen(window) else { return false }
        // Let the new Space finish sliding in before the next app is launched.
        try? await Task.sleep(nanoseconds: 900_000_000)
        return true
    }

    private static func canSetFullScreen(_ window: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(window, fullScreenAttribute, &settable) == .success && settable.boolValue
    }

    private static func fullScreenButton(of window: AXUIElement) -> AXUIElement? {
        copy(window, kAXFullScreenButtonAttribute)
    }

    private static func describe(_ w: AXUIElement) -> String {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(w, fullScreenAttribute, &settable)
        let title: String = copy(w, kAXTitleAttribute) ?? "?"
        let subrole: String = copy(w, kAXSubroleAttribute) ?? "?"
        let full: Bool? = copy(w, fullScreenAttribute as String)
        return "title=\"\(title)\" subrole=\(subrole) AXFullScreen=\(full.map(String.init) ?? "nil") "
            + "settable=\(settable.boolValue) (err \(err.rawValue)) greenButton=\(fullScreenButton(of: w) != nil)"
    }

    private static func mainWindow(of app: AXUIElement) -> AXUIElement? {
        if let main: AXUIElement = copy(app, kAXMainWindowAttribute) { return main }
        let windows: [AXUIElement] = copy(app, kAXWindowsAttribute) ?? []
        return windows.first { (copy($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole }
    }

    private static func isFullScreen(_ window: AXUIElement) -> Bool {
        (copy(window, fullScreenAttribute as String) as Bool?) ?? false
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
