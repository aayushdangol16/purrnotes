import AppKit
import Combine

// MARK: - Configuration

/// One app in the workstation, in launch order.
struct WorkstationApp: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var bundleID: String?
    var enabled = true
    /// Launch without showing its windows.
    var startHidden = false
    /// Put the app's window into native full screen (its own Space) after launching.
    var fullScreen = true
    /// Optional web address, file or folder to open in the app (e.g. a project folder for VS Code).
    var openTarget = ""

    init(path: String) {
        self.path = path
        name = WorkstationApp.displayName(for: path)
        bundleID = Bundle(path: path)?.bundleIdentifier
    }

    static func displayName(for path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private enum CodingKeys: String, CodingKey { case id, name, path, bundleID, enabled, startHidden, fullScreen, openTarget }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? WorkstationApp.displayName(for: path)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        startHidden = try c.decodeIfPresent(Bool.self, forKey: .startHidden) ?? false
        // Set-ups saved before this option existed open in full screen unless hidden.
        fullScreen = try c.decodeIfPresent(Bool.self, forKey: .fullScreen) ?? !startHidden
        openTarget = try c.decodeIfPresent(String.self, forKey: .openTarget) ?? ""
    }
}

// MARK: - Session

/// What happened to one app when the workstation started.
struct SessionEntry: Identifiable, Codable, Equatable {
    enum Outcome: String, Codable {
        /// Launched by the workstation: it will be quit when the session ends.
        case opened
        /// Was already running before the workstation started: it is left alone.
        case alreadyRunning
        /// Could not be launched.
        case failed
    }

    var id: UUID          // the WorkstationApp's id
    var name: String
    var bundleID: String?
    var outcome: Outcome
    var pid: Int32?
    var launchDate: Date?
    var note: String?
    /// true: went full screen. false: couldn't (see `fullScreenNote`). nil: not asked for, or skipped.
    var fullScreen: Bool?
    var fullScreenNote: String?
}

/// Owns the workstation set-up (`workstation.json`) and the current session
/// (`workstation-session.json`), and does the launching and closing.
///
/// Only apps the workstation itself launched are ever quit. An app counts as
/// launched by the workstation only if nothing with its bundle ID was running
/// just before the launch, and it is quit only if the same process (pid, bundle
/// ID and launch time all matching) is still the one running.
@MainActor
final class Workstation: NSObject, ObservableObject {
    enum Phase { case idle, starting, active, ending }

    private struct Config: Codable {
        var apps: [WorkstationApp]
        var pauseSeconds: Double?
    }

    private struct SavedSession: Codable {
        var started: Date
        var entries: [SessionEntry]
    }

    static let defaultBundleIDs = ["com.apple.Safari", "com.brave.Browser", "com.apple.Terminal", "com.microsoft.VSCode"]

    @Published private(set) var apps: [WorkstationApp] = []
    /// Seconds to wait between launching one app and the next.
    @Published var pauseSeconds: Double = 0.5 { didSet { if pauseSeconds != oldValue { scheduleSave() } } }
    @Published private(set) var hasUnsavedChanges = false

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var entries: [SessionEntry] = []
    /// A short message about the last start or end, shown under the button.
    @Published private(set) var message: String?
    /// Bumped when other apps launch or quit, so running/closed labels stay current.
    @Published private(set) var refreshTick = 0
    /// Whether macOS lets PurrNotes put other apps into full screen (Accessibility permission).
    @Published private(set) var fullScreenAllowed = FullScreen.isAllowed

    let configURL: URL
    let sessionURL: URL
    private var saveTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    init(directory: URL? = nil) {
        let dir = directory ?? NotesStore.defaultDirectory
        configURL = dir.appendingPathComponent("workstation.json")
        sessionURL = dir.appendingPathComponent("workstation-session.json")
        super.init()
        loadConfig()
        loadSession()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTick += 1 }
            })
        }
        // Re-check the permission whenever the user comes back from System Settings.
        workspaceObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        })
    }

    func refreshPermission() {
        let allowed = FullScreen.isAllowed
        if allowed != fullScreenAllowed { fullScreenAllowed = allowed }
    }

    /// True when a switched-on app wants full screen but macOS hasn't allowed it yet.
    var needsFullScreenPermission: Bool {
        !fullScreenAllowed && enabledApps.contains { $0.fullScreen && !$0.startHidden }
    }

    // MARK: Reading

    var enabledApps: [WorkstationApp] { apps.filter(\.enabled) }

    /// Session entries for apps the workstation launched and that are still running.
    var ownedRunning: [SessionEntry] {
        entries.filter { $0.outcome == .opened && Self.runningApp(for: $0) != nil }
    }

    func entry(for app: WorkstationApp) -> SessionEntry? { entries.first { $0.id == app.id } }

    func isInstalled(_ app: WorkstationApp) -> Bool { FileManager.default.fileExists(atPath: app.path) }

    /// The running process for a session entry, but only if it is the very same
    /// process that was launched: pid, bundle ID and launch time must all match.
    static func runningApp(for entry: SessionEntry) -> NSRunningApplication? {
        guard let pid = entry.pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        if let id = entry.bundleID, app.bundleIdentifier != id { return nil }
        switch (entry.launchDate, app.launchDate) {
        case let (recorded?, actual?):
            return abs(recorded.timeIntervalSince(actual)) < 1.5 ? app : nil
        case (nil, nil):
            return app
        default:
            return nil
        }
    }

    // MARK: Editing the set-up

    func add(path: String) {
        guard !apps.contains(where: { $0.path == path }) else { return }
        apps.append(WorkstationApp(path: path))
        scheduleSave()
    }

    func remove(_ id: UUID) {
        apps.removeAll { $0.id == id }
        scheduleSave()
    }

    func move(_ id: UUID, by offset: Int) {
        guard let i = apps.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard apps.indices.contains(j) else { return }
        apps.swapAt(i, j)
        scheduleSave()
    }

    func update(_ id: UUID, _ change: (inout WorkstationApp) -> Void) {
        guard let i = apps.firstIndex(where: { $0.id == id }) else { return }
        var app = apps[i]
        change(&app)
        guard app != apps[i] else { return }
        apps[i] = app
        scheduleSave()
    }

    /// Points an entry at a different copy of the app (keeps its other settings).
    func changePath(_ id: UUID, to path: String) {
        update(id) { app in
            app.path = path
            app.name = WorkstationApp.displayName(for: path)
            app.bundleID = Bundle(path: path)?.bundleIdentifier
        }
    }

    // MARK: Starting

    /// Launches every enabled app in order, one after another.
    func start() async {
        guard phase == .idle else { return }
        phase = .starting
        entries = []
        message = nil
        refreshPermission()
        let plan = enabledApps
        let pause = max(0, pauseSeconds)

        // Step 1: open every app on the current desktop, in order.
        for (index, app) in plan.enumerated() {
            let entry = await launch(app)
            entries.append(entry)
            saveSession()
            if index < plan.count - 1, pause > 0 {
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            }
        }

        // Step 2: put each app the workstation opened into full screen, one at a
        // time and in the same order. Each switch moves the user into that app's
        // new Space, and macOS only lets PurrNotes see windows on the Space being
        // shown, so every app is brought to the front (back on the desktop) first.
        Self.trace("full-screen step: allowed=\(fullScreenAllowed) live=\(FullScreen.isAllowed)")
        if fullScreenAllowed {
            for app in plan where app.fullScreen && !app.startHidden {
                // Right after launch macOS can take a moment to fill in an app's details,
                // so give the "is this the app we opened?" check up to 2 seconds.
                if let i = entries.firstIndex(where: { $0.id == app.id && $0.outcome == .opened }) {
                    let until = Date().addingTimeInterval(2)
                    while Self.runningApp(for: entries[i]) == nil, Date() < until {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
                guard let i = entries.firstIndex(where: { $0.id == app.id && $0.outcome == .opened }),
                      let pid = entries[i].pid, Self.runningApp(for: entries[i]) != nil else {
                    let e = entries.first { $0.id == app.id }
                    if let pid = e?.pid, let live = NSRunningApplication(processIdentifier: pid) {
                        Self.trace("  live app: bundle=\(String(describing: live.bundleIdentifier)) expected=\(String(describing: e?.bundleID)) "
                            + "terminated=\(live.isTerminated) dateDiff=\(String(describing: e?.launchDate.flatMap { d in live.launchDate.map { d.timeIntervalSince($0) } }))")
                    } else {
                        Self.trace("  live app: NSRunningApplication(processIdentifier:) returned nil")
                    }
                    Self.trace("skip \(app.name): outcome=\(e?.outcome.rawValue ?? "none") pid=\(String(describing: e?.pid)) "
                        + "recorded=\(String(describing: e?.launchDate)) live=\(String(describing: e?.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.launchDate }))")
                    continue
                }
                Self.trace("full screen \(app.name) pid=\(pid)")
                let result = await FullScreen.enter(pid: pid)
                switch result {
                case .done, .alreadyFullScreen:
                    entries[i].fullScreen = true
                case .notAllowed:
                    entries[i].fullScreen = nil
                default:
                    entries[i].fullScreen = false
                    entries[i].fullScreenNote = result.explanation
                }
                Self.trace("  -> \(result)")
                saveSession()
            }
        }

        let opened = entries.filter { $0.outcome == .opened }.count
        let already = entries.filter { $0.outcome == .alreadyRunning }.count
        let failed = entries.filter { $0.outcome == .failed }.count
        var parts: [String] = []
        if opened > 0 { parts.append("opened \(opened)") }
        if already > 0 { parts.append("\(already) already open") }
        if failed > 0 { parts.append("\(failed) couldn't open") }
        message = plan.isEmpty ? "No apps are switched on." : (parts.joined(separator: ", ").capitalizedFirst + ".")
        let wantedFullScreen = Set(plan.filter { $0.fullScreen && !$0.startHidden }.map(\.id))
        if !fullScreenAllowed, entries.contains(where: { $0.outcome == .opened && wantedFullScreen.contains($0.id) }) {
            message = (message ?? "") + " Full screen was skipped: allow PurrNotes under Accessibility."
        }

        if entries.isEmpty {
            phase = .idle
            clearSession()
        } else {
            phase = .active
        }
    }

    private func launch(_ app: WorkstationApp) async -> SessionEntry {
        var entry = SessionEntry(id: app.id, name: app.name, bundleID: app.bundleID, outcome: .failed)
        let appURL = URL(fileURLWithPath: app.path)
        guard FileManager.default.fileExists(atPath: app.path) else {
            entry.note = "Not found at \(app.path)"
            return entry
        }
        let bundleID = app.bundleID ?? Bundle(url: appURL)?.bundleIdentifier
        entry.bundleID = bundleID

        // Ownership is decided before launching: was anything with this ID already running?
        let wasRunning = isRunning(bundleID: bundleID, appURL: appURL)
        let before = Date()

        let config = NSWorkspace.OpenConfiguration()
        config.hides = app.startHidden
        config.activates = !app.startHidden

        var target: URL?
        let wanted = app.openTarget.trimmingCharacters(in: .whitespaces)
        if !wanted.isEmpty {
            target = Self.targetURL(wanted)
            if target == nil { entry.note = "Couldn't find “\(wanted)”, opened the app on its own" }
        }

        do {
            let running: NSRunningApplication
            if let target {
                running = try await NSWorkspace.shared.open([target], withApplicationAt: appURL, configuration: config)
            } else {
                running = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            }
            let fresh = running.launchDate.map { $0 >= before.addingTimeInterval(-1) } ?? true
            if !wasRunning && fresh {
                entry.outcome = .opened
                entry.pid = running.processIdentifier
                entry.launchDate = running.launchDate
                entry.bundleID = running.bundleIdentifier ?? bundleID
            } else {
                entry.outcome = .alreadyRunning
            }
        } catch {
            entry.outcome = wasRunning ? .alreadyRunning : .failed
            entry.note = error.localizedDescription
        }
        return entry
    }

    /// Safari and a few other system apps really live in a hidden system folder;
    /// prefer the familiar /Applications path when it points at the same app.
    static func friendlyPath(_ url: URL) -> String {
        let candidate = URL(fileURLWithPath: "/Applications").appendingPathComponent(url.lastPathComponent)
        if candidate.path != url.path,
           candidate.resolvingSymlinksInPath().standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path {
            return candidate.path
        }
        return url.path
    }

    private func isRunning(bundleID: String?, appURL: URL) -> Bool {
        if let bundleID {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
        }
        let path = appURL.standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == path }
    }

    /// Accepts a web address (https://…), any other URL scheme, or a file / folder path (~ allowed).
    static func targetURL(_ text: String) -> URL? {
        if let url = URL(string: text), let scheme = url.scheme, scheme.count > 1, !text.hasPrefix("/") {
            return url
        }
        let path = (text as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    // MARK: Ending

    /// Asks every app the workstation opened to quit, newest first, and waits a
    /// few seconds. Apps never get force-quit: anything still open (for example
    /// one asking to save) stays in the session so "End" can be tried again.
    func end() async {
        guard phase == .active else { return }
        phase = .ending
        message = nil

        let targets = entries.filter { $0.outcome == .opened }.reversed()
        var refused: [String] = []
        for entry in targets {
            guard let app = Self.runningApp(for: entry) else { continue }
            if !app.terminate() { refused.append(entry.name) }
        }

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !ownedRunning.isEmpty {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let stillOpen = ownedRunning
        let closed = targets.count - stillOpen.count
        if stillOpen.isEmpty {
            entries = []
            phase = .idle
            clearSession()
            message = closed == 0 ? "Workstation ended. Nothing needed closing."
                                  : "Workstation ended. Closed \(closed) app\(closed == 1 ? "" : "s")."
        } else {
            // Keep only what is still open, so a second "End" retries just those.
            entries = stillOpen
            phase = .active
            saveSession()
            let names = stillOpen.map(\.name).joined(separator: ", ")
            message = refused.isEmpty
                ? "Still open: \(names). It may be asking you something — answer it, then press End again."
                : "Still open: \(names). macOS didn't let PurrNotes quit it; quit it yourself or press End again."
        }
    }

    // MARK: Persistence

    private func loadConfig() {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            apps = Self.defaultBundleIDs.compactMap { id in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { WorkstationApp(path: Self.friendlyPath($0)) }
            }
            // Save straight away so each app keeps the same identity across launches;
            // a running session refers to its apps by that identity.
            hasUnsavedChanges = true
            flush()
            return
        }
        do {
            let config = try Self.decoder.decode(Config.self, from: Data(contentsOf: configURL))
            apps = config.apps
            pauseSeconds = config.pauseSeconds ?? 0.5
            hasUnsavedChanges = false
        } catch {
            setAside(configURL, prefix: "workstation", error: error)
        }
    }

    private func loadSession() {
        guard FileManager.default.fileExists(atPath: sessionURL.path) else { return }
        do {
            let saved = try Self.decoder.decode(SavedSession.self, from: Data(contentsOf: sessionURL))
            // Keep the session only while something it opened is still running.
            let live = saved.entries.filter { $0.outcome == .opened && Self.runningApp(for: $0) != nil }
            if live.isEmpty {
                clearSession()
            } else {
                entries = saved.entries.filter { $0.outcome != .opened || Self.runningApp(for: $0) != nil }
                phase = .active
            }
        } catch {
            setAside(sessionURL, prefix: "workstation-session", error: error)
        }
    }

    private func setAside(_ url: URL, prefix: String, error: Error) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.deletingLastPathComponent().appendingPathComponent("\(prefix).unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: backup)
        NSLog("PurrNotes: could not read %@ (%@). Moved it to %@", url.lastPathComponent, "\(error)", backup.path)
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970   // full precision, needed to recognise the same process later
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    private func saveSession() {
        do {
            try write(SavedSession(started: Date(), entries: entries), to: sessionURL)
        } catch {
            NSLog("PurrNotes: saving the workstation session failed: %@", "\(error)")
        }
    }

    private func clearSession() {
        try? FileManager.default.removeItem(at: sessionURL)
    }

    private func scheduleSave() {
        hasUnsavedChanges = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(saveTimerFired),
                                         userInfo: nil, repeats: false)
    }

    @objc private func saveTimerFired() { flush() }

    /// Writes the set-up immediately if anything changed.
    func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard hasUnsavedChanges else { return }
        do {
            try write(Config(apps: apps, pauseSeconds: pauseSeconds), to: configURL)
            hasUnsavedChanges = false
        } catch {
            NSLog("PurrNotes: saving the workstation set-up failed: %@", "\(error)")
        }
    }

    // MARK: Debug

    /// Prints a line when running with `--trace-workstation` (used by the tests).
    static func trace(_ line: @autoclosure () -> String) {
        if CommandLine.arguments.contains("--trace-workstation") { print("          [ws] \(line())") }
    }

    /// Test hook: rewrites a session entry, e.g. to fake a different launch time.
    func debugReplaceEntries(_ newEntries: [SessionEntry]) {
        entries = newEntries
        saveSession()
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
